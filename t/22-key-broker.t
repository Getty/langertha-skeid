use strict;
use warnings;
use Test2::V0;

use Langertha::Skeid::KeyBroker;

# Base class requires subclass to implement resolve_key
my $broker = Langertha::Skeid::KeyBroker->new;
ok $broker, 'base broker instantiates';
is $broker->needs_refresh, 0, 'needs_refresh defaults to false';

# resolve_key dies with useful message
like dies { $broker->resolve_key('some/path') },
  qr/must implement resolve_key/,
  'base resolve_key croaks';

# Subclass works
{
  package TestBroker;
  use Moo;
  extends 'Langertha::Skeid::KeyBroker';
  has _keys => (is => 'ro', default => sub { {} });
  sub resolve_key {
    my ($self, $ref) = @_;
    return $self->_keys->{$ref} // die "no key for $ref";
  }
}

my $tb = TestBroker->new(_keys => { 'provider/groq' => 'gsk_test123' });
is $tb->resolve_key('provider/groq'), 'gsk_test123', 'subclass resolves key';
like dies { $tb->resolve_key('missing') }, qr/no key for/, 'missing key dies';

# Test api_key_ref passes through add_node
use Langertha::Skeid;

my $skeid = Langertha::Skeid->new;
$skeid->add_node(
  id => 'groq-llama',
  url => 'https://api.groq.com/openai/v1',
  model => 'llama-4-scout',
  api_key_ref => 'provider/groq/api-key',
);
my $node = $skeid->list_nodes->[0];
is $node->{api_key_ref}, 'provider/groq/api-key', 'api_key_ref stored on node';
ok !exists $node->{api_key_env}, 'no api_key_env when ref used';

# Test key_broker attribute
my $broker2 = TestBroker->new(_keys => { 'provider/groq/api-key' => 'gsk_test' });
my $skeid2 = Langertha::Skeid->new(key_broker => $broker2);
ok $skeid2->has_key_broker, 'has_key_broker predicate';
is $skeid2->key_broker->resolve_key('provider/groq/api-key'), 'gsk_test', 'broker resolves via skeid2';

done_testing;
