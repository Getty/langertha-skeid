#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Mojo;
use FindBin;
use lib "$FindBin::Bin/lib";
use JSON::MaybeXS ();
use Mojo::IOLoop;
use Mojo::Promise;
use Langertha::Skeid;
use Langertha::Skeid::Filter;
use Langertha::Skeid::Proxy;
use Langertha::Skeid::Protocol::RawBody;
use Test::Skeid::Filter;

# The filter seam (ADR 0035), through the proxy: without a filter nothing changes, byte for byte;
# with one, the texts of every face are handed out after the pick, replaced in the client's bytes
# without touching anything else, and the answer -- JSON or SSE, content or tool-call arguments --
# is translated back. local plans away from the filter's nodes, refuse and a failing filter
# answer the client, and every path leaves every slot free. The relayed routes and what no
# filter can read never reach a filtered node.

binmode(Test::More->builder->$_, ':encoding(UTF-8)') for qw( output failure_output todo_output );

my $JSON  = JSON::MaybeXS->new(utf8 => 1, canonical => 1);
my $CHARS = JSON::MaybeXS->new;
my $P1 = "\x{27E6}PERSON_1\x{27E7}";
my $E1 = "\x{27E6}EMAIL_1\x{27E7}";

# What the fake upstream does: answer => coderef ($c, $body) rendering the answer.
my (@upstream, $answer);

sub completion {
  my ($content, %extra) = @_;
  return { id => 'cmpl-1', object => 'chat.completion', model => 'm',
    choices => [{ index => 0, message => { role => 'assistant', content => $content, %extra }, finish_reason => 'stop' }],
    usage => { prompt_tokens => 5, completion_tokens => 3, total_tokens => 8 } };
}

# Writes the SSE body in pieces cut at the given byte offsets, one per timer tick.
sub sse_in_pieces {
  my ($c, $body, @cuts) = @_;
  utf8::encode($body) if utf8::is_utf8($body);
  my @pieces;
  my $at = 0;
  for my $cut (@cuts, length $body) {
    push @pieces, substr($body, $at, $cut - $at);
    $at = $cut;
  }
  $c->render_later;
  $c->res->code(200);
  $c->res->headers->content_type('text/event-stream');
  my $write;
  $write = sub {
    return $c->finish unless @pieces;
    my $piece = shift @pieces;
    $c->write_chunk($piece => sub { Mojo::IOLoop->timer(0.005 => $write) });
  };
  Mojo::IOLoop->timer(0.01 => $write);
  return;
}

sub frame { return 'data: ' . $JSON->encode($_[0]) . "\n\n" }

sub harness {
  my (%args) = @_;
  my @events;
  my $class = $args{class} // 'Test::Skeid::Filter';
  my $skeid = $class->new(
    store_usage_event => sub { push @events, $_[1]; return { ok => 1 } },
    %{$args{skeid} || {}},
  );
  my $app = Langertha::Skeid::Proxy->build_app(skeid => $skeid);
  $app->log->level('fatal');
  $app->mode('production');
  for my $path (qw( chat/completions embeddings rerank )) {
    $app->routes->post("/__up/v1/$path" => sub {
      my ($c) = @_;
      push @upstream, { path => $path, bytes => $c->req->body, headers => $c->req->headers->to_hash,
        body => $c->req->json };
      return $answer->($c, $c->req->json || {}) if $answer && $path eq 'chat/completions';
      return $c->render(json => { object => 'list', data => [{ object => 'embedding', index => 0, embedding => [0.1] }],
        usage => { prompt_tokens => 1, total_tokens => 1 } }) if $path eq 'embeddings';
      return $c->render(json => { results => [{ index => 0, relevance_score => 0.5 }] }) if $path eq 'rerank';
      $c->render(json => completion('plain'));
    });
  }
  my $t = Test::Mojo->new($app);
  my $url = $t->ua->server->nb_url->clone;
  $url->path('/__up/v1');
  for my $node (@{$args{nodes} || [{ id => 'cloud', tags => ['cloud'] }]}) {
    $skeid->add_node(trust => 'internal', url => "$url", engine => 'openai', healthy => 1,
      max_conns => 2, model => 'm', %$node);
  }
  $skeid->filter_config($skeid->_load_filter($args{filter})) if $args{filter};
  return ($t, $skeid, \@events, $app, "$url");
}

sub all_free {
  my ($skeid, $name) = @_;
  my @busy = grep { $_->{inflight} } map { $skeid->node_metrics($_->{id}) } @{$skeid->list_nodes};
  ok !@busy, "$name: no node holds a slot" or diag explain \@busy;
}

sub wait_a_moment {
  Mojo::IOLoop->timer(0.2 => sub { Mojo::IOLoop->stop });
  Mojo::IOLoop->start;
}

sub reset_upstream { @upstream = (); $answer = undef }

# ---------------------------------------------------------------------------------------------

subtest 'no filter, no class: the request and the answer are byte for byte what they were' => sub {
  reset_upstream();
  my $calls = 0;
  no warnings 'redefine';
  my $extract = \&Langertha::Skeid::Filter::extract;
  local *Langertha::Skeid::Filter::extract = sub { $calls++; goto &$extract };
  my ($t, $skeid) = harness(class => 'Langertha::Skeid');
  ok !$skeid->filters_requests, 'nothing filters';
  my $bytes = qq({"messages" : [{"role":"user","content":"Max Mustermann \\u00fc"}],  "model":"m","zeta":1});
  my $node_answer = qq({"z":1, "choices":[{"index":0,"message":{"role":"assistant","content":"$P1"}}],"a":2});
  utf8::encode($node_answer);
  $answer = sub { $_[0]->render(data => $node_answer, format => 'json') };
  $t->post_ok('/v1/chat/completions' => { 'Content-Type' => 'application/json' } => $bytes)->status_is(200);
  is $upstream[-1]{bytes}, $bytes, 'the node got the client\'s bytes';
  is $t->tx->res->body, $node_answer, 'the client got the node\'s bytes, placeholder-looking text untouched';

  my $sse = frame({ id => 'c', choices => [{ index => 0, delta => { content => "[PERSON_1] hi" } }] }) . "data: [DONE]\n\n";
  $answer = sub { sse_in_pieces($_[0], $sse, 7, 20) };
  $t->post_ok('/v1/chat/completions' => json => { model => 'm', stream => \1, messages => [{ role => 'user', content => 'x' }] })
    ->status_is(200);
  is $t->tx->res->body, $sse, 'the stream is relayed untouched';
  is $calls, 0, 'no text was extracted';
  all_free($skeid, 'default path');
};

subtest 'a filter configured, a node outside `when`: unchanged, and the filter is not asked' => sub {
  reset_upstream();
  my $calls = 0;
  no warnings 'redefine';
  my $extract = \&Langertha::Skeid::Filter::extract;
  local *Langertha::Skeid::Filter::extract = sub { $calls++; goto &$extract };
  my ($t, $skeid) = harness(nodes => [{ id => 'local', tags => ['local'] }],
    filter => { url => 'http://127.0.0.1:9/never', when => ['cloud'] });
  my $bytes = qq({"model":"m", "messages":[{"role":"user","content":"Max Mustermann"}]});
  $t->post_ok('/v1/chat/completions' => { 'Content-Type' => 'application/json' } => $bytes)->status_is(200);
  is $upstream[-1]{bytes}, $bytes, 'bytes unchanged';
  is scalar @{$skeid->contexts}, 0, 'the filter was not asked';
  is $calls, 0, 'no text was extracted for a node the filter does not apply to';
};

subtest 'OpenAI face, JSON: strings replaced in place, the answer translated back' => sub {
  reset_upstream();
  my ($t, $skeid, $events) = harness();
  $answer = sub { $_[0]->render(json => completion("Dear $P1, write to [EMAIL_1] or [PERSON_9].",
    tool_calls => [{ id => 't', type => 'function', function => { name => 'mail', arguments => qq({"to":"$E1","who":"$P1"}) } }])) };
  my $bytes = qq({ "temperature" : 0.2, "messages":[{"role":"user","content":"I am Max Mustermann, max\@example.org"},)
    . qq({"role":"user","content":[{"type":"text","text":"Erika \\"E\\" M\\\\uller"}]}],)
    . qq("tools":[{"type":"function","function":{"name":"Max Mustermann","parameters":{"type":"object","description":"Max Mustermann"}}}],"model":"m", "user":"a\\/b\\u00fc"});
  $t->post_ok('/v1/chat/completions' => { 'Content-Type' => 'application/json', 'X-Tenant' => 't1' } => $bytes)->status_is(200);

  my $sent = $upstream[-1]{bytes};
  (my $expect = $bytes) =~ s/I am Max Mustermann, max\@example.org/I am $P1, $E1/;
  $expect =~ s/Erika \\"E\\" M\\\\uller/\x{27E6}PERSON_2\x{27E7}/;
  utf8::encode($expect);
  is $sent, $expect, 'only the texts changed: order, spacing, escapes, tools and their schema as sent';
  is $upstream[-1]{headers}{'X-Skeid-Filter'}, 'done', 'the filter\'s header went upstream';

  my $ctx = $skeid->contexts->[-1];
  is_deeply [ map { $_->{id} } @{$ctx->{texts}} ],
    ['$.messages[0].content', '$.messages[1].content[0].text'], 'the texts, never tools or names of tools';
  is $ctx->{face}, 'openai', 'face';
  is $ctx->{kind}, 'chat', 'kind';
  is $ctx->{route}, '/v1/chat/completions', 'route';
  is_deeply $ctx->{node}, { id => 'cloud', tags => ['cloud'] }, 'the node picked';
  is $ctx->{version}, 1, 'contract version';

  my $got = $t->tx->res->json;
  is $got->{choices}[0]{message}{content}, 'Dear Max Mustermann, write to max@example.org or [PERSON_9].',
    'content translated back, lenient form included, unknown left';
  is_deeply $CHARS->decode($got->{choices}[0]{message}{tool_calls}[0]{function}{arguments}),
    { to => 'max@example.org', who => 'Max Mustermann' }, 'tool-call arguments translated back';
  my ($event) = @$events;
  is $event->{pii_found}, 3, 'the filter\'s usage field';
  is $event->{filter_restored}, 4, 'what Skeid translated back';
  is $event->{pii_unknown}, 1, 'the unknown placeholder';
  ok $event->{ok}, 'ok';
  all_free($skeid, 'replace');
};

subtest 'OpenAI face, SSE: placeholders cut across chunks and frames, tool-call fragments per call' => sub {
  reset_upstream();
  my ($t, $skeid, $events) = harness();
  my $sse = join '',
    frame({ id => 'c', choices => [{ index => 0, delta => { role => 'assistant' } }] }),
    frame({ id => 'c', choices => [{ index => 0, delta => { content => "Hi \x{27E6}PERS" } }] }),
    frame({ id => 'c', choices => [{ index => 0, delta => { content => "ON_1\x{27E7}, mail [EMA" } }] }),
    frame({ id => 'c', choices => [{ index => 0, delta => { tool_calls => [
      { index => 0, id => 'a', type => 'function', function => { name => 'f', arguments => qq({"who":"[PER) } },
      { index => 1, id => 'b', type => 'function', function => { name => 'g', arguments => qq({"to":"\x{27E6}EM) } },
    ] } }] }),
    frame({ id => 'c', choices => [{ index => 0, delta => { tool_calls => [{ index => 1, function => { arguments => qq(AIL_1\x{27E7}"}) } }] } }] }),
    frame({ id => 'c', choices => [{ index => 0, delta => { tool_calls => [{ index => 0, function => { arguments => qq(SON_2]"}) } }] } }] }),
    frame({ id => 'c', choices => [{ index => 0, delta => { content => 'IL_1] [' } }] }),
    frame({ id => 'c', choices => [{ index => 0, delta => {}, finish_reason => 'stop' }],
      usage => { prompt_tokens => 4, completion_tokens => 9, total_tokens => 13 } }),
    "data: [DONE]\n\n";
  # Cut inside a frame, inside a multi-byte character, inside a placeholder.
  $answer = sub { sse_in_pieces($_[0], $sse, 3, 70, 71, 72, 140, 300) };
  $t->post_ok('/v1/chat/completions' => json => { model => 'm', stream => \1,
    messages => [{ role => 'user', content => 'Max Mustermann max@example.org Erika "E" M\\uller' }] })->status_is(200);
  my $body = $t->tx->res->body;
  my (%args, $content, $finish, @lines);
  for my $line (split /\n/, $body) {
    push @lines, $line;
    next unless $line =~ /^data: (.*)/ && $1 ne '[DONE]';
    my $f = $JSON->decode($1);
    my $d = $f->{choices}[0]{delta} || {};
    $content .= $d->{content} // '';
    $args{$_->{index}} .= $_->{function}{arguments} // '' for @{$d->{tool_calls} || []};
    $finish = $f->{choices}[0]{finish_reason} if $f->{choices}[0]{finish_reason};
  }
  is $content, 'Hi Max Mustermann, mail max@example.org [', 'content, in order, held text flushed before the end';
  is_deeply $CHARS->decode($args{0}), { who => 'Erika "E" M\\uller' }, 'call 0: valid JSON, value JSON-escaped';
  is_deeply $CHARS->decode($args{1}), { to => 'max@example.org' }, 'call 1';
  is $finish, 'stop', 'the end of the choice';
  like $body, qr/\Q@{[ frame({ id => 'c', choices => [{ index => 0, delta => { role => 'assistant' } }] }) ]}\E/,
    'a frame without text is relayed as it came';
  like $body, qr/data: \[DONE\]\n\n\z/, 'the stream ends as the node ended it';
  my ($event) = @$events;
  is $event->{output_tokens}, 9, 'usage still read off the stream';
  is $event->{filter_restored}, 4, 'restored count';
  all_free($skeid, 'sse');
};

subtest 'OpenAI face, SSE: a frame the filter changed keeps exactly the keys the node sent' => sub {
  reset_upstream();
  my ($t, $skeid) = harness();
  my $sse = join '',
    frame({ id => 'c', object => 'chat.completion.chunk', choices => [{ index => 0, delta => { content => "Hi $P1" } }] }),
    frame({ id => 'c', object => 'chat.completion.chunk', choices => [{ index => 0, delta => {}, finish_reason => 'stop' }] }),
    "data: [DONE]\n\n";
  $answer = sub { sse_in_pieces($_[0], $sse) };
  $t->post_ok('/v1/chat/completions' => json => { model => 'm', stream => \1,
    messages => [{ role => 'user', content => 'Max Mustermann' }] })->status_is(200);
  my ($first) = map { $JSON->decode($_) } grep { $_ ne '[DONE]' } $t->tx->res->body =~ /^data: (.*)$/mg;
  is_deeply [ sort keys %$first ], [qw( choices id object )], 'frame keys as sent';
  is_deeply [ sort keys %{$first->{choices}[0]} ], [qw( delta index )], 'choice keys as sent';
  is_deeply $first->{choices}[0]{delta}, { content => 'Hi Max Mustermann' }, 'delta: only content, translated back';
  all_free($skeid, 'keys');
};

subtest 'Anthropic face: system and tool input are texts, the answer translated back, JSON and stream' => sub {
  reset_upstream();
  my ($t, $skeid) = harness();
  $answer = sub {
    my ($c, $body) = @_;
    return sse_in_pieces($c, join('',
      frame({ id => 'c', choices => [{ index => 0, delta => { content => "Hello \x{27E6}PER" } }] }),
      frame({ id => 'c', choices => [{ index => 0, delta => { content => "SON_1\x{27E7}" } }] }),
      frame({ id => 'c', choices => [{ index => 0, delta => {}, finish_reason => 'stop' }],
        usage => { prompt_tokens => 1, completion_tokens => 2, total_tokens => 3 } }),
      "data: [DONE]\n\n"), 50) if $body->{stream};
    $c->render(json => completion("Hello $P1"));
  };
  my $req = { model => 'm', max_tokens => 10, system => 'Assist Max Mustermann.',
    messages => [
      { role => 'user', content => 'I am Max Mustermann' },
      { role => 'assistant', content => [{ type => 'tool_use', id => 'tu', name => 'find', input => { email => 'max@example.org' } }] },
      { role => 'user', content => [{ type => 'tool_result', tool_use_id => 'tu', content => 'found max@example.org' }] },
    ],
    tools => [{ name => 'find', description => 'Max Mustermann', input_schema => { type => 'object' } }] };
  $t->post_ok('/v1/messages' => json => $req)->status_is(200);
  my $ctx = $skeid->contexts->[-1];
  is $ctx->{face}, 'anthropic', 'face';
  my %text = map { $_->{id} => $_->{text} } @{$ctx->{texts}};
  is $text{'$.messages[0].content'}, 'Assist Max Mustermann.', 'the system prompt, translated into a message';
  ok grep({ /tool_calls\[0\]\.function\.arguments\.email\z/ } keys %text), 'the tool input';
  ok !grep({ $_ eq 'Max Mustermann' && 0 } values %text), 'sanity';
  my $up = $upstream[-1]{body};
  unlike $upstream[-1]{bytes}, qr/I am Max Mustermann|Assist Max|"email\\?":\\?"max\@/, 'no original text upstream';
  is $up->{tools}[0]{function}{description}, 'Max Mustermann', 'tool definitions are not texts';
  is $t->tx->res->json->{content}[0]{text}, 'Hello Max Mustermann', 'the Anthropic answer translated back';

  $t->post_ok('/v1/messages' => json => { %$req, stream => \1 })->status_is(200);
  my $text = join '', map { /"text":"([^"]*)"/ ? $1 : '' } grep { /text_delta/ } split /\n/, $t->tx->res->body;
  is $text, 'Hello Max Mustermann', 'the Anthropic stream translated back';
  all_free($skeid, 'anthropic');
};

subtest 'Ollama face and embeddings' => sub {
  reset_upstream();
  my ($t, $skeid) = harness();
  $answer = sub { $_[0]->render(json => completion("[ person 1 ] wrote")) };
  $t->post_ok('/api/chat' => json => { model => 'm', stream => \0,
    messages => [{ role => 'user', content => 'Max Mustermann' }] })->status_is(200);
  is $t->tx->res->json->{message}{content}, 'Max Mustermann wrote', 'Ollama answer translated back';
  is $upstream[-1]{body}{messages}[0]{content}, $P1, 'the upstream text replaced';

  $t->post_ok('/v1/embeddings' => json => { model => 'm', input => ['Max Mustermann', 'other'] })->status_is(200);
  is_deeply $upstream[-1]{body}{input}, [$P1, 'other'], 'embeddings input replaced';
  is $skeid->contexts->[-1]{kind}, 'embeddings', 'kind embeddings';
  $t->post_ok('/api/embed' => json => { model => 'm', input => 'Max Mustermann' })->status_is(200);
  is $upstream[-1]{body}{input}, $P1, 'Ollama embed input replaced';
  all_free($skeid, 'ollama');
};

subtest 'local: planned again away from the filter\'s nodes, unchanged; none left is 503' => sub {
  reset_upstream();
  my ($t, $skeid, $events) = harness(nodes => [{ id => 'cloud', tags => ['cloud'], weight => 100 },
    { id => 'onprem', tags => ['onprem'] }], filter => { url => 'http://127.0.0.1:9/x', when => ['cloud'] });
  $skeid->decision('local');
  my $bytes = qq({"model":"m","messages":[{"role":"user","content":"Max Mustermann"}]});
  for (1 .. 3) {
    $t->post_ok('/v1/chat/completions' => { 'Content-Type' => 'application/json' } => $bytes)->status_is(200)
      ->header_is('x-skeid-node' => 'onprem');
    is $upstream[-1]{bytes}, $bytes, 'the original request, to the local node';
  }
  ok scalar(@{$skeid->contexts}) >= 1, 'the filter was asked for the cloud node';
  all_free($skeid, 'local');

  my ($t2, $skeid2, $events2) = harness(filter => { url => 'http://127.0.0.1:9/x', when => ['cloud'] });
  $skeid2->decision('local');
  @upstream = ();
  $t2->post_ok('/v1/chat/completions' => json => { model => 'm', messages => [{ role => 'user', content => 'x' }] })
    ->status_is(503)->json_is('/error/type' => 'filter_local_unavailable')
    ->json_like('/error/message' => qr/must stay local/);
  is scalar @upstream, 0, 'nothing went upstream';
  is scalar @$events2, 0, 'nothing went upstream, nothing metered';
  all_free($skeid2, 'local, none left');
};

subtest 'refuse and every failing filter: the client is answered, nothing goes upstream' => sub {
  reset_upstream();
  my ($t, $skeid, $events) = harness();
  $skeid->decision('refuse');
  $skeid->usage({ pii_found => 2, pii_secret => 'Max Mustermann' });
  $t->post_ok('/v1/chat/completions' => json => { model => 'm', messages => [{ role => 'user', content => 'x' }] })
    ->status_is(403)->json_is('/error/type' => 'filter_refused');
  is $events->[-1]{error_type}, 'filter_refused', 'usage event';
  is $events->[-1]{pii_found}, 2, 'with the filter\'s usage';
  ok !exists $events->[-1]{pii_secret}, 'a text in a usage field is dropped';
  all_free($skeid, 'refuse');

  for my $case (
    ['bad decision',    sub { { decision => 'perhaps' } }],
    ['unknown text id', sub { { decision => 'replace', texts => [{ id => '$.model', text => 'x' }] } }],
    ['not an object',   sub { 'yes' }],
    ['dies',            sub { die "boom\n" }],
  ) {
    $skeid->decision($case->[1]);
    $t->post_ok('/v1/chat/completions' => json => { model => 'm', messages => [{ role => 'user', content => 'x' }] })
      ->status_is(503, $case->[0])->json_is('/error/type' => 'filter_unavailable');
    is $events->[-1]{error_type}, 'filter_unavailable', "$case->[0]: usage event";
    all_free($skeid, $case->[0]);
  }
  is scalar @upstream, 0, 'nothing went upstream';

  # The Anthropic face gets its own error shape.
  $skeid->decision('refuse');
  $t->post_ok('/v1/messages' => json => { model => 'm', max_tokens => 5, messages => [{ role => 'user', content => 'x' }] })
    ->status_is(403)->json_is('/type' => 'error');
};

subtest 'the client leaves while the filter is out: its slot is given back' => sub {
  reset_upstream();
  my ($t, $skeid) = harness();
  $skeid->hold(1);
  my $tx = $t->ua->build_tx(POST => '/v1/chat/completions' => json => { model => 'm',
    messages => [{ role => 'user', content => 'Max Mustermann' }] });
  $t->ua->start($tx => sub { });
  Mojo::IOLoop->one_tick until @{$skeid->held};
  is $skeid->node_metrics('cloud')->{inflight}, 1, 'the slot is held while the filter is out';
  Mojo::IOLoop->stream($tx->connection)->close;
  wait_a_moment();
  all_free($skeid, 'client left');
  my ($p, $answer) = @{$skeid->held->[0]};
  $p->resolve($answer);
  wait_a_moment();
  is scalar @upstream, 0, 'the late answer sent nothing upstream';
  all_free($skeid, 'after the late answer');
};

subtest 'Filter::HTTP: the context POSTed with the token, fail-closed on every failure' => sub {
  reset_upstream();
  my (@seen, $filter_answer);
  my ($t, $skeid, $events, $app) = harness(class => 'Langertha::Skeid');
  $app->routes->post('/__filter' => sub {
    my ($c) = @_;
    push @seen, { auth => $c->req->headers->authorization, ctx => $c->req->json };
    $filter_answer->($c);
  });
  my $base = $t->ua->server->nb_url->clone->path('/__filter');
  local $ENV{SKEID_TEST_FILTER_TOKEN} = 'tok-123';
  $skeid->filter_config($skeid->_load_filter({ url => "$base", token_env => 'SKEID_TEST_FILTER_TOKEN',
    timeout_ms => 300, organization => 'acme', pass_headers => ['X-Tenant'] }));
  ok $skeid->filters_requests, 'the config filters';

  $filter_answer = sub {
    my ($c) = @_;
    my $ctx = $c->req->json;
    $c->render(json => { decision => 'replace', texts => [{ id => $ctx->{texts}[0]{id}, text => "hi $P1" }],
      map => [{ text => 'Max', placeholder => $P1 }] });
  };
  $answer = sub { $_[0]->render(json => completion("bye $P1")) };
  $t->post_ok('/v1/chat/completions' => { 'X-Tenant' => 't9', 'X-Skeid-Filter' => 'edge' }
    => json => { model => 'm', messages => [{ role => 'user', content => 'hi Max' }] })->status_is(200);
  is $seen[-1]{auth}, 'Bearer tok-123', 'the token from token_env';
  is $seen[-1]{ctx}{organization}, 'acme', 'organization';
  is_deeply $seen[-1]{ctx}{headers}, { 'x-tenant' => 't9' }, 'pass_headers';
  is $seen[-1]{ctx}{mark}, 'edge', 'the incoming mark header';
  is $upstream[-1]{body}{messages}[0]{content}, "hi $P1", 'replaced upstream';
  is $t->tx->res->json->{choices}[0]{message}{content}, 'bye Max', 'translated back';

  for my $case (
    ['status 500', sub { $_[0]->render(json => { decision => 'pass' }, status => 500) }],
    ['bad JSON',   sub { $_[0]->render(data => 'nope', format => 'json') }],
    ['timeout',    sub { my ($c) = @_; $c->render_later; Mojo::IOLoop->timer(1 => sub { $c->render(json => { decision => 'pass' }) }) }],
  ) {
    $filter_answer = $case->[1];
    @upstream = ();
    $t->post_ok('/v1/chat/completions' => json => { model => 'm', messages => [{ role => 'user', content => 'x' }] })
      ->status_is(503, $case->[0])->json_is('/error/type' => 'filter_unavailable');
    is scalar @upstream, 0, "$case->[0]: nothing upstream";
    all_free($skeid, $case->[0]);
  }
  delete local $ENV{SKEID_TEST_FILTER_TOKEN};
  $filter_answer = sub { $_[0]->render(json => { decision => 'pass' }) };
  $t->post_ok('/v1/chat/completions' => json => { model => 'm', messages => [{ role => 'user', content => 'x' }] })
    ->status_is(503, 'token_env not set')->json_is('/error/type' => 'filter_unavailable');
  unlike $events->[-1]{error_message}, qr/tok-123/, 'no token in the usage event';
};

subtest 'what no filter can read, and the relayed routes, never reach a filtered node' => sub {
  reset_upstream();
  my ($t, $skeid) = harness(nodes => [{ id => 'cloud', tags => ['cloud'], weight => 100 },
    { id => 'onprem', tags => ['onprem'] }], filter => { url => 'http://127.0.0.1:9/x', when => ['cloud'] });
  for (1 .. 3) {
    $t->post_ok('/v1/chat/completions' => json => { model => 'm', messages => [{ role => 'user', content => [
      { type => 'text', text => 'Max Mustermann' }, { type => 'image_url', image_url => { url => 'data:image/png;base64,AA==' } },
    ] }] })->status_is(200)->header_is('x-skeid-node' => 'onprem');
    $t->post_ok('/v1/rerank' => json => { model => 'm', query => 'Max', documents => ['a'] })->status_is(200)
      ->header_is('x-skeid-node' => 'onprem');
  }
  is scalar @{$skeid->contexts}, 0, 'the filter was never asked';
  all_free($skeid, 'unfilterable, admitted on the cloud node first');
  is $skeid->node_metrics('cloud')->{aborted} // 0, 3, 'the cloud node gave back the slot of each unfilterable request';

  my ($t2, $skeid2) = harness(filter => { url => 'http://127.0.0.1:9/x', when => ['cloud'] });
  $t2->post_ok('/v1/rerank' => json => { model => 'm', query => 'Max', documents => ['a'] })
    ->status_is(503)->json_is('/error/type' => 'filter_local_unavailable');
  $t2->post_ok('/v1/audio/transcriptions' => form => { model => 'm', file => { content => 'RIFF', filename => 'a.wav' } })
    ->status_is(503)->json_is('/error/type' => 'filter_local_unavailable');
  $t2->post_ok('/v1/embeddings' => json => { model => 'm', input => [1, 2, 3] })
    ->status_is(503)->json_is('/error/type' => 'filter_local_unavailable');
  $skeid2->add_node(id => 'docs-cloud', trust => 'internal', url => 'http://127.0.0.1:9/v1', kind => 'documents',
    tags => ['cloud'], healthy => 1, max_conns => 1);
  $t2->post_ok('/v1/convert/source' => json => { file_sources => [{ base64_string => 'AA==', filename => 'a.pdf' }] })
    ->status_is(503)->json_is('/error/type' => 'filter_local_unavailable');
  my $code;
  $t2->ua->websocket('/v1/realtime?model=m&intent=transcription' => sub {
    my (undef, $tx) = @_;
    $code = $tx->res->code;
    Mojo::IOLoop->stop;
  });
  Mojo::IOLoop->start;
  is $code, 503, 'realtime: the handshake is refused';
  # No `when`: every node is filtered, so nothing relayed goes anywhere.
  my ($t3) = harness(filter => { url => 'http://127.0.0.1:9/x' });
  $t3->post_ok('/v1/rerank' => json => { model => 'm', query => 'q', documents => ['a'] })
    ->status_is(503)->json_is('/error/type' => 'filter_local_unavailable');
  all_free($skeid2, 'relayed');
};

subtest 'config: strict, and a reload without the section filters nothing' => sub {
  my $skeid = Langertha::Skeid->new;
  for my $bad (
    [[], 'not a hash'], [{}, 'no url'], [{ url => 'ftp://x' }, 'not http'], [{ url => 'http://x', when => [{}] }, 'bad when'],
    [{ url => 'http://x', timeout_ms => 0 }, 'timeout 0'], [{ url => 'http://x', token => 'secret' }, 'unknown key'],
  ) {
    ok !eval { $skeid->_load_filter($bad->[0]); 1 }, "refused: $bad->[1]";
  }
  my $cfg = $skeid->_load_filter({ url => 'http://f/x', when => 'cloud', pass_headers => ['X-A'] });
  is_deeply $cfg, { url => 'http://f/x', timeout_ms => 5000, when => ['cloud'], pass_headers => ['x-a'] }, 'normalized';
  ok grep({ $_ eq 'filter' } Langertha::Skeid->capabilities), 'capability filter';
  is(Langertha::Skeid->filter_hooks_version, 1, 'filter hooks version 1');
};

done_testing;
