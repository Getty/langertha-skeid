package Langertha::Skeid::Secret;
our $VERSION = '0.004';
# ABSTRACT: Constant-time comparison for keys, tokens and signatures
use strict;
use warnings;
use Digest::SHA ();

=head1 SYNOPSIS

  use Langertha::Skeid::Secret;
  Langertha::Skeid::Secret->equal($presented_token, $admin_api_key) or return deny();

=head1 DESCRIPTION

Every place Skeid checks a presented secret -- the admin API key, the registry read key, a
registry snapshot signature -- compares through L</equal>, never with C<eq>/C<ne>, so a caller
cannot recover the secret one character at a time from response timing.

=method equal

  my $ok = Langertha::Skeid::Secret->equal($given, $want);

True (1) when both strings are equal, else 0. It compares the SHA-256 digests of both strings
byte by byte without short-circuiting, so the time depends neither on where they first differ
nor on either string's length. C<undef> compares as the empty string; callers that must reject
an empty or missing secret check that before calling.

=cut

sub equal {
  my ($class, $given, $want) = @_;
  my $have = Digest::SHA::sha256(defined($given) ? "$given" : '');
  my $need = Digest::SHA::sha256(defined($want)  ? "$want"  : '');
  my $diff = 0;
  $diff |= ord(substr($have, $_, 1)) ^ ord(substr($need, $_, 1)) for 0 .. length($need) - 1;
  return $diff == 0 ? 1 : 0;
}

=seealso

L<Langertha::Skeid::Proxy> (admin and registry bearer checks), L<Langertha::Skeid::Registry/verify>

=cut

1;
