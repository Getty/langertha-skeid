---
name: skeid-protocols
description: Load when working on the protocols Skeid speaks — OpenAI, Anthropic and Ollama client formats, translation upstream, SSE streaming, tool calls, header and auth forwarding.
user-invocable: false
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

Everything about the wire. Terms (**API format**, **Engine ID**, **Translation**, **Upstream**,
**SSE relay**) are defined in `CONTEXT.md`. The relayed routes (audio, rerank, realtime) and the MCP
gateway: skill `skeid-relay-routes`.

## The one-hub rule

Skeid speaks three **API formats** to clients but makes exactly one kind of upstream call:
OpenAI `POST {node.url}/chat/completions` (or `/embeddings`). Every other format is translated in
and out. Not negotiable:

- A format-specific field name (`system`, `tool_use`, `prompt_eval_count`, …) appears only inside
  that format's translation functions. Never in routing, usage, or the upstream call.
- A new **API format** = one request translator, one response translator, one route, one
  `api_format` string in the usage meta. Never a second upstream code path.
- The upstream call is engine-agnostic: vLLM, SGLang, Ollama-in-OpenAI-mode and OpenAI take the
  same body; the **Engine ID** is metadata for accounting and eligibility, not a branch in the
  request builder.
- A non-chat route of the OpenAI face (audio, rerank) is **relayed** to the node's endpoint of
  the same name, not translated into the chat call (ADR 0021) — a second path and body shape,
  not a second proxy function. Documents (`/v1/convert/*`, docling) follow the same rule with no
  `model`: planned over nodes of `kind: documents` under the routing key `documents` (skill
  `skeid-relay-routes`).
  The realtime route (`GET /v1/realtime`, ADR 0029) is the one that is a *session*: a WebSocket
  relayed in the node's own events, one slot and one usage event for its whole length.

## Traps almost every change hits

- **Tool calls are Langertha's job.** `Langertha::Tool` / `ToolCall` / `ToolChoice` own every
  format's tool shape. Never hand-roll a parser — extend Langertha, pin the new version in
  `cpanfile`.
- **Never rewrite a chunk on the OpenAI face** — the relay is byte-transparent. Every stream
  path calls `request.finish` exactly once.
- **Injected key drops the client's `Authorization` and `x-api-key` in any spelling**; a
  configured key source that yields no key fails closed (`503 upstream_key_unavailable`), never
  pass-through. A resolve failure never names the key.
- **`x-skeid-key-id` overrides only with `routing.trust_key_id_header`.** A new client route goes
  behind its face's `client_auth` bridge, or it is an open door.
- **Errors take the client's shape** (`_render_error`, stash `skeid.error_format`).
- A node url is a base, never a full endpoint.

## Where to read next

- Route table per face, embeddings path, `/health`, manifest → `references/client-edge.md`
- Anthropic/Ollama request and response translation, error shapes, tool calls →
  `references/translation.md`
- Upstream URL, forwarded headers, key injection and fail-closed, customer key ID,
  client auth → `references/upstream-auth.md`
- `_proxy_openai_stream`, drain queue, stream errors, usage in streams →
  `references/streaming.md`

## Engine IDs

`supported_engine_ids` is discovered from the installed `Langertha`, with a compiled-in fallback
list. `normalize_engine_id` lowercases and strips separators (`OpenAI-Base` = `openaibase`). An
unknown engine id on a node is not fatal — it only gates eligibility and lands in the usage event.

## Testing protocols

`Test::Mojo` against `Langertha::Skeid::Proxy->build_app(skeid => $skeid)` with a fake upstream
mounted in the same app (a second Mojolicious route the node url points at). Assert the
translated *shape*, not a golden JSON blob — pinning every upstream field fails on the next
harmless addition and says nothing about the contract.
