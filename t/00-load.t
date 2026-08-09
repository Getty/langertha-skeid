use strict;
use warnings;
use Test::More;

my @modules = qw(
  Langertha::Skeid
  Langertha::Skeid::Proxy
  Langertha::Skeid::Protocol
  Langertha::Skeid::Protocol::Anthropic
  Langertha::Skeid::Protocol::Ollama
  Langertha::Skeid::UsageStore
  Langertha::Skeid::UsageStore::JsonLog
  Langertha::Skeid::UsageStore::DBI
  Langertha::Skeid::KeyBroker
);

for my $mod (@modules) {
  require_ok($mod);
}

done_testing;
