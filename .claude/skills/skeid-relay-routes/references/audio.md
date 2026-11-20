Read when touching `/v1/audio/transcriptions` or `/v1/audio/translations`, `Protocol::Audio` or its `$relay`.

# Relayed routes (audio)

A route of the OpenAI face that is not a chat call is **relayed, not translated** (ADR 0021):
`/v1/audio/transcriptions` and `/v1/audio/translations` go to `{node.url}/audio/...` as the
multipart form the client sent; the node's answer (JSON, `verbose_json`, `text`, `srt`, `vtt`,
SSE) comes back untouched. `Langertha::Skeid::Protocol::Audio` owns that wire — form fields,
upstream parts, where an answer reports usage; its names (`transcript.text.delta`,
`usage.type: duration`) appear nowhere else.

- `$relay` keys used: `request` (builds the upstream transaction), `units` (usage units off the
  answer), `delta_text` (stream frame text for `content_bytes`).
- Skeid reads `model` (exactly once, else `400`; routes and applies the key's policy by it) and
  `stream` (last one decides; on for pydantic's truth set `1 true on yes t y`). It writes `model`
  only when a tier serves another one. Everything else passes as sent — unknown and repeated
  fields, the client's part order and boundary.
- **Two parsers, one form.** The node parses the form again. Whatever a node could read as the
  `model` field must count as one in `form_fields`, or a key routes by one model and is served
  another. Loosen that parser, never tighten it; `name*` is refused.
- Upload mechanics (no copy, limit, `Expect`): `uploads.md`.
- Usage: tokens through `metrics.normalize` when reported; `audio_seconds` from `usage.seconds`
  (`usage.type` = `duration`), else top-level `duration`, else **absent** — never `0`. Not priced.
- Nothing is injected into the form (`stream_include_usage` is the client's to send).
