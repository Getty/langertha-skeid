use strict;
use warnings;
use Test::More;
use Test::Mojo;
use JSON::MaybeXS qw(decode_json);
use Langertha::Skeid;
use Langertha::Skeid::Proxy;

# Provider manifest per customer key (skeid #29, ADR 0015; core ADR 0029, raider ADR 0007).
# /.well-known/langertha.json tells a client which models it may use and how to reach them. The
# property that matters is who gets told what: a key sees exactly the models its own keys:
# entry grants, never another key's richer catalog, never anything unless the operator opted
# in, and never an internal node URL or upstream key. Core's Langertha::Manifest is newer than
# the Langertha 0.503 this dist requires, so the route has to degrade to 404 without it.

my $HAS_MANIFEST = eval { require Langertha::Manifest; require Langertha::Manifest::Builder; 1 };

my $ALICE_KEY = 'sk-alice-secret';
my $BOB_KEY   = 'sk-bob-secret';
my $ALICE_ID  = Langertha::Skeid->key_id_for_key($ALICE_KEY);
my $BOB_ID    = Langertha::Skeid->key_id_for_key($BOB_KEY);

my $NODE_URL = 'http://10.13.37.5:8000/v1';

sub base_config {
  my (%manifest) = @_;
  return {
    policies       => { standard => { deny_tags => ['cloud'] }, burstable => {} },
    default_policy => 'standard',
    names          => { alice => $ALICE_ID, bob => $BOB_ID },
    aliases        => { 'house-model' => { tiers => [{ tags => ['local'], model => 'qwen3-32b' }] } },
    keys           => {
      alice => {
        policy   => 'burstable',
        manifest => { models => ['house-model', 'qwen3-32b', 'gpt-cloud'] },
      },
      bob => { manifest => { models => ['house-model'] } },
    },
    nodes => [
      { id => 'gpu01', url => $NODE_URL, model => 'qwen3-32b', tags => ['local'],
        api_key_ref => 'secret/skeid/nodes/gpu01' },
      { id => 'cloud1', url => 'https://api.cloud.example/v1', model => 'gpt-cloud', tags => ['cloud'],
        api_key_env => 'UPSTREAM_CLOUD_KEY' },
    ],
    (%manifest ? (manifest => { %manifest }) : ()),
  };
}

sub app_for {
  my ($cfg) = @_;
  my $skeid = Langertha::Skeid->new(config_loader => sub { $cfg });
  return (Test::Mojo->new(Langertha::Skeid::Proxy->build_app(skeid => $skeid)), $skeid);
}

my %ENABLED = (enabled => 1, public_url => 'https://llm.example.com/', provider_id => 'example-llm');

# --- nothing is published unless the operator turns it on ---
{
  my ($t) = app_for(base_config());
  $t->get_ok('/.well-known/langertha.json' => { Authorization => "Bearer $ALICE_KEY" })
    ->status_is(404, 'no manifest: section means no manifest, even for a key with a grant')
    ->header_like('Cache-Control' => qr/private/);

  ($t) = app_for(base_config(%ENABLED, enabled => 0));
  $t->get_ok('/.well-known/langertha.json' => { Authorization => "Bearer $ALICE_KEY" })
    ->status_is(404, 'enabled: false publishes nothing');
}

unless ($HAS_MANIFEST) {
  my ($t) = do {
    local $SIG{__WARN__} = sub { };
    app_for(base_config(%ENABLED));
  };
  $t->get_ok('/.well-known/langertha.json' => { Authorization => "Bearer $ALICE_KEY" })
    ->status_is(404, 'enabled on a Langertha without Langertha::Manifest answers 404')
    ->json_is('/error/type' => 'not_found');
  done_testing;
  exit;
}

# --- who gets what ---
{
  my ($t, $skeid) = app_for(base_config(%ENABLED,
    capabilities => { 'house-model' => { tools_native => 1, tool_choice_auto => 1, streaming => 0 } },
  ));

  $t->get_ok('/.well-known/langertha.json')
    ->status_is(401, 'no key, no manifest -- not even a minimal one')
    ->header_like('WWW-Authenticate' => qr/Bearer/);

  $t->get_ok('/.well-known/langertha.json' => { Authorization => 'Bearer sk-somebody-else' })
    ->status_is(403, 'a key without a manifest: grant is refused, not shown the catalog');

  # Alternate the two keys: whatever was built or served for one must not bleed into the other.
  my %body;
  for my $round (1 .. 2) {
    for my $who ([alice => $ALICE_KEY], [bob => $BOB_KEY]) {
      my ($name, $key) = @$who;
      $t->get_ok('/.well-known/langertha.json' => { 'x-api-key' => $key })
        ->status_is(200, "$name gets a manifest (round $round)")
        ->header_like('Content-Type' => qr{application/json})
        ->header_like('Cache-Control' => qr/private/, 'never cacheable by a shared cache')
        ->header_like('Vary' => qr/Authorization/i)
        ->header_like('Vary' => qr/X-Api-Key/i);
      $body{$name}[$round] = $t->tx->res->body;
    }
  }
  is($body{alice}[2], $body{alice}[1], 'alice is served the same bytes every time');
  is($body{bob}[2],   $body{bob}[1],   'and so is bob');

  my $alice = Langertha::Manifest->from_json($body{alice}[1]);
  my $bob   = Langertha::Manifest->from_json($body{bob}[1]);
  ok($alice && $bob, 'both validate as core manifests');

  my %alice_models = map { $_->id => 1 } @{$alice->models};
  is_deeply([sort keys %alice_models], [qw(gpt-cloud house-model qwen3-32b)],
    'alice sees exactly her granted models');
  is_deeply([sort map { $_->id } @{$bob->models}], [('house-model') x 3],
    'bob sees only house-model, once per face');
  unlike($body{bob}[1], qr/qwen3-32b|gpt-cloud/, "bob's manifest names none of alice's extra models");
  unlike($body{bob}[2], qr/qwen3-32b|gpt-cloud/, 'not after alice was served either');

  for my $pair ([alice => $body{alice}[1]], [bob => $body{bob}[1]]) {
    my ($name, $json) = @$pair;
    unlike($json, qr/10\.13\.37\.5|gpu01|cloud1|api\.cloud\.example|UPSTREAM_CLOUD_KEY|secret\/skeid|sk-/,
      "$name: no node URL, node id, upstream key reference or customer key leaks");
  }

  is($alice->provider_id, 'example-llm', 'provider_id from the config');
  is($alice->issuer, 'https://llm.example.com', 'issuer is the public origin');
  my %endpoints = map { $_->id => $_ } @{$alice->endpoints};
  is_deeply([sort keys %endpoints], [qw(anthropic ollama openai)], 'one endpoint per face');
  is($endpoints{openai}->dialect,    'openai-chat',      'openai face');
  is($endpoints{anthropic}->dialect, 'anthropic-compat',
    'anthropic face is a shim: no output_config.format through the OpenAI upstream call');
  is($endpoints{ollama}->dialect,    'ollama',           'ollama face');
  is($endpoints{openai}->base_url,    'https://llm.example.com/v1', 'openai base under /v1');
  is($endpoints{anthropic}->base_url, 'https://llm.example.com',    'anthropic base at the root');
  is($endpoints{ollama}->base_url,    'https://llm.example.com',    'ollama base at the root');
  is_deeply([map { $_->type } @{$alice->auth}], ['api_key'], "skeid's customer key is the one auth mechanism");
  ok(!grep({ ($_->auth_ref // '') ne 'api' } values %endpoints), 'every face requires it');

  my ($house) = grep { $_->id eq 'house-model' && $_->endpoint_ref eq 'openai' } @{$alice->models};
  ok($house->supports('tools_native'), 'declared capabilities are published');
  ok($house->supports('chat'), 'chat is claimed by default');
  ok(!$house->supports('streaming'), 'a declared false removes a default claim');
  my ($qwen) = grep { $_->id eq 'qwen3-32b' } @{$alice->models};
  is_deeply($qwen->capabilities, { chat => 1, streaming => 1 },
    'an undeclared model claims only chat and streaming');
}

# --- the trusted identity header is honoured the same way the request path honours it ---
{
  my $cfg = base_config(%ENABLED);
  $cfg->{routing} = { trust_key_id_header => 1 };
  my ($t) = app_for($cfg);
  $t->get_ok('/.well-known/langertha.json' => { 'x-skeid-key-id' => $BOB_ID })
    ->status_is(200, 'a trusted x-skeid-key-id names the customer');
  unlike($t->tx->res->body, qr/qwen3-32b/, "and gets that customer's manifest");

  ($t) = app_for(base_config(%ENABLED));
  $t->get_ok('/.well-known/langertha.json' => { 'x-skeid-key-id' => $ALICE_ID })
    ->status_is(401, 'untrusted, the header names nobody');
}

# --- a reload that withdraws a grant withdraws the manifest ---
{
  my $cfg = base_config(%ENABLED);
  my ($t) = app_for($cfg);
  $t->get_ok('/.well-known/langertha.json' => { Authorization => "Bearer $ALICE_KEY" })->status_is(200);
  delete $cfg->{keys}{alice}{manifest};
  $t->get_ok('/.well-known/langertha.json' => { Authorization => "Bearer $ALICE_KEY" })
    ->status_is(403, 'no stale manifest survives the reload that removed the grant');
}

# --- faces ---
{
  my ($t) = app_for(base_config(%ENABLED, faces => ['openai']));
  $t->get_ok('/.well-known/langertha.json' => { Authorization => "Bearer $BOB_KEY" })->status_is(200);
  my $manifest = Langertha::Manifest->from_json($t->tx->res->body);
  is_deeply([map { $_->id } @{$manifest->endpoints}], ['openai'], 'faces: limits the published endpoints');
}

# --- config contradictions are load errors ---
{
  my $cfg = base_config(%ENABLED);
  $cfg->{keys}{bob}{manifest}{models} = ['gpt-cloud'];
  ok(!eval { Langertha::Skeid->new(config_loader => sub { $cfg }); 1 },
    'a model the key policy denies cannot be published to it');
  like($@, qr/key 'bob'.*gpt-cloud.*does not let it reach/, 'and the error names key and model');

  $cfg = base_config(%ENABLED);
  $cfg->{keys}{bob}{models} = ['house-model'];
  $cfg->{keys}{bob}{manifest}{models} = ['house-model', 'qwen3-32b'];
  ok(!eval { Langertha::Skeid->new(config_loader => sub { $cfg }); 1 },
    'nor a model outside the key policy models: list');
  like($@, qr/key 'bob'.*qwen3-32b/, 'named in the error');

  $cfg = base_config(%ENABLED);
  $cfg->{keys}{bob}{manifest}{models} = ['no-such-model'];
  ok(!eval { Langertha::Skeid->new(config_loader => sub { $cfg }); 1 },
    'nor a model no node serves');

  $cfg = base_config(%ENABLED);
  delete $cfg->{manifest}{public_url};
  ok(!eval { Langertha::Skeid->new(config_loader => sub { $cfg }); 1 }, 'enabled needs a public_url');
  like($@, qr/public_url/, 'named in the error');

  $cfg = base_config(%ENABLED, capabilities => { 'house-model' => { transcription => 1 } });
  ok(!eval { Langertha::Skeid->new(config_loader => sub { $cfg }); 1 },
    'only chat-call capabilities may be claimed on a model');
  like($@, qr/transcription/, 'named in the error');

  $cfg = base_config(%ENABLED, faces => ['grpc']);
  ok(!eval { Langertha::Skeid->new(config_loader => sub { $cfg }); 1 }, 'an unknown face is an error');

  $cfg = base_config(%ENABLED, public_url => 'https://user:pw@llm.example.com');
  ok(!eval { Langertha::Skeid->new(config_loader => sub { $cfg }); 1 },
    'a public_url core would refuse (userinfo) fails the load');
  like($@, qr/userinfo/, 'with the core validation reason');
}

done_testing;
