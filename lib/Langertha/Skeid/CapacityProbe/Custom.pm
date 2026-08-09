package Langertha::Skeid::CapacityProbe::Custom;
our $VERSION = '0.003';
# ABSTRACT: Capacity probe backed by a caller-supplied callback
use Moo;
use Carp qw(croak);
use namespace::clean;

extends 'Langertha::Skeid::CapacityProbe';

=head1 SYNOPSIS

  $skeid->add_node(
    id => 'weird-1', url => 'http://weird-1/v1', model => 'm',
    capacity => {
      probe       => 'custom',
      interval_ms => 1000,
      code        => sub {
        my ($probe) = @_;
        my $depth = ask_the_thing();          # must not block
        $probe->skeid->set_capacity_reading($probe->node_id,
          source => 'custom', used => $depth, limit => 16);
      },
    },
  );

=head1 DESCRIPTION

Skeid fronts whatever an operator happens to run, so "any way of finding out how busy a node
is" has to be part of the contract rather than something bolted on when the built-ins run out
(ADR 0009). The built-in probes are conveniences for the engines we know about.

The callback gets the probe and reports through the same methods as any other probe:
C<set_capacity_reading> when it knows, C<forget_capacity> when it does not. It runs on a timer,
never on the request path, so it must not block — the whole process waits on it.

=cut

=attr code

The callback, called with the probe as its only argument.

=cut

has code => (
  is       => 'ro',
  required => 1,
  isa      => sub { croak 'custom capacity probe needs a coderef' unless ref($_[0]) eq 'CODE' },
);

sub poll {
  my ($self) = @_;
  return $self->code->($self);
}

1;
