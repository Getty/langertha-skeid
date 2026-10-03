---
name: skeid-protocols
description: Load when working on the protocols Skeid speaks — OpenAI, Anthropic and Ollama client formats, translation upstream, SSE streaming, tool calls, header and auth forwarding.
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
- A non-chat route of the OpenAI face (audio, rerank) is **relayed** to the node's endpoint of
  the same name, not translated into the chat call (ADR 0021, sections below). That is a second
  path and body shape, not a second proxy function.

## Client edge

| API format | Routes | Streaming |
|---|---|---|
| OpenAI | `POST /v1/chat/completions`, `POST /v1/embeddings`, `GET /v1/models` | yes, SSE relay |
| OpenAI, relayed (ADR 0021) | `POST /v1/audio/transcriptions`, `POST /v1/audio/translations` | yes, SSE relay in the node's own event dialect |
| OpenAI, relayed (ADR 0021) | `POST /v1/rerank`, `POST /rerank` (one route) | no |
| Anthropic | `POST /v1/messages` | yes — OpenAI SSE re-chunked into Anthropic events (`Protocol::Anthropic::Stream`) |
| Ollama | `POST /api/chat`, `POST /api/generate`, `GET /api/tags`, `GET /api/ps` | yes — NDJSON (`Protocol::Ollama::Stream`, `shape => 'generate'` for `/api/generate`) |

`GET /health` is unauthenticated and cheap (also with `client_auth`); `/skeid/*` is the admin surface (skill
`skeid-core`). `GET /.well-known/langertha.json` serves the per-key provider manifest (ADR 0015).

Streams on every face are metered and priced like non-streamed requests (the verbatim upstream
usage frame goes through `metrics.normalize`, skeid #41); images are translated to OpenAI
`image_url` parts on the Anthropic and Ollama faces (skeid #42/#43).

## Translation

`Langertha::Skeid::Protocol::Anthropic`
- request → OpenAI: `system` (string or block array) becomes a leading system message; content
  blocks fold to text, except that `image` blocks (base64 or url source) make an OpenAI content
  array with `image_url` parts in client order — a Files API image is a `400`; `tool_use`
  blocks become `tool_calls` on an assistant message; `tool_result` blocks become their own
  `role => 'tool'` message with `tool_call_id`, their images lifted into one user message after
  the tool messages; `tools` and `tool_choice` go through `Langertha::Tool->from_list` /
  `Langertha::ToolChoice->from_hash` and out via `->to_openai`. A provider built-in tool
  (`web_search_*`, `bash_*`, …) is a `400`, never forwarded.
- response → Anthropic: content becomes a `text` block, tool calls become `tool_use` blocks via
  `Langertha::ToolCall->to_anthropic_block`, `finish_reason` maps `tool_calls → tool_use` (also
  `stop` when tool calls are present), `length → max_tokens`, everything else → `end_turn`,
  usage becomes `input_tokens` / `output_tokens`.

`Langertha::Skeid::Protocol::Ollama`
- request → OpenAI: `options.temperature` / `options.num_predict` lift to `temperature` /
  `max_tokens`; `format` becomes `response_format` (`json_object`, or `json_schema` named
  `ollama_format`); a message's raw base64 `images` become `data:` `image_url` parts typed by
  magic bytes; tool round-trips are translated to OpenAI shape. `/api/generate`
  (`generate_request_to_openai`) turns `system` + `prompt` into one chat conversation.
- response → Ollama: `message.content`, optional `message.tool_calls` via `->to_ollama`,
  `done` as JSON `true` (not `1`, which typed clients reject), `done_reason` from
  `finish_reason`, token counts as `prompt_eval_count` / `eval_count`; `/api/generate` answers
  in generate's shape (`response`, …).
- `/api/tags` synthesises a model list from the node inventory; `/api/ps` is a stub `[]`.

Errors take the client's shape too: `_render_error` reads the stash key `skeid.error_format`
(set by the `/v1/messages` route and the `/api` block) and renders the Anthropic envelope, the
Ollama `{"error": "<string>"}`, or the OpenAI error object. Each face's manifest capability list
lives with its translator (`manifest_endpoint`; OpenAI's in `Langertha::Skeid::Protocol`).

**Tool calls are Langertha's job, not Skeid's.** `Langertha::Tool`, `Langertha::ToolCall`,
`Langertha::ToolChoice` own every format's tool shape, including recovering Hermes-style
`<tool_call>{…}</tool_call>` blocks out of plain text
(`ToolCall->extract_hermes_from_text`). Never hand-roll a parser here — extend Langertha
instead, and pin the new `Langertha` version in `cpanfile`.

## Relayed routes (audio)

A route of the OpenAI face that is not a chat call is **relayed, not translated** (ADR 0021):
`/v1/audio/transcriptions` and `/v1/audio/translations` go to `{node.url}/audio/...` as the
multipart form the client sent, and the node's answer (JSON, `verbose_json`, `text`, `srt`,
`vtt`, SSE) comes back untouched. `Langertha::Skeid::Protocol::Audio` owns that wire — the
form fields, the upstream parts, where an answer reports usage; its names
(`transcript.text.delta`, `usage.type: duration`) appear nowhere else.

- No second proxy function. `_proxy_openai_json_async` / `_proxy_openai_stream` take an optional
  `$relay` hash: `request` (builds the upstream transaction), `units` (usage units off the
  answer), `delta_text` (stream frame text for `content_bytes`). A new relayed route brings a
  `$relay`, never a copy of the relay.
- Skeid reads `model` (exactly once, else `400`; routes and applies the key's policy by it) and
  `stream` (last one decides; on for pydantic's truth set `1 true on yes t y`). It writes
  `model` only when a tier serves another one. Everything else passes as sent — unknown and
  repeated fields, the client's part order and boundary.
- **Two parsers, one form.** The node parses the form again. Whatever a node could read as the
  `model` field must count as one in `form_fields`, or a key routes by one model and is served
  another. Loosen that parser, never tighten it; `name*` is refused.
- The upload is not copied: parts above 256 KiB are file assets, and `upstream_parts` hands the
  same asset to the user agent's `multipart` generator. `$part->asset->slurp` on the file is the
  regression (`t/68` counts it).
- The upload limit is `uploads.max_bytes`, set per request by `_limit_upload` on the request
  content's `body` event — head parsed, body unread. Declared too large, or a caller
  `client_auth` refuses: the limit is set to 1, the parser stops, the route (or the gate)
  answers `413` / `401` without the body. A new upload route has to be known to
  `_limit_upload`, or it runs under the server's 16 MiB.
- `Expect` is dropped from the upstream headers of an upload: a node's `100 Continue` makes
  Mojo::UserAgent start a fresh response object, and the stream relay listens on the old one.
- Usage: tokens through `metrics.normalize` when reported; `audio_seconds` from `usage.seconds`
  (`usage.type` = `duration`) else top-level `duration`, else **absent** — never `0`. Not priced.
- Nothing is injected into the form (`stream_include_usage` is the client's to send).

## Relayed route: rerank

`POST /v1/rerank` and `POST /rerank` are one handler (`_handle_openai_rerank`); the event's
`endpoint` is `/v1/rerank` for both. `Langertha::Skeid::Protocol::Rerank` owns the wire —
`query`, `documents`, `top_n`, `return_documents`, TEI's `texts` / `return_text` / `score`,
`x-compute-tokens`, `meta.tokens` appear nowhere else.

- Before a node is picked, `request_problem` answers `400` for: a body that is no JSON object, a
  `model` that is not a non-empty string, a `query` that is not a string, `documents` that is
  not a non-empty array. No slot, no event. What a document may be is the node's to say.
- **Default: relayed.** The body goes to `{node.url}/rerank` re-encoded with `model` = served
  model and every other field as sent; the answer comes back byte for byte
  (`_render_upstream_response`). vLLM, infinity (`--url-prefix /v1`), Jina, Cohere. Do not
  normalise what they do differently (`document` as `{text}` vs a plain string, vLLM returning
  documents unasked). Re-encoding is deliberate: one `model` reaches the node, the one Skeid
  routed by — never pass the client's bytes through.
- **`rerank_format: tei` on the node: translated on the upstream side** (ADR 0021 Update; the
  only translation that is not at the client edge). `POST <node url without /v1>/rerank` with
  `{query, texts, return_text?, truncate?}`; the bare array becomes
  `{model: served, results: [{index, relevance_score, document: {text}?}], usage: {total_tokens}?}`,
  sorted by score, cut to `top_n` (absent / `null` / `0` = all). It is a node option, never an
  `engine` branch. A new upstream dialect is a row in `Protocol::Rerank`'s `%FORMAT`.
- The dialect is known only after admission. A request a TEI node cannot take (a document that
  is not a string or `{text: string}`, a bad `top_n`) throws a `Protocol::Refusal` from
  `request_to_upstream`; the handler answers through `_refuse_unsendable_request`:
  `request.finish`, one failed event (`400`, `invalid_request_error`), no upstream call.
- `$relay` keys rerank added, both called with `($payload, $res)`: `usage` (returns the usage
  block to meter, or nothing — instead of pricing the body's own `usage`) and `answer` (the
  response translator for a node with a format; a `die` is the `translation_error` path, `500`).
  `units` gets `$res` as its second argument too.
- Usage: `documents` = documents in the request, on the event of a request the node answered
  2xx, absent otherwise; recorded, not priced. Tokens are **input** tokens (`prompt_tokens` =
  total, `completion_tokens` 0) so `input_per_million` prices them, read from
  `usage.prompt_tokens`, else `usage.total_tokens`, else `meta.tokens.input_tokens` (Cohere);
  for `tei` from the `x-compute-tokens` header only. infinity counts characters unless
  `lengths_via_tokenize`. No `search_units`, no streaming, no `/v2/rerank`.
- `t/69-rerank.t`; 26 mutations of the logic were checked to fail it.

## Upstream call

The call is `POST {node.url}/chat/completions` or `/embeddings`; a relayed route posts to its
own path (above); a `rerank_format: tei` node is called at its server root
(`_root_url_for_node`). `_endpoint_url_for_node($base, $path)` — appends `/v1` unless the node url
already ends in `/v1`. A node url is a base, never a full endpoint.

`_forward_headers` passes the client's headers through minus the hop-by-hop set
(`connection`, `keep-alive`, `proxy-authenticate`, `proxy-authorization`, `te`, `trailer`,
`transfer-encoding`, `upgrade`) and `host`, `content-length`, `accept-encoding`.
`_inject_node_auth_async` then overrides `Authorization`:

1. **KeyBroker**, if the node has `api_key_ref` — resolved per request through `key_async`
   (in-memory cache, coalesced misses; never `resolve_key` on the request path).
2. **`api_key_env`** fallback — key from that environment variable.
3. Neither **configured** → the client's own `Authorization` survives (pass-through
   deployments).

When a key is injected, the client's `Authorization` and `x-api-key` are dropped first — in
any spelling (`_drop_client_credentials`; Mojolicious hands `X-Api-Key` on as the client wrote
it, and an exact-case delete forwards it beside the node's key) — so an Anthropic-style client
can never leak its own key upstream. A resolve failure warns — with the reference, never the key or
a vault response body — and falls through to `api_key_env`.

**A configured key source that yields no key fails closed.** Broker error or cached failure, no
broker at all (a failed OpenBao login at boot), variable unset or empty, or a node that left
the inventory after it was selected (its key source is unknown): the callback gets a reason, and both callers answer through `_refuse_unkeyed_node` — no upstream call,
`request.finish` with `ok => 0`, one failed usage event, `503 upstream_key_unavailable` in the
face's error shape. The pass-through is for a node that names *no* key source; taking it for a
node whose key went missing sends the customer's key to the provider. The reason (reference,
variable name) goes to the log and the usage event, not to the client. `t/61-node-key-fail-closed.t`
fails if the pass-through comes back.

## Caller identity

The **Customer key ID** is derived from the key the caller presented (`Authorization` bearer,
else `x-api-key`): `k_` plus its full SHA-1 hex (`Langertha::Skeid->key_id_for_key`, ADR 0016),
or `anonymous`. A legacy 12-hex id in the config still matches by prefix. The raw key is never
stored, logged, or reported — the hash exists precisely so metering works without keeping it.

`x-skeid-key-id` (or `x-api-key-id`) overrides that **only** when
`routing.trust_key_id_header` is set, for deployments that authenticate callers before Skeid
sees them. Do not make it the default and do not add a second way in: the routing policy of
ADR 0008 hangs off this id, so anything a client can set freely turns permissions into a
suggestion. `t/26-key-policies.t` fails if that check goes away.

**Client authentication** (`client_auth:`, ADR 0020) is the only place a key is refused for
*who* it is: with the section, every client route's `under` bridge (`_authorize_client`) reloads
the config, then answers `401` + `WWW-Authenticate` in the face's dialect to an id not on the
list — before body parsing, `request.start`, broker, upstream or usage event. A new client
route goes behind the bridge of its face, or it is an open door. `/health` and `/skeid/*` stay
outside. `t/67-client-auth.t`.

`x-request-id` is honoured if present, otherwise a `req_<ms>_<rand>` id is generated.

## Streaming mechanics

`_proxy_openai_stream` serves every face. The upstream body is read raw
(`Proxy::RelayContent`, so an unchunked `text/event-stream` is not swallowed by Mojolicious's
own SSE parser); `data: {…}` lines are parsed — across read boundaries — for content size and
the verbatim `usage` block, then one usage event is written on completion. Without a
translator the bytes are relayed as they came; with one (`Protocol::*::Stream`) each parsed
chunk goes through `->delta` and the client gets the translator's framing and content type.
Rules:

- Never rewrite a chunk on the OpenAI face. The relay is byte-transparent; anything else breaks
  client parsers and makes TTFT unmeasurable.
- `content-length`, `transfer-encoding` and `content-encoding` are stripped from the relayed
  headers (a translated stream also drops `content-type`); `x-skeid-node` is added.
- Chunks go out through a drain queue, not one `write_chunk` per read — a dynamic response
  with no drain callback ends when its queue empties.
- Headers are sent on the first chunk. On a translated face an upstream error status before
  that is a plain HTTP error in the client's shape; after it the failure travels in-band (an
  Anthropic `error` event, an Ollama error line) and the stream is `ok = 0`, as is a body cut
  short of its own framing. Every path calls `request.finish` exactly once.
- Anthropic and Ollama streams are sent upstream with `stream_options.include_usage`; the
  OpenAI face forwards the client's body as is. Missing usage is expected, not an error: the
  event is written with zeroed tokens.

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
