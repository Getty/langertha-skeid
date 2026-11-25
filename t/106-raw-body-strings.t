#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use JSON::MaybeXS ();
use Time::HiRes qw(time);
use Langertha::Skeid::Protocol::RawBody;

# RawBody follows JSON structure without building anything (ADR 0023), and a JSON string token is
# the part it matches most: every key and every string value of every chat and embeddings body.
# The token is matched unrolled -- a run of plain characters, then an escape, then a run -- so a
# long string is one match instead of one per character (k140). These tests pin that the scanner
# reads exactly what it read before, and that no input makes it backtrack catastrophically.

my $with    = \&Langertha::Skeid::Protocol::RawBody::with_top_level;
my $schemas = \&Langertha::Skeid::Protocol::RawBody::tool_schemas;
my $spans   = \&Langertha::Skeid::Protocol::RawBody::_top_level_spans;
my $values  = \&Langertha::Skeid::Protocol::RawBody::string_values;

# --- escapes ---
{
  for my $case (
    [ '{"a":"x\\"","model":"m"}',              'an escaped quote at the end of a string' ],
    [ '{"a":"x\\\\","model":"m"}',             'an escaped backslash at the end of a string' ],
    [ '{"a":"\\\\\\"","model":"m"}',           'an escaped backslash, then an escaped quote' ],
    [ '{"a":"\\\\\\\\\\\\","model":"m"}',      'three escaped backslashes and nothing else' ],
    [ '{"a":"\\"","model":"m"}',               'a string that is one escaped quote' ],
    [ '{"a":"","model":"m"}',                  'an empty string' ],
    [ '{"a":"\\u00e4\\u65e5\\ud83d\\ude00","model":"m"}', '\\u sequences, a surrogate pair among them' ],
    [ '{"a":"\\n\\t\\r\\b\\f\\/","model":"m"}', 'the single-character escapes' ],
    [ qq({"a":"line\nbreak","model":"m"}),     'a raw newline inside a string' ],
    [ '{"x\\"y":"\\"","model":"m"}',           'an escaped quote inside a key' ],
  ) {
    my ($body, $name) = @$case;
    (my $want = $body) =~ s/"model":"m"/"model":"s"/;
    is($with->($body, model => 's'), $want, $name);
  }

  is($with->('{"mod\\u0065l":"a"}', model => 'b'), '{"mod\\u0065l":"b"}', 'a key spelled with \\u is still the key');

  my $utf8 = encode('UTF-8', '{"t":"Grüße — 日本 😀 \\" ü","n":["ä\\\\",{"k":"ö"}],"model":"a"}');
  is($with->($utf8, model => 'b'), encode('UTF-8', '{"t":"Grüße — 日本 😀 \\" ü","n":["ä\\\\",{"k":"ö"}],"model":"b"}'),
    'multi-byte UTF-8 around escapes passes through as bytes');
  my $got = $spans->($utf8);
  is_deeply([ map { $_->{key} } @$got ], [qw(t n model)], 'and every key is found');
  is(substr($utf8, $got->[1]{start}, $got->[1]{length}), encode('UTF-8', '["ä\\\\",{"k":"ö"}]'),
    'with the span of a nested value exact to the byte');

  is_deeply($schemas->('{"tools":[{"input_schema":{"d":"a \\"}\\" ]"}},{"input_schema":"\\\\"}]}', 'input_schema'),
    ['{"d":"a \\"}\\" ]"}', '"\\\\"'], 'brackets after an escaped quote inside a schema stay text');
}

# --- size ---
{
  my $mb = 'x' x (1024 * 1024);
  my $body = '{"messages":[{"role":"user","content":"' . $mb . '"}],"model":"a","input":"' . $mb . '\\"' . '"}';
  my $t0 = time;
  my $out = $with->($body, model => 'b');
  my $took = time - $t0;
  is(length($out // ''), length($body), 'a body with 1 MB strings is followed to the end');
  ok(index($out // q(), q("model":"b")) > 0, q(and its model replaced));
  cmp_ok($took, '<', 2, 'in well under the time box');

  my $esc = '"' . ('\\"x' x 200_000) . '"';
  is_deeply($schemas->('{"tools":[{"p":' . $esc . '}]}', 'p'), [$esc], 'a string of 200 000 escapes is one token');

  my $many = '{"model":"a","messages":[' . join(',', map { '{"role":"user","content":"m' . $_ . ' \\"q\\""}' } 1 .. 20_000) . ']}';
  $t0 = time;
  my $res = $with->($many, model => 'b');
  $took = time - $t0;
  is(substr($res // '', 0, 20), '{"model":"b","messag', 'many small strings: the body is followed');
  is(length($res), length($many), 'and nothing else changes length');
  cmp_ok($took, '<', 2, 'in well under the time box');
}

# --- pathological input finishes, and is refused ---
{
  my $n = 1_000_000;
  for my $case (
    [ '{"a":"' . ('x' x $n),                       'an unterminated 1 MB string' ],
    [ '{"a":"' . ('\\' x $n),                      'an unterminated run of backslashes (even)' ],
    [ '{"a":"' . ('\\' x ($n + 1)) . '"}',         'an odd run of backslashes that escapes the closing quote' ],
    [ '{"a":"' . ('\\"' x ($n / 2)),               'an unterminated run of escaped quotes' ],
    [ '{"' . ('\\' x ($n + 1)) . '":1}',           'a key whose closing quote is escaped' ],
    [ '{"a":[' . ('"x\\' x ($n / 3)),              'unterminated strings inside an array' ],
    [ '{"a":' . ('[' x 100_000) . '"\\' x 10,      'deep nesting ending in an unterminated string' ],
    [ '{"a":"' . ('\\u' x ($n / 2)),               'a run of half escapes' ],
  ) {
    my ($body, $name) = @$case;
    my $t0 = time;
    my $out = $with->($body, model => 'b');
    my $took = time - $t0;
    is($out, undef, $name . ': undef');
    cmp_ok($took, '<', 2, $name . ': finishes inside the time box');
    $t0 = time;
    is($schemas->($body, 'input_schema'), undef, $name . ': no schemas either');
    cmp_ok(time - $t0, '<', 2, $name . ': and that finishes too');
  }

  my $t0 = time;
  my $ok = $with->('{"a":"' . ('\\\\' x ($n / 2)) . '","model":"x"}', model => 'b');
  ok(defined $ok && $ok =~ /"model":"b"\}\z/, 'an even run of backslashes ends the string where it should');
  cmp_ok(time - $t0, '<', 2, 'inside the time box');
}

# --- the same answers as the per-character matching it replaces ---
{
  my @corpus = (
    '{"model":"a","x":1}',
    qq({ "z" : [1,2] ,\n  "model"  :  "a" , "a":{"model":"inner"} }),
    '{"model":"a","m":"x","model":"c"}',
    '{"t":"a \" } ] { [ , \\\\","model":"a"}',
    '{"model":null,"n":-1.5e3,"b":true}',
    encode('UTF-8', '{"t":"Grüße — 日本","model":"a"}'),
    '{"x":1}', '[{"model":"a"}]', '{"model":"a"', '{"model":"a"} trailing', '{"model" "a"}', '{}', '',
    '{"tools":[{"name":"a","input_schema":{"type":"object","required":[],"properties":{}}},{"name":"b"}]}',
    '{"tools":[{"type":"function","function":{"name":"w","parameters":{"type":"object","properties":{"p":{"type":"string","description":"a\\"b\\\\"}}}}}],"model":"m"}',
    '{"tools":{}}',
    '{"a":"\\', '{"a":"\\"}', '{"a":"\\\\"}', '{"\\"":"\\\\\\""}',
  );

  # A random corpus: generated bodies, and every one of them cut and with a byte flipped.
  srand(140);
  my @alphabet = ('a', 'Z', ' ', '"', '\\', '\\"', '\\\\', '\\u00e4', '{', '}', '[', ']', ',', ':',
    "\n", encode('UTF-8', 'ü'), encode('UTF-8', '日'), encode('UTF-8', '😀'));
  my $text = sub { join '', map { $alphabet[int rand @alphabet] } 1 .. int rand 12 };
  my $json = JSON::MaybeXS->new(utf8 => 0, canonical => 1);
  my $value; $value = sub {
    my ($depth) = @_;
    my $r = rand;
    return $json->encode($text->()) if $r < 0.4 || $depth > 4;
    return (int rand 1000) if $r < 0.5;
    return '[' . join(', ', map { $value->($depth + 1) } 1 .. int rand 4) . ']' if $r < 0.7;
    return '{' . join(',', map { $json->encode($text->()) . ' : ' . $value->($depth + 1) } 1 .. int rand 4) . '}';
  };
  for (1 .. 400) {
    my @members = map { $json->encode($text->()) . ':' . $value->(0) } 1 .. int rand 5;
    splice(@members, int rand(@members + 1), 0, '"model":' . $value->(3)) if rand > 0.2;
    splice(@members, int rand(@members + 1), 0,
      '"tools":[' . join(',', map { '{"input_schema":' . $value->(1) . ',"function":{"parameters":' . $value->(1) . '}}' } 1 .. int rand 3) . ']')
      if rand > 0.4;
    my $body = '{' . join(', ', @members) . '}';
    push @corpus, $body, substr($body, 0, int rand length $body);
    my $flip = $body;
    substr($flip, int rand length $flip, 1, $alphabet[int rand @alphabet]) if length $flip;
    push @corpus, $flip;
  }

  my $differ = 0;
  for my $body (@corpus) {
    my @old = (
      Old::with_top_level($body, model => 'served'),
      Old::tool_schemas($body, 'input_schema'),
      Old::tool_schemas($body, 'function', 'parameters'),
      Old::_top_level_spans($body),
    );
    my @new = (
      $with->($body, model => 'served'),
      $schemas->($body, 'input_schema'),
      $schemas->($body, 'function', 'parameters'),
      $spans->($body),
    );
    next if Test::More::eq_array(\@old, \@new);
    $differ++;
    diag('differs: ' . $body) if $differ <= 5;
  }
  is($differ, 0, 'with_top_level, tool_schemas and the spans answer byte for byte as before on '
    . scalar(@corpus) . ' bodies');
  my $followed = grep { defined Old::_top_level_spans($_) } @corpus;
  cmp_ok($followed, '>', 300, 'a corpus in which most bodies are followable, not just refused (' . $followed . ')');

  my $scan = $values->('{"a":"x\\"","b":["\\\\",{"c":"\\u00e4"}]}');
  is_deeply([ map { [ $_->{start}, $_->{length} ] } @{$scan->{strings}} ], [ [5, 5], [16, 4], [26, 8] ],
    'string_values, which already matched unrolled, reads the same spans');
}

done_testing;

# The per-character matching as it was before k140, kept to compare against.
package Old;

my $STRING;
BEGIN { $STRING = JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1) }    # set before the tests above run

sub with_top_level {
  my ($body, $key, $value) = @_;
  return undef unless defined($body) && defined($key) && defined($value);
  my $spans = _top_level_spans($body) or return undef;
  my @hits = grep { $_->{key} eq $key } @$spans;
  return undef unless @hits;
  my $replacement = $STRING->encode("$value");
  for my $hit (sort { $b->{start} <=> $a->{start} } @hits) {
    substr($body, $hit->{start}, $hit->{length}, $replacement);
  }
  return $body;
}

sub _top_level_spans {
  my ($json) = @_;
  my @spans;
  pos($json) = 0;
  $json =~ /\G\s*\{/gc or return undef;
  $json =~ /\G\s*/gc;
  unless ($json =~ /\G\}/gc) {
    while (1) {
      $json =~ /\G\s*("(?:[^"\\]|\\.)*")\s*:\s*/gcs or return undef;
      my $key = eval { $STRING->decode($1) };
      return undef unless defined $key;
      my $start = pos($json);
      _skip_value(\$json) or return undef;
      push @spans, { key => $key, start => $start, length => pos($json) - $start };
      $json =~ /\G\s*/gc;
      next if $json =~ /\G,/gc;
      last if $json =~ /\G\}/gc;
      return undef;
    }
  }
  $json =~ /\G\s*\z/gc or return undef;
  return \@spans;
}

sub _elements {
  my ($json) = @_;
  my @elements;
  pos($json) = 0;
  $json =~ /\G\s*\[/gc or return undef;
  $json =~ /\G\s*/gc;
  unless ($json =~ /\G\]/gc) {
    while (1) {
      $json =~ /\G\s*/gc;
      my $start = pos($json);
      _skip_value(\$json) or return undef;
      push @elements, substr($json, $start, pos($json) - $start);
      $json =~ /\G\s*/gc;
      next if $json =~ /\G,/gc;
      last if $json =~ /\G\]/gc;
      return undef;
    }
  }
  $json =~ /\G\s*\z/gc or return undef;
  return \@elements;
}

sub _member {
  my ($json, $key) = @_;
  my $spans = _top_level_spans($json) or return undef;
  my ($hit) = reverse grep { $_->{key} eq $key } @$spans;
  return $hit ? substr($json, $hit->{start}, $hit->{length}) : undef;
}

sub _skip_value {
  my ($ref) = @_;
  return 1 if $$ref =~ /\G"(?:[^"\\]|\\.)*"/gcs;
  if ($$ref =~ /\G[\[\{]/gc) {
    my $depth = 1;
    while ($depth) {
      if    ($$ref =~ /\G[^"\[\]\{\}]+/gc)       { }
      elsif ($$ref =~ /\G"(?:[^"\\]|\\.)*"/gcs)   { }
      elsif ($$ref =~ /\G[\[\{]/gc)              { $depth++ }
      elsif ($$ref =~ /\G[\]\}]/gc)              { $depth-- }
      else                                       { return 0 }
    }
    return 1;
  }
  return $$ref =~ /\G[^\s,\]\}"\[\{]+/gc ? 1 : 0;
}

sub tool_schemas {
  my ($body, @path) = @_;
  return undef unless defined $body;
  my $tools = _member($body, 'tools');
  my $elements = defined($tools) ? _elements($tools) : undef;
  return undef unless $elements;
  my @schemas;
  for my $text (@$elements) {
    for my $key (@path) {
      $text = defined($text) ? _member($text, $key) : undef;
    }
    push @schemas, $text;
  }
  return \@schemas;
}
