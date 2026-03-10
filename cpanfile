requires 'Langertha', '0.306';
requires 'Moo', '2.005005';
requires 'DBI', '1.643';
requires 'DBD::SQLite', '1.66';
requires 'YAML::PP', '0.038';
requires 'Mojolicious', '9.0';
requires 'JSON::MaybeXS', '1.004004';
requires 'Langertha::Knarr', '0.005';

recommends 'DBD::Pg';

on test => sub {
  requires 'Test2::Suite';
  requires 'Test::Mojo';
};
