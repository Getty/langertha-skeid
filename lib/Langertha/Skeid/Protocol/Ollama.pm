package Langertha::Skeid::Protocol::Ollama;
our $VERSION = '0.003';
# ABSTRACT: Translate between the Ollama chat format and the upstream OpenAI call
use strict;
use warnings;
use Langertha::Skeid::Protocol;
use Langertha::ToolCall;

=head1 DESCRIPTION

Serves C<POST /api/chat> and C<GET /api/tags>. Ollama-specific field names — C<done_reason>,
C<prompt_eval_count>, C<eval_count> — live here and nowhere else in Skeid.

Ollama's messages are already OpenAI-shaped, so the request translation is small — but it is
not empty: generation settings arrive nested under C<options> with Ollama's own names.

Streaming is translated, not refused. C<stream: true> on this route — and an absent
C<stream> field, which Ollama defaults to true — is rewritten to an OpenAI stream with
C<stream_options.include_usage>; the response is re-emitted as Ollama's newline-delimited
JSON, one line per delta and a closing line that carries C<done>, C<done_reason>, and the
token counts an Ollama client reads from. C<done_reason> is the OpenAI C<finish_reason>
passed through verbatim — there is no translation to do. See
L<Langertha::Skeid::Protocol::Ollama::Stream> for the per-chunk rewrite and
F<t/31-stream-translation.t> for what the wire looks like end-to-end.

=method request_to_openai

  my $openai_body = Langertha::Skeid::Protocol::Ollama->request_to_openai($body);

Turns an Ollama chat request into the OpenAI chat-completions body Skeid forwards.
C<options.temperature> and C<options.num_predict> are lifted out of the nested hash to
C<temperature> and C<max_tokens>; C<messages>, C<tools> and C<tool_choice> pass through
unchanged.

=cut

sub request_to_openai {
  my ($class, $body) = @_;
  my $options = ref($body->{options}) eq 'HASH' ? $body->{options} : {};

  return {
    model => ($body->{model} // ''),
    messages => ($body->{messages} || []),
    (defined($options->{temperature}) ? (temperature => 0 + $options->{temperature}) : ()),
    (defined($options->{num_predict}) ? (max_tokens  => 0 + $options->{num_predict}) : ()),
    (defined($body->{tools}) ? (tools => $body->{tools}) : ()),
    (defined($body->{tool_choice}) ? (tool_choice => $body->{tool_choice}) : ()),
  };
}

=method response_from_openai

  my $ollama = Langertha::Skeid::Protocol::Ollama->response_from_openai($res);

Turns the upstream OpenAI response into an Ollama chat response. Tool calls come from
L<Langertha::ToolCall>, including Hermes-style calls recovered from plain text — when they are
recovered, the text they were embedded in is stripped from the message content.

Token counts are reported under Ollama's names; C<done> is always true because this path never
streams.

=cut

sub response_from_openai {
  my ($class, $res) = @_;
  my $choice = (ref($res->{choices}) eq 'ARRAY' ? $res->{choices}[0] : {}) || {};
  my $msg = $choice->{message} || {};
  my $text = ($msg->{content} // '');
  my $tool_calls = [];

  if (ref($msg->{tool_calls}) eq 'ARRAY') {
    my @calls = Langertha::ToolCall->extract($res || {});
    $tool_calls = [ map { $_->to_ollama } @calls ];
  } elsif (length($text)) {
    my ($clean, $calls) = Langertha::ToolCall->extract_hermes_from_text($text);
    if (@$calls) {
      $text = $clean;
      $tool_calls = [ map { $_->to_ollama } @$calls ];
    }
  }

  return {
    model      => ($res->{model} // ''),
    created_at => Langertha::Skeid::Protocol::iso8601_now(),
    message    => {
      role    => ($msg->{role} // 'assistant'),
      content => $text,
      (@$tool_calls ? (tool_calls => $tool_calls) : ()),
    },
    done       => 1,
    done_reason => ($choice->{finish_reason} // 'stop'),
    prompt_eval_count => 0 + (($res->{usage} || {})->{prompt_tokens} // 0),
    eval_count        => 0 + (($res->{usage} || {})->{completion_tokens} // 0),
  };
}

=method tags_from_nodes

  my $tags = Langertha::Skeid::Protocol::Ollama->tags_from_nodes($skeid->list_nodes);

Renders the node inventory as an Ollama C<< /api/tags >> model list. The fields Ollama clients
expect but Skeid cannot know — size, digest, parameter size, quantisation — are filled with
empty or C<'unknown'> placeholders rather than invented, so a client that displays them shows
nothing instead of showing a lie.

=cut

sub tags_from_nodes {
  my ($class, $nodes) = @_;
  my @models = map {
    +{
      name       => ($_->{model} // $_->{id}),
      model      => ($_->{model} // $_->{id}),
      modified_at => Langertha::Skeid::Protocol::iso8601_now(),
      size       => 0,
      digest     => '',
      details    => {
        family             => ($_->{engine} || 'openaibase'),
        parameter_size     => 'unknown',
        quantization_level => 'unknown',
      },
    }
  } @{$nodes || []};

  return { models => \@models };
}

1;
