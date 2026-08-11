use strict;
use warnings;
use Test::More;
use Mojolicious;
use Mojo::IOLoop;
use Mojo::Server::Daemon;
use Mojo::UserAgent;
use JSON::MaybeXS qw(decode_json);
use Langertha::Skeid;
use Langertha::Skeid::Proxy;

# Skeid makes one shape of upstream call and translates at the client edge (ADR 0001). For a
# stream that means rewriting OpenAI SSE into the client's own protocol -- which for Anthropic
# is an event protocol, not a sequence of deltas: the client is told a message began, a block
# opened, then the text, then that both closed, and it reads its token counts from the closing
# events. None of that exists in an OpenAI stream; it is synthesised at the right moments.

my @upstream_bodies;

my $upstream = Mojolicious->new;
$upstream->log->level('fatal');
$upstream->routes->post('/v1/chat/completions' => sub {
  my ($c) = @_;
  push @upstream_bodies, ($c->req->json || {});

  $c->res->code(200);
  $c->res->headers->content_type('text/event-stream');
  $c->write_chunk(qq{data: {"id":"c1","choices":[{"index":0,"delta":{"role":"assistant"}}]}\n\n});
  $c->write_chunk(qq{data: {"id":"c1","choices":[{"index":0,"delta":{"content":"Hel"}}]}\n\n});
  $c->write_chunk(qq{data: {"id":"c1","choices":[{"index":0,"delta":{"content":"lo"}}]}\n\n});
  my $final = '{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],'
            . '"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10}}';
  $c->write_chunk("data: $final\n\n");
  $c->write_chunk(qq{data: [DONE]\n\n});
  $c->write_chunk('' => sub { $c->finish });
});
my $upstream_daemon = Mojo::Server::Daemon->new(app => $upstream, listen => ['http://127.0.0.1'], silent => 1);
$upstream_daemon->start;
my $upstream_port = $upstream_daemon->ports->[0];

my @events;
my $skeid = Langertha::Skeid->new(
  route_wait_poll_ms => 5,
  store_usage_event  => sub { push @events, $_[1]; return { ok => 1 } },
);
$skeid->add_node(id => 'n1', url => "http://127.0.0.1:$upstream_port/v1", model => 'm1', max_conns => 4);

my $proxy = Langertha::Skeid::Proxy->build_app(skeid => $skeid);
$proxy->log->level('fatal');
my $proxy_daemon = Mojo::Server::Daemon->new(app => $proxy, listen => ['http://127.0.0.1'], silent => 1);
$proxy_daemon->start;
my $proxy_port = $proxy_daemon->ports->[0];

my $ua = Mojo::UserAgent->new;

sub post_stream {
  my ($path, $payload) = @_;
  my $tx;
  my $guard = Mojo::IOLoop->timer(10 => sub { Mojo::IOLoop->stop });
  $ua->post("http://127.0.0.1:$proxy_port$path" => json => $payload => sub {
    (undef, $tx) = @_;
    Mojo::IOLoop->stop;
  });
  Mojo::IOLoop->start;
  Mojo::IOLoop->remove($guard);
  return $tx;
}

# Parses an SSE body into [ [event, data], ... ]
sub sse_events {
  my ($body) = @_;
  my @out;
  for my $frame (split /\n\n/, ($body // '')) {
    my ($name) = $frame =~ /^event:\s*(\S+)/m;
    my ($data) = $frame =~ /^data:\s*(.+)$/m;
    next unless defined $name;
    push @out, [$name, ($data ? decode_json($data) : undef)];
  }
  return @out;
}

# --- Anthropic ---
{
  @upstream_bodies = ();
  @events = ();
  my $tx = post_stream('/v1/messages', {
    model      => 'm1',
    max_tokens => 64,
    stream     => JSON::MaybeXS::true,
    messages   => [{ role => 'user', content => 'hi' }],
  });

  is $tx->res->code, 200, 'a streaming Anthropic request is served, not refused with 501';
  like $tx->res->headers->content_type, qr{text/event-stream}, 'as SSE';
  is $tx->res->headers->header('x-skeid-node'), 'n1', 'from the routed node';

  ok $upstream_bodies[0]{stream}, 'the upstream was asked to stream';
  ok $upstream_bodies[0]{stream_options}{include_usage},
    'with include_usage, because an Anthropic client reads token counts from message_delta and '
    . 'an OpenAI stream omits usage unless asked';

  my @got = sse_events($tx->res->body);
  my @names = map { $_->[0] } @got;
  is_deeply \@names,
    [qw(message_start content_block_start content_block_delta content_block_delta
        content_block_stop message_delta message_stop)],
    'the client sees a complete, correctly ordered Anthropic event sequence';

  my ($start) = grep { $_->[0] eq 'message_start' } @got;
  is $start->[1]{message}{role}, 'assistant', 'message_start names the role';
  is $start->[1]{message}{model}, 'm1', 'and the model the client asked for';

  my @deltas = grep { $_->[0] eq 'content_block_delta' } @got;
  is join('', map { $_->[1]{delta}{text} } @deltas), 'Hello',
    'the text arrives intact across chunks';
  is $deltas[0][1]{delta}{type}, 'text_delta', 'as text_delta, which is what a client dispatches on';

  my ($mdelta) = grep { $_->[0] eq 'message_delta' } @got;
  is $mdelta->[1]{delta}{stop_reason}, 'end_turn', "OpenAI's stop becomes Anthropic's end_turn";
  is $mdelta->[1]{usage}{output_tokens}, 3,
    'and the token count reaches the client, which is the whole reason message_delta exists';

  unlike $tx->res->body, qr/\[DONE\]/,
    "OpenAI's [DONE] sentinel is not relayed -- it is not part of this protocol";
  unlike $tx->res->body, qr/"choices"/, 'and no OpenAI-shaped payload leaks through';

  is scalar(@events), 1, 'one usage event';
  is $events[0]{api_format}, 'anthropic', 'recorded under the format the client used';
  is $events[0]{output_tokens}, 3, 'with the tokens the stream carried';
  is $events[0]{input_tokens}, 7, 'and the prompt tokens, so a translated stream still bills';
}

# --- Ollama ---
{
  @upstream_bodies = ();
  @events = ();
  my $tx = post_stream('/api/chat', {
    model    => 'm1',
    stream   => JSON::MaybeXS::true,
    messages => [{ role => 'user', content => 'hi' }],
  });

  is $tx->res->code, 200, 'a streaming Ollama request is served';
  like $tx->res->headers->content_type, qr{application/x-ndjson},
    'as newline-delimited JSON, not SSE -- relaying text/event-stream would tell an Ollama '
    . 'client to parse something it does not speak';

  my @lines = grep { length } split /\n/, ($tx->res->body // '');
  my @objs = map { decode_json($_) } @lines;
  ok scalar(@objs) >= 3, 'several lines, one per delta plus the closing one';

  is join('', map { $_->{message}{content} // '' } @objs), 'Hello', 'the text arrives intact';
  ok !$objs[0]{done}, 'the first line is not done';
  ok $objs[-1]{done}, 'and the last one is';
  is $objs[-1]{done_reason}, 'stop', 'carrying the reason';
  is $objs[-1]{prompt_eval_count}, 7, 'and the prompt tokens';
  is $objs[-1]{eval_count}, 3,
    'and the generated tokens -- an Ollama client reads its statistics from this line and '
    . 'treats the stream as unfinished without it';

  is $events[0]{api_format}, 'ollama', 'usage is recorded for the client format';
}

# Ollama defaults stream to true when the field is absent, unlike everyone else.
{
  @upstream_bodies = ();
  my $tx = post_stream('/api/chat', {
    model    => 'm1',
    messages => [{ role => 'user', content => 'hi' }],
  });
  like $tx->res->headers->content_type, qr{application/x-ndjson},
    'an Ollama request that omits stream still gets one -- that is Ollama\'s default, and a '
    . 'client that omits it is waiting for NDJSON';
}

{
  my $tx = post_stream('/api/chat', {
    model    => 'm1',
    stream   => JSON::MaybeXS::false,
    messages => [{ role => 'user', content => 'hi' }],
  });
  like $tx->res->headers->content_type, qr{application/json},
    'and stream:false still gets a single JSON reply';
  ok $tx->res->json->{done}, 'marked done';
}

# --- OpenAI is untouched ---
{
  @upstream_bodies = ();
  my $tx = post_stream('/v1/chat/completions', {
    model    => 'm1',
    stream   => JSON::MaybeXS::true,
    messages => [{ role => 'user', content => 'hi' }],
  });

  is $tx->res->code, 200, 'an OpenAI stream still works';
  like $tx->res->body, qr/\[DONE\]/,
    'and is relayed byte for byte, sentinel included -- the untranslated path is the only one '
    . 'that cannot lose anything, so it stays a pass-through';
  like $tx->res->body, qr/"delta"/, 'with OpenAI payloads intact';
}

# --- finish_reason == "length" maps to the protocol's own "truncated" reason ---
{
  my $length = Mojolicious->new;
  $length->log->level('fatal');
  $length->routes->post('/v1/chat/completions' => sub {
    my ($c) = @_;
    $c->res->code(200);
    $c->res->headers->content_type('text/event-stream');
    $c->write_chunk(qq{data: {"id":"c1","choices":[{"index":0,"delta":{"content":"half"}}]}\n\n});
    my $final = '{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"length"}],'
              . '"usage":{"prompt_tokens":4,"completion_tokens":1,"total_tokens":5}}';
    $c->write_chunk("data: $final\n\n");
    $c->write_chunk(qq{data: [DONE]\n\n});
    $c->write_chunk('' => sub { $c->finish });
  });
  my $len_daemon = Mojo::Server::Daemon->new(app => $length, listen => ['http://127.0.0.1'], silent => 1);
  $len_daemon->start;
  my $len_port = $len_daemon->ports->[0];

  my $skeid3 = Langertha::Skeid->new(route_wait_poll_ms => 5);
  $skeid3->add_node(id => 'len1', url => "http://127.0.0.1:$len_port/v1", model => 'm1', max_conns => 2);
  my $proxy3 = Langertha::Skeid::Proxy->build_app(skeid => $skeid3);
  $proxy3->log->level('fatal');
  my $pd3 = Mojo::Server::Daemon->new(app => $proxy3, listen => ['http://127.0.0.1'], silent => 1);
  $pd3->start;
  my $port3 = $pd3->ports->[0];

  my $tx;
  my $guard = Mojo::IOLoop->timer(10 => sub { Mojo::IOLoop->stop });
  $ua->post("http://127.0.0.1:$port3/v1/messages" => json => {
    model => 'm1', max_tokens => 64, stream => JSON::MaybeXS::true,
    messages => [{ role => 'user', content => 'hi' }],
  } => sub { (undef, $tx) = @_; Mojo::IOLoop->stop });
  Mojo::IOLoop->start;
  Mojo::IOLoop->remove($guard);

  my ($mdelta) = grep { $_->[0] eq 'message_delta' } sse_events($tx->res->body);
  is $mdelta->[1]{delta}{stop_reason}, 'max_tokens',
    'finish_reason=length maps to Anthropic max_tokens -- a token-budget run-out is what the '
    . 'client needs to know happened';

  my $tx2;
  my $guard2 = Mojo::IOLoop->timer(10 => sub { Mojo::IOLoop->stop });
  $ua->post("http://127.0.0.1:$port3/api/chat" => json => {
    model => 'm1', stream => JSON::MaybeXS::true,
    messages => [{ role => 'user', content => 'hi' }],
  } => sub { (undef, $tx2) = @_; Mojo::IOLoop->stop });
  Mojo::IOLoop->start;
  Mojo::IOLoop->remove($guard2);

  my @lines = grep { length } split /\n/, ($tx2->res->body // '');
  my @objs = map { decode_json($_) } @lines;
  is $objs[-1]{done_reason}, 'length',
    'and Ollama done_reason carries the same OpenAI finish_reason through verbatim';

  is $skeid3->node_metrics('len1')->{inflight}, 0, 'no admission leaked on the length path';
}

# --- an upstream that dies mid-stream still closes the client's protocol ---
{
  my $flaky = Mojolicious->new;
  $flaky->log->level('fatal');
  $flaky->routes->post('/v1/chat/completions' => sub {
    my ($c) = @_;
    $c->res->code(200);
    $c->res->headers->content_type('text/event-stream');
    $c->write_chunk(qq{data: {"id":"c1","choices":[{"index":0,"delta":{"content":"par"}}]}\n\n});
    # No finish_reason, no usage, no [DONE] -- the upstream simply stops talking.
    Mojo::IOLoop->timer(0.05 => sub { $c->finish });
  });
  my $flaky_daemon = Mojo::Server::Daemon->new(app => $flaky, listen => ['http://127.0.0.1'], silent => 1);
  $flaky_daemon->start;
  my $flaky_port = $flaky_daemon->ports->[0];

  my $skeid2 = Langertha::Skeid->new(route_wait_poll_ms => 5);
  $skeid2->add_node(id => 'f1', url => "http://127.0.0.1:$flaky_port/v1", model => 'm1', max_conns => 2);
  my $proxy2 = Langertha::Skeid::Proxy->build_app(skeid => $skeid2);
  $proxy2->log->level('fatal');
  my $pd2 = Mojo::Server::Daemon->new(app => $proxy2, listen => ['http://127.0.0.1'], silent => 1);
  $pd2->start;
  my $port2 = $pd2->ports->[0];

  my $tx;
  my $guard = Mojo::IOLoop->timer(10 => sub { Mojo::IOLoop->stop });
  $ua->post("http://127.0.0.1:$port2/v1/messages" => json => {
    model => 'm1', max_tokens => 64, stream => JSON::MaybeXS::true,
    messages => [{ role => 'user', content => 'hi' }],
  } => sub { (undef, $tx) = @_; Mojo::IOLoop->stop });
  Mojo::IOLoop->start;
  Mojo::IOLoop->remove($guard);

  my @names = map { $_->[0] } sse_events($tx->res->body);
  is $names[-1], 'message_stop',
    'a truncated upstream still ends with message_stop -- an Anthropic client waits for it, so '
    . 'leaving it out turns an upstream hiccup into a client that hangs';
  ok scalar(grep { $_ eq 'content_block_stop' } @names), 'and the open block is closed';

  is $skeid2->node_metrics('f1')->{inflight}, 0, 'no admission leaked on the error path';
}

is $skeid->node_metrics('n1')->{inflight}, 0, 'no admission leaked';

done_testing;
