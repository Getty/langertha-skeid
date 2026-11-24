#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Cwd qw( abs_path );
use Errno qw( EACCES );
use Fcntl qw( :flock );
use File::Temp qw( tempdir );
use JSON::MaybeXS qw( encode_json );
use Scalar::Util qw( weaken );

# A jsonlog store in file mode purges by rewriting the file under the lock appends take
# (t/94-usage-purge.t). Windows locks are mandatory -- a file one handle holds locked cannot be
# read through another -- and Windows refuses to rename over a file held open. These tests give
# the store those rules: a readline fails on a file another handle holds LOCK_EX on, and rename
# fails on a file this process holds open (/proc/self/fd tells which).

our $WINDOWS;
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
  my %locked;    # "dev:ino" => the handle holding LOCK_EX on it, weak
  my $file_of = sub { my @st = CORE::stat($_[0]); @st ? "$st[0]:$st[1]" : undef };
  # Installed before the store is compiled, so its flock, readline and rename come through here.
  *CORE::GLOBAL::flock = sub (*$) {
    my ( $fh, $op ) = @_;
    my $ok = CORE::flock($fh, $op) or return 0;
    my $file = $file_of->($fh) // return $ok;
    if ( $op & LOCK_EX ) { $locked{$file} = $fh; weaken $locked{$file} }
    elsif ( $op & LOCK_UN ) { delete $locked{$file} }
    return $ok;
  };
  *CORE::GLOBAL::readline = sub (;*) {
    my $fh = @_ ? $_[0] : \*ARGV;
    if ( $WINDOWS && defined( my $file = $file_of->($fh) ) ) {
      my $holder = $locked{$file};
      if ( $holder && defined fileno($holder) && fileno($holder) != fileno($fh) ) {
        $! = EACCES;
        return;
      }
    }
    return CORE::readline($fh);
  };
  *CORE::GLOBAL::rename = sub ($$) {
    my ( $from, $to ) = @_;
    if ( $WINDOWS && ( $held->($from) || $held->($to) ) ) { $! = EACCES; return 0 }
    return CORE::rename($from, $to);
  };
}

plan skip_all => 'needs /proc/self/fd to tell which files this process holds open'
  unless -d '/proc/self/fd';

use Langertha::Skeid;

my $dir = tempdir(CLEANUP => 1);
my ($ORG_A, $ORG_B, $OTHER) = map { 'k_' . ($_ x 40) } qw( a b c );

sub seed {
  my ($skeid) = @_;
  my $n = 0;
  for my $row ([$ORG_A, '2020-01-01T00:00:00Z'], [$ORG_A, '2026-11-01T00:00:00Z'],
               [$ORG_B, '2026-11-01T00:00:00Z'], [$OTHER, '2020-01-01T00:00:00Z'],
               [$OTHER, '2026-11-01T00:00:00Z']) {
    my ($id, $at) = @$row;
    $skeid->call_function('usage.record', { created_at => $at, request_id => 'r' . $n++,
      api_key_id => $id, model => 'm', ok => 1, status_code => 200 })->{ok} or die 'seed failed';
  }
}
sub count_for { $_[0]->call_function('usage.report', { api_key_id => $_[1] })->{totals}{requests} }
sub total     { $_[0]->call_function('usage.report', {})->{totals}{requests} }

# --- the rules these tests give the store ---
{
  local $WINDOWS = 1;
  my $file = "$dir/probe.txt";
  open my $fh, '>', $file or die $!;
  print {$fh} "x\n";
  close $fh;
  open my $lock, '>>', $file or die $!;
  flock($lock, LOCK_EX) or die $!;
  open my $other, '<', $file or die $!;
  ok !defined(scalar <$other>), 'a file locked by one handle cannot be read through another';
  open my $new, '>', "$dir/probe.new" or die $!;
  close $new;
  ok !rename("$dir/probe.new", $file), 'nor replaced while it is held open';
  close $lock;
  is scalar(<$other>), "x\n", 'once the lock is let go it reads';
}

for my $fsync (0, 1) {
  subtest "jsonlog file, fsync $fsync" => sub {
    local $^O = 'MSWin32';
    local $WINDOWS = 1;
    my $log = "$dir/usage-$fsync.jsonl";
    my $skeid = Langertha::Skeid->new(usage_store => { backend => 'jsonlog', log_path => $log,
      mode => 'file', fsync => $fsync });
    seed($skeid);
    is total($skeid), 5, 'five events';
    my $ino = (stat $log)[1];

    my $dry = $skeid->purge_usage(api_key_ids => [ $ORG_A, $ORG_B ], dry_run => 1);
    is_deeply [ @{$dry}{qw( ok matched deleted )} ], [ 1, 3, 0 ],
      'a dry run counts the organisation\'s events through the lock it holds';

    # Another writer that opened the log before the purge and appends once the lock is free.
    open my $writer, '>>', $log or die $!;
    my $done = $skeid->purge_usage(api_key_ids => [ $ORG_A, $ORG_B ]);
    is_deeply [ @{$done}{qw( ok matched deleted )} ], [ 1, 3, 3 ], 'the purge deletes them'
      or diag $done->{error};
    is count_for($skeid, $ORG_A) + count_for($skeid, $ORG_B), 0, 'none of the organisation\'s events is left';
    is count_for($skeid, $OTHER), 2, 'other keys keep theirs';
    is((stat $log)[1], $ino, 'the log is rewritten in place, not replaced');
    is_deeply [ glob "$log.purge-*" ], [], 'and the copy written first is gone';
    flock($writer, LOCK_EX) or die $!;
    print {$writer} encode_json({ api_key_id => $OTHER, model => 'm', ok => 1, status_code => 200,
      created_at => '2026-11-02T00:00:00Z', request_id => 'late' }), "\n";
    close $writer;
    is count_for($skeid, $OTHER), 3, 'an append by a handle opened before the purge is kept';

    my $again = $skeid->purge_usage(api_key_ids => [ $ORG_A, $ORG_B ]);
    is_deeply [ @{$again}{qw( ok matched deleted )} ], [ 1, 0, 0 ], 'repeated, it is idempotent';

    my $old = $skeid->purge_usage(before => '2026-01-01T00:00:00Z');
    is_deeply [ @{$old}{qw( ok deleted )} ], [ 1, 1 ], 'before deletes what is older';
    is total($skeid), 2, 'the newer events stay';

    ok $skeid->call_function('usage.record', { api_key_id => $OTHER, model => 'm', ok => 1, status_code => 200 })->{ok},
      'the store still takes events after a purge';
    is total($skeid), 3, 'and reports them';
  };
}

done_testing;
