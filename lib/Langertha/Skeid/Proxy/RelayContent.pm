package Langertha::Skeid::Proxy::RelayContent;
our $VERSION = '0.003';
# ABSTRACT: Upstream response content that is always relayed as raw bytes
use Mojo::Base 'Mojo::Content::Single';

=head1 DESCRIPTION

The content object the proxy puts on a streaming upstream response before starting it: a
L<Mojo::Content::Single> that never takes Mojolicious's own Server-Sent Events path.

Mojolicious parses a response body itself when its C<Content-Type> is exactly
C<text/event-stream> (no parameters) and the body is not chunked: the bytes become C<sse> events
and no C<read> event is ever emitted. The relay reads the upstream on C<read>, so such an
upstream would be relayed as nothing and metered as a served request without tokens. Skeid
reads the SSE frames itself and relays them byte for byte, so it needs the bytes whatever the
exact media type or framing.

  my $tx = $ua->build_tx(POST => $url, \%headers, json => $body);
  $tx->res->content(Langertha::Skeid::Proxy::RelayContent->new);
  $tx->res->content->unsubscribe('read')->on(read => sub { ... });

=method is_sse

Always false, so the body is parsed as plain content and every byte arrives on C<read>.

=cut

sub is_sse {0}

1;
