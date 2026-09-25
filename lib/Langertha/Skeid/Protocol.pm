package Langertha::Skeid::Protocol;
our $VERSION = '0.003';
# ABSTRACT: Shared helpers for Skeid wire-format translation
use strict;
use warnings;
use POSIX qw(strftime);
use JSON::MaybeXS qw(encode_json decode_json);

# Nested JSON (a document carried as a string inside another) must be characters: the body
# around it is byte-encoded once when it is sent (skeid #33, core k252).
my $TEXT_JSON = JSON::MaybeXS->new(utf8 => 0, canonical => 1);

=head1 DESCRIPTION

Skeid speaks several client dialects but makes exactly one kind of upstream call: an
OpenAI-shaped C<POST> to the selected node. Every other API format is translated in on the way
up and out on the way back, by a module under this namespace — one per format.

That is the whole rule, and it is load-bearing: a format-specific field name belongs inside its
own translator and nowhere else. Routing, admission, usage accounting and the upstream request
builder never learn that Anthropic calls it C<system> or that Ollama calls it
C<prompt_eval_count>. See F<docs/adr/0001-one-upstream-call-shape-all-client-formats-translated.md>.

This module itself holds only the handful of helpers the translators share.

=method iso8601_now

Current UTC time as C<YYYY-MM-DDTHH:MM:SSZ>.

=cut

sub iso8601_now {
  return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime());
}

=method encode_json_safe

JSON-encodes a value to UTF-8 B<bytes>, returning C<'{}'> rather than dying on anything
unencodable. For a whole wire unit that goes out as-is -- one SSE event or NDJSON line. Never
for a string nested inside another JSON document: use L</encode_json_text_safe>.

=cut

sub encode_json_safe {
  my ($value) = @_;
  return '{}' unless defined $value;
  return eval { encode_json($value) } || '{}';
}

=method encode_json_text_safe

JSON-encodes a value to a B<character> string, returning C<'{}'> rather than dying. For JSON
nested as a string inside a body that is encoded as a whole later -- C<tool_use.input> becoming
C<function.arguments>, a structured C<tool_result> becoming a tool message's content. Byte
output there would be encoded a second time and every non-ASCII character would reach the
model as mojibake.
Used where a malformed tool argument must not take the whole request down.

=cut

sub encode_json_text_safe {
  my ($value) = @_;
  return '{}' unless defined $value;
  return eval { $TEXT_JSON->encode($value) } || '{}';
}

=method decode_json_safe

Decodes a JSON string of UTF-8 B<bytes> (a raw body or SSE payload), returning C<undef> instead
of dying. Not for text that is already characters, such as C<function.arguments> read from a
decoded body. A reference is passed through unchanged, so it is safe to call on a value that
may already be decoded.

=cut

sub decode_json_safe {
  my ($value) = @_;
  return $value if ref($value);
  return undef unless defined $value && length $value;
  my $decoded = eval { decode_json($value) };
  return $@ ? undef : $decoded;
}

1;
