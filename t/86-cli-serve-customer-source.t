#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Config;
use File::Temp qw(tempdir);
use Path::Tiny qw(path);
use POSIX qw(WNOHANG);
use FindBin;

# `skeid serve` with a customer_source (ADR 0026). Without DBD::Pg the config does not load,
# and the message names the module. With it, a database that refuses the connection does not
# stop the start: Skeid starts degraded and fail-closed and says so. Both offline -- the refused
# connection is to a closed port on 127.0.0.1.

my $bin = path($FindBin::Bin)->parent->child('bin', 'skeid')->stringify;
my $tmp = tempdir(CLEANUP => 1);

# Runs bin/skeid with the test's @INC and returns (exit code, output). A serve whose output
# matches $up has started: it is stopped and reported as exit code -1. Without $up the run ends
# by itself. The deadline is generous: loading Skeid alone takes over 20 seconds on a slow ARM
# board.
sub run_skeid {
  my ($up, @args) = @_;
  my $out = path($tmp)->child('out-' . $$ . '-' . int(rand(1e9)));
  # Joined by the platform's separator: on Windows it is ";", and ":" is part of "C:\".
  local $ENV{PERL5LIB} = join($Config{path_sep}, grep { !ref } @INC);
  my $pid = fork;
  die "fork: $!" unless defined $pid;
  if (!$pid) {
    open STDOUT, '>', "$out" or die $!;
    open STDERR, '>&', \*STDOUT or die $!;
    chdir $tmp or die $!;
    exec $^X, $bin, @args;
    die "exec: $!";
  }
  my $deadline = time + 300;
  my $code;
  while (time < $deadline) {
    if (waitpid($pid, WNOHANG) == $pid) { $code = $? >> 8; last }
    last if $up && -f "$out" && $out->slurp_utf8 =~ $up;
    select(undef, undef, undef, 0.1);
  }
  unless (defined $code) {
    kill 'TERM', $pid;
    waitpid($pid, 0);
    $code = -1;
  }
  return ($code, (-f "$out" ? $out->slurp_utf8 : ''));
}

my $config = path($tmp)->child('skeid.yaml');
$config->spew_utf8(<<'YAML');
client_auth:
  keys: []
customer_source:
  host: 127.0.0.1
  port: 1
  dbname: console
  user: skeid_reader
  relation: skeid.customer_keys
  connect_timeout_s: 2
YAML

my $have_pg = eval { require DBD::Pg; 1 };

SKIP: {
  skip 'DBD::Pg is installed here', 3 if $have_pg;
  my ($code, $output) = run_skeid(undef, 'serve', '--listen', '127.0.0.1:0', '--config', "$config");
  ok $code > 0, 'serve with a customer_source and no DBD::Pg exits non-zero';
  like $output, qr/DBD::Pg/, 'naming the module';
  unlike $output, qr/Starting Skeid proxy/, 'nothing claims the proxy started';
}

SKIP: {
  skip 'needs DBD::Pg', 3 unless $have_pg;
  # The daemon logs this once it listens, its stop signals in place: stopped then, the process
  # ends cleanly and what it printed reaches the output.
  my ($code, $output) = run_skeid(qr/Listening at/, 'serve', '--listen', '127.0.0.1:0', '--config', "$config");
  is $code, -1, 'a refused database connection does not stop the start';
  like $output, qr/starting degraded and fail-closed/, 'it says it starts degraded';
  like $output, qr/Starting Skeid proxy/, 'and starts';
}

done_testing;
