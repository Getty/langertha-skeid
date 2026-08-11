package Langertha::Skeid::Protocol::Ollama::Stream;
our $VERSION = '0.003';
# ABSTRACT: Rewrites an OpenAI SSE stream as Ollama newline-delimited JSON
use strict;
use warnings;
use Langertha::Skeid::Protocol;

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

=cut

sub new {
  my ($class, %args) = @_;
  return bless {
    model         => ($args{model} // ''),
    started       => 0,
    finished      => 0,
    input_tokens  => 0,
    output_tokens => 0,
    done_reason   => undef,
    text_bytes    => 0,
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
for the closing line.

=cut

sub delta {
  my ($self, $chunk) = @_;
  return '' unless ref($chunk) eq 'HASH';

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
  $self->{text_bytes} += length $text;
  return _line({
    model      => $self->{model},
    created_at => Langertha::Skeid::Protocol::iso8601_now(),
    message    => { role => 'assistant', content => $text },
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
    message     => { role => 'assistant', content => '' },
    done        => \1,
    done_reason => ($args{done_reason} // $self->{done_reason} // 'stop'),
    prompt_eval_count => 0 + ($args{input_tokens}  // $self->{input_tokens}  // 0),
    eval_count        => 0 + ($args{output_tokens} // $self->{output_tokens} // 0),
  });
}

=method usage

  my ($input, $output, $content_bytes) = $stream->usage;

What the stream carried, for the usage event.

=cut

sub usage {
  my ($self) = @_;
  return ($self->{input_tokens}, $self->{output_tokens}, $self->{text_bytes});
}

1;
