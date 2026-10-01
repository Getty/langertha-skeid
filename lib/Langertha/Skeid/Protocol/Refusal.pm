package Langertha::Skeid::Protocol::Refusal;
our $VERSION = '0.004';
# ABSTRACT: A translator's deliberate refusal of a request, with a message for the client
use strict;
use warnings;
use Carp qw( croak );

=head1 DESCRIPTION

A request translator that turns a request down on purpose -- a provider built-in tool, an image
source skeid cannot forward -- throws one of these, carrying a one-line message written for the
client. The proxy answers such a refusal with that message as a C<400>. Any other exception is a
failure of the translator's own, its text can quote the request, and the proxy answers it with a
fixed text instead.

=method refuse

  Langertha::Skeid::Protocol::Refusal->refuse('tool type is not supported');

Dies with a refusal carrying the message.

=method message

The client-facing message of a refusal.

=cut

sub refuse {
  my ( $class, $message ) = @_;
  croak(__PACKAGE__.'->refuse needs a message') unless defined $message && length $message;
  die bless { message => $message }, $class;
}

sub message { $_[0]->{message} }

1;
