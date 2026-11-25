#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Errno qw( ENOTEMPTY EACCES );
use File::Temp qw( tempdir );
use JSON::MaybeXS qw( encode_json decode_json );
use POSIX qw( strftime );

# A jsonlog store in dir mode keeps one file per event (skeid k131). One flat directory grew to
# tens of thousands of files in days, so events go to a directory per UTC day,
# <path>/YYYY-MM-DD/<id>.json, the day of the id's time. Report and purge read the day
# directories and the flat <path>/*.json files an older store wrote, so nothing needs migrating.

# The store's clock and its mkdir/rmdir come through here, installed before it is compiled.
our ( $NOW, @MKDIR, $RMDIR_FAILS );
BEGIN {
  *CORE::GLOBAL::time = sub () { defined $NOW ? $NOW : CORE::time() };
  *CORE::GLOBAL::mkdir = sub (_;$) {
    my ( $dir, @mode ) = @_;
    push @MKDIR, $dir;
    return CORE::mkdir($dir, @mode ? @mode : 0777);
  };
  *CORE::GLOBAL::rmdir = sub (_) {
    my ( $dir ) = @_;
    if ( defined $RMDIR_FAILS ) { $! = $RMDIR_FAILS; return 0 }
    return CORE::rmdir($dir);
  };
}
use Langertha::Skeid::UsageStore::JsonLog;

my $DAY1 = 1764028800;    # 2025-11-25T00:00:00Z
my $DAY  = 86400;
my ( $A, $B ) = ( 'k_' . ( 'a' x 40 ), 'k_' . ( 'b' x 40 ) );

sub day_of { strftime('%Y-%m-%d', gmtime $_[0]) }

sub json_files {
  my ( $dir ) = @_;
  opendir my $dh, $dir or return;
  return sort grep { /\.json\z/ } readdir $dh;
}

sub day_dirs {
  my ( $dir ) = @_;
  opendir my $dh, $dir or return;
  return sort grep { /\A\d{4}-\d\d-\d\d\z/ && -d "$dir/$_" } readdir $dh;
}

# An event file as a store before the day directories wrote it, straight into <path>.
sub seed_flat {
  my ( $dir, $id, %ev ) = @_;
  open my $fh, '>', "$dir/$id.json" or die "Cannot seed $dir/$id.json: $!";
  print {$fh} encode_json({ %ev, id => $id }), "\n";
  close $fh or die $!;
}

sub store_at {
  my ( $store, $at, %ev ) = @_;
  local $NOW = $at;
  my $res = $store->store({ created_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime $at), model => 'm', %ev });
  die 'store failed: ' . ( $res->{error} // '' ) unless $res->{ok};
  return $res;
}

# --- layout on disk ---
{
  my $dir   = tempdir(CLEANUP => 1);
  my $store = Langertha::Skeid::UsageStore::JsonLog->new(path => $dir);
  $store->prepare;

  my $r1 = store_at($store, $DAY1 + 10, api_key_id => $A);
  my $r2 = store_at($store, $DAY1 + $DAY - 1, api_key_id => $A);
  my $r3 = store_at($store, $DAY1 + $DAY, api_key_id => $B);

  is_deeply [ json_files($dir) ], [], 'no event file lands in the top directory';
  is_deeply [ day_dirs($dir) ], [ day_of($DAY1), day_of($DAY1 + $DAY) ], 'one directory per UTC day';
  is_deeply [ json_files("$dir/" . day_of($DAY1)) ], [ sort map { "$_->{id}.json" } $r1, $r2 ],
    'the first day holds its two events, named by id';
  is_deeply [ json_files("$dir/" . day_of($DAY1 + $DAY)) ], [ "$r3->{id}.json" ],
    'the event a second past midnight is in the next day';
  for my $r ( $r1, $r2, $r3 ) {
    ( my $ymd = substr($r->{id}, 0, 8) ) =~ s/\A(\d{4})(\d\d)(\d\d)\z/$1-$2-$3/;
    ok -f "$dir/$ymd/$r->{id}.json", "the day directory is the day of the id's time ($r->{id})";
  }
  my $ev = decode_json(do { local ( @ARGV, $/ ) = "$dir/" . day_of($DAY1 + $DAY) . "/$r3->{id}.json"; <> });
  is $ev->{id}, $r3->{id}, 'the event carries its id';
}

# --- the write path makes a day directory once, not per event ---
{
  my $dir   = tempdir(CLEANUP => 1);
  my $store = Langertha::Skeid::UsageStore::JsonLog->new(path => $dir);
  $store->prepare;
  local @MKDIR;
  store_at($store, $DAY1 + $_) for 1 .. 50;
  store_at($store, $DAY1 + $DAY + $_) for 1 .. 50;
  is scalar(@MKDIR), 2, 'a hundred events over two days: two mkdir calls';
}

# --- a day directory another writer made first is fine (EEXIST) ---
{
  my $dir = tempdir(CLEANUP => 1);
  CORE::mkdir("$dir/" . day_of($DAY1)) or die $!;
  my $store = Langertha::Skeid::UsageStore::JsonLog->new(path => $dir);
  my $r = store_at($store, $DAY1 + 5);
  ok -f "$dir/" . day_of($DAY1) . "/$r->{id}.json", 'an existing day directory takes the event';
}

# --- a writer whose day directory a purge removed makes it again ---
{
  my $dir   = tempdir(CLEANUP => 1);
  my $store = Langertha::Skeid::UsageStore::JsonLog->new(path => $dir);
  $store->prepare;
  store_at($store, $DAY1 + 1, api_key_id => $A);
  my $purger = Langertha::Skeid::UsageStore::JsonLog->new(path => $dir);
  is $purger->purge({ api_key_ids => [ $A ] })->{deleted}, 1, 'another store purges the only event';
  ok !-d "$dir/" . day_of($DAY1), 'and the emptied day directory is gone';
  my $res = do { local $NOW = $DAY1 + 2; $store->store({ model => 'm', api_key_id => $B }) };
  ok $res->{ok}, 'the writer still stores into that day'
    or diag $res->{error};
  ok -f "$dir/" . day_of($DAY1) . "/$res->{id}.json", 'in a day directory made again';
}

# --- a base directory that is gone is reported, not retried forever ---
{
  my $dir   = tempdir(CLEANUP => 1);
  my $store = Langertha::Skeid::UsageStore::JsonLog->new(path => "$dir/missing");
  my $res   = store_at_maybe($store);
  ok !$res->{ok}, 'no base directory: the event is reported lost';
  like $res->{error}, qr/\QCannot create $dir\/missing\E/, 'naming the day directory it could not make';
}
sub store_at_maybe { local $NOW = $DAY1; $_[0]->store({ model => 'm' }) }

# --- report and purge across the flat files and the day directories ---
{
  my $dir   = tempdir(CLEANUP => 1);
  my $store = Langertha::Skeid::UsageStore::JsonLog->new(path => $dir);
  $store->prepare;
  seed_flat($dir, '20201231-235959-1-' . ( 'f' x 32 ) . '-0000000001', api_key_id => $A,
    created_at => '2020-12-31T23:59:59Z', model => 'old', total_tokens => 3);
  seed_flat($dir, '20210101-000000-1-' . ( 'f' x 32 ) . '-0000000002', api_key_id => $B,
    created_at => '2021-01-01T00:00:00Z', model => 'old', total_tokens => 5);
  my $n1 = store_at($store, $DAY1 + 1, api_key_id => $A, total_tokens => 7);
  my $n2 = store_at($store, $DAY1 + $DAY + 1, api_key_id => $B, total_tokens => 11);

  my $report = $store->report({});
  is $report->{totals}{requests}, 4, 'report counts the flat files and the day directories';
  is $report->{totals}{total_tokens}, 26, 'and sums them all';
  is_deeply [ map { $_->{id} } @{ $report->{recent} } ],
    [ $n2->{id}, $n1->{id}, '20210101-000000-1-' . ( 'f' x 32 ) . '-0000000002', '20201231-235959-1-' . ( 'f' x 32 ) . '-0000000001' ],
    'recent is newest first across both layouts';
  is $store->report({ since => '2021-01-01T00:00:00Z' })->{totals}{requests}, 3, 'since filters across both';
  is $store->report({ api_key_id => $A })->{totals}{requests}, 2, 'api_key_id filters across both';

  my $dry = $store->purge({ before => '2025-11-26T00:00:00Z', dry_run => 1 });
  is_deeply [ @{$dry}{qw( ok matched deleted )} ], [ 1, 3, 0 ], 'a dry run counts in both layouts';
  ok -d "$dir/" . day_of($DAY1), 'and removes no directory';

  my $old = $store->purge({ before => '2021-06-01T00:00:00Z' });
  is_deeply [ @{$old}{qw( ok matched deleted )} ], [ 1, 2, 2 ], 'purge by time deletes the old flat files';
  is_deeply [ json_files($dir) ], [], 'none of them is left';
  is $store->report({})->{totals}{requests}, 2, 'the day directories keep theirs';

  my $byk = $store->purge({ api_key_ids => [ $A ] });
  is_deeply [ @{$byk}{qw( ok matched deleted )} ], [ 1, 1, 1 ], 'purge by key id reaches into a day directory';
  ok !-d "$dir/" . day_of($DAY1), 'the day directory it emptied is removed';
  ok -d "$dir/" . day_of($DAY1 + $DAY), 'a day directory still holding events stays';
  is_deeply [ map { $_->{id} } @{ $store->report({})->{recent} } ], [ $n2->{id} ], 'only the other key\'s event is left';

  is_deeply [ @{ $store->purge({ api_key_ids => [ $A ] }) }{qw( ok matched deleted )} ], [ 1, 0, 0 ],
    'a repeated purge matches nothing';
}

# --- an empty day directory a crash left behind goes with the next purge ---
{
  my $dir = tempdir(CLEANUP => 1);
  CORE::mkdir("$dir/2024-01-01") or die $!;
  my $store = Langertha::Skeid::UsageStore::JsonLog->new(path => $dir);
  ok $store->purge({ before => '2025-01-01T00:00:00Z' })->{ok}, 'the purge succeeds';
  ok !-d "$dir/2024-01-01", 'and removes the empty day directory';
  CORE::mkdir("$dir/2024-01-02") or die $!;
  $store->purge({ before => '2025-01-01T00:00:00Z', dry_run => 1 });
  ok -d "$dir/2024-01-02", 'a dry run leaves it';
}

# --- a day directory a writer refilled meanwhile is not an error ---
{
  my $dir   = tempdir(CLEANUP => 1);
  my $store = Langertha::Skeid::UsageStore::JsonLog->new(path => $dir);
  store_at($store, $DAY1 + 1, api_key_id => $A);
  my $res = do { local $RMDIR_FAILS = ENOTEMPTY; $store->purge({ api_key_ids => [ $A ] }) };
  is_deeply [ @{$res}{qw( ok deleted )} ], [ 1, 1 ], 'rmdir answering ENOTEMPTY leaves the purge ok';
  ok -d "$dir/" . day_of($DAY1), 'and the directory in place';

  store_at($store, $DAY1 + 2, api_key_id => $A);
  my $bad = do { local $RMDIR_FAILS = EACCES; $store->purge({ api_key_ids => [ $A ] }) };
  is $bad->{ok}, 0, 'any other rmdir failure fails the purge';
  like $bad->{error}, qr/Cannot remove .*\Q@{[ day_of($DAY1) ]}\E/, 'naming the directory';
  is_deeply [ json_files("$dir/" . day_of($DAY1)) ], [], 'the matching event is deleted all the same';
  is $store->purge({ api_key_ids => [ $A ] })->{ok}, 1, 'and the purge repeated goes through';
}

# --- a directory of many files: a few thousand flat ones beside a few thousand in day dirs ---
{
  my $dir   = tempdir(CLEANUP => 1);
  my $store = Langertha::Skeid::UsageStore::JsonLog->new(path => $dir);
  $store->prepare;
  my $nonce = 'e' x 32;
  for my $i ( 1 .. 2500 ) {
    seed_flat($dir, sprintf('20200101-000000-1-%s-%010d', $nonce, $i), api_key_id => ( $i % 2 ? $A : $B ),
      created_at => '2020-01-01T00:00:00Z', total_tokens => 1);
  }
  for my $i ( 1 .. 2500 ) {
    store_at($store, $DAY1 + ( $i % 5 ) * $DAY + $i, api_key_id => ( $i % 2 ? $A : $B ), total_tokens => 1);
  }
  is scalar(my @days = day_dirs($dir)), 5, 'the stored events spread over five days';
  my $report = $store->report({ limit => 3 });
  is $report->{totals}{requests}, 5000, 'report reads all five thousand events';
  is scalar(@{ $report->{recent} }), 3, 'and honours limit';

  my $old = $store->purge({ before => '2021-01-01T00:00:00Z' });
  is_deeply [ @{$old}{qw( ok deleted )} ], [ 1, 2500 ], 'purge by time deletes every flat file';
  my $gone = $store->purge({ api_key_ids => [ $A, $B ] });
  is_deeply [ @{$gone}{qw( ok deleted )} ], [ 1, 2500 ], 'purge by key ids empties the day directories';
  is_deeply [ day_dirs($dir) ], [], 'and removes all five';
  is $store->report({})->{totals}{requests}, 0, 'nothing is left';
}

# --- file mode is unchanged: one file, no day directories ---
{
  my $dir   = tempdir(CLEANUP => 1);
  my $store = Langertha::Skeid::UsageStore::JsonLog->new(path => "$dir/usage.jsonl", mode => 'file');
  $store->prepare;
  store_at($store, $DAY1 + 1);
  ok -s "$dir/usage.jsonl", 'file mode appends to its file';
  is_deeply [ day_dirs($dir) ], [], 'and makes no day directory';
}

done_testing;
