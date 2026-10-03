package Langertha::Skeid::Proxy;
our $VERSION = '0.004';
# ABSTRACT: Multi-format LLM proxy (OpenAI, Anthropic, Ollama) powered by Langertha::Skeid routing
use strict;
use warnings;
use Mojolicious;
use Mojo::IOLoop;
use Time::HiRes qw(time);
use JSON::MaybeXS qw(decode_json);
use Scalar::Util qw(blessed weaken);
use Mojo::Util qw(decode encode);
use Langertha::Skeid;
use Langertha::Skeid::CapacityProbe;
use Langertha::Skeid::Registry;
use Langertha::Skeid::Secret;
use Langertha::Skeid::Proxy::RelayContent;
use Langertha::Skeid::Protocol;
use Langertha::Skeid::Protocol::Anthropic;
use Langertha::Skeid::Protocol::Anthropic::Stream;
use Langertha::Skeid::Protocol::Audio;
use Langertha::Skeid::Protocol::Ollama;
use Langertha::Skeid::Protocol::Ollama::Stream;
use Langertha::Skeid::Protocol::Rerank;
use Langertha::ToolCall;

=head1 SYNOPSIS

  use Langertha::Skeid::Proxy;
  use Mojo::Server::Daemon;

  my $app = Langertha::Skeid::Proxy->build_app(config_file => '/etc/skeid/skeid.yaml');
  Mojo::Server::Daemon->new(app => $app, listen => ['http://127.0.0.1:8090'])->run;

  # or simply
  skeid serve --config /etc/skeid/skeid.yaml --listen 127.0.0.1:8090

=head1 DESCRIPTION

The Mojolicious application in front of L<Langertha::Skeid>. It speaks three client formats --
OpenAI, Anthropic and Ollama -- and makes one kind of upstream call, an OpenAI-shaped C<POST> to
the node routing picked (ADR 0001); the translation lives in L<Langertha::Skeid::Protocol> and
its per-format modules. Everything else -- nodes, routing, admission, pricing, usage -- is the
control plane's, driven through L<Langertha::Skeid/call_function>, and is configured there (see
L<Langertha::Skeid/CONFIGURATION>). C<skeid serve> runs it.

The request path is asynchronous throughout (ADR 0005): waiting for capacity is a timer, key
resolution goes through L<Langertha::Skeid::KeyBroker/key_async>, and the upstream call never
blocks the loop.

=head2 Client routes

No Skeid credential is needed on these unless the config has a C<client_auth> section; then
every one but C</health> answers C<401> to a key not on its list. See L</Customer identity>.

  GET  /health                     {status: ok, proxy: skeid, config_reload: {...}}
  GET  /.well-known/langertha.json provider manifest for the presented key
  GET  /v1/models                  OpenAI: node models and alias names, once each
  POST /v1/chat/completions        OpenAI chat; a stream is relayed byte for byte
  POST /v1/embeddings              OpenAI embeddings
  POST /v1/audio/transcriptions    OpenAI audio: multipart upload, relayed as the node answers
  POST /v1/audio/translations      the same, to the node's translations endpoint
  POST /v1/rerank                  rerank: relayed as the node answers, translated for a TEI node
  POST /rerank                     the same route under its other name
  POST /v1/messages                Anthropic Messages, streamed or not
  POST /api/chat                   Ollama chat; streams unless "stream": false
  POST /api/generate               Ollama generate; streams unless "stream": false
  GET  /api/tags                   Ollama: the same names as /v1/models
  GET  /api/ps                     Ollama: always an empty list

C</health> stays C<ok> while a config reload is failing -- the proxy serves under the config it
kept -- and shows the reload state without its message. C</v1/models> and C</api/tags> list the
node models and the alias names, each once, so a client can discover what it may put in
C<model>. The list follows the policy of the key presented (no key: the default policy): a name
the key's C<models> do not grant, an alias with every tier denied and a model only denied nodes
serve are left out. Unhealthy nodes are included. A node without a C<model> is not listed -- it matches any
requested name, so no name reaches it in particular. The manifest route answers C<404> unless
the config enables it, C<401> without a key and C<403> for a key without a grant; see
L<Langertha::Skeid/Provider Manifest>.

=head2 Audio routes

C</v1/audio/transcriptions> and C</v1/audio/translations> take OpenAI's C<multipart/form-data>
upload -- C<file>, C<model> and whatever else the client sends -- and relay it to
C<{node url}/audio/transcriptions> or C</audio/translations>, the endpoint vLLM (Whisper) and
speaches both serve. Nothing is translated in either direction (ADR 0021): there is one dialect
for the request, and the answer is the node's own. What Skeid knows of that wire is in
L<Langertha::Skeid::Protocol::Audio>.

The request is routed like a chat request -- by the form's C<model> field, through aliases,
tiers, the key's policy, eligibility and admission -- and the form goes upstream part for part:
each part with its own headers and content, in the client's order, under the client's boundary.
Fields Skeid does not know and fields that repeat (C<timestamp_granularities[]>) pass through.
One part is rewritten: C<model>, when an alias tier serves another model than the one asked
for. The upload itself is never copied: the server spools a part above 256 KiB to a temporary
file, and the upstream request is sent from that file. The client's C<Expect> header is not
passed on.

Skeid reads two fields. C<model> has to be there exactly once, as a non-empty value of at most
1024 bytes; anything else is a C<400> before a node is touched -- with two, Skeid would route by
one while the node may serve the other. C<stream> picks the relay: the last one in the form
decides, and it is on for C<true>, C<1>, C<on>, C<yes>, C<t> and C<y> in any case, which is what
the nodes read as true. A part's name is taken from its C<Content-Disposition> however it is
written (quoted or bare, any case); a name in the extended C<name*> notation is refused.

The answer comes back as the node gave it -- its status, its headers but for the framing ones,
its body untouched: JSON, C<verbose_json>, plain C<text>, C<srt>, C<vtt>. A stream is relayed byte for byte like a chat stream, in whichever
event dialect the node speaks -- OpenAI's and speaches' C<transcript.text.delta> /
C<transcript.text.done>, or vLLM's C<transcription.chunk> frames ending in C<[DONE]> -- and
nothing is added to the form to make the node report usage: a vLLM node sends its usage frame
when the client's form carries C<stream_include_usage=true>.

The usage event has C<api_format> C<openai> and the route as its C<endpoint>. Tokens are
recorded when the node reports them (OpenAI's C<usage.type: tokens>, vLLM's stream usage
frame); C<audio_seconds> when it reports a duration -- C<usage.seconds> of a C<usage.type:
duration> block, else the top-level C<duration> of a C<verbose_json> answer; a streamed request
also has C<content_bytes>, the UTF-8 bytes of the text relayed. A node that reports neither
count leaves an event with a status and a duration and no C<audio_seconds> key: not measured,
which is not zero. See L<Langertha::Skeid/Pluggable Usage Storage>.

=head2 Rerank route

C</v1/rerank> and C</rerank> are one route. It takes the request shape Cohere set and vLLM, Jina
and infinity took over -- C<model>, C<query>, C<documents>, optionally C<top_n>,
C<return_documents> and whatever else the node understands -- and answers with the node's
C<results>. It is not a streamed route.

Four things are checked before a node is picked, each a C<400> that costs no slot and no usage
event: the body is a JSON object, C<model> is a non-empty string, C<query> is a string,
C<documents> is a non-empty array. What a document may be is left to the node. The request is
then routed like a chat request -- by C<model>, through aliases, tiers, the key's policy,
eligibility and admission.

By default the request is B<relayed> (ADR 0021): it goes to C<{node url}/rerank> with every
field as the client sent it and C<model> replaced by the served model, and the node's answer
comes back as it is -- status, headers but for the framing ones, body byte for byte. That
covers vLLM, infinity started with C<--url-prefix /v1>, Jina and Cohere, and Skeid does not
even out what differs between them: C<document> is C<{ "text": ... }> on vLLM and Cohere and a
plain string on infinity, and vLLM returns the documents whether C<return_documents> asked for
them or not. The body is decoded and written again on the way, so the node sees exactly one
C<model> -- the one Skeid routed by.

A node with C<rerank_format: tei> (L<Langertha::Skeid/nodes>) is Hugging Face
text-embeddings-inference, which speaks another dialect, and is B<translated> in both
directions. The request goes to C</rerank> at the server root -- the node's URL with or without
a trailing C</v1> -- as C<query>, C<texts> (each document a string, or an object's string
C<text>), C<return_text> for C<return_documents> and C<truncate> when the client sent them, and
nothing else. TEI's bare array becomes C<< { model, results, usage } >>: C<model> the served
model, C<results> sorted by score with C<relevance_score> and, when C<return_documents> asked
for it, C<< document => { text } >>, cut to C<top_n>; C<usage.total_tokens> from TEI's
C<x-compute-tokens> header when it sent one. A request such a node cannot take -- a document
that is not text, a C<top_n> that is not a whole number of at least zero -- is a C<400> as
well, but one known only after the node was admitted: the slot is given back, and one failed
usage event is written. An answer that is not TEI's array is a C<500> C<api_error>, as for
any translation that fails. The wire of both dialects is L<Langertha::Skeid::Protocol::Rerank>'s.

The usage event has C<api_format> C<openai> and C<endpoint> C</v1/rerank> for both spellings.
C<documents> is the number of documents the request carried, on the event of a request the
node answered and on no other. The node's tokens are recorded as B<input> tokens and as the
total, so the model's C<input_per_million> prices them, from wherever that node reports them:
C<usage.prompt_tokens>, else C<usage.total_tokens>, else Cohere's C<meta.tokens.input_tokens>,
or a TEI node's C<x-compute-tokens>. A node that reports none leaves an event without tokens.
infinity counts characters unless it runs with C<lengths_via_tokenize>; Skeid records what the
node says. See L<Langertha::Skeid/Pluggable Usage Storage>.

=head2 Uploads

The audio routes are the upload routes: their request limit is the config's
C<uploads.max_bytes> (L<Langertha::Skeid/uploads>, default 26214400), not the server's own
(Mojolicious' 16 MiB, which every other route keeps). A larger body is answered C<413> in the
OpenAI error shape, with no node touched and no usage event.

The limit is applied when the request's head has arrived, before its body is read. A request
that declares a larger C<Content-Length> is answered at once and its connection closed; a body
of undeclared length (chunked) is cut off once it is 1 MiB past the limit, and measured exactly
if it ends before that. With C<client_auth>, a caller the list does not let in is cut off the
same way -- its C<401> does not wait for, or store, the upload. The limit is read per request,
so a changed C<uploads.max_bytes> holds from the next one.

A client that sends C<Expect: 100-continue> (curl does, above 1 MiB) gets no C<100 Continue>:
the server underneath does not send one. It gets a C<401> or C<413> right away, and otherwise
sends the body after its own timeout.

=head2 Registry route

  GET  /skeid/registry/snapshot    signed capacity snapshot, for a fronting Skeid

Bearer token: the admin API key or the registry read key (C<registry.read_key_env>), and nothing
else accepts the read key. C<404> when neither is configured or the registry is not enabled,
C<401> for a wrong token, C<503> while the signing secret is missing. The body is signed in C<X-Skeid-Registry-Signature> and sent
C<Cache-Control: no-store>. See L<Langertha::Skeid/registry_enabled> and ADR 0017.

=head2 Admin routes

Bearer token: the admin API key (L<Langertha::Skeid/admin>). Without one configured every
C</skeid/*> route answers C<404>; a missing or wrong token answers C<401>.

  GET  /skeid/nodes                {nodes}
  POST /skeid/nodes                body: a node, as a config nodes entry -> {ok, nodes}, or 400
  POST /skeid/nodes/:id/health     body: {"healthy": true|false} -> {ok}
  GET  /skeid/config               {reload}: the config reload status, with its message
  GET  /skeid/metrics/nodes        {metrics}: per-node counters, never billed
  GET  /skeid/usage                ?since=&api_key_id=&model=&limit= (default 50) -> the report

Changes made here live in this process only: a changed C<nodes> section in the config replaces
them, and under C<--workers> each write reaches one worker (ADR 0010).

=head2 Customer identity

Skeid does not authenticate customers unless the config has a C<client_auth> section
(L<Langertha::Skeid/client_auth>). The key a client presents (C<Authorization: Bearer>, else
C<x-api-key>) derives the customer key id (L<Langertha::Skeid/key_id_for_key>; no key is
C<anonymous>), which selects the routing policy and is recorded on the usage event. With
C<routing.trust_key_id_header> a C<x-skeid-key-id> (or C<x-api-key-id>) header names the key id
instead.

With C<client_auth>, that key id has to be on the section's list. Every client route checks it
first -- C</v1/models>, C</v1/chat/completions>, C</v1/embeddings>, the C</v1/audio/*> routes,
C</v1/rerank> and C</rerank>, C</v1/messages>, every C</api/*> route and C</.well-known/langertha.json> -- after picking up a
changed config
(L<Langertha::Skeid/maybe_reload_config>), so a list change holds from the next request.
No key is C<401> C<Missing API key>, a key whose id is not listed C<401> C<Invalid API key>,
both with C<WWW-Authenticate: Bearer realm="skeid">, and nothing else happens for that request:
the body is not parsed, no node is admitted or called, no usage event is written, and Skeid logs
nothing about it. The answer names neither the key nor its id. C</health> and the C</skeid/*> routes are not checked;
they have their own rules. Being let in widens nothing: the key's routing policy still applies.

=head2 The upstream call

The node URL gets C</v1> added unless it ends in it, then C</chat/completions> or
C</embeddings> (an audio route: C</audio/transcriptions> or C</audio/translations>, see
L</Audio routes>; rerank: C</rerank>, for a TEI node without the C</v1>, see L</Rerank route>);
the body carries the served model (an alias tier's C<model>), everything else
as the client sent it or as translated. The client's headers go upstream except the hop-by-hop
ones, C<Host>, C<Content-Length> and C<Accept-Encoding>. When the node has a key of its own --
C<api_key_ref> through the key broker, else C<api_key_env> -- it replaces C<Authorization> and
the client's C<Authorization> and C<x-api-key> are dropped, however the client spelled them. A
node that names neither forwards the client's own key. A node that names one and gets no key
from it -- the broker fails or is not running, the variable is unset or empty -- is not called
at all, and neither is one that left the inventory after it was selected: the request is
refused with C<503> (see L</Errors>), so the client's key never stands in for the node's. An answer that came from a node carries
C<x-skeid-node> with the node id. Rate-limit headers and C<429>s on every response feed
L<Langertha::Skeid/observe_response_headers>.

Each admitted request gets its C<request.finish> on every path and one usage event, failures
included.

=head2 A client that hangs up

A client that closes its connection before the answer is complete ends its request at that
moment. While it waits for capacity it stops waiting and takes no slot. Once a node was called,
the upstream connection is closed -- which is how the node learns to stop generating -- and is
not returned to the pool; the slot is given back with a C<request.finish> marked C<aborted> -- counted apart, not as a node
error, so the node's error counter and the registry snapshot's C<errors_in_window> stay untouched --
and the one usage event is written with C<ok = 0>, C<status_code> 499 and C<error_type>
C<client_abort>, priced from the usage the stream had reported until then (nothing, for a
request that was not streamed). A client that leaves while the node's key is still being
resolved gives its slot back too, but nothing was forwarded, so no usage event is written.
When the node had already finished and only the rest of the answer was still being written
out, the request stays what it was: finished and metered by the node's answer.

=head2 Errors

A key the C<client_auth> list does not let in is C<401> (OpenAI: type C<invalid_request_error>,
code C<invalid_api_key>; Anthropic: C<authentication_error>; see L</Customer identity>). An
upload over C<uploads.max_bytes> is C<413 invalid_request_error>; an audio request that is not a
multipart form, or whose form has no usable C<model> field, is C<400 invalid_request_error>, as
is a rerank request without a C<model>, a string C<query> or C<documents>. A
request no node may serve for this key is C<403 permission_error>; a model no healthy node
serves is C<503 model_not_found>; eligible nodes that stay full past the wait are
C<429 rate_limit_error>; an upstream failure is its status (or C<502>) with type
C<upstream_error>; a node whose own key cannot be resolved is
C<503 upstream_key_unavailable>, logged with the key reference and recorded as a failed usage
event. The body is shaped for the face that was called: OpenAI's
C<{error: {message, type}}>, Anthropic's envelope
(L<Langertha::Skeid::Protocol::Anthropic/error_body>) on C</v1/messages>, and Ollama's
C<{error: "..."}> on C</api/*>. A stream that fails after it opened ends with the face's in-band
error event where it has one.

=head1 METHODS

=method build_app

  my $app = Langertha::Skeid::Proxy->build_app(%options);

Builds the L<Mojolicious> application. Options:

=over 4

=item * C<config_file> -- the config to build a L<Langertha::Skeid> from.

=item * C<skeid> -- an existing L<Langertha::Skeid> to serve instead; C<config_file> and the
OpenBao detection below are then not used.

=item * C<admin_api_key> -- the explicit admin API key (L<Langertha::Skeid/set_admin_api_key>):
it wins over the config's, on every reload. Empty leaves the key to the config and
C<SKEID_ADMIN_API_KEY>.

=item * C<worker_count> -- how many prefork workers share the nodes (L<Langertha::Skeid/worker_count>),
set before any admission or probe timer reads it.

=back

The Skeid's L<Langertha::Skeid/on_usage_lost> is set to this app's C<usage event lost> log line,
so a usage event a write-behind store could not write is logged like one whose synchronous write
failed. An embedding application that wants its own hook sets it after C<build_app>.

With both C<OPENBAO_ROLE_ID> and C<OPENBAO_SECRET_ID> set, a
L<Langertha::Skeid::KeyBroker::OpenBao> at C<OPENBAO_ADDR> (default C<http://127.0.0.1:8200>)
becomes the key broker; if its login fails the proxy warns and runs without one. A broker that
can renew its token starts renewing on a timer. The capacity probes of every node are started
and restarted whenever the probed part of the inventory changes.

Upstream connections time out after 10s to connect, and at most C<SKEID_UPSTREAM_POOL>
(default 100) are kept. An upstream request may take C<SKEID_UPSTREAM_TIMEOUT> seconds (default
300; a positive integer, anything else counts as unset) and may be silent for all of them --
the time to the first token is silence on the wire. The client's connection is given the same
time on top of the server's own inactivity timeout, on the routes that call an upstream and for
that request only: the proxy never closes a request its upstream is still working on, and is
still there to answer when the upstream timed out. Every other route stays under the server's
timeout. The client's side is read from the user agent when a request arrives, so whoever
changes C<< $app->ua->request_timeout >> afterwards changes both sides, and should set
C<< $app->ua->inactivity_timeout >> to match.

The app has a C<skeid> helper returning the control plane.

=cut

# What the request limit of an upload route allows on top of uploads.max_bytes (skeid k91): the
# request's head, which the server counts into its message size and caps well below this itself
# (100 lines of 8 KiB). The body alone is checked exactly when the route runs.
my $UPLOAD_HEAD_ALLOWANCE = 1048576;

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

  # The explicit admin API key goes into new(), so it is in force for the first config already
  # (a registry block checks for it); an existing Skeid gets it set (skeid k64).
  push @skeid_opts, admin_api_key => $opts{admin_api_key}
    if defined($opts{admin_api_key}) && length($opts{admin_api_key});
  my $skeid = $opts{skeid} || Langertha::Skeid->new(@skeid_opts);
  $skeid->set_admin_api_key($opts{admin_api_key}) if exists $opts{admin_api_key};
  # How many processes share these nodes. Set before anything reads max_conns or starts a
  # timer, since both are divided by it (ADR 0010).
  if (defined $opts{worker_count} && $opts{worker_count} > 0) {
    $skeid->worker_count(0 + $opts{worker_count});
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
  my $probe_key = $skeid->_probe_inventory_key;

  my $app = Mojolicious->new;
  $app->secrets(['skeid-proxy']);

  # A write-behind usage store (usage_store.flush_interval_ms) writes after the request was
  # answered, so its failures cannot come back through _record_usage_event; they come here and
  # get the same log line (skeid k78). Weak: the app holds the skeid, the skeid holds this.
  weaken(my $weak_app = $app);
  $skeid->on_usage_lost(sub {
    my ($skeid, $event, $err) = @_;
    return _log_lost_usage_event($weak_app, $skeid, $event, $err) if $weak_app;
    warn 'skeid: usage event lost: request_id=' . ($event->{request_id} // '') . ': '
      . ($err // 'unknown error') . "\n";
    return;
  });
  $app->ua->connect_timeout(10);
  # One number for how long an upstream may take and how long it may be silent: a model that
  # thinks sends nothing until its first token, and Mojo::UserAgent closes a connection that
  # was silent for 40s whatever the request timeout allows. The client's side follows the same
  # number per request, see _extend_client_timeout.
  my $upstream_timeout
    = (defined($ENV{SKEID_UPSTREAM_TIMEOUT}) && $ENV{SKEID_UPSTREAM_TIMEOUT} =~ /^\d+$/
      && $ENV{SKEID_UPSTREAM_TIMEOUT} > 0)
    ? 0 + $ENV{SKEID_UPSTREAM_TIMEOUT}
    : 300;
  $app->ua->request_timeout($upstream_timeout);
  $app->ua->inactivity_timeout($upstream_timeout);
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
  # polling for nodes that are gone and never start for new ones. They follow the probe key,
  # not the inventory generation: a health flip moves the generation but not what a probe
  # polls, and a restart makes every probe forget its own reading (skeid #40) -- readings from
  # other sources, such as a rate-limit backoff, survive it. The key is recomputed only when the
  # generation has moved, so an unchanged inventory costs an integer compare per request.
  $app->hook(before_dispatch => sub {
    my $key = $skeid->_probe_inventory_key;
    return if $key eq $probe_key;
    $probe_key = $key;
    $_->stop for values %$probes;
    $probes = Langertha::Skeid::CapacityProbe->start_for_skeid($skeid);
  });

  # The request's id is fixed here, before anything can fail or hang up: the client gets it back
  # as x-request-id whatever the answer turns out to be, and the usage event and the lost-event
  # log line carry the same one. It lives in the stash because a request whose client is gone
  # has no transaction to read it from any more.
  $app->hook(before_dispatch => sub {
    my ($c) = @_;
    my $id = _request_id($c);
    $c->stash('skeid.request_id' => $id);
    $c->res->headers->header('x-request-id' => $id);
  });

  # The upload routes get their own request limit (uploads.max_bytes, skeid k91), set the moment
  # the request's head is parsed and before any of its body is: see _limit_upload. The
  # transaction is held weakly -- the listener sits on its own request content, and a connection
  # that closes before the head is complete would otherwise keep both alive.
  $app->hook(after_build_tx => sub {
    my ($tx, $app) = @_;
    weaken $tx;
    $tx->req->content->once(body => sub { _limit_upload($app, $tx) if $tx });
  });

  my $r = $app->routes;

  # Still 'ok' while a config reload is failing: the proxy serves under the config it kept, so
  # it is not unhealthy, and a probe that restarted it would lose that config. The reload
  # state is shown without its message, which can name customers; that is on /skeid/config.
  $r->get('/health' => sub {
    my ($c) = @_;
    my $reload = $c->skeid->reload_status;
    delete $reload->{error};
    $c->render(json => { status => 'ok', proxy => 'skeid', config_reload => $reload });
  });

  # Client routes sit behind _authorize_client (skeid k90): a bridge, so only these routes are
  # gated and an unknown path stays a 404. Each face's bridge sets what its 401 needs before the
  # gate can render it -- the error dialect, the manifest's cache headers.

  # Provider manifest (skeid #29, ADR 0015): per customer key, never the whole catalog.
  my $manifest = $r->under(sub {
    my ($c) = @_;
    _manifest_cache_headers($c);
    return _authorize_client($c);
  });

  $manifest->get('/.well-known/langertha.json' => sub {
    my ($c) = @_;
    _handle_manifest($c);
  });

  # OpenAI format
  my $openai = $r->under(sub {
    my ($c) = @_;
    return _authorize_client($c);
  });

  $openai->get('/v1/models' => sub {
    my ($c) = @_;
    my @data = map {
      +{
        id       => $_->{model},
        object   => 'model',
        created  => int(time),
        owned_by => 'skeid',
      }
    } @{$c->skeid->list_models(api_key_id => _request_api_key_id($c))};
    $c->render(json => { object => 'list', data => \@data });
  });

  $openai->post('/v1/chat/completions' => sub {
    my ($c) = @_;
    _handle_openai_chat($c);
  });

  $openai->post('/v1/embeddings' => sub {
    my ($c) = @_;
    _handle_openai_embeddings($c);
  });

  # Audio (skeid k91): relayed in the upstream's own shape, not translated (ADR 0021).
  for my $endpoint (Langertha::Skeid::Protocol::Audio->routes) {
    $openai->post($endpoint => sub {
      my ($c) = @_;
      _handle_openai_audio($c, $endpoint);
    });
  }

  # Rerank (skeid k92): /v1/rerank and its alias /rerank, one route. Relayed like audio, except
  # to a node whose rerank_format names another upstream dialect.
  for my $endpoint (Langertha::Skeid::Protocol::Rerank->routes) {
    $openai->post($endpoint => sub {
      my ($c) = @_;
      _handle_openai_rerank($c);
    });
  }

  # Anthropic format. Every error this request produces, wherever it is rendered -- the gate's
  # 401 included -- has to be Anthropic-shaped (core karr #224). _render_error reads this.
  my $anthropic = $r->under(sub {
    my ($c) = @_;
    $c->stash('skeid.error_format' => 'anthropic');
    return _authorize_client($c);
  });

  $anthropic->post('/v1/messages' => sub {
    my ($c) = @_;
    _handle_anthropic_messages($c);
  });

  # Ollama format. Every error on these routes has to be Ollama-shaped, {"error": "<string>"}:
  # an Ollama client decodes the error as a string and fails on the OpenAI object (skeid #47).
  # _render_error reads this.
  my $ollama = $r->under('/api' => sub {
    my ($c) = @_;
    $c->stash('skeid.error_format' => 'ollama');
    return _authorize_client($c);
  });

  $ollama->post('/chat' => sub {
    my ($c) = @_;
    _handle_ollama($c, 'chat');
  });

  $ollama->post('/generate' => sub {
    my ($c) = @_;
    _handle_ollama($c, 'generate');
  });

  $ollama->get('/tags' => sub {
    my ($c) = @_;
    $c->render(json => Langertha::Skeid::Protocol::Ollama->tags_from_models(
      $c->skeid->list_models(api_key_id => _request_api_key_id($c))));
  });

  $ollama->get('/ps' => sub {
    my ($c) = @_;
    $c->render(json => { models => [] });
  });

  # Skeid-to-Skeid registry (skeid #18, ADR 0017): a fronting tier's CapacityProbe::Registry
  # pulls this. 404 unless registry.enabled, and never unsigned. No store may keep it: a cached
  # snapshot is a stale one. It is registered before the /skeid admin block so it is not behind
  # _authorize_admin: it also takes the registry read key (skeid #49), which that block must
  # never accept -- the read key opens this one route and nothing else.
  $r->get('/skeid/registry/snapshot' => sub {
    my ($c) = @_;
    return unless _authorize_registry_read($c);
    my $skeid = $c->skeid;
    $c->res->headers->header('Cache-Control' => 'no-store');
    unless ($skeid->registry_enabled) {
      $c->render(status => 404,
        json => { error => { message => 'No registry snapshot is published here', type => 'not_found' } });
      return;
    }
    my ($body, $signature) = eval { Langertha::Skeid::Registry->signed_snapshot($skeid) };
    unless (defined $body) {
      my $err = $@ || 'unknown error';
      unless (length($skeid->registry_secret // '')) {
        $c->render(status => 503,
          json => { error => { message => 'Registry secret is not set', type => 'unavailable' } });
        return;
      }
      # Anything else is a bug in building the snapshot. The operator gets the cause in the
      # log; the caller gets nothing that could describe this process's internals.
      $err =~ s/\s+\z//;
      $c->app->log->error("registry snapshot failed: $err");
      $c->render(status => 500,
        json => { error => { message => 'Registry snapshot could not be built', type => 'server_error' } });
      return;
    }
    $c->res->headers->header(Langertha::Skeid::Registry->SIGNATURE_HEADER => $signature);
    $c->render(data => $body, format => 'json');
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

  $admin->get('/config' => sub {
    my ($c) = @_;
    $c->render(json => { reload => $c->skeid->call_function('config.status', {}) });
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
  my $ok = defined($scheme) && lc($scheme) eq 'bearer' && defined($token)
    && Langertha::Skeid::Secret->equal($token, $admin_api_key);
  if (!$ok) {
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

# The snapshot route's gate: the admin API key (compat) or the registry read key, each compared
# in constant time. 404 when neither is configured, like every closed /skeid route; 401 with the
# admin route's challenge otherwise.
sub _authorize_registry_read {
  my ($c) = @_;
  my $skeid = $c->skeid;
  $skeid->maybe_reload_config;

  my @accepted = grep { length } ($skeid->admin_api_key // '', $skeid->registry_read_key // '');
  unless (@accepted) {
    $c->render(status => 404, text => 'Not Found');
    return undef;
  }

  my $auth = $c->req->headers->authorization // '';
  my ($scheme, $token) = $auth =~ /\A(\S+)\s+(.+)\z/;
  my $ok = 0;
  if (defined($scheme) && lc($scheme) eq 'bearer' && defined($token)) {
    # No short-circuit: both candidates are compared whichever one matches.
    $ok |= Langertha::Skeid::Secret->equal($token, $_) for @accepted;
  }
  return 1 if $ok;

  $c->res->headers->header('WWW-Authenticate' => 'Bearer realm="skeid-admin"');
  $c->render(
    status => 401,
    json   => {
      error => {
        type    => 'unauthorized',
        message => 'Missing or invalid registry bearer token',
      },
    },
  );
  return undef;
}

# The client routes' gate (skeid k90), run by their bridges before anything else of the request:
# before the body is parsed, a node is admitted (request.start), a key resolved, an upstream
# called or a usage event written -- a refused request has nothing to give back. It reloads the
# config first, so switching client authentication on or off or rotating an id holds from the
# next request on every client route, a GET included. That is what the reload throttle
# (config_reload_interval) and the no-op on an unchanged config are for: an anonymous GET does
# not rerun the loader, nor restart the node probes, per request. Off without client_auth.
# The identity is the one routing uses, so with routing.trust_key_id_header the header's id is
# what must be on the list. A refusal is not logged -- the routes are public, and a line per
# rejected request would be anybody's to flood -- and its body names neither the key nor its id.
sub _authorize_client {
  my ($c) = @_;
  my $skeid = $c->skeid;
  $skeid->maybe_reload_config;
  return 1 unless $skeid->client_auth_enabled;

  my $api_key_id = _request_api_key_id($c);
  return 1 if $skeid->client_key_allowed($api_key_id);

  my $missing = !defined($api_key_id) || $api_key_id eq 'anonymous';
  $c->res->headers->header('WWW-Authenticate' => 'Bearer realm="skeid"');
  _render_error($c, 401, ($missing ? 'Missing API key' : 'Invalid API key'),
    'invalid_request_error', 'invalid_api_key');
  return undef;
}

# What a key is shown depends on who presents it, so no cache may hand one key's answer to
# another: every answer -- the client gate's 401 included -- is private, not stored, and varies on
# each header that can carry the identity. Set by the route's bridge, before the gate.
sub _manifest_cache_headers {
  my ($c) = @_;
  my $headers = $c->res->headers;
  $headers->header('Cache-Control' => 'private, no-store');
  $headers->header(Vary => 'Authorization, X-Api-Key, X-Skeid-Key-Id, X-Api-Key-Id');
  return;
}

# The config is reloaded by the client gate before this runs (see _authorize_client), throttled
# by config_reload_interval and a no-op when nothing changed. 404 when nothing is published
# (disabled, or a Langertha without Langertha::Manifest), 401 without a key (ADR 0015: no
# anonymous manifest, not even a minimal one), 403 for a key without a manifest: grant, else the
# manifest built for that key id.
sub _handle_manifest {
  my ($c) = @_;
  my $skeid = $c->skeid;

  my $headers = $c->res->headers;

  unless ($skeid->manifest_enabled && $skeid->manifest_available) {
    $c->render(status => 404,
      json => { error => { message => 'No provider manifest is published here', type => 'not_found' } });
    return;
  }

  my $api_key_id = _request_api_key_id($c);
  if (!defined($api_key_id) || $api_key_id eq 'anonymous') {
    $headers->header('WWW-Authenticate' => 'Bearer realm="skeid"');
    $c->render(status => 401,
      json => { error => { message => 'An API key is required for the provider manifest', type => 'unauthorized' } });
    return;
  }

  my $json = $skeid->manifest_for_key($api_key_id);
  unless (defined $json) {
    $c->render(status => 403,
      json => { error => { message => 'No provider manifest is published for this key', type => 'permission_error' } });
    return;
  }

  $c->render(data => $json, format => 'json');
  return;
}

# The client's connection is silent while the upstream works, and the server closes a connection
# that was silent for its inactivity timeout (30s unless the server was told otherwise). So a
# request that calls an upstream gets, on top of that, what the upstream may take: the client
# outlasts the upstream and is still there for the answer, or for the error. Read from the user
# agent rather than kept beside it, so the two sides cannot drift apart. It holds for this
# request only: the server sets its own timeout again for the next one on the connection. A
# timeout of 0 is none, on either side, and stays none.
sub _extend_client_timeout {
  my ($c) = @_;
  my $stream = Mojo::IOLoop->stream($c->tx->connection // '') or return;
  my $own = $stream->timeout;
  my $upstream = $c->app->ua->request_timeout;
  $stream->timeout(($own && $upstream) ? $own + $upstream : 0);
  return;
}

sub _handle_openai_chat {
  my ($c) = @_;
  _extend_client_timeout($c);
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
  _extend_client_timeout($c);
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

# Runs once per request, when its head is parsed and its body is still on the wire (the request
# content's `body` event). An upload route gets its own limit there, because afterwards is too
# late for either thing it is for (skeid k91):
#
# - uploads.max_bytes replaces the server's request limit, which is 16 MiB and so below the
#   default upload limit. A request that declares a larger body is cut off at once: the limit is
#   set below what was already read, the parser stops, and the route answers 413 without the body
#   having been received. A body of undeclared length (chunked) is cut off when it passes the
#   limit plus the head allowance, so it is never buffered whole either.
# - A caller the client gate is going to refuse is cut off the same way, so its 401 does not
#   cost an upload spooled to disk first. The gate itself still runs and renders the 401.
#
# The limit is read off the Skeid here, after picking up a changed config, so a reload holds
# from the next upload. Every other route keeps the server's own limit: nothing is set for it.
# A failure here leaves the server's limit in force and the route's own checks to decide.
sub _limit_upload {
  my ($app, $tx) = @_;
  my $req = $tx->req;
  return unless uc($req->method // '') eq 'POST';
  (my $path = $req->url->path->to_route) =~ s{/\z}{};
  return unless Langertha::Skeid::Protocol::Audio->upstream_path($path);

  my $done = eval {
    my $c = $app->build_controller($tx);
    my $skeid = $c->skeid;
    $skeid->maybe_reload_config;

    if ($skeid->client_auth_enabled && !$skeid->client_key_allowed(_request_api_key_id($c))) {
      $req->max_message_size(1);
      return 1;
    }

    my $max = $skeid->upload_max_bytes;
    my $declared = $req->headers->content_length;
    if (!$req->content->is_chunked && defined($declared) && $declared =~ /\A[0-9]+\z/ && $declared > $max) {
      $req->max_message_size(1);
      return 1;
    }
    $req->max_message_size($max + $UPLOAD_HEAD_ALLOWANCE);
    1;
  };
  $app->log->error('Setting the upload limit failed: ' . ($@ || 'unknown error')) unless $done;
  return;
}

# POST /v1/audio/transcriptions and /v1/audio/translations (skeid k91). The request is a
# multipart form and the answer is whatever the node's transcription endpoint says -- JSON, plain
# text, subtitles or an event stream. Neither is translated (ADR 0021): the form goes upstream
# part for part as the client sent it, the answer comes back byte for byte. Skeid reads two
# fields of the form, `model` to route by and `stream` to pick the relay, and writes one, `model`
# again, when an alias tier serves another model than the one asked for (ADR 0008). What the
# form and the answers look like on the wire is Langertha::Skeid::Protocol::Audio's to know.
sub _handle_openai_audio {
  my ($c, $endpoint) = @_;
  my $audio = 'Langertha::Skeid::Protocol::Audio';
  _extend_client_timeout($c);
  my $req = $c->req;

  # Before anything is read off the body: a request cut off by _limit_upload has no complete
  # form. The body size is checked again, exactly, for what the limit set there lets through.
  my $max = $c->skeid->upload_max_bytes;
  if ($req->is_limit_exceeded || ($req->body_size // 0) > $max) {
    _render_error($c, 413, "Maximum content size limit ($max bytes) exceeded", 'invalid_request_error');
    return;
  }

  my $content = $req->content;
  unless ($content->is_multipart) {
    _render_error($c, 400, 'Expected a multipart/form-data body', 'invalid_request_error');
    return;
  }

  # One `model` field, no more: with two, Skeid would route -- and apply the key's policy -- by
  # one while the node may well serve the other.
  my ($field, $problem) = $audio->form_fields($content);
  my @models = @{$field->{model} || []};
  my $model = @models == 1 ? $models[0]{value} : undef;
  $model = decode('UTF-8', $model) // $model if defined $model;
  $problem //= !@models                           ? "The 'model' form field is required"
             : @models > 1                        ? "The 'model' form field may be given only once"
             : !(defined($model) && length($model)) ? "The 'model' form field is empty or too long"
             :                                      undef;
  if (defined $problem) {
    _render_error($c, 400, $problem, 'invalid_request_error');
    return;
  }

  # The last `stream` field decides, as it does for the node that parses the same form.
  my $streamed = @{$field->{stream} || []} ? $audio->is_true($field->{stream}[-1]{value}) : 0;

  my $api_key_id = _request_api_key_id($c);
  _begin_route_async($c, $model, $api_key_id, sub {
    my ($route, $node_id, $started, $tier) = @_;
    return unless $route;

    # Requested and served model are two strings once an alias is in play (ADR 0008): the form
    # that goes upstream carries the served one, the usage event carries both.
    my $served_model = _served_model($tier, $model);
    my %replace = $served_model eq $model ? () : ($models[0]{index} => encode('UTF-8', $served_model));

    my $url = _endpoint_url_for_node($route->{url}, $audio->upstream_path($endpoint));
    my $meta = {
      api_format => 'openai',
      endpoint   => $endpoint,
      api_key_id => $api_key_id,
      provider   => 'skeid',
      engine     => ($route->{engine} // 'openaibase'),
      model            => $served_model,
      requested_model  => $model,
      route_url        => ($route->{url} // ''),
    };
    my $relay = {
      # The upstream form is built from the parts the server already parsed: a part is its
      # headers and an asset, and an upload above 256 KiB is an asset on disk, so the file is
      # streamed from there and never copied into memory. The client's Content-Type travels in
      # the forwarded headers and its boundary is the one the body is written with.
      #
      # The client's `Expect: 100-continue` (curl sends one with every upload above 1 MiB) is
      # not forwarded: the body is in hand, so nothing is expected of the node any more, and a
      # node that answered the header with its `100 Continue` would have the user agent start
      # a fresh response object -- one the stream relay is not listening on.
      request => sub {
        my ($ua, $url, $headers) = @_;
        delete @{$headers}{ grep { lc($_) eq 'expect' } keys %$headers };
        return $ua->build_tx(POST => $url, $headers,
          multipart => $audio->upstream_parts($content, \%replace));
      },
      units      => sub { $audio->usage_units(@_) },
      delta_text => sub { $audio->delta_text(@_) },
    };
    my $body = { model => $served_model };

    if ($streamed) {
      _proxy_openai_stream($c, $url, $body, $node_id, $started, $meta, undef, $relay);
      return;
    }

    $c->render_later;
    _proxy_openai_json_async($c, $url, $body, $node_id, $started, $meta, sub {
      my ($res, $err, $status) = @_;
      return if $err;
      _render_upstream_response($c, $res, $node_id);
    }, undef, $relay);
  });
}

# POST /v1/rerank and POST /rerank (skeid k92). A JSON body in the shape Cohere, vLLM, Jina and
# infinity share, routed by its `model` like a chat request. To a node that speaks that shape
# the body is relayed with only `model` replaced, and the answer comes back byte for byte (ADR
# 0021). A node marked `rerank_format` speaks another dialect and is translated in both
# directions -- on the upstream side, the one place Skeid does that. Either way the wire's names
# are Langertha::Skeid::Protocol::Rerank's to know.
sub _handle_openai_rerank {
  my ($c) = @_;
  my $rerank = 'Langertha::Skeid::Protocol::Rerank';
  _extend_client_timeout($c);
  my $body = $c->req->json;
  if (defined(my $problem = $rerank->request_problem($body))) {
    _render_error($c, 400, $problem, 'invalid_request_error');
    return;
  }

  my $model = $body->{model};
  my $documents = $rerank->document_count($body);
  my $api_key_id = _request_api_key_id($c);
  _begin_route_async($c, $model, $api_key_id, sub {
    my ($route, $node_id, $started, $tier) = @_;
    return unless $route;

    # Requested and served model are two strings once an alias is in play (ADR 0008): the body
    # that goes upstream carries the served one, the usage event carries both.
    my $served_model = _served_model($tier, $model);
    my $format = $route->{rerank_format} // '';
    my $meta = {
      api_format => 'openai',
      endpoint   => $rerank->endpoint,
      api_key_id => $api_key_id,
      provider   => 'skeid',
      engine     => ($route->{engine} // 'openaibase'),
      model            => $served_model,
      requested_model  => $model,
      route_url        => ($route->{url} // ''),
    };

    # Which dialect the request has to be put in is known only now, with the node. A request
    # this node's dialect cannot carry -- a document that is not text, for a node that takes
    # texts -- is the client's to fix, but it holds a slot already.
    my $upstream_body = eval { $rerank->request_to_upstream($body, $served_model, $format) };
    unless (ref($upstream_body) eq 'HASH') {
      my $err = $@;
      my $message = blessed($err) && $err->isa('Langertha::Skeid::Protocol::Refusal')
        ? $err->message : 'Invalid request';
      _refuse_unsendable_request($c, $node_id, $started, $meta, $message);
      return;
    }

    my $url = $rerank->at_server_root($format)
      ? _root_url_for_node($route->{url}, $rerank->upstream_path)
      : _endpoint_url_for_node($route->{url}, $rerank->upstream_path);
    my $relay = {
      # Tokens are reported in three places, none of them where a chat answer has them.
      usage => sub {
        my ($payload, $res) = @_;
        return $rerank->usage($payload, $res->headers, $format);
      },
      # Counted off the request, so it needs nothing from the node but its answer.
      units => sub {
        my ($payload, $res) = @_;
        return $res->is_success ? (documents => $documents) : ();
      },
      (length($format) ? (answer => sub {
        my ($payload, $res) = @_;
        return $rerank->response_from_upstream($payload, $res->headers, $body, $served_model, $format);
      }) : ()),
    };

    $c->render_later;
    _proxy_openai_json_async($c, $url, $upstream_body, $node_id, $started, $meta, sub {
      my ($res, $err, $status, $upstream, $payload) = @_;
      return if $err;
      return _render_upstream_response($c, $res, $node_id) unless length $format;
      $c->res->code($status || 200);
      $c->res->headers->header('x-skeid-node' => $node_id);
      $c->render(json => $payload);
    }, undef, $relay);
  });
}

sub _handle_anthropic_messages {
  my ($c) = @_;
  _extend_client_timeout($c);
  my $body = $c->req->json;
  unless (ref($body) eq 'HASH') {
    _render_error($c, 400, 'Invalid JSON body', 'invalid_request_error');
    return;
  }

  my $wants_stream = $body->{stream} ? 1 : 0;

  # Translation reads the client's body, so a failure there is the client's malformed request
  # -- a provider built-in tool skeid cannot forward, or a shape the translator cannot read.
  # Uncaught it escapes as Mojolicious' HTML 500; answer a 400 an Anthropic SDK can parse, before
  # anything is routed or metered (core karr #216).
  my $openai_body = eval { Langertha::Skeid::Protocol::Anthropic->request_to_openai($body) };
  unless ($openai_body) {
    # A deliberate refusal carries a message written for the client. Any other exception can quote
    # the request, so its text is neither sent nor logged (k75, k82).
    my $err = $@;
    my $msg = blessed($err) && $err->isa('Langertha::Skeid::Protocol::Refusal')
      ? $err->message : 'Invalid request';
    _render_error($c, 400, $msg, 'invalid_request_error');
    return;
  }
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

    if ($wants_stream) {
      # Ask upstream for a stream in the one dialect Skeid speaks to nodes, and rewrite it at
      # the client edge (ADR 0001). include_usage because Anthropic clients read token counts
      # from message_delta, and an OpenAI stream omits usage unless asked.
      $openai_body->{stream} = \1;
      $openai_body->{stream_options} = { include_usage => \1 };
      _proxy_openai_stream($c, $url, $openai_body, $node_id, $started, $meta,
        Langertha::Skeid::Protocol::Anthropic::Stream->new(model => $model));
      return;
    }

    delete $openai_body->{stream};
    $c->render_later;
    _proxy_openai_json_async($c, $url, $openai_body, $node_id, $started, $meta, sub {
      my ($res, $err, $status, $upstream, $payload) = @_;
      return if $err;
      $c->res->code($status || 200);
      $c->res->headers->header('x-skeid-node' => $node_id);
      $c->render(json => $payload);
    }, sub {
      # response_from_openai reads a decoded OpenAI response ($upstream->{choices}, ...); the
      # raw Mojo $res would read as all-undef and yield a well-formed but empty envelope (karr #26).
      return Langertha::Skeid::Protocol::Anthropic->response_from_openai($_[0], $model);
    });
  });
}

# Serves both Ollama completion routes. /api/chat and /api/generate differ only at the edge --
# generate's prompt/system/images become one chat conversation on the way up, and the answer
# carries `response` instead of `message` on the way back (skeid #43) -- so they share the
# route, admission, metering and pricing below and cannot drift apart.
my %OLLAMA_FACE = (
  chat => {
    endpoint => '/api/chat',
    request  => 'request_to_openai',
    response => 'response_from_openai',
    shape    => 'chat',
  },
  generate => {
    endpoint => '/api/generate',
    request  => 'generate_request_to_openai',
    response => 'generate_response_from_openai',
    shape    => 'generate',
  },
);

sub _handle_ollama {
  my ($c, $kind) = @_;
  _extend_client_timeout($c);
  my $face = $OLLAMA_FACE{$kind};
  my $body = $c->req->json;
  unless (ref($body) eq 'HASH') {
    _render_error($c, 400, 'Invalid JSON body', 'invalid_request_error');
    return;
  }

  # Ollama defaults stream to true when the field is absent, unlike everyone else. A client
  # that omits it is asking for a stream and will sit waiting for newline-delimited JSON.
  my $wants_stream = exists $body->{stream} ? ($body->{stream} ? 1 : 0) : 1;

  my $request_method = $face->{request};
  # A body the translator cannot read is the client's malformed request. Uncaught it escapes as
  # Mojolicious' HTML 500; answer a 400 in Ollama's shape before anything is routed or metered.
  # The exception's text stays out of the answer and the log, as with a dying response translator.
  my $openai_body = eval { Langertha::Skeid::Protocol::Ollama->$request_method($body) };
  unless (ref($openai_body) eq 'HASH') {
    _render_error($c, 400, 'Invalid request', 'invalid_request_error');
    return;
  }
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
      endpoint        => $face->{endpoint},
      api_key_id      => _request_api_key_id($c),
      provider        => 'skeid',
      engine          => ($route->{engine} // 'openaibase'),
      model           => $served_model,
      requested_model => $model,
      route_url       => ($route->{url} // ''),
    };

    if ($wants_stream) {
      $openai_body->{stream} = \1;
      $openai_body->{stream_options} = { include_usage => \1 };
      _proxy_openai_stream($c, $url, $openai_body, $node_id, $started, $meta,
        Langertha::Skeid::Protocol::Ollama::Stream->new(model => $model, shape => $face->{shape}));
      return;
    }

    delete $openai_body->{stream};
    $c->render_later;
    _proxy_openai_json_async($c, $url, $openai_body, $node_id, $started, $meta, sub {
      my ($res, $err, $status, $upstream, $payload) = @_;
      return if $err;
      $c->res->code($status || 200);
      $c->res->headers->header('x-skeid-node' => $node_id);
      $c->render(json => $payload);
    }, sub {
      # See the Anthropic path above: the translator needs the decoded upstream body, not the
      # Mojo response object, or every field reads undef and the client gets empty content (karr #26).
      my $response_method = $face->{response};
      return Langertha::Skeid::Protocol::Ollama->$response_method($_[0]);
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
    _render_error($c, 403, "Model '$model' is not available for this key", 'permission_error');
    $cb->();
    return;
  }

  my $plan = $decision->{tiers} || [];
  my $started = time;
  my $saw_eligible = 0;
  my $last_node_id = '';
  my $index = 0;
  my $tier_deadline = 0;

  my $tick;
  my $wait_timer;
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
        _render_error($c, 403, "Model '$model' is not available for this key", 'permission_error');
        undef $tick;
        $cb->();
        return;
      }
    }

    if (!$saw_eligible) {
      _render_error($c, 503, "No healthy node available for model '$model'", 'model_not_found');
    } else {
      my $waited_ms = int((time - $started) * 1000);
      my $msg = length($last_node_id)
        ? "Timed out waiting for free capacity on node '$last_node_id' (waited ${waited_ms}ms)"
        : "Timed out waiting for free capacity for model '$model' (waited ${waited_ms}ms)";
      _render_error($c, 429, $msg, 'rate_limit_error');
    }
    undef $tick;
    $cb->();
    return;
  };

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
          # Break the recursive callback's self-reference before control moves into the upstream
          # lifecycle. The active call frame keeps it alive until this invocation returns.
          undef $tick;
          $cb->($route, $node_id, $started, $tier);
          return;
        }
      }

      # Eligible but nothing free: this tier is worth waiting on, up to its own window.
      if (time < $tier_deadline) {
        $wait_timer = Mojo::IOLoop->timer($wait_poll_ms / 1000, $tick);
        return;
      }
    }

    $index++;
    $tier_deadline = time + (($plan->[$index] ? ($plan->[$index]{wait_ms} // 0) : 0) / 1000);
    $tick->();
    return;
  };

  # A client that hangs up while its request waits for capacity stops waiting: the next poll
  # would take a slot for nobody and never give it back. $tick is set exactly as long as
  # admission is undecided, which tells this finish from the one every answered request emits
  # as well. Nothing is rendered, there is nobody to read it. A stand-in controller has no
  # transaction.
  if ($c->can('tx') && $c->tx) {
    $c->tx->on(finish => sub {
      return unless $tick;
      Mojo::IOLoop->remove($wait_timer) if defined $wait_timer;
      undef $tick;
      $cb->();
    });
  }

  $tier_deadline = time + ((@$plan ? ($plan->[0]{wait_ms} // 0) : 0) / 1000);
  $tick->();
  return;
}

# True once the client of this request cannot be answered any more: its transaction was closed,
# or is destroyed already -- the controller holds it weakly. Only asked before anything was
# rendered, because a transaction that was answered is finished as well.
sub _client_gone {
  my ($c) = @_;
  my $tx = $c->tx;
  return (!$tx || $tx->is_finished) ? 1 : 0;
}

# Ends an upstream transaction in flight by closing its connection. The user agent then drops
# the connection instead of pooling it and runs the transaction's completion callback, and the
# node sees the connection close, which is what makes it stop generating. A transaction that
# is still connecting is closed as soon as it has a connection -- one tick later, because the
# user agent is in the middle of setting that connection up when it announces it. A finished
# transaction is left alone: its connection may be serving another request by now.
sub _cancel_upstream {
  my ($tx) = @_;
  my $close = sub {
    my ($id) = @_;
    return if $tx->is_finished;
    my $stream = Mojo::IOLoop->stream($id) or return;
    $stream->close;
    return;
  };
  if (defined(my $id = $tx->connection)) {
    $close->($id);
    return;
  }
  $tx->once(connection => sub {
    my (undef, $id) = @_;
    Mojo::IOLoop->next_tick(sub { $close->($id) });
  });
  return;
}

# What a request its client abandoned records (ADR 0004): failed, under the status nginx made
# the convention for "client closed request" -- no answer was delivered, and 499 can be told
# from every status a node or Skeid itself answers with.
sub _client_abort_event {
  return (
    status_code   => 499,
    ok            => 0,
    error_type    => 'client_abort',
    error_message => 'Client closed the connection before the response was complete',
  );
}

# $translate is an optional coderef that turns the decoded upstream answer into what the client
# gets. It runs before the request is finished and metered, so a translator that dies is one
# failed request -- one usage event with ok => 0, an error in the face's own shape -- and the
# callback gets the translated payload as its fifth argument, or nothing after an error.
#
# $relay is what a route relayed in the upstream's own shape brings (ADR 0021), all optional:
# `request`, a code ref called with the user agent, the URL and the upstream headers that builds
# the upstream transaction instead of the JSON one made from $body; `units`, a code ref that
# reads the route's own usage units off the decoded answer and returns them as event fields;
# and, for a stream, `delta_text`, which returns the text of a frame in the route's own dialect.
# Two more for an answer that is not chat-shaped (rerank, skeid k92), both called with the
# decoded answer -- whatever JSON it is -- and the upstream response: `usage` returns the usage
# block to meter, or nothing, where the answer reports its tokens somewhere else than a chat
# answer does; `answer` is $translate for a node whose own dialect is not the client's, and
# fails the same way.
sub _proxy_openai_json_async {
  my ($c, $url, $body, $node_id, $started, $meta, $cb, $translate, $relay) = @_;
  $meta ||= {};
  $cb ||= sub { };
  $relay ||= {};

  my %fwd_headers = _forward_headers($c);
  _inject_node_auth_async(\%fwd_headers, $c->skeid, $node_id, sub {
  my ($no_key) = @_;

  # The client hung up while the node key was being resolved, whether or not it resolved -- asked
  # before the refusal, which would meter and answer a transaction nobody holds any more. Nothing went upstream: the slot
  # is given back and nothing is metered, as for every request that was not forwarded.
  if (_client_gone($c)) {
    $c->skeid->call_function('request.finish', {
      id => $node_id,
      ok => 0,
      aborted => 1,
      duration_ms => _duration_ms($started),
    });
    $cb->(undef, 1, 499);
    return;
  }

  if (defined $no_key) {
    _refuse_unkeyed_node($c, $node_id, $started, $meta, $no_key);
    $cb->(undef, 1, 503);
    return;
  }
  my $tx = _upstream_tx($c, $url, \%fwd_headers, $body, $relay);

  # Set by whichever comes first, the upstream's completion or the client hanging up, so that
  # request.finish and the usage event happen once.
  my $closed = 0;

  $c->tx->on(finish => sub {
    return if $closed;
    $closed = 1;
    my $duration_ms = _duration_ms($started);
    $c->skeid->call_function('request.finish', {
      id => $node_id,
      ok => 0,
      aborted => 1,
      duration_ms => $duration_ms,
    });
    _record_usage_event($c, {
      %$meta,
      _client_abort_event(),
      node_id     => $node_id,
      duration_ms => $duration_ms,
      metrics     => {},
    });
    _cancel_upstream($tx);
    $cb->(undef, 1, 499);
  });

  $c->app->ua->start($tx => sub {
    my ($ua, $done) = @_;
    # The client hung up and its request was closed then; this is the cancelled transaction.
    return if $closed;
    $closed = 1;
    my $duration_ms = _duration_ms($started);
    my $res = $done->res;

    # Mojo reports an HTTP 4xx/5xx through tx->error too. Observe the response that actually
    # arrived before taking that error return, so a 429's Retry-After can gate the next request.
    # A transport failure has no useful status or headers and _observe_capacity records nothing.
    _observe_capacity($c, $node_id, $res);

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
      _render_error($c, ($err->{code} || 502),
        'Upstream error: ' . _upstream_error_message($err, $done->res->body), 'upstream_error');
      $cb->(undef, 1, ($err->{code} || 502));
      return;
    }

    my $status = $res->code // 200;
    my $payload = eval { $res->json };

    my $translated;
    if ($translate || $relay->{answer}) {
      $translated = eval {
        $relay->{answer}
          ? $relay->{answer}->($payload, $res)
          : $translate->(ref($payload) eq 'HASH' ? $payload : {});
      };
      unless (defined $translated) {
        $c->app->log->error('Translating the answer of node ' . $node_id . ' failed');
        $c->skeid->call_function('request.finish', {
          id => $node_id,
          ok => 0,
          duration_ms => $duration_ms,
        });
        _record_usage_event($c, {
          %$meta,
          node_id       => $node_id,
          status_code   => 500,
          ok            => 0,
          duration_ms   => $duration_ms,
          error_type    => 'translation_error',
          error_message => 'Response translation failed',
          metrics       => {},
        });
        _render_error($c, 500, 'Response translation failed', 'api_error');
        $cb->(undef, 1, 500);
        return;
      }
    }

    $c->skeid->call_function('request.finish', {
      id => $node_id,
      ok => ($status < 500) ? 1 : 0,
      duration_ms => $duration_ms,
    });

    my $metrics = {};
    if ($relay->{usage}) {
      my $usage = $relay->{usage}->($payload, $res);
      $metrics = _priced_metrics($c, $meta, $body, $duration_ms, { usage => $usage })
        if ref($usage) eq 'HASH';
    } elsif (ref($payload) eq 'HASH') {
      my $tool_calls = eval { [ map { $_->to_hash } Langertha::ToolCall->extract('openai', $payload) ] } || [];
      $metrics = _priced_metrics($c, $meta, $body, $duration_ms, $payload, $tool_calls);
    }

    _record_usage_event($c, {
      %$meta,
      node_id      => $node_id,
      status_code  => $status,
      ok           => ($status < 500) ? 1 : 0,
      duration_ms  => $duration_ms,
      metrics      => $metrics,
      ($relay->{units} ? $relay->{units}->($payload, $res) : ()),
    });

    $cb->($res, 0, $status, (ref($payload) eq 'HASH' ? $payload : {}), $translated);
  });
  });

  return;
}

# $stream is an optional translator (Protocol::*::Stream). Without one the upstream's bytes are
# relayed untouched, which is what an OpenAI client wants and the only path that cannot lose
# anything in translation. With one, each OpenAI chunk is decoded and re-emitted in the
# client's own format -- the same edge-translation seam as the non-streaming path (ADR 0001).
# $relay is as for _proxy_openai_json_async.
sub _proxy_openai_stream {
  my ($c, $url, $body, $node_id, $started, $meta, $stream, $relay) = @_;
  $meta ||= {};
  $relay ||= {};

  my %fwd_headers = _forward_headers($c);

  # render_later before the key resolution, not after: a cold cache means the callback runs on
  # a later tick, and Mojolicious would have rendered an empty response by then.
  $c->render_later;

  _inject_node_auth_async(\%fwd_headers, $c->skeid, $node_id, sub {
  my ($no_key) = @_;

  # The client hung up while the node key was being resolved, whether or not it resolved -- asked
  # before the refusal, which would meter and answer a transaction nobody holds any more. Nothing
  # went upstream: the slot is given back and nothing is metered, as for every request that was
  # not forwarded. Nothing is set up yet, so there is nothing to take apart.
  if (_client_gone($c)) {
    $c->skeid->call_function('request.finish', {
      id => $node_id,
      ok => 0,
      aborted => 1,
      duration_ms => _duration_ms($started),
    });
    return;
  }

  return _refuse_unkeyed_node($c, $node_id, $started, $meta, $no_key) if defined $no_key;
  my $tx = _upstream_tx($c, $url, \%fwd_headers, $body, $relay);
  # Mojolicious would parse an unchunked, exactly-text/event-stream body into its own `sse`
  # events and never emit `read` -- the relay would forward nothing (skeid karr #30).
  $tx->res->content(Langertha::Skeid::Proxy::RelayContent->new);

  my $headers_sent = 0;
  my $had_error = 0;
  # Taken now: the header goes out before the first byte, and the request may be past its
  # transaction by then.
  my $request_id = _request_id($c);
  # A translator that can report errors in its own format (Anthropic, Ollama) takes the failure
  # paths too: an upstream error status before the stream opens becomes a plain HTTP error in
  # the client's shape, a failure after it becomes an in-band error event (core karr #224).
  my $stream_errors = $stream && $stream->can('error_event');
  my $upstream_failed = 0;
  my $upstream_error_body = '';
  my $status = 200;
  # The upstream's own usage block, verbatim, so a stream is priced by the same metrics.normalize
  # call as a non-streamed answer (skeid #41). undef until a frame carries one.
  my $upstream_usage;
  my $accumulated_content_bytes = 0;
  # UTF-8 bytes of the content this stream relayed or translated, for the usage event (skeid #36).
  # A relayed stream counts off the OpenAI deltas it read along; a translated one takes its
  # translator's own count -- the text it actually wrote in the client's format. An observation
  # recorded beside the token counts, never a substitute for them.
  my $content_bytes = sub { $stream ? 0 + ((($stream->usage)[2]) // 0) : $accumulated_content_bytes };
  # The route's own usage units (ADR 0021), read off the usage the stream carried so far -- the
  # same block a non-streamed answer would have carried. Nothing until a frame had one.
  my $units = sub {
    return () unless $relay->{units} && ref($upstream_usage) eq 'HASH';
    return $relay->{units}->({ usage => $upstream_usage });
  };

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
        # write_chunk retains its last drain callback. Clear the recursive callback scalar once
        # the queue is complete so that callback cannot retain the controller through $drain.
        undef $drain;
      }
      return;
    }
    $draining = 1;
    my $chunk = shift @queue;
    $c->write_chunk($chunk => sub { $drain->() if $drain });
  };

  # SSE frames do not respect read boundaries: one read can carry half a frame, and the half
  # that completes it arrives in the next. Parsing per read would silently drop the split
  # frame -- usually the last one, which is the one carrying usage.
  my $pending = '';

  # Set by whichever comes first, the upstream's completion, the client hanging up or a
  # translator that died, so that request.finish and the usage event happen once.
  my $closed = 0;

  # A translator that dies on a chunk ends the request here, not in the upstream callback the
  # exception would escape from: the upstream is cancelled, the slot given back, one failed usage
  # event written, and the client answered in its own face's error shape -- an HTTP error when
  # nothing was queued for it yet, an in-band error event when the stream is open. The
  # exception's text is neither logged nor sent: it is the translator's own and may quote the
  # request.
  my $wrote = 0;
  my $fail_translation = sub {
    return if $closed;
    $closed = 1;
    $tx->res->content->unsubscribe('read');
    my $duration_ms = _duration_ms($started);
    $c->skeid->call_function('request.finish', {
      id => $node_id,
      ok => 0,
      duration_ms => $duration_ms,
    });
    _record_usage_event($c, {
      %$meta,
      node_id       => $node_id,
      status_code   => 500,
      ok            => 0,
      duration_ms   => $duration_ms,
      error_type    => 'translation_error',
      error_message => 'Stream translation failed',
      content_bytes => $content_bytes->(),
      metrics       => _stream_metrics($c, $meta, $body, $duration_ms, $upstream_usage),
      $units->(),
    });
    _cancel_upstream($tx);
    $upstream_done = 1;
    if (!$wrote) {
      $c->res->headers->remove($_) for @{$c->res->headers->names};
      $c->res->headers->header('x-request-id' => $request_id);
      _render_error($c, 500, 'Stream translation failed', 'api_error');
      undef $drain;
      return;
    }
    my $frame = eval { $stream_errors ? $stream->error_event(500, 'Stream translation failed') : '' };
    push @queue, $frame if defined $frame && length $frame;
    $drain->() unless $draining;
    if (!$draining && !$finished) {
      $finished = 1;
      $c->finish;
      undef $drain;
    }
  };

  $tx->res->content->unsubscribe('read')->on(read => sub {
    my ($content, $bytes) = @_;
    # Kept only to lift the upstream's own error message into the error the client gets.
    return $upstream_error_body .= $bytes if $upstream_failed;
    unless ($headers_sent) {
      $status = $tx->res->code // 200;
      # The upstream refused before streaming anything. Opening an SSE response for it would
      # hand the client a 4xx/5xx event stream with no events in it; leave the response unsent
      # and let the completion callback answer it as an error, as the non-streaming path does.
      if ($stream_errors && $status >= 400) {
        $upstream_failed = 1;
        $upstream_error_body .= $bytes;
        return;
      }
      $c->res->code($status);
      for my $name (@{$tx->res->headers->names}) {
        my $lc = lc($name);
        next if $lc eq 'content-length' || $lc eq 'transfer-encoding' || $lc eq 'content-encoding';
        # A translated stream is not the upstream's media type any more. Relaying
        # text/event-stream to an Ollama client tells it to parse something it does not speak.
        next if $stream && $lc eq 'content-type';
        $c->res->headers->header($name => $tx->res->headers->header($name));
      }
      $c->res->headers->header('content-type' => $stream->content_type) if $stream;
      $c->res->headers->header('x-skeid-node' => $node_id);
      $c->res->headers->header('x-request-id' => $request_id);
      $headers_sent = 1;
    }

    # Parse SSE lines and accumulate usage + content bytes. Without a translator the relayed
    # bytes are never modified -- this reads along, it does not rewrite.
    $pending .= $bytes;
    my $translated = '';
    while ($pending =~ s/\A([^\n]*)\n//) {
      my $line = $1;
      next unless $line =~ /^data: (.+?)\s*$/;
      my $payload = $1;

      # OpenAI closes with a literal [DONE] sentinel, which is not JSON and has no equivalent
      # in either target format -- the translated stream ends with its own closing events.
      next if $payload eq '[DONE]';

      my $json = eval { decode_json($payload) };
      next unless $json && ref($json) eq 'HASH';

      if (my $delta = $json->{choices}[0]{delta}) {
        if (my $delta_content = $delta->{content}) {
          $accumulated_content_bytes += Langertha::Skeid::Protocol::utf8_length($delta_content);
        }
      }
      if ($relay->{delta_text}) {
        my $text = $relay->{delta_text}->($json);
        $accumulated_content_bytes += Langertha::Skeid::Protocol::utf8_length($text)
          if defined($text) && length($text);
      }

      if (ref($json->{usage}) eq 'HASH') {
        $upstream_usage = _merge_usage($upstream_usage, $json->{usage});
      }

      if ($stream) {
        my $out = eval { $stream->delta($json) };
        unless (defined $out) {
          $c->app->log->error('Translating a stream chunk failed for node ' . $node_id);
          return $fail_translation->();
        }
        $translated .= $out;
      }
    }

    # The first read event fires with an empty chunk as soon as the upstream headers are
    # parsed, and writing an empty chunk finalizes a Mojolicious response. Relaying it would
    # end the stream before its first token -- headers, no body, no error.
    if ($stream) {
      return unless length $translated;
      $wrote = 1;
      push @queue, $translated;
    } else {
      return unless length $bytes;
      $wrote = 1;
      push @queue, $bytes;
    }
    $drain->() unless $draining;
  });

  $c->tx->on(finish => sub {
    # Also emitted when the answer is complete, and then there is nothing left to do here. When
    # the client hung up, what is queued has no reader and the drain callback that would take
    # the next chunk does not run again: drop the queue and the callback's self-reference, or
    # they keep the controller alive.
    @queue = ();
    $finished = 1;
    undef $drain;
    return if $closed;
    $closed = 1;
    $tx->res->content->unsubscribe('read');

    # Billed from what the stream reported before the client left; the node spent that, whoever
    # read it (ADR 0004).
    my $duration_ms = _duration_ms($started);
    $c->skeid->call_function('request.finish', {
      id => $node_id,
      ok => 0,
      aborted => 1,
      duration_ms => $duration_ms,
    });
    _record_usage_event($c, {
      %$meta,
      _client_abort_event(),
      node_id       => $node_id,
      duration_ms   => $duration_ms,
      content_bytes => $content_bytes->(),
      metrics       => _stream_metrics($c, $meta, $body, $duration_ms, $upstream_usage),
      $units->(),
    });
    _cancel_upstream($tx);
  });

  $c->app->ua->start($tx => sub {
    my ($ua, $tx_done) = @_;

    # The read listener closes over both the upstream transaction and the client controller.
    # Completion means no further bytes can arrive, so remove it before returning from any path;
    # otherwise the completed transaction owns the listener that owns the transaction forever.
    $tx_done->res->content->unsubscribe('read');

    # The client hung up and its request was closed then; this is the cancelled transaction.
    return if $closed;
    $closed = 1;

    # As on the JSON path, an HTTP error is still a response whose capacity headers matter.
    # Observe it before the pre-stream error return; transport failures contribute nothing.
    _observe_capacity($c, $node_id, $tx_done->res);

    if (my $err = $tx_done->error) {
      $had_error = 1;
      unless ($headers_sent) {
        my $duration_ms = _duration_ms($started);
        my $err_status = $err->{code} || 502;
        $c->skeid->call_function('request.finish', {
          id => $node_id,
          ok => 0,
          duration_ms => $duration_ms,
        });
        _record_usage_event($c, {
          %$meta,
          node_id       => $node_id,
          status_code   => $err_status,
          ok            => 0,
          duration_ms   => $duration_ms,
          error_type    => 'upstream_error',
          error_message => ($err->{message} // 'unknown'),
          content_bytes => $content_bytes->(),
          metrics       => _stream_metrics($c, $meta, $body, _duration_ms($started), $upstream_usage),
          $units->(),
        });
        _render_error($c, $err_status,
          'Upstream error: ' . _upstream_error_message($err, $upstream_error_body), 'upstream_error');
        undef $drain;
        return;
      }
    }

    # The stream is open, so the status is already sent. Mojo::UserAgent reports an upstream
    # that hangs up mid-body as no error at all once the status line has arrived, so the body's
    # own framing (the chunked terminator, Content-Length) is the witness for that case; a
    # close-delimited body cannot be told apart from a complete one. A cut stream failed on
    # every face: the usage event and request.finish must not mean something different
    # depending on the client's dialect (ADR 0004).
    my $cut = 0;
    if ($headers_sent && !$had_error) {
      my $content = $tx_done->res->content;
      my $framed = $content->is_chunked || length($content->headers->content_length // '');
      $cut = $framed && !$content->is_finished;
      $had_error = 1 if $cut;
    }

    # A translator that can say so in-band ends a failed stream with its error event instead of
    # a closing sequence that would read as a complete answer.
    if ($stream_errors && $headers_sent) {
      if ($had_error) {
        my $reason = $cut ? 'Premature connection close' : ($tx_done->error->{message} // 'unknown');
        my $frame = $stream->error_event(500, "Upstream error: $reason");
        if (length $frame) {
          push @queue, $frame;
          $drain->() unless $draining;
        }
      }
    }

    # Finalize a translated stream before closing admission or recording its Usage event: a
    # translator can discover a terminal error only when it sees that no more upstream frames
    # are coming. Its tail is queued like any other chunk so it still lands after deltas already
    # in flight. Keep an unexpected finalizer exception inside the callback boundary and use the
    # translator's existing in-band error shape without reflecting internal details.
    if ($stream && $headers_sent) {
      my $tail = '';
      my $finalized = eval {
        $tail = $stream->finish;
        1;
      };
      unless ($finalized) {
        $had_error = 1;
        $tail = eval { $stream_errors
          ? $stream->error_event(500, 'Stream translation failed')
          : '' };
      }
      $tail = '' unless defined $tail;
      if (length $tail) {
        push @queue, $tail;
        $drain->() unless $draining;
      }
    }

    # An upstream that reported its failure inside the stream, or a translator that could only
    # detect one while finalizing, was answered with an error event; the request still failed.
    $had_error = 1 if $stream && $stream->can('errored') && $stream->errored;

    my $duration_ms = _duration_ms($started);
    $c->skeid->call_function('request.finish', {
      id => $node_id,
      ok => ($had_error || $status >= 500) ? 0 : 1,
      duration_ms => $duration_ms,
    });

    # Priced from whatever usage the stream carried, also when it was cut: a cut stream still
    # spent what its frames reported, and one that reported nothing records zero (ADR 0004).
    _record_usage_event($c, {
      %$meta,
      node_id      => $node_id,
      status_code  => $status,
      ok           => ($had_error || $status >= 500) ? 0 : 1,
      duration_ms  => $duration_ms,
      content_bytes => $content_bytes->(),
      metrics      => _stream_metrics($c, $meta, $body, $duration_ms, $upstream_usage),
      $units->(),
    });

    # Only finish once the queue has drained, or the tail of the stream is cut off. If the
    # drain loop is still running it will finish for us when it empties.
    $upstream_done = 1;
    if (!$draining && !$finished) {
      $finished = 1;
      $c->finish;
      undef $drain;
    }
  });
  });
}

# The upstream request of an admitted call: the one JSON POST every translated route makes (ADR
# 0001), or what a relayed route's own `request` builder returns (ADR 0021).
sub _upstream_tx {
  my ($c, $url, $headers, $body, $relay) = @_;
  my $ua = $c->app->ua;
  return $relay->{request}->($ua, $url, $headers) if $relay && $relay->{request};
  return $ua->build_tx(POST => $url, $headers, json => $body);
}

# Renders an error in the shape of the face the client called. The Anthropic Messages face
# gets Anthropic's envelope, {type: "error", error: {type, message}}, with the type taken from
# the HTTP status, because that is what an Anthropic SDK parses and raises on (core karr #224).
# The Ollama face gets Ollama's {error: "<message>"}, a plain string, because that is what the
# Ollama clients decode (skeid #47). Every other face keeps the OpenAI shape it always had, with
# $openai_type as its type and $openai_code, when given, as its code (OpenAI's own 401 carries
# invalid_api_key). The face is read off the stash, which the /v1/messages and /api/* bridges
# set; a controller without one (a unit test's stand-in) is an OpenAI face.
sub _render_error {
  my ($c, $status, $message, $openai_type, $openai_code) = @_;
  my $format = $c->can('stash') ? ($c->stash('skeid.error_format') // '') : '';
  if ($format eq 'anthropic') {
    $c->render(json => Langertha::Skeid::Protocol::Anthropic->error_body($status, $message),
      status => $status);
    return;
  }
  if ($format eq 'ollama') {
    $c->render(json => Langertha::Skeid::Protocol::Ollama->error_body($message), status => $status);
    return;
  }
  $c->render(json => { error => {
    message => $message,
    type    => $openai_type,
    defined($openai_code) ? ( code => $openai_code ) : (),
  } }, status => $status);
  return;
}

# The message to put after "Upstream error: ". Mojo sets $err->{message} to the HTTP reason
# phrase for a 4xx/5xx ("Bad Request"); the upstream usually said more in its own body, in the
# OpenAI dialect every node speaks (ADR 0001), and that is what the client needs to act on.
sub _upstream_error_message {
  my ($err, $body) = @_;
  my $json = (defined($body) && length($body)) ? eval { decode_json($body) } : undef;
  if (ref($json) eq 'HASH') {
    my $e = $json->{error};
    my $msg = ref($e) eq 'HASH' ? $e->{message} : $e;
    return "$msg" if defined($msg) && !ref($msg) && length($msg);
  }
  return $err->{message} // 'unknown';
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
  $c->res->headers->header('x-request-id' => _request_id($c));
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
# The callback runs exactly once, and always. It is called with nothing when the request may go
# upstream: the node's key is in place, or the node names no key source and forwards the
# client's header untouched. It is called with a reason when the node names a key source and
# none produced a key, or when the node is no longer in the inventory and what it named cannot
# be known -- the caller must then refuse the request (_refuse_unkeyed_node) rather than call
# the node, because the only credential left in the headers is the customer's own, and the
# pass-through would hand it to the provider (ADR 0003). The reason names the node, the key
# reference and the variable, never a key, and is for the log and the usage event.
#
# Wherever the client's header is not what goes upstream -- a key was injected, or the request
# is refused -- the client's credentials are taken out of the headers first, in any spelling.
#
# Async because resolution can mean a vault round-trip, and this sits between routing and the
# upstream call -- doing it synchronously stalls every other in-flight request for that
# round-trip (ADR 0005). key_async answers from cache without touching the loop, so the
# blocking case is a cold cache, and even then only one request per reference pays for it.
sub _inject_node_auth_async {
  my ($headers_ref, $skeid, $node_id, $cb) = @_;
  $cb ||= sub { };

  my ($node) = grep { ($_->{id} // '') eq $node_id } @{$skeid->nodes};
  unless ($node) {
    _drop_client_credentials($headers_ref);
    return $cb->("node '$node_id' is no longer in the inventory, its key source is unknown");
  }

  my $ref = $node->{api_key_ref};
  $ref = undef unless defined($ref) && length($ref);
  my $env_name = $node->{api_key_env};
  $env_name = undef unless defined($env_name) && length($env_name);

  my $apply = sub {
    my ($key, $ref_failure) = @_;

    # Fallback: env var
    if (!defined($key) || !length($key)) {
      if (defined $env_name) {
        $key = $ENV{$env_name} // '';
      }
    }

    if (defined($key) && length($key)) {
      _drop_client_credentials($headers_ref);
      $headers_ref->{Authorization} = "Bearer $key";
      return $cb->();
    }

    # A node with no key of its own: the documented pass-through.
    return $cb->() unless defined($ref) || defined($env_name);

    # A key source was named and produced nothing. Take the client's credentials out of what
    # would go upstream as well, so a caller that ignored the reason still could not leak them.
    _drop_client_credentials($headers_ref);
    $cb->(join('; ',
      (defined($ref) ? "api_key_ref '$ref' $ref_failure" : ()),
      (defined($env_name)
        ? "api_key_env '$env_name' is " . (defined($ENV{$env_name}) ? 'empty' : 'not set')
        : ()),
    ));
  };

  if (defined($ref) && $skeid->has_key_broker) {
    $skeid->key_broker->key_async($ref, sub {
      my ($key, $error) = @_;
      # The reference may be logged; what it resolves to may not, and neither may a vault
      # response body that might carry it (ADR 0003).
      warn "KeyBroker resolve failed for '$ref': $error"
        if defined($error) && !defined($key);
      $apply->($key, 'did not resolve');
    });
    return;
  }

  $apply->(undef, 'has no key broker to resolve it');
  return;
}

# Header names are case-insensitive and Mojolicious hands an unknown one on as the client
# spelled it, so `X-Api-Key` is as much the client's key as `x-api-key`. An exact-case delete
# lets it travel upstream beside the node's own key.
sub _drop_client_credentials {
  my ($headers_ref) = @_;
  delete @{$headers_ref}{
    grep { lc($_) eq 'authorization' || lc($_) eq 'x-api-key' } keys %$headers_ref
  };
  return;
}

# The answer to a request whose node names a key source that produced no key: no upstream call,
# and everything an admitted request is owed -- its request.finish, one usage event, an error in
# the shape of the face that was called. 503, not 502: no upstream was asked, so nothing came
# back bad; this Skeid cannot serve the request until its broker or its environment is put
# right, and a client may retry. The client is told no more than that -- the reason carries a
# key reference, which belongs in the log and the usage event, not in a customer's answer.
sub _refuse_unkeyed_node {
  my ($c, $node_id, $started, $meta, $reason) = @_;
  my $duration_ms = _duration_ms($started);
  $c->app->log->error("No upstream key for node '$node_id', request refused: $reason");
  $c->skeid->call_function('request.finish', {
    id => $node_id,
    ok => 0,
    duration_ms => $duration_ms,
  });
  _record_usage_event($c, {
    %$meta,
    node_id       => $node_id,
    status_code   => 503,
    ok            => 0,
    duration_ms   => $duration_ms,
    error_type    => 'upstream_key_unavailable',
    error_message => $reason,
    metrics       => {},
  });
  _render_error($c, 503, 'The upstream key for this model is not available',
    'upstream_key_unavailable');
  return;
}

# The answer to a request that holds a slot on a node and cannot be put to it: the body is in a
# shape the node's dialect has no place for, which only shows once the node is known (rerank to a
# `rerank_format` node, skeid k92). As for an unkeyed node, no upstream call and everything an
# admitted request is owed -- its request.finish, one usage event, an error in the face's shape
# -- but 400: the request is the client's to change, and no retry will get it through.
# $message is written for the client and quotes nothing of the request.
sub _refuse_unsendable_request {
  my ($c, $node_id, $started, $meta, $message) = @_;
  my $duration_ms = _duration_ms($started);
  $c->skeid->call_function('request.finish', {
    id => $node_id,
    ok => 0,
    duration_ms => $duration_ms,
  });
  _record_usage_event($c, {
    %$meta,
    node_id       => $node_id,
    status_code   => 400,
    ok            => 0,
    duration_ms   => $duration_ms,
    error_type    => 'invalid_request_error',
    error_message => $message,
    metrics       => {},
  });
  _render_error($c, 400, $message, 'invalid_request_error');
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

# The id taken when the request arrived; a client's own x-request-id is taken over, else one is
# made up. Before that hook ran (a bare controller) it is worked out from the request, and once
# the transaction is gone it must come from the stash.
sub _request_id {
  my ($c) = @_;
  my $kept = $c->stash('skeid.request_id');
  return $kept if defined($kept) && length($kept);
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
      # This reshaping drops prompt_tokens_details, so the cache count has to be carried across
      # it explicitly or record_usage never sees it. Both paths carry it as a flat
      # metrics->{cached_tokens}, from metrics.normalize or the raw payload (k27, skeid #41).
      cached => (_cached_tokens($usage) || 0 + ($metrics->{cached_tokens} // 0)),
    },
  };

  my $request_id = _request_id($c);
  my $recorded = eval {
    $c->skeid->call_function('usage.record', {
      created_at    => Langertha::Skeid::Protocol::iso8601_now(),
      request_id    => $request_id,
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
      # Streamed requests only; absent otherwise, so the event says "not measured" (skeid #36).
      (defined($args->{content_bytes}) ? (content_bytes => 0 + $args->{content_bytes}) : ()),
      # Audio routes only, and only when the node reported it (skeid k91, ADR 0021).
      (defined($args->{audio_seconds}) ? (audio_seconds => 0 + $args->{audio_seconds}) : ()),
      # The rerank route only, and only for a request the node answered (skeid k92).
      (defined($args->{documents}) ? (documents => 0 + $args->{documents}) : ()),
      metrics       => $safe_metrics,
    });
  };
  my $err;
  if ($@) {
    $err = "$@";
    $recorded = { ok => 0, error => $err };
  } elsif (ref($recorded) eq 'HASH' && !$recorded->{ok} && ($recorded->{enabled} // 1)) {
    # A store reports a failed write in its answer (the JsonLog contract); no sink at all
    # answers enabled => 0 and has nothing to lose.
    $err = $recorded->{error} // 'unknown error';
  }
  if (defined $err) {
    _log_lost_usage_event($c->app, $c->skeid, {
      request_id  => $request_id,
      api_key_id  => ($args->{api_key_id} // 'anonymous'),
      model       => $args->{model},
      status_code => $args->{status_code},
    }, $err);
  }

  return $recorded;
}

# The event is the billing unit (ADR 0004) and it is gone: say so at a level production keeps,
# with what an operator needs to reconcile it by hand. The request id and the key id, never the
# key -- the key id is a digest (ADR 0016), the key is a secret (ADR 0003). One line for both
# ways an event is lost: a write that failed while the request waited, and a queued one a
# write-behind flush could not write later (skeid k78).
sub _log_lost_usage_event {
  my ($app, $skeid, $event, $err) = @_;
  $err //= 'unknown error';
  $err =~ s/\s+$//;
  $app->log->error('usage event lost: request_id=' . ($event->{request_id} // '')
    . ' store=' . _usage_sink_name($skeid)
    . ' api_key_id=' . ($event->{api_key_id} // 'anonymous')
    . ' model=' . ($event->{model} // '')
    . ' status=' . ($event->{status_code} // 0)
    . ': ' . $err);
  return;
}

# Which sink a lost usage event was meant for, for the log line: the store's backend name, or
# how the embedding application took the event over. Never the DSN or path, which may carry
# credentials.
sub _usage_sink_name {
  my ($skeid) = @_;
  return 'store_usage_event' if $skeid->has_store_usage_event;
  my $cfg = $skeid->usage_store;
  return (ref($cfg) eq 'HASH' && length($cfg->{backend} // '')) ? $cfg->{backend} : 'custom';
}

# The prompt-cache read count off a raw OpenAI-shaped upstream usage hash (k27). OpenAI nests it
# under prompt_tokens_details.cached_tokens; some OpenAI-compatible servers expose a flat
# cached_tokens, an Anthropic-spelled block cache_read_input_tokens, and a caller of usage.record may pass it as `cached`. Missing -> 0, the
# same fault-tolerance the other token reads here have. This reads a count off a response Skeid
# already holds -- every upstream answers in the OpenAI dialect (ADR 0001) -- it does not
# translate a client format. Both paths prefer the count metrics.normalize reads through
# Langertha::Usage and prices (skeid #28, #41); this is the fallback on Langertha 0.503.
sub _cached_tokens {
  my ($usage) = @_;
  return 0 unless ref($usage) eq 'HASH';
  my $details = $usage->{prompt_tokens_details};
  return 0 + ($usage->{cached}
    // $usage->{cached_tokens}
    // (ref($details) eq 'HASH' ? $details->{cached_tokens} : undef)
    // $usage->{cache_read_input_tokens}
    // 0);
}

# Prices an upstream answer: its usage block goes through metrics.normalize (Langertha::Usage +
# Langertha::Pricing), the one pricing path for every face, streamed or not (skeid #28, #41).
# $payload is the decoded upstream body, or for a stream a body holding only the usage block
# the stream carried -- the same usage, so the same cost.
sub _priced_metrics {
  my ($c, $meta, $body, $duration_ms, $payload, $tool_calls) = @_;
  my $metrics = eval {
    $c->skeid->call_function('metrics.normalize', {
      provider    => ($meta->{provider} || 'skeid'),
      engine      => ($meta->{engine} || 'openaibase'),
      model       => ($meta->{model} || ($body->{model} // '')),
      route       => ($meta->{endpoint} || ''),
      duration_ms => $duration_ms,
      response    => $payload,
      tool_calls  => ($tool_calls || []),
    });
  };
  $metrics = {} unless ref($metrics) eq 'HASH';
  # metrics.normalize reports the prompt-cache counts off Langertha::Usage, from every wire
  # spelling it knows (skeid #28). Langertha 0.503's Usage has no such counts, so there they are
  # pulled straight off the raw upstream usage and carried flat, the way input/output survive
  # as metrics->{*_tokens} (k27).
  if (!defined $metrics->{cached_tokens}) {
    my $cached = _cached_tokens($payload->{usage});
    $metrics->{cached_tokens} = $cached if $cached;
  }
  if (!defined $metrics->{cache_write_tokens}) {
    my $written = _cache_write_tokens($payload->{usage});
    $metrics->{cache_write_tokens} = $written if $written;
  }
  return $metrics;
}

# A stream's metrics: its verbatim usage priced exactly as a non-streamed body carrying it would
# be. A stream that carried no usage has nothing to price -- no token count or cost is invented.
sub _stream_metrics {
  my ($c, $meta, $body, $duration_ms, $usage) = @_;
  return {} unless ref($usage) eq 'HASH';
  return _priced_metrics($c, $meta, $body, $duration_ms, { usage => $usage });
}

# Folds one stream frame's usage block into what the stream reported so far, key by key, a later
# frame's value replacing an earlier one (nested blocks such as prompt_tokens_details likewise).
# Usage counts on a stream are running totals, never increments: OpenAI's final frame carries
# the whole request, a server that reports on every chunk repeats the growing total, and a wire
# that splits the block (input on the first frame, output on the last) is completed rather
# than lost. Summing frames would bill the same tokens twice.
sub _merge_usage {
  my ($into, $frame) = @_;
  my %merged = ref($into) eq 'HASH' ? %$into : ();
  for my $key (keys %$frame) {
    my $value = $frame->{$key};
    next unless defined $value;
    $merged{$key} = (ref($value) eq 'HASH' && ref($merged{$key}) eq 'HASH')
      ? _merge_usage($merged{$key}, $value)
      : $value;
  }
  return \%merged;
}

# The prompt-cache write count off a raw upstream usage hash, for a Langertha that cannot read it
# itself (0.503): OpenAI Chat nests it under prompt_tokens_details.cache_write_tokens, an
# Anthropic-shaped block carries cache_creation_input_tokens. Missing -> 0. A count, never priced
# here -- pricing is Langertha::Pricing's (skeid #41).
sub _cache_write_tokens {
  my ($usage) = @_;
  return 0 unless ref($usage) eq 'HASH';
  my $details = $usage->{prompt_tokens_details};
  return 0 + ((ref($details) eq 'HASH' ? $details->{cache_write_tokens} : undef)
    // $usage->{cache_write_tokens}
    // $usage->{cache_creation_input_tokens}
    // 0);
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

# The URL of a route a node serves at its server root rather than below /v1 (a TEI node's
# /rerank): a node URL is a base, and one written with a trailing /v1 names the same server.
sub _root_url_for_node {
  my ($base, $path) = @_;
  $base //= '';
  $base =~ s{/\z}{};
  $base =~ s{/v1\z}{};
  return $base . $path;
}

sub _duration_ms {
  my ($started) = @_;
  return int((time - $started) * 1000);
}

=seealso

=over 4

=item * L<Langertha::Skeid> -- the control plane and its configuration

=item * L<skeid> -- the command that runs this app

=item * L<Langertha::Skeid::Protocol::Anthropic>, L<Langertha::Skeid::Protocol::Ollama> -- the
translated faces

=item * L<Langertha::Skeid::Protocol::Audio> -- the wire of the relayed audio routes

=item * L<Langertha::Skeid::Protocol::Rerank> -- the wire of the rerank route, and its TEI dialect

=item * L<Langertha::Skeid::KeyBroker::OpenBao> -- upstream keys from OpenBao

=back

=cut

1;
