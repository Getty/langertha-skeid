# ADR 0001 — One upstream call shape; all client formats are translated

- Status: accepted — error translation extended to the Ollama face (skeid #47, see Update); non-chat routes are relayed, not translated (ADR 0021); one rerank dialect is translated upstream (ADR 0021, Update k92)
- Date: 2026-08-08
- Tags: protocols, translation, routing, backfill

## Context

Skeid accepts requests in three client dialects — OpenAI (`/v1/chat/completions`,
`/v1/embeddings`), Anthropic (`/v1/messages`) and Ollama (`/api/chat`) — and forwards them to
nodes that may be OpenAI, vLLM, SGLang, Groq, Ollama-in-OpenAI-mode or anything else Langertha
knows. The naive shape for that is a matrix: every client format times every upstream engine.
With three client formats and a growing engine list, that matrix is where a proxy goes to die
— every new engine multiplies the number of code paths that can be subtly wrong, and each of
them has to be tested against a real provider to know.

## Decision

There is exactly **one** upstream call: `POST {node.url}/chat/completions` (or `/embeddings`)
with an OpenAI-shaped body. Every non-OpenAI client format is translated into that call on the
way in and back into its own dialect on the way out.

- The **Engine ID** on a node is metadata — it gates eligibility and lands in the usage event.
  It is never a branch in the request builder.
- Format-specific field names (`system`, `tool_use`, `prompt_eval_count`, …) may appear only
  inside that format's translator, which lives in `Langertha::Skeid::Protocol::*`.
- Adding a client format means one request translator, one response translator, one route and
  one `api_format` string. It never means a second upstream code path.
- Tool calls are modelled by `Langertha::Tool` / `ToolCall` / `ToolChoice`, not by Skeid. A
  format Langertha cannot express is a Langertha ticket, not a parser in the proxy.

## Consequences

- Skeid's blast radius per new engine is zero: an engine that speaks the OpenAI dialect works
  by configuration alone.
- The OpenAI dialect is load-bearing. If a provider diverges from it in a way translation
  cannot absorb, that is an architectural event, not a patch — it needs a new ADR.
- Anthropic and Ollama streaming is translated at the client edge from the same OpenAI
  upstream stream, not refused: `stream: true` is rewritten to an OpenAI stream with
  `stream_options.include_usage` and the response is re-emitted as the Anthropic event protocol
  (`message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`,
  `message_delta`, `message_stop`) or as Ollama's newline-delimited JSON. The OpenAI pass-through
  is unchanged; only the formats that need translation are rewritten. See
  `Langertha::Skeid::Protocol::Anthropic::Stream`, `::Ollama::Stream`, and `t/31-stream-translation.t`.
- Response fidelity is bounded by the translation, not by the upstream. Fields no translator
  maps are dropped, deliberately and visibly, rather than leaking a foreign dialect to a client
  that cannot parse it.

## Update (k224, 2026-09-25): errors are translated at the client edge too

Errors follow the same rule as responses: the upstream speaks OpenAI, the client reads its own
dialect. The OpenAI and Ollama faces keep the OpenAI error envelope; the Anthropic face renders
every error — skeid's own (invalid JSON, 403, 429, 503) and the upstream's — as Anthropic's
`{type: "error", error: {type, message}}`, with `error.type` taken from the HTTP status by
`Langertha::Skeid::Protocol::Anthropic->error_type_for_status`. That envelope, like every other
Anthropic field name, lives in the translator; the proxy only picks the face (`_render_error`).

A translated stream fails in one of two places, and each has its own form:

- **Before it opens** — the upstream answers a stream request with a 4xx/5xx. The client gets a
  plain HTTP error with that status, never an event stream with no events in it.
- **After it opens** — the status is already sent, so the failure travels in-band: the
  Anthropic stream ends with an `event: error` frame and no closing sequence (`message_stop`),
  so a client cannot read a failed stream as a complete one. A stream counts as failed on a
  transport error, on an upstream error chunk, and when the body stops short of its own
  framing (chunked terminator, Content-Length) — Mojo::UserAgent reports that last case as
  success once the status line has arrived. A close-delimited body cannot be told apart from a
  complete one.

The in-band frame is presentation and belongs to the face. The failure itself is not: a cut
stream is `ok = 0` on the usage event and on `request.finish` whichever face the client called
(ADR 0004). The OpenAI pass-through and the Ollama stream get no in-band error frame yet.

## Update (skeid #47, #57): the Ollama face translates errors too

The k224 update above left the Ollama face on the OpenAI error envelope and its stream without
an in-band error. Both changed: every error on `/api/*` is rendered as Ollama's
`{"error": "<message>"}` with the failure's HTTP status
(`Langertha::Skeid::Protocol::Ollama->error_body`), and a translated Ollama stream that fails
after it opened ends with an Ollama error line and no `done: true` line. Only the OpenAI
pass-through still has no in-band error frame.

## Update (skeid k91, ADR 0021): non-chat routes of the OpenAI face are relayed

The audio routes (`/v1/audio/transcriptions`, `/v1/audio/translations`) are not the
`/chat/completions` call and are not translated into it: a multipart upload has nothing to be
translated into, and only the OpenAI face has these routes. They go to the node's endpoint of
the same name in their own shape, through the same proxy functions as the chat call (ADR 0021).
The rule here is unchanged for chat: three client formats, one upstream call, no second code
path. The wire names of a relayed route live in its own `Langertha::Skeid::Protocol::*` module,
as a translator's do.

## Update (skeid k92, ADR 0021): rerank is relayed; `rerank_format: tei` translates upstream

`/v1/rerank` is relayed like the audio routes. One kind of node, Hugging Face
text-embeddings-inference, speaks a rerank dialect no client speaks, and a node marked
`rerank_format: tei` is translated on the upstream side. That is not the matrix this ADR rules
out: the chat call still has one upstream shape, `engine` still changes no call, and rerank has
one client dialect. The reasoning and the cost are in ADR 0021's Update.
