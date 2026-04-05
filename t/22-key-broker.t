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

done_testing;
