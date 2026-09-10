use strict;
use warnings;
use Test::More;
use Mojolicious;
use Mojo::IOLoop;
use Mojo::Server::Daemon;
use Mojo::UserAgent;
use Langertha::Skeid;
use Langertha::Skeid::Proxy;

# The translated formats have a non-streaming path too, and until this file existed nothing
# drove it: every /v1/messages and /api/chat test asked for a stream, where the translation is
# done by the Stream translator on chunks it decodes itself. The plain JSON path takes a
# different route through the proxy -- it is handed the finished upstream response and has to
# turn that into the client's format -- and it was handing the translator a Mojo response
# object where a decoded body was wanted, so every field read off it was undef. Status 200,
# well-formed envelope, no content: the shape of bug that only an end-to-end request finds.

my $upstream = Mojolicious->new;
$upstream->log->level('fatal');
$upstream->routes->post('/v1/chat/completions' => sub {
  my ($c) = @_;
  $c->render(json => {
    id      => 'chatcmpl-1',
    object  => 'chat.completion',
    model   => 'm1',
    choices => [{
      index         => 0,
      message       => { role => 'assistant', content => 'Hello there' },
      finish_reason => 'stop',
    }],
    usage => { prompt_tokens => 7, completion_tokens => 2, total_tokens => 9 },
  });
});
my $upstream_daemon = Mojo::Server::Daemon->new(app => $upstream, listen => ['http://127.0.0.1'], silent => 1);
$upstream_daemon->start;
my $upstream_port = $upstream_daemon->ports->[0];

my $skeid = Langertha::Skeid->new(
  route_wait_poll_ms => 5,
  store_usage_event  => sub { return { ok => 1 } },
);
$skeid->add_node(id => 'n1', url => "http://127.0.0.1:$upstream_port/v1", model => 'm1', max_conns => 4);

my $proxy = Langertha::Skeid::Proxy->build_app(skeid => $skeid);
$proxy->log->level('fatal');
my $proxy_daemon = Mojo::Server::Daemon->new(app => $proxy, listen => ['http://127.0.0.1'], silent => 1);
$proxy_daemon->start;
my $port = $proxy_daemon->ports->[0];

my $ua = Mojo::UserAgent->new;

# Non-blocking, because the upstream, the proxy and this test share one event loop: a
# blocking request would stop the loop that has to serve it.
sub post_json {
  my ($path, $payload) = @_;
  my $tx;
  my $guard = Mojo::IOLoop->timer(10 => sub { Mojo::IOLoop->stop });
  $ua->post("http://127.0.0.1:$port$path" => json => $payload => sub {
    (undef, $tx) = @_;
    Mojo::IOLoop->stop;
  });
  Mojo::IOLoop->start;
  Mojo::IOLoop->remove($guard);
  return $tx->res;
}

# --- Anthropic ---
{
  my $res = post_json('/v1/messages', {
    model => 'm1', max_tokens => 64,
    messages => [{ role => 'user', content => 'hi' }],
  });
  is $res->code, 200, 'a non-streamed Anthropic request is answered';

  my $body = $res->json;
  is $body->{type}, 'message', 'typed as a message';
  is scalar(@{ $body->{content} // [] }), 1, 'one content block -- not an empty array';
  is $body->{content}[0]{type}, 'text', 'the block is text';
  is $body->{content}[0]{text}, 'Hello there', 'carrying what the upstream actually said';
  is $body->{stop_reason}, 'end_turn', 'stop_reason translated from finish_reason';
  is $body->{usage}{input_tokens}, 7, 'input tokens come from the upstream, not from zero';
  is $body->{usage}{output_tokens}, 2, 'output tokens likewise -- a client bills on these';
  like $body->{id}, qr/^msg_chatcmpl-1$/, 'the upstream id is preserved, not replaced by a clock reading';
}

# --- Ollama ---
{
  my $res = post_json('/api/chat', {
    model => 'm1', stream => JSON::MaybeXS::false,
    messages => [{ role => 'user', content => 'hi' }],
  });
  is $res->code, 200, 'a non-streamed Ollama request is answered';

  my $body = $res->json;
  is $body->{message}{content}, 'Hello there', 'the assistant message survives translation';
  is $body->{model}, 'm1', 'the model is reported, not an empty string';
  is $body->{eval_count}, 2, 'eval_count is the completion token count';
  is $body->{prompt_eval_count}, 7, 'prompt_eval_count is the prompt token count';
}

done_testing;
