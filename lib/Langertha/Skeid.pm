package Langertha::Skeid;
our $VERSION = '0.003';
# ABSTRACT: Dynamic routing control-plane for multi-node LLM serving with normalized metrics and cost accounting
use Moo;
use strict;
use warnings;
use Carp qw(croak);
use POSIX qw(strftime);
use Digest::SHA qw(sha1_hex sha256_hex);
use Scalar::Util qw(blessed refaddr reftype);
use Time::HiRes ();
use YAML::PP;
use Langertha ();
use Langertha::Skeid::UsageStore;
use Langertha::Skeid::Protocol;
use Langertha::Skeid::Protocol::Anthropic;
use Langertha::Skeid::Protocol::Ollama;
use Langertha::Usage;
use Langertha::Cost;
use Langertha::Pricing;
use Langertha::UsageRecord;

=head1 SYNOPSIS

  use Langertha::Skeid;

  my $skeid = Langertha::Skeid->new(
    config_file => '/etc/skeid/config.yaml',
  );

  my $cost = $skeid->call_function('metrics.estimate_cost', {
    model => 'gpt-4o-mini',
    usage => { prompt_tokens => 1000, completion_tokens => 200 },
  });

=head1 DESCRIPTION

Langertha::Skeid is a routing control-plane for provider-style LLM operations.
It keeps a live node table, routes by model/health/capacity, and records
normalized token/cost usage.

Skeid is commonly used as one API edge in front of many upstream APIs
(cloud + local). With C<pricing> and C<usage.record/report>, you can build
tenant billing from one consistent ledger.

=head2 Multi-API Billing Flow

1. Define multiple nodes in config (for example OpenAI-compatible cloud APIs
   and local vLLM/SGLang).
2. Set model pricing via C<pricing> or C<pricing.set>.
3. Let tenant identity follow from the API key the caller presents. C<skeid keyid>
   prints the id a given key resolves to. A deployment that authenticates callers
   in front of Skeid can instead pass C<x-skeid-key-id> and set
   C<routing.trust_key_id_header>.
4. Read totals by key/model/time with C<usage.report>.

=head2 Engine IDs

C<nodes[].engine> uses lowercased engine class names from L<Langertha>.
Examples: C<OpenAI =E<gt> openai>, C<OpenAIBase =E<gt> openaibase>,
C<vLLM =E<gt> vllm>. Legacy aliases like C<openai-compatible> are intentionally
rejected.

=head2 Pluggable Usage Storage

The usage storage layer is pluggable.  Built-in backends are C<jsonlog>
(recommended, no DBI required), C<sqlite>, and C<postgresql>.  You can also
replace the storage layer entirely via constructor callbacks or subclass
override.

B<jsonlog backend> (recommended — no DBI dependency):

  # Directory mode: one JSON file per event (no collision risk)
  my $skeid = Langertha::Skeid->new(
    usage_store => { backend => 'jsonlog', path => '/var/log/skeid/events/' },
  );

  # File mode: JSON-lines appended to a single file
  my $skeid = Langertha::Skeid->new(
    usage_store => { backend => 'jsonlog', path => '/var/log/skeid/usage.jsonl', mode => 'file' },
  );

Directory mode is auto-detected when the path is an existing directory or ends
with C</>.  It writes one C<.json> file per event, which avoids file-level
locking and concurrent-write collisions entirely.

B<Constructor callbacks> (custom backend, no subclassing):

  my $skeid = Langertha::Skeid->new(
    store_usage_event => sub {
      my ($self, $event) = @_;
      # $event is a hashref with all normalized usage columns
      publish_to_nats($event);
      return { ok => 1 };
    },
    query_usage_report => sub {
      my ($self, $filters) = @_;
      # $filters has: since, api_key_id, model, limit
      return { ok => 1, enabled => 1, totals => { ... } };
    },
  );

B<Option 2 – Subclass override>:

  package MyApp::Skeid;
  use Moo;
  extends 'Langertha::Skeid';

  sub _store_usage_event {
    my ($self, $event) = @_;
    ...
    return { ok => 1 };
  }

  sub _query_usage_report {
    my ($self, $filters) = @_;
    ...
  }

B<Optional fields.> A streamed request's event also carries C<content_bytes>: the
UTF-8 byte count of the content Skeid relayed (OpenAI face) or translated (Anthropic
and Ollama faces). It is set on every stream, including one whose upstream reported
token counts, and is absent from non-streamed events -- a sink must not assume it is
there. It is an observation, not a billing quantity: Skeid never derives token counts
or cost from it. The DBI stores keep it in a nullable C<content_bytes> column (C<NULL>
for a non-streamed or pre-existing row); C<jsonlog> writes it as part of the event.

When a callback or override is provided, the DBI default is bypassed entirely
and no database connection is created.  DBI and DBD::SQLite are C<recommends>
dependencies — they are not required when usage is handled externally.

=head2 Per-Key Routing Policy

Which nodes a customer key may be served from, and which models it may ask for:

  policies:
    standard:  { deny_tags: [cloud] }        # our own hardware only
    burstable: {}                            # cloud is fine when local is full
  default_policy: standard
  names:
    alice:   k_5f0e1a2b3c4d                   # id from `skeid keyid <key>` -- never the key
    bigcorp: k_9c8b7a6f5e4d
  keys:
    alice: burstable                          # a keys: entry may be written by name ...
    bigcorp:
      policy: standard
      models: [house-model]                  # sparse override of one field
    k_1122334455aa: burstable                 # ... or still by the raw key id

Resolved once at config load: a request costs one hash lookup, keys on the same profile share
one policy object, and a key that takes the default is not listed at all. C<deny_tags> filters
node selection, not just the plan, so a denied node cannot be reached by asking for its own
model name instead of an alias. A refusal is C<403>, never a capacity error.

The optional C<names:> section maps a readable name to a customer key id (karr #17). It makes
C<keys:> entries legible and confines key rotation to a single line -- change the id a name
points at, and every policy line that named the customer follows. Its values are ids from
C<skeid keyid>, never customer keys, so the config still holds no secret; it is read only at
config load and never on the request path.

Identity comes from the API key the caller presented — see L</key_id_for_key>. See also ADR
0008 in the distribution repository.

=head2 Admin API Key

C<admin.api_key> (or C<admin_api_key>) controls access to proxy admin routes.
If empty, admin routes are effectively disabled by returning C<404>. If set,
the proxy expects C<Authorization: Bearer ...>. This value can be changed
through dynamic config reload.

=head2 Provider Manifest

C<GET /.well-known/langertha.json> serves a provider manifest (core's
L<Langertha::Manifest>, schema v1) to a customer key -- listing only the models that key's own
C<keys:> entry names. Nothing is published automatically: the route answers C<404> until the
config turns it on, and a key without a C<manifest:> entry gets C<403>, never the catalog.

  manifest:
    enabled: true
    public_url: https://llm.example.com   # where clients reach Skeid -- never a node URL
    provider_id: example-llm              # default: skeid
    faces: [openai, anthropic, ollama]    # default: all three
    capabilities:                         # optional claims per model; default chat + streaming
      house-model: { tools_native: true, tool_choice_auto: true }
  names:                                  # ids from `skeid keyid <key>` -- never the key
    alice: k_5f0e1a2b3c4d
    bob:   k_9c8b7a6f5e4d
  keys:
    alice:
      policy: burstable
      manifest: { models: [house-model, qwen3-32b] }
    bob:
      manifest: { models: [house-model] }

One endpoint per face, all under C<public_url> and all with one C<api_key> auth entry (the
C<Authorization: Bearer> / C<x-api-key> scheme every face already takes): C<openai>
(C<openai-chat>, C<public_url/v1>), C<anthropic> (C<anthropic-compat> at C<public_url> --
Skeid translates C</v1/messages> to the OpenAI upstream call and does not carry
C<output_config.format>, so structured output takes the synthetic-tool path) and C<ollama>
(C<public_url>). Every listed model appears on every published face. Its capabilities default
to C<chat> and C<streaming>, take the claims declared for it (only flags from
L<Langertha::Manifest::Builder/model_capabilities>), and are then cut per face to what that
face's translator carries upstream -- a claim holds at that endpoint or is not made there. The
lists are L<Langertha::Skeid::Protocol/openai_manifest_endpoint>,
L<Langertha::Skeid::Protocol::Anthropic/manifest_endpoint> and
L<Langertha::Skeid::Protocol::Ollama/manifest_endpoint>.

Resolved at config load, like the routing policy: each key's manifest is built and validated
once and stored under the key id, so a request costs one hash lookup and one key's manifest
cannot be served for another. The load croaks on a model the key's routing policy does not
let it reach (not granted, or served only by nodes it is denied), on an unknown capability,
one no face carries, an unknown face, and an enabled manifest without C<public_url>. A config
that fails to load keeps the previous one in force, manifests included. The route never
reloads the config itself; the request paths that already do pick up a change.
Without a key the route answers C<401>. Needs a Langertha with L<Langertha::Manifest>; on an
older one the route answers C<404>. See ADR 0015 in the distribution repository.

=cut

has nodes => (
  is      => 'rw',
  default => sub { [] },
  # Routing caches derived node lists, so every path that can change the inventory has to
  # invalidate them. The methods below bump the generation explicitly; this trigger catches
  # the remaining one -- somebody assigning the whole list through the public accessor.
  trigger => sub { $_[0]->_bump_inventory },
);

has model_pricing => (
  is      => 'rw',
  default => sub { {} },
);

has model_aliases => (
  is      => 'rw',
  default => sub { {} },
);

has policies => (
  is      => 'rw',
  default => sub { {} },
);

has default_policy => (
  is      => 'rw',
  default => sub { undef },
);

# Key id -> resolved policy. Identical resolutions share one object, and a key that takes the
# default is not listed at all, so ten thousand identical customers cost nothing here.
has key_policies => (
  is      => 'rw',
  default => sub { {} },
);

# Readable name -> customer key id, from the config `names:` section. A config-authoring
# convenience only: it lets `keys:` entries be written by name and localises key rotation to
# one line, and is resolved to key ids once at config load. It never reaches the request path
# -- a request still carries a derived key id, and policy_for_key still costs one hash lookup.
has key_names => (
  is      => 'rw',
  default => sub { {} },
);

# /.well-known/langertha.json (skeid #29, ADR 0015). Off until the config enables it.
has manifest_enabled => (
  is      => 'rw',
  default => sub { 0 },
);

# Whether this Langertha has Langertha::Manifest (core newer than 0.503). Enabled without it,
# the route answers 404 rather than failing the config.
has manifest_available => (
  is      => 'rw',
  default => sub { 0 },
);

# Key id -> the canonical JSON of that key's manifest, built at config load. This is the
# manifest cache, and it is keyed by the key id the caller's key derives to: a customer can
# only ever be served the entry built from its own keys: line, never another key's catalog.
has key_manifests => (
  is      => 'rw',
  default => sub { {} },
);

# Whether x-skeid-key-id / x-api-key-id from the client may name the customer. Off by default:
# once a policy hangs off the key id, believing that header lets any client pick its own
# permissions in one line. Turn it on only when something in front of Skeid authenticates the
# caller and sets the header itself.
has trust_key_id_header => (
  is      => 'rw',
  default => sub {
    return (defined($ENV{SKEID_TRUST_KEY_ID_HEADER}) && $ENV{SKEID_TRUST_KEY_ID_HEADER} =~ /^(1|true|yes|on)$/i)
      ? 1 : 0;
  },
);

has route_wait_timeout_ms => (
  is      => 'rw',
  default => sub {
    return (defined($ENV{SKEID_ROUTE_WAIT_TIMEOUT_MS}) && length($ENV{SKEID_ROUTE_WAIT_TIMEOUT_MS}))
      ? 0 + $ENV{SKEID_ROUTE_WAIT_TIMEOUT_MS}
      : 2000;
  },
);

has route_wait_poll_ms => (
  is      => 'rw',
  default => sub {
    return (defined($ENV{SKEID_ROUTE_WAIT_POLL_MS}) && length($ENV{SKEID_ROUTE_WAIT_POLL_MS}))
      ? 0 + $ENV{SKEID_ROUTE_WAIT_POLL_MS}
      : 25;
  },
);

has usage_db_path => (
  is        => 'rw',
  predicate => 'has_usage_db_path',
  clearer   => 'clear_usage_db_path',
  default   => sub {
    return (defined($ENV{SKEID_USAGE_DB}) && length($ENV{SKEID_USAGE_DB}))
      ? $ENV{SKEID_USAGE_DB}
      : undef;
  },
);

has usage_store => (
  is      => 'rw',
  default => sub { {} },
);

has store_usage_event => (
  is        => 'ro',
  predicate => 'has_store_usage_event',
);

has query_usage_report => (
  is        => 'ro',
  predicate => 'has_query_usage_report',
);

has admin_api_key => (
  is      => 'rw',
  default => sub {
    return (defined($ENV{SKEID_ADMIN_API_KEY}) && length($ENV{SKEID_ADMIN_API_KEY}))
      ? $ENV{SKEID_ADMIN_API_KEY}
      : '';
  },
);

has key_broker => (is => 'ro', predicate => 'has_key_broker');

has config_file => (
  is        => 'ro',
  predicate => 'has_config_file',
);

=attr config_loader

A code ref that returns the config as a hashref, instead of a C<config_file>. It is called with
the Skeid object, at construction and then from C<call_function> at most once per
L</config_reload_interval>.

It may return C<($config, $version)>. A defined version is the change detector: the same
version as last applied means nothing changed and the config is not applied again. Without a
version Skeid digests the returned structure (hash keys sorted) instead. Either way an
unchanged config is a no-op, and a changed one whose C<nodes> section is unchanged keeps the
node list -- its inventory generation, its running capacity probes and any health set through
the admin API. A code ref inside the config (a custom probe's C<code>) digests by identity, so
a loader that builds a fresh closure every call should return a version.

A config file follows the same rules, minus the throttle: an mtime change whose content is
unchanged applies nothing. An explicit C<config.reload> does too, so a value taken from the
environment (C<admin.api_key_env>, a usage store's C<password_env>) is read again only when the
config itself changes.

=cut

has config_loader => (
  is        => 'ro',
  predicate => 'has_config_loader',
);

has _config_mtime => (
  is      => 'rw',
  default => sub { undef },
);

=attr config_reload_interval

The least time, in seconds, between two runs of a C<config_loader> (default 1; fractions
allowed; 0 runs it on every dispatch, as before skeid #38).

A loader-based config is re-read from C<call_function>, which every request passes through
several times. Without a throttle every request would rerun the loader. A config file is not
throttled: its mtime check is one C<stat>.

=cut

has config_reload_interval => (
  is      => 'rw',
  default => sub {
    return (defined($ENV{SKEID_CONFIG_RELOAD_INTERVAL}) && length($ENV{SKEID_CONFIG_RELOAD_INTERVAL}))
      ? 0 + $ENV{SKEID_CONFIG_RELOAD_INTERVAL}
      : 1;
  },
);

# When the loader may run next (see config_reload_interval).
has _config_next_check_at => (
  is      => 'rw',
  default => sub { undef },
);

# What the last applied config was: the loader's version when it gives one, else a digest of
# the loaded structure. A reload that reads the same fingerprint changes nothing (skeid #38).
has _config_fingerprint => (
  is      => 'rw',
  default => sub { undef },
);

# Digest of the nodes section the node list was last built from. An unchanged section keeps
# the node list -- and with it the inventory generation, the running probes and any health an
# admin set -- even when another section of the config changed.
has _nodes_fingerprint => (
  is      => 'rw',
  default => sub { undef },
);

has _rr_cursor => (
  is      => 'rw',
  default => sub { {} },
);

has _inventory_generation => (
  is      => 'rw',
  default => sub { 0 },
);

has _route_cache => (
  is      => 'rw',
  default => sub { { generation => -1, entries => {} } },
);

has _inflight => (
  is      => 'rw',
  default => sub { {} },
);

# node_id => normalized capacity reading (see set_capacity_reading). Written by probes off the
# request path, read by admission.
has _capacity => (
  is      => 'rw',
  default => sub { {} },
);

=attr capacity_max_age_ms

How long a capacity reading is trusted, in milliseconds (default 5000, 0 disables expiry).

A stale reading is worse than none: it describes a node as it was, and admission acts on it as
if it were now. Past this age a reading is ignored and C<inflight> decides again, which is the
same behaviour as having configured no probe at all (ADR 0009).

=cut

has capacity_max_age_ms => (
  is      => 'rw',
  default => sub {
    return (defined($ENV{SKEID_CAPACITY_MAX_AGE_MS}) && length($ENV{SKEID_CAPACITY_MAX_AGE_MS}))
      ? 0 + $ENV{SKEID_CAPACITY_MAX_AGE_MS}
      : 5000;
  },
);

=attr worker_count

How many worker processes share this configuration (default 1).

C<inflight> and C<max_conns> are per-process, so N workers would each admit up to C<max_conns>
to a node that can only serve one number — C<max_conns: 8> across 4 workers would permit 32,
silently. Setting this makes each worker take its share instead (ADR 0010). Anything on a timer
is spread the same way, so the process group's aggregate poll rate stays what was configured.

=cut

has worker_count => (
  is      => 'rw',
  default => sub { 1 },
  trigger => sub { $_[0]->_bump_inventory },
);

=attr frontend_count

How many separate Skeid frontends stand in front of one node (default 1).

C<worker_count> partitions C<max_conns> across the prefork workers of one process; this
partitions it across the distinct Skeid hosts sharing a node — a number only the operator
knows, because two frontends are two processes on two machines with nothing between them to
count each other's C<inflight> (there is no probe and no shared state; that absence is the
whole reason this has to be declared rather than detected). With F frontends each admits its
share C<max_conns/F>, so the group as a whole never admits more than the node was configured
for (ADR 0009, ADR 0012).

It composes with C<worker_count>: the two divisors multiply, so one worker's share is
C<max_conns/(F*N)> — partitioned across frontends first, then across workers, which integer
division makes the same thing either way. Unlike the worker divisor it does not scale anything
on a timer: separate frontends each run their own probes and hold their own vault token, the
same reason vault renewal is not scaled per worker (ADR 0010).

Explicit and opt-in: the default 1 is today's behaviour, unchanged. An operator who runs two
frontends and forgets to say so over-admits the node by a factor of two, silently — which is
exactly the failure this field exists to prevent.

=cut

has frontend_count => (
  is      => 'rw',
  default => sub {
    return (defined($ENV{SKEID_FRONTEND_COUNT}) && length($ENV{SKEID_FRONTEND_COUNT}))
      ? 0 + $ENV{SKEID_FRONTEND_COUNT}
      : 1;
  },
);

has _stats => (
  is      => 'rw',
  default => sub { {} },
);

has _usage_store_obj => (
  is      => 'rw',
  default => sub { undef },
);

my %FALLBACK_ENGINE_IDS = map { $_ => 1 } qw(
  aki
  akiopenai
  anthropic
  anthropicbase
  cerebras
  deepseek
  gemini
  groq
  huggingface
  lmstudio
  lmstudioanthropic
  lmstudioopenai
  llamacpp
  minimax
  mistral
  nousresearch
  ollama
  ollamaopenai
  openai
  openaibase
  openrouter
  perplexity
  remote
  replicate
  sglang
  vllm
  whisper
);

sub BUILD {
  my ($self) = @_;
  if ($self->has_config_loader || $self->has_config_file) {
    $self->reload_config;
  }
  if (ref($self->usage_store) eq 'HASH' && keys %{$self->usage_store}) {
    $self->_configure_usage_store($self->usage_store);
  } else {
    my $path = $self->usage_db_path;
    if (defined $path && length $path) {
      $self->_set_usage_db_path($path);
    }
  }
}

sub add_node {
  my ($self, %node) = @_;
  my $id  = $node{id}  // croak 'node id required';
  my $url = $node{url} // croak 'node url required';

  $self->remove_node($id);
  push @{$self->nodes}, {
    id          => $id,
    url         => $url,
    model       => ($node{model} // ''),
    engine      => $self->normalize_engine_id((defined($node{engine}) && length($node{engine})) ? $node{engine} : 'OpenAIBase'),
    weight      => (defined $node{weight} ? 0 + $node{weight} : 1),
    max_conns   => (defined $node{max_conns} ? 0 + $node{max_conns} : 0),
    healthy     => (exists $node{healthy} ? ($node{healthy} ? 1 : 0) : 1),
    tags        => $self->normalize_tags($node{tags}),
    metadata    => (ref($node{metadata}) eq 'HASH' ? $node{metadata} : {}),
    (defined($node{api_key_env}) && length($node{api_key_env})
      ? (api_key_env => "$node{api_key_env}")
      : ()),
    (defined($node{api_key_ref}) && length($node{api_key_ref})
      ? (api_key_ref => "$node{api_key_ref}")
      : ()),
    # How this node's capacity is found (ADR 0009). Absent means inflight, which is every
    # deployment that existed before probes did.
    (ref($node{capacity}) eq 'HASH' ? (capacity => { %{$node{capacity}} }) : ()),
  };
  $self->_bump_inventory;
  return 1;
}

sub remove_node {
  my ($self, $id) = @_;
  return 0 unless defined $id && length $id;
  my @keep = grep { ($_->{id} // '') ne $id } @{$self->nodes};
  my $removed = @{$self->nodes} - @keep;
  $self->nodes(\@keep);
  # Or a node re-added under the same id inherits a reading about a different machine.
  $self->forget_capacity($id) if $removed;
  return $removed ? 1 : 0;
}

sub _bump_inventory {
  my ($self) = @_;
  # Defensive //0: the nodes trigger can fire during construction, before this attribute's own
  # default has been assigned.
  $self->_inventory_generation(($self->_inventory_generation // 0) + 1);
  return;
}

=method normalize_tags

  my $tags = Langertha::Skeid->normalize_tags(['Local', 'gb10']);
  my $tags = Langertha::Skeid->normalize_tags('local, gb10');

Tags are lowercased, trimmed, de-duplicated and kept in the order first seen. A plain string is
accepted and split on commas or whitespace, because a hand-written config says
C<tags: local, gb10> at least as often as it says a YAML list.

=cut

sub normalize_tags {
  my ($self, $value) = @_;
  return [] unless defined $value;

  my @raw = ref($value) eq 'ARRAY' ? @$value : split(/[,\s]+/, "$value");
  my (@tags, %seen);
  for my $tag (@raw) {
    next unless defined $tag;
    my $clean = lc "$tag";
    $clean =~ s/\A\s+//;
    $clean =~ s/\s+\z//;
    next unless length $clean;
    next if $seen{$clean}++;
    push @tags, $clean;
  }
  return \@tags;
}

sub list_nodes {
  my ($self) = @_;
  return [ map { +{%$_} } @{$self->nodes} ];
}

sub set_node_health {
  my ($self, $id, $healthy) = @_;
  return 0 unless defined $id && length $id;
  my $found = 0;
  for my $n (@{$self->nodes}) {
    next unless ($n->{id} // '') eq $id;
    $n->{healthy} = $healthy ? 1 : 0;
    $found = 1;
    last;
  }
  # Health is part of eligibility, so flipping it has to drop the derived lists -- otherwise a
  # node taken out of rotation keeps receiving traffic until something else changes.
  $self->_bump_inventory if $found;
  return $found;
}

sub set_model_pricing {
  my ($self, $model, $pricing) = @_;
  croak 'model required' unless defined $model && length $model;
  croak 'pricing hash required' unless ref($pricing) eq 'HASH';
  $self->model_pricing->{$model} = {
    input_per_million  => 0 + ($pricing->{input_per_million}  // 0),
    output_per_million => 0 + ($pricing->{output_per_million} // 0),
  };
  return $self->model_pricing->{$model};
}

sub pricing_for_model {
  my ($self, $model) = @_;
  return $self->model_pricing->{$model}
    || $self->model_pricing->{'*'}
    || { input_per_million => 0, output_per_million => 0 };
}

# The config state a reload replaces. A reload is all or nothing (skeid #29 review): a
# config that fails anywhere -- a bad policy, alias or manifest grant -- must not leave the
# sections before it applied and the ones after it not, which served every customer a 403
# from an emptied manifest map while routing already ran on the new policies.
my @CONFIG_STATE = qw(
  model_aliases policies default_policy key_policies key_names nodes
  route_wait_timeout_ms route_wait_poll_ms trust_key_id_header frontend_count admin_api_key
  manifest_enabled manifest_available key_manifests
);

sub reload_config {
  my ($self) = @_;
  my ($cfg, $fingerprint) = $self->_read_config;

  # Same config as last applied: nothing to do. Rebuilding would replace the node list, which
  # bumps the inventory generation, restarts every capacity probe and forgets health an admin
  # set -- for a config that did not change (skeid #38).
  my $last = $self->_config_fingerprint;
  return $cfg if defined($last) && $last eq $fingerprint;

  my %before = map { $_ => $self->$_ } @CONFIG_STATE;
  my %pricing = %{$self->model_pricing || {}};
  my ($generation, $route_cache) = ($self->_inventory_generation, $self->_route_cache);

  my $nodes_print;
  if (eval { $nodes_print = $self->_apply_config($cfg); 1 }) {
    $self->_config_fingerprint($fingerprint);
    $self->_nodes_fingerprint($nodes_print);
    return $cfg;
  }

  my $err = $@ || 'config reload failed';
  for my $attr (@CONFIG_STATE) {
    next if $attr eq 'nodes';
    $self->$attr($before{$attr});
  }
  $self->model_pricing(\%pricing);
  # Setting nodes bumps the inventory generation, which restarts the capacity probes. The old
  # list comes back unchanged (the failed load only built a new array), so its generation and
  # the route cache derived from it come back with it: an inventory that did not change must
  # not look changed.
  if ($self->nodes != $before{nodes}) {
    $self->nodes($before{nodes});
    $self->_inventory_generation($generation);
    $self->_route_cache($route_cache);
  }
  die $err;
}

# Reads the config source: the loader's answer or the parsed file, plus its fingerprint. A
# loader may return ($config, $version); a defined version is the fingerprint, otherwise it is
# a digest of the structure (see _config_digest).
sub _read_config {
  my ($self) = @_;
  my $cfg = {};
  my $version;

  if ($self->has_config_loader) {
    # Counted from the start of the run, so the throttle also holds for a loader that dies.
    $self->_config_next_check_at($self->_now + (0 + ($self->config_reload_interval // 0)));
    my ($loaded, $loader_version) = $self->config_loader->($self);
    $cfg = $loaded if ref($loaded) eq 'HASH';
    $version = $loader_version;
  } elsif ($self->has_config_file) {
    my $file = $self->config_file;
    if (-f $file) {
      my $ypp = YAML::PP->new;
      my $loaded = $ypp->load_file($file);
      $cfg = $loaded if ref($loaded) eq 'HASH';
      $self->_config_mtime((stat($file))[9] || time);
    }
  }

  my $fingerprint = defined($version) && !ref($version)
    ? "version:$version"
    : 'digest:' . _config_digest($cfg);
  return ($cfg, $fingerprint);
}

# A canonical digest of a loaded config structure: hash keys sorted, so two loads of the same
# data digest alike whatever order the loader built them in. A code ref or an object other
# than a boolean digests by identity -- the same callback digests alike, a fresh closure per
# load counts as a change, which reloads rather than missing one.
sub _config_digest {
  my ($data) = @_;
  my $out = '';
  my $walk;
  $walk = sub {
    my ($node) = @_;
    if (!defined $node) {
      $out .= 'u;';
    } elsif (!ref $node) {
      $out .= 's' . length($node) . ':' . $node . ';';
    } elsif (blessed($node) && reftype($node) eq 'SCALAR') {
      # JSON / YAML booleans: their value is what counts, not which object carries it.
      $out .= 'b' . (${$node} ? 1 : 0) . ';';
    } elsif (!blessed($node) && reftype($node) eq 'HASH') {
      $out .= 'h{';
      for my $key (sort keys %$node) {
        $out .= 's' . length($key) . ':' . $key . ';';
        $walk->($node->{$key});
      }
      $out .= '}';
    } elsif (!blessed($node) && reftype($node) eq 'ARRAY') {
      $out .= 'a[';
      $walk->($_) for @$node;
      $out .= ']';
    } else {
      $out .= 'r' . reftype($node) . ':' . refaddr($node) . ';';
    }
  };
  $walk->($data);
  undef $walk;
  return sha256_hex($out);
}

# Applies a config to $self, section by section; reload_config undoes it on a croak. The usage
# store goes last and swaps only once the new store is prepared, so nothing after it can fail.
# Returns the fingerprint of the nodes section the node list now stands for.
sub _apply_config {
  my ($self, $cfg) = @_;

  if (ref($cfg->{pricing}) eq 'HASH') {
    for my $model (keys %{$cfg->{pricing}}) {
      my $p = $cfg->{pricing}{$model};
      next unless ref($p) eq 'HASH';
      $self->set_model_pricing($model, $p);
    }
  }

  if (ref($cfg->{policies}) eq 'HASH' || exists $cfg->{default_policy}
      || ref($cfg->{keys}) eq 'HASH' || ref($cfg->{names}) eq 'HASH') {
    $self->_load_policies($cfg);
  }

  if (ref($cfg->{aliases}) eq 'HASH') {
    # Replaced wholesale, like nodes: the file is the declared state.
    $self->model_aliases({});
    for my $name (keys %{$cfg->{aliases}}) {
      $self->set_model_alias($name, $cfg->{aliases}{$name});
    }
  }

  my $nodes_print = $self->_nodes_fingerprint // '';
  if (ref($cfg->{nodes}) eq 'ARRAY') {
    # An unchanged nodes section keeps the node list as it is (skeid #38).
    my $print = _config_digest($cfg->{nodes});
    if ($print ne $nodes_print) {
      $self->nodes([]);
      for my $n (@{$cfg->{nodes}}) {
        next unless ref($n) eq 'HASH';
        next unless defined $n->{id} && defined $n->{url};
        $self->add_node(%$n);
      }
      $nodes_print = $print;
    }
  }

  if (ref($cfg->{routing}) eq 'HASH') {
    if (defined $cfg->{routing}{wait_timeout_ms}) {
      $self->route_wait_timeout_ms(0 + $cfg->{routing}{wait_timeout_ms});
    }
    if (defined $cfg->{routing}{wait_poll_ms}) {
      my $poll = 0 + $cfg->{routing}{wait_poll_ms};
      $poll = 1 if $poll < 1;
      $self->route_wait_poll_ms($poll);
    }
    if (defined $cfg->{routing}{trust_key_id_header}) {
      $self->trust_key_id_header($cfg->{routing}{trust_key_id_header} =~ /^(1|true|yes|on)$/i ? 1 : 0);
    }
    if (defined $cfg->{routing}{frontend_count}) {
      # How many Skeid hosts share the nodes. Only the config knows it -- there is nothing to
      # detect -- and forgetting it over-admits every node by that factor (ADR 0012). Floor at
      # one, so a stray 0 falls back to today's single-frontend behaviour instead of dividing
      # max_conns to nothing.
      my $frontends = int(0 + $cfg->{routing}{frontend_count});
      $frontends = 1 if $frontends < 1;
      $self->frontend_count($frontends);
    }
  }

  # The admin key may be named directly or handed over by environment variable, the same way
  # usage_store takes password_env -- a deployment should not have to write the key into a
  # file that gets mounted into a container.
  if (exists $cfg->{admin_api_key}) {
    $self->admin_api_key(defined($cfg->{admin_api_key}) ? "$cfg->{admin_api_key}" : '');
  } elsif (defined $cfg->{admin_api_key_env}) {
    $self->admin_api_key($ENV{$cfg->{admin_api_key_env}} // '');
  } elsif (ref($cfg->{admin}) eq 'HASH') {
    my $admin = $cfg->{admin};
    if (exists $admin->{api_key}) {
      $self->admin_api_key(defined($admin->{api_key}) ? "$admin->{api_key}" : '');
    } elsif (defined $admin->{api_key_env}) {
      $self->admin_api_key($ENV{$admin->{api_key_env}} // '');
    } else {
      $self->admin_api_key('');
    }
  } elsif ($self->has_config_loader || $self->has_config_file) {
    # Config-managed mode: absent key means admin API is disabled.
    $self->admin_api_key('');
  }

  # Last: a key's manifest is checked against its routing policy and the aliases.
  $self->_load_manifest($cfg);

  my $usage_cfg = $cfg->{usage_store};
  if (ref($usage_cfg) eq 'HASH') {
    $self->_configure_usage_store($usage_cfg);
  } elsif (exists $cfg->{usage_db_path}) {
    $self->_configure_usage_store({
      backend     => 'sqlite',
      sqlite_path => $cfg->{usage_db_path},
    });
  }

  return $nodes_print;
}

sub maybe_reload_config {
  my ($self) = @_;

  if ($self->has_config_loader && !$self->has_config_file) {
    # Loader-based configs are dynamic, but not re-read more often than
    # config_reload_interval, and a load that reads what was already applied is a no-op.
    my $now  = $self->_now;
    my $next = $self->_config_next_check_at;
    return 0 if defined($next) && $now < $next;
    my $before = $self->_config_fingerprint // '';
    $self->reload_config;
    return (($self->_config_fingerprint // '') ne $before) ? 1 : 0;
  }

  return 0 unless $self->has_config_file;
  my $file = $self->config_file;
  return 0 unless -f $file;

  my $mtime = (stat($file))[9] || 0;
  my $last  = $self->_config_mtime;
  if (!defined($last) || $mtime > $last) {
    my $before = $self->_config_fingerprint // '';
    $self->reload_config;
    return (($self->_config_fingerprint // '') ne $before) ? 1 : 0;
  }
  return 0;
}

sub _now { Time::HiRes::time() }

# The client-facing faces Skeid serves, as manifest endpoints. Each face's spec -- dialect,
# path under public_url, and the capability flags its translator actually carries upstream --
# lives with that face's translator (ADR 0001: format-specific facts stay in the translator).
my %MANIFEST_FACES = (
  openai    => sub { Langertha::Skeid::Protocol->openai_manifest_endpoint },
  anthropic => sub { Langertha::Skeid::Protocol::Anthropic->manifest_endpoint },
  ollama    => sub { Langertha::Skeid::Protocol::Ollama->manifest_endpoint },
);
my @MANIFEST_FACE_ORDER = qw(openai anthropic ollama);
my $manifest_unavailable_warned;

sub _is_true {
  my ($value) = @_;
  return (defined($value) && "$value" =~ /^(1|true|yes|on)$/i) ? 1 : 0;
}

# Resolves the manifest section and every key's manifest: grant once, at config load (ADR
# 0015). Nothing is published that a keys: entry does not list, and what is listed has to be
# something that key's routing policy lets it reach -- a contradiction is a load error, not a
# manifest that promises a model the request path then refuses with 403. Everything is built
# into lexicals and set together at the end; reload_config restores the old state on a croak.
sub _load_manifest {
  my ($self, $cfg) = @_;
  my ($enabled, $available, %manifests) = (0, 0);
  my $commit = sub {
    $self->manifest_enabled($enabled);
    $self->manifest_available($available);
    $self->key_manifests({%manifests});
    return 1;
  };

  my %grants;
  if (ref($cfg->{keys}) eq 'HASH') {
    for my $label (sort keys %{$cfg->{keys}}) {
      my $entry = $cfg->{keys}{$label};
      next unless ref($entry) eq 'HASH' && exists $entry->{manifest};
      my $grant = $entry->{manifest};
      croak "key '$label': manifest must be a hashref with a models list"
        unless ref($grant) eq 'HASH' && ref($grant->{models}) eq 'ARRAY';
      my (%seen, @models);
      for my $model (@{$grant->{models}}) {
        croak "key '$label': manifest models must be non-empty model names"
          unless defined($model) && !ref($model) && length($model);
        push @models, "$model" unless $seen{$model}++;
      }
      my $id = $self->key_names->{$label} // $label;
      $grants{$id} = { label => $label, models => \@models };
    }
  }

  my $section = $cfg->{manifest};
  return $commit->() unless defined $section;
  croak 'manifest must be a hashref' unless ref($section) eq 'HASH';
  return $commit->() unless _is_true($section->{enabled});

  my $public_url = $section->{public_url};
  croak 'manifest.public_url is required when the manifest is enabled: the URL clients reach '
    . 'Skeid at, never a node URL'
    unless defined($public_url) && !ref($public_url) && length($public_url);
  $public_url =~ s{/+\z}{};
  my ($issuer) = $public_url =~ m{\A([A-Za-z][A-Za-z0-9+.-]*://[^/?#]+)};
  croak "manifest.public_url must be an absolute http(s) URL, got '$public_url'" unless $issuer;

  my $provider_id = $section->{provider_id} // 'skeid';

  my @faces = @MANIFEST_FACE_ORDER;
  if (defined $section->{faces}) {
    croak 'manifest.faces must be a list' unless ref($section->{faces}) eq 'ARRAY';
    my %want;
    for my $face (@{$section->{faces}}) {
      croak "manifest.faces: unknown face '" . ($face // '') . "' (known: @MANIFEST_FACE_ORDER)"
        unless defined($face) && !ref($face) && $MANIFEST_FACES{$face};
      $want{$face} = 1;
    }
    @faces = grep { $want{$_} } @MANIFEST_FACE_ORDER;
    croak 'manifest.faces must name at least one face' unless @faces;
  }
  my %spec = map { $_ => $MANIFEST_FACES{$_}->() } @MANIFEST_FACE_ORDER;

  my $declared = $section->{capabilities} // {};
  croak 'manifest.capabilities must map model names to capability hashes'
    unless ref($declared) eq 'HASH' && !grep { ref($_) ne 'HASH' } values %$declared;

  $enabled = 1;

  # Core's manifest (Langertha::Manifest, ADR 0029) is newer than the released Langertha this
  # dist requires. Without it the route answers 404; the config is still loaded.
  unless (eval { require Langertha::Manifest::Builder; 1 }) {
    warn "skeid: manifest is enabled, but this Langertha has no Langertha::Manifest; "
      . "/.well-known/langertha.json answers 404\n"
      unless $manifest_unavailable_warned++;
    return $commit->();
  }

  # A claim no face of Skeid carries could never be published; saying so beats dropping it.
  my %allowed = map { $_ => 1 } Langertha::Manifest::Builder->model_capabilities;
  my %carried = map { $_ => 1 } map { @{$spec{$_}{capabilities}} } @MANIFEST_FACE_ORDER;
  for my $model (sort keys %$declared) {
    for my $flag (sort keys %{$declared->{$model}}) {
      croak "manifest.capabilities.$model: '$flag' is not a model capability a manifest may "
        . 'claim (see Langertha::Manifest::Builder->model_capabilities)'
        unless $allowed{$flag};
      croak "manifest.capabilities.$model: '$flag' is not carried by any face Skeid serves"
        unless $carried{$flag};
    }
  }

  for my $id (sort keys %grants) {
    my $grant = $grants{$id};
    for my $model (@{$grant->{models}}) {
      croak "key '$grant->{label}': manifest lists model '$model', which its routing policy "
        . 'does not let it reach'
        unless $self->_manifest_model_reachable($model, $id);
    }
    my $json = eval {
      my $builder = Langertha::Manifest::Builder->new(
        provider_id => $provider_id,
        issuer      => $issuer,
      );
      $builder->add_auth(id => 'api', type => 'api_key');
      for my $face (@faces) {
        my $face_spec = $spec{$face};
        my %face_carries = map { $_ => 1 } @{$face_spec->{capabilities}};
        $builder->add_endpoint(
          id       => $face,
          dialect  => $face_spec->{dialect},
          base_url => $public_url . $face_spec->{path},
          auth_ref => 'api',
        );
        for my $model (@{$grant->{models}}) {
          # Declared claims over the chat + streaming default, then cut to what this face's
          # translator carries: a claim holds "at that endpoint" (core ADR 0029) or not at all.
          my %caps = (chat => 1, streaming => 1);
          my $claims = $declared->{$model} || {};
          for my $flag (keys %$claims) {
            if (_is_true($claims->{$flag})) { $caps{$flag} = 1 } else { delete $caps{$flag} }
          }
          delete $caps{$_} for grep { !$face_carries{$_} } keys %caps;
          $builder->add_model(id => $model, endpoint_ref => $face, capabilities => \%caps);
        }
      }
      $builder->manifest->to_json;
    };
    unless (defined $json) {
      (my $err = $@) =~ s/\s+at \S+ line \d+\.?\s*\z//s;
      croak "key '$grant->{label}': manifest does not validate: $err";
    }
    $manifests{$id} = $json;
  }

  $available = 1;
  return $commit->();
}

# Whether the key could be routed to the model at all: its policy grants the name, and some
# node a permitted tier selects -- deny_tags applied, health ignored (a manifest is a claim,
# not a probe) -- serves it. A raw node model behind a denied tag is as unreachable as an alias
# the policy leaves out (ADR 0008), so it is not published either.
sub _manifest_model_reachable {
  my ($self, $model, $api_key_id) = @_;
  my $plan = $self->route_plan(model => $model, api_key_id => $api_key_id);
  return 0 unless $plan->{permitted};
  for my $tier (@{$plan->{tiers}}) {
    for my $node (@{$self->select_nodes(tags => $tier->{tags}, deny_tags => $tier->{deny_tags})}) {
      my $served = $node->{model};
      return 1 if !defined($served) || !length($served) || $served eq $tier->{model};
    }
  }
  return 0;
}

=method manifest_for_key

  my $json = $skeid->manifest_for_key($api_key_id);   # UTF-8 JSON bytes, or undef

The provider manifest published to a customer key id, as canonical JSON, or undef when the
key has no C<manifest:> grant, the manifest is disabled, or this Langertha has no
L<Langertha::Manifest>. Built at config load; see L</Provider Manifest>.

=cut

sub manifest_for_key {
  my ($self, $api_key_id) = @_;
  return undef unless $self->manifest_enabled && $self->manifest_available;
  return undef unless defined($api_key_id) && length($api_key_id);
  return $self->key_manifests->{$api_key_id};
}

sub configure_usage_store {
  my ($self, $cfg) = @_;
  return $self->_configure_usage_store($cfg);
}


sub _configure_usage_store {
  my ($self, $cfg) = @_;
  my $normalized = Langertha::Skeid::UsageStore->normalize_config(
    $cfg,
    default_sqlite_path => ($self->has_usage_db_path ? $self->usage_db_path : undef),
  );

  my $old = $self->usage_store || {};
  my $same = ref($old) eq 'HASH'
    && (($old->{backend} // '') eq ($normalized->{backend} // ''))
    && (($old->{dsn} // '') eq ($normalized->{dsn} // ''))
    && (($old->{path} // '') eq ($normalized->{path} // ''))
    && (($old->{mode} // '') eq ($normalized->{mode} // ''))
    && (($old->{user} // '') eq ($normalized->{user} // ''))
    && (($old->{password} // '') eq ($normalized->{password} // ''))
    && (($old->{schema_file} // '') eq ($normalized->{schema_file} // ''))
    && ((($old->{auto_migrate} // 1) ? 1 : 0) == (($normalized->{auto_migrate} // 1) ? 1 : 0));

  # Rebuild when the config changed, and also when there simply is no store object yet:
  # BUILD hands us the caller's raw config as $old, which can compare equal to its own
  # normalized form and would otherwise leave the store unbuilt.
  my $changed = $same ? 0 : 1;
  if ($changed || !$self->_usage_store_obj) {
    # Prepare the new store before letting go of the old one: a store that fails to come up
    # fails the reload with the old store still connected (reload_config is all or nothing).
    my $store = Langertha::Skeid::UsageStore->for_config($normalized);
    $store->prepare if $store;
    $self->_disconnect_usage_store;
    $self->usage_store($normalized);
    $self->_usage_store_obj($store);
  }

  if ($normalized->{backend} eq 'sqlite') {
    $self->usage_db_path($normalized->{path});
  } elsif ($normalized->{backend} ne 'jsonlog') {
    $self->clear_usage_db_path if $self->has_usage_db_path;
  }

  return $self->usage_store;
}
sub _set_usage_db_path {
  my ($self, $path) = @_;
  return $self->_configure_usage_store({
    backend     => 'sqlite',
    sqlite_path => $path,
  });
}


sub _num {
  my ($v) = @_;
  return 0 unless defined $v;
  return 0 + $v;
}

sub _iso8601_now {
  return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
}

sub _discover_engine_ids {
  my %ids = %FALLBACK_ENGINE_IDS;
  if (Langertha->can('available_engine_ids')) {
    my $found = eval { Langertha->available_engine_ids };
    if (!$@ && ref($found) eq 'ARRAY') {
      for my $id (@$found) {
        next unless defined $id && length $id;
        $ids{lc $id} = 1;
      }
    }
  }

  return \%ids;
}

sub supported_engine_ids {
  my ($self) = @_;
  my $ids = _discover_engine_ids();
  return [ sort keys %$ids ];
}

sub normalize_engine_id {
  my ($self, $value) = @_;
  return '' unless defined $value;

  my $raw = "$value";
  $raw =~ s/^\s+//;
  $raw =~ s/\s+$//;
  return '' unless length $raw;

  my $id = lc($raw);
  $id =~ s/\Alangertha::engine:://;
  $id =~ s/\Alangerthax::engine:://;

  my $ids = _discover_engine_ids();
  return $id if $ids->{$id};

  my $known = join(', ', sort keys %$ids);
  croak "unknown engine '$raw' (expected one of: $known)";
}

sub record_usage {
  my ($self, %args) = @_;

  # Disabled fast path: with no sink at all, the event has nowhere to go, so
  # skip building it. record_usage runs once per forwarded request, and a
  # deployment that meters nothing should not pay for a normalized event it is
  # only going to throw away in _store_usage_event. (karr #15)
  return { ok => 0, error => 'usage_store not configured' }
    unless $self->_has_usage_sink;

  my $metrics = ref($args{metrics}) eq 'HASH' ? $args{metrics} : {};
  my $usage = ref($metrics->{usage}) eq 'HASH' ? $metrics->{usage} : {};
  my $tool_calls = ref($metrics->{tool_names}) eq 'ARRAY'
    ? scalar(@{$metrics->{tool_names}})
    : _num($metrics->{tool_calls});
  my $input_tokens  = _num($usage->{input}) || _num($usage->{prompt_tokens}) || _num($metrics->{input_tokens});
  my $output_tokens = _num($usage->{output}) || _num($usage->{completion_tokens}) || _num($metrics->{output_tokens});
  my $total_tokens  = _num($usage->{total}) || _num($metrics->{total_tokens}) || ($input_tokens + $output_tokens);
  # Prompt-cache read count (k27). Read the same way as the token counts above: the normalized
  # name first, then the OpenAI wire spelling (nested under prompt_tokens_details on a real
  # OpenAI usage payload), then a flat cached_tokens some compatible servers use, then the
  # flattened metrics fallback. Recording only -- Langertha::Pricing 0.503 has no cache-discount
  # rate, so cost below is unchanged and cached tokens still bill at the normal rate (ADR 0013).
  my $cached_tokens = _num($usage->{cached})
    || _num($usage->{cached_tokens})
    || _num(ref($usage->{prompt_tokens_details}) eq 'HASH' ? $usage->{prompt_tokens_details}{cached_tokens} : undef)
    || _num($metrics->{cached_tokens});
  my $cost_input    = _num($metrics->{cost_input_usd}) || _num($metrics->{input_cost_usd});
  my $cost_output   = _num($metrics->{cost_output_usd}) || _num($metrics->{output_cost_usd});
  my $cost_total    = _num($metrics->{cost_total_usd}) || _num($metrics->{total_cost_usd});

  my %event = (
    created_at    => ($args{created_at} // _iso8601_now()),
    request_id    => ($args{request_id} // ''),
    api_format    => ($args{api_format} // ''),
    endpoint      => ($args{endpoint} // ''),
    api_key_id    => ($args{api_key_id} // ''),
    provider      => ($args{provider} // ''),
    engine        => ($args{engine} // ''),
    model         => ($args{model} // ''),
    requested_model => ($args{requested_model} // $args{model} // ''),
    node_id       => ($args{node_id} // ''),
    route_url     => ($args{route_url} // ''),
    status_code   => (_num($args{status_code}) || 0),
    ok            => ($args{ok} ? 1 : 0),
    duration_ms   => (_num($args{duration_ms}) || 0),
    input_tokens  => $input_tokens,
    output_tokens => $output_tokens,
    total_tokens  => $total_tokens,
    cached_tokens => $cached_tokens,
    tool_calls    => _num($tool_calls),
    cost_input_usd  => $cost_input,
    cost_output_usd => $cost_output,
    cost_total_usd  => $cost_total,
    error_type    => ($args{error_type} // ''),
    error_message => ($args{error_message} // ''),
  );
  # UTF-8 bytes of the content a streamed request relayed (skeid #36). Optional and additive: a
  # non-streamed event has no such key, which a store records as "not measured". An observation
  # beside the token counts -- never used to estimate or replace them.
  $event{content_bytes} = _num($args{content_bytes}) if defined $args{content_bytes};

  return $self->_store_usage_event(\%event);
}

sub _store_usage_event {
  my ($self, $event) = @_;
  return $self->store_usage_event->($self, $event) if $self->has_store_usage_event;
  my $store = $self->_usage_store_obj;
  return { ok => 0, error => 'usage_store not configured' } unless $store;
  return $store->store($event);
}

# True when a usage event has somewhere to go: a store_usage_event callback, a
# configured usage store object, or a subclass that overrides _store_usage_event
# (documented in README, exercised by t/14) -- the last is why this cannot be a
# plain attribute check. record_usage consults this before building an event.
sub _has_usage_sink {
  my ($self) = @_;
  return 1 if $self->has_store_usage_event;
  return 1 if $self->_usage_store_obj;
  my $impl = $self->can('_store_usage_event');
  return 1 if $impl && $impl != \&_store_usage_event;
  return 0;
}

sub usage_report {
  my ($self, %args) = @_;

  my $limit = _num($args{limit});
  $limit = 20 if $limit < 1;
  $limit = 500 if $limit > 500;

  my %filters;
  $filters{since}      = $args{since}      if defined $args{since}      && length $args{since};
  $filters{api_key_id} = $args{api_key_id} if defined $args{api_key_id} && length $args{api_key_id};
  $filters{model}      = $args{model}      if defined $args{model}      && length $args{model};
  $filters{limit}      = $limit;

  return $self->_query_usage_report(\%filters);
}

sub _query_usage_report {
  my ($self, $filters) = @_;
  return $self->query_usage_report->($self, $filters) if $self->has_query_usage_report;
  my $store = $self->_usage_store_obj;
  return { ok => 0, enabled => 0, error => 'usage_store not configured' } unless $store;
  return $store->report($filters);
}
sub _usage_object {
  my ($self, %args) = @_;
  return Langertha::Usage->from_hash($args{usage}) if ref($args{usage}) eq 'HASH';
  return $args{usage} if ref($args{usage}) && $args{usage}->isa('Langertha::Usage');
  return Langertha::Usage->from_response($args{response});
}

sub estimate_cost {
  my ($self, %args) = @_;
  my $model = $args{model} // '';
  my $usage = $self->_usage_object(%args);
  my $rule  = $args{pricing} || $self->pricing_for_model($model);
  my $pricing = Langertha::Pricing->new( default_rule => $rule );
  return $pricing->cost_for( $usage, undef )->to_hash;
}

sub normalize_metrics {
  my ($self, %args) = @_;
  my $model = $args{model} // '';
  my $usage = $self->_usage_object(%args);
  my $rule  = $args{pricing} || $self->pricing_for_model($model);
  my $pricing = Langertha::Pricing->new( default_rule => $rule );
  my $cost = $pricing->cost_for( $usage, undef );

  my @names;
  for my $tc ( @{ $args{tool_calls} || [] } ) {
    next unless ref($tc) eq 'HASH';
    my $n = $tc->{name} // ( ref( $tc->{function} ) eq 'HASH' ? $tc->{function}{name} : undef );
    push @names, $n if defined $n && length $n;
  }

  my $record = Langertha::UsageRecord->new(
    usage           => $usage,
    cost            => $cost,
    provider        => $args{provider},
    engine          => $args{engine},
    model           => $model,
    route           => $args{route},
    duration_ms     => $args{duration_ms},
    started_at      => $args{started_at},
    finished_at     => $args{finished_at},
    tool_calls      => scalar(@names),
    tool_names      => \@names,
    pricing_version => $args{pricing_version},
  );
  return $record->to_hash;
}

sub _route_key {
  my ($self, %args) = @_;
  my $model  = $args{model}  // '';
  my $engine = $self->normalize_engine_id($args{engine} // '');
  my $tags   = join(',', @{$self->normalize_tags($args{tags})});
  my $deny   = join(',', @{$self->normalize_tags($args{deny_tags})});
  # Tags belong in the key: two selections over the same model address different node sets, and
  # a shared round-robin cursor across different-sized sets picks the wrong node. Denied tags
  # too -- a key that may not use cloud addresses a smaller set than one that may.
  return join('|', $model, $engine, $tags, ($deny ? "-$deny" : ())) if length($tags) || length($deny);
  return join('|', $model, $engine);
}

sub _node_can_take {
  my ($self, $node) = @_;
  return 0 unless ref($node) eq 'HASH';
  return 0 unless ($node->{healthy} // 0);
  my $id = $node->{id} // '';
  return 0 unless length $id;

  # Both have to agree, and they are not symmetric: max_conns is this process's own guardrail
  # and always applies, while a probe may only narrow what it allows. A probe that could widen
  # it would turn a stale or broken reading into an overload -- and for a rented node,
  # max_conns is a spend limit, not a capacity estimate (ADR 0009).
  return 0 unless $self->_inflight_allows($node);
  return 0 unless $self->_capacity_allows($id);
  return 1;
}

sub _inflight_allows {
  my ($self, $node) = @_;
  my $max = $self->worker_max_conns($node);
  return 1 if $max <= 0;
  return (0 + ($self->_inflight->{$node->{id} // ''} // 0)) < $max ? 1 : 0;
}

=method worker_max_conns

  my $share = $skeid->worker_max_conns($node);

This process's share of a node's C<max_conns> (ADR 0010, ADR 0012). With one worker and one
frontend that is the configured value; otherwise it is the configured value divided by the
number of processes sharing the node — C<frontend_count> separate Skeid hosts times the
C<worker_count> prefork workers of this one — so the group as a whole never admits more than was
asked for.

Never less than 1 when a limit is set: a process that may admit nothing is a process that does
nothing. That means a C<max_conns> below that combined process count cannot be honoured, and
L</worker_share_warnings> is what says so out loud.

=cut

sub worker_max_conns {
  my ($self, $node) = @_;
  my $max = 0 + ((ref($node) eq 'HASH' ? $node->{max_conns} : $node) // 0);
  return 0 if $max <= 0;

  my $divisor = $self->_admission_divisor;
  return $max if $divisor <= 1;

  my $share = int($max / $divisor);
  return $share > 0 ? $share : 1;
}

# How many processes across the whole deployment share one node's max_conns: the prefork workers
# of this process (worker_count) times the separate Skeid frontends in front of the node
# (frontend_count). max_conns is partitioned across frontends first and then across workers, but
# integer division composes -- floor(floor(max/F)/N) == floor(max/(F*N)) -- so the product is
# the only number admission needs (ADR 0012).
sub _admission_divisor {
  my ($self) = @_;
  my $workers   = 0 + ($self->worker_count   // 1);
  my $frontends = 0 + ($self->frontend_count // 1);
  $workers   = 1 if $workers   < 1;
  $frontends = 1 if $frontends < 1;
  return $workers * $frontends;
}

=method worker_share_warnings

  warn $_ for @{ $skeid->worker_share_warnings };

The nodes whose C<max_conns> cannot be divided among the processes sharing them without
exceeding it — C<frontend_count> frontends times C<worker_count> workers. Returned rather than
warned so the caller decides where they go; C<bin/skeid> prints them at startup.

Silence here would be the bad kind: the operator wrote a number, and the process group is about
to ignore it.

=cut

sub worker_share_warnings {
  my ($self) = @_;
  my $workers   = 0 + ($self->worker_count   // 1);
  my $frontends = 0 + ($self->frontend_count // 1);
  $workers   = 1 if $workers   < 1;
  $frontends = 1 if $frontends < 1;
  my $divisor = $workers * $frontends;
  return [] if $divisor <= 1;

  # Name the axes that are actually in play, and the matching fix: the operator can only shed
  # what they configured. With both dividing, "worker" alone would misname where the surplus
  # comes from.
  my ($split, $fix);
  if ($frontends > 1 && $workers > 1) {
    $split = sprintf('%d frontends x %d workers = %d processes', $frontends, $workers, $divisor);
    $fix   = 'fewer frontends or workers, or raise max_conns';
  } elsif ($frontends > 1) {
    $split = sprintf('%d frontends', $frontends);
    $fix   = 'fewer frontends or raise max_conns';
  } else {
    $split = sprintf('%d workers', $workers);
    $fix   = 'fewer workers or raise max_conns';
  }

  my @warnings;
  for my $node (@{$self->nodes}) {
    my $max = 0 + ($node->{max_conns} // 0);
    next if $max <= 0;
    next if $max >= $divisor;
    push @warnings, sprintf(
      "node '%s': max_conns %d cannot be split across %s; each process will admit 1, "
      . "so the node may see up to %d concurrent requests. Use %s.",
      ($node->{id} // '?'), $max, $split, $divisor, $fix,
    );
  }
  return \@warnings;
}

# What a probe says about a node, if anything current. Unknown is a valid answer and means
# "inflight decides" -- which is the entire behaviour of a deployment that configures no probes.
sub _capacity_allows {
  my ($self, $node_id) = @_;
  my $reading = $self->capacity_reading($node_id) or return 1;

  # A provider that told us to come back later is not busy in the inflight sense: no request of
  # ours is outstanding, and admitting one would just buy another 429.
  return 0 if $reading->{retry_after} && time < $reading->{retry_after};

  my $limit = 0 + ($reading->{limit} // 0);
  return 1 if $limit <= 0;
  return (0 + ($reading->{used} // 0)) < $limit ? 1 : 0;
}

sub _node_has_tags {
  my ($self, $node, $tags) = @_;
  return 1 unless $tags && @$tags;
  my %have = map { $_ => 1 } @{$node->{tags} || []};
  for my $tag (@$tags) {
    return 0 unless $have{$tag};
  }
  return 1;
}

# The deny side is ANY, not ALL: one forbidden tag on a node is enough to rule it out. A policy
# that denies "cloud" must exclude a node tagged [cloud, groq] without having to name groq too.
sub _node_has_any_tag {
  my ($self, $node, $tags) = @_;
  return 0 unless $tags && @$tags;
  my %have = map { $_ => 1 } @{$node->{tags} || []};
  for my $tag (@$tags) {
    return 1 if $have{$tag};
  }
  return 0;
}

# Everything derived from the inventory -- which nodes are eligible, their round-robin order
# and their weights -- is computed once per selection and reused until the inventory changes.
# Only admission stays per request, because inflight is the one part that moves between two
# requests to the same selection.
sub _route_entry {
  my ($self, %args) = @_;
  my $cache = $self->_route_cache;
  if (($cache->{generation} // -1) != $self->_inventory_generation) {
    $cache = { generation => $self->_inventory_generation, entries => {} };
    $self->_route_cache($cache);
  }

  my $key = $self->_route_key(%args);
  my $entry = $cache->{entries}{$key};
  return $entry if $entry;

  my $model  = $args{model};
  my $engine = $self->normalize_engine_id($args{engine} // '');
  my $tags   = $self->normalize_tags($args{tags});
  my $deny   = $self->normalize_tags($args{deny_tags});

  my @nodes = grep {
    (!defined($model) || !length($model) || !defined($_->{model}) || !length($_->{model}) || $_->{model} eq $model)
      && (!defined($engine) || !length($engine) || !defined($_->{engine}) || !length($_->{engine}) || $_->{engine} eq $engine)
      && (($_->{healthy} // 0) ? 1 : 0)
      && $self->_node_has_tags($_, $tags)
      && !$self->_node_has_any_tag($_, $deny)
  } @{$self->nodes || []};

  @nodes = sort { ($a->{id} // '') cmp ($b->{id} // '') } @nodes;
  my @weights = map {
    my $w = 0 + ($_->{weight} // 1);
    $w = 1 if $w < 1;
    int($w);
  } @nodes;
  my $total_weight = 0;
  $total_weight += $_ for @weights;

  return $cache->{entries}{$key} = {
    nodes        => \@nodes,
    weights      => \@weights,
    total_weight => $total_weight,
  };
}

# Returns the live node hashrefs, not copies. Callers read them and must not mutate them --
# pick_node builds its own hash for the node it returns.
sub _eligible_nodes {
  my ($self, %args) = @_;
  return $self->_route_entry(%args)->{nodes};
}

=method set_model_alias

  $skeid->set_model_alias('our-fast-model', {
    tiers => [
      { tags => ['local'], model => 'qwen3-32b',              wait_ms => 200 },
      { tags => ['cloud'], model => 'llama-3.3-70b-versatile' },
    ],
  });

Defines a client-facing model name as an ordered list of tiers. A bare arrayref of tiers is
accepted as shorthand for C<< { tiers => [...] } >>.

Per tier: C<tags> selects nodes, C<model> is the model actually asked of them (defaulting to
the alias name itself, for the case where nodes carry that name), C<engine> optionally
constrains the engine, and C<wait_ms> is how long to wait for capacity in this tier before
falling through to the next.

C<wait_ms> defaults to B<0>. Writing tiers means "try here, then there"; waiting is the
exception you opt into, and a tier that waits by default would send traffic to a paid cloud
only after a delay nobody asked for -- or, worse, make a cheap tier look slow.

=cut

sub set_model_alias {
  my ($self, $name, $spec) = @_;
  croak 'alias name required' unless defined $name && length $name;

  my $tiers = ref($spec) eq 'ARRAY' ? $spec
            : ref($spec) eq 'HASH'  ? $spec->{tiers}
            : croak "alias '$name': must be a hashref with tiers, or an arrayref of tiers";
  croak "alias '$name': tiers must be an arrayref" unless ref($tiers) eq 'ARRAY';
  croak "alias '$name': needs at least one tier" unless @$tiers;

  my @normalized;
  for my $tier (@$tiers) {
    croak "alias '$name': each tier must be a hashref" unless ref($tier) eq 'HASH';
    push @normalized, {
      tags    => $self->normalize_tags($tier->{tags}),
      model   => ((defined($tier->{model}) && length($tier->{model})) ? "$tier->{model}" : $name),
      engine  => $self->normalize_engine_id($tier->{engine} // ''),
      wait_ms => (defined($tier->{wait_ms}) && $tier->{wait_ms} > 0 ? 0 + $tier->{wait_ms} : 0),
    };
  }

  $self->model_aliases->{$name} = { tiers => \@normalized };
  return 1;
}

=method set_policy

  $skeid->set_policy('standard-local-only', { deny_tags => ['cloud'] });

Defines a named policy profile. Profiles are the "standard setups" most customers take
unchanged; a customer needing something precise gets the profile plus overrides, or a profile
of their own.

=cut

sub set_policy {
  my ($self, $name, $spec) = @_;
  croak 'policy name required' unless defined $name && length $name;
  $self->policies->{$name} = $self->resolve_policy($spec, $name);
  return 1;
}

=method resolve_policy

  my $policy = $skeid->resolve_policy({ models => ['house-model'], deny_tags => ['cloud'] });

Turns a policy spec into the immutable form routing uses: C<models> (or C<aliases>) becomes a
lookup hash of the requested model names the key may ask for, absent meaning all of them, and
C<deny_tags> becomes a normalized tag list.

=cut

sub resolve_policy {
  my ($self, $spec, $name) = @_;
  $spec = {} unless ref($spec) eq 'HASH';

  my $allow = $spec->{models} // $spec->{aliases};
  my $allow_models;
  if (defined $allow) {
    my @list = ref($allow) eq 'ARRAY' ? @$allow : split(/[,\s]+/, "$allow");
    @list = grep { defined && length } @list;
    # An explicit '*' is the same as saying nothing, and saying it out loud reads better in a
    # config than an absent key.
    $allow_models = (grep { $_ eq '*' } @list) ? undef : { map { $_ => 1 } @list };
  }

  return {
    name         => ($name // $spec->{name} // ''),
    allow_models => $allow_models,
    deny_tags    => $self->normalize_tags($spec->{deny_tags}),
  };
}

# Resolves the whole policy section once, at config load. Nothing here happens per request:
# a request costs one hash lookup, and identical resolutions share a single object, so a
# thousand keys on three profiles are three policy objects and a thousand pointers.
sub _load_policies {
  my ($self, $cfg) = @_;

  my %policies;
  if (ref($cfg->{policies}) eq 'HASH') {
    for my $name (keys %{$cfg->{policies}}) {
      $policies{$name} = $self->resolve_policy($cfg->{policies}{$name}, $name);
    }
  }

  my %interned = map { $self->_policy_fingerprint($_) => $_ } values %policies;
  my $intern = sub {
    my ($policy) = @_;
    my $print = $self->_policy_fingerprint($policy);
    return $interned{$print} ||= $policy;
  };

  my $default;
  if (defined $cfg->{default_policy} && length $cfg->{default_policy}) {
    $default = $policies{$cfg->{default_policy}};
    croak "default_policy '$cfg->{default_policy}' is not defined in policies" unless $default;
  }

  # names: is a readable-name -> key-id registry that lives in the config, resolved to key ids
  # here and never consulted on the request path (karr #17, ADR 0008). A value must be an id
  # from `skeid keyid`, never a customer key -- the config still holds no keys. With it, a
  # keys: entry may be written by name, and rotating a customer's key is a one-line edit here
  # rather than a rewrite of every policy line that named them by id.
  my %key_names;
  if (ref($cfg->{names}) eq 'HASH') {
    for my $name (keys %{$cfg->{names}}) {
      my $id = $cfg->{names}{$name};
      croak "name '$name' must map to a key id string, not a structure" if ref $id;
      croak "name '$name' maps to an empty key id" unless defined($id) && length($id);
      $key_names{$name} = $id;
    }
  }

  # Resolve a keys: entry's label through the names registry, if it is a known name; otherwise
  # it is taken to be a key id already. Two labels resolving to the same id is a config error,
  # not a silent last-wins -- it usually means a name and its own id were both listed.
  my %seen_id;
  my $resolve_key_id = sub {
    my ($label) = @_;
    my $id = exists $key_names{$label} ? $key_names{$label} : $label;
    croak "keys entry '$label' resolves to key id '$id', which another entry already claims"
      if $seen_id{$id}++;
    return $id;
  };

  my %key_policies;
  if (ref($cfg->{keys}) eq 'HASH') {
    for my $label (keys %{$cfg->{keys}}) {
      my $key   = $resolve_key_id->($label);
      my $entry = $cfg->{keys}{$label};

      if (!ref($entry)) {
        my $policy = $policies{$entry};
        croak "key '$label' references undefined policy '$entry'" unless $policy;
        $key_policies{$key} = $policy;
        next;
      }

      croak "key '$label' must be a policy name or a hashref" unless ref($entry) eq 'HASH';

      my $base = {};
      if (defined $entry->{policy} && length $entry->{policy}) {
        my $named = $policies{$entry->{policy}};
        croak "key '$label' references undefined policy '$entry->{policy}'" unless $named;
        $base = $named;
      } elsif ($default) {
        $base = $default;
      }

      # Overrides are sparse: an absent field keeps the profile's value, so "same as standard
      # but allowed to use cloud" is one line rather than a restated profile.
      my $overrides = ref($entry->{overrides}) eq 'HASH' ? $entry->{overrides} : $entry;
      my $merged = {
        name         => ($base->{name} // ''),
        allow_models => (exists($overrides->{models}) || exists($overrides->{aliases})
                          ? $self->resolve_policy($overrides)->{allow_models}
                          : $base->{allow_models}),
        deny_tags    => (exists($overrides->{deny_tags})
                          ? $self->normalize_tags($overrides->{deny_tags})
                          : ($base->{deny_tags} // [])),
      };
      $key_policies{$key} = $intern->($merged);
    }
  }

  $self->policies(\%policies);
  $self->default_policy($default);
  $self->key_policies(\%key_policies);
  $self->key_names(\%key_names);
  return 1;
}

sub _policy_fingerprint {
  my ($self, $policy) = @_;
  my $models = defined($policy->{allow_models}) ? join(',', sort keys %{$policy->{allow_models}}) : '*';
  return join("\0", $models, join(',', @{$policy->{deny_tags}}));
}

=method key_id_for_key

  my $id = Langertha::Skeid->key_id_for_key('sk-alice-secret');   # k_5f0e...

The customer key id derived from the presented API key. This is the name a C<keys:> entry has
to use, and C<skeid keyid> prints it, because the config must be able to name a customer
without holding that customer's key.

It is a truncated digest, not a secret: it identifies, it does not authenticate. What
authenticates is that the caller presented the key it was derived from.

=cut

sub key_id_for_key {
  my ($self, $api_key) = @_;
  return 'anonymous' unless defined($api_key) && length($api_key);
  return 'k_' . substr(sha1_hex($api_key), 0, 12);
}

=method policy_for_key

  my $policy = $skeid->policy_for_key('alice');

The policy a customer key routes under. Unlisted keys take the default policy, which is what
makes a deployment with ten thousand identically-configured customers a config with zero key
entries. Returns undef when no policies are configured at all.

=cut

sub policy_for_key {
  my ($self, $api_key_id) = @_;
  return $self->key_policies->{$api_key_id}
    if defined($api_key_id) && length($api_key_id) && $self->key_policies->{$api_key_id};
  return $self->default_policy;
}

=method key_id_for_name

  my $id = $skeid->key_id_for_name('alice');   # k_5f0e1a2b3c4d, or undef

The customer key id a readable name maps to under the config C<names:> section, or undef when
the name is not registered. The registry is a config-authoring convenience -- it lets a
C<keys:> entry be written by name and confines key rotation to one line -- and is resolved to
ids at config load, so it never appears on the request path.

=cut

sub key_id_for_name {
  my ($self, $name) = @_;
  return undef unless defined($name) && length($name);
  return $self->key_names->{$name};
}

=method route_plan

  my $plan = $skeid->route_plan(model => 'our-fast-model', api_key_id => 'alice');
  # { tiers => [...], permitted => 1, reason => '' }

The ordered tiers to try for a requested model, under the policy of the key that asked. A model
with no alias yields a single implicit tier that selects on the name itself and inherits the
global C<route_wait_timeout_ms>, which is what makes an aliasless config behave exactly as it
did before aliases existed.

C<permitted> is false when the policy does not grant this model, or when every tier of it was
denied. Both mean the same thing to a caller — this key may not reach this model — and neither
is a capacity problem, so they must not be reported as one.

Tiers carry the policy's C<deny_tags> down into node selection. Dropping a denied tier is only
the reporting half; without the node-level filter, a key denied C<cloud> could still reach a
cloud node by asking for its raw model name instead of the alias.

=cut

sub route_plan {
  my ($self, %args) = @_;
  my $model  = $args{model} // '';
  my $policy = $self->policy_for_key($args{api_key_id});
  my $deny   = $policy ? $policy->{deny_tags} : [];

  if ($policy && $policy->{allow_models} && !$policy->{allow_models}{$model}) {
    return { tiers => [], permitted => 0, reason => 'model_not_permitted' };
  }

  my $alias = $self->model_aliases->{$model};
  my @tiers = $alias
    ? (map { +{ %$_, deny_tags => $deny } } @{$alias->{tiers}})
    : ({
        tags      => [],
        model     => $model,
        engine    => $self->normalize_engine_id($args{engine} // ''),
        wait_ms   => 0 + ($self->route_wait_timeout_ms // 0),
        deny_tags => $deny,
      });

  my $before = scalar @tiers;
  if (@$deny) {
    my %denied = map { $_ => 1 } @$deny;
    @tiers = grep {
      my $tier = $_;
      !grep { $denied{$_} } @{$tier->{tags} || []};
    } @tiers;
  }

  return { tiers => [], permitted => 0, reason => 'all_tiers_denied' }
    if $before && !@tiers;

  return { tiers => \@tiers, permitted => 1, reason => '' };
}

=method select_nodes

  my $local = $skeid->select_nodes(tags => ['local']);

Nodes carrying every listed tag, as copies. No tags selects everything. Selection is by tag,
never by node id, so a config can talk about C<local> or C<cloud> without naming machines.

=cut

sub select_nodes {
  my ($self, %args) = @_;
  my $tags = $self->normalize_tags($args{tags});
  my $deny = $self->normalize_tags($args{deny_tags});
  return [
    map { +{%$_} }
    grep { $self->_node_has_tags($_, $tags) && !$self->_node_has_any_tag($_, $deny) }
    @{$self->nodes || []}
  ];
}

sub pick_node {
  my ($self, %args) = @_;
  my $entry = $self->_route_entry(%args);
  my @nodes = @{$entry->{nodes}};
  return unless @nodes;

  my @weights = @{$entry->{weights}};
  my $total_weight = $entry->{total_weight};
  return unless $total_weight > 0;

  my $key = $self->_route_key(%args);
  my $cursor = 0 + ($self->_rr_cursor->{$key} // 0);

  # Weighted round-robin with admission checks.
  for my $step (0 .. $total_weight - 1) {
    my $target = ($cursor + $step) % $total_weight;
    my $acc = 0;
    for my $idx (0 .. $#nodes) {
      $acc += $weights[$idx];
      next if $target >= $acc;
      my $candidate = $nodes[$idx];
      next unless $self->_node_can_take($candidate);
      $self->_rr_cursor->{$key} = ($cursor + $step + 1) % $total_weight;
      my $id = $candidate->{id};
      my $inflight = 0 + ($self->_inflight->{$id} // 0);
      return {
        %$candidate,
        inflight => $inflight,
        route_key => $key,
      };
    }
  }

  return;
}

sub route_state {
  my ($self, %args) = @_;
  my $engine = $self->normalize_engine_id($args{engine} // '');
  my $eligible = $self->_eligible_nodes(%args);
  my $available = [ grep { $self->_node_can_take($_) } @$eligible ];

  return {
    model          => ($args{model} // ''),
    engine         => $engine,
    tags           => $self->normalize_tags($args{tags}),
    deny_tags      => $self->normalize_tags($args{deny_tags}),
    eligible_count => scalar(@$eligible),
    available_count => scalar(@$available),
    has_eligible   => @$eligible ? 1 : 0,
    has_available  => @$available ? 1 : 0,
  };
}

=method set_capacity_reading

  $skeid->set_capacity_reading('gpu-1', used => 6, limit => 8, source => 'prometheus');
  $skeid->set_capacity_reading('groq-1', retry_after_ms => 2000, source => 'ratelimit');

Records what a probe found. One shape for every probe, so admission never learns where a
number came from (ADR 0009):

=over 4

=item * C<used> / C<limit> — occupancy. C<limit> 0 or absent means the probe measured
something it cannot turn into a ceiling, so it does not constrain admission.

=item * C<retry_after_ms> — do not send anything here until it elapses. What a C<429> means.

=item * C<source> — which probe, for reports. Never consulted by admission.

=back

A reading only ever narrows what C<max_conns> already allows, and expires after
L</capacity_max_age_ms>. Probing is a background activity: calling this from a request handler
is a bug unless the reading was a by-product of a response already in hand.

=cut

sub set_capacity_reading {
  my ($self, $node_id, %reading) = @_;
  croak 'node_id required' unless defined $node_id && length $node_id;

  my $now = time;
  my $entry = {
    source => ((defined($reading{source}) && length($reading{source})) ? "$reading{source}" : 'custom'),
    used   => (defined $reading{used}  ? 0 + $reading{used}  : undef),
    limit  => (defined $reading{limit} ? 0 + $reading{limit} : undef),
    at     => (defined $reading{at}    ? 0 + $reading{at}    : $now),
    # Which of a provider's several quotas this reading is about, when it had more than one.
    # For reports only -- admission just sees used and limit.
    (defined $reading{quota} ? (quota => "$reading{quota}") : ()),
  };

  if (defined $reading{retry_after_ms} && $reading{retry_after_ms} > 0) {
    $entry->{retry_after} = $now + ($reading{retry_after_ms} / 1000);
  } elsif (defined $reading{retry_after}) {
    $entry->{retry_after} = 0 + $reading{retry_after};
  }

  $self->_capacity->{$node_id} = $entry;
  return $entry;
}

=method capacity_reading

  my $reading = $skeid->capacity_reading('gpu-1');   # or nothing

The node's current capacity reading, or nothing when no probe has reported or the last report
has aged out. A backoff outlives the age limit: a provider that said "not for another 30
seconds" told us something that is still true.

=cut

sub capacity_reading {
  my ($self, $node_id) = @_;
  return unless defined($node_id) && length($node_id);
  my $entry = $self->_capacity->{$node_id} or return;

  my $backoff_pending = ($entry->{retry_after} && time < $entry->{retry_after}) ? 1 : 0;
  my $max_age = 0 + ($self->capacity_max_age_ms // 0);
  if (!$backoff_pending && $max_age > 0 && (time - ($entry->{at} // 0)) > ($max_age / 1000)) {
    delete $self->_capacity->{$node_id};
    return;
  }
  return $entry;
}

=method forget_capacity

  $skeid->forget_capacity('gpu-1');   # or all of them with no argument

Drops probe readings, so C<inflight> decides again. What a node removal calls, and what a probe
calls when it can no longer reach its source — reporting nothing beats reporting last hour.

=cut

sub forget_capacity {
  my ($self, $node_id) = @_;
  if (defined($node_id) && length($node_id)) {
    delete $self->_capacity->{$node_id};
    return 1;
  }
  %{$self->_capacity} = ();
  return 1;
}

# Rate-limit headers, in the spellings the big providers actually use. Ordered: the first one
# present wins, so a provider sending several does not get read twice.
# Providers meter more than one thing at once, and for an LLM API the token budget is usually
# what runs out first -- a node with requests to spare and no tokens left answers 429 all the
# same. Each quota is read separately and the tightest one decides.
#
# Within a quota the order is "most specific first": the first name present wins, so a provider
# sending both a specific and a generic spelling is not counted twice.
my @RATELIMIT_QUOTAS = (
  {
    name      => 'requests',
    remaining => [qw(
      x-ratelimit-remaining-requests
      anthropic-ratelimit-requests-remaining
      x-ratelimit-remaining
      ratelimit-remaining
    )],
    limit => [qw(
      x-ratelimit-limit-requests
      anthropic-ratelimit-requests-limit
      x-ratelimit-limit
      ratelimit-limit
    )],
  },
  {
    name      => 'tokens',
    remaining => [qw(
      x-ratelimit-remaining-tokens
      anthropic-ratelimit-tokens-remaining
      anthropic-ratelimit-input-tokens-remaining
    )],
    limit => [qw(
      x-ratelimit-limit-tokens
      anthropic-ratelimit-tokens-limit
      anthropic-ratelimit-input-tokens-limit
    )],
  },
);

=method capacity_header_names

The response headers worth looking at, so a caller on the request path can pull those few by
name instead of walking every header of every response.

=cut

sub capacity_header_names {
  return ((map { @{$_->{remaining}}, @{$_->{limit}} } @RATELIMIT_QUOTAS), 'retry-after');
}

=method observe_response_headers

  $skeid->observe_response_headers('groq-1', \%headers, status => 429);

The zero-cost probe: commercial providers do not publish queue depth, but they do put their
rate-limit state on every response Skeid already receives. Reading it costs no extra request
(ADR 0009).

Providers meter requests and tokens separately, and for an LLM API the token budget is usually
what runs out first. Both are read, and the one closest to exhausted decides — compared as a
fraction, since the two are not the same unit.

C<Retry-After> on a C<429> becomes a backoff. It deliberately does B<not> touch C<healthy>:
rate-limited is busy, not broken, and nothing would ever flip that back.

Returns the reading it recorded, or nothing when the response said nothing useful.

=cut

sub observe_response_headers {
  my ($self, $node_id, $headers, %args) = @_;
  return unless defined($node_id) && length($node_id);
  return unless ref($headers) eq 'HASH';

  # Case-insensitive: header casing is not something a provider promises.
  my %h = map { lc($_) => $headers->{$_} } keys %$headers;
  my %reading = (source => 'ratelimit');
  my $useful = 0;

  # The tightest quota wins, compared as a fraction because requests and tokens are not the
  # same unit. Reporting the roomier one would admit a request the provider is about to refuse.
  my $tightest = -1;
  for my $quota (@RATELIMIT_QUOTAS) {
    my ($remaining) = grep { defined } map { $h{$_} } @{$quota->{remaining}};
    next unless defined($remaining) && $remaining =~ /^\s*(\d+)/;
    my $left = 0 + $1;

    my ($limit) = grep { defined } map { $h{$_} } @{$quota->{limit}};
    # The probe contract counts what is used, not what is left; a limit we were not told is
    # reconstructed as "one more than we have", which is enough to stop admitting at zero.
    my $total = (defined($limit) && $limit =~ /^\s*(\d+)/) ? 0 + $1 : $left + 1;
    next unless $total > 0;

    my $used = $total - $left;
    $used = $total if $used > $total;
    $used = 0 if $used < 0;

    my $fraction = $used / $total;
    next unless $fraction > $tightest;
    $tightest = $fraction;
    $reading{limit} = $total;
    $reading{used}  = $used;
    $reading{quota} = $quota->{name};
    $useful = 1;
  }

  my $retry = $h{'retry-after'};
  my $status = 0 + ($args{status} // 0);
  if ($status == 429 || defined $retry) {
    my $secs;
    if (defined($retry) && $retry =~ /^\s*([\d.]+)\s*$/) {
      $secs = 0 + $1;
    } elsif ($status == 429) {
      # A 429 with no Retry-After still means "not now". One second is short enough not to
      # strand capacity and long enough to stop hammering.
      $secs = 1;
    }
    if (defined $secs && $secs > 0) {
      $reading{retry_after_ms} = $secs * 1000;
      $useful = 1;
    }
  }

  return unless $useful;
  return $self->set_capacity_reading($node_id, %reading);
}

sub start_request {
  my ($self, $node_id) = @_;
  croak 'node_id required' unless defined $node_id && length $node_id;
  my $node = (grep { ($_->{id} // '') eq $node_id } @{$self->nodes})[0];
  return 0 unless $node && $self->_node_can_take($node);

  $self->_inflight->{$node_id} = 1 + ($self->_inflight->{$node_id} // 0);
  $self->_stats->{$node_id}{started} = 1 + ($self->_stats->{$node_id}{started} // 0);
  return 1;
}

sub finish_request {
  my ($self, $node_id, %args) = @_;
  croak 'node_id required' unless defined $node_id && length $node_id;
  my $cur = 0 + ($self->_inflight->{$node_id} // 0);
  $cur--;
  $cur = 0 if $cur < 0;
  $self->_inflight->{$node_id} = $cur;

  if ($args{ok}) {
    $self->_stats->{$node_id}{ok} = 1 + ($self->_stats->{$node_id}{ok} // 0);
  } else {
    $self->_stats->{$node_id}{error} = 1 + ($self->_stats->{$node_id}{error} // 0);
  }

  if (defined $args{duration_ms}) {
    $self->_stats->{$node_id}{duration_ms_total}
      = (0 + ($self->_stats->{$node_id}{duration_ms_total} // 0)) + (0 + $args{duration_ms});
  }

  return 1;
}

sub node_metrics {
  my ($self, $node_id) = @_;
  if (defined $node_id && length $node_id) {
    my $s = $self->_stats->{$node_id} || {};
    my $reading = $self->capacity_reading($node_id);
    return {
      node_id => $node_id,
      inflight => 0 + ($self->_inflight->{$node_id} // 0),
      started => 0 + ($s->{started} // 0),
      ok => 0 + ($s->{ok} // 0),
      error => 0 + ($s->{error} // 0),
      duration_ms_total => 0 + ($s->{duration_ms_total} // 0),
      # Present only when a probe has something current to say. A report must not present a
      # measured node and an inferred one as equally known (ADR 0009).
      ($reading ? (capacity => { %$reading }) : ()),
    };
  }

  my @rows;
  for my $n (@{$self->nodes}) {
    push @rows, $self->node_metrics($n->{id});
  }
  return \@rows;
}

sub call_function {
  my ($self, $name, $args) = @_;
  $args ||= {};
  croak 'function name required' unless defined $name && length $name;
  croak 'function args must be hashref' unless ref($args) eq 'HASH';

  # Dynamic config refresh on each task/function dispatch.
  $self->maybe_reload_config;

  if ($name eq 'metrics.estimate_cost') {
    return $self->estimate_cost(%$args);
  }
  if ($name eq 'metrics.normalize') {
    return $self->normalize_metrics(%$args);
  }
  if ($name eq 'pricing.set') {
    my $model = $args->{model} // croak 'pricing.set: model required';
    my $pricing = $args->{pricing} // croak 'pricing.set: pricing required';
    return $self->set_model_pricing($model, $pricing);
  }
  if ($name eq 'nodes.add') {
    return { ok => $self->add_node(%$args) ? 1 : 0 };
  }
  if ($name eq 'nodes.remove') {
    return { ok => $self->remove_node($args->{id}) ? 1 : 0 };
  }
  if ($name eq 'nodes.list') {
    return { nodes => $self->list_nodes };
  }
  if ($name eq 'nodes.select') {
    return { nodes => $self->select_nodes(tags => $args->{tags}, deny_tags => $args->{deny_tags}) };
  }
  if ($name eq 'alias.set') {
    my $alias = $args->{name} // croak 'alias.set: name required';
    return { ok => $self->set_model_alias($alias, $args->{alias} // $args) ? 1 : 0 };
  }
  if ($name eq 'route.plan') {
    return $self->route_plan(
      model      => ($args->{model} // ''),
      engine     => $args->{engine},
      api_key_id => $args->{api_key_id},
    );
  }
  if ($name eq 'policy.set') {
    my $policy = $args->{name} // croak 'policy.set: name required';
    return { ok => $self->set_policy($policy, $args->{policy} // $args) ? 1 : 0 };
  }
  if ($name eq 'policy.for_key') {
    return { policy => $self->policy_for_key($args->{api_key_id}) };
  }
  if ($name eq 'nodes.set_health') {
    return { ok => $self->set_node_health($args->{id}, $args->{healthy}) ? 1 : 0 };
  }
  if ($name eq 'nodes.metrics') {
    return { metrics => $self->node_metrics($args->{id}) };
  }
  if ($name eq 'engines.list') {
    return { engines => $self->supported_engine_ids };
  }
  if ($name eq 'route.next') {
    my $node = $self->pick_node(
      model  => ($args->{model} // ''),
      engine => $self->normalize_engine_id($args->{engine} // ''),
      tags   => $args->{tags},
      deny_tags => $args->{deny_tags},
    );
    return { node => $node };
  }
  if ($name eq 'route.state') {
    my $engine = $self->normalize_engine_id($args->{engine} // '');
    return $self->route_state(
      model  => ($args->{model} // ''),
      engine => $engine,
      tags   => $args->{tags},
      deny_tags => $args->{deny_tags},
    );
  }
  if ($name eq 'capacity.set') {
    my $id = $args->{id} // croak 'capacity.set: id required';
    return { capacity => $self->set_capacity_reading($id, %$args) };
  }
  if ($name eq 'capacity.get') {
    my $id = $args->{id} // croak 'capacity.get: id required';
    return { capacity => $self->capacity_reading($id) };
  }
  if ($name eq 'capacity.observe') {
    my $id = $args->{id} // croak 'capacity.observe: id required';
    return { capacity => $self->observe_response_headers(
      $id, ($args->{headers} || {}), status => $args->{status}) };
  }
  if ($name eq 'capacity.forget') {
    return { ok => $self->forget_capacity($args->{id}) ? 1 : 0 };
  }
  if ($name eq 'request.start') {
    my $id = $args->{id} // croak 'request.start: id required';
    return { ok => $self->start_request($id) ? 1 : 0 };
  }
  if ($name eq 'request.finish') {
    my $id = $args->{id} // croak 'request.finish: id required';
    return { ok => $self->finish_request($id, %$args) ? 1 : 0 };
  }
  if ($name eq 'config.reload') {
    return { config => $self->reload_config };
  }
  if ($name eq 'usage.record') {
    return $self->record_usage(%$args);
  }
  if ($name eq 'usage.report') {
    return $self->usage_report(%$args);
  }
  if ($name eq 'usage.configure') {
    my $store = $args->{usage_store} // $args;
    return { usage_store => $self->configure_usage_store($store) };
  }

  croak "unknown function: $name";
}

sub DEMOLISH {
  my ($self) = @_;
  $self->_disconnect_usage_store;
}

sub _disconnect_usage_store {
  my ($self) = @_;
  my $store = $self->_usage_store_obj or return;
  $store->disconnect;
  $self->_usage_store_obj(undef);
  return;
}

1;
