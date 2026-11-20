---
name: skeid-relay-routes
description: Use when working on Skeid routes relayed rather than translated — /v1/audio, /v1/rerank (incl. rerank_format tei), multipart uploads and their limits, docling /v1/convert, the /v1/realtime WebSocket session, or the MCP gateway /mcp/<name> and its mcp config.
user-invocable: false
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

Builds on `skeid-protocols` (one-hub rule, `_forward_headers`, key injection, client auth,
streaming relay) and `skeid-core` (nodes, admission, usage). Terms are defined in `CONTEXT.md`.

A route of the OpenAI face that is not a chat call is **relayed, not translated** (ADR 0021): the
client's body or form goes to the node, the node's answer comes back untouched.

## Rules every relayed route keeps

- **No second proxy function.** `_proxy_openai_json_async` / `_proxy_openai_stream` take an
  optional `$relay` hash. A new relayed route brings a `$relay`, never a copy of the relay.
  Keys: `request` (builds the upstream transaction), `units` (usage units off the answer; gets
  `$res` as second argument), `delta_text` (stream frame text for `content_bytes`), `usage` and
  `answer` (both `($payload, $res)`: usage block to meter or nothing; response translator, a `die`
  is the `translation_error` path, `500`), `max_parse_bytes` (larger answers stay undecoded).
- **One `Protocol::*` module owns each wire** (`Audio`, `Rerank`, `Documents`, `Realtime`, `MCP`);
  its field and event names appear nowhere else. A new dialect or field is an entry there.
- **One `model` reaches the node — the one Skeid routed by.** Skeid writes the served model;
  never pass the client's bytes through where a `model` could differ. Whatever a node could read
  as `model` must count as one in Skeid's parser — loosen it, never tighten; `name*` is refused.
- **Validation `400`s come before admission**: no slot, no event. Refusals after admission
  (`Protocol::Refusal` → `_refuse_unsendable_request`) still do `request.finish` and one failed
  event.
- **Usage fields are absent when not seen — never `0`.** Units like `audio_seconds`,
  `documents`, `pages` are recorded, not priced (realtime is priced through `_stream_metrics`).
- An upstream 4xx/5xx takes the existing error path (`upstream_error`, the node's message).
- **A new upload route is an entry in `%UPLOAD_ROUTE`** (read by `_limit_upload`), or it runs
  under the server's 16 MiB and gets no early `413` / `401`.
- **Realtime and the MCP gateway do not go through `_proxy_openai_*`** and bring no `$relay`.
  The MCP gateway has no node: it never touches `request.start` / `request.finish`.

## Where the details are

| Working on | Read |
|---|---|
| `/v1/audio/transcriptions`, `/v1/audio/translations`, `Protocol::Audio` | `references/audio.md` |
| `/v1/rerank`, `/rerank`, `rerank_format: tei`, `Protocol::Refusal` | `references/rerank.md` |
| Multipart, upload limits, `_limit_upload`, `Expect`, no-copy assets | `references/uploads.md` |
| docling `/v1/convert/file` / `/v1/convert/source`, `kind: documents` | `references/documents.md` |
| `GET /v1/realtime` WebSocket session, `realtime:` config | `references/realtime.md` |
| `/mcp/<name>`, `_relay_mcp`, `_authorize_mcp_client`, `mcp:` config | `references/mcp-gateway.md` |

Tests: `t/68` (upload copy), `t/69-rerank.t`, `t/72-mcp-gateway.t`, `t/88-documents-convert.t`,
`t/90-realtime-*.t`.
