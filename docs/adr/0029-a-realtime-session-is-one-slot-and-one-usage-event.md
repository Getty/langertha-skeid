# ADR 0029 — A realtime session is one slot and one usage event; the WebSocket is relayed, not translated

- Status: accepted — implemented (skeid k95)
- Date: 2026-10-15
- Tags: protocols, relay, realtime, websocket, audio, admission, usage, metering, auth

---

## Context

A client of live transcription keeps a WebSocket open and streams audio into it; text comes
back while it speaks (OpenAI's realtime protocol, `GET /v1/realtime`, served by vLLM and
speaches for realtime-capable models). Skeid fronts such a node like it fronts a file
transcription node (ADR 0021): behind client authentication (ADR 0020), routed by model and the
key's policy (ADR 0008), admitted (ADR 0002), the node's key injected (ADR 0003), metered
(ADR 0004).

Every route Skeid had until now is **one request, one answer**: `request.start`, one upstream
call, `request.finish`, one usage event. A session breaks each of those assumptions. It lasts
minutes; both sides send many messages; either side ends it, or neither does; its usage arrives
in pieces; and a client can change what it asked for in the middle of it (`session.update`),
after the key's policy was applied to the handshake.

The proxy functions of `Proxy.pm` are one-request helpers, so ADR 0021's "a relayed route brings
a `$relay`" does not reach this route.

## Decision

**`GET /v1/realtime` is a relayed route (ADR 0021) that is a session. A session holds one slot
of its node from the handshake to its close, is relayed in the node's own events, and is one
usage event, written when it closes.**

- **Handshake first, upgrade last.** Everything that can refuse a session is a plain HTTP
  answer before a socket exists: the client gate (a bridge, `401`), the `model` query parameter
  (exactly one — `intent=transcription` alone is a `400`, no slot is promised to a client that
  has not said what it wants), the key's policy (`403`), routing (`503`), admission (`429`,
  after `route_wait`, so a client waits in a pending handshake as an HTTP client waits for an
  answer). Then the node's key is resolved and **Skeid opens the node's WebSocket first**; the
  client is upgraded only when the node accepted. A node that refuses is a `502`, never an
  accepted-then-closed socket, and gives the slot back. A client that leaves during the wait
  gives it back too.
- **Not translated.** The beta dialect (`transcription_session.update`) and the GA dialect
  (`session.update` with a `transcription` session) go through as the client speaks them; the
  node answers in its own. `Protocol::Realtime` is the one place that knows the names.
- **The model of the session is the handshake's.** The policy hole of a session is a
  `session.update` naming a model the key was never granted. Every client text frame is
  decoded as JSON — never pre-filtered by substring, since JSON spells one text many ways and
  the node decodes the frame again (ADR 0021's two-parsers hazard) — and every string `model`
  in it is compared: the session's own is rewritten to the served one (alias tiers), any other
  is **not forwarded**; the client gets an `error` event and the session goes on, on the model
  it started with. What is forwarded is the document Skeid inspected, encoded again, so Skeid
  and the node read one thing. A frame that is not a JSON object closes the session `1003`, and
  so does a binary frame from the client.
- **One slot per session.** `request.start` is taken in the handshake and `request.finish`
  runs exactly once on every path, from one place that ends the session (client close, node
  close, abnormal end of either, a limit, a graceful stop). Therefore **`max_conns` of a
  realtime node means concurrent sessions**: give such a node its own entry. Under prefork
  workers `max_conns` is split between them (ADR 0010), so a realtime node needs
  `max_conns` of at least the number of workers, and its share per worker is the number of
  sessions one worker admits; a session is pinned to the worker that accepted it. The shared
  scoreboard (ADR 0014) is the real answer for same-box admission and is not built here.
- **One usage event per session**, written when it closes: the session's length as
  `duration_ms`, the `usage` blocks of its `…input_audio_transcription.completed` events
  **summed** (each block is one transcription's, unlike a stream's running totals) and priced
  through `metrics.normalize` like any answer, `audio_seconds` where a block is a duration, the
  bytes of the text relayed as `content_bytes`, and a status for how it ended. A client that
  closed properly is `ok`, whatever code it used; one that vanished without a close frame is
  `499 client_abort`; a node that closed with an error, or died, is `502`; a message above the
  limit is `413`; a client that sent what a session cannot carry is `400`. Counts the node did
  not report are absent, never zero (ADR 0021).
- **Bounded.** `realtime:` in the config (hot-reloadable, strict like `uploads`):
  `idle_timeout` 300 s, `max_session_seconds` 3600 s, `max_message_bytes` 1 MiB,
  `max_queued_bytes` 4 MiB. A message above its limit closes `1009`; bytes written to a peer that
  has not taken them, counted per direction until the transaction has drained them, close the
  session `1013` past their limit; silence and age close `1000` with a reason. All of it is
  timers and counters on the loop (ADR 0005).
- **A graceful stop closes sessions.** On the event loop's `finish` event — what a prefork
  worker emits on `SIGQUIT` — every open session is closed `1001`, so `request.finish` and the
  usage event run before the worker exits and not when the manager's `graceful_timeout` kills
  it. A kill without that (`SIGKILL`, OOM) loses the events of the sessions in flight, the same
  loss class as any request in flight, only longer. No checkpoint events.
- **A browser's key.** A page cannot set `Authorization` on a WebSocket. The key may come in the
  subprotocol list as `openai-insecure-api-key.<key>`, beside `realtime`, at the lowest
  priority (after `Authorization` and `x-api-key`), on this route only, behind the same client
  gate (a `401` before the upgrade). It is **never answered** — the subprotocol Skeid selects
  is `realtime`, or none — never logged and never passed to the node: the client's
  `Sec-WebSocket-*` headers, `Origin` and cookies are not forwarded, and the node is called with
  its own key (ADR 0003).

## Consequences

- ADR 0004's "one event per forwarded request" becomes "one event per forwarded request, or per
  session". Reports, `skeid usage`, the stores and their schema are unchanged: a session is a row
  like any other, with the same optional columns. Per-turn billing is not possible from it; one
  event per completed transcription would be, at the price of `request.finish` (per session) and
  events (per turn) no longer pairing and `duration_ms` losing its meaning.
- ADR 0021's "a relayed route is one request" gains the exception it was written around: a
  relayed route may be a session, and then `request.start`/`request.finish` bracket the session.
  See its Update.
- A slot held for minutes shows in capacity: an inflight probe is right as it is; a Prometheus
  probe reads the node's own gauge, which for a realtime node may count differently — to be
  checked against the deployed vLLM, not coded for.
- Every client frame is decoded and the forwarded ones are encoded again: a cost per audio chunk
  that was not measured (no `bench/` run). Chunks are small base64 strings.
- The read side is not throttled: a sender faster than its peer reads is cut with `1013` at
  `max_queued_bytes` rather than slowed. Mojolicious can pause a connection's reads
  (`Mojo::IOLoop::Stream->stop`/`start`, checked), which would turn that into backpressure; it
  was left out because it is a second mechanism for the same safety net.
- **Verified against speaches, not against vLLM.** `t/data/realtime/speaches.jsonl` was recorded from a
  real speaches node (`xt/live/record-realtime`), and `t/951-live-speaches.t` runs a session through Skeid
  against it. Findings: the node's `session.created` is the flat session of the conversation API
  (`input_audio_format`, `input_audio_transcription`), and it applies a flat `session.update`
  (`input_audio_transcription.model`/`language`) but ignores the GA `type: transcription` form; it ends
  a turn by server VAD only once the buffer is longer than 3 s (a shorter utterance needs trailing
  silence), and a manual `input_audio_buffer.commit` crashed its session in the version tried (an
  `AssertionError` in `commit_and_transcribe`, speaches 993994f); its `…completed` carries
  `usage: {type: duration, seconds}` and there are no `…delta` events; it accepted the connection without
  the `realtime` subprotocol. vLLM's dialect and usage block are still open.

## Tests

`t/90-realtime-config.t`, `-protocol.t`, `-handshake.t`, `-relay.t`, `-limits.t`, `-usage.t`:
the section's validation and reload; every place a frame can name a model, the escaped spelling,
non-objects and binary frames; the `401`/`400`/`403`/`429`/`502` before any socket, the key in
the subprotocol never echoed, logged or forwarded, a client that leaves during the node's
handshake or the capacity wait; both directions in order, the node's bytes unchanged, close
codes passed and mapped, a connection that vanishes on either side, fifty cycles that leave no
slot, session or connection behind; each limit and the graceful stop; summed usage, seconds, the
absent fields, failures, and the stores. Ten mutations of the logic were checked to fail them.
