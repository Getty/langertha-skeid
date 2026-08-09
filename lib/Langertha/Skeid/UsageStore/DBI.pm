package Langertha::Skeid::UsageStore::DBI;
our $VERSION = '0.003';
# ABSTRACT: SQLite and PostgreSQL usage store
use Moo;
use strict;
use warnings;
use Carp qw(croak);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::ShareDir qw(dist_dir);
use Langertha::Skeid::UsageStore;

=head1 DESCRIPTION

Usage events in a real database — SQLite for a single box, PostgreSQL for a deployment. Both
speak the same C<usage_events> table, shipped as F<share/sql/usage_events.E<lt>backendE<gt>.sql>.

Writing here costs a synchronous database round-trip on the request path, which is why
L<Langertha::Skeid::UsageStore::JsonLog> is the recommended default and this backend is a
deliberate choice. See F<docs/adr/0004-usage-events-are-the-billing-unit.md>.

C<DBI> is loaded at runtime rather than compile time: a Skeid that never configures a database
backend must not require one to be installed.

=attr backend

C<sqlite> or C<postgresql>. Decides the schema file and whether an insert can report a row id.

=attr dsn, user, password

Connect info, as normalized by L<Langertha::Skeid::UsageStore>.

=attr path

SQLite database file. Its parent directory is created on connect. Empty for PostgreSQL.

=attr schema_file

Explicit schema path. Empty means "find the shipped one for this backend".

=attr auto_migrate

Apply the schema when the store is prepared. On by default.

=cut

has backend      => (is => 'ro', required => 1);
has dsn          => (is => 'ro', required => 1);
has user         => (is => 'ro', default => sub { '' });
has password     => (is => 'ro', default => sub { '' });
has path         => (is => 'ro', default => sub { '' });
has schema_file  => (is => 'ro', default => sub { '' });
has auto_migrate => (is => 'ro', default => sub { 1 });

has _dbh => (is => 'rw');

=method prepare

Connects if possible and applies the schema when C<auto_migrate> is on. Returns false without
complaint when C<DBI> is unavailable — an unusable store degrades to "no usage recorded", it
does not take the proxy down.

=cut

sub prepare {
  my ($self) = @_;
  my $dbh = $self->dbh or return;
  return 1 unless $self->auto_migrate;

  my $schema_file = $self->schema_file;
  $schema_file = $self->shipped_schema_file unless length $schema_file;
  croak "usage schema file not found: $schema_file" unless -f $schema_file;

  my $sql = Langertha::Skeid::UsageStore::read_text_file($schema_file);
  my @stmts = grep { /\S/ } map {
    my $s = $_;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    $s;
  } split /;\s*(?:\n|$)/, $sql;
  # Tables first, then any column an older table is missing, then the rest. The index
  # statements reference columns, so on an upgraded table they only work after the ALTER --
  # running the file top to bottom fails on exactly the deployments this exists for.
  my (@tables, @rest);
  for my $stmt (@stmts) {
    if ($stmt =~ /\A\s*CREATE\s+TABLE\b/i) { push @tables, $stmt }
    else                                   { push @rest, $stmt }
  }
  $dbh->do($_) for @tables;
  $self->_add_missing_columns($dbh);
  $dbh->do($_) for @rest;
  return 1;
}

# The shipped schema is CREATE TABLE IF NOT EXISTS, so it does nothing to a table that already
# exists -- a deployment that upgrades Skeid keeps its old columns and every insert naming a
# new one fails. Usage failures are reported rather than thrown, so that would show up as
# silently missing billing data. Adding the column is the whole migration story; nothing here
# ever drops or rewrites one.
my @ADDED_COLUMNS = (
  ['requested_model', 'TEXT'],
);

sub _add_missing_columns {
  my ($self, $dbh) = @_;

  my $existing = eval {
    my $sth = $dbh->prepare('SELECT * FROM usage_events WHERE 1=0');
    $sth->execute;
    my %cols = map { lc($_) => 1 } @{ $sth->{NAME_lc} || [] };
    $sth->finish;
    \%cols;
  } or return;

  for my $column (@ADDED_COLUMNS) {
    my ($name, $type) = @$column;
    next if $existing->{$name};
    eval { $dbh->do("ALTER TABLE usage_events ADD COLUMN $name $type") };
  }
  return 1;
}

=method dbh

The cached database handle, connecting on first use. Returns nothing when C<DBI> is not
installed or no DSN is configured.

=cut

sub dbh {
  my ($self) = @_;
  my $cached = $self->_dbh;
  return $cached if $cached;
  return unless length($self->backend) && length($self->dsn);

  eval { require DBI } or return;

  if ($self->backend eq 'sqlite' && length $self->path) {
    my $dir = dirname($self->path);
    if (defined $dir && length $dir && $dir ne '.' && !-d $dir) {
      make_path($dir);
    }
  }

  my %connect_attr = (
    RaiseError => 1,
    PrintError => 0,
    AutoCommit => 1,
  );
  $connect_attr{sqlite_unicode} = 1 if $self->backend eq 'sqlite';

  my $dbh = DBI->connect($self->dsn, $self->user, $self->password, \%connect_attr);
  $self->_dbh($dbh);
  return $dbh;
}

=method disconnect

Drops the cached handle. Called when the store is replaced and from Skeid's C<DEMOLISH>.

=cut

sub disconnect {
  my ($self) = @_;
  my $dbh = $self->_dbh or return;
  eval { $dbh->disconnect };
  $self->_dbh(undef);
  return;
}

=method shipped_schema_file

The schema file this backend would apply when C<schema_file> is not set. Looks in the installed
sharedir first, then walks up from this file for the repository's F<share/sql/> — the dev and
C<dzil test> case, where nothing is installed yet. Returns the first candidate that exists, or
the first candidate at all, so the caller can report a useful path when none does.

=cut

sub shipped_schema_file {
  my ($self) = @_;
  my $name = ($self->backend eq 'postgresql') ? 'usage_events.postgresql.sql' : 'usage_events.sqlite.sql';
  my @candidates;

  # Installed/runtime lookup via dist sharedir.
  my $share_dir = eval { dist_dir('Langertha-Skeid') };
  if (!$@ && defined($share_dir) && length($share_dir)) {
    push @candidates, File::Spec->catfile($share_dir, 'sql', $name);
  }

  # Dev + dzil test fallback: walk up from this file looking for the repo's share/.
  my $dir = dirname(dirname(dirname(dirname(__FILE__))));
  for (1 .. 6) {
    push @candidates, File::Spec->catfile($dir, 'share', 'sql', $name);
    push @candidates, File::Spec->catfile($dir, 'sql', $name);
    my $parent = dirname($dir);
    last if !defined($parent) || $parent eq $dir;
    $dir = $parent;
  }

  for my $path (@candidates) {
    return $path if -f $path;
  }

  return $candidates[0];
}

=method store

  my $res = $store->store($event);

Inserts one event. Returns C<< { ok => 1 } >> (plus C<id> on SQLite) or
C<< { ok => 0, error => … } >> — a failing usage write is reported, not thrown, because the
request it describes has already been served.

=cut

sub store {
  my ($self, $event) = @_;

  my $dbh = eval { $self->dbh };
  if (!$dbh || $@) {
    my $err = $@ || 'failed to connect usage database';
    $err =~ s/\s+$//;
    return { ok => 0, error => $err };
  }

  my $sth = $dbh->prepare_cached(q{
    INSERT INTO usage_events (
      created_at, request_id, api_format, endpoint, api_key_id, provider, engine, model, node_id, route_url,
      status_code, ok, duration_ms, input_tokens, output_tokens, total_tokens, tool_calls,
      cost_input_usd, cost_output_usd, cost_total_usd, error_type, error_message, requested_model
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  });
  $sth->execute(
    $event->{created_at},
    $event->{request_id},
    $event->{api_format},
    $event->{endpoint},
    $event->{api_key_id},
    $event->{provider},
    $event->{engine},
    $event->{model},
    $event->{node_id},
    $event->{route_url},
    $event->{status_code},
    $event->{ok},
    $event->{duration_ms},
    $event->{input_tokens},
    $event->{output_tokens},
    $event->{total_tokens},
    $event->{tool_calls},
    $event->{cost_input_usd},
    $event->{cost_output_usd},
    $event->{cost_total_usd},
    $event->{error_type},
    $event->{error_message},
    ($event->{requested_model} // $event->{model} // ''),
  );

  my %out = (ok => 1);
  if ($self->backend eq 'sqlite' && $dbh->can('sqlite_last_insert_rowid')) {
    $out{id} = Langertha::Skeid::UsageStore::num($dbh->sqlite_last_insert_rowid);
  }
  return \%out;
}

=method report

  my $report = $store->report(\%filters);

Aggregates in SQL: totals, per-key and per-model breakdowns, and the newest C<limit> events.
The same C<since> / C<api_key_id> / C<model> filter set applies to every part of the report, so
the breakdowns always add up to the totals shown next to them.

=cut

sub report {
  my ($self, $filters) = @_;
  $filters ||= {};
  my $num = \&Langertha::Skeid::UsageStore::num;

  my $dbh = eval { $self->dbh };
  if (!$dbh || $@) {
    my $err = $@ || 'failed to connect usage database';
    $err =~ s/\s+$//;
    return { ok => 0, enabled => 0, error => $err };
  }

  my $limit = $filters->{limit} // 20;

  my @where;
  my @bind;
  if (defined $filters->{since} && length $filters->{since}) {
    push @where, 'created_at >= ?';
    push @bind, $filters->{since};
  }
  if (defined $filters->{api_key_id} && length $filters->{api_key_id}) {
    push @where, 'api_key_id = ?';
    push @bind, $filters->{api_key_id};
  }
  if (defined $filters->{model} && length $filters->{model}) {
    push @where, 'model = ?';
    push @bind, $filters->{model};
  }

  my $where_sql = @where ? ('WHERE ' . join(' AND ', @where)) : '';

  my $totals = $dbh->selectrow_hashref(
    "SELECT
       COUNT(*) AS requests,
       COALESCE(SUM(input_tokens), 0) AS input_tokens,
       COALESCE(SUM(output_tokens), 0) AS output_tokens,
       COALESCE(SUM(total_tokens), 0) AS total_tokens,
       COALESCE(SUM(tool_calls), 0) AS tool_calls,
       COALESCE(SUM(cost_total_usd), 0) AS total_cost_usd
     FROM usage_events $where_sql",
    undef,
    @bind,
  ) || {};

  my $by_key = $dbh->selectall_arrayref(
    "SELECT
       COALESCE(api_key_id, '') AS api_key_id,
       COUNT(*) AS requests,
       COALESCE(SUM(total_tokens), 0) AS total_tokens,
       COALESCE(SUM(cost_total_usd), 0) AS total_cost_usd
     FROM usage_events
     $where_sql
     GROUP BY api_key_id
     ORDER BY total_cost_usd DESC, requests DESC",
    { Slice => {} },
    @bind,
  ) || [];

  my $by_model = $dbh->selectall_arrayref(
    "SELECT
       COALESCE(model, '') AS model,
       COUNT(*) AS requests,
       COALESCE(SUM(total_tokens), 0) AS total_tokens,
       COALESCE(SUM(cost_total_usd), 0) AS total_cost_usd
     FROM usage_events
     $where_sql
     GROUP BY model
     ORDER BY total_cost_usd DESC, requests DESC",
    { Slice => {} },
    @bind,
  ) || [];

  my $recent = $dbh->selectall_arrayref(
    "SELECT
       id, created_at, api_format, endpoint, api_key_id, model, requested_model, node_id, status_code, ok,
       input_tokens, output_tokens, total_tokens, tool_calls, cost_total_usd
     FROM usage_events
     $where_sql
     ORDER BY id DESC
     LIMIT ?",
    { Slice => {} },
    @bind,
    $limit,
  ) || [];

  return {
    ok        => 1,
    enabled   => 1,
    backend   => $self->backend,
    db_path   => ($self->backend eq 'sqlite' ? ($self->path // '') : ''),
    since     => ($filters->{since} // ''),
    totals    => {
      requests       => $num->($totals->{requests}),
      input_tokens   => $num->($totals->{input_tokens}),
      output_tokens  => $num->($totals->{output_tokens}),
      total_tokens   => $num->($totals->{total_tokens}),
      tool_calls     => $num->($totals->{tool_calls}),
      total_cost_usd => $num->($totals->{total_cost_usd}),
    },
    by_key   => [ map {
      +{
        api_key_id     => ($_->{api_key_id} // ''),
        requests       => $num->($_->{requests}),
        total_tokens   => $num->($_->{total_tokens}),
        total_cost_usd => $num->($_->{total_cost_usd}),
      }
    } @$by_key ],
    by_model => [ map {
      +{
        model          => ($_->{model} // ''),
        requests       => $num->($_->{requests}),
        total_tokens   => $num->($_->{total_tokens}),
        total_cost_usd => $num->($_->{total_cost_usd}),
      }
    } @$by_model ],
    recent   => [ map {
      +{
        id            => $num->($_->{id}),
        created_at    => ($_->{created_at} // ''),
        api_format    => ($_->{api_format} // ''),
        endpoint      => ($_->{endpoint} // ''),
        api_key_id    => ($_->{api_key_id} // ''),
        model           => ($_->{model} // ''),
        requested_model => ($_->{requested_model} // $_->{model} // ''),
        node_id         => ($_->{node_id} // ''),
        status_code   => $num->($_->{status_code}),
        ok            => ($_->{ok} ? 1 : 0),
        input_tokens  => $num->($_->{input_tokens}),
        output_tokens => $num->($_->{output_tokens}),
        total_tokens  => $num->($_->{total_tokens}),
        tool_calls    => $num->($_->{tool_calls}),
        cost_total_usd => $num->($_->{cost_total_usd}),
      }
    } @$recent ],
  };
}

1;
