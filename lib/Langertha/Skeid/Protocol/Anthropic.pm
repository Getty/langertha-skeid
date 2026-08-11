package Langertha::Skeid::Protocol::Anthropic;
our $VERSION = '0.003';
# ABSTRACT: Translate between the Anthropic Messages format and the upstream OpenAI call
use strict;
use warnings;
use Langertha::Skeid::Protocol;
use Langertha::Tool;
use Langertha::ToolCall;
use Langertha::ToolChoice;

=head1 DESCRIPTION

Serves C<POST /v1/messages>. Anthropic-specific field names live here and nowhere else in
Skeid.

Tool shapes are not translated by hand — L<Langertha::Tool>, L<Langertha::ToolCall> and
L<Langertha::ToolChoice> own what a tool looks like in each dialect, including recovering
Hermes-style C<< <tool_call> >> blocks from plain text. A format Langertha cannot express is a
Langertha ticket, not a parser here.

Streaming is translated, not refused: C<stream: true> is rewritten to an OpenAI stream with
C<stream_options.include_usage> set, so the token counts an Anthropic client reads from
C<message_delta> actually arrive; the response is re-emitted at the client edge as the
Anthropic event protocol — C<message_start>, C<content_block_start>,
C<content_block_delta>, C<content_block_stop>, C<message_delta>, C<message_stop>. The same
single upstream call (ADR 0001) carries the load; the format-specific framing is the only
thing that changes between the wire Skeid speaks and the wire the client reads. See
L<Langertha::Skeid::Protocol::Anthropic::Stream> for the per-chunk rewrite and the usage
accumulator, and F<t/31-stream-translation.t> for what the wire looks like end-to-end.

C<< finish_reason >> mapping is the same as the non-streaming path: C<tool_calls> becomes
C<tool_use>, C<length> becomes C<max_tokens>, anything else becomes C<end_turn>. Tool calls
emitted during a stream are not yet re-emitted as C<tool_use> content blocks — only the
closing C<stop_reason> reports C<tool_use> today; streaming tool calls is a separate ticket
that touches the translator's delta shape.

=method request_to_openai

  my $openai_body = Langertha::Skeid::Protocol::Anthropic->request_to_openai($body);

Turns an Anthropic Messages request into the OpenAI chat-completions body Skeid forwards.

C<system> (a string or a block array) becomes a leading system message. Content block arrays
fold to text; C<tool_use> blocks become C<tool_calls> on the assistant message; C<tool_result>
blocks become their own C<role => 'tool'> message carrying C<tool_call_id>, which is why a
single Anthropic message can expand into several OpenAI ones.

=cut

sub request_to_openai {
  my ($class, $body) = @_;
  my @messages;

  if (defined $body->{system}) {
    if (ref($body->{system}) eq 'ARRAY') {
      my $txt = join('', map { ref($_) eq 'HASH' ? ($_->{text} // '') : "$_" } @{$body->{system}});
      push @messages, { role => 'system', content => $txt } if length $txt;
    } else {
      push @messages, { role => 'system', content => "$body->{system}" };
    }
  }

  for my $m (@{$body->{messages} || []}) {
    next unless ref($m) eq 'HASH';
    my $role = $m->{role} // 'user';
    my $content = $m->{content};

    if (!ref($content)) {
      push @messages, { role => $role, content => (defined($content) ? "$content" : '') };
      next;
    }

    if (ref($content) eq 'ARRAY') {
      my @text;
      my @tool_calls;

      for my $block (@$content) {
        next unless ref($block) eq 'HASH';
        my $type = $block->{type} // '';

        if ($type eq 'text') {
          push @text, ($block->{text} // '');
          next;
        }

        if ($type eq 'tool_use') {
          my $id = $block->{id} // ('toolu_' . int(rand(1_000_000)));
          my $name = $block->{name} // 'tool';
          my $args = Langertha::Skeid::Protocol::encode_json_safe($block->{input} || {});
          push @tool_calls, {
            id => $id,
            type => 'function',
            function => {
              name => $name,
              arguments => $args,
            },
          };
          next;
        }

        if ($type eq 'tool_result') {
          my $tcid = $block->{tool_use_id} // $block->{id} // '';
          my $val = $block->{content};
          my $txt = ref($val) ? Langertha::Skeid::Protocol::encode_json_safe($val) : (defined($val) ? "$val" : '');
          push @messages, {
            role => 'tool',
            tool_call_id => $tcid,
            content => $txt,
          };
          next;
        }
      }

      my $text = join('', @text);
      if ($role eq 'assistant') {
        my %msg = (role => 'assistant');
        $msg{content} = $text if length $text;
        $msg{tool_calls} = \@tool_calls if @tool_calls;
        $msg{content} = '' if !exists($msg{content}) && !exists($msg{tool_calls});
        push @messages, \%msg;
      } elsif (length $text) {
        push @messages, { role => $role, content => $text };
      }
    }
  }

  my %out = (
    model    => ($body->{model} // ''),
    messages => \@messages,
    (defined($body->{max_tokens}) ? (max_tokens => 0 + $body->{max_tokens}) : ()),
    (defined($body->{temperature}) ? (temperature => 0 + $body->{temperature}) : ()),
    (defined($body->{top_p}) ? (top_p => 0 + $body->{top_p}) : ()),
  );

  if (ref($body->{tools}) eq 'ARRAY') {
    my $tools = Langertha::Tool->from_list($body->{tools});
    $out{tools} = [ map { $_->to_openai } @$tools ];
  }

  if (defined $body->{tool_choice}) {
    my $tc = Langertha::ToolChoice->from_hash($body->{tool_choice});
    if ($tc) {
      my $oai_tc = $tc->to_openai;
      $out{tool_choice} = $oai_tc if defined $oai_tc;
    }
  }

  return \%out;
}

=method response_from_openai

  my $anthropic = Langertha::Skeid::Protocol::Anthropic->response_from_openai($res, $model);

Turns the upstream OpenAI response into an Anthropic message. Content becomes a C<text> block,
tool calls become C<tool_use> blocks, and C<finish_reason> maps C<tool_calls> to C<tool_use>,
C<length> to C<max_tokens>, everything else to C<end_turn>.

C<$model> is the model the client asked for, used only when the upstream omits it.

=cut

sub response_from_openai {
  my ($class, $res, $default_model) = @_;

  my $choice = (ref($res->{choices}) eq 'ARRAY' ? $res->{choices}[0] : {}) || {};
  my $msg = $choice->{message} || {};
  my $text = $msg->{content} // '';
  my @calls = Langertha::ToolCall->extract($res || {});

  if (!@calls && length($text)) {
    my ($clean, $extracted) = Langertha::ToolCall->extract_hermes_from_text($text);
    $text = $clean;
    @calls = @$extracted;
  }

  my @content;
  push @content, { type => 'text', text => $text } if length $text;
  my $i = 0;
  for my $call (@calls) {
    $i++;
    push @content, $call->to_anthropic_block( fallback_id => "toolu_skeid_$i" );
  }

  my $fr = $choice->{finish_reason} // 'stop';
  my $stop_reason = $fr eq 'tool_calls' ? 'tool_use'
                  : $fr eq 'length'     ? 'max_tokens'
                  : 'end_turn';

  return {
    id           => ($res->{id} ? ('msg_' . $res->{id}) : ('msg_' . int(time * 1000))),
    type         => 'message',
    role         => 'assistant',
    model        => ($res->{model} // $default_model),
    content      => \@content,
    stop_reason  => $stop_reason,
    stop_sequence => undef,
    usage => {
      input_tokens  => 0 + (($res->{usage} || {})->{prompt_tokens} // 0),
      output_tokens => 0 + (($res->{usage} || {})->{completion_tokens} // 0),
    },
  };
}

1;
