package Langertha::Skeid::Proxy;
our $VERSION = '0.003';
# ABSTRACT: Multi-format LLM proxy (OpenAI, Anthropic, Ollama) powered by Langertha::Skeid routing
use strict;
use warnings;
use Mojolicious;
use Mojo::IOLoop;
use Time::HiRes qw(time);
use JSON::MaybeXS qw(decode_json);
use Langertha::Skeid;
use Langertha::Skeid::CapacityProbe;
use Langertha::Skeid::Protocol;
use Langertha::Skeid::Protocol::Anthropic;
use Langertha::Skeid::Protocol::Ollama;
use Langertha::ToolCall;

sub build_app {
  my ($class, %opts) = @_;

  # Auto-detect OpenBao KeyBroker if OPENBAO_ROLE_ID is set
  my @skeid_opts = ($opts{config_file} ? (config_file => $opts{config_file}) : ());
  if ($ENV{OPENBAO_ROLE_ID} && $ENV{OPENBAO_SECRET_ID}) {
    eval {
      require Langertha::Skeid::KeyBroker::OpenBao;
      push @skeid_opts, key_broker => Langertha::Skeid::KeyBroker::OpenBao->new(
        addr      => $ENV{OPENBAO_ADDR} // 'http://127.0.0.1:8200',
        role_id   => $ENV{OPENBAO_ROLE_ID},
        secret_id => $ENV{OPENBAO_SECRET_ID},
      );
    };
    warn "Failed to initialize OpenBao KeyBroker: $@" if $@;
  }

  my $skeid = $opts{skeid} || Langertha::Skeid->new(@skeid_opts);
  if (exists $opts{admin_api_key}) {
    $skeid->admin_api_key(defined($opts{admin_api_key}) ? $opts{admin_api_key} : '');
  }

  # Renew the vault token on a timer rather than when a request discovers it expired. A request
  # that has to renew first pays the round-trip in its own latency, and it is the request least
  # able to afford it -- the first one after a quiet period.
  if ($skeid->has_key_broker && $skeid->key_broker->can('start_renewal')) {
    $skeid->key_broker->start_renewal;
  }

  # Capacity probes (ADR 0009). Held by the app, because a probe that goes out of scope stops
  # polling. Nodes with no capacity block get none, which is plain inflight admission.
  my $probes = Langertha::Skeid::CapacityProbe->start_for_skeid($skeid);
  my $probe_generation = $skeid->_inventory_generation;

  my $app = Mojolicious->new;
  $app->secrets(['skeid-proxy']);
  $app->ua->connect_timeout(10);
  $app->ua->request_timeout(300);
  # Mojo::UserAgent pools 5 upstream connections by default. A proxy serving more concurrent
  # requests than that reconnects for the surplus on every request, which shows up as latency
  # that grows with concurrency for no visible reason. Sized for the concurrency a single
  # Skeid process can actually sustain, not for the number of nodes.
  $app->ua->max_connections(
    (defined($ENV{SKEID_UPSTREAM_POOL}) && $ENV{SKEID_UPSTREAM_POOL} =~ /^\d+$/)
      ? 0 + $ENV{SKEID_UPSTREAM_POOL}
      : 100
  );
  $app->helper(skeid => sub { $skeid });

  # A config reload replaces the whole inventory, so probes have to follow it or they keep
  # polling for nodes that are gone and never start for new ones. An integer compare per
  # request is cheap enough not to need its own timer, and the rebuild itself is rare.
  $app->hook(before_dispatch => sub {
    my $generation = $skeid->_inventory_generation;
    return if $generation == $probe_generation;
    $probe_generation = $generation;
    $_->stop for values %$probes;
    $probes = Langertha::Skeid::CapacityProbe->start_for_skeid($skeid);
  });

  my $r = $app->routes;

  $r->get('/health' => sub {
    my ($c) = @_;
    $c->render(json => { status => 'ok', proxy => 'skeid' });
  });

  # OpenAI format
  $r->get('/v1/models' => sub {
    my ($c) = @_;
    my %seen;
    my @data;
    for my $n (@{$c->skeid->list_nodes}) {
      my $id = $n->{model};
      next unless defined $id && length $id;
      next if $seen{$id}++;
      push @data, {
        id       => $id,
        object   => 'model',
        created  => int(time),
        owned_by => 'skeid',
      };
    }
    $c->render(json => { object => 'list', data => \@data });
  });

  $r->post('/v1/chat/completions' => sub {
    my ($c) = @_;
    _handle_openai_chat($c);
  });

  $r->post('/v1/embeddings' => sub {
    my ($c) = @_;
    _handle_openai_embeddings($c);
  });

  # Anthropic format
  $r->post('/v1/messages' => sub {
    my ($c) = @_;
    _handle_anthropic_messages($c);
  });

  # Ollama format
  $r->post('/api/chat' => sub {
    my ($c) = @_;
    _handle_ollama_chat($c);
  });

  $r->get('/api/tags' => sub {
    my ($c) = @_;
    $c->render(json => Langertha::Skeid::Protocol::Ollama->tags_from_nodes($c->skeid->list_nodes));
  });

  $r->get('/api/ps' => sub {
    my ($c) = @_;
    $c->render(json => { models => [] });
  });

  # Lightweight admin API for live control-plane updates.
  my $admin = $r->under('/skeid' => sub {
    my ($c) = @_;
    return _authorize_admin($c);
  });

  $admin->get('/nodes' => sub {
    my ($c) = @_;
    $c->render(json => { nodes => $c->skeid->list_nodes });
  });

  $admin->post('/nodes' => sub {
    my ($c) = @_;
    my $body = $c->req->json || {};
    my $ok = eval { $c->skeid->call_function('nodes.add', $body)->{ok} };
    if (!$ok || $@) {
      my $msg = $@ ? "$@" : 'invalid node payload';
      $msg =~ s/\s+$//;
      $c->render(json => { error => { message => $msg, type => 'invalid_request_error' } }, status => 400);
      return;
    }
    $c->render(json => { ok => 1, nodes => $c->skeid->list_nodes });
  });

  $admin->post('/nodes/:id/health' => sub {
    my ($c) = @_;
    my $body = $c->req->json || {};
    my $id = $c->param('id');
    my $ok = $c->skeid->call_function('nodes.set_health', {
      id      => $id,
      healthy => ($body->{healthy} ? 1 : 0),
    })->{ok};
    $c->render(json => { ok => $ok ? 1 : 0 });
  });

  $admin->get('/metrics/nodes' => sub {
    my ($c) = @_;
    $c->render(json => { metrics => $c->skeid->node_metrics });
  });

  $admin->get('/usage' => sub {
    my ($c) = @_;
    my $report = $c->skeid->call_function('usage.report', {
      (defined($c->param('since')) && length($c->param('since')) ? (since => $c->param('since')) : ()),
      (defined($c->param('api_key_id')) && length($c->param('api_key_id')) ? (api_key_id => $c->param('api_key_id')) : ()),
      (defined($c->param('model')) && length($c->param('model')) ? (model => $c->param('model')) : ()),
      limit => ($c->param('limit') // 50),
    });
    my $status = ($report->{ok} ? 200 : 400);
    $c->render(status => $status, json => $report);
  });

  return $app;
}

sub _authorize_admin {
  my ($c) = @_;
  $c->skeid->maybe_reload_config;

  my $admin_api_key = $c->skeid->admin_api_key // '';
  if (!length($admin_api_key)) {
    $c->render(status => 404, text => 'Not Found');
    return undef;
  }

  my $auth = $c->req->headers->authorization // '';
  my ($scheme, $token) = $auth =~ /\A(\S+)\s+(.+)\z/;
  if (!defined($scheme) || lc($scheme) ne 'bearer' || !defined($token) || $token ne $admin_api_key) {
    $c->res->headers->header('WWW-Authenticate' => 'Bearer realm="skeid-admin"');
    $c->render(
      status => 401,
      json   => {
        error => {
          type    => 'unauthorized',
          message => 'Missing or invalid admin bearer token',
        },
      },
    );
    return undef;
  }
  return 1;
}

sub _handle_openai_chat {
  my ($c) = @_;
  my $body = $c->req->json;
  unless (ref($body) eq 'HASH') {
    $c->render(json => { error => { message => 'Invalid JSON body', type => 'invalid_request_error' } }, status => 400);
    return;
  }

  my $model = $body->{model} // '';
  my $api_key_id = _request_api_key_id($c);
  _begin_route_async($c, $model, $api_key_id, sub {
    my ($route, $node_id, $started, $tier) = @_;
    return unless $route;

    # The alias layer means the model the client asked for and the model the node is asked for
    # are two different strings (ADR 0008). The upstream body carries the served model; the
    # usage event carries both, or cost attribution silently loses which product was used.
    my $served_model = _served_model($tier, $model);
    $body->{model} = $served_model if ref($body) eq 'HASH';

    my $url = _endpoint_url_for_node($route->{url}, '/chat/completions');
    my $meta = {
      api_format => 'openai',
      endpoint   => '/v1/chat/completions',
      api_key_id => $api_key_id,
      provider   => 'skeid',
      engine     => ($route->{engine} // 'openaibase'),
      model            => $served_model,
      requested_model  => $model,
      route_url        => ($route->{url} // ''),
    };

    if ($body->{stream}) {
      _proxy_openai_stream($c, $url, $body, $node_id, $started, $meta);
      return;
    }

    $c->render_later;
    _proxy_openai_json_async($c, $url, $body, $node_id, $started, $meta, sub {
      my ($res, $err, $status) = @_;
      return if $err;
      _render_upstream_response($c, $res, $node_id);
    });
  });
}

sub _handle_openai_embeddings {
  my ($c) = @_;
  my $body = $c->req->json;
  unless (ref($body) eq 'HASH') {
    $c->render(json => { error => { message => 'Invalid JSON body', type => 'invalid_request_error' } }, status => 400);
    return;
  }

  my $model = $body->{model} // '';
  my $api_key_id = _request_api_key_id($c);
  _begin_route_async($c, $model, $api_key_id, sub {
    my ($route, $node_id, $started, $tier) = @_;
    return unless $route;

    # The alias layer means the model the client asked for and the model the node is asked for
    # are two different strings (ADR 0008). The upstream body carries the served model; the
    # usage event carries both, or cost attribution silently loses which product was used.
    my $served_model = _served_model($tier, $model);
    $body->{model} = $served_model if ref($body) eq 'HASH';

    my $url = _endpoint_url_for_node($route->{url}, '/embeddings');
    my $meta = {
      api_format => 'openai',
      endpoint   => '/v1/embeddings',
      api_key_id => $api_key_id,
      provider   => 'skeid',
      engine     => ($route->{engine} // 'openaibase'),
      model            => $served_model,
      requested_model  => $model,
      route_url        => ($route->{url} // ''),
    };
    $c->render_later;
    _proxy_openai_json_async($c, $url, $body, $node_id, $started, $meta, sub {
      my ($res, $err, $status) = @_;
      return if $err;
      _render_upstream_response($c, $res, $node_id);
    });
  });
}

sub _handle_anthropic_messages {
  my ($c) = @_;
  my $body = $c->req->json;
  unless (ref($body) eq 'HASH') {
    $c->render(json => { error => { message => 'Invalid JSON body', type => 'invalid_request_error' } }, status => 400);
    return;
  }

  if ($body->{stream}) {
    $c->render(json => {
      error => {
        message => 'Anthropic streaming is not implemented in Skeid proxy yet',
        type    => 'not_supported_error',
      }
    }, status => 501);
    return;
  }

  my $openai_body = Langertha::Skeid::Protocol::Anthropic->request_to_openai($body);
  my $model = $openai_body->{model} // '';
  my $api_key_id = _request_api_key_id($c);

  _begin_route_async($c, $model, $api_key_id, sub {
    my ($route, $node_id, $started, $tier) = @_;
    return unless $route;

    # The alias layer means the model the client asked for and the model the node is asked for
    # are two different strings (ADR 0008). The upstream body carries the served model; the
    # usage event carries both, or cost attribution silently loses which product was used.
    my $served_model = _served_model($tier, $model);
    $openai_body->{model} = $served_model;

    my $url = _endpoint_url_for_node($route->{url}, '/chat/completions');
    my $meta = {
      api_format => 'anthropic',
      endpoint   => '/v1/messages',
      api_key_id => $api_key_id,
      provider   => 'skeid',
      engine     => ($route->{engine} // 'openaibase'),
      model            => $served_model,
      requested_model  => $model,
      route_url        => ($route->{url} // ''),
    };
    $c->render_later;
    _proxy_openai_json_async($c, $url, $openai_body, $node_id, $started, $meta, sub {
      my ($res, $err, $status) = @_;
      return if $err;

      my $payload = Langertha::Skeid::Protocol::Anthropic->response_from_openai($res, $model);
      $c->res->code($status || 200);
      $c->res->headers->header('x-skeid-node' => $node_id);
      $c->render(json => $payload);
    });
  });
}

sub _handle_ollama_chat {
  my ($c) = @_;
  my $body = $c->req->json;
  unless (ref($body) eq 'HASH') {
    $c->render(json => { error => 'Invalid JSON body' }, status => 400);
    return;
  }

  if ($body->{stream}) {
    $c->render(json => { error => 'Ollama streaming is not implemented in Skeid proxy yet' }, status => 501);
    return;
  }

  my $openai_body = Langertha::Skeid::Protocol::Ollama->request_to_openai($body);
  my $model = $openai_body->{model} // '';
  my $api_key_id = _request_api_key_id($c);

  _begin_route_async($c, $model, $api_key_id, sub {
    my ($route, $node_id, $started, $tier) = @_;
    return unless $route;

    # The alias layer means the model the client asked for and the model the node is asked for
    # are two different strings (ADR 0008). The upstream body carries the served model; the
    # usage event carries both, or cost attribution silently loses which product was used.
    my $served_model = _served_model($tier, $model);
    $openai_body->{model} = $served_model;

    my $url = _endpoint_url_for_node($route->{url}, '/chat/completions');
    my $meta = {
      api_format      => 'ollama',
      endpoint        => '/api/chat',
      api_key_id      => _request_api_key_id($c),
      provider        => 'skeid',
      engine          => ($route->{engine} // 'openaibase'),
      model           => $served_model,
      requested_model => $model,
      route_url       => ($route->{url} // ''),
    };
    $c->render_later;
    _proxy_openai_json_async($c, $url, $openai_body, $node_id, $started, $meta, sub {
      my ($res, $err, $status) = @_;
      return if $err;

      my $payload = Langertha::Skeid::Protocol::Ollama->response_from_openai($res);
      $c->res->code($status || 200);
      $c->res->headers->header('x-skeid-node' => $node_id);
      $c->render(json => $payload);
    });
  });
}

# Walks the tiers of a requested model (ADR 0008) until one admits the request.
#
# The two ways a tier can fail are not the same and must not be treated the same. A tier with
# no eligible node is skipped immediately -- waiting cannot conjure a node that does not exist.
# A tier whose nodes are all busy is waited on for its own wait_ms, because capacity comes back.
# Only when every tier is exhausted does the request fail, and which failure it is depends on
# whether any tier ever had an eligible node: none did means the model is unroutable (503),
# some did means everything was busy (429).
#
# $cb is called with ($route, $node_id, $started, $tier) on success and with nothing on failure,
# after the error has been rendered.
sub _begin_route_async {
  my ($c, $model, $api_key_id, $cb) = @_;
  $cb ||= sub { };
  my $wait_poll_ms = 0 + ($c->skeid->route_wait_poll_ms // 25);
  $wait_poll_ms = 1 if $wait_poll_ms < 1;

  my $decision = $c->skeid->call_function('route.plan', {
    model      => ($model // ''),
    api_key_id => $api_key_id,
  });

  # The key's policy does not grant this model, or grants it but forbids every tier that serves
  # it. Both are permission answers, and neither improves by retrying -- so neither may be
  # reported as a capacity problem.
  if (!$decision->{permitted}) {
    $c->render(json => {
      error => {
        message => "Model '$model' is not available for this key",
        type    => 'permission_error',
      }
    }, status => 403);
    $cb->();
    return;
  }

  my $plan = $decision->{tiers} || [];
  my $started = time;
  my $saw_eligible = 0;
  my $last_node_id = '';
  my $index = 0;
  my $tier_deadline = 0;

  my $fail = sub {
    # Nothing eligible can mean two different things once a policy is in play: the model is
    # unroutable, or it is routable and this key is not allowed at the nodes that serve it.
    # Only the failure path pays for telling them apart.
    if (!$saw_eligible && grep { @{$_->{deny_tags} || []} } @$plan) {
      my $without_deny = 0;
      for my $tier (@$plan) {
        my $state = $c->skeid->call_function('route.state', {
          model => ($tier->{model} // ''),
          tags  => ($tier->{tags} || []),
        });
        $without_deny = 1, last if ref($state) eq 'HASH' && $state->{has_eligible};
      }
      if ($without_deny) {
        $c->render(json => {
          error => {
            message => "Model '$model' is not available for this key",
            type    => 'permission_error',
          }
        }, status => 403);
        $cb->();
        return;
      }
    }

    if (!$saw_eligible) {
      $c->render(json => {
        error => {
          message => "No healthy node available for model '$model'",
          type    => 'model_not_found',
        }
      }, status => 503);
    } else {
      my $waited_ms = int((time - $started) * 1000);
      my $msg = length($last_node_id)
        ? "Timed out waiting for free capacity on node '$last_node_id' (waited ${waited_ms}ms)"
        : "Timed out waiting for free capacity for model '$model' (waited ${waited_ms}ms)";
      $c->render(json => {
        error => {
          message => $msg,
          type    => 'rate_limit_error',
        }
      }, status => 429);
    }
    $cb->();
    return;
  };

  my $tick;
  $tick = sub {
    return $fail->() if $index > $#$plan;

    my $tier = $plan->[$index];
    my %selector = (
      model     => ($tier->{model} // ''),
      tags      => ($tier->{tags} || []),
      deny_tags => ($tier->{deny_tags} || []),
      (length($tier->{engine} // '') ? (engine => $tier->{engine}) : ()),
    );

    my $state = $c->skeid->call_function('route.state', \%selector);
    if (ref($state) eq 'HASH' && $state->{has_eligible}) {
      $saw_eligible = 1;

      my $route = $c->skeid->call_function('route.next', \%selector)->{node};
      if ($route && ref($route) eq 'HASH') {
        my $node_id = $route->{id};
        $last_node_id = $node_id if defined $node_id;
        if ($c->skeid->call_function('request.start', { id => $node_id })->{ok}) {
          $cb->($route, $node_id, $started, $tier);
          return;
        }
      }

      # Eligible but nothing free: this tier is worth waiting on, up to its own window.
      if (time < $tier_deadline) {
        Mojo::IOLoop->timer($wait_poll_ms / 1000, $tick);
        return;
      }
    }

    $index++;
    $tier_deadline = time + (($plan->[$index] ? ($plan->[$index]{wait_ms} // 0) : 0) / 1000);
    $tick->();
    return;
  };

  $tier_deadline = time + ((@$plan ? ($plan->[0]{wait_ms} // 0) : 0) / 1000);
  $tick->();
  return;
}

sub _proxy_openai_json_async {
  my ($c, $url, $body, $node_id, $started, $meta, $cb) = @_;
  $meta ||= {};
  $cb ||= sub { };

  my %fwd_headers = _forward_headers($c);
  _inject_node_auth_async(\%fwd_headers, $c->skeid, $node_id, sub {
  my $tx = $c->app->ua->build_tx(POST => $url, \%fwd_headers, json => $body);
  $c->app->ua->start($tx => sub {
    my ($ua, $done) = @_;
    my $duration_ms = _duration_ms($started);

    if (my $err = $done->error) {
      $c->skeid->call_function('request.finish', {
        id => $node_id,
        ok => 0,
        duration_ms => $duration_ms,
      });
      _record_usage_event($c, {
        %$meta,
        node_id       => $node_id,
        status_code   => ($err->{code} || 502),
        ok            => 0,
        duration_ms   => $duration_ms,
        error_type    => 'upstream_error',
        error_message => ($err->{message} // 'unknown'),
        metrics       => {},
      });
      $c->render(json => {
        error => {
          message => 'Upstream error: ' . ($err->{message} // 'unknown'),
          type    => 'upstream_error',
        }
      }, status => ($err->{code} || 502));
      $cb->(undef, 1, ($err->{code} || 502));
      return;
    }

    my $res = $done->res;
    my $status = $res->code // 200;

    _observe_capacity($c, $node_id, $res);
    $c->skeid->call_function('request.finish', {
      id => $node_id,
      ok => ($status < 500) ? 1 : 0,
      duration_ms => $duration_ms,
    });

    my $payload = eval { $res->json };
    my $metrics = {};
    if (ref($payload) eq 'HASH') {
      my $tool_calls = eval { [ map { $_->to_hash } Langertha::ToolCall->extract($payload) ] } || [];
      $metrics = eval {
        $c->skeid->call_function('metrics.normalize', {
          provider    => ($meta->{provider} || 'skeid'),
          engine      => ($meta->{engine} || 'openaibase'),
          model       => ($meta->{model} || ($body->{model} // '')),
          route       => ($meta->{endpoint} || ''),
          duration_ms => $duration_ms,
          response    => $payload,
          tool_calls  => $tool_calls,
        });
      } || {};
    }

    _record_usage_event($c, {
      %$meta,
      node_id      => $node_id,
      status_code  => $status,
      ok           => ($status < 500) ? 1 : 0,
      duration_ms  => $duration_ms,
      metrics      => (ref($metrics) eq 'HASH' ? $metrics : {}),
    });

    $cb->($res, 0, $status);
  });
  });

  return;
}

sub _proxy_openai_stream {
  my ($c, $url, $body, $node_id, $started, $meta) = @_;
  $meta ||= {};

  my %fwd_headers = _forward_headers($c);

  # render_later before the key resolution, not after: a cold cache means the callback runs on
  # a later tick, and Mojolicious would have rendered an empty response by then.
  $c->render_later;

  _inject_node_auth_async(\%fwd_headers, $c->skeid, $node_id, sub {
  my $tx = $c->app->ua->build_tx(POST => $url, \%fwd_headers, json => $body);

  my $headers_sent = 0;
  my $had_error = 0;
  my $status = 200;
  my $accumulated_usage = { input => 0, output => 0, total => 0 };
  my $accumulated_content_bytes = 0;

  # Upstream chunks arrive faster than they can be written out, so they are queued and drained
  # one at a time. Writing each chunk directly would end the response after the first one:
  # a dynamic Mojolicious response with no drain callback is finished once its write queue
  # empties, and every later chunk then hits a destroyed transaction. The client sees headers,
  # no body, and no error.
  my @queue;
  my $draining = 0;
  my $upstream_done = 0;
  my $finished = 0;

  my $drain;
  $drain = sub {
    if (!@queue) {
      $draining = 0;
      if ($upstream_done && !$finished) {
        $finished = 1;
        $c->finish;
      }
      return;
    }
    $draining = 1;
    my $chunk = shift @queue;
    $c->write_chunk($chunk => sub { $drain->() });
  };

  # SSE frames do not respect read boundaries: one read can carry half a frame, and the half
  # that completes it arrives in the next. Parsing per read would silently drop the split
  # frame -- usually the last one, which is the one carrying usage.
  my $pending = '';

  $tx->res->content->unsubscribe('read')->on(read => sub {
    my ($content, $bytes) = @_;
    unless ($headers_sent) {
      $status = $tx->res->code // 200;
      $c->res->code($status);
      for my $name (@{$tx->res->headers->names}) {
        my $lc = lc($name);
        next if $lc eq 'content-length' || $lc eq 'transfer-encoding' || $lc eq 'content-encoding';
        $c->res->headers->header($name => $tx->res->headers->header($name));
      }
      $c->res->headers->header('x-skeid-node' => $node_id);
      $headers_sent = 1;
    }

    # Parse SSE lines and accumulate usage + content bytes. The relayed bytes are never
    # modified -- this reads along, it does not rewrite.
    $pending .= $bytes;
    while ($pending =~ s/\A([^\n]*)\n//) {
      my $line = $1;
      next unless $line =~ /^data: (.+?)\s*$/;
      my $json = eval { decode_json($1) };
      next unless $json && ref($json) eq 'HASH';

      if (my $delta = $json->{choices}[0]{delta}) {
        if (my $delta_content = $delta->{content}) {
          $accumulated_content_bytes += length($delta_content);
        }
      }

      if (my $usage = $json->{usage}) {
        $accumulated_usage->{input}   += ($usage->{prompt_tokens} // $usage->{input_tokens} // 0);
        $accumulated_usage->{output} += ($usage->{completion_tokens} // $usage->{output_tokens} // 0);
        $accumulated_usage->{total}  += ($usage->{total_tokens} // 0);
      }
    }

    # The first read event fires with an empty chunk as soon as the upstream headers are
    # parsed, and writing an empty chunk finalizes a Mojolicious response. Relaying it would
    # end the stream before its first token -- headers, no body, no error.
    return unless length $bytes;

    push @queue, $bytes;
    $drain->() unless $draining;
  });

  $c->app->ua->start($tx => sub {
    my ($ua, $tx_done) = @_;

    if (my $err = $tx_done->error) {
      $had_error = 1;
      unless ($headers_sent) {
        my $duration_ms = _duration_ms($started);
        $c->skeid->call_function('request.finish', {
          id => $node_id,
          ok => 0,
          duration_ms => $duration_ms,
        });
        _record_usage_event($c, {
          %$meta,
          node_id       => $node_id,
          status_code   => 502,
          ok            => 0,
          duration_ms   => $duration_ms,
          error_type    => 'upstream_error',
          error_message => ($err->{message} // 'unknown'),
          metrics       => $accumulated_usage->{total} > 0 ? { usage => $accumulated_usage } : {},
        });
        $c->render(json => {
          error => {
            message => 'Upstream error: ' . ($err->{message} // 'unknown'),
            type    => 'upstream_error',
          }
        }, status => 502);
        return;
      }
    }

    my $duration_ms = _duration_ms($started);
    _observe_capacity($c, $node_id, $tx_done->res);
    $c->skeid->call_function('request.finish', {
      id => $node_id,
      ok => ($had_error || $status >= 500) ? 0 : 1,
      duration_ms => $duration_ms,
    });

    # For streaming: use accumulated usage from chunks; if none, try to get from final response
    my $metrics = {};
    if ($accumulated_usage->{total} > 0) {
      $metrics = { usage => $accumulated_usage };
    }

    _record_usage_event($c, {
      %$meta,
      node_id      => $node_id,
      status_code  => $status,
      ok           => ($had_error || $status >= 500) ? 0 : 1,
      duration_ms  => $duration_ms,
      metrics      => $metrics,
    });

    # Only finish once the queue has drained, or the tail of the stream is cut off. If the
    # drain loop is still running it will finish for us when it empties.
    $upstream_done = 1;
    if (!$draining && !$finished) {
      $finished = 1;
      $c->finish;
    }
  });
  });
}

sub _render_upstream_response {
  my ($c, $res, $node_id) = @_;

  $c->res->code($res->code);
  for my $name (@{$res->headers->names}) {
    my $lc = lc($name);
    next if $lc eq 'content-length' || $lc eq 'transfer-encoding' || $lc eq 'content-encoding';
    $c->res->headers->header($name => $res->headers->header($name));
  }
  $c->res->headers->header('x-skeid-node' => $node_id);
  $c->res->body($res->body);
  $c->rendered;
}

# Hop-by-hop headers describe the client's connection to Skeid, not the request. Forwarding
# them upstream is wrong per RFC 7230 and expensive here in particular: a client that sends
# `Connection: close` -- most benchmark tools and plenty of HTTP libraries do -- made Skeid
# tear down its own upstream connection after every single request, so the connection pool
# never held anything and each request paid for a fresh TCP handshake.
my %HOP_BY_HOP = map { $_ => 1 } qw(
  connection
  keep-alive
  proxy-authenticate
  proxy-authorization
  te
  trailer
  transfer-encoding
  upgrade
);

sub _forward_headers {
  my ($c) = @_;
  my %fwd_headers;
  for my $name (@{$c->req->headers->names}) {
    my $lc = lc($name);
    next if $HOP_BY_HOP{$lc};
    next if $lc eq 'host' || $lc eq 'content-length' || $lc eq 'accept-encoding';
    $fwd_headers{$name} = $c->req->headers->header($name);
  }
  return %fwd_headers;
}

# Sets the upstream Authorization header for the selected node, from the KeyBroker
# (api_key_ref) or from the environment (api_key_env), overriding whatever the client sent.
# The callback runs exactly once, and always: a node with no key of its own simply forwards
# the client's header untouched.
#
# Async because resolution can mean a vault round-trip, and this sits between routing and the
# upstream call -- doing it synchronously stalls every other in-flight request for that
# round-trip (ADR 0005). key_async answers from cache without touching the loop, so the
# blocking case is a cold cache, and even then only one request per reference pays for it.
sub _inject_node_auth_async {
  my ($headers_ref, $skeid, $node_id, $cb) = @_;
  $cb ||= sub { };

  my ($node) = grep { ($_->{id} // '') eq $node_id } @{$skeid->nodes};
  return $cb->() unless $node;

  my $apply = sub {
    my ($key) = @_;

    # Fallback: env var
    if (!defined($key) || !length($key)) {
      if (defined(my $env_name = $node->{api_key_env})) {
        $key = $ENV{$env_name} // '';
      }
    }

    return $cb->() unless defined($key) && length($key);
    $headers_ref->{Authorization} = "Bearer $key";
    delete $headers_ref->{'x-api-key'};
    $cb->();
  };

  if ($skeid->has_key_broker && defined(my $ref = $node->{api_key_ref})) {
    $skeid->key_broker->key_async($ref, sub {
      my ($key, $error) = @_;
      # The reference may be logged; what it resolves to may not, and neither may a vault
      # response body that might carry it (ADR 0003).
      warn "KeyBroker resolve failed for '$ref': $error"
        if defined($error) && !defined($key);
      $apply->($key);
    });
    return;
  }

  $apply->();
  return;
}

# The free capacity probe (ADR 0009): a commercial provider will not tell us its queue depth,
# but it puts its rate-limit state on every response we already have in hand. Reading it costs
# no extra request -- which is the whole reason this is worth doing on the request path at all.
#
# Pulls the handful of headers by name rather than walking all of them; this runs per response.
my @CAPACITY_HEADERS = Langertha::Skeid->capacity_header_names;

sub _observe_capacity {
  my ($c, $node_id, $res) = @_;
  return unless defined($node_id) && length($node_id);
  return unless $res;
  my $headers = $res->headers or return;

  my %found;
  for my $name (@CAPACITY_HEADERS) {
    my $value = $headers->header($name);
    $found{$name} = $value if defined $value;
  }
  my $status = $res->code // 0;
  return unless %found || $status == 429;

  $c->skeid->call_function('capacity.observe', {
    id      => $node_id,
    headers => \%found,
    status  => $status,
  });
  return;
}

sub _extract_request_api_key {
  my ($c) = @_;
  my $auth = $c->req->headers->authorization;
  my $x_api_key = $c->req->headers->header('x-api-key');
  my $raw = defined($auth) ? $auth : (defined($x_api_key) ? $x_api_key : '');
  my $api_key = $raw // '';
  $api_key =~ s/^Bearer\s+//i;
  return ($raw, $api_key);
}

# Who the caller is. Everything downstream hangs off this: the routing policy that decides
# which nodes they may reach, and the usage event they get billed for. So it may only be
# derived from something the caller had to prove -- the key they presented.
#
# x-skeid-key-id is honoured only when the deployment says it authenticates the caller before
# Skeid sees the request (routing.trust_key_id_header). Believing it unconditionally would let
# any client name itself into another customer's policy, and into another customer's bill.
sub _request_api_key_id {
  my ($c) = @_;

  if ($c->skeid->trust_key_id_header) {
    my $forced = $c->req->headers->header('x-skeid-key-id')
      // $c->req->headers->header('x-api-key-id');
    return $forced if defined($forced) && length($forced);
  }

  my (undef, $api_key) = _extract_request_api_key($c);
  return $c->skeid->key_id_for_key($api_key);
}

sub _request_id {
  my ($c) = @_;
  my $rid = $c->req->headers->header('x-request-id');
  return $rid if defined($rid) && length($rid);
  return 'req_' . int(time * 1000) . '_' . int(rand(1_000_000));
}

sub _record_usage_event {
  my ($c, $args) = @_;
  $args ||= {};
  my $metrics = ref($args->{metrics}) eq 'HASH' ? $args->{metrics} : {};
  my $usage = ref($metrics->{usage}) eq 'HASH' ? $metrics->{usage} : {};
  my $safe_metrics = {
    %$metrics,
    usage => {
      input  => 0 + ($usage->{input} // $usage->{prompt_tokens} // 0),
      output => 0 + ($usage->{output} // $usage->{completion_tokens} // 0),
      total  => 0 + ($usage->{total} // 0),
    },
  };

  my $recorded = eval {
    $c->skeid->call_function('usage.record', {
      created_at    => Langertha::Skeid::Protocol::iso8601_now(),
      request_id    => _request_id($c),
      api_format    => ($args->{api_format} // ''),
      requested_model => ($args->{requested_model} // $args->{model} // ''),
      endpoint      => ($args->{endpoint} // ''),
      api_key_id    => ($args->{api_key_id} // 'anonymous'),
      provider      => ($args->{provider} // 'skeid'),
      engine        => ($args->{engine} // ''),
      model         => ($args->{model} // ''),
      node_id       => ($args->{node_id} // ''),
      route_url     => ($args->{route_url} // ''),
      status_code   => 0 + ($args->{status_code} // 0),
      ok            => ($args->{ok} ? 1 : 0),
      duration_ms   => 0 + ($args->{duration_ms} // 0),
      error_type    => ($args->{error_type} // ''),
      error_message => ($args->{error_message} // ''),
      metrics       => $safe_metrics,
    });
  };
  if ($@) {
    my $err = "$@";
    $err =~ s/\s+$//;
    $c->app->log->debug("usage.record failed: $err");
    return { ok => 0, error => $err };
  }

  return $recorded;
}

# The model a tier asks its nodes for. Falls back to what the client requested, which is what
# makes an aliasless deployment behave exactly as it did before tiers existed.
sub _served_model {
  my ($tier, $requested) = @_;
  return $requested unless ref($tier) eq 'HASH';
  my $model = $tier->{model};
  return (defined($model) && length($model)) ? $model : $requested;
}

sub _endpoint_url_for_node {
  my ($base, $path) = @_;
  $base //= '';
  $path //= '';
  $base =~ s{/\z}{};

  return $base . $path if $base =~ m{/v1\z} && $path =~ m{^/};
  return $base . '/v1' . $path if $path =~ m{^/};
  return $base . '/v1/' . $path;
}

sub _duration_ms {
  my ($started) = @_;
  return int((time - $started) * 1000);
}

1;
