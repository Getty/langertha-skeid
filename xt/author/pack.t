#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use IO::Socket::INET;
use Mojo::IOLoop::Server;
use Mojo::UserAgent;
use Path::Tiny qw(path);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);

# `skeid pack` (ADR 0030): a deployment's class and Skeid in one executable, built by
# PAR::Packer. Packs a small class, removes its source, and runs the file: it must listen, answer
# a chat request from the node only the packed class picks, and say how big it is and how long it
# takes to start -- cold (an empty PAR cache, which unpacks) and warm (the cache it left).
# Author test: it needs PAR::Packer, and packing takes a while.

plan skip_all => 'author test, set AUTHOR_TESTING=1' unless $ENV{AUTHOR_TESTING};
plan skip_all => 'needs PAR::Packer' unless eval { require PAR::Packer; 1 };

my $root = path($FindBin::Bin)->parent->parent;
my $bin  = $root->child('bin', 'skeid')->stringify;
my $tmp  = path(tempdir(CLEANUP => 1));

my %pid;
END {
  # $? is the test's exit status here: reaping the children below would overwrite it with
  # theirs -- a SIGKILLed child is 9 -- and a passing run would exit 9.
  local $?;
  for my $pid (grep { defined } values %pid) {
    kill 'KILL', $pid;
    waitpid($pid, 0);
  }
}

# The class: the node tagged `packed` before any other. Round-robin would serve `a` first.
my $lib = $tmp->child('lib');
$lib->child('Pack')->mkpath;
$lib->child('Pack', 'Skeid.pm')->spew(<<'PERL');
package Pack::Skeid;
use Moo;
extends 'Langertha::Skeid';
around pick_node => sub {
  my ($orig, $self, %selector) = @_;
  return $self->$orig(%selector, tags => ['packed']) // $self->$orig(%selector);
};
1;
PERL

# The fake upstream, a process of its own: the packed file is one too.
my $up_port = Mojo::IOLoop::Server->generate_port;
$pid{upstream} = fork // die "fork: $!";
if (!$pid{upstream}) {
  require Mojolicious;
  require Mojo::Server::Daemon;
  my $app = Mojolicious->new;
  $app->log->level('fatal');
  $app->routes->post('/v1/chat/completions' => sub {
    my ($c) = @_;
    my $model = ($c->req->json || {})->{model} // '';
    $c->render(json => {
      id      => 'chatcmpl-pack',
      object  => 'chat.completion',
      model   => $model,
      choices => [{ index => 0, message => { role => 'assistant', content => 'packed' }, finish_reason => 'stop' }],
      usage   => { prompt_tokens => 2, completion_tokens => 1, total_tokens => 3 },
    });
  });
  Mojo::Server::Daemon->new(app => $app, listen => ["http://127.0.0.1:$up_port"], silent => 1)->run;
  POSIX::_exit(0);
}

my $config = $tmp->child('skeid.yaml');
$config->spew(<<"YAML");
nodes:
  - { id: a, url: "http://127.0.0.1:$up_port/v1", model: m, trust: internal }
  - { id: b, url: "http://127.0.0.1:$up_port/v1", model: m, trust: internal, tags: [packed] }
YAML

my $packed = $tmp->child('my-skeid');
my $started = time;
my $output = `"$^X" -I"$root/lib" "$bin" pack --class Pack::Skeid -I "$lib" -o "$packed" 2>&1`;
my $pack_status = $?;
my $pack_seconds = time - $started;
is $pack_status, 0, 'skeid pack exits 0' or diag $output;
unlike $output, qr/Use of uninitialized value \$mod|# Use of runtime loader module/,
  'the two Module::ScanDeps notices are filtered';
like $output, qr/^Packed Pack::Skeid into \Q$packed\E$/m, 'and says what it packed';
ok -f $packed && -x $packed, 'the file is there and executable';
diag sprintf('pack: %.1f s, %.1f MB', $pack_seconds, (-s $packed // 0) / 1e6);

# Nothing of the class or Skeid outside the file: the class's source is gone, and no lib is
# on the path.
$lib->remove_tree;

my $cache = $tmp->child('par-cache');
$cache->mkpath;

# Starts the packed file and returns how long it took to listen, or undef.
sub start_packed {
  my ($name, $port) = @_;
  my $log = $tmp->child("$name.log");
  $started = time;
  $pid{$name} = fork // die "fork: $!";
  if (!$pid{$name}) {
    delete @ENV{qw( PERL5LIB PERLLIB PERL5OPT )};
    $ENV{PAR_GLOBAL_TEMP} = "$cache";
    chdir "$tmp" or die $!;
    open STDOUT, '>', "$log" or die $!;
    open STDERR, '>&', \*STDOUT or die $!;
    exec "$packed", 'serve', '--listen', "127.0.0.1:$port", '--config', "$config";
    die "exec: $!";
  }
  my $deadline = time + 120;
  while (time < $deadline) {
    return time - $started if IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1);
    last if waitpid($pid{$name}, WNOHANG) == $pid{$name};
    sleep 0.02;
  }
  diag $log->slurp if -f $log;
  return undef;
}

sub stop_packed {
  my ($name) = @_;
  kill 'TERM', $pid{$name};
  waitpid($pid{$name}, 0);
  delete $pid{$name};
}

my $port = Mojo::IOLoop::Server->generate_port;
my $cold = start_packed(cold => $port);
ok defined $cold, 'the packed file listens';

my $tx = Mojo::UserAgent->new->post("http://127.0.0.1:$port/v1/chat/completions" => json => {
  model    => 'm',
  messages => [{ role => 'user', content => 'hi' }],
});
is $tx->res->code, 200, 'a chat request through the packed file is answered'
  or diag $tx->res->body;
is $tx->res->json('/choices/0/message/content'), 'packed', 'by the upstream';
is $tx->res->headers->header('x-skeid-node'), 'b', 'from the node the packed class picks';
stop_packed('cold');
# Read once it stopped: its standard output is a file, buffered until then.
like $tmp->child('cold.log')->slurp, qr/^Class: Pack::Skeid$/m, 'serving the packed class';

$port = Mojo::IOLoop::Server->generate_port;
my $warm = start_packed(warm => $port);
ok defined $warm, 'a second start, from the PAR cache, listens';
stop_packed('warm');

diag sprintf('start until listening: cold %.2f s, warm %.2f s', $cold // -1, $warm // -1);

done_testing;
