package Langertha::Skeid::Filter::Restore;
our $VERSION = '0.006';
# ABSTRACT: The answer of a filtered request, its placeholders translated back
use Moo;
use JSON::MaybeXS ();
use List::Util qw(max);
use Langertha::Skeid::Protocol::RawBody;
use namespace::clean;

=head1 SYNOPSIS

  my $restore = Langertha::Skeid::Filter::Restore->new(
    map   => [{ placeholder => '⟦PERSON_1⟧', text => 'Max Mustermann' }],
    usage => $usage,                       # counts filter_restored and pii_unknown into it
  );

  $restore->restore_text('Hello [PERSON 1]');     # 'Hello Max Mustermann'
  $restore->restore_payload($decoded_answer);      # in place, before a face translator
  my $bytes = $restore->restore_bytes($res->body); # the OpenAI face, every other byte kept
  my ($frames) = $restore->frames($sse_frame);     # a stream, held back across chunks
  my @tail = $restore->flush_frames;               # what is still held at the end

=head1 DESCRIPTION

The reverse table of a request a filter replaced texts in (ADR 0035): placeholder to original,
built from the filter's map, held in memory for this one answer and dropped with it. Nothing here
logs: the table is the request's personal data.

A placeholder is found as the filter wrote it, and in its lenient forms when the table knows it:
C<[> or C<⟦> around it, a space for an underscore, spaces inside, either case -- C<⟦PERSON_1⟧>,
C<[PERSON_1]>, C<⟦PERSON 1⟧>, C<[ person_1 ]>. A placeholder-shaped text of a kind the table has
(C<PERSON_…>) that it does not know is left as it is and counted as C<pii_unknown>.

In tool-call arguments, which are JSON, the original is inserted JSON-escaped, so they stay
valid JSON.

A stream has one channel per choice and field (C<content>, C<reasoning_content>, C<reasoning>,
C<refusal>) and per tool call. Each holds back from its last C<[> or C<⟦> for up to 40 characters
until it is closed, so a placeholder cut across chunks is still found.

=cut

=attr map

The filter's map, checked: C<< [{ placeholder, text }] >>.

=attr usage

The hash the counts go into: C<filter_restored>, placeholders translated back, and
C<pii_unknown>. It is the filter's own usage of the request, which the usage event carries.

=cut

has map   => (is => 'ro', required => 1);
has usage => (is => 'ro', default => sub { {} });

# The longest text a held-back channel keeps waiting for a closing bracket.
my $HOLDBACK = 40;

my $OPEN  = "[\x{27E6}";
my $CLOSE = "]\x{27E7}";
my $CANDIDATE = qr/[\[\x{27E6}]([^\[\]\x{27E6}\x{27E7}]{1,38})[\]\x{27E7}]/;

my $CHARS = JSON::MaybeXS->new(allow_nonref => 1);
my $BYTES = JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1);
my $CANONICAL = JSON::MaybeXS->new(utf8 => 1, allow_nonref => 1, canonical => 1);

my @TEXT_FIELDS = qw( content reasoning_content reasoning refusal );

has _table => (is => 'lazy', init_arg => undef);

sub _build__table {
  my ($self) = @_;
  my (%exact, %key, %kind);
  for my $entry (@{$self->map}) {
    my ($placeholder, $text) = @{$entry}{qw( placeholder text )};
    $exact{$placeholder} = $text;
    my $inner = $placeholder;
    $inner =~ s/\A[\Q$OPEN\E]//;
    $inner =~ s/[\Q$CLOSE\E]\z//;
    my $normal = _normalize($inner);
    next unless length $normal;
    $key{$normal} = $text;
    my ($type) = split /_/, $normal;
    $kind{$type} = 1 if $normal =~ /_/;
  }
  my @exact = sort { length($b) <=> length($a) || $a cmp $b } keys %exact;
  my $exact_re = @exact ? join('|', map { quotemeta } @exact) : '(?!)';
  return {
    exact => \%exact,
    key   => \%key,
    kind  => \%kind,
    # Every placeholder opens with a bracket: a text without one has nothing to translate back.
    bracketed => (!grep { !/\A[\Q$OPEN\E]/ } @exact) ? 1 : 0,
    re    => qr/($exact_re)|$CANDIDATE/,
  };
}

sub _normalize {
  my ($inner) = @_;
  $inner =~ s/\A\s+//;
  $inner =~ s/\s+\z//;
  $inner =~ s/[\s_]+/_/g;
  return uc $inner;
}

# The channels of a stream: text held back, by channel key; and the tool calls seen per choice.
has _held  => (is => 'ro', init_arg => undef, default => sub { {} });
has _frame => (is => 'rw', init_arg => undef);

=method restore_text

  my $text = $restore->restore_text($text);
  my $json = $restore->restore_text($arguments, 1);   # originals JSON-escaped

The text with every placeholder the table knows translated back.

=cut

sub restore_text {
  my ($self, $text, $json) = @_;
  return $text unless defined($text) && length($text);
  my $table = $self->_table;
  my $usage = $self->usage;
  $text =~ s{$table->{re}}{
    my ($whole, $exact, $inner) = ($&, $1, $2);
    my $original = defined($exact) ? $table->{exact}{$exact} : $table->{key}{_normalize($inner)};
    if (defined $original) {
      $usage->{filter_restored}++;
      $json ? substr($CHARS->encode($original), 1, -1) : $original;
    } else {
      my $normal = _normalize($inner);
      my ($type, $rest) = split /_/, $normal, 2;
      $usage->{pii_unknown}++
        if defined($rest) && $table->{kind}{$type} && $rest =~ /\A[A-Z0-9]+(?:_[A-Z0-9]+)*\z/;
      $whole;
    }
  }ge;
  return $text;
}

=method feed

  my $out = $restore->feed($channel, $chunk, $json);

The next chunk of a channel, translated back, without what it holds back: from the channel's
last opening bracket, up to 40 characters, until it is closed.

=method flush

  my $out = $restore->flush($channel, $json);

What the channel still holds, translated back; the channel is empty after it.

=cut

sub feed {
  my ($self, $channel, $chunk, $json) = @_;
  # The common chunk: nothing held, no opening bracket -- nothing to hold and nothing to find.
  return $chunk if defined($chunk) && !exists($self->_held->{$channel})
    && index($chunk, '[') < 0 && index($chunk, "\x{27E6}") < 0 && $self->_table->{bracketed};
  my $buffer = (delete($self->_held->{$channel}) // '') . ($chunk // '');
  my $at = max(rindex($buffer, '['), rindex($buffer, "\x{27E6}"));
  if ($at >= 0 && length($buffer) - $at <= $HOLDBACK && substr($buffer, $at) !~ /[\Q$CLOSE\E]/) {
    $self->_held->{$channel} = substr($buffer, $at);
    $buffer = substr($buffer, 0, $at);
  }
  return $self->restore_text($buffer, $json);
}

sub flush {
  my ($self, $channel, $json) = @_;
  my $held = delete $self->_held->{$channel};
  return '' unless defined($held) && length($held);
  return $self->restore_text($held, $json);
}

=method frames

  my ($frames, $changed) = $restore->frames($frame);

One decoded stream frame (a C<chat.completion.chunk>), its texts translated back with their
channels' holdback -- in place. Returns the frames to send in its stead: the frame itself; or,
when it ends a choice while something is still held, a frame with the held text and then the
frame that ends it. C<$changed> is false when the frame is as it came.

=cut

sub frames {
  my ($self, $frame) = @_;
  my $choices = ref($frame) eq 'HASH' ? $frame->{choices} : undef;
  return ([$frame], 0) unless ref($choices) eq 'ARRAY';
  # The shape of a flushed frame: the stream's id, object, created and model, taken once.
  $self->_frame({ map { exists $frame->{$_} ? ($_ => $frame->{$_}) : () } qw( id object created model ) })
    unless $self->_frame;

  my $changed = 0;
  my @ending;
  for my $pos (0 .. $#$choices) {
    my $choice = $choices->[$pos];
    next unless ref($choice) eq 'HASH';
    my $i = $choice->{index} // $pos;
    my $delta = $choice->{delta};
    if (ref($delta) eq 'HASH') {
      for my $field (@TEXT_FIELDS) {
        my $value = $delta->{$field};
        next unless defined($value) && !ref($value);
        my $out = $self->feed("$i/$field", $value);
        next if $out eq $value;
        $delta->{$field} = $out;
        $changed = 1;
      }
      if (ref($delta->{tool_calls}) eq 'ARRAY') {
        my $calls = $delta->{tool_calls};
        for my $k (0 .. $#$calls) {
          my $call = $calls->[$k];
          next unless ref($call) eq 'HASH' && ref($call->{function}) eq 'HASH';
          my $value = $call->{function}{arguments};
          next unless defined($value) && !ref($value);
          my $out = $self->feed("$i/tool/" . ($call->{index} // $k), $value, 1);
          next if $out eq $value;
          $call->{function}{arguments} = $out;
          $changed = 1;
        }
      }
    }
    push @ending, [$pos, $i] if defined $choice->{finish_reason};
  }
  return ([$frame], $changed) unless @ending;

  # A choice ends: what its channels hold goes out first, in a frame of its own, so a
  # translator sees the text before the end of the choice.
  my %tail;
  for my $end (@ending) {
    my $i = $end->[1];
    my $held = $self->_flush_choice($i);
    $tail{$end->[0]} = $held if %$held;
  }
  return ([$frame], $changed) unless %tail;

  my %first = %$frame;
  delete $first{usage};
  $first{choices} = [ map {
    my $pos = $_;
    my %choice = %{$choices->[$pos]};
    $choice{delta} = { %{ ref($choice{delta}) eq 'HASH' ? $choice{delta} : {} } };
    if (my $held = $tail{$pos}) {
      $choice{finish_reason} = undef;
      _append($choice{delta}, $held);
    }
    \%choice;
  } grep { ref($choices->[$_]) eq 'HASH' } 0 .. $#$choices ];

  my %last = %$frame;
  $last{choices} = [ map { +{ %{$choices->[$_]}, delta => {} } } sort { $a <=> $b } keys %tail ];
  return ([\%first, \%last], 1);
}

# The held text of every channel of choice $i, flushed: { field => text, tools => { k => text } }.
sub _flush_choice {
  my ($self, $i) = @_;
  my %held;
  for my $channel (sort grep { m{\A\Q$i\E/} } keys %{$self->_held}) {
    my (undef, $field, $k) = split m{/}, $channel, 3;
    my $json = $field eq 'tool' ? 1 : 0;
    my $text = $self->flush($channel, $json);
    next unless length $text;
    if ($field eq 'tool') { $held{tools}{$k} = $text }
    else                  { $held{$field} = $text }
  }
  return \%held;
}

sub _append {
  my ($delta, $held) = @_;
  for my $field (@TEXT_FIELDS) {
    $delta->{$field} = ($delta->{$field} // '') . $held->{$field} if defined $held->{$field};
  }
  for my $k (sort { $a <=> $b } keys %{$held->{tools} || {}}) {
    my @calls = ref($delta->{tool_calls}) eq 'ARRAY' ? map { +{ %$_ } } @{$delta->{tool_calls}} : ();
    my ($call) = grep { ($_->{index} // -1) == $k } @calls;
    if ($call) {
      $call->{function} = { %{$call->{function} || {}} };
      $call->{function}{arguments} = ($call->{function}{arguments} // '') . $held->{tools}{$k};
    } else {
      push @calls, { index => 0 + $k, function => { arguments => $held->{tools}{$k} } };
    }
    $delta->{tool_calls} = \@calls;
  }
  return;
}

=method flush_frames

  my @frames = $restore->flush_frames;

What every channel still holds, as one frame shaped like the stream's last, or nothing. For the
end of a stream whose choices did not say they ended.

=cut

sub flush_frames {
  my ($self) = @_;
  my %choices;
  for my $channel (keys %{$self->_held}) {
    my ($i) = split m{/}, $channel;
    $choices{$i} = 1;
  }
  my @choices;
  for my $i (sort { $a <=> $b } keys %choices) {
    my $held = $self->_flush_choice($i);
    next unless %$held;
    my $delta = {};
    _append($delta, $held);
    push @choices, { index => 0 + $i, delta => $delta, finish_reason => undef };
  }
  return () unless @choices;
  return { object => 'chat.completion.chunk', %{$self->_frame || {}}, choices => \@choices };
}

=method restore_payload

  my $changed = $restore->restore_payload($answer);

A decoded chat-completions answer, its texts translated back in place: each choice's
C<message> (C<content>, C<reasoning_content>, C<reasoning>, C<refusal>, and C<arguments> of its
tool calls) and C<text>. What the translated faces get before their translator.

=cut

sub restore_payload {
  my ($self, $answer) = @_;
  my $choices = ref($answer) eq 'HASH' ? $answer->{choices} : undef;
  return 0 unless ref($choices) eq 'ARRAY';
  my $changed = 0;
  my $set = sub {
    my ($holder, $key, $json) = @_;
    my $value = $holder->{$key};
    return unless defined($value) && !ref($value);
    my $out = $self->restore_text($value, $json);
    return if $out eq $value;
    $holder->{$key} = $out;
    $changed = 1;
  };
  for my $choice (@$choices) {
    next unless ref($choice) eq 'HASH';
    $set->($choice, 'text');
    my $message = $choice->{message};
    next unless ref($message) eq 'HASH';
    $set->($message, $_) for @TEXT_FIELDS;
    next unless ref($message->{tool_calls}) eq 'ARRAY';
    for my $call (@{$message->{tool_calls}}) {
      $set->($call->{function}, 'arguments', 1)
        if ref($call) eq 'HASH' && ref($call->{function}) eq 'HASH';
    }
  }
  return $changed;
}

=method restore_bytes

  my $bytes = $restore->restore_bytes($body);   # undef: nothing to translate back

A chat-completions answer as bytes, with the same fields as L</restore_payload> translated back
at the offsets of their string tokens and every other byte as the node sent it. An answer the
scanner cannot follow is decoded, translated back and encoded.

=cut

sub restore_bytes {
  my ($self, $body) = @_;
  return undef unless defined($body) && length($body);
  my $scan = Langertha::Skeid::Protocol::RawBody::string_values($body);
  unless ($scan) {
    my $answer = eval { $BYTES->decode($body) };
    return undef unless ref($answer) eq 'HASH' && $self->restore_payload($answer);
    return $CANONICAL->encode($answer);
  }
  my @edits;
  for my $token (@{$scan->{strings}}) {
    my $json = _answer_field($token->{path}) // next;
    my $value = eval { $BYTES->decode(substr($body, $token->{start}, $token->{length})) };
    next unless defined $value;
    my $out = $self->restore_text($value, $json eq 'json' ? 1 : 0);
    push @edits, [$token, $BYTES->encode($out)] unless $out eq $value;
  }
  return undef unless @edits;
  for my $edit (sort { $b->[0]{start} <=> $a->[0]{start} } @edits) {
    substr($body, $edit->[0]{start}, $edit->[0]{length}, $edit->[1]);
  }
  return $body;
}

my %MESSAGE_FIELD = map { $_ => 1 } @TEXT_FIELDS;

# 'text' or 'json' for a path of an answer whose string is translated back, else undef.
sub _answer_field {
  my ($path) = @_;
  my @key = map { $_->[0] ? '#' : $_->[1] } @$path;
  return undef unless @key >= 3 && $key[0] eq 'choices' && $key[1] eq '#';
  return 'text' if @key == 3 && $key[2] eq 'text';
  return undef unless $key[2] eq 'message';
  return 'text' if @key == 4 && $MESSAGE_FIELD{$key[3]};
  return 'json' if @key == 7 && $key[3] eq 'tool_calls' && $key[4] eq '#'
    && $key[5] eq 'function' && $key[6] eq 'arguments';
  return undef;
}

1;
