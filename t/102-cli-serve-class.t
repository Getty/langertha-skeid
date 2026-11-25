#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Config;
use File::Temp qw(tempdir);
use Path::Tiny qw(path);
use POSIX qw(WNOHANG);
use FindBin;

# `skeid serve --class` and the config's skeid_class (ADR 0030): Skeid serves a deployment's own
# Langertha::Skeid subclass, found through -I. A class that cannot be used -- not a subclass,
# not found -- stops the start with an ERROR line and exit 2, like a missing config. `skeid pack`
# checks the class the same way before it packs anything; the pack itself is
# xt/author/pack.t's, since it needs PAR::Packer.

my $bin = path($FindBin::Bin)->parent->child('bin', 'skeid')->stringify;
my $lib = path($FindBin::Bin)->child('lib')->stringify;
my $tmp = tempdir(CLEANUP => 1);

# Runs bin/skeid with the test's @INC and returns (exit code, output). A serve whose output
# matches $up has started: it is stopped and reported as exit code -1. Without $up the run ends
# by itself. The deadline is generous: loading Skeid alone takes over 20 seconds on a slow ARM
# board.
sub run_skeid {
  my ($up, @args) = @_;
  my $out = path($tmp)->child('out-' . $$ . '-' . int(rand(1e9)));
  # Joined by the platform's separator: on Windows it is ";", and ":" is part of "C:\".
  # t/lib is left out on purpose: the class is found through -I or not at all.
  local $ENV{PERL5LIB} = join($Config{path_sep}, grep { !ref && $_ ne $lib && !/\bt\/lib\z/ } @INC);
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
$config->spew_utf8("skeid_class: Test::Skeid::Dispatch\n");
my $plain = path($tmp)->child('plain.yaml');
$plain->spew_utf8("nodes: []\n");
my $wrong = path($tmp)->child('wrong.yaml');
$wrong->spew_utf8("skeid_class: Mojo::File\n");

my @serve = ('serve', '--listen', '127.0.0.1:0');

{
  my ($code, $output) = run_skeid(qr/Listening at/, @serve, '--config', "$plain",
    '--class', 'Test::Skeid::Dispatch', '-I', $lib);
  is $code, -1, 'serve --class with -I starts';
  like $output, qr/^Class: Test::Skeid::Dispatch$/m, 'and names the class it serves';
}

{
  my ($code, $output) = run_skeid(qr/Listening at/, @serve, '--config', "$config", '-I', $lib);
  is $code, -1, 'serve with the config\'s skeid_class starts';
  like $output, qr/^Class: Test::Skeid::Dispatch$/m, 'serving the config\'s class';
}

{
  my ($code, $output) = run_skeid(qr/Listening at/, @serve, '--config', "$plain");
  is $code, -1, 'serve without a class starts';
  unlike $output, qr/^Class:/m, 'and prints no class line for Langertha::Skeid';
}

{
  my ($code, $output) = run_skeid(qr/Listening at/, @serve, '--config', "$wrong",
    '--class', 'Test::Skeid::Dispatch', '-I', $lib);
  is $code, -1, '--class wins over the config\'s skeid_class';
  like $output, qr/^Class: Test::Skeid::Dispatch$/m, 'the class of the command line is served';
}

for my $case (
  [ 'a class that is no Langertha::Skeid', [ '--config', "$plain", '--class', 'Mojo::File' ],
    qr/^ERROR: skeid_class 'Mojo::File' is not a Langertha::Skeid subclass$/m ],
  [ 'a config naming one',                 [ '--config', "$wrong" ],
    qr/^ERROR: skeid_class 'Mojo::File' is not a Langertha::Skeid subclass$/m ],
  [ 'a class not in @INC',                 [ '--config', "$plain", '--class', 'Test::Skeid::Dispatch' ],
    qr/^ERROR: skeid_class 'Test::Skeid::Dispatch' not found in \@INC$/m ],
) {
  my ($name, $args, $error) = @$case;
  my ($code, $output) = run_skeid(qr/Listening at/, @serve, @$args);
  is $code, 2, "serve with $name exits 2";
  like $output, $error, 'saying why';
  unlike $output, qr/Starting Skeid proxy/, 'nothing claims the proxy started';
}

{
  my ($code, $output) = run_skeid(undef, 'pack', '--class', 'Test::Skeid::Dispatch');
  is $code, 2, 'pack without -o exits 2';
  like $output, qr/^ERROR: skeid pack needs --class and -o$/m, 'saying what it needs';

  ($code, $output) = run_skeid(undef, 'pack', '--class', 'Mojo::File', '-o', "$tmp/packed");
  is $code, 2, 'pack of a class that is no Langertha::Skeid exits 2';
  like $output, qr/^ERROR: skeid_class 'Mojo::File' is not a Langertha::Skeid subclass$/m, 'saying why';
  ok !-e "$tmp/packed", 'and writes nothing';
}

SKIP: {
  skip 'PAR::Packer is installed here; xt/author/pack.t packs', 3 if eval { require PAR::Packer; 1 };
  my ($code, $output) = run_skeid(undef, 'pack', '--class', 'Test::Skeid::Dispatch', '-I', $lib,
    '-o', "$tmp/packed");
  is $code, 2, 'pack without PAR::Packer exits 2';
  like $output, qr/^ERROR: skeid pack needs PAR::Packer, which is not installed/m, 'naming it';
  ok !-e "$tmp/packed", 'and writes nothing';
}

done_testing;
