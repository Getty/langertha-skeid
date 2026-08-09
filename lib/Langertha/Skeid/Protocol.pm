package Langertha::Skeid::Protocol;
our $VERSION = '0.003';
# ABSTRACT: Shared helpers for Skeid wire-format translation
use strict;
use warnings;
use POSIX qw(strftime);
use JSON::MaybeXS qw(encode_json decode_json);

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

JSON-encodes a value, returning C<'{}'> rather than dying on anything unencodable. Used where a
malformed tool argument must not take the whole request down.

=cut

sub encode_json_safe {
  my ($value) = @_;
  return '{}' unless defined $value;
  return eval { encode_json($value) } || '{}';
}

=method decode_json_safe

Decodes a JSON string, returning C<undef> instead of dying. A reference is passed through
unchanged, so it is safe to call on a value that may already be decoded.

=cut

sub decode_json_safe {
  my ($value) = @_;
  return $value if ref($value);
  return undef unless defined $value && length $value;
  my $decoded = eval { decode_json($value) };
  return $@ ? undef : $decoded;
}

1;
