---
name: skeid-protocols
description: "Wire protocols Skeid speaks — OpenAI/Anthropic/Ollama client formats, translation to the upstream OpenAI call, SSE streaming, tool calls via Langertha::Tool/ToolCall, header and auth forwarding, Langertha engine ids."
user-invocable: false
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

Everything about the wire. Terms (**API format**, **Engine ID**, **Translation**, **Upstream**,
**SSE relay**) are defined in `CONTEXT.md`.

## The one-hub rule

Skeid speaks three **API formats** to clients but makes exactly one kind of upstream call:
OpenAI `POST {node.url}/chat/completions` (or `/embeddings`). Every other format is translated
in and out. Consequences that are not negotiable:

- A format-specific field name (`system`, `tool_use`, `prompt_eval_count`, …) may appear only
  inside that format's translation functions. Never in routing, usage, or the upstream call.
- Adding an **API format** means: one request translator, one response translator, one route,
  one `api_format` string in the usage meta. It does not mean a second upstream code path.
- The upstream call is engine-agnostic. vLLM, SGLang, Ollama-in-OpenAI-mode and OpenAI itself
  all take the same body; the **Engine ID** is metadata for accounting and eligibility, not a
  branch in the request builder.

## Client edge

| API format | Routes | Streaming |
|---|---|---|
| OpenAI | `POST /v1/chat/completions`, `POST /v1/embeddings`, `GET /v1/models` | yes, SSE relay |
| Anthropic | `POST /v1/messages` | **no** — `stream: true` → `501` |
| Ollama | `POST /api/chat`, `GET /api/tags`, `GET /api/ps` | **no** — `stream: true` → `501` |

`GET /health` is unauthenticated and cheap; `/skeid/*` is the admin surface (skill
`skeid-core`).

Streaming for the translated formats is unimplemented on purpose, not by omission: SSE deltas
would have to be re-chunked into Anthropic events / Ollama NDJSON, and the usage accumulator
would have to survive that. Do not half-add it — that is an ADR-sized decision.

## Translation

`Langertha::Skeid::Protocol::Anthropic`
- request → OpenAI: `system` (string or block array) becomes a leading system message; content
  blocks fold to text; `tool_use` blocks become `tool_calls` on an assistant message;
  `tool_result` blocks become their own `role => 'tool'` message with `tool_call_id`; `tools`
  and `tool_choice` go through `Langertha::Tool->from_list` / `Langertha::ToolChoice->from_hash`
  and out via `->to_openai`.
- response → Anthropic: content becomes a `text` block, tool calls become `tool_use` blocks via
  `Langertha::ToolCall->to_anthropic_block`, `finish_reason` maps
  `tool_calls → tool_use`, `length → max_tokens`, everything else → `end_turn`, usage becomes
  `input_tokens` / `output_tokens`.

`Langertha::Skeid::Protocol::Ollama`
- response → Ollama: `message.content`, optional `message.tool_calls` via `->to_ollama`,
  `done: 1`, `done_reason` from `finish_reason`, token counts as `prompt_eval_count` /
  `eval_count`.
- `/api/tags` synthesises a model list from the node inventory; `/api/ps` is a stub `[]`.

**Tool calls are Langertha's job, not Skeid's.** `Langertha::Tool`, `Langertha::ToolCall`,
`Langertha::ToolChoice` own every format's tool shape, including recovering Hermes-style
`<tool_call>{…}</tool_call>` blocks out of plain text
(`ToolCall->extract_hermes_from_text`). Never hand-roll a parser here — extend Langertha
instead, and pin the new `Langertha` version in `cpanfile`.

## Upstream call

`_endpoint_url_for_node($base, $path)` — appends `/v1` unless the node url already ends in
`/v1`. A node url is a base, never a full endpoint.

`_forward_headers` passes the client's headers through minus `host`, `content-length`,
`transfer-encoding`, `accept-encoding`. `_inject_node_auth` then overrides `Authorization`:

1. **KeyBroker**, if the node has `api_key_ref` — resolved per request, in memory
   (`refresh` first when `needs_refresh`).
2. **`api_key_env`** fallback — key from that environment variable.
3. Neither → the client's own `Authorization` survives (pass-through deployments).

When a key is injected, the client's `x-api-key` is dropped so an Anthropic-style client can
never leak its own key upstream. A resolve failure warns and falls through — it must never put
the reference or the key into the message.

## Caller identity

The **Customer key ID** is derived from the key the caller presented: `k_<12 hex>` from a SHA-1
of it (`Langertha::Skeid->key_id_for_key`), or `anonymous`. The raw key is never stored,
logged, or reported — the hash exists precisely so metering works without keeping it.

`x-skeid-key-id` (or `x-api-key-id`) overrides that **only** when
`routing.trust_key_id_header` is set, for deployments that authenticate callers before Skeid
sees them. Do not make it the default and do not add a second way in: the routing policy of
ADR 0008 hangs off this id, so anything a client can set freely turns permissions into a
suggestion. `t/26-key-policies.t` fails if that check goes away.

`x-request-id` is honoured if present, otherwise a `req_<ms>_<rand>` id is generated.

## Streaming mechanics (OpenAI only)

`_proxy_openai_stream` writes upstream bytes straight through. It parses `data: {…}` lines
only to accumulate `choices[0].delta.content` size and any `usage` object, then writes one
usage event on completion. Rules:

- Never rewrite a chunk. The relay is byte-transparent; anything else breaks client parsers
  and makes TTFT unmeasurable.
- `content-length`, `transfer-encoding` and `content-encoding` are stripped from the relayed
  headers; `x-skeid-node` is added.
- Headers are sent on the first chunk. After that an upstream error can no longer become a
  JSON error body — it can only truncate the stream. Both paths must still call
  `request.finish` exactly once.
- Many upstreams only emit `usage` when asked (`stream_options.include_usage`). Missing usage
  is expected, not an error: the event is written with zeroed tokens.

## Engine IDs

`supported_engine_ids` is discovered from the installed `Langertha` distribution, with a
compiled-in fallback list. `normalize_engine_id` lowercases and strips separators, so
`OpenAI-Base` and `openaibase` are the same id. An unknown engine id on a node is not fatal —
it only ever gates eligibility and lands in the usage event.

## Testing protocols

`Test::Mojo` against `Langertha::Skeid::Proxy->build_app(skeid => $skeid)` with a fake upstream
mounted in the same app (a second Mojolicious route the node url points at). Assert on the
translated *shape*, not on a golden JSON blob: a test that pins every field of an upstream
response fails on the next harmless field addition and tells you nothing about the contract.
