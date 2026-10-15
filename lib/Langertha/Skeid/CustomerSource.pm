package Langertha::Skeid::CustomerSource;
our $VERSION = '0.004';
# ABSTRACT: Customer keys, names and policies from a database view, fetched in the background
use Moo;
use strict;
use warnings;
use Carp qw(croak);
use Digest::SHA qw(sha256_hex);
use JSON::MaybeXS ();
use Mojo::IOLoop;
use Scalar::Util qw(weaken);
use Time::HiRes ();
use POSIX qw(strftime);
use Langertha::Skeid::CustomerSource::DBI;

=head1 SYNOPSIS

  customer_source:
    dsn: dbi:Pg:dbname=customers;host=db.internal
    user: skeid_ro
    password_env: SKEID_CUSTOMERS_PASSWORD
    relation: skeid_customer_keys
    poll_interval_s: 30

=head1 DESCRIPTION

An optional C<customer_source:> section names a database relation Skeid reads for the caller
side of its config (ADR 0026). The contract is

  SELECT key_id, name, policy, models FROM <relation>

one row per active customer key id; a revoked key is a row that is absent. This class is the
background fetcher and the merge: it never runs on the request path.

A fetch is a L<Mojo::IOLoop/subprocess>: connect and query are ordinary blocking DBI in a child
process (a blocking C<DBI-E<gt>connect> on the loop would stall every in-flight stream, k109),
and the parent receives only the finished rows. Before forking, a non-blocking TCP connect to
the DSN's host and port skips the fork -- and backs off -- when the port is closed or
blackholed. The child runs under a deadline (C<connect_timeout_s> plus a margin) and is killed
when it overruns it. With C<listen:> a second, long-lived child waits for C<NOTIFY> and wakes
the poll; the poll stays the floor.

The fetcher holds the I<last good snapshot>: a failed fetch keeps it, and C<max_stale_s>
drops one that got too old. The snapshot takes part in the config fingerprint of
L<Langertha::Skeid>, so a changed snapshot is applied by the next config reload exactly like a
changed file.

=cut

my %KNOWN = map { $_ => 1 } qw(
  dsn from_usage_store user password_env relation
  poll_interval_s max_stale_s connect_timeout_s listen
);
my $IDENT = qr/[A-Za-z_][A-Za-z0-9_]*/;

# What a child may overrun its connect timeout by before the parent kills it.
our $DEADLINE_MARGIN_S = 5;
# Longest wait between two fetches of a failing source.
my $BACKOFF_MAX_S = 300;
# Net::DNS::Native makes Mojo::IOLoop::Client resolve names without blocking; without it a
# hostname is resolved synchronously, so the pre-check only runs for an address literal.
my $NONBLOCKING_DNS = $ENV{MOJO_NO_NNR} ? 0 : eval { require Net::DNS::Native; 1 } ? 1 : 0;

=method normalize_config

  my $cfg = Langertha::Skeid::CustomerSource->normalize_config($section, usage_store => $usage_cfg);

Validates the C<customer_source> section and fills its defaults. Croaks -- a failed config
load -- on a section that is not a hash, an unknown key, a literal C<password>, a C<relation>
that is not a (schema-qualified) identifier, a DSN that is neither C<dbi:Pg:> nor
C<dbi:SQLite:>, C<listen> on anything but PostgreSQL, a number out of range, and
C<from_usage_store> without a usage store that names a database. The password is read from
C<password_env> here and never appears in a message.

=cut

sub normalize_config {
  my ($class, $section, %opt) = @_;
  croak 'customer_source must be a hash' unless ref($section) eq 'HASH';
  croak 'customer_source: a password is never written into the config; name the environment '
    . 'variable that holds it with password_env' if exists $section->{password};
  for my $key (sort keys %$section) {
    croak "customer_source: unknown key '$key' (known: " . join(' ', sort keys %KNOWN) . ')'
      unless $KNOWN{$key};
  }

  my ($dsn, $user, $password) = ($section->{dsn}, $section->{user}, '');
  my $env = $section->{password_env};
  if ($section->{from_usage_store}) {
    my $usage = $opt{usage_store};
    croak 'customer_source.from_usage_store needs a usage_store section naming a database'
      unless ref($usage) eq 'HASH';
    require Langertha::Skeid::UsageStore;
    my $norm = Langertha::Skeid::UsageStore->normalize_config($usage);
    croak 'customer_source.from_usage_store needs a sqlite or postgresql usage_store'
      unless $norm->{backend} eq 'sqlite' || $norm->{backend} eq 'postgresql';
    ($dsn, $user, $password) = ($norm->{dsn}, $norm->{user}, $norm->{password});
  } else {
    croak 'customer_source.dsn is required (or from_usage_store: true)'
      unless defined($dsn) && length($dsn);
    $user = '' unless defined $user;
    $password = $ENV{$env} // '' if defined($env) && length($env);
  }
  croak 'customer_source.dsn must be a dbi:Pg: or dbi:SQLite: data source'
    unless $dsn =~ /\Adbi:(?:Pg|SQLite):/i;
  my $driver = $dsn =~ /\Adbi:Pg:/i ? 'Pg' : 'SQLite';

  my $relation = $section->{relation};
  croak 'customer_source.relation is required (a table or view, schema-qualified allowed)'
    unless defined($relation) && length($relation);
  croak 'customer_source.relation must be a table or view name, optionally schema-qualified'
    unless $relation =~ /\A$IDENT(?:\.$IDENT)?\z/;

  my $listen = $section->{listen};
  if (defined($listen) && length($listen)) {
    croak 'customer_source.listen is a PostgreSQL feature' unless $driver eq 'Pg';
    croak 'customer_source.listen must be a channel name'
      unless $listen =~ /\A$IDENT\z/;
  } else {
    $listen = undef;
  }

  my %num = (poll_interval_s => [ 30, 1 ], max_stale_s => [ 0, 0 ], connect_timeout_s => [ 5, 1 ]);
  my %out;
  for my $key (sort keys %num) {
    my ($default, $min) = @{ $num{$key} };
    my $value = defined($section->{$key}) ? $section->{$key} : $default;
    croak "customer_source.$key must be a number of seconds, at least $min"
      unless !ref($value) && $value =~ /\A\d+(?:\.\d+)?\z/ && $value >= $min;
    $out{$key} = 0 + $value;
  }

  return {
    dsn      => $dsn,
    driver   => $driver,
    user     => $user,
    password => $password,
    relation => $relation,
    listen   => $listen,
    %out,
  };
}

has config => (is => 'ro', required => 1);

=attr source

The object that reads the relation: C<fetch> returns the rows, C<tcp_target> the host and port
to pre-check, C<listen_loop> waits for notifications. Defaults to
L<Langertha::Skeid::CustomerSource::DBI> built from C<config>; a test passes a fake.

=cut

has source => (is => 'lazy');

sub _build_source {
  my ($self) = @_;
  my $c = $self->config;
  return Langertha::Skeid::CustomerSource::DBI->new(
    map { $_ => $c->{$_} } qw(dsn user password relation connect_timeout_s listen),
  );
}

=attr clock

Code ref returning the current time; defaults to L<Time::HiRes/time>. For tests.

=cut

has clock => (is => 'ro', default => sub { sub { Time::HiRes::time() } });

has snapshot => (is => 'rw', default => sub { undef });
has failures => (is => 'rw', default => sub { 0 });
has last_ok_at => (is => 'rw', default => sub { undef });
has error_kind => (is => 'rw', default => sub { undef });
has error_at => (is => 'rw', default => sub { undef });
has fetches => (is => 'rw', default => sub { 0 });
has precheck_skips => (is => 'rw', default => sub { 0 });
has _timer => (is => 'rw');
has _deadline => (is => 'rw');
has _sub => (is => 'rw');
has _inflight => (is => 'rw', default => sub { 0 });
has _again => (is => 'rw', default => sub { 0 });
has _stopped => (is => 'rw', default => sub { 1 });
has _listener => (is => 'rw');
has _listener_timer => (is => 'rw');
has _listener_failures => (is => 'rw', default => sub { 0 });
has _generation => (is => 'rw', default => sub { 0 });

sub _now { $_[0]->clock->() }

=method start

Begins polling: the first fetch is the next tick of the loop, then one every
C<poll_interval_s> (plus up to 10% jitter). Returns the fetcher.

=cut

sub start {
  my ($self) = @_;
  return $self unless $self->_stopped;
  $self->_stopped(0);
  $self->_schedule(0);
  $self->_start_listener;
  return $self;
}

=method stop

Stops polling, kills a running child and the listener. The snapshot stays.

=cut

sub stop {
  my ($self) = @_;
  $self->_stopped(1);
  for my $slot (qw(_timer _deadline _listener_timer)) {
    my $id = $self->$slot;
    Mojo::IOLoop->remove($id) if defined $id;
    $self->$slot(undef);
  }
  $self->_generation($self->_generation + 1);
  $self->_kill($self->_sub);
  $self->_sub(undef);
  $self->_kill($self->_listener);
  $self->_listener(undef);
  $self->_inflight(0);
  return $self;
}

sub DEMOLISH {
  my ($self) = @_;
  $self->stop if !$self->_stopped;
  return;
}

sub _kill {
  my ($self, $sub) = @_;
  return unless $sub;
  my $pid = $sub->pid;
  kill 'KILL', $pid if $pid;
  return;
}

=method fetch_now

Asks for a fetch at once. A fetch already running is followed by another when it ends.

=cut

sub fetch_now {
  my ($self) = @_;
  return if $self->_stopped;
  if ($self->_inflight) {
    $self->_again(1);
    return;
  }
  $self->_schedule(0);
  return;
}

sub _schedule {
  my ($self, $delay) = @_;
  return if $self->_stopped;
  if (defined(my $old = $self->_timer)) { Mojo::IOLoop->remove($old) }
  weaken(my $weak = $self);
  my $generation = $self->_generation;
  $self->_timer(Mojo::IOLoop->timer($delay => sub {
    return unless $weak && $weak->_generation == $generation;
    $weak->_timer(undef);
    $weak->_tick;
  }));
  return;
}

sub _next_delay {
  my ($self) = @_;
  my $poll = $self->config->{poll_interval_s};
  my $n = $self->failures;
  return $poll * (1 + rand(0.1)) unless $n;
  my $delay = $poll * 2 ** ($n - 1);
  my $cap = $BACKOFF_MAX_S > $poll ? $BACKOFF_MAX_S : $poll;
  return $delay > $cap ? $cap : $delay;
}

sub _tick {
  my ($self) = @_;
  return if $self->_stopped || $self->_inflight;
  $self->_inflight(1);
  $self->fetches($self->fetches + 1);

  my ($host, $port) = $self->source->tcp_target;
  if (defined($host) && length($host) && $port && $self->_can_precheck($host)) {
    weaken(my $weak = $self);
    my $generation = $self->_generation;
    my $timeout = $self->config->{connect_timeout_s};
    $timeout = 3 if $timeout > 3;
    Mojo::IOLoop->client({ address => $host, port => $port, timeout => $timeout } => sub {
      my ($loop, $err, $stream) = @_;
      return unless $weak && $weak->_generation == $generation;
      if ($err) {
        $weak->precheck_skips($weak->precheck_skips + 1);
        return $weak->_failed('tcp', 'the database port did not accept a connection');
      }
      $stream->close;
      $weak->_fork_fetch;
    });
    return;
  }
  $self->_fork_fetch;
  return;
}

sub _can_precheck {
  my ($self, $host) = @_;
  return 0 if $host =~ m{\A/} || $host =~ /,/;
  return 1 if $host =~ /\A\d+\.\d+\.\d+\.\d+\z/ || $host =~ /\A[0-9a-fA-F:]+\z/;
  return $NONBLOCKING_DNS;
}

sub _fork_fetch {
  my ($self) = @_;
  my $source = $self->source;
  my $sub = Mojo::IOLoop->subprocess;
  $self->_sub($sub);
  weaken(my $weak = $self);
  my $generation = $self->_generation;
  my $done = 0;

  my $deadline = $self->config->{connect_timeout_s} + $DEADLINE_MARGIN_S;
  $self->_deadline(Mojo::IOLoop->timer($deadline => sub {
    return unless $weak && $weak->_generation == $generation && !$done;
    $done = 1;
    $weak->_deadline(undef);
    $weak->_kill($sub);
    $weak->_failed('timeout', 'the fetch overran its deadline and was killed');
  }));

  $sub->run(
    sub { return $source->fetch },
    sub {
      my ($sp, $err, $rows) = @_;
      return unless $weak && !$done && $weak->_generation == $generation;
      $done = 1;
      if (defined(my $id = $weak->_deadline)) { Mojo::IOLoop->remove($id); $weak->_deadline(undef) }
      $weak->_sub(undef);
      return $weak->_failed(($err =~ /connect failed/ ? 'connect' : 'query'), $err) if $err;
      return $weak->_failed('query', 'the source returned no rows list') unless ref($rows) eq 'ARRAY';
      $weak->_succeeded($rows);
    },
  );
  return;
}

sub _scrub {
  my ($self, $text) = @_;
  $text = '' unless defined $text;
  my $pw = $self->config->{password};
  $text =~ s/\Q$pw\E/***/g if defined($pw) && length($pw);
  $text =~ s/\s+/ /g;
  $text =~ s/\A\s+|\s+\z//g;
  return length($text) > 300 ? substr($text, 0, 300) . '...' : $text;
}

sub _succeeded {
  my ($self, $rows) = @_;
  my $now = $self->_now;
  my $digest = $self->_rows_digest($rows);
  $self->snapshot({ rows => $rows, fetched_at => $now, digest => $digest });
  $self->last_ok_at($now);
  if ($self->failures) {
    warn "skeid: customer_source: fetch succeeded again after " . $self->failures
      . " failure(s)\n";
  }
  $self->failures(0);
  $self->error_kind(undef);
  $self->error_at(undef);
  $self->_finish_cycle;
  return;
}

sub _failed {
  my ($self, $kind, $detail) = @_;
  my $previous = $self->error_kind;
  $self->failures($self->failures + 1);
  $self->error_kind($kind);
  $self->error_at($self->_now);
  # Logged when the kind is new; the same outage again, retry after retry, is not.
  warn 'skeid: customer_source: fetch failed (' . $kind . '), keeping the last snapshot: '
    . $self->_scrub($detail) . "\n"
    unless defined($previous) && $previous eq $kind;
  $self->_finish_cycle;
  return;
}

sub _finish_cycle {
  my ($self) = @_;
  $self->_inflight(0);
  if ($self->_again) {
    $self->_again(0);
    return $self->_schedule(0);
  }
  $self->_schedule($self->_next_delay);
  return;
}

# A digest of the rows, order-independent: the database is free to return them in any order.
sub _rows_digest {
  my ($self, $rows) = @_;
  my @lines = sort map {
    my $row = $_;
    join("\0", map {
      my $v = ref($_) eq 'ARRAY' ? join("\1", @$_) : $_;
      defined($v) ? 's' . length($v) . ':' . $v : 'u';
    } @$row);
  } @$rows;
  return sha256_hex(join("\n", scalar(@lines), @lines));
}

=method effective_snapshot

  my $snapshot = $fetcher->effective_snapshot;

The last good snapshot, C<{ rows, fetched_at, digest }>, or undef when there is none yet or
C<max_stale_s> is set and it is older than that. Cheap: called on the request path.

=cut

sub effective_snapshot {
  my ($self) = @_;
  my $snap = $self->snapshot or return;
  my $max = $self->config->{max_stale_s};
  return if $max > 0 && $self->_now - $snap->{fetched_at} > $max;
  return $snap;
}

=method digest

The digest of the snapshot in force, or C<none>. It is what the config fingerprint carries.

=cut

sub digest {
  my ($self) = @_;
  my $snap = $self->effective_snapshot;
  return $snap ? $snap->{digest} : 'none';
}

=method status

  my $status = $fetcher->status;

What an operator wants to know: whether a snapshot is in force, its age, and the last failure's
kind. The failure's text is logged, never returned (this is served on C</health>'s sibling
routes and must not name hosts).

=cut

sub status {
  my ($self) = @_;
  my $snap = $self->snapshot;
  my $eff  = $self->effective_snapshot;
  my $iso = sub { strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($_[0])) };
  return {
    snapshot  => $eff ? 1 : 0,
    rows      => $eff ? scalar(@{ $eff->{rows} }) : 0,
    stale     => ($snap && !$eff) ? 1 : 0,
    ($snap ? (fetched_at => $iso->($snap->{fetched_at}),
              age_s      => int($self->_now - $snap->{fetched_at})) : ()),
    ok        => defined($self->error_kind) ? 0 : 1,
    failures  => $self->failures,
    (defined($self->error_kind) ? (error_kind => $self->error_kind,
                                   failed_at  => $iso->($self->error_at)) : ()),
  };
}

# --- the listener ----------------------------------------------------------------------------

sub _start_listener {
  my ($self) = @_;
  return if $self->_stopped || !$self->config->{listen} || $self->_listener;
  my $source = $self->source;
  my $sub = Mojo::IOLoop->subprocess;
  $self->_listener($sub);
  weaken(my $weak = $self);
  my $generation = $self->_generation;
  my $parent = $$;
  my $ready = 0;

  $sub->on(progress => sub {
    my ($sp, $msg) = @_;
    return unless $weak && $weak->_generation == $generation;
    if (($msg // '') eq 'ready') {
      $ready = 1;
      $weak->_listener_failures(0);
      if (defined(my $id = $weak->_listener_timer)) { Mojo::IOLoop->remove($id); $weak->_listener_timer(undef) }
    } elsif (($msg // '') eq 'notify') {
      $weak->fetch_now;
    }
  });

  # A listener that never gets as far as LISTEN is a blocked connect: killed like a fetch.
  my $deadline = $self->config->{connect_timeout_s} + $DEADLINE_MARGIN_S;
  $self->_listener_timer(Mojo::IOLoop->timer($deadline => sub {
    return unless $weak && $weak->_generation == $generation && !$ready;
    $weak->_listener_timer(undef);
    $weak->_kill($sub);
  }));

  $sub->run(
    sub {
      my ($sp) = @_;
      $source->listen_loop(sub { $sp->progress($_[0]) }, sub { getppid() != $parent });
      return 1;
    },
    sub {
      my ($sp, $err) = @_;
      return unless $weak && $weak->_generation == $generation;
      $weak->_listener(undef);
      if (defined(my $id = $weak->_listener_timer)) { Mojo::IOLoop->remove($id); $weak->_listener_timer(undef) }
      my $n = $weak->_listener_failures + 1;
      $weak->_listener_failures($n);
      return if $weak->_stopped;
      warn "skeid: customer_source: the NOTIFY listener ended, polling stays in force: "
        . $weak->_scrub($err // 'child exited') . "\n" if $n == 1;
      my $poll = $weak->config->{poll_interval_s};
      my $wait = $poll * 2 ** ($n - 1);
      $wait = $BACKOFF_MAX_S if $wait > $BACKOFF_MAX_S;
      my $gen = $weak->_generation;
      $weak->_listener_timer(Mojo::IOLoop->timer($wait => sub {
        return unless $weak && $weak->_generation == $gen;
        $weak->_listener_timer(undef);
        $weak->_start_listener;
      }));
    },
  );
  return;
}

# --- the merge -------------------------------------------------------------------------------

=method merge

  my ($merged, $report) = Langertha::Skeid::CustomerSource->merge($cfg, $snapshot);

Applies a snapshot to a copy of a config hash (the original is not touched). Rows are validated
one at a time against the config's own C<policies>; a row that fails grants nothing and is
counted in C<< $report->{rejected} >> with its position and a fixed reason, never its value
(ADR 0003). A key id the file already names (C<keys:>, C<names:>) is taken from the file and
counted as shadowed. With a C<client_auth> section the accepted ids join its list; without one
they are not added to anything. A row's C<models> narrows the policy it selects (the
intersection with the profile's own list), it never widens it.

C<$report> is C<< { accepted, shadowed, rejected => [{ position, reason }], names => { id => name } } >>.
A snapshot of C<undef> merges nothing.

=cut

sub merge {
  my ($class, $cfg, $snapshot) = @_;
  my %report = (accepted => 0, shadowed => 0, rejected => [], names => {});
  return ($cfg, \%report) unless $snapshot;

  my $policies = ref($cfg->{policies}) eq 'HASH' ? $cfg->{policies} : {};
  my $file_keys  = ref($cfg->{keys}) eq 'HASH' ? $cfg->{keys} : {};
  my $file_names = ref($cfg->{names}) eq 'HASH' ? $cfg->{names} : {};

  my %claimed;
  for my $label (keys %$file_keys) {
    my $id = exists $file_names->{$label} ? $file_names->{$label} : $label;
    $claimed{$id} = 1 if defined($id) && !ref($id);
  }
  for my $id (values %$file_names) { $claimed{$id} = 1 if defined($id) && !ref($id) }

  my $rows = $snapshot->{rows};
  my %count;
  for my $row (@$rows) {
    my $id = ref($row) eq 'ARRAY' ? $row->[0] : undef;
    $count{$id}++ if defined($id) && !ref($id);
  }

  my (%entries, @allowed, %names);
  my $position = 0;
  ROW: for my $row (@$rows) {
    $position++;
    my $reject = sub { push @{ $report{rejected} }, { position => $position, reason => $_[0] }; };
    unless (ref($row) eq 'ARRAY') { $reject->('row is not a record'); next ROW }
    my ($id, $name, $policy, $models) = @$row;

    unless (defined($id) && !ref($id) && $id =~ /\Ak_[0-9a-f]{40}\z/) {
      $reject->('key_id is not k_ + 40 lowercase hex');
      next ROW;
    }
    if ($count{$id} > 1) { $reject->('key_id is not unique in the relation'); next ROW }
    my $short = substr($id, 0, 14);
    if ($claimed{$id} || $claimed{$short} || exists $file_names->{$id}) {
      $report{shadowed}++;
      next ROW;
    }

    my $profile;
    if (defined($policy) && length($policy)) {
      if (ref($policy) || !exists $policies->{$policy}) {
        $reject->('policy is not defined in the file\'s policies');
        next ROW;
      }
      $profile = $policies->{$policy};
    } else {
      $policy = undef;
      my $default = $cfg->{default_policy};
      $profile = $policies->{$default} if defined($default) && !ref($default) && exists $policies->{$default};
    }

    my $list;
    if (defined($models) && !(!ref($models) && !length($models))) {
      my $decoded = $models;
      unless (ref($models) eq 'ARRAY') {
        $decoded = eval { JSON::MaybeXS->new(utf8 => 0)->decode($models) };
      }
      unless (ref($decoded) eq 'ARRAY' && @$decoded
              && !grep { !defined($_) || ref($_) || !length($_) || $_ eq '*' } @$decoded) {
        $reject->('models is not a non-empty JSON list of model names');
        next ROW;
      }
      my %seen;
      $list = [ grep { !$seen{$_}++ } @$decoded ];
      my $base = $class->_allowed_list($profile);
      if ($base) {
        my %in = map { $_ => 1 } @$base;
        $list = [ grep { $in{$_} } @$list ];
        unless (@$list) { $reject->('models has nothing the policy allows'); next ROW }
      }
    }

    $entries{$id} = !defined($list) ? (defined($policy) ? $policy : undef)
                  : defined($policy) ? { policy => $policy, models => $list }
                  : { models => $list };
    push @allowed, $id;
    $report{accepted}++;
    if (defined($name) && !ref($name) && length($name)) {
      (my $clean = $name) =~ s/[[:cntrl:]]//g;
      $names{$id} = length($clean) > 200 ? substr($clean, 0, 200) : $clean;
    }
  }
  $report{names} = \%names;

  my %merged = %$cfg;
  my %add = map { $_ => $entries{$_} } grep { defined $entries{$_} } keys %entries;
  if (%add) {
    $merged{keys} = { %$file_keys, %add };
  }
  if (ref($cfg->{client_auth}) eq 'HASH' && defined $cfg->{client_auth}{keys}) {
    my $list = $cfg->{client_auth}{keys};
    $list = [ $list ] unless ref $list;
    if (ref($list) eq 'ARRAY') {
      $merged{client_auth} = { %{ $cfg->{client_auth} }, keys => [ @$list, @allowed ] };
    }
  }
  return (\%merged, \%report);
}

# The model list a policy profile allows, mirroring Skeid::resolve_policy: undef means all.
sub _allowed_list {
  my ($class, $spec) = @_;
  return unless ref($spec) eq 'HASH';
  my $allow = $spec->{models} // $spec->{aliases};
  return unless defined $allow;
  my @list = ref($allow) eq 'ARRAY' ? @$allow : split(/[,\s]+/, "$allow");
  @list = grep { defined && length } @list;
  return if grep { $_ eq '*' } @list;
  return \@list;
}

=seealso

=over 4

=item * F<docs/adr/0026-customer-keys-can-come-from-a-database-view.md>

=item * L<Langertha::Skeid::CustomerSource::DBI> -- the blocking read that runs in the child

=item * L<Langertha::Skeid/customer_source_status>

=back

=cut

1;
