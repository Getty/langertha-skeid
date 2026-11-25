#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::MaybeXS ();
use Langertha::Skeid::Filter;
use Langertha::Skeid::Filter::Restore;
use Langertha::Skeid::Protocol::RawBody;

# The pieces of the filter seam (ADR 0035) without a proxy: which texts a request has, the
# filtered texts put back into the client's bytes, the filter's answer checked, the usage
# allowlist, and the reverse table that translates an answer back -- held back across chunks,
# per channel, JSON-escaped in tool-call arguments.

binmode(Test::More->builder->$_, ':encoding(UTF-8)') for qw( output failure_output todo_output );

my $F = 'Langertha::Skeid::Filter';
my $JSON = JSON::MaybeXS->new(utf8 => 1, canonical => 1);
my $CHARS = JSON::MaybeXS->new;
my $P1 = "\x{27E6}PERSON_1\x{27E7}";

subtest 'string_values: every string value with its path, keys excluded' => sub {
  my $scan = Langertha::Skeid::Protocol::RawBody::string_values('{"a" : ["x", {"b":"y","n":1}], "c":"z"}');
  my @ids = map { $F->path_id($_->{path}) } @{$scan->{strings}};
  is_deeply \@ids, ['$.a[0]', '$.a[1].b', '$.c'], 'paths of the values';
  ok !$scan->{duplicate}, 'no key twice';
  ok Langertha::Skeid::Protocol::RawBody::string_values('{"a":"1","a":"2"}')->{duplicate}, 'a key twice is said';
  is Langertha::Skeid::Protocol::RawBody::string_values('{"a":'), undef, 'broken JSON: undef';
  is $F->path_id([[0, 'a b'], [1, 2], [0, 'c']]), '$["a b"][2].c', 'an odd key is quoted';
  my $long = '{"t":"' . ('a\\"' x 40000) . '"}';
  is scalar @{Langertha::Skeid::Protocol::RawBody::string_values($long)->{strings}}, 1, 'a long string with escapes';
};

subtest 'extract: the texts of a chat request, nothing else' => sub {
  my $body = {
    model    => 'm',
    tools    => [{ type => 'function', function => { name => 'lookup', description => 'Max Mustermann',
      parameters => { type => 'object', properties => { who => { type => 'string', description => 'x' } } } } }],
    response_format => { type => 'json_schema', json_schema => { name => 'n', schema => { type => 'string' } } },
    messages => [
      { role => 'system', content => 'You help.' },
      { role => 'user', name => 'max', content => [{ type => 'text', text => 'I am Max' }] },
      { role => 'assistant', content => undef, tool_calls => [{ id => 'c1', type => 'function',
        function => { name => 'lookup', arguments => '{"who":"Max","n":3,"tags":["a"]}' } }] },
      { role => 'tool', tool_call_id => 'c1', content => 'Max lives here' },
    ],
  };
  my $got = $F->extract($body, 'chat');
  is_deeply [ map { $_->{id} } @{$got->{texts}} ], [
    '$.messages[0].content',
    '$.messages[1].content[0].text',
    '$.messages[1].name',
    '$.messages[2].tool_calls[0].function.arguments.who',
    '$.messages[2].tool_calls[0].function.arguments.tags[0]',
    '$.messages[3].content',
  ], 'contents, text parts, names, argument strings -- no tools, schemas, function names, ids, roles';
  ok !$got->{unfilterable}, 'filterable';

  my $image = $F->extract({ messages => [{ role => 'user', content => [
    { type => 'text', text => 'see' }, { type => 'image_url', image_url => { url => 'data:...' } },
  ] }] }, 'chat');
  ok $image->{unfilterable}, 'an image part cannot be filtered';
  ok $F->extract({ messages => [{ role => 'assistant', tool_calls => [{ function => { name => 'f', arguments => 'not json' } }] }] }, 'chat')->{unfilterable},
    'arguments that are not JSON cannot be filtered';

  is_deeply [ map { $_->{id} } @{$F->extract({ input => ['a', 'b'] }, 'embeddings')->{texts}} ],
    ['$.input[0]', '$.input[1]'], 'embeddings input list';
  is_deeply [ map { $_->{id} } @{$F->extract({ input => 'a' }, 'embeddings')->{texts}} ], ['$.input'], 'one input';
  ok $F->extract($JSON->decode('{"input":[1,2,3]}'), 'embeddings')->{unfilterable}, 'token ids cannot be filtered';
  ok !$F->extract($JSON->decode('{"input":["1","2"]}'), 'embeddings')->{unfilterable}, 'digits in a string are text';
};

subtest 'substitute: only the strings change, key order, whitespace and escapes stay' => sub {
  my $bytes = qq({ "model" :"m",\n  "messages":[{"content":"Hi I am Max \\u00fc","role":"user"},)
    . qq({"role":"assistant","tool_calls":[{"function":{"arguments":"{\\"who\\": \\"Max\\", \\"n\\":1}","name":"f"}}]}], "zeta":"\\/"});
  my $body = $JSON->decode($bytes);
  my $texts = $F->extract($body, 'chat');
  my %replace = (
    '$.messages[0].content' => qq(Hi I am $P1 "quoted" back\\slash\nnew),
    '$.messages[1].tool_calls[0].function.arguments.who' => qq($P1 "q"),
  );
  my $out = $F->substitute($bytes, $texts, \%replace);
  ok defined $out, 'substituted';
  my $expect_content = $JSON->encode(qq(Hi I am $P1 "quoted" back\\slash\nnew));
  like $out, qr/\A\{ "model" :"m",\n  "messages":\[\{"content":\Q$expect_content\E,"role":"user"\}/,
    'the members before and after keep their order and spacing';
  like $out, qr/"zeta":"\\\/"\}\z/, 'an escape elsewhere is kept as the client wrote it';
  my $decoded = $JSON->decode($out);
  is $decoded->{messages}[0]{content}, qq(Hi I am $P1 "quoted" back\\slash\nnew), 'the content decodes to the filtered text';
  is_deeply $CHARS->decode($decoded->{messages}[1]{tool_calls}[0]{function}{arguments}), { who => qq($P1 "q"), n => 1 },
    'the arguments stay JSON, with the filtered value';
  like $decoded->{messages}[1]{tool_calls}[0]{function}{arguments}, qr/\A\{"who": "/, 'their own spacing kept';

  is $F->substitute('{"messages":[{"content":"a"}],"messages":[{"content":"b"}]}', $texts, { '$.messages[0].content' => 'x' }),
    undef, 'a key twice: the bytes are not used';
  is $F->substitute('{"messages":[]}', $texts, { '$.messages[0].content' => 'x' }), undef,
    'a text not where its id says: the bytes are not used';

  my $data = $JSON->decode($bytes);
  $F->set_texts($data, $texts, \%replace);
  is $data->{messages}[0]{content}, $replace{'$.messages[0].content'}, 'set_texts: the decoded body';
  is $CHARS->decode($data->{messages}[1]{tool_calls}[0]{function}{arguments})->{who}, qq($P1 "q"),
    'set_texts: inside the arguments';
};

subtest 'check_result: the contract, fail-closed' => sub {
  my $texts = $F->extract({ messages => [{ role => 'user', content => 'I am Max' }] }, 'chat');
  my ($r, $e) = $F->check_result({ decision => 'replace',
    texts => [{ id => '$.messages[0].content', text => "I am $P1" }],
    map   => [{ id => '$.messages[0].content', start => 5, end => 8, placeholder => $P1 }],
    headers => { 'X-Skeid-Filter' => 'done', Authorization => 'x', 'x-api-key' => 'k', 'X-Bad' => "a\r\nb" },
  }, $texts);
  ok $r, 'a good answer' or diag $e;
  is_deeply $r->{map}, [{ placeholder => $P1, text => 'Max' }], 'the original is the span of the original text';
  is_deeply $r->{headers}, { 'X-Skeid-Filter' => 'done' }, 'only X- headers, no credential, no line breaks';
  for my $bad (
    [undef, 'not an object'],
    [{ decision => 'maybe' }, 'unknown decision'],
    [{ decision => 'replace', texts => [{ id => '$.nope', text => 'x' }] }, 'unknown id'],
    [{ decision => 'replace', texts => [{ id => '$.messages[0].content', text => {} }] }, 'text not a string'],
    [{ decision => 'replace', texts => 'x' }, 'texts not a list'],
    [{ decision => 'replace', map => [{ text => 'Max' }] }, 'map entry without placeholder'],
    [{ decision => 'replace', map => [{ placeholder => $P1 }] }, 'map entry without original'],
    [{ decision => 'pass', usage => [] }, 'usage not an object'],
  ) {
    my ($ok, $error) = $F->check_result($bad->[0], $texts);
    ok !$ok && $error, "refused: $bad->[1]";
  }
};

subtest 'usage_fields: pii_* and filter_* numbers, tokens, flat hashes' => sub {
  is_deeply $F->usage_fields({
    pii_found   => 3,
    filter_ms   => '12.5',
    filter_model => 'ner-v2',
    pii_types   => { PERSON => 2, EMAIL => 1, bad => 'x', 'with space' => 1 },
    pii_text    => 'Max Mustermann',
    pii_nested  => { a => { b => 1 } },
    filter_list => [1],
    cost        => 1,
    text        => 'secret',
  }), {
    pii_found => 3, filter_ms => 12.5, filter_model => 'ner-v2', pii_types => { PERSON => 2, EMAIL => 1 },
  }, 'a text, a list, a nested hash and other keys are dropped';
};

sub restorer {
  my (%usage);
  my $r = Langertha::Skeid::Filter::Restore->new(usage => \%usage, map => [
    { placeholder => $P1, text => 'Max Mustermann' },
    { placeholder => "\x{27E6}EMAIL_1\x{27E7}", text => 'max@example.org' },
    { placeholder => "\x{27E6}PERSON_2\x{27E7}", text => 'Erika "E" M\\uller' },
  ]);
  return ($r, \%usage);
}

subtest 'restore_text: exact, lenient forms for known tags, unknown counted' => sub {
  my ($r, $usage) = restorer();
  is $r->restore_text("Hi $P1!"), 'Hi Max Mustermann!', 'as written';
  is $r->restore_text('Hi [PERSON_1], [ person 1 ], ⟦PERSON 1⟧, [PERSON  _1]'),
    'Hi Max Mustermann, Max Mustermann, Max Mustermann, Max Mustermann', 'lenient forms';
  is $usage->{filter_restored}, 5, 'counted';
  is $r->restore_text('[PERSON_7] and [EMAIL_9] and [link] and [NOTE_1]'),
    '[PERSON_7] and [EMAIL_9] and [link] and [NOTE_1]', 'unknown placeholders are left';
  is $usage->{pii_unknown}, 2, 'only those of a known kind count as unknown';
  is $r->restore_text('a ⟦PERSON_2⟧ b', 1), 'a Erika \\"E\\" M\\\\uller b', 'JSON-escaped in arguments';
  is $r->restore_text('Max is ⟦EMAIL_1⟧ ⟦PERSON_1⟧'), 'Max is max@example.org Max Mustermann',
    'an original is not translated again';
};

subtest 'feed/flush: placeholders cut across chunk borders, 40-character holdback' => sub {
  my ($r) = restorer();
  my $text = "Hello $P1, mail [EMAIL_1] or ⟦PER SON_2⟧? [x] done";
  my $out = '';
  $out .= $r->feed('0/content', $_) for split //, $text;
  $out .= $r->flush('0/content');
  is $out, 'Hello Max Mustermann, mail max@example.org or ⟦PER SON_2⟧? [x] done', 'one character per chunk';

  ($r) = restorer();
  my $first = $r->feed('c', 'see [' . ('a' x 30));
  is $first, 'see ', 'an open bracket is held';
  my $second = $r->feed('c', 'a' x 10);
  is $second, '[' . ('a' x 40), 'past 40 characters it is let go';

  ($r) = restorer();
  is $r->feed('a', 'x [PERS'), 'x ', 'channel a holds';
  is $r->feed('b', 'ON_1]'), 'ON_1]', 'channel b is its own';
  is $r->feed('a', 'ON_1] y'), 'Max Mustermann y', 'channel a completes';

  ($r) = restorer();
  is $r->feed('h', 'x [PERS'), 'x ', 'held';
  is $r->feed('h', 'ON_1'), '', 'a chunk without a bracket while something is held is held too';
  is $r->feed('h', '] y'), 'Max Mustermann y', 'and completes the placeholder';
  is $r->feed('h', 'plain text'), 'plain text', 'nothing held, no bracket: as it came';

  my %u;
  my $bare = Langertha::Skeid::Filter::Restore->new(usage => \%u, map => [{ placeholder => 'PII_1', text => 'Max' }]);
  is $bare->feed('b', 'hi PII_1'), 'hi Max', 'a placeholder without brackets is still found in a bracketless chunk';
};

subtest 'frames: SSE deltas, the ending choice, tool-call fragments per call' => sub {
  my ($r) = restorer();
  my @in = (
    { id => 'c', choices => [{ index => 0, delta => { role => 'assistant' } }] },
    { id => 'c', choices => [{ index => 0, delta => { content => 'Hi ⟦PER' } }] },
    { id => 'c', choices => [{ index => 0, delta => { content => 'SON_1⟧, see [' } }] },
    { id => 'c', choices => [{ index => 0, delta => {}, finish_reason => 'stop' }], usage => { total_tokens => 3 } },
  );
  my (@out, @changed);
  for my $frame (@in) {
    my ($frames, $changed) = $r->frames($frame);
    push @out, @$frames;
    push @changed, $changed;
  }
  is_deeply \@changed, [0, 1, 1, 1], 'a frame without text is unchanged';
  is join('', map { $_->{choices}[0]{delta}{content} // '' } @out), 'Hi Max Mustermann, see [', 'the text, in order';
  is scalar(@out), 5, 'the end of the choice was split off';
  is $out[3]{choices}[0]{finish_reason}, undef, 'the held text goes first, without the end';
  ok !exists $out[3]{usage}, 'and without the usage';
  is $out[4]{choices}[0]{finish_reason}, 'stop', 'then the end';
  is_deeply $out[4]{usage}, { total_tokens => 3 }, 'with the usage';

  ($r) = restorer();
  my @tool = (
    { choices => [{ index => 0, delta => { tool_calls => [
      { index => 0, id => 't0', function => { name => 'a', arguments => '{"who":"⟦PER' } },
      { index => 1, id => 't1', function => { name => 'b', arguments => '{"to":"[EMA' } },
    ] } }] },
    { choices => [{ index => 0, delta => { tool_calls => [{ index => 1, function => { arguments => 'IL_1]"}' } }] } }] },
    { choices => [{ index => 0, delta => { tool_calls => [{ index => 0, function => { arguments => 'SON_2⟧"}' } }] } }] },
  );
  my %args;
  for my $frame (@tool) {
    my ($frames) = $r->frames($frame);
    for my $f (@$frames) {
      $args{$_->{index}} .= $_->{function}{arguments} // '' for @{$f->{choices}[0]{delta}{tool_calls} || []};
    }
  }
  for my $f ($r->flush_frames) {
    $args{$_->{index}} .= $_->{function}{arguments} // '' for @{$f->{choices}[0]{delta}{tool_calls} || []};
  }
  is_deeply $CHARS->decode($args{0}), { who => 'Erika "E" M\\uller' }, 'call 0: valid JSON, value escaped';
  is_deeply $CHARS->decode($args{1}), { to => 'max@example.org' }, 'call 1: its own fragments';
};

subtest 'restore_bytes and restore_payload: an answer' => sub {
  my ($r) = restorer();
  my $body = qq({"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":"Hi $P1",)
    . qq("tool_calls":[{"id":"t","function":{"name":"f","arguments":"{\\"who\\":\\"$P1\\"}"}}]}}],"model":"[PERSON_1]"});
  utf8::encode($body);
  my $out = $r->restore_bytes($body);
  like $out, qr/\A\{"id":"x","choices":\[\{"index":0,"message":\{"role":"assistant","content":"Hi Max Mustermann",/,
    'content translated back, order kept';
  like $out, qr/"model":"\[PERSON_1\]"\}\z/, 'a field that is no answer text is left';
  my $decoded = $JSON->decode($out);
  is_deeply $CHARS->decode($decoded->{choices}[0]{message}{tool_calls}[0]{function}{arguments}), { who => 'Max Mustermann' },
    'arguments translated back';
  is $r->restore_bytes('{"choices":[{"message":{"content":"nothing"}}]}'), undef, 'nothing to translate: undef';

  my $payload = { choices => [{ message => { content => "a $P1", reasoning_content => '[PERSON_1]' } }] };
  ok $r->restore_payload($payload), 'payload changed';
  is $payload->{choices}[0]{message}{content}, 'a Max Mustermann', 'content';
  is $payload->{choices}[0]{message}{reasoning_content}, 'Max Mustermann', 'reasoning';
};

done_testing;
