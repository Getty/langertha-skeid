#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Cwd qw( abs_path );
use Errno qw( EACCES );
use File::Spec;
use File::Temp qw( tempdir );
use JSON::MaybeXS qw( decode_json );

# A DBI store spools what the database cannot take and replays it once the database is back
# (t/82-usage-dbi-spool.t). The replay claims a spool file by renaming it, rewrites what is left
# of it and removes it once done. Windows refuses to rename, replace or remove a file held open,
# by any handle; and perl before 5.34 on Windows reports no inode, and a handle's device differs
# from its path's. These tests give the store those rules: rename and unlink fail on a file this
# process holds open (/proc/self/fd tells which), and stat returns what such a perl returns.

our ( $WINDOWS, $STAT );
BEGIN {
  my $held = sub {
    my ( $path ) = @_;
    my $want = abs_path($path) // return 0;
    opendir my $dh, '/proc/self/fd' or return 0;
    for my $fd ( grep { /\A\d+\z/ } readdir $dh ) {
      my $target = readlink "/proc/self/fd/$fd";
      return 1 if defined $target && $target eq $want;
    }
    return 0;
  };
  # Installed before the store is compiled, so its rename, unlink and stat come through here.
  *CORE::GLOBAL::rename = sub ($$) {
    my ( $from, $to ) = @_;
    if ( $WINDOWS && ( $held->($from) || $held->($to) ) ) { $! = EACCES; return 0 }
    return CORE::rename($from, $to);
  };
  *CORE::GLOBAL::unlink = sub (@) {
    my @paths = @_ ? @_ : ($_);
    my $n = 0;
    for my $path (@paths) {
      if ( $WINDOWS && $held->($path) ) { $! = EACCES; next }
      $n += CORE::unlink($path);
    }
    return $n;
  };
  *CORE::GLOBAL::stat = sub (;*) {
    my ( $what ) = @_;
    my @st = CORE::stat($what);
    return $STAT && @st ? $STAT->($what, @st) : @st;
  };
}

plan skip_all => 'needs /proc/self/fd to tell which files this process holds open'
  unless -d '/proc/self/fd';
eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBI/DBD::SQLite not available';

use Test::File::ShareDir -share => {
  -dist => { 'Langertha-Skeid' => 'share' },
};
use Langertha::Skeid::UsageStore::DBI;

# --- A database that can be switched off ------------------------------------------------------
my $real_connect = \&DBI::connect;
my $down = 0;
{
  no warnings 'redefine';
  *DBI::connect = sub {
    die "DBI connect('dbname=usage','skeid',...) failed: Connection refused\n" if $down;
    goto &$real_connect;
  };
}
my $clock = 1000;
{
  no warnings 'redefine';
  *Langertha::Skeid::UsageStore::DBI::_now = sub { $clock };
}
$SIG{__WARN__} = sub { };

sub event {
  my ( $request_id ) = @_;
  return {
    created_at   => '2026-10-13T04:00:00Z',
    request_id   => $request_id,
    api_format   => 'openai',
    endpoint     => '/v1/chat/completions',
    api_key_id   => 'k_0123456789abcdef0123456789abcdef01234567',
    model        => 'm1',
    node_id      => 'n1',
    status_code  => 200,
    ok           => 1,
    input_tokens => 7, output_tokens => 3, total_tokens => 10, tool_calls => 0,
    cost_input_usd => 0, cost_output_usd => 0, cost_total_usd => 0.25,
  };
}

sub rows {
  my ( $path, $request_id ) = @_;
  my $dbh = $real_connect->('DBI', "dbi:SQLite:dbname=$path", '', '', { RaiseError => 1, PrintError => 0 });
  my ( $count ) = $dbh->selectrow_array('SELECT COUNT(*) FROM usage_events WHERE request_id = ?', undef, $request_id);
  $dbh->disconnect;
  return $count;
}

sub spool_files {
  my ( $dir ) = @_;
  opendir( my $dh, $dir ) or return ();
  my @files = sort grep { /\Ausage-spool-/ } readdir $dh;
  closedir $dh;
  return @files;
}

# Made, and its database file created, before a test switches to Windows: DBD::SQLite itself
# asks for Win32 to name a file that does not exist yet.
sub new_store {
  my $dir = tempdir(CLEANUP => 1);
  my $store = Langertha::Skeid::UsageStore::DBI->new(
    backend   => 'sqlite',
    dsn       => "dbi:SQLite:dbname=$dir/usage.sqlite",
    path      => "$dir/usage.sqlite",
    spool_dir => "$dir/spool",
  );
  $store->prepare;
  return ( $store, "$dir/usage.sqlite", "$dir/spool" );
}

sub take_down {
  my ( $store ) = @_;
  my $dbh = $store->_dbh;
  $dbh->disconnect if $dbh;
  $down = 1;
}

sub bring_back {
  $down = 0;
  $clock += 3600;   # well past any backoff deadline
}

# perl before 5.34 on Windows: no inode, and a device of 0 for a handle but the drive number
# (2 for C:) for a path.
my $old_windows_stat = sub {
  my ( $what, @st ) = @_;
  @st[0, 1] = ( ref $what ? 0 : 2, 0 );
  return @st;
};

{
  my ( $store, $db, $spool ) = new_store();
  local $^O      = 'MSWin32';
  local $WINDOWS = 1;
  take_down($store);
  is_deeply [ map { $store->store(event("req-win-$_")) } 1 .. 3 ], [ map { { ok => 1, spooled => 1 } } 1 .. 3 ],
    'on Windows, events the database cannot take are spooled';
  bring_back();
  ok $store->store(event('req-win-back'))->{ok}, 'the database is back';
  is rows($db, "req-win-$_"), 1, "req-win-$_ is replayed" for 1 .. 3;
  is_deeply [ spool_files($spool) ], [], 'and the spool is removed';
}

{
  local $Langertha::Skeid::UsageStore::DBI::REPLAY_BATCH = 2;
  my ( $store, $db, $spool ) = new_store();
  local $^O      = 'MSWin32';
  local $WINDOWS = 1;
  take_down($store);
  $store->store(event("req-batch-$_")) for 1 .. 3;
  bring_back();
  my $first = $store->replay_spool;
  is $first->{consumed}, 2, 'on Windows, one replay takes one batch';
  my @left = map {
    open my $fh, '<', File::Spec->catfile($spool, $_) or die $!;
    map { decode_json($_)->{request_id} } <$fh>;
  } spool_files($spool);
  is_deeply \@left, ['req-batch-3'], 'and the spool keeps only the line it did not take';
  $store->replay_spool;
  is rows($db, "req-batch-$_"), 1, "req-batch-$_ once" for 1 .. 3;
  is_deeply [ spool_files($spool) ], [], 'the second replay empties it';
}

{
  my ( $store, $db, $spool ) = new_store();
  local $^O      = 'MSWin32';
  local $WINDOWS = 1;
  take_down($store);
  $store->store(event('req-held'));
  my ( $name ) = spool_files($spool);
  open my $writer, '>>', File::Spec->catfile($spool, $name) or die $!;   # a writer holds it
  bring_back();
  ok $store->replay_spool->{ok}, 'a replay while a writer holds the spool file';
  is_deeply [ spool_files($spool) ], [$name], 'leaves the file to the writer, unclaimed';
  is rows($db, 'req-held'), 0, 'and replays nothing of it';
  close $writer;
  $store->replay_spool;
  is rows($db, 'req-held'), 1, 'once the writer let go, the next replay takes it';
  is_deeply [ spool_files($spool) ], [], 'and removes it';
}

{
  local $STAT    = $old_windows_stat;
  my ( $store, $db, $spool ) = new_store();
  local $^O      = 'MSWin32';
  local $WINDOWS = 1;
  take_down($store);
  is_deeply $store->store(event('req-old-perl')), { ok => 1, spooled => 1 },
    'on Windows before perl 5.34, where stat reports no inode, an event is spooled';
  bring_back();
  $store->store(event('req-old-perl-back'));
  is rows($db, 'req-old-perl'), 1, 'and replayed';
  is_deeply [ spool_files($spool) ], [], 'and the spool is removed';
}

{
  local $STAT = $old_windows_stat;
  my ( $store, $db, $spool ) = new_store();
  take_down($store);
  my $res = $store->store(event('req-unconfirmed'));
  ok !$res->{ok}, 'elsewhere a file can be renamed while held: a spool file that cannot be confirmed is not written to';
  like $res->{error} // '', qr/claimed by a replay/, 'and says why';
}

done_testing;
