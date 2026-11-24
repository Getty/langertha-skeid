package Langertha::Skeid::Proxy::Linger;
our $VERSION = '0.006';
# ABSTRACT: Close a connection its peer still sends on without resetting it
use strict;
use warnings;
use Mojo::IOLoop::Stream;
use Scalar::Util qw( refaddr );

=head1 SYNOPSIS

  use Langertha::Skeid::Proxy::Linger;
  Langertha::Skeid::Proxy::Linger->on_close(Mojo::IOLoop->stream($tx->connection));
  $tx->finish(1013);

=head1 DESCRIPTION

A connection closed while data its peer sent is still unread is reset, not ended. A peer on
Linux reads what came before the reset; one on Windows, Cygwin or Haiku drops it, and with it
the answer it had not read yet -- a 413 sent before the body, the close frame of a WebSocket
session. Skeid closes such a connection the way an HTTP server does: it ends its own side, so
the peer reads the answer and then the end of the stream, reads off and drops what the peer
still sends, and closes once the peer has finished, has been quiet for 2 seconds, or after 10
seconds.

Mojolicious closes a stream by letting go of its handle, and the socket closes once nothing
holds it. L</on_close> holds it from the stream's C<close> event on, so the event loop and the
server let go of the connection exactly as on any other close.

=method on_close

  Langertha::Skeid::Proxy::Linger->on_close($stream);

Arms a L<Mojo::IOLoop::Stream>: once it closes, its connection lingers as described above. A
missing or already closed stream is ignored.

=cut

my $IDLE = 2;
my $MAX  = 10;

# The connections lingering now: each is held here until it closes.
my %LINGERING;

sub on_close {
  my ($class, $stream) = @_;
  return unless $stream && (my $handle = $stream->handle);
  my $reactor = $stream->reactor;
  $stream->once(close => sub { _linger($reactor, $handle) });
  return;
}

sub _linger {
  my ($reactor, $handle) = @_;
  shutdown $handle, 1;
  my $linger = Mojo::IOLoop::Stream->new($handle);
  $linger->reactor($reactor)->timeout($IDLE);
  my $key = refaddr $linger;
  my $timer = $reactor->timer($MAX => sub { $LINGERING{$key}->close if $LINGERING{$key} });
  $linger->on(error => sub { });
  $linger->on(close => sub { $reactor->remove($timer); delete $LINGERING{$key} });
  $LINGERING{$key} = $linger;
  $linger->start;
  return;
}

=seealso

L<Langertha::Skeid::Proxy>, L<Langertha::Skeid::Proxy::Realtime>

=cut

1;
