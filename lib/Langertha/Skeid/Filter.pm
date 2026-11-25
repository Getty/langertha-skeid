package Langertha::Skeid::Filter;
our $VERSION = '0.006';
# ABSTRACT: The filter seam: a request's texts, the filter's answer checked, texts put back
use strict;
use warnings;
use B ();
use JSON::MaybeXS ();
use Scalar::Util qw(looks_like_number);
use Langertha::Skeid::Protocol::RawBody;
use Langertha::Skeid::Filter::Restore;

=head1 SYNOPSIS

  my $filter = 'Langertha::Skeid::Filter';
  my $texts  = $filter->extract($openai_body, 'chat');
  # { texts => [{ id => '$.messages[0].content', text => 'Hi, I am Max' }], unfilterable => 0 }

  my ($result, $error) = $filter->check_result($answer, $texts);
  $filter->set_texts($openai_body, $texts, $result->{texts});
  my $bytes = $filter->substitute($client_bytes, $texts, $result->{texts});

=head1 DESCRIPTION

What Skeid does around a deployment's filter (ADR 0035), without knowing what the filter looks
for: it finds the texts of a request, checks what the filter answered, puts the filtered texts
back -- into the decoded body, and into the client's bytes at the offsets of their string
tokens -- and builds the L<Langertha::Skeid::Filter::Restore> that translates the answer back.

A text's C<id> is a JSON path into the request in the OpenAI shape: C<$.messages[0].content>,
C<$.input[2]>, C<$['a key'].x>. Inside a string that carries JSON -- a tool call's C<arguments>
-- the path goes on into that JSON: C<$.messages[1].tool_calls[0].function.arguments.city>.

The proxy calls this only for a request a filter is configured for; nothing here runs on the
default path.

=cut

my $CHARS = JSON::MaybeXS->new(allow_nonref => 1);
my $BYTES = JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1);
my $CANONICAL = JSON::MaybeXS->new(allow_nonref => 1, canonical => 1);

my %DECISION = map { $_ => 1 } qw( pass replace local refuse );

# The fields of a message that carry text, besides its content.
my @MESSAGE_TEXT = qw( name );

=method extract

  my $texts = Langertha::Skeid::Filter->extract($body, $kind);

The texts of a request body in the OpenAI shape (C<$kind> C<chat> or C<embeddings>):
C<< { texts => [{ id, text }], unfilterable => 0|1, by_id => { $id => { path, inner } } } >>.

For chat, C<messages[].content> (a string, or the C<text> of each text part), C<messages[].name>
and every string value inside C<messages[].tool_calls[].function.arguments>; for embeddings,
C<input>. Never a key, a schema, C<tools>, a function name or another field. C<unfilterable> is
true when the request carries what no filter can see -- a content part that is not text,
token ids as input, arguments that are not JSON: such a request must not reach a node the
filter applies to.

=cut

sub extract {
  my ($self, $body, $kind) = @_;
  my $out = { texts => [], unfilterable => 0, by_id => {} };
  return $out unless ref($body) eq 'HASH';
  if (($kind // '') eq 'embeddings') {
    my $input = $body->{input};
    if (_is_string($input)) {
      $self->_add($out, [[0, 'input']], undef, $input);
    } elsif (ref($input) eq 'ARRAY') {
      for my $i (0 .. $#$input) {
        my $value = $input->[$i];
        if (_is_string($value)) {
          $self->_add($out, [[0, 'input'], [1, $i]], undef, $value);
        } else {
          # Token ids (numbers, or lists of them) are no text a filter can read.
          $out->{unfilterable} = 1;
        }
      }
    } elsif (defined $input) {
      $out->{unfilterable} = 1;
    }
    return $out;
  }

  my $messages = $body->{messages};
  return $out unless ref($messages) eq 'ARRAY';
  for my $i (0 .. $#$messages) {
    my $message = $messages->[$i];
    next unless ref($message) eq 'HASH';
    my @at = ([0, 'messages'], [1, $i]);
    my $content = $message->{content};
    if (defined($content) && !ref($content)) {
      $self->_add($out, [@at, [0, 'content']], undef, $content);
    } elsif (ref($content) eq 'ARRAY') {
      for my $j (0 .. $#$content) {
        my $part = $content->[$j];
        if (ref($part) eq 'HASH' && ($part->{type} // '') eq 'text'
            && defined($part->{text}) && !ref($part->{text})) {
          $self->_add($out, [@at, [0, 'content'], [1, $j], [0, 'text']], undef, $part->{text});
        } else {
          $out->{unfilterable} = 1;
        }
      }
    } elsif (defined $content) {
      $out->{unfilterable} = 1;
    }
    for my $field (@MESSAGE_TEXT) {
      my $value = $message->{$field};
      $self->_add($out, [@at, [0, $field]], undef, $value) if defined($value) && !ref($value);
    }
    my $calls = $message->{tool_calls};
    next unless ref($calls) eq 'ARRAY';
    for my $k (0 .. $#$calls) {
      my $call = $calls->[$k];
      next unless ref($call) eq 'HASH' && ref($call->{function}) eq 'HASH';
      my $arguments = $call->{function}{arguments};
      next unless defined($arguments) && !ref($arguments) && length($arguments);
      my @outer = (@at, [0, 'tool_calls'], [1, $k], [0, 'function'], [0, 'arguments']);
      my $scan = Langertha::Skeid::Protocol::RawBody::string_values($arguments, 1);
      unless ($scan) {
        $out->{unfilterable} = 1;
        next;
      }
      for my $token (@{$scan->{strings}}) {
        my $text = eval { $CHARS->decode(substr($arguments, $token->{start}, $token->{length})) };
        next unless defined $text;
        $self->_add($out, \@outer, $token->{path}, $text);
      }
    }
  }
  return $out;
}

# A string as the decoder made it, not a number: a JSON number has no string value yet.
sub _is_string {
  my ($value) = @_;
  return 0 unless defined($value) && !ref($value);
  return (B::svref_2object(\$value)->FLAGS & B::SVp_POK()) ? 1 : 0;
}

sub _add {
  my ($self, $out, $path, $inner, $text) = @_;
  return unless length $text;
  my $id = $self->path_id($path, $inner);
  # A path twice (inner JSON that spells a key twice) is one text: the last one, as decoders read.
  push @{$out->{texts}}, { id => $id, text => "$text" } unless $out->{by_id}{$id};
  $out->{by_id}{$id} = { path => $path, inner => $inner, text => "$text" };
  return;
}

=method path_id

  my $id = Langertha::Skeid::Filter->path_id([[0, 'messages'], [1, 0], [0, 'content']]);
  # '$.messages[0].content'

The id of a path as L<Langertha::Skeid::Protocol::RawBody/string_values> spells it, and of a path
inside the JSON a string at that path carries.

=cut

sub path_id {
  my ($self, $path, $inner) = @_;
  my $id = '$';
  for my $step (@$path, @{$inner || []}) {
    my ($index, $key) = @$step;
    $id .= $index ? "[$key]"
         : $key =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/ ? ".$key"
         : '[' . $CHARS->encode("$key") . ']';
  }
  return $id;
}

=method check_result

  my ($result, $error) = Langertha::Skeid::Filter->check_result($answer, $texts);

The filter's answer checked against the contract (ADR 0035), fail-closed: a decision that is
none of C<pass>, C<replace>, C<local>, C<refuse>, a text whose id the request did not have, a
text or a map entry that is not what the contract says -- each an C<$error> (a few words, never
a text or a placeholder), which the proxy answers as a refusal. C<$result> carries C<decision>,
C<texts> as C<< { $id => $text } >>, C<map>, C<headers> (only C<X-> names, never a credential
header) and C<usage>.

=cut

sub check_result {
  my ($self, $answer, $texts) = @_;
  return (undef, 'the answer is not an object') unless ref($answer) eq 'HASH';
  my $decision = $answer->{decision};
  return (undef, 'unknown decision')
    unless defined($decision) && !ref($decision) && $DECISION{$decision};
  my %result = (decision => $decision, texts => {}, map => [], headers => {}, usage => {});

  if (defined $answer->{headers}) {
    return (undef, 'headers is not an object') unless ref($answer->{headers}) eq 'HASH';
    for my $name (sort keys %{$answer->{headers}}) {
      my $value = $answer->{headers}{$name};
      next unless defined($value) && !ref($value) && $value !~ /[\r\n]/;
      next unless $name =~ /\Ax-[A-Za-z0-9-]{1,64}\z/i && lc($name) ne 'x-api-key';
      $result{headers}{$name} = "$value";
    }
  }
  if (defined $answer->{usage}) {
    return (undef, 'usage is not an object') unless ref($answer->{usage}) eq 'HASH';
    $result{usage} = $self->usage_fields($answer->{usage});
  }
  return (\%result) unless $decision eq 'replace';

  my $by_id = ref($texts) eq 'HASH' ? ($texts->{by_id} || {}) : {};
  my $list = $answer->{texts} // [];
  return (undef, 'texts is not a list') unless ref($list) eq 'ARRAY';
  for my $entry (@$list) {
    return (undef, 'a text is not an object') unless ref($entry) eq 'HASH';
    my ($id, $text) = @{$entry}{qw( id text )};
    return (undef, 'a text has no known id')
      unless defined($id) && !ref($id) && $by_id->{$id};
    return (undef, 'a text is not a string') unless defined($text) && !ref($text);
    $result{texts}{$id} = "$text";
  }

  my $map = $answer->{map} // [];
  return (undef, 'map is not a list') unless ref($map) eq 'ARRAY';
  for my $entry (@$map) {
    return (undef, 'a map entry is not an object') unless ref($entry) eq 'HASH';
    my $placeholder = $entry->{placeholder};
    return (undef, 'a map entry has no placeholder')
      unless defined($placeholder) && !ref($placeholder) && length($placeholder);
    my $original;
    # The span of the original text when the entry names it; else the text it carries.
    if (defined($entry->{id}) && !ref($entry->{id}) && $by_id->{$entry->{id}}
        && _offset($entry->{start}) && _offset($entry->{end})) {
      my $from = $by_id->{$entry->{id}}{text};
      my ($start, $end) = ($entry->{start}, $entry->{end});
      $original = substr($from, $start, $end - $start)
        if $start <= $end && $end <= length($from);
    }
    $original //= $entry->{text} if defined($entry->{text}) && !ref($entry->{text});
    return (undef, 'a map entry has no original text') unless defined($original) && length($original);
    push @{$result{map}}, { placeholder => "$placeholder", text => "$original" };
  }
  return (\%result);
}

sub _offset { my ($n) = @_; return defined($n) && !ref($n) && $n =~ /\A[0-9]+\z/ ? 1 : 0 }

=method usage_fields

  my $fields = Langertha::Skeid::Filter->usage_fields($usage);

The fields of a filter's C<usage> a usage event may carry: keys C<pii_*> and C<filter_*>, each a
number, a short token string (C<A-Z a-z 0-9 _ . : ->, at most 64 characters), or a flat hash of
numbers under such keys. Everything else is dropped, so no field can carry a text or a
placeholder into the usage store. L<Langertha::Skeid/record_usage> applies the same rule.

=cut

sub usage_fields {
  my ($self, $usage) = @_;
  return {} unless ref($usage) eq 'HASH';
  my %fields;
  for my $key (keys %$usage) {
    next unless $key =~ /\A(?:pii|filter)_[A-Za-z0-9_]{1,60}\z/;
    my $value = $usage->{$key};
    if (ref($value) eq 'HASH') {
      my %flat;
      for my $name (keys %$value) {
        next unless $name =~ /\A[A-Za-z0-9_.-]{1,64}\z/;
        my $n = $value->{$name};
        $flat{$name} = 0 + $n if defined($n) && !ref($n) && looks_like_number($n);
      }
      $fields{$key} = \%flat if %flat && keys(%flat) <= 64;
    } elsif (defined($value) && !ref($value)) {
      $fields{$key} = looks_like_number($value) ? 0 + $value : "$value"
        if looks_like_number($value) || $value =~ /\A[A-Za-z0-9_.:-]{0,64}\z/;
    }
  }
  return \%fields;
}

=method set_texts

  Langertha::Skeid::Filter->set_texts($body, $texts, { $id => $text });

Sets each filtered text in the decoded body, at its path; inside tool-call arguments the inner
JSON is decoded, set and encoded again. What the proxy encodes when the client's bytes cannot be
used, and what the translated faces encode anyway.

=cut

sub set_texts {
  my ($self, $body, $texts, $replace) = @_;
  my %inner;
  for my $id (keys %$replace) {
    my $at = $texts->{by_id}{$id} or next;
    if ($at->{inner}) {
      push @{$inner{$self->path_id($at->{path})}}, [$at, $replace->{$id}];
      next;
    }
    _set_at($body, $at->{path}, $replace->{$id});
  }
  for my $list (values %inner) {
    my $path = $list->[0][0]{path};
    my $holder = _get_at($body, $path);
    my $decoded = defined($holder) ? eval { $CHARS->decode($holder) } : undef;
    next unless defined $decoded;
    _set_at(\$decoded, $_->[0]{inner}, $_->[1]) for @$list;
    _set_at($body, $path, $CANONICAL->encode($decoded));
  }
  return $body;
}

sub _get_at {
  my ($node, $path) = @_;
  for my $step (@$path) {
    my ($index, $key) = @$step;
    $node = $index ? (ref($node) eq 'ARRAY' ? $node->[$key] : undef)
                   : (ref($node) eq 'HASH' ? $node->{$key} : undef);
    return undef unless defined $node;
  }
  return $node;
}

# Sets the value at $path below $root -- a hash or array, or a reference to a scalar holding one.
sub _set_at {
  my ($root, $path, $value) = @_;
  my $node = ref($root) eq 'SCALAR' || ref($root) eq 'REF' ? $$root : $root;
  my @steps = @$path;
  my $last = pop @steps;
  for my $step (@steps) {
    my ($index, $key) = @$step;
    $node = $index ? (ref($node) eq 'ARRAY' ? $node->[$key] : undef)
                   : (ref($node) eq 'HASH' ? $node->{$key} : undef);
    return unless ref $node;
  }
  my ($index, $key) = @$last;
  if ($index) { $node->[$key] = $value if ref($node) eq 'ARRAY' }
  else        { $node->{$key} = $value if ref($node) eq 'HASH' }
  return;
}

=method substitute

  my $bytes = Langertha::Skeid::Filter->substitute($bytes, $texts, { $id => $text });

The client's bytes with each filtered text put at the offsets of its string token, and nothing
else changed: key order, whitespace and every other escape stay as the client spelled them (ADR
0035). Inside tool-call arguments the inner JSON is substituted the same way and the string
encoded again. Returns C<undef> when the bytes cannot be used -- the scanner cannot follow them,
an object spells a key twice, or a text is not where its id says -- and the caller then encodes
the decoded body with the texts set.

=cut

sub substitute {
  my ($self, $bytes, $texts, $replace) = @_;
  return undef unless defined $bytes;
  my $scan = Langertha::Skeid::Protocol::RawBody::string_values($bytes) or return undef;
  return undef if $scan->{duplicate};

  my (%plain, %inner);
  for my $id (keys %$replace) {
    my $at = $texts->{by_id}{$id} or return undef;
    if ($at->{inner}) { $inner{$self->path_id($at->{path})}{$self->path_id([], $at->{inner})} = $replace->{$id} }
    else              { $plain{$id} = $replace->{$id} }
  }

  my (@edits, %found);
  for my $token (@{$scan->{strings}}) {
    my $id = $self->path_id($token->{path});
    if (exists $plain{$id}) {
      push @edits, [$token, $BYTES->encode($plain{$id})];
      $found{$id} = 1;
    } elsif (my $set = $inner{$id}) {
      my $text = eval { $BYTES->decode(substr($bytes, $token->{start}, $token->{length})) };
      return undef unless defined $text;
      my $replaced = $self->_substitute_chars($text, $set) // return undef;
      push @edits, [$token, $BYTES->encode($replaced)];
      $found{$id} = 1;
    }
  }
  return undef if grep { !$found{$_} } keys(%plain), keys(%inner);
  # Back to front, so the offsets of the earlier tokens stay valid.
  for my $edit (sort { $b->[0]{start} <=> $a->[0]{start} } @edits) {
    substr($bytes, $edit->[0]{start}, $edit->[0]{length}, $edit->[1]);
  }
  return $bytes;
}

# The JSON in a decoded string, with the texts of %$set (inner id => text) at their tokens.
sub _substitute_chars {
  my ($self, $text, $set) = @_;
  my $scan = Langertha::Skeid::Protocol::RawBody::string_values($text, 1) or return undef;
  return undef if $scan->{duplicate};
  my (@edits, %found);
  for my $token (@{$scan->{strings}}) {
    my $id = $self->path_id($token->{path});
    next unless exists $set->{$id};
    push @edits, [$token, $CHARS->encode($set->{$id})];
    $found{$id} = 1;
  }
  return undef if grep { !$found{$_} } keys %$set;
  for my $edit (sort { $b->[0]{start} <=> $a->[0]{start} } @edits) {
    substr($text, $edit->[0]{start}, $edit->[0]{length}, $edit->[1]);
  }
  return $text;
}

=method restore

  my $restore = Langertha::Skeid::Filter->restore($result->{map}, $usage);

The L<Langertha::Skeid::Filter::Restore> of a replaced request: the reverse table of its map,
counting into C<$usage>. C<undef> for an empty map: there is nothing to translate back.

=cut

sub restore {
  my ($self, $map, $usage) = @_;
  return undef unless ref($map) eq 'ARRAY' && @$map;
  return Langertha::Skeid::Filter::Restore->new(map => $map, usage => ($usage || {}));
}

1;
