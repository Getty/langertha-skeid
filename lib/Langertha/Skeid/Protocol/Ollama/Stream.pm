package Langertha::Skeid::Protocol::Ollama::Stream;
our $VERSION = '0.003';
# ABSTRACT: Rewrites an OpenAI SSE stream as Ollama newline-delimited JSON
use strict;
use warnings;
use Langertha::Skeid::Protocol;
use Langertha::Skeid::Protocol::Ollama;

=head1 DESCRIPTION

The counterpart to L<Langertha::Skeid::Protocol::Anthropic::Stream> for Ollama's C</api/chat>,
and a simpler job: Ollama streams newline-delimited JSON objects rather than SSE events, each
one a whole message with a C<done> flag. There is no prologue and no event framing — just one
line per delta and a final line that says it is over.

  my $stream = Langertha::Skeid::Protocol::Ollama::Stream->new(model => 'qwen3');
  $write->($stream->start);            # empty, by design
  $write->($stream->delta($chunk)) for @chunks;
  $write->($stream->finish);

The trailing line matters more than it looks: an Ollama client reads token counts from it and
treats the stream as unfinished without it.

C</api/generate> streams the same lines with the text under C<response> instead of
C<message>; C<< shape => 'generate' >> selects that, the default C<chat> is C</api/chat>.

  my $stream = Langertha::Skeid::Protocol::Ollama::Stream->new(model => 'qwen3', shape => 'generate');

=cut

sub new {
  my ($class, %args) = @_;
  return bless {
    model         => ($args{model} // ''),
    shape         => (($args{shape} // 'chat') eq 'generate' ? 'generate' : 'chat'),
    started       => 0,
    finished      => 0,
    input_tokens  => 0,
    output_tokens => 0,
    done_reason   => undef,
    text_bytes    => 0,
    errored       => 0,
  }, $class;
}

=method content_type

C<application/x-ndjson>. Not SSE: relaying the upstream's C<text/event-stream> here would tell
an Ollama client to parse something it does not speak.

=cut

sub content_type { 'application/x-ndjson' }

sub _line {
  my ($payload) = @_;
  return Langertha::Skeid::Protocol::encode_json_safe($payload) . "\n";
}

# The text of one line in this stream's shape: a chat message, or generate's bare response.
sub _text_field {
  my ($self, $text) = @_;
  return (response => $text) if $self->{shape} eq 'generate';
  return (message => { role => 'assistant', content => $text });
}

=method start

Nothing. Ollama has no prologue — the first line a client sees is the first delta. Present so
both stream translators answer the same three calls.

=cut

sub start {
  my ($self) = @_;
  $self->{started} = 1;
  return '';
}

=method delta

One decoded OpenAI chunk becomes one Ollama line, or nothing when the chunk carries no text
(an opening role-only chunk, or the final usage-only one). Usage and finish reason are recorded
for the closing line. A chunk carrying an OpenAI error object instead of choices ends the
stream with L</error_event>.

=cut

sub delta {
  my ($self, $chunk) = @_;
  return '' unless ref($chunk) eq 'HASH';
  return '' if $self->{finished};

  # Some servers report a failure inside an open stream as a chunk carrying an OpenAI error
  # object. The HTTP status is already 200, so an Ollama client can only learn of it in-band,
  # as Ollama's own error line -- and nothing after it (skeid #47).
  if (ref($chunk->{error}) eq 'HASH') {
    my $message = $chunk->{error}{message} // 'upstream error';
    return $self->error_event(500, "Upstream error: $message");
  }

  if (my $usage = $chunk->{usage}) {
    $self->{input_tokens}  = 0 + ($usage->{prompt_tokens}     // $usage->{input_tokens}  // $self->{input_tokens});
    $self->{output_tokens} = 0 + ($usage->{completion_tokens} // $usage->{output_tokens} // $self->{output_tokens});
  }

  my $choice = (ref($chunk->{choices}) eq 'ARRAY' ? $chunk->{choices}[0] : undef) || {};
  $self->{done_reason} = $choice->{finish_reason} if defined $choice->{finish_reason};
  $self->{model} = $chunk->{model} if defined($chunk->{model}) && length($chunk->{model});

  my $text = $choice->{delta}{content};
  return '' unless defined($text) && length($text);

  $self->{started} = 1;
  $self->{text_bytes} += Langertha::Skeid::Protocol::utf8_length($text);
  return _line({
    model      => $self->{model},
    created_at => Langertha::Skeid::Protocol::iso8601_now(),
    $self->_text_field($text),
    done       => \0,
  });
}

=method finish

The closing line: C<done> true, the reason, and the token counts an Ollama client reads its
statistics from. Idempotent.

=cut

sub finish {
  my ($self, %args) = @_;
  return '' if $self->{finished};
  $self->{finished} = 1;

  return _line({
    model       => $self->{model},
    created_at  => Langertha::Skeid::Protocol::iso8601_now(),
    $self->_text_field(''),
    done        => \1,
    done_reason => ($args{done_reason} // $self->{done_reason} // 'stop'),
    prompt_eval_count => 0 + ($args{input_tokens}  // $self->{input_tokens}  // 0),
    eval_count        => 0 + ($args{output_tokens} // $self->{output_tokens} // 0),
  });
}

=method error_event

  my $bytes = $stream->error_event(500, 'Upstream error: ...');

Ends the stream with Ollama's error line, C<{"error":"<message>"}> -- how Ollama itself reports a
failure after the stream has opened, and what its clients check every line for. The status is
accepted for the same call shape as L<Langertha::Skeid::Protocol::Anthropic::Stream/error_event>
and is not on the wire: the HTTP status went out with the first line.

The stream is finished afterwards: C<delta> and C<finish> return nothing, so no C<done: true>
line follows and a client cannot mistake a failed stream for a complete one. Returns nothing if
the stream has already finished.

=cut

sub error_event {
  my ($self, $status, $message) = @_;
  return '' if $self->{finished};
  $self->{finished} = 1;
  $self->{errored}  = 1;
  return _line(Langertha::Skeid::Protocol::Ollama->error_body($message));
}

=method errored

True once L</error_event> ended the stream, so the proxy records the request as failed even
though the HTTP status was 200.

=cut

sub errored { $_[0]->{errored} }

=method usage

  my ($input, $output, $content_bytes) = $stream->usage;

What the stream carried, for the usage event. C<content_bytes> counts UTF-8 bytes of the text
this translator wrote and becomes the event's C<content_bytes>, recorded beside the token counts
on every stream -- an observation, never an estimate of tokens.

=cut

sub usage {
  my ($self) = @_;
  return ($self->{input_tokens}, $self->{output_tokens}, $self->{text_bytes});
}

1;
