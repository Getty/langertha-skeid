#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw( tempdir );
use JSON::MaybeXS qw( decode_json );

# A file-mode append locks the usage log, then checks that the handle it locked is still the file
# at the path: a purge may have renamed a rewritten copy over it while the append waited, and an
# event written into the replaced file is lost. stat answers that by device and inode. These
# tests give the store the values a platform's stat returns, and a purge that lands in the gap.

our ( $STAT, $ON_LOCK );
BEGIN {
  # Installed before the store is compiled, so its stat and flock come through here.
  *CORE::GLOBAL::stat = sub (;*) {
    my ( $what ) = @_;
    my @st = CORE::stat($what);
    return $STAT && @st ? $STAT->($what, @st) : @st;
  };
  *CORE::GLOBAL::flock = sub (*$) {
    my ( $fh, $operation ) = @_;
    my $ok = CORE::flock($fh, $operation);
    $ON_LOCK->() if $ok && $ON_LOCK;
    return $ok;
  };
}

use Langertha::Skeid::UsageStore::JsonLog;

sub lines {
  my ( $file ) = @_;
  open my $fh, '<', $file or die "Cannot read $file: $!";
  return map { decode_json($_) } <$fh>;
}

# perl before 5.34 on Windows: the C runtime's stat reports no inode, and a device of 0 for a
# handle but the drive number (2 for C:) for a path -- so a handle never matches its own path.
my $windows_stat = sub {
  my ( $what, @st ) = @_;
  @st[0, 1] = ( ref $what ? 0 : 2, 0 );
  return @st;
};

{
  my $dir   = tempdir(CLEANUP => 1);
  my $store = Langertha::Skeid::UsageStore::JsonLog->new(path => "$dir/usage.jsonl", mode => 'file');
  my $res = do {
    local $^O   = 'MSWin32';
    local $STAT = $windows_stat;
    $store->store({ marker => 'windows' });
  };
  ok $res->{ok}, 'on Windows, where stat reports no inode, an append is stored'
    or diag $res->{error};
  is_deeply [ map { $_->{marker} } lines("$dir/usage.jsonl") ], [ 'windows' ],
    'as a line of the usage log';
}

{
  my $dir   = tempdir(CLEANUP => 1);
  my $store = Langertha::Skeid::UsageStore::JsonLog->new(path => "$dir/usage.jsonl", mode => 'file');
  my $res = do {
    local $STAT = $windows_stat;
    $store->store({ marker => 'unconfirmed' });
  };
  ok !$res->{ok}, 'elsewhere a file can be replaced while held: an append that cannot confirm the file is refused';
  like $res->{error}, qr/replaced while waiting for the lock/, 'and says why';
}

{
  my $dir   = tempdir(CLEANUP => 1);
  my $path  = "$dir/usage.jsonl";
  my $store = Langertha::Skeid::UsageStore::JsonLog->new(path => $path, mode => 'file');
  ok $store->store({ marker => 'before' })->{ok}, 'a first event is appended';

  open my $fresh, '>', "$dir/rewritten" or die "Cannot write $dir/rewritten: $!";
  print {$fresh} qq({"marker":"rewritten"}\n) or die "Cannot write $dir/rewritten: $!";
  close $fresh or die "Cannot close $dir/rewritten: $!";

  my $refused;
  my $res = do {
    my $purged;
    local $ON_LOCK = sub { $purged++ or rename("$dir/rewritten", $path) or $refused = "$!" };
    $store->store({ marker => 'after' });
  };
  SKIP: {
    skip "this platform does not rename over a file held open ($refused)", 2 if defined $refused;
    ok $res->{ok}, 'an append whose file was replaced while it waited for the lock is stored';
    is_deeply [ map { $_->{marker} } lines($path) ], [qw( rewritten after )],
      'in the file now at the path, not in the replaced one';
  }
}

done_testing;
