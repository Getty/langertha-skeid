Read when changing how an Anthropic or Ollama request or response is translated, how errors are shaped per face, or anything about tool calls.

# Translation

`Langertha::Skeid::Protocol::Anthropic`
- request → OpenAI: `system` (string or block array) becomes a leading system message, joined by
  any `role: system` messages before the first turn. A later `role: system` message (Claude Code
  mid-conversation system) is never a system message and never moved into the leading one (prefix
  caching): wrapped in `<system-reminder>` it is appended to the preceding user message, else
  prepended to the next one, else its own user message — never between `tool_calls` and their
  `tool` messages (k100).
- Content blocks fold to text, except `image` blocks (base64 or url source) → OpenAI content array
  with `image_url` parts in client order; a Files API image is a `400`. `tool_use` blocks →
  `tool_calls` on an assistant message; `tool_result` blocks → their own `role => 'tool'` message
  with `tool_call_id`, their images lifted into one user message after the tool messages.
  `tools` / `tool_choice` go through `Langertha::Tool->from_list` /
  `Langertha::ToolChoice->from_hash` and out via `->to_openai`. A provider built-in tool
  (`web_search_*`, `bash_*`, …) is a `400`, never forwarded.
- response → Anthropic: content → `text` block, tool calls → `tool_use` blocks via
  `Langertha::ToolCall->to_anthropic_block`; `finish_reason` `tool_calls → tool_use` (also `stop`
  when tool calls are present), `length → max_tokens`, else `end_turn`; usage → `input_tokens` /
  `output_tokens`.

`Langertha::Skeid::Protocol::Ollama`
- request → OpenAI: `options.temperature` / `options.num_predict` → `temperature` /
  `max_tokens`; `format` → `response_format` (`json_object`, or `json_schema` named
  `ollama_format`); raw base64 `images` → `data:` `image_url` parts typed by magic bytes; tool
  round-trips translated to OpenAI shape. `/api/generate` (`generate_request_to_openai`) turns
  `system` + `prompt` into one chat conversation.
- response → Ollama: `message.content`, optional `message.tool_calls` via `->to_ollama`, `done` as
  JSON `true` (not `1` — typed clients reject it), `done_reason` from `finish_reason`, token
  counts as `prompt_eval_count` / `eval_count`; `/api/generate` answers in generate's shape
  (`response`, …).
- `/api/embed` / `/api/embeddings` (`_handle_ollama_embeddings`, `embed*_request_to_openai`):
  to the node's `/embeddings`, answered as `embeddings` (input order by `index`) +
  `prompt_eval_count`, resp. one `embedding`; not streamed.
- `/api/tags` synthesises a model list from the node inventory; `/api/ps` is a stub `[]`.

## Errors

Errors take the client's shape: `_render_error` reads stash key `skeid.error_format` (set by the
`/v1/messages` route and the `/api` block) and renders the Anthropic envelope, Ollama's
`{"error": "<string>"}`, or the OpenAI error object. Each face's manifest capability list lives
with its translator (`manifest_endpoint`; OpenAI's in `Langertha::Skeid::Protocol`).

## Tool calls

**Tool calls are Langertha's job, not Skeid's.** `Langertha::Tool`, `Langertha::ToolCall`,
`Langertha::ToolChoice` own every format's tool shape, including Hermes-style
`<tool_call>{…}</tool_call>` recovery from plain text (`ToolCall->extract_hermes_from_text`).
Never hand-roll a parser here — extend Langertha and pin the new `Langertha` version in
`cpanfile`.
