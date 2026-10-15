package Langertha::Skeid::CustomerSource::DBI;
our $VERSION = '0.004';
# ABSTRACT: Blocking DBI read of the customer relation, for the fetch child
use Moo;
use strict;
use warnings;
use Carp qw(croak);
use IO::Select;

=head1 DESCRIPTION

The part of L<Langertha::Skeid::CustomerSource> that blocks: connect, query, disconnect (and,
with C<listen>, wait for a C<NOTIFY>). It runs only in a child process started by
L<Mojo::IOLoop/subprocess>; nothing here is ever called on the event loop's own process.

C<DBI> and its driver are loaded when a fetch runs, not at compile time: a Skeid without a
C<customer_source> must not need either. C<DBD::Pg> is needed for a C<dbi:Pg:> DSN;
C<DBD::SQLite> serves the offline tests.

The connection is its own -- never the usage store's handle -- and is opened for each fetch and
closed again. It reads one relation and writes nothing.

=attr dsn

The DBI data source. For PostgreSQL C<connect_timeout> is added to it unless it names one.

=attr user

=attr password

Resolved from C<password_env> by L<Langertha::Skeid::CustomerSource/normalize_config>. Held in
this object only, and scrubbed out of every error message.

=attr relation

A table or view, optionally schema-qualified; validated as an identifier, so it is safe to
place in the query text.

=attr connect_timeout_s

=attr listen

The C<NOTIFY> channel for L</listen_loop>, or undef.

=cut

has dsn               => (is => 'ro', required => 1);
has user              => (is => 'ro', default => sub { '' });
has password          => (is => 'ro', default => sub { '' });
has relation          => (is => 'ro', required => 1);
has connect_timeout_s => (is => 'ro', default => sub { 5 });
has listen            => (is => 'ro', default => sub { undef });

sub _is_pg { $_[0]->dsn =~ /\Adbi:Pg:/i ? 1 : 0 }

=method tcp_target

  my ($host, $port) = $source->tcp_target;

The host and port of a PostgreSQL DSN, for the non-blocking pre-check; an empty list when the
DSN names none (a unix socket, a file database).

=cut

sub tcp_target {
  my ($self) = @_;
  return unless $self->_is_pg;
  (my $rest = $self->dsn) =~ s/\Adbi:Pg://i;
  my %kv;
  for my $part (split /[;\s]+/, $rest) {
    my ($k, $v) = split /=/, $part, 2;
    $kv{lc $k} = $v if defined($k) && defined($v);
  }
  my $host = $kv{host} // $kv{hostaddr};
  return unless defined($host) && length($host);
  return ($host, $kv{port} || 5432);
}

sub _connect {
  my ($self) = @_;
  require DBI;
  my $dsn = $self->dsn;
  $dsn .= ';connect_timeout=' . int($self->connect_timeout_s + 0.999)
    if $self->_is_pg && $dsn !~ /connect_timeout=/i;
  my $dbh = eval {
    DBI->connect($dsn, $self->user, $self->password,
      { RaiseError => 1, PrintError => 0, AutoCommit => 1 });
  };
  unless ($dbh) {
    my $err = $@ || 'connect failed';
    croak 'customer_source: connect failed: ' . $self->_scrub($err);
  }
  return $dbh;
}

sub _scrub {
  my ($self, $text) = @_;
  my $pw = $self->password;
  $text =~ s/\Q$pw\E/***/g if defined($pw) && length($pw);
  $text =~ s/\s+/ /g;
  return $text;
}

=method fetch

  my $rows = $source->fetch;   # [[key_id, name, policy, models], ...]

Runs C<SELECT key_id, name, policy, models FROM E<lt>relationE<gt>> and returns the rows
unvalidated -- judging a row is the merge's job. Dies on a connect or query failure, which
the fetcher turns into "keep the last snapshot".

=cut

sub fetch {
  my ($self) = @_;
  my $dbh = $self->_connect;
  my $rows = eval {
    my $sth = $dbh->prepare('SELECT key_id, name, policy, models FROM ' . $self->relation);
    $sth->execute;
    my @out;
    while (my $row = $sth->fetchrow_arrayref) {
      push @out, [ map { ref($_) eq 'ARRAY' ? [ @$_ ] : $_ } @$row ];
    }
    \@out;
  };
  my $err = $@;
  eval { $dbh->disconnect };
  croak 'customer_source: query failed: ' . $self->_scrub($err) unless $rows;
  return $rows;
}

=method listen_loop

  $source->listen_loop($emit, $should_stop);

Blocks, in the listener child: connects, issues C<LISTEN>, calls C<< $emit->('ready') >>, then
C<< $emit->('notify') >> for every notification, until C<< $should_stop->() >> is true.
PostgreSQL only. A lost notification costs nothing: the poll is the floor.

=cut

sub listen_loop {
  my ($self, $emit, $should_stop) = @_;
  croak 'customer_source: listen needs PostgreSQL' unless $self->_is_pg && $self->listen;
  my $dbh = $self->_connect;
  $dbh->do('LISTEN ' . $self->listen);
  $emit->('ready');
  my $select = IO::Select->new;
  open(my $sock, '<&=', $dbh->{pg_socket}) or croak 'customer_source: no socket to wait on';
  $select->add($sock);
  until ($should_stop->()) {
    $select->can_read(2);
    my $notified = 0;
    while (my $n = $dbh->pg_notifies) { $notified++ }
    $emit->('notify') if $notified;
  }
  eval { $dbh->disconnect };
  return;
}

1;
