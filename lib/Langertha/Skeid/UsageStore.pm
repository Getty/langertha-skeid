package Langertha::Skeid::UsageStore;
our $VERSION = '0.003';
# ABSTRACT: Usage event sink — config normalization and backend factory
use strict;
use warnings;
use Carp qw(croak);

=head1 DESCRIPTION

A usage store is where a L<Langertha::Skeid> usage event goes to become durable. One event is
written per forwarded request, including failures, and it is the billing unit — which is why
swapping the backend must never change what an event I<means>. See
F<docs/adr/0004-usage-events-are-the-billing-unit.md>.

This module owns the config shape and hands back the object that implements it:
L<Langertha::Skeid::UsageStore::JsonLog> or L<Langertha::Skeid::UsageStore::DBI>.

=method normalize_config

  my $normalized = Langertha::Skeid::UsageStore->normalize_config($cfg, %opts);

Turns a user-supplied C<usage_store> config into the canonical hashref Skeid keeps on its
C<usage_store> attribute. Backend selection is inference-first, because most configs name only
one thing: an explicit C<backend> wins, otherwise a sqlite path key, a C<dbi:Pg:> DSN or a
C<log_path> decides. C<password_env> reads the password from the environment so it never has
to sit in the file.

C<default_sqlite_path> supplies the path for a sqlite config that names none.

=cut

sub normalize_config {
  my ($class, $cfg, %opts) = @_;
  $cfg ||= {};
  croak 'usage_store must be a hashref' unless ref($cfg) eq 'HASH';

  my $backend = lc($cfg->{backend} // '');
  $backend = 'sqlite' if !$backend && (defined($cfg->{sqlite_path}) || defined($cfg->{path}) || defined($cfg->{db_path}));
  $backend = 'postgresql' if !$backend && defined($cfg->{dsn}) && $cfg->{dsn} =~ /^dbi:Pg:/i;
  $backend = 'jsonlog' if !$backend && defined($cfg->{log_path});
  $backend = 'sqlite' unless length $backend;
  $backend = 'postgresql' if $backend =~ /^postgres/;
  $backend = 'jsonlog' if $backend =~ /^json/;

  if ($backend eq 'sqlite') {
    my $path = $cfg->{sqlite_path} // $cfg->{path} // $cfg->{db_path} // $opts{default_sqlite_path};
    if (!defined($path) || !length($path)) {
      croak 'usage_store.sqlite_path (or path/db_path) is required for sqlite backend';
    }
    return {
      backend      => 'sqlite',
      path         => $path,
      dsn          => "dbi:SQLite:dbname=$path",
      user         => '',
      password     => '',
      schema_file  => ($cfg->{schema_file} // ''),
      auto_migrate => exists($cfg->{auto_migrate}) ? ($cfg->{auto_migrate} ? 1 : 0) : 1,
    };
  }

  if ($backend eq 'postgresql') {
    my $dsn = $cfg->{dsn};
    if (!defined($dsn) || !length($dsn)) {
      my $host = $cfg->{host} // '127.0.0.1';
      my $port = $cfg->{port} // 5432;
      my $name = $cfg->{dbname} // $cfg->{database} // 'skeid';
      $dsn = "dbi:Pg:dbname=$name;host=$host;port=$port";
    }
    my $password = defined($cfg->{password}) ? $cfg->{password} : '';
    if (!length($password) && defined($cfg->{password_env}) && length($cfg->{password_env})) {
      $password = $ENV{$cfg->{password_env}} // '';
    }
    return {
      backend      => 'postgresql',
      path         => '',
      dsn          => $dsn,
      user         => ($cfg->{user} // ''),
      password     => $password,
      schema_file  => ($cfg->{schema_file} // ''),
      auto_migrate => exists($cfg->{auto_migrate}) ? ($cfg->{auto_migrate} ? 1 : 0) : 1,
    };
  }

  if ($backend eq 'jsonlog') {
    my $path = $cfg->{log_path} // $cfg->{path} // '';
    croak 'usage_store.log_path (or path) is required for jsonlog backend' unless length $path;
    my $mode = $cfg->{mode} // '';
    if (!length($mode)) {
      $mode = (-d $path || $path =~ m{/$}) ? 'dir' : 'file';
    }
    return {
      backend => 'jsonlog',
      path    => $path,
      mode    => $mode,
    };
  }

  croak "unsupported usage_store backend '$backend'";
}

=method for_config

  my $store = Langertha::Skeid::UsageStore->for_config($normalized);

Builds the store object for a normalized config, or returns nothing when no backend is
configured. Does not touch the filesystem or connect — call C<prepare> for that, so that
constructing a Skeid object never has a side effect on disk.

=cut

sub for_config {
  my ($class, $cfg) = @_;
  return unless ref($cfg) eq 'HASH';
  my $backend = $cfg->{backend} // '';
  return unless length $backend;

  if ($backend eq 'jsonlog') {
    require Langertha::Skeid::UsageStore::JsonLog;
    return Langertha::Skeid::UsageStore::JsonLog->new(
      path => ($cfg->{path} // ''),
      mode => ($cfg->{mode} // 'dir'),
    );
  }

  require Langertha::Skeid::UsageStore::DBI;
  return Langertha::Skeid::UsageStore::DBI->new(
    backend      => $backend,
    dsn          => ($cfg->{dsn} // ''),
    user         => ($cfg->{user} // ''),
    password     => ($cfg->{password} // ''),
    path         => ($cfg->{path} // ''),
    schema_file  => ($cfg->{schema_file} // ''),
    auto_migrate => (exists($cfg->{auto_migrate}) ? ($cfg->{auto_migrate} ? 1 : 0) : 1),
  );
}

=method num

Numeric coercion that treats undef as zero. Reports sum columns that may be C<NULL> on an empty
table, so this is the one place that is allowed to be lax about it.

=cut

sub num {
  my ($v) = @_;
  return 0 unless defined $v;
  return 0 + $v;
}

=method read_text_file

Slurps a file, dying with the path on failure.

=cut

sub read_text_file {
  my ($path) = @_;
  open my $fh, '<', $path or die "Cannot open $path: $!";
  local $/;
  my $text = <$fh>;
  close $fh;
  return $text;
}

1;
