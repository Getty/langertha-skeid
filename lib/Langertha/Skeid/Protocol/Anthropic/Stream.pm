package Langertha::Skeid::Protocol::Anthropic::Stream;
our $VERSION = '0.003';
# ABSTRACT: Rewrites an OpenAI SSE stream as Anthropic streaming events
use strict;
use warnings;
use Langertha::Skeid::Protocol;

=head1 DESCRIPTION

Skeid makes one shape of upstream call and translates at the client edge (ADR 0001). For a
non-streaming response that is one function; for a stream it needs state, because Anthropic's
format is an event protocol rather than a sequence of deltas: a client is told a message began,
that a content block opened, then the text, then that both closed — and the token counts arrive
in the closing events.

An OpenAI stream says none of that. It sends deltas and stops. Everything else here is
synthesised at the right moment from what the OpenAI stream does say.

  my $stream = Langertha::Skeid::Protocol::Anthropic::Stream->new(model => 'claude-x');
  $write->($stream->start);
  $write->($stream->delta($openai_chunk)) for @chunks;
  $write->($stream->finish);

Every method returns bytes to write, possibly empty. C<start> and C<finish> are idempotent, so
a stream that fails mid-flight can still be closed correctly.

=cut

sub new {
  my ($class, %args) = @_;
  return bless {
    model      => ($args{model} // ''),
    message_id => ($args{message_id} // ('msg_' . int(time * 1000))),
    started       => 0,
    block_open    => 0,
    finished      => 0,
    output_tokens => 0,
    input_tokens  => 0,
    stop_reason   => undef,
    text_bytes    => 0,
  }, $class;
}

=method content_type

The C<Content-Type> the client edge must send. Anthropic streams are SSE, same as OpenAI, but
the events inside are not interchangeable — which is exactly why this class exists.

=cut

sub content_type { 'text/event-stream' }

sub _event {
  my ($name, $payload) = @_;
  return "event: $name\ndata: " . Langertha::Skeid::Protocol::encode_json_safe($payload) . "\n\n";
}

=method start

Opens the message and its first content block. Emitted once, on the first chunk rather than
before it, so an upstream that fails immediately produces an error rather than a half-open
message the client has to time out.

=cut

sub start {
  my ($self) = @_;
  return '' if $self->{started};
  $self->{started} = 1;

  my $out = _event('message_start', {
    type    => 'message',
    message => {
      id            => $self->{message_id},
      type          => 'message',
      role          => 'assistant',
      model         => $self->{model},
      content       => [],
      stop_reason   => undef,
      stop_sequence => undef,
      usage         => { input_tokens => 0, output_tokens => 0 },
    },
  });

  $self->{block_open} = 1;
  $out .= _event('content_block_start', {
    type          => 'content_block',
    index         => 0,
    content_block => { type => 'text', text => '' },
  });
  return $out;
}

=method delta

  my $bytes = $stream->delta($openai_chunk);

Turns one decoded OpenAI chunk into whatever Anthropic events it implies — usually one
C<content_block_delta>, sometimes nothing (a role-only opening chunk, a keepalive), and along
the way it records the usage and finish reason that the closing events need.

=cut

sub delta {
  my ($self, $chunk) = @_;
  return '' unless ref($chunk) eq 'HASH';

  my $out = '';

  # Usage can arrive on any chunk and usually arrives on the last one, which is also the chunk
  # that has no content. Recorded whenever seen, reported at the end.
  if (my $usage = $chunk->{usage}) {
    $self->{input_tokens}  = 0 + ($usage->{prompt_tokens}     // $usage->{input_tokens}  // $self->{input_tokens});
    $self->{output_tokens} = 0 + ($usage->{completion_tokens} // $usage->{output_tokens} // $self->{output_tokens});
  }

  my $choice = (ref($chunk->{choices}) eq 'ARRAY' ? $chunk->{choices}[0] : undef) || {};
  if (defined(my $reason = $choice->{finish_reason})) {
    $self->{stop_reason} = $reason eq 'tool_calls' ? 'tool_use'
                         : $reason eq 'length'     ? 'max_tokens'
                         :                           'end_turn';
  }

  my $text = $choice->{delta}{content};
  if (defined($text) && length($text)) {
    $out .= $self->start unless $self->{started};
    $self->{text_bytes} += length $text;
    $out .= _event('content_block_delta', {
      type  => 'content_block_delta',
      index => 0,
      delta => { type => 'text_delta', text => $text },
    });
  }

  return $out;
}

=method finish

Closes the content block and the message. Carries the output token count, because an Anthropic
client reads usage from C<message_delta> and would otherwise be told nothing was generated.

Idempotent, and it opens the message first if nothing ever did: a stream that produced no text
at all still has to be a well-formed Anthropic message, or the client waits for an end that
never comes.

=cut

sub finish {
  my ($self, %args) = @_;
  return '' if $self->{finished};

  my $out = '';
  $out .= $self->start unless $self->{started};
  $self->{finished} = 1;

  if ($self->{block_open}) {
    $self->{block_open} = 0;
    $out .= _event('content_block_stop', { type => 'content_block_stop', index => 0 });
  }

  $out .= _event('message_delta', {
    type  => 'message_delta',
    delta => {
      stop_reason   => ($args{stop_reason} // $self->{stop_reason} // 'end_turn'),
      stop_sequence => undef,
    },
    usage => { output_tokens => 0 + ($args{output_tokens} // $self->{output_tokens} // 0) },
  });

  $out .= _event('message_stop', { type => 'message_stop' });
  return $out;
}

=method usage

  my ($input, $output, $content_bytes) = $stream->usage;

What the stream carried, for the usage event. C<content_bytes> is the fallback when an upstream
never reports token counts.

=cut

sub usage {
  my ($self) = @_;
  return ($self->{input_tokens}, $self->{output_tokens}, $self->{text_bytes});
}

1;
