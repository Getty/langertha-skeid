#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/lib";
use File::Temp qw(tempdir);
use JSON::MaybeXS qw(encode_json);
use Mojo::IOLoop;
use Mojo::Promise;
use Path::Tiny qw(path);
use Scalar::Util qw(weaken);
use Langertha::Skeid;
use Langertha::Skeid::Proxy;
use Test::Skeid::Dispatch;

# The dispatch hooks (ADR 0030): a deployment's own class overrides plan, pick, admit/refuse and
# on-finish, and they change routing in the proxy; an asynchronous pick (pick_node_p) may wait on
# somebody outside the process without blocking the loop, and every path out of it -- answered,
# rejected, died, abandoned by the client -- leaves no slot taken. A class that overrides nothing
# routes as Langertha::Skeid does, through the synchronous pick.

{
  package Local::AsyncSkeid;
  use Moo;
  use namespace::clean;
  extends 'Langertha::Skeid';

  # How each model's pick goes: `slow` resolves after a while with the node tagged `chosen`,
  # `reject` rejects after a while, `die` dies at once, `hold` waits for the test to answer.
  has modes => (is => 'ro', default => sub { {} });
  has held  => (is => 'ro', default => sub { [] });
  has picks => (is => 'rw', default => sub { 0 });

  sub pick_node_p {
    my ($self, %selector) = @_;
    $self->picks($self->picks + 1);
    my $mode = $self->modes->{$selector{model}} // 'slow';
    die "the pick service is down\n" if $mode eq 'die';
    my $p = Mojo::Promise->new;
    if ($mode eq 'hold') {
      push @{$self->held}, [$p, \%selector];
      return $p;
    }
    Mojo::IOLoop->timer(0.05 => sub {
      return $p->reject("the pick service said no\n") if $mode eq 'reject';
      $p->resolve($self->pick_node(%selector, tags => ['chosen']));
    });
    return $p;
  }
}

sub chat { my ($model) = @_; return { model => $model, messages => [{ role => 'user', content => 'hi' }] } }

sub completion {
  my ($model) = @_;
  return {
    id      => 'chatcmpl-hooks',
    object  => 'chat.completion',
    model   => $model,
    choices => [{ index => 0, message => { role => 'assistant', content => 'ok' }, finish_reason => 'stop' }],
    usage   => { prompt_tokens => 2, completion_tokens => 1, total_tokens => 3 },
  };
}

# An app around $skeid with a fake upstream on the same server, and its nodes added.
sub harness {
  my ($skeid, @nodes) = @_;
  my $app = Langertha::Skeid::Proxy->build_app(skeid => $skeid);
  $app->log->level('fatal');
  $app->mode('production');
  my @upstream;
  $app->routes->post('/__fake_upstream/v1/chat/completions' => sub {
    my ($c) = @_;
    my $body = $c->req->json || {};
    push @upstream, $body->{model};
    if ($body->{stream}) {
      $c->res->headers->content_type('text/event-stream; charset=utf-8');
      return $c->render(data => join '',
        qq{data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}\n\n},
        qq{data: [DONE]\n\n});
    }
    $c->render(json => completion($body->{model} // ''));
  });
  $app->routes->post('/__fake_upstream/v1/embeddings' => sub {
    my ($c) = @_;
    push @upstream, ($c->req->json || {})->{model};
    $c->render(json => { object => 'list', data => [{ object => 'embedding', index => 0, embedding => [0.1, 0.2] }],
      usage => { prompt_tokens => 1, total_tokens => 1 } });
  });
  $app->routes->post('/__fake_upstream/v1/rerank' => sub {
    my ($c) = @_;
    push @upstream, ($c->req->json || {})->{model};
    $c->render(json => { results => [{ index => 0, relevance_score => 0.9 }] });
  });
  my $t = Test::Mojo->new($app);
  my $url = $t->ua->server->nb_url->clone;
  $url->path('/__fake_upstream/v1');
  for my $node (@nodes) {
    $skeid->add_node(trust => 'internal', url => "$url", engine => 'openai', healthy => 1,
      max_conns => 1, %$node);
  }
  return ($t, \@upstream, $app);
}

sub served_by {
  my ($t, $model) = @_;
  $t->post_ok('/v1/chat/completions' => json => chat($model));
  return ($t->tx->res->code, $t->tx->res->headers->header('x-skeid-node') // '');
}

sub all_free {
  my ($skeid, $name) = @_;
  my @busy = grep { $_->{inflight} } map { $skeid->node_metrics($_->{id}) } @{$skeid->list_nodes};
  ok !@busy, "$name: no node holds a slot" or diag explain \@busy;
}

sub paired {
  my ($skeid, $id, $started, $name) = @_;
  my $m = $skeid->node_metrics($id);
  is $m->{started}, $started, "$name: $id started $started";
  is $m->{inflight}, 0, "$name: $id holds no slot";
  is $m->{ok} + $m->{error} + ($m->{aborted} // 0) + ($m->{rejected} // 0), $m->{started},
    "$name: every start of $id has its finish";
}

sub run_until {
  my ($cond, $max) = @_;
  return 1 if $cond->();
  my $met = 0;
  my $guard = Mojo::IOLoop->timer(($max // 2) => sub { Mojo::IOLoop->stop });
  my $poll = Mojo::IOLoop->recurring(0.005 => sub {
    return unless $cond->();
    $met = 1;
    Mojo::IOLoop->stop;
  });
  Mojo::IOLoop->start;
  Mojo::IOLoop->remove($_) for $guard, $poll;
  return $met;
}

sub run_for {
  my ($seconds) = @_;
  Mojo::IOLoop->timer($seconds => sub { Mojo::IOLoop->stop });
  Mojo::IOLoop->start;
  return;
}

subtest 'the contract' => sub {
  is(Langertha::Skeid->dispatch_hooks_version, 1, 'dispatch hooks version 1');
  is(Test::Skeid::Dispatch->dispatch_hooks_version, 1, 'a subclass reports the same');
  is(Langertha::Skeid->new->picks_async, 0, 'Langertha::Skeid picks synchronously');
  is(Test::Skeid::Dispatch->new->picks_async, 0, 'so does a class that overrides only pick_node');
  is(Local::AsyncSkeid->new->picks_async, 1, 'a class that overrides pick_node_p picks through it');
  ok((grep { $_ eq 'skeid_class' } Langertha::Skeid->capabilities), 'skeid_class is a capability');
};

subtest 'without a subclass: unchanged, and no promise on the request path' => sub {
  my $calls = 0;
  my $orig = \&Langertha::Skeid::pick_node_p;
  no warnings 'redefine';
  local *Langertha::Skeid::pick_node_p = sub { $calls++; goto &$orig };
  use warnings 'redefine';

  my $skeid = Langertha::Skeid->new(route_wait_timeout_ms => 0);
  my ($t) = harness($skeid,
    { id => 'a', model => 'm' },
    { id => 'b', model => 'm', tags => ['warm'] },
  );
  my @order = map { (served_by($t, 'm'))[1] } 1 .. 4;
  is_deeply \@order, [qw( a b a b )], 'round-robin over both nodes, tags or not';
  is $calls, 0, 'the default path never calls pick_node_p';
  paired($skeid, $_, 2, 'default') for qw( a b );

  # The default pick_node_p is pick_node in a promise: the same node for the same cursor.
  my $sync  = Langertha::Skeid->new;
  my $async = Langertha::Skeid->new;
  for my $s ($sync, $async) {
    $s->add_node(id => $_, url => "http://$_/v1", model => 'm', trust => 'internal') for qw( a b );
  }
  my @got;
  for (1 .. 3) {
    $async->pick_node_p(model => 'm')->then(sub { push @got, $_[0]{id} })->wait;
  }
  is_deeply \@got, [map { $sync->pick_node(model => 'm')->{id} } 1 .. 3],
    'pick_node_p by default resolves with what pick_node returns';

  my $res;
  $async->call_function('route.next_p', { model => 'nope' })->then(sub { $res = $_[0] })->wait;
  is_deeply $res, { node => undef }, 'route.next_p resolves { node } -- here with nothing';
};

subtest 'a subclass: the hooks change routing' => sub {
  my $skeid = Test::Skeid::Dispatch->new(route_wait_timeout_ms => 30, route_wait_poll_ms => 5);
  my ($t) = harness($skeid,
    { id => 'a', model => 'm' },
    { id => 'b', model => 'm', tags => ['warm'] },
  );

  my @order = map { (served_by($t, 'm'))[1] } 1 .. 3;
  is_deeply \@order, [qw( b b b )], 'pick: the warm node, every time';
  is_deeply [map { $_->{id} } @{$skeid->finished}], [qw( b b b )], 'on finish: once per admitted request';
  ok((!grep { !$_->{ok} } @{$skeid->finished}), 'with the outcome of each');

  my ($code, $node) = served_by($t, 'closed');
  is $code, 403, 'plan: a model the class grants nobody is a 403';
  $t->json_is('/error/type' => 'permission_error');

  $skeid->refused->{b} = 1;
  ($code) = served_by($t, 'm');
  is $code, 429, 'refuse: the picked node refused admission is waited on, then a 429';
  $t->json_is('/error/type' => 'rate_limit_error');

  # The other node is still there: a pick that falls back reaches it once warm is full.
  delete $skeid->refused->{b};
  ok $skeid->start_request('b'), 'the warm node is full';
  (undef, $node) = served_by($t, 'm');
  is $node, 'a', 'pick: a full warm node falls back to the tier';
  $skeid->finish_request('b', ok => 1);
  all_free($skeid, 'subclass');
};

subtest 'pick_node_p: a pick that takes a while' => sub {
  my $skeid = Local::AsyncSkeid->new(route_wait_timeout_ms => 0);
  my ($t, $upstream) = harness($skeid,
    { id => 'a', model => 'm' },
    { id => 'b', model => 'm', tags => ['chosen'] },
  );
  my @order = map { (served_by($t, 'm'))[1] } 1 .. 3;
  is_deeply \@order, [qw( b b b )], 'the node the promise named serves, every time';
  is $skeid->picks, 3, 'one asynchronous pick per request';
  is scalar(@$upstream), 3, 'each reached the upstream';
  paired($skeid, 'b', 3, 'async');
  paired($skeid, 'a', 0, 'async');

  # While one request waits on its pick, the loop serves another.
  $skeid->modes->{held} = 'hold';
  $skeid->add_node(id => 'h', model => 'held', trust => 'internal', engine => 'openai',
    url => $skeid->list_nodes->[0]{url}, healthy => 1, max_conns => 1);
  my $held_done;
  $t->ua->post('/v1/chat/completions' => json => chat('held') => sub { $held_done = $_[1] });
  ok run_until(sub { @{$skeid->held} }), 'a request waits on its pick';
  my (undef, $other) = served_by($t, 'm');
  is $other, 'b', 'another request is served meanwhile';
  ok !$held_done, 'and the first one still waits';
  my ($p, $selector) = @{shift @{$skeid->held}};
  $p->resolve($skeid->pick_node(%$selector));
  ok run_until(sub { $held_done }), 'answered once the pick resolved';
  is $held_done->res->code, 200, 'with 200';
  is $held_done->res->headers->header('x-skeid-node'), 'h', 'from the node the pick named';
  paired($skeid, 'h', 1, 'held pick');
};

subtest 'pick_node_p: the answer comes later, and Mojolicious is told so' => sub {
  # The route callback runs after the action has returned. Unless the request is marked as
  # rendered later, Mojolicious looks for a template first and logs that nothing was rendered --
  # on every request of an async-pick class, a measured cost.
  my $skeid = Local::AsyncSkeid->new(route_wait_timeout_ms => 0);
  my ($t, $upstream, $app) = harness($skeid, { id => 'b', model => 'm', tags => ['chosen'] });
  my @logged;
  $app->log->level('trace');
  $app->log->unsubscribe('message');
  $app->log->on(message => sub { my (undef, undef, @lines) = @_; push @logged, join '', @lines });

  # Every face that routes through the pick: the translated ones and the relayed ones.
  my $chat = chat('m');
  for my $face (
    [ 'OpenAI chat'        => '/v1/chat/completions' => $chat ],
    [ 'OpenAI chat stream' => '/v1/chat/completions' => { %$chat, stream => \1 } ],
    [ 'OpenAI embeddings'  => '/v1/embeddings'       => { model => 'm', input => 'hi' } ],
    [ 'Anthropic'          => '/v1/messages'         => { %$chat, max_tokens => 16 } ],
    [ 'Ollama chat'        => '/api/chat'            => { %$chat, stream => \0 } ],
    [ 'Ollama embed'       => '/api/embed'           => { model => 'm', input => 'hi' } ],
    [ 'rerank'             => '/v1/rerank'           => { model => 'm', query => 'q', documents => ['d'] } ],
  ) {
    my ($name, $path, $body) = @$face;
    @logged = ();
    $t->post_ok($path => json => $body)->status_is(200, "$name: answered");
    is $t->tx->res->headers->header('x-skeid-node'), 'b', "$name: by the node the pick named"
      unless $name =~ /stream/;
    my @noise = grep { /Nothing has been rendered|not found/ } @logged;
    ok !@noise, "$name: no template lookup and no \"nothing rendered\" in the log"
      or diag explain \@noise;
  }
  paired($skeid, 'b', 7, 'rendered later');
  is $skeid->picks, 7, 'each through the asynchronous pick';
};

subtest 'pick_node_p: rejected or died -- an error, and no slot taken' => sub {
  my $skeid = Local::AsyncSkeid->new(route_wait_timeout_ms => 0);
  $skeid->modes->{$_} = $_ for qw( reject die );
  my ($t, $upstream, $app) = harness($skeid,
    { id => 'r', model => 'reject', tags => ['chosen'] },
    { id => 'd', model => 'die',    tags => ['chosen'] },
  );
  my (@logged, @errors);
  $app->log->unsubscribe('message');
  $app->log->on(message => sub { my (undef, undef, @lines) = @_; push @logged, join '', @lines });

  for my $model (qw( reject die )) {
    @logged = ();
    $app->log->level('trace');
    my ($code) = served_by($t, $model);
    ok !(grep { /Nothing has been rendered|not found/ } @logged), "$model: rendered, not looked up";
    my @said = grep { /failed/ } @logged;
    is scalar(@said), 1, "$model: one error line, nothing rendered twice" or diag explain \@said;
    push @errors, @said;
    is $code, 502, "$model: 502";
    $t->json_is('/error/type' => 'api_error')
      ->json_like('/error/message' => qr/Node selection failed for model '\Q$model\E'/);
    unlike $t->tx->res->body, qr/pick service/, "$model: the reason stays out of the answer";
  }
  like $errors[0], qr/Picking a node for model 'reject' failed: the pick service said no/,
    'a rejection is logged with its reason';
  like $errors[1], qr/Picking a node for model 'die' failed: the pick service is down/,
    'so is a pick_node_p that died';
  is scalar(@$upstream), 0, 'nothing reached an upstream';
  paired($skeid, $_, 0, 'failed pick') for qw( r d );

  # The node is fine: once the pick answers, the same node serves.
  $skeid->modes->{reject} = 'slow';
  my (undef, $node) = served_by($t, 'reject');
  is $node, 'r', 'the next pick that resolves is served';
  paired($skeid, 'r', 1, 'after a failed pick');
};

subtest 'pick_node_p: the client hangs up while its pick is out' => sub {
  my $skeid = Local::AsyncSkeid->new(route_wait_timeout_ms => 0);
  $skeid->modes->{m} = 'hold';
  my ($t, $upstream, $app) = harness($skeid, { id => 'a', model => 'm' });

  my @controllers;
  $app->hook(before_dispatch => sub {
    push @controllers, $_[0];
    weaken($controllers[-1]);
  });

  my $json = encode_json(chat('m'));
  my $stream;
  Mojo::IOLoop->client({ address => '127.0.0.1', port => $t->ua->server->nb_url->port } => sub {
    my (undef, $err, $s) = @_;
    return if $err;
    $stream = $s;
    $s->write(join("\r\n", 'POST /v1/chat/completions HTTP/1.1', 'Host: 127.0.0.1',
      'Content-Type: application/json', 'Content-Length: ' . length($json), '', '') . $json);
  });
  ok run_until(sub { @{$skeid->held} }), 'the request waits on its pick';
  $stream->close;
  run_for(0.05);

  # The pick's promise is the class's: it holds the request until it settles, and no longer.
  my ($p, $selector) = @{shift @{$skeid->held}};
  $p->resolve($skeid->pick_node(%$selector));
  ok run_until(sub { !grep { defined } @controllers }), 'the abandoned request was let go';
  run_for(0.05);
  is scalar(@$upstream), 0, 'the late pick called no upstream for nobody';
  paired($skeid, 'a', 0, 'abandoned pick');
};

subtest 'skeid_class: the config names the class build_app builds' => sub {
  my $dir = tempdir(CLEANUP => 1);
  my $file = path($dir)->child('skeid.yaml');
  $file->spew("skeid_class: Test::Skeid::Dispatch\nnodes:\n  - id: a\n    url: http://a/v1\n    trust: internal\n");

  my $app = Langertha::Skeid::Proxy->build_app(config_file => "$file");
  isa_ok $app->skeid, 'Test::Skeid::Dispatch', 'the class of the config';
  is $app->skeid->list_nodes->[0]{id}, 'a', 'built from that config';

  $app = Langertha::Skeid::Proxy->build_app(config_file => "$file", skeid_class => 'Langertha::Skeid');
  is ref($app->skeid), 'Langertha::Skeid', 'an explicit skeid_class wins over the config';

  is(Langertha::Skeid::Proxy->skeid_class, 'Langertha::Skeid', 'nothing named: Langertha::Skeid');
  for my $case (
    [ 'Mojo::File'           => qr/is not a Langertha::Skeid subclass/ ],
    [ 'Test::Skeid::Missing' => qr/not found in \@INC/ ],
    [ 'not a class'          => qr/is not a Perl class name/ ],
  ) {
    my ($name, $error) = @$case;
    ok !eval { Langertha::Skeid::Proxy->skeid_class(skeid_class => $name); 1 }, "$name is refused";
    like $@, $error, 'saying why';
  }

  $file->spew("skeid_class: Mojo::File\n");
  ok !eval { Langertha::Skeid::Proxy->build_app(config_file => "$file"); 1 },
    'build_app refuses a config naming a class that is no Langertha::Skeid';
  like $@, qr/skeid_class 'Mojo::File' is not a Langertha::Skeid subclass/, 'saying why';
};

done_testing;
