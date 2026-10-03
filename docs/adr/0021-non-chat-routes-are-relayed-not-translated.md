# ADR 0021 — Non-chat routes of the OpenAI face are relayed, not translated; their usage units are optional event fields

- Status: accepted — implemented for audio (skeid k91); rerank follows (skeid k92)
- Date: 2026-10-03
- Tags: protocols, relay, audio, uploads, usage, metering, pricing

---

## Context

Skeid sits in front of a GPU cluster that runs more than chat models. A Whisper node (vLLM, or
speaches with faster-whisper) serves `POST /v1/audio/transcriptions` and
`/v1/audio/translations`; a reranker serves `/v1/rerank`. These requests have to come in through
Skeid like chat does — behind client authentication (ADR 0020), routed over nodes with
eligibility, admission and capacity (ADR 0002, 0009), one usage event each (ADR 0004).

ADR 0001 says there is exactly one upstream call, `POST {node.url}/chat/completions` (or
`/embeddings`) with an OpenAI-shaped JSON body, and every client format is translated into it.
That rule exists to avoid a matrix of client formats times upstream engines. The audio routes
do not fit its letter, and do not create its problem:

- The request is not JSON. It is a `multipart/form-data` upload, tens of megabytes of it a
  file. There is nothing to translate it *into*: the node's endpoint takes the same form.
- There is one client dialect, OpenAI's, and the nodes speak it. No Anthropic or Ollama face
  of these routes exists, so there is no matrix.
- The answer has several shapes — JSON, `verbose_json`, plain `text`, `srt`, `vtt`, and three
  event-stream dialects (OpenAI's and speaches' `transcript.text.delta` / `.done`, vLLM's
  `transcription.chunk` frames with `[DONE]`) — and the client asked for the one it gets.
  Normalising them would be translation with no client that wants the result.

The usage of such a route is not tokens either. A Whisper node reports seconds of audio
(`usage: {type: "duration", seconds}`, or the `duration` of a `verbose_json` answer), sometimes
tokens, often nothing. `Langertha::Usage` and `Langertha::Pricing` model tokens only.

## Decision

**A route of the OpenAI face that is not a chat call is a relayed route: its request goes to the
node's endpoint of the same name in its own shape, and the answer comes back as the node gave
it. Skeid routes it, admits it, authenticates it and meters it like every other request, and
translates nothing.**

- **Still one hub.** The upstream is still the OpenAI dialect at `{node.url}`; only the path
  and the body shape follow the route. ADR 0001's rule against a second upstream code path
  stands for chat: a relayed route does not get its own proxy function. `_proxy_openai_json_async`
  and `_proxy_openai_stream` take one optional `$relay` hash — `request` (builds the upstream
  transaction instead of the JSON POST), `units` (reads the route's usage units off the decoded
  answer), `delta_text` (the text of a stream frame in the route's dialect). Key injection,
  `request.start` / `request.finish` pairing, client abort, the cut-stream check, the drain
  queue and the usage event are the same code for every route.
- **What Skeid reads and writes is the minimum routing needs.** It reads `model` (to route and
  to apply the key's policy, ADR 0008) and `stream` (to pick the relay). It writes `model`,
  only when an alias tier serves another one. Every other part of the form — unknown fields,
  repeated fields — goes upstream as the client sent it, in the client's order, under the
  client's boundary.
- **The two parsers of one form must not disagree about `model`.** The form is parsed by Skeid
  and again by the node. A second `model` field, or one spelled so that only the node would
  read it, would let a key route by one model and be served another. So `model` must appear
  exactly once, a part's name is read as liberally as any node's parser reads it, and a name in
  the extended `name*` notation is refused (`400`).
- **A relayed stream is byte-transparent, as on the chat route.** Skeid reads along — any
  frame's `usage` block, merged; the delta text for `content_bytes` — and injects nothing: it
  does not add `stream_include_usage` to the form, as the chat relay does not add
  `stream_options.include_usage`. The OpenAI face never changes what the client asked for.
- **The wire knowledge lives in one module per route family**, `Langertha::Skeid::Protocol::Audio`
  — the form fields, the upstream parts, where an answer reports usage. The names of that wire
  (`transcript.text.delta`, `usage.type: duration`) appear there and nowhere else, which is ADR
  0001's rule for format-specific names applied to a route that has no translator.
- **An upload has its own request limit**, `uploads.max_bytes` (default 25 MiB, OpenAI's own),
  applied when the request's head has arrived and before its body is read. A request that
  declares more is answered `413` at once; a caller client authentication refuses is cut off
  the same way, so a `401` never costs a stored upload. The upload is not copied: the server
  spools it to a file and the upstream request is sent from that file. Every other route keeps
  the server's limit and its answers.
- **A route's usage unit is an optional, nullable field of the usage event**, recorded as the
  node reports it. For audio that is `audio_seconds`: `usage.seconds` when `usage.type` is
  `duration`, else a numeric top-level `duration`, else absent. Absent means not measured and
  is never written as `0` — the rule `content_bytes` and `cached_tokens` already follow (ADR
  0004, ADR 0013). Tokens a node reports go through `metrics.normalize` as on any route. The
  DBI stores get a nullable column through the additive migration, `jsonlog` writes the key,
  and the report sums it in `totals`, `by_key` and `by_model`.
- **Recorded, not priced.** `Langertha::Pricing` has no per-second rate and `Langertha::Usage`
  no seconds, so `cost_*_usd` of an audio event is what its tokens cost, which is usually
  nothing. This is ADR 0013's first step again: put the count on the ledger now, price it when
  Langertha can. A per-second rate kept in Skeid would be pricing outside `Langertha::Pricing`,
  which ADR 0013 chose to wait for rather than build.

## Consequences

- A Whisper node is a node like any other: `model`, `max_conns`, `tags`, aliases, tiers, key
  policy and capacity probes apply unchanged. There is no capability check — a chat request
  that names a Whisper model is routed to that node and refused there.
- Metering depends on what the node says. vLLM's JSON answer and every `verbose_json` answer
  carry seconds; speaches' plain JSON, `text` / `srt` / `vtt`, vLLM translations and most
  streams carry nothing, and their event has a status and a duration only. An operator who
  bills by the second has to have clients ask for `verbose_json`, or bill by request. Skeid does
  not measure the audio itself: that would mean decoding the upload.
- A route's units are fields, not a generic `units` map. Each new unit is a column, an entry in
  `@ADDED_COLUMNS` and a line in the report — deliberate, because a column a report can sum is
  what ADR 0004 promises, and the number of such units is small.
- `skeid usage` prints audio seconds only where there are some, so the report of a store
  without audio events is what it was. The JSON report gains `audio_seconds` keys (`0` where
  there is none).
- The upload limit holds while the body arrives because Mojolicious lets the limit be set per
  request once the head is parsed. A chunked body is only known to be too large when it is,
  so it is cut off 1 MiB past the limit rather than at it. Mojolicious does not answer
  `Expect: 100-continue`; a client that sends it (curl, above 1 MiB) waits out its own timeout
  before sending. The client's `Expect` is not forwarded: Skeid holds the body before it calls
  the node.
- The whole upload is received and spooled before a node is chosen. Admission is decided after
  the upload, so a saturated cluster answers `429` to a client that already sent its file.
- Rerank (k92) is the next relayed route: a JSON body, so no upload handling, but the same
  rule — relayed in the node's shape, its unit an optional event field.
- Follow-ups outside this decision: `Langertha::Usage` carrying audio seconds and
  `Langertha::Pricing` a per-second rate, after which `metrics.normalize` reports and prices
  them and `Protocol::Audio->usage_units` goes away; the provider manifest (ADR 0015) does not
  publish these routes, because its OpenAI endpoint is the `openai-chat` dialect.
- `t/68-audio-transcription.t` proves the relay against vLLM-, speaches- and OpenAI-shaped fake
  nodes: the form part for part with a file sent from disk, the alias rewrite, byte-identical
  answers and streams, the units read, load sharing with `max_conns` and health, the `413` and
  `401` before the body, every exit path's `request.finish` and one event, and the stores.
