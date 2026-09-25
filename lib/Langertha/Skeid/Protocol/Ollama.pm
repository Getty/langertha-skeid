package Langertha::Skeid::Protocol::Ollama;
our $VERSION = '0.003';
# ABSTRACT: Translate between the Ollama chat format and the upstream OpenAI call
use strict;
use warnings;
use Langertha::Skeid::Protocol;
use Langertha::ToolCall;

=head1 DESCRIPTION

Serves C<POST /api/chat>, C<POST /api/generate> and C<GET /api/tags>. Ollama-specific field names — C<done_reason>,
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
C<temperature> and C<max_tokens>; C<tools> and C<tool_choice> pass through unchanged.

A user message's C<images>, raw base64 strings, become an OpenAI content array: the message
text as a C<text> part, then one C<image_url> part per image, each a C<data:> URL whose media
type is read from the image's magic bytes (PNG, JPEG, GIF, WebP; PNG otherwise, see
L<Langertha::Skeid::Protocol/image_media_type>). A message without images keeps its string
content.

=cut

sub request_to_openai {
  my ($class, $body) = @_;
  my $options = ref($body->{options}) eq 'HASH' ? $body->{options} : {};

  return {
    model => ($body->{model} // ''),
    messages => _messages_to_openai($body->{messages}),
    (defined($options->{temperature}) ? (temperature => 0 + $options->{temperature}) : ()),
    (defined($options->{num_predict}) ? (max_tokens  => 0 + $options->{num_predict}) : ()),
    (defined($body->{tools}) ? (tools => $body->{tools}) : ()),
    (defined($body->{tool_choice}) ? (tool_choice => $body->{tool_choice}) : ()),
  };
}

# Assistant tool_calls: arguments object -> character JSON string, ids synthesized; tool
# messages: tool_name -> tool_call_id of the matching call of the preceding assistant turn.
sub _messages_to_openai {
  my ($messages) = @_;
  return [] unless ref($messages) eq 'ARRAY';

  my $next_id = 0;
  my @unanswered;   # [ id, name ] of the latest assistant turn's calls, not yet answered
  my @out;

  for my $msg (@$messages) {
    if (ref($msg) ne 'HASH') {
      push @out, $msg;
      next;
    }
    my $role = $msg->{role} // '';

    if ($role eq 'assistant' && ref($msg->{tool_calls}) eq 'ARRAY') {
      @unanswered = ();
      my @calls;
      for my $call (@{$msg->{tool_calls}}) {
        if (ref($call) ne 'HASH') {
          push @calls, $call;
          next;
        }
        my $function = ref($call->{function}) eq 'HASH' ? $call->{function} : {};
        my $args = $function->{arguments};
        my $id = (defined($call->{id}) && length($call->{id})) ? $call->{id} : 'call_skeid_' . $next_id++;
        push @calls, {
          %$call,
          id       => $id,
          type     => 'function',
          function => {
            %$function,
            arguments => (ref($args) ? Langertha::Skeid::Protocol::encode_json_text_safe($args)
                                     : ($args // '{}')),
          },
        };
        push @unanswered, [ $id, $function->{name} // '' ];
      }
      push @out, { %$msg, tool_calls => \@calls };
      next;
    }

    if ($role eq 'tool') {
      my %tool = %$msg;
      my $tool_name = delete $tool{tool_name};
      if (defined($tool{tool_call_id}) && length($tool{tool_call_id})) {
        @unanswered = grep { $_->[0] ne $tool{tool_call_id} } @unanswered;
      } elsif (@unanswered) {
        my ($pick) = grep { defined($tool_name) && $unanswered[$_][1] eq $tool_name } 0 .. $#unanswered;
        $pick //= 0;
        $tool{tool_call_id} = $unanswered[$pick][0];
        splice @unanswered, $pick, 1;
      }
      push @out, \%tool;
      next;
    }

    if ($role ne 'assistant' && ref($msg->{images}) eq 'ARRAY' && @{$msg->{images}}) {
      my %with_images = %$msg;
      my $images = delete $with_images{images};
      my $text = $with_images{content};
      $with_images{content} = [
        ((defined($text) && !ref($text) && length($text)) ? { type => 'text', text => "$text" } : ()),
        map { _image_part($_) } grep { defined($_) && !ref($_) && length($_) } @$images,
      ];
      push @out, \%with_images;
      next;
    }

    push @out, $msg;
  }

  return \@out;
}

# Ollama sends images as raw base64 without a type; the OpenAI upstream wants a URL. A client
# that already sends a data: URL keeps it.
sub _image_part {
  my ($image) = @_;
  return Langertha::Skeid::Protocol::image_url_part($image) if $image =~ /\Adata:/;
  return Langertha::Skeid::Protocol::image_url_part(undef, $image);
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
    my @calls = Langertha::ToolCall->extract('openai', $res || {});
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

=method generate_request_to_openai

  my $openai_body = Langertha::Skeid::Protocol::Ollama->generate_request_to_openai($body);

Turns an Ollama C</api/generate> request into the same OpenAI chat-completions body
L</request_to_openai> builds for C</api/chat>, by way of a chat conversation: C<system>, when
given, becomes a system message, and C<prompt> with its C<images> becomes one user message --
so the images become C<image_url> parts exactly as a chat message's do. C<model> and
C<options> are read as on C</api/chat>.

Everything else a generate request can carry is not forwarded: C<format>, C<think> and
C<options.seed> (not carried on C</api/chat> either), and the fields that only mean something
to an Ollama server's own prompt handling -- C<suffix>, C<template>, C<raw>, C<context>,
C<keep_alive>.

=cut

sub generate_request_to_openai {
  my ($class, $body) = @_;
  my $prompt = $body->{prompt};
  my @messages;
  push @messages, { role => 'system', content => "$body->{system}" }
    if defined($body->{system}) && !ref($body->{system}) && length($body->{system});
  push @messages, {
    role    => 'user',
    content => ((defined($prompt) && !ref($prompt)) ? "$prompt" : ''),
    (ref($body->{images}) eq 'ARRAY' ? (images => $body->{images}) : ()),
  };

  return $class->request_to_openai({
    (exists $body->{model}   ? (model   => $body->{model})   : ()),
    (exists $body->{options} ? (options => $body->{options}) : ()),
    messages => \@messages,
  });
}

=method generate_response_from_openai

  my $ollama = Langertha::Skeid::Protocol::Ollama->generate_response_from_openai($res);

Turns the upstream OpenAI response into an Ollama generate response: the answer text as
C<response>, C<done> true, C<done_reason> and the token counts under the same names as
L</response_from_openai>. The text is passed as the model wrote it -- generate has no tool
calls, so nothing is lifted out of it. Ollama's C<context> (its token ids for the next call)
and its timing durations are not reported; Skeid has neither.

=cut

sub generate_response_from_openai {
  my ($class, $res) = @_;
  my $choice = (ref($res->{choices}) eq 'ARRAY' ? $res->{choices}[0] : {}) || {};
  my $msg = $choice->{message} || {};
  my $usage = $res->{usage} || {};

  return {
    model       => ($res->{model} // ''),
    created_at  => Langertha::Skeid::Protocol::iso8601_now(),
    response    => ($msg->{content} // ''),
    done        => \1,
    done_reason => ($choice->{finish_reason} // 'stop'),
    prompt_eval_count => 0 + ($usage->{prompt_tokens} // 0),
    eval_count        => 0 + ($usage->{completion_tokens} // 0),
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

=method manifest_endpoint

  my $spec = Langertha::Skeid::Protocol::Ollama->manifest_endpoint;

How this face appears in the provider manifest (skeid #29): C<ollama> at the public root, and
the capability flags L</request_to_openai> actually carries to the upstream -- messages
(a C<system> message included), C<tools>, C<options.temperature>, C<options.num_predict>
(response size), C<stream> and a message's C<images> (C<image_input>). A model is published here only with the capabilities declared
for it that are in this list.

C</api/generate> needs no entry of its own: the C<ollama> dialect names the whole Ollama API at
this root, and the manifest's capabilities describe a chat call, which C</api/chat> is.

Not carried, so never claimed: C<format> (structured output), C<options.seed> and C<think>.
C<tool_choice> is passed through when a client sends one, but the Ollama dialect has no such
field, so no C<tool_choice_*> flag is claimed.

=cut

sub manifest_endpoint {
  return {
    dialect      => 'ollama',
    path         => '',
    capabilities => [qw(
      chat streaming system_prompt
      tools_native tools_hermes
      temperature response_size
      image_input
    )],
  };
}

1;
