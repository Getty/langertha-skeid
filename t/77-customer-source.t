use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::MaybeXS ();
use Mojo::IOLoop;
use Time::HiRes ();
use YAML::PP;
use Langertha::Skeid;
use Langertha::Skeid::CustomerSource;

# skeid k108/k109, ADR 0024: customer keys, names and policies from a database view, fetched in
# the background by a child process. Everything offline: a DBD::SQLite file stands in for
# PostgreSQL and the subprocess path runs against it; a fake source object covers the failure
# modes a database would need a network for.

BEGIN {
  eval { require DBI; require DBD::SQLite; 1 } or plan skip_all => 'DBD::SQLite is not installed';
}

my $dir  = tempdir(CLEANUP => 1);
my $json = JSON::MaybeXS->new(canonical => 1);

sub kid { Langertha::Skeid->key_id_for_key($_[0]) }

# Runs the loop until $cond is true or $secs pass; returns whether it became true.
sub wait_for {
  my ($cond, $secs) = @_;
  $secs ||= 10;
  my $ok = 0;
  my $poll = Mojo::IOLoop->recurring(0.02 => sub {
    if ($cond->()) { $ok = 1; Mojo::IOLoop->stop }
  });
  my $limit = Mojo::IOLoop->timer($secs => sub { Mojo::IOLoop->stop });
  Mojo::IOLoop->start;
  Mojo::IOLoop->remove($_) for $poll, $limit;
  return $ok;
}

# --- a SQLite file as the owning application's view ---
my $db = "$dir/customers.sqlite";
sub dbh {
  my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
  return $dbh;
}
{
  my $dbh = dbh();
  $dbh->do('CREATE TABLE skeid_customer_keys (key_id TEXT, name TEXT, policy TEXT, models TEXT)');
  $dbh->disconnect;
}
sub set_rows {
  my (@rows) = @_;
  my $dbh = dbh();
  $dbh->do('DELETE FROM skeid_customer_keys');
  $dbh->do('INSERT INTO skeid_customer_keys VALUES (?,?,?,?)', undef, @$_) for @rows;
  $dbh->disconnect;
}

my ($alice, $bob, $carol, $dave, $erin) = map { kid("sk-$_") } qw(alice bob carol dave erin);

my %base = (
  nodes    => [{ id => 'n1', url => 'http://127.0.0.1:1/v1', model => 'm' }],
  policies => {
    standard => { deny_tags => ['cloud'] },
    burst    => {},
    narrow   => { models => ['m-a', 'm-b'] },
  },
  default_policy => 'standard',
);
sub section {
  return { dsn => "dbi:SQLite:dbname=$db", relation => 'skeid_customer_keys',
           poll_interval_s => 30, connect_timeout_s => 2, @_ };
}

sub skeid_for {
  my ($cfg_ref, %args) = @_;
  return Langertha::Skeid->new(
    config_reload_interval => 0,
    config_loader          => sub { return { %{ $$cfg_ref } } },
    %args,
  );
}

# Starts a Skeid and waits for the first snapshot, then applies it.
sub ready {
  my ($skeid) = @_;
  my $f = $skeid->_customer_fetcher;
  wait_for(sub { $f->snapshot || $f->error_kind });
  $skeid->maybe_reload_config;
}

# ---------------------------------------------------------------------------------------------
# merge, offline fetch through the subprocess, and the union rule
# ---------------------------------------------------------------------------------------------
{
  set_rows(
    [ $alice, 'Alice', 'burst', undef ],
    [ $bob,   'Bob',   undef,   '["m-a"]' ],
  );
  my $cfg = { %base, client_auth => { keys => [ kid('sk-file') ] }, customer_source => section() };
  my @warn;
  local $SIG{__WARN__} = sub { push @warn, @_ };
  my $skeid = skeid_for(\$cfg);

  ok $skeid->_customer_fetcher, 'the section starts a fetcher';
  is $skeid->policy_for_key($alice), $skeid->default_policy,
    'degraded start: before the first fetch a database customer has default_policy';
  ok !$skeid->client_key_allowed($alice), 'degraded start: and is not on the allowlist (401)';

  ready($skeid);
  my $status = $skeid->customer_source_status;
  is $status->{snapshot}, 1, 'a snapshot is in force after the fetch child answered';
  is $status->{accepted}, 2, 'two rows accepted';
  is $skeid->policy_for_key($alice)->{name}, 'burst', 'the row selects the file profile';
  is_deeply $skeid->policy_for_key($alice)->{deny_tags}, [], 'burst denies nothing';
  ok $skeid->client_key_allowed($alice), 'a database key joins the allowlist when client_auth is declared';
  ok $skeid->client_key_allowed(kid('sk-file')), 'the file key stays on it';
  is_deeply $skeid->policy_for_key($bob)->{allow_models}, { 'm-a' => 1 },
    'models narrows the default profile: no model list means all, so the row list stands';
  is $skeid->customer_names->{$alice}, 'Alice', 'the name is kept for admin output';
  is $skeid->reload_status->{customer_source}{accepted}, 2, 'reload_status carries the customer source';

  # revoked: a missing row
  set_rows([ $alice, 'Alice', 'burst', undef ]);
  $skeid->_customer_fetcher->fetch_now;
  my $before = $skeid->_customer_fetcher->fetches;
  wait_for(sub { $skeid->_customer_fetcher->fetches > $before && !$skeid->_customer_fetcher->_inflight });
  ok $skeid->maybe_reload_config, 'the changed snapshot is applied like a changed file';
  ok !$skeid->client_key_allowed($bob), 'a row that is gone is a revoked key';
  ok $skeid->client_key_allowed($alice), 'the others are unaffected';
  is $skeid->reload_status->{ok}, 1, 'no reload failure';
  is_deeply \@warn, [], 'nothing was warned about';
}

# without client_auth the database does not turn authentication on
{
  set_rows([ $alice, 'Alice', 'burst', undef ]);
  my $cfg = { %base, customer_source => section() };
  my $skeid = skeid_for(\$cfg);
  ready($skeid);
  is $skeid->policy_for_key($alice)->{name}, 'burst', 'policy applies without client_auth';
  ok !$skeid->client_auth_enabled, 'a customer source does not enable client_auth';
  ok $skeid->client_key_allowed('k_anything'), 'so every key is still allowed';
}

# ---------------------------------------------------------------------------------------------
# rows are judged one by one and never fail a reload; the file wins; secrets never logged
# ---------------------------------------------------------------------------------------------
{
  my $pasted = 'sk-live-THIS-IS-A-KEY-NOT-AN-ID';
  set_rows(
    [ $alice,  'Alice',  'burst',       undef ],
    [ $pasted, 'Pasted', undef,         undef ],
    [ $carol,  'Carol',  'no-such',     undef ],
    [ $dave,   'Dave',   'narrow',      '[1,2' ],
    [ $erin,   'Erin',   'narrow',      '["other-model"]' ],
    [ $bob,    'Bob',    'burst',       undef ],
    [ $bob,    'Bob2',   'standard',    undef ],
    [ kid('sk-file'), 'FileKey', 'burst', undef ],
  );
  my $cfg = {
    %base,
    names       => { filekey => kid('sk-file') },
    keys        => { filekey => 'standard' },
    client_auth => { keys => ['filekey'] },
    customer_source => section(),
  };
  my @warn;
  local $SIG{__WARN__} = sub { push @warn, @_ };
  my $skeid = skeid_for(\$cfg);
  ready($skeid);

  is $skeid->reload_status->{ok}, 1, 'bad rows do not fail the reload';
  my $st = $skeid->customer_source_status;
  is $st->{accepted}, 1, 'only the good row grants';
  is $st->{rejected}, 6, 'pasted key, unknown policy, bad models, disjoint models and both duplicate rows are rejected';
  is $st->{shadowed}, 1, 'the file key is shadowed';
  is $skeid->policy_for_key(kid('sk-file'))->{name}, 'standard', 'the file wins per key id';
  ok !$skeid->client_key_allowed($carol), 'rejected row: not allowed';
  ok !$skeid->client_key_allowed($dave), 'rejected row: not allowed';
  ok !$skeid->client_key_allowed($erin), 'rejected row: not allowed';
  ok !$skeid->client_key_allowed($bob), 'duplicate key_id: neither row grants';
  my $log = join '', @warn;
  like $log, qr/6 row\(s\) rejected/, 'the rejection is logged with a count';
  like $log, qr/row 2: key_id is not k_ \+ 40 lowercase hex/, 'with position and reason';
  unlike $log, qr/\Q$pasted\E/, 'a pasted key never reaches the log';
  unlike $json->encode($skeid->reload_status), qr/\Q$pasted\E/, 'nor the status';
}

# ---------------------------------------------------------------------------------------------
# outage keeps the last snapshot; max_stale_s drops it; recovery
# ---------------------------------------------------------------------------------------------
{
  set_rows([ $alice, 'Alice', 'burst', undef ]);
  my $cfg = { %base, client_auth => { keys => [ kid('sk-file') ] },
              customer_source => section(poll_interval_s => 1, max_stale_s => 3600) };
  my @warn;
  local $SIG{__WARN__} = sub { push @warn, @_ };
  my $skeid = skeid_for(\$cfg);
  ready($skeid);
  ok $skeid->client_key_allowed($alice), 'outage: key allowed before the outage';

  my $f = $skeid->_customer_fetcher;
  { my $dbh = dbh(); $dbh->do('ALTER TABLE skeid_customer_keys RENAME TO gone'); $dbh->disconnect }
  $f->fetch_now;
  ok wait_for(sub { defined $f->error_kind }), 'the failed fetch is noticed';
  is $f->error_kind, 'query', 'as a query failure';
  ok $skeid->client_key_allowed($alice), 'outage: the last good snapshot stays in force';
  my $s = $skeid->reload_status->{customer_source};
  is $s->{ok}, 0, 'and the failure is reported';
  is $s->{error_kind}, 'query', 'by kind';
  ok !exists $s->{error}, 'never by text';
  like join('', @warn), qr/fetch failed \(query\), keeping the last snapshot/, 'and logged once';

  # max_stale_s: the snapshot is older than the limit -> file alone
  my $future = Time::HiRes::time() + 7200;
  no warnings 'redefine';
  local *Langertha::Skeid::_now = sub { $future };
  ok $skeid->maybe_reload_config, 'a stale snapshot is dropped by a reload';
  ok !$skeid->client_key_allowed($alice), 'max_stale_s: the file alone is in force (fail closed)';
  is $skeid->customer_source_status->{stale}, 1, 'status says stale';
}

# recovery after an outage
{
  my $dbh = dbh();
  $dbh->do('ALTER TABLE gone RENAME TO skeid_customer_keys');
  $dbh->disconnect;
}

# ---------------------------------------------------------------------------------------------
# degraded start from a broken relation, and a file-based config
# ---------------------------------------------------------------------------------------------
{
  my $file = "$dir/skeid.yaml";
  my $cfg = { %base, client_auth => { keys => [ kid('sk-file') ] },
              customer_source => section(relation => 'no_such_view') };
  YAML::PP->new->dump_file($file, $cfg);
  local $SIG{__WARN__} = sub { };
  my $skeid = Langertha::Skeid->new(config_file => $file, config_reload_interval => 0);
  my $f = $skeid->_customer_fetcher;
  wait_for(sub { defined $f->error_kind });
  ok $skeid->client_key_allowed(kid('sk-file')), 'degraded start: the file customers work';
  ok !$skeid->client_key_allowed($alice), 'degraded start: database customers are 401';
  is $skeid->reload_status->{ok}, 1, 'degraded start is not a reload failure';

  # file-based: a snapshot landing is applied without the file having changed
  $cfg->{customer_source}{relation} = 'skeid_customer_keys';
  set_rows([ $alice, 'Alice', 'burst', undef ]);
  YAML::PP->new->dump_file($file, $cfg);
  utime(time + 5, time + 5, $file);
  $skeid->maybe_reload_config;    # new section -> new fetcher
  $f = $skeid->_customer_fetcher;
  wait_for(sub { $f->snapshot });
  set_rows([ $alice, 'Alice', 'burst', undef ], [ $bob, 'Bob', 'burst', undef ]);
  $f->fetch_now;
  my $n = $f->fetches;
  wait_for(sub { $f->fetches > $n && !$f->_inflight });
  ok $skeid->maybe_reload_config, 'file-based config: a new snapshot is applied with the file unchanged';
  ok $skeid->policy_for_key($bob) && $skeid->policy_for_key($bob)->{name} eq 'burst', 'and takes effect';
}

# ---------------------------------------------------------------------------------------------
# a fake source: wake-up, deadline, pre-check, secrets
# ---------------------------------------------------------------------------------------------
{
  package FakeSource;
  use JSON::MaybeXS ();
  sub new { my ($c, %a) = @_; bless {%a}, $c }
  sub _state { my $s = shift; open my $fh, '<', $s->{file} or die "no state\n"; local $/; JSON::MaybeXS::decode_json(<$fh>) }
  sub tcp_target { my $s = shift; return $s->{target} ? @{ $s->{target} } : () }
  sub fetch {
    my ($s) = @_;
    open my $m, '>>', $s->{marker} or die $!; print $m "x\n"; close $m;
    my $st = $s->_state;
    sleep $st->{sleep} if $st->{sleep};
    die $st->{die} . "\n" if $st->{die};
    return $st->{rows};
  }
  sub listen_loop {
    my ($s, $emit, $stop) = @_;
    $emit->('ready');
    until ($stop->()) {
      if (-e $s->{notify}) { unlink $s->{notify}; $emit->('notify') }
      select undef, undef, undef, 0.05;
    }
  }
}

sub fake {
  my (%a) = @_;
  my $state = "$dir/fake-state.json";
  my $marker = "$dir/fake-marker";
  unlink $marker;
  my $write = sub { open my $fh, '>', $state or die; print $fh $json->encode($_[0]); close $fh };
  $write->({ rows => [] });
  my $source = FakeSource->new(file => $state, marker => $marker, notify => "$dir/notify", %a);
  return ($source, $write, $marker);
}
sub marks { my $m = shift; return 0 unless -e $m; open my $fh, '<', $m; my @l = <$fh>; return scalar @l }

# NOTIFY wakes the poll; poll_interval_s is far away
{
  my ($source, $write, $marker) = fake();
  $write->({ rows => [[ $alice, 'Alice', 'burst', undef ]] });
  my $cfg = { %base, client_auth => { keys => [ kid('sk-file') ] },
              customer_source => { dsn => 'dbi:Pg:dbname=x', relation => 'v', listen => 'skeid_customers',
                                   poll_interval_s => 600, connect_timeout_s => 2 } };
  my $skeid = skeid_for(\$cfg, customer_source_factory => sub { $source });
  ready($skeid);
  ok $skeid->client_key_allowed($alice), 'listen: first fetch landed';
  my $f = $skeid->_customer_fetcher;
  $write->({ rows => [[ $alice, 'Alice', 'burst', undef ], [ $bob, 'Bob', 'burst', undef ]] });
  my $n = marks($marker);
  open my $fh, '>', "$dir/notify"; close $fh;
  ok wait_for(sub { marks($marker) > $n && !$f->_inflight && @{ $f->snapshot->{rows} } == 2 }, 8),
    'a NOTIFY wakes the fetch long before the poll interval';
  $skeid->maybe_reload_config;
  ok $skeid->client_key_allowed($bob), 'and the new customer is in';
  $f->stop;
}

# the child is killed at its deadline, the loop keeps running
{
  my ($source, $write, $marker) = fake();
  $write->({ sleep => 30, rows => [] });
  local $Langertha::Skeid::CustomerSource::DEADLINE_MARGIN_S = 0;
  my $cfg = { %base, customer_source => { dsn => 'dbi:SQLite:dbname=x', relation => 'v',
                                          poll_interval_s => 600, connect_timeout_s => 1 } };
  my @warn;
  local $SIG{__WARN__} = sub { push @warn, @_ };
  my $skeid = skeid_for(\$cfg, customer_source_factory => sub { $source });
  my $f = $skeid->_customer_fetcher;
  my ($last, $gap) = (Time::HiRes::time(), 0);
  my $tick = Mojo::IOLoop->recurring(0.05 => sub {
    my $now = Time::HiRes::time();
    $gap = $now - $last if $now - $last > $gap;
    $last = $now;
  });
  my $t0 = Time::HiRes::time();
  ok wait_for(sub { defined $f->error_kind }, 10), 'an overrunning child is given up on';
  my $took = Time::HiRes::time() - $t0;
  Mojo::IOLoop->remove($tick);
  is $f->error_kind, 'timeout', 'as a timeout';
  cmp_ok $took, '<', 5, 'at the deadline, not after the 30s the child wanted';
  cmp_ok $gap, '<', 0.5, 'and the loop kept ticking while the child blocked (largest gap ' . sprintf('%.3f', $gap) . 's)';
  $f->stop;
}

# TCP pre-check: a closed port costs no fork; the loop is not blocked
{
  my ($source, $write, $marker) = fake(target => [ '127.0.0.1', 1 ]);
  $write->({ rows => [] });
  my $cfg = { %base, customer_source => { dsn => 'dbi:Pg:dbname=x;host=127.0.0.1;port=1', relation => 'v',
                                          poll_interval_s => 600, connect_timeout_s => 2 } };
  local $SIG{__WARN__} = sub { };
  my $skeid = skeid_for(\$cfg, customer_source_factory => sub { $source });
  my $f = $skeid->_customer_fetcher;
  ok wait_for(sub { defined $f->error_kind }, 8), 'closed port: the failure is noticed';
  is $f->error_kind, 'tcp', 'by the pre-check';
  is marks($marker), 0, 'without forking a fetch child';
  is $f->precheck_skips, 1, 'counted';
  $f->stop;
}

# control for the measurement: a blocking call on the loop DOES stall a ticking timer, which is
# the k109 failure (a DBD::Pg connect to a blackholed host blocks like this for up to
# connect_timeout_s) -- and the fetcher's child path above shows no such gap.
{
  my ($last, $gap) = (Time::HiRes::time(), 0);
  my $tick = Mojo::IOLoop->recurring(0.05 => sub {
    my $now = Time::HiRes::time();
    $gap = $now - $last if $now - $last > $gap;
    $last = $now;
  });
  Mojo::IOLoop->timer(0.1 => sub { select undef, undef, undef, 0.6; Mojo::IOLoop->timer(0.2 => sub { Mojo::IOLoop->stop }) });
  Mojo::IOLoop->start;
  Mojo::IOLoop->remove($tick);
  cmp_ok $gap, '>=', 0.5, 'control: a blocking call on the loop produces the gap the child path avoids';
}

# secrets: the password reaches neither the log nor the status
{
  local $ENV{SKEID_TEST_CUSTOMERS_PW} = 'hunter2-the-password';
  my ($source, $write) = fake();
  $write->({ die => 'FATAL: password authentication failed (hunter2-the-password) for user "ro"' });
  my $cfg = { %base, customer_source => { dsn => 'dbi:SQLite:dbname=x', relation => 'v',
                                          password_env => 'SKEID_TEST_CUSTOMERS_PW',
                                          poll_interval_s => 600, connect_timeout_s => 2 } };
  my @warn;
  local $SIG{__WARN__} = sub { push @warn, @_ };
  my $skeid = skeid_for(\$cfg, customer_source_factory => sub { $source });
  my $f = $skeid->_customer_fetcher;
  wait_for(sub { defined $f->error_kind });
  my $all = join('', @warn) . $json->encode($skeid->reload_status);
  like $all, qr/fetch failed/, 'the failure is logged';
  unlike $all, qr/hunter2-the-password/, 'the password is scrubbed from the log and the status';
  $f->stop;
}

# ---------------------------------------------------------------------------------------------
# the section is validated at load
# ---------------------------------------------------------------------------------------------
{
  my $n = 'Langertha::Skeid::CustomerSource';
  my %ok = (dsn => 'dbi:Pg:dbname=c', relation => 'v');
  my $norm = $n->normalize_config({ %ok });
  is $norm->{poll_interval_s}, 30, 'default poll interval';
  is $norm->{max_stale_s}, 0, 'default: keep the snapshot forever';
  like eval { $n->normalize_config({ %ok, password => 'x' }); '' } || $@, qr/never written into the config/, 'a literal password is refused';
  like eval { $n->normalize_config({ %ok, relation => 'v; drop table x' }); '' } || $@, qr/table or view name/, 'relation is an identifier';
  like eval { $n->normalize_config({ %ok, nope => 1 }); '' } || $@, qr/unknown key 'nope'/, 'unknown key';
  like eval { $n->normalize_config({ dsn => 'dbi:SQLite:dbname=x', relation => 'v', listen => 'c' }); '' } || $@, qr/PostgreSQL feature/, 'listen is PostgreSQL only';
  like eval { $n->normalize_config({ %ok, poll_interval_s => 0 }); '' } || $@, qr/poll_interval_s/, 'poll interval floor';
  like eval { $n->normalize_config({ from_usage_store => 1, relation => 'v' }); '' } || $@, qr/usage_store/, 'from_usage_store needs a usage store';
  my $u = $n->normalize_config({ from_usage_store => 1, relation => 'v' },
    usage_store => { sqlite_path => "$dir/u.sqlite" });
  is $u->{dsn}, "dbi:SQLite:dbname=$dir/u.sqlite", 'from_usage_store reuses the store\'s DSN';

  my $cfg = { %base, customer_source => { %ok, password => 'x' } };
  local $SIG{__WARN__} = sub { };
  ok !eval { skeid_for(\$cfg); 1 }, 'a bad section fails the load';
  like $@, qr/customer_source/, 'naming the section';
}

done_testing;
