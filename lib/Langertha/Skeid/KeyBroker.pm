package Langertha::Skeid::KeyBroker;
our $VERSION = '0.002';
# ABSTRACT: Pluggable API key resolution for Skeid nodes
use Moo;
use Carp qw(croak);
use namespace::clean;

sub resolve_key {
  my ($self, $ref) = @_;
  croak ref($self) . " must implement resolve_key()";
}

sub needs_refresh { 0 }

sub refresh { }

1;
