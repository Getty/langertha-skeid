package Test::Skeid::Dispatch;
# ABSTRACT: A deployment's own Skeid class, for the tests: every dispatch hook overridden

# What ADR 0030 means by a deployment's class: a Langertha::Skeid subclass that carries its own
# dispatch logic through the documented hooks, and nothing else. t/101-dispatch-hooks.t drives
# it in the proxy, t/102-cli-serve-class.t through `skeid serve --class` and skeid_class.

use Moo;
use namespace::clean;
extends 'Langertha::Skeid';

# Node ids start_request refuses: a card the deployment knows to be full.
has refused => (is => 'ro', default => sub { {} });

# What finish_request saw, in order: { id, and the outcome }.
has finished => (is => 'ro', default => sub { [] });

# plan: a model named `closed` is granted to nobody.
around route_plan => sub {
  my ($orig, $self, %args) = @_;
  return { tiers => [], permitted => 0, reason => 'model_not_permitted' }
    if ($args{model} // '') eq 'closed';
  return $self->$orig(%args);
};

# pick: a node tagged `warm` before any other of the tier.
around pick_node => sub {
  my ($orig, $self, %selector) = @_;
  return $self->$orig(%selector, tags => [@{$selector{tags} || []}, 'warm'])
    // $self->$orig(%selector);
};

# admit or refuse.
around start_request => sub {
  my ($orig, $self, $id) = @_;
  return 0 if $self->refused->{$id};
  return $self->$orig($id);
};

# on finish.
around finish_request => sub {
  my ($orig, $self, $id, %args) = @_;
  push @{$self->finished}, { id => $id, %args };
  return $self->$orig($id, %args);
};

1;
