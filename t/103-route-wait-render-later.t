#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::IOLoop;
use Langertha::Skeid;
use Langertha::Skeid::Proxy;

# A request on the synchronous pick that has to wait for capacity is answered from the route
# wait timer, after the action has returned (skeid k138). Unless the request is marked as rendered
# later, Mojolicious looks for a template and logs that nothing was rendered, once per waiting
# request. A request that does not wait is answered inside the action and needs no mark.

sub chat { return { model => 'm', messages => [{ role => 'user', content => 'hi' }] } }

sub harness {
  my (%config) = @_;
  my $skeid = Langertha::Skeid->new(route_wait_poll_ms => 20, %config);
  my $app = Langertha::Skeid::Proxy->build_app(skeid => $skeid);
  $app->mode('production');
  $app->routes->post('/__fake_upstream/v1/chat/completions' => sub {
    my ($c) = @_;
    $c->render(json => {
      id      => 'chatcmpl-wait',
      object  => 'chat.completion',
      model   => 'm',
      choices => [{ index => 0, message => { role => 'assistant', content => 'ok' }, finish_reason => 'stop' }],
      usage   => { prompt_tokens => 2, completion_tokens => 1, total_tokens => 3 },
    });
  });
  my $t = Test::Mojo->new($app);
  my $url = $t->ua->server->nb_url->clone;
  $url->path('/__fake_upstream/v1');
  $skeid->add_node(id => 'w', trust => 'internal', url => "$url", engine => 'openai', model => 'm',
    healthy => 1, max_conns => 1);
  my @logged;
  $app->log->level('trace');
  $app->log->unsubscribe('message');
  $app->log->on(message => sub { my (undef, undef, @lines) = @_; push @logged, join '', @lines });
  return ($t, $skeid, \@logged);
}

sub noise { return grep { /Nothing has been rendered|not found/ } @{$_[0]} }

# The status lines the client's request logged -- the fake upstream on the same app logs its own.
sub statuses {
  my ($logged, $code) = @_;
  my ($id) = map { /^\[(\S+?)\]POST "\/v1\// ? $1 : () } @$logged;
  return grep { /^\[\Q$id\E\]\Q$code\E \w/ } @$logged;
}

subtest 'a request that waits, then is served' => sub {
  my ($t, $skeid, $logged) = harness(route_wait_timeout_ms => 2000);
  ok $skeid->start_request('w'), 'the only slot is taken';
  my $freed = 0;
  Mojo::IOLoop->timer(0.1 => sub { $skeid->finish_request('w', ok => 1); $freed = 1 });
  $t->post_ok('/v1/chat/completions' => json => chat())->status_is(200, 'served once the slot is free');
  ok $freed, 'and only after it was freed';
  my @noise = noise($logged);
  ok !@noise, 'no template lookup and no "nothing rendered" in the log' or diag explain \@noise;
  is $skeid->node_metrics('w')->{inflight}, 0, 'no slot left taken';
};

subtest 'a request that waits, then times out' => sub {
  my ($t, $skeid, $logged) = harness(route_wait_timeout_ms => 100);
  ok $skeid->start_request('w'), 'the only slot is taken, and stays taken';
  $t->post_ok('/v1/chat/completions' => json => chat())->status_is(429, '429 after the wait')
    ->json_is('/error/type' => 'rate_limit_error');
  my @noise = noise($logged);
  ok !@noise, 'no template lookup and no "nothing rendered" in the log' or diag explain \@noise;
  is scalar(statuses($logged, 429)), 1, 'rendered exactly once' or diag explain $logged;
  $skeid->finish_request('w', ok => 1);
  is $skeid->node_metrics('w')->{inflight}, 0, 'the test slot given back, nothing else taken';
};

subtest 'no eligible node: 503 at once, rendered once' => sub {
  my ($t, $skeid, $logged) = harness(route_wait_timeout_ms => 100);
  $t->post_ok('/v1/chat/completions' => json => { %{ chat() }, model => 'nope' })
    ->status_is(503)->json_is('/error/type' => 'model_not_found');
  ok !noise($logged), 'nothing in the log about rendering';
  is scalar(statuses($logged, 503)), 1, 'rendered exactly once' or diag explain $logged;
};

subtest 'a request that does not wait' => sub {
  my ($t, $skeid, $logged) = harness(route_wait_timeout_ms => 2000);
  $t->post_ok('/v1/chat/completions' => json => chat())->status_is(200, 'served at once');
  ok !noise($logged), 'nothing in the log about rendering';
  is scalar(statuses($logged, 200)), 1, 'rendered exactly once' or diag explain $logged;
};

done_testing;
