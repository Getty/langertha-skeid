package Langertha::Skeid::CustomerSource::Pg;
our $VERSION = '0.004';
# ABSTRACT: Customer source fetcher on Mojo::Pg - non-blocking query, LISTEN for a sooner fetch
use Moo;
use strict;
use warnings;
use POSIX qw(ceil);
use Scalar::Util qw(weaken);
use Langertha::Skeid::CustomerSource;

=head1 SYNOPSIS

  my $fetcher = Langertha::Skeid::CustomerSource::Pg->new(config => $normalized_section);
  $fetcher->on_notify(sub { ... });          # with config listen: a NOTIFY arrived
  $fetcher->fetch(sub {
    my ($err, $rows) = @_;                   # rows: [ { key_id, name, policy, models }, ... ]
  });
  $fetcher->release;                         # close every connection; the next fetch reopens

=head1 DESCRIPTION

The fetcher L<Langertha::Skeid> uses for a C<customer_source> section unless it was given
another (L<Langertha::Skeid/customer_source_fetcher>). It runs
L<Langertha::Skeid::CustomerSource/statement> through L<Mojo::Pg>, whose queries are
non-blocking: DBD::Pg's asynchronous mode, with the socket watched by the L<Mojo::IOLoop>
reactor. L<Mojo::Pg> is loaded on the first fetch, never by building the object, and is a
C<recommends> of this distribution together with DBD::Pg.

B<Connecting is not asynchronous.> DBD::Pg has no non-blocking connect, so opening a
connection blocks the event loop until the database answers or C<connect_timeout_s> runs out
(it is put into the DSN as libpq's C<connect_timeout>, which counts whole seconds and at least
2). That happens once per process while the connection lives -- not per fetch -- and again
after the connection was lost. Each query is bounded by C<statement_timeout>, set to
C<connect_timeout_s> on the connection.

With C<listen> in the config, a second connection C<LISTEN>s on that channel through
L<Mojo::Pg::PubSub>, which reconnects by itself, and calls the C<on_notify> callback for every
notification; the payload is ignored. Its C<LISTEN> is set up with the first fetch in the
process, and tried again with each fetch until it succeeded.

Connections belong to the process that opened them: after a fork the next fetch opens its own,
and L</release> closes them on purpose -- C<skeid serve> calls it before the prefork manager
forks.

=attr config

The normalized C<customer_source> section (L<Langertha::Skeid::CustomerSource/normalize_config>).
Required.

=cut

has config => (is => 'ro', required => 1);

has _pg        => (is => 'rw');
has _pid       => (is => 'rw', default => sub { 0 });
has _notify    => (is => 'rw');
has _listening => (is => 'rw', default => sub { 0 });

=method statement

The statement every fetch runs, from L<Langertha::Skeid::CustomerSource/statement>.

=cut

sub statement {
  my ($self) = @_;
  return Langertha::Skeid::CustomerSource->statement($self->config->{relation});
}

=method dsn

The DSN the connection uses: the configured one, with C<connect_timeout> added unless it names
one.

=cut

sub dsn {
  my ($self) = @_;
  my $dsn = $self->config->{dsn};
  return $dsn if $dsn =~ /\bconnect_timeout=/i;
  my $seconds = ceil($self->config->{connect_timeout_s} // 5);
  $seconds = 2 if $seconds < 2;
  return $dsn . ($dsn =~ /[:;]\z/ ? '' : ';') . "connect_timeout=$seconds";
}

=method fetch

  $fetcher->fetch(sub { my ($err, $rows) = @_; ... });

Runs the statement without blocking and calls back with the rows as hashes, C<models> as an
array reference, or with the error. A connection that cannot be opened is an error too.

=cut

sub fetch {
  my ($self, $cb) = @_;
  my $db = eval { $self->_connection->db };
  return $cb->($@ || 'could not connect') unless $db;
  $self->_listen unless $self->_listening;
  $db->query($self->statement, sub {
    my ($db, $err, $results) = @_;
    return $cb->($err) if $err;
    my $rows = eval { $results->hashes->to_array };
    return $cb->($@ || 'could not read the rows') unless $rows;
    return $cb->(undef, $rows);
  });
  return;
}

=method on_notify

  $fetcher->on_notify(sub { ... });

The callback for a notification on the configured C<listen> channel. Without C<listen> it is
never called.

=cut

sub on_notify {
  my ($self, $cb) = @_;
  $self->_notify($cb);
  return;
}

=method release

Closes every connection this object holds, its C<LISTEN> included. The next fetch opens new
ones.

=cut

sub release {
  my ($self) = @_;
  my $pg = $self->_pg;
  if ($pg && $self->_pid == $$) {
    eval { $pg->pubsub->reset if $self->_listening; 1 };
  }
  $self->_pg(undef);
  $self->_listening(0);
  return;
}

# The Mojo::Pg of this process, built on first use. One built by the parent of a fork is
# dropped, not used: its connections are the parent's.
sub _connection {
  my ($self) = @_;
  if (!$self->_pg || $self->_pid != $$) {
    $self->_pg(undef);
    $self->_listening(0);
    require Mojo::Pg;
    my $cfg = $self->config;
    my $pg = Mojo::Pg->new;
    $pg->dsn($self->dsn);
    $pg->username($cfg->{user}) if defined($cfg->{user}) && length($cfg->{user});
    $pg->password($cfg->{password}) if defined($cfg->{password}) && length($cfg->{password});
    $pg->max_connections(1);
    my $ms = int(1000 * ($cfg->{connect_timeout_s} // 5));
    $pg->on(connection => sub {
      my ($pg, $dbh) = @_;
      eval { $dbh->do("SET statement_timeout = $ms"); 1 };
    });
    $self->_pg($pg);
    $self->_pid($$);
  }
  return $self->_pg;
}

sub _listen {
  my ($self) = @_;
  my $channel = $self->config->{listen};
  return unless defined($channel) && length($channel);
  my $weak = $self;
  weaken($weak);
  my $ok = eval {
    $self->_connection->pubsub->listen($channel => sub {
      my $cb = $weak && $weak->_notify;
      $cb->() if $cb;
    });
    1;
  };
  $self->_listening($ok ? 1 : 0);
  return;
}

sub DEMOLISH {
  my ($self, $global) = @_;
  return if $global;
  $self->release;
}

=seealso

=over 4

=item * L<Langertha::Skeid::CustomerSource> -- the fetcher contract, the row contract, the loop

=item * L<Langertha::Skeid/customer_source>

=back

=cut

1;
