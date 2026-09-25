use strict;
use warnings;
use Test::More;
use Mojolicious;
use Mojo::IOLoop;
use Mojo::Server::Daemon;
use Mojo::UserAgent;
use Langertha::Skeid;
use Langertha::Skeid::Proxy;

# An Anthropic SDK parses an error body as {type: "error", error: {type, message}} and picks its
# exception class from error.type (and, for a stream, from an `event: error` frame). Skeid used
# to answer every /v1/messages failure except the k216 400 in the OpenAI shape
# {error: {message, type}} with OpenAI-only types (model_not_found, upstream_error), so an
# Anthropic client got an unparseable body and a generic exception instead of a rate-limit or
# permission error it can act on. Every error on the Messages face goes through one Anthropic
# renderer; the OpenAI faces keep their own shape (core karr #224).

# --- upstream: one behaviour per model name ---
my $upstream = Mojolicious->new;
$upstream->log->level('fatal');
$upstream->routes->post('/v1/chat/completions' => sub {
  my ($c) = @_;
  my $model  = $c->req->json->{model} // '';
  my $stream = $c->req->json->{stream};

  if ($model eq 'bad-model') {
    return $c->render(status => 400,
      json => { error => { message => 'context too long', type => 'invalid_request_error' } });
  }
  if ($model eq 'boom-model') {
    return $c->render(status => 500,
      json => { error => { message => 'kaputt', type => 'server_error' } });
  }
  if ($model eq 'cut-model' || $model eq 'errchunk-model') {
    $c->render_later;
    $c->res->code(200);
    $c->res->headers->content_type('text/event-stream');
    my @frames = (
      qq{data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}\n\n},
    );
    push @frames, qq{data: {"error":{"message":"engine fell over","type":"server_error"}}\n\n}
      if $model eq 'errchunk-model';
    my $write;
    $write = sub {
      my $frame = shift @frames;
      unless (defined $frame) {
        return $c->finish if $model eq 'errchunk-model';
        # Drop the connection mid-stream: headers and a token went out, the end never comes.
        Mojo::IOLoop->stream($c->tx->connection)->close;
        return;
      }
      $c->write_chunk($frame => sub { Mojo::IOLoop->timer(0.02 => $write) });
    };
    Mojo::IOLoop->timer(0.02 => $write);
    return;
  }
  $c->render(json => {
    id => 'chatcmpl-1', object => 'chat.completion', model => $model,
    choices => [{ index => 0, message => { role => 'assistant', content => 'ok' }, finish_reason => 'stop' }],
    usage => { prompt_tokens => 3, completion_tokens => 1, total_tokens => 4 },
  });
});
my $upstream_daemon = Mojo::Server::Daemon->new(app => $upstream, listen => ['http://127.0.0.1'], silent => 1);
$upstream_daemon->start;
my $up = 'http://127.0.0.1:' . $upstream_daemon->ports->[0] . '/v1';

# A port nothing listens on: the connection is refused, which is an upstream transport error.
my $dead_port = Mojo::IOLoop::Server->generate_port;

my @usage_events;
my $skeid = Langertha::Skeid->new(
  route_wait_poll_ms => 5,
  store_usage_event  => sub { push @usage_events, $_[1]; return { ok => 1 } },
  config_loader      => sub {
    return {
      policies => {
        standard => {
          models    => [qw(ok-model busy-model bad-model boom-model cut-model errchunk-model
                           dead-model forbidden-model no-such-model)],
          deny_tags => ['forbidden'],
        },
      },
      default_policy => 'standard',
      routing        => { wait_timeout_ms => 30, wait_poll_ms => 5 },
    };
  },
);
$skeid->add_node(id => "n-$_", url => $up, model => $_, max_conns => 4)
  for qw(ok-model bad-model boom-model cut-model errchunk-model);
$skeid->add_node(id => 'n-busy', url => $up, model => 'busy-model', max_conns => 1);
$skeid->add_node(id => 'n-dead', url => "http://127.0.0.1:$dead_port/v1", model => 'dead-model', max_conns => 4);
$skeid->add_node(id => 'n-forbidden', url => $up, model => 'forbidden-model', max_conns => 4,
  tags => ['forbidden']);
ok $skeid->start_request('n-busy'), 'occupy the only slot of busy-model';

my $proxy = Langertha::Skeid::Proxy->build_app(skeid => $skeid);
$proxy->log->level('fatal');
$proxy->mode('production');
my $proxy_daemon = Mojo::Server::Daemon->new(app => $proxy, listen => ['http://127.0.0.1'], silent => 1);
$proxy_daemon->start;
my $base = 'http://127.0.0.1:' . $proxy_daemon->ports->[0];

my $ua = Mojo::UserAgent->new;

sub post {
  my ($path, @body) = @_;
  my %headers = ('x-api-key' => 'sk-test', (ref($body[0]) eq 'HASH' ? %{shift @body} : ()));
  my $tx;
  my $guard = Mojo::IOLoop->timer(10 => sub { Mojo::IOLoop->stop });
  $ua->post("$base$path" => \%headers => @body => sub {
    (undef, $tx) = @_;
    Mojo::IOLoop->stop;
  });
  Mojo::IOLoop->start;
  Mojo::IOLoop->remove($guard);
  return $tx->res;
}

sub messages {
  my ($model, %extra) = @_;
  return post('/v1/messages', json => {
    model => $model, max_tokens => 16, messages => [{ role => 'user', content => 'hi' }], %extra,
  });
}

sub is_anthropic_error {
  my ($res, $status, $type, $name) = @_;
  is $res->code, $status, "$name: HTTP $status";
  like $res->headers->content_type // '', qr{application/json}, "$name: a JSON body";
  my $body = $res->json;
  is ref($body), 'HASH', "$name: the body decodes" or return {};
  is $body->{type}, 'error', "$name: top-level type is 'error', the Anthropic envelope";
  is $body->{error}{type}, $type, "$name: error.type is $type";
  ok length($body->{error}{message} // ''), "$name: error.message is set";
  is_deeply [sort keys %$body], [qw(error type)], "$name: nothing but the Anthropic envelope";
  return $body->{error};
}

# Parse an Anthropic SSE body into [event, data] pairs.
sub sse_events {
  my ($body) = @_;
  my @events;
  while ($body =~ /event: (\S+)\ndata: ([^\n]*)\n\n/g) {
    push @events, [ $1, Mojo::JSON::decode_json($2) ];
  }
  return @events;
}

# --- the status -> error.type table, from Anthropic's error reference ---
{
  my %want = (
    400 => 'invalid_request_error', 401 => 'authentication_error', 402 => 'billing_error',
    403 => 'permission_error',      404 => 'not_found_error',      413 => 'request_too_large',
    429 => 'rate_limit_error',      500 => 'api_error',            504 => 'timeout_error',
    529 => 'overloaded_error',
    # Not in the reference: fall back by class.
    502 => 'api_error', 503 => 'api_error', 422 => 'invalid_request_error',
  );
  is(Langertha::Skeid::Protocol::Anthropic->error_type_for_status($_), $want{$_}, "status $_ -> $want{$_}")
    for sort keys %want;
}

# --- the Messages face: every error is Anthropic-shaped ---

is_anthropic_error(post('/v1/messages', { 'Content-Type' => 'application/json' } => 'not json{'),
  400, 'invalid_request_error', 'invalid JSON body');

is_anthropic_error(messages('ok-model', tools => [{ type => 'web_search_20250305', name => 'web_search' }]),
  400, 'invalid_request_error', 'provider built-in tool (k216)');

is_anthropic_error(messages('not-granted'), 403, 'permission_error', 'model not granted to the key');
is_anthropic_error(messages('forbidden-model'), 403, 'permission_error', 'model only on denied nodes');
is_anthropic_error(messages('busy-model'), 429, 'rate_limit_error', 'no free capacity');
is_anthropic_error(messages('no-such-model'), 503, 'api_error', 'no node serves the model');

is_anthropic_error(messages('bad-model'), 400, 'invalid_request_error', 'upstream 400');
is_anthropic_error(messages('boom-model'), 500, 'api_error', 'upstream 500');
is_anthropic_error(messages('dead-model'), 502, 'api_error', 'upstream unreachable');

# A streamed request that fails before the stream opens is an ordinary HTTP error, as it is at
# Anthropic: the SDK has nothing to read an event from yet.
is_anthropic_error(messages('busy-model', stream => \1), 429, 'rate_limit_error', 'streamed, no capacity');
is_anthropic_error(messages('bad-model', stream => \1), 400, 'invalid_request_error', 'streamed, upstream 400');
is_anthropic_error(messages('boom-model', stream => \1), 500, 'api_error', 'streamed, upstream 500');
is_anthropic_error(messages('dead-model', stream => \1), 502, 'api_error', 'streamed, upstream unreachable');

# Once the stream is open the status is already 200, so the failure has to travel in-band as an
# `event: error` frame -- and the stream must not then claim a clean end with message_stop.
for my $case (
  [ 'cut-model',      'upstream connection dropped mid-stream' ],
  [ 'errchunk-model', 'upstream sent an error chunk mid-stream' ],
) {
  my ($model, $name) = @$case;
  @usage_events = ();
  my $res = messages($model, stream => \1);
  is $res->code, 200, "$name: the stream had started";
  my @events = sse_events($res->body);
  is $events[0][0], 'message_start', "$name: the message had opened";
  ok((grep { $_->[0] eq 'content_block_delta' } @events), "$name: a token got through first");
  my ($error) = grep { $_->[0] eq 'error' } @events;
  ok $error, "$name: an error event is sent" or next;
  is $error->[1]{type}, 'error', "$name: its data is typed 'error'";
  is $error->[1]{error}{type}, 'api_error', "$name: error.type is api_error";
  ok length($error->[1]{error}{message} // ''), "$name: error.message is set";
  is $events[-1][0], 'error', "$name: the error is the last event";
  ok !(grep { $_->[0] eq 'message_stop' } @events), "$name: no message_stop claims a clean end";
  is scalar(@usage_events), 1, "$name: one usage event";
  is $usage_events[0]{ok}, 0, "$name: recorded as failed";
}

# The happy path is untouched.
{
  my $res = messages('ok-model');
  is $res->code, 200, 'a good request is still answered';
  is $res->json->{type}, 'message', 'as an Anthropic message';
}

# --- the OpenAI faces keep the OpenAI shape ---

sub is_openai_error {
  my ($res, $status, $type, $name) = @_;
  is $res->code, $status, "$name: HTTP $status";
  my $body = $res->json;
  is ref($body), 'HASH', "$name: the body decodes" or return;
  ok !exists $body->{type}, "$name: no Anthropic top-level type";
  is $body->{error}{type}, $type, "$name: error.type stays $type";
}

sub chat {
  my ($model, %extra) = @_;
  return post('/v1/chat/completions', json => {
    model => $model, messages => [{ role => 'user', content => 'hi' }], %extra,
  });
}

is_openai_error(post('/v1/chat/completions', { 'Content-Type' => 'application/json' } => 'not json{'),
  400, 'invalid_request_error', 'openai: invalid JSON body');
is_openai_error(chat('not-granted'), 403, 'permission_error', 'openai: model not granted');
is_openai_error(chat('busy-model'), 429, 'rate_limit_error', 'openai: no free capacity');
is_openai_error(chat('no-such-model'), 503, 'model_not_found', 'openai: no node serves the model');
is_openai_error(chat('dead-model'), 502, 'upstream_error', 'openai: upstream unreachable');
is_openai_error(chat('dead-model', stream => \1), 502, 'upstream_error', 'openai: streamed, upstream unreachable');
is_openai_error(post('/v1/embeddings', json => { model => 'busy-model', input => 'x' }),
  429, 'rate_limit_error', 'openai embeddings: no free capacity');

# An upstream 4xx on the OpenAI chat face keeps its status and its OpenAI upstream_error type.
is_openai_error(chat('bad-model'), 400, 'upstream_error', 'openai: upstream 400');

$skeid->finish_request('n-busy', ok => 1);

done_testing;
