# Design — Realtime transcription over WebSocket (OpenAI Realtime protocol)

- Status: implemented (k95, ADR 0029); section 4.4 corrected by the Task 0 facts of 2026-10-15,
  section 2 still open for the deployed backends (see below)
- Date: 2026-10-15
- Plan: `docs/superpowers/plans/2026-10-15-realtime-transcription.md`
- Builds on: ADR 0005 (async-only), ADR 0004 (usage event), ADR 0009/0010 (admission, worker
  share), ADR 0020 (client authentication), ADR 0021 (relayed routes), k91 (file transcription)
- Vocabulary: `CONTEXT.md` (Relayed route, Admission, Inflight, Worker share, Usage event)
- Companion ADR: `docs/adr/0029-a-realtime-session-is-one-slot-and-one-usage-event.md` — **session
  admission and session metering**, the first request that is not one request/one answer.

## 1. Problem

A client keeps a WebSocket open and streams audio; text comes back while it speaks. Skeid
fronts the nodes (vLLM `/v1/realtime`, speaches' realtime route) like it does for file
transcription: behind `client_auth`, routed, admitted, key injected, metered. Today every route
is *one request, one answer* — `request.start` … `request.finish`, one usage event, one
upstream call. A WebSocket session breaks each of those assumptions: it lasts minutes, it has
many messages in both directions, it ends from either side, and its usage arrives in pieces.

## 2. The protocol, as far as Skeid is concerned

Checked against OpenAI's current guide on 2026-10-15 — **and it has drifted from the card**:

| | Card (k95) | OpenAI today |
|---|---|---|
| session setup event | `transcription_session.update` | `session.update` with `session.type: "transcription"`, `audio.input.{format,transcription.model,turn_detection}` |
| client audio | `input_audio_buffer.append` (base64 PCM16 in `audio`), `.commit` | same |
| server text | `conversation.item.input_audio_transcription.delta` (`item_id`, `content_index`, `delta`) | same; `.completed` carries `transcript` |
| session announce | `session.created` | not in the guide page read (see reference) |
| usage in `.completed` | "a usage block" | not documented on the guide page |

**Not verified against a deployed backend (open, k95):** the plan's Task 0 asked for recordings
of vLLM and speaches; with no live node they could not be made. `t/data/realtime/*.jsonl` is
written by hand after the guide and says so.

So there are at least **two client dialects** (the beta `transcription_session.update` and the
GA `session.update`) and **backends that speak whichever version they implement**. Skeid must
not guess: the first task of the plan is to capture what the *deployed* vLLM/speaches send and
accept (`websocat` against each, recorded transcripts as fixtures). Everything below is written
so that the dialect is data in one module, not logic in the handler.

Connection facts needed: `GET /v1/realtime?model=…` (or `?intent=transcription`) upgraded to a
WebSocket; key in `Authorization: Bearer`, and for browsers (cannot set headers) in a
subprotocol (`openai-insecure-api-key.<key>` alongside `realtime`, per OpenAI's browser
convention — to verify with a real client in Task 0).

## 3. Goals and non-goals

**Goals**
- `GET /v1/realtime` behind the client gate, routed by model, relayed as a session, admitted per
  session, metered once per session.
- No unbounded memory: bounded queue per direction, bounded message size, bounded idle and
  session time.
- Every exit path ends with exactly one `request.finish` and one usage event; secrets never in
  logs or events (ADR 0003).
- Fully offline tests (`websocket_ok`, a fake WebSocket upstream in the same test process).

**Non-goals**
- Realtime *conversation* (audio out, tool calls, responses): `intent=transcription` only. A
  session that asks for more is whatever the node does; Skeid does not police the dialect.
- A second server process; Mojolicious serves the socket in the same prefork workers.
- Translating between the beta and GA dialects (decision 2).
- Server-side VAD or audio decoding in Skeid.

## 4. Design

### 4.1 One module, one route

`Langertha::Skeid::Proxy::Realtime` (some 350–500 lines, as the card estimates) owns the
session. `Proxy.pm` mounts `$openai->websocket('/v1/realtime')` and calls into it. The wire
names (`input_audio_buffer.append`, `…transcription.completed`, `session.update`,
`transcription_session.update`) live in `Langertha::Skeid::Protocol::Realtime` only — ADR
0021's one-module rule for wire knowledge. The proxy functions of `Proxy.pm` are not reused for
the relay (they are one-request helpers); `_begin_route_async`, `_inject_node_auth_async`,
`_record_usage_event`, `_merge_usage` and `_forward_headers` are.

### 4.2 Handshake (before the upgrade)

Order matters; each refusal is a plain HTTP answer and **no socket is opened**:

1. **Client gate** (the `$openai` bridge, `_authorize_client`) — `401`, never an open socket.
   The key is read from `Authorization`/`x-api-key` first, else from the subprotocol list;
   `_extract_request_api_key` gets that third source. The key is never echoed: the subprotocol
   Skeid selects in its answer is `realtime` (or none), never the key-carrying entry, and the
   `Sec-WebSocket-Protocol` header is never logged.
2. **Model**: `model` from the query. `intent=transcription` without `model` → `400`.
   (Decision 1: holding the socket until `session.update` names it is rejected by default.)
3. **Policy and routing**: `_begin_route_async($c, $model, $api_key_id, …)` — `403`/`503`/`429`
   as for every route. `route_wait` therefore happens *before* the upgrade; a client waiting
   for capacity sees a pending handshake, as an HTTP client sees a pending request.
4. **Slot**: `request.start` happens inside `_begin_route_async`; `request.finish` is now the
   session's to call, once (4.6).
5. **Upstream first, then upgrade**: Skeid opens the upstream WebSocket
   (`$app->ua->websocket`, async, node key injected into the handshake headers by
   `_inject_node_auth_async`, URL scheme `http→ws`, `https→wss`, model query replaced by the
   served model) and upgrades the client **only when the upstream handshake succeeded**. An
   upstream that refuses becomes an HTTP error to the client (`502` in the OpenAI shape), not
   an accepted-then-closed socket. A client that hangs up during this wait gives the slot back
   (the `_client_gone` pattern of `_proxy_openai_stream`).

### 4.3 The relay

Two `Mojo::Transaction::WebSocket` objects, A (client) and B (upstream), a pair of callbacks
each way:

- **Text frames** (JSON): decoded, inspected by `Protocol::Realtime->client_frame`, forwarded.
- **Binary frames**: this protocol sends JSON text only; a binary frame from the client is
  closed with `1003`. (Decision 2 keeps this simple; a node that wants raw PCM binary frames
  would be a separate, explicit option.)
- **Server → client**: text frames are decoded for usage (`.completed` blocks), forwarded
  verbatim (re-sending the received bytes, not the re-encoded structure — byte-transparent as
  the SSE relay is).

**Why client frames are parsed, and what is checked (the policy hole):** the key's policy
(ADR 0008) was applied to the handshake model. A `session.update` that names another model
would switch the session to a model the key was never granted — a policy bypass that no
single-request test sees. Therefore every client text frame is JSON-decoded (a frame that is
not a JSON object is closed `1003`/`1008`) and, where it carries a model
(`session.audio.input.transcription.model`, `session.model`, or the beta `input_audio_transcription.model`):

- equal to the requested model → rewritten to the served model (alias tiers, ADR 0008);
- anything else → **not forwarded**; Skeid sends a protocol `error` event to the client and
  keeps the session on the handshake model. (Rewriting to the handshake model silently would
  hide the bug; refusing the session would be harsh for a client that re-sends its config.)

A substring pre-check instead of decoding is **rejected**: JSON allows `"session.update"`
and the two-parsers hazard of ADR 0021 applies — Skeid and the node would read different
things. Decoding every client frame is acceptable: audio chunks are small base64 strings, and
this is the only way both parsers see the same document. The cost is measured in Task 8.

### 4.4 Backpressure, sizes, timeouts

Facts checked on this box (Mojolicious 9.49, throwaway script, 2026-10-15) and what the
implementation does with them:

- **Queue per direction, bounded.** `$tx->send($frame, $cb)` runs `$cb` on the transaction's
  next `drain`, i.e. when the stream has taken everything queued before it; a peer that does not
  read keeps its frames in the transaction's buffer. Skeid counts sent-and-not-drained bytes per
  direction and, past `realtime.max_queued_bytes` (default 4 MiB), closes the session `1013`
  rather than letting a fast sender grow the worker. **Read-side flow control exists**:
  `Mojo::IOLoop->stream($tx->connection)->stop` / `->start` pauses and resumes delivery of a
  connection's frames (verified: nothing delivered while stopped, all of it after `start`). It
  is not used; the close is the one mechanism (decision recorded in ADR 0029).
- **Message size** (a): `max_websocket_size` is an attribute of each `Mojo::Transaction::
  WebSocket`, set per transaction on either end (default `MOJO_MAX_WEBSOCKET_SIZE` or 256 KiB); a
  larger message makes the transaction close `1009` itself. Set per session on both sides from
  `realtime.max_message_bytes` (default 1 MiB).
- **Idle** (b), (c): `$c->inactivity_timeout($s)` works on an upgraded connection (the socket
  closes after `$s` seconds, without a close frame, `1006`). On the **upstream** socket,
  `$ua->inactivity_timeout` (300 in `build_app`) **does** cut an established WebSocket (checked
  with 1 s: closed after 1.0 s), while `$ua->request_timeout` does **not**; setting
  `Mojo::IOLoop->stream($tx->connection)->timeout($n)` after the upgrade overrides it. So the
  session sets both streams' timeout to `idle_timeout + 5` as a backstop and closes with a reason
  at `realtime.idle_timeout` (default 300 s) from its own timer, re-armed from the last frame
  in either direction.
- **Session lifetime**: `realtime.max_session_seconds` (default 3600) → close `1000` with the
  reason `session time limit`. Without it a leaked client holds a slot forever.
- **Subprotocol** (e): `$tx->with_protocols('realtime')` selects `realtime` when it is among the
  offered ones and sets the answer's header; when none matches, no header is sent and the
  handshake still succeeds (a browser fails such a handshake, so a browser client has to offer
  `realtime` beside its key entry, as OpenAI's own convention does). The key entry is never
  selected.
- **Graceful stop** (f): the prefork manager sends `QUIT` to its workers on its own `QUIT`; a
  worker runs `$loop->stop_gracefully`, which emits `finish` on `Mojo::IOLoop->singleton` and
  then waits for open connections. Without a listener, a worker holding a WebSocket is killed at
  `graceful_timeout` (checked: client `1006`, manager out after the timeout), so `request.finish`
  and the usage event are lost. With a `finish` listener that closes the sessions `1001`, the
  client gets `1001` and the manager is out in about the time it takes to close. Skeid
  registers that listener, per process, with its first session (`Proxy::Realtime`). `bin/skeid`
  needs no change.

### 4.5 Close handling

Whichever side closes first, the other is closed with the mapped code and Skeid finishes once.
Codes 1005/1006/1015 cannot be sent on the wire: mapped to `1000` (client went) / `1011`
(upstream died). A normal client close is `status: ok`; upstream close `1011`, an upstream
`error` event followed by close, or any internal failure is `status: error`; client close while
no `.completed` was ever seen is still `ok` (no transcription was requested), not `aborted`.

### 4.6 Admission and metering: per session

- **Admission**: the slot is held from handshake to close. `max_conns` of a realtime node
  therefore means *concurrent sessions*; the node should be a node of its own (a Whisper node
  serving both file and realtime has two meanings of `max_conns` — documented, not
  prevented). Worker shares (ADR 0010): `max_conns / workers`, so `max_conns 4` with 4 workers
  admits one session per worker and refuses the fifth when one worker has two clients —
  documented in the deployment notes; the shared scoreboard (ADR 0014) is the real answer and
  not part of this card.
- **Capacity probes** (ADR 0009): an inflight probe is correct as is; a Prometheus probe
  reads the node's own gauge, which for a realtime node may count differently — to verify
  with the deployed vLLM, documented, no code.
- **Metering**: **one usage event per session, at close** (decision 4): `endpoint:
  /v1/realtime`, `duration_ms` = session length, `status` per 4.5, `model`/`requested_model`
  as for any route, tokens = the `usage` blocks of all `…transcription.completed` events
  merged by `_merge_usage` (and `audio_seconds` where `usage.type: duration`) — so the existing
  columns, `metrics.normalize` and the reports apply unchanged. No new column is required; an
  optional `transcriptions` count is **not** added (not asked for, `content_bytes` of the
  transcript text is already an existing observation field: summed delta text).
- **Crash window**: an event written only at close is lost with the worker if it is
  SIGKILLed mid-session — the same loss class as any in-flight request, only longer. Checkpoint
  events are not proposed.

### 4.7 Secrets and logs

The key may arrive in a subprotocol. It is read once for `_extract_request_api_key`, never
stored on the stash beyond what exists today, never in `$app->log`, errors, or the usage event
(only the key *id* is). The Authorization sent upstream is the node's key; the client's
subprotocol key is not forwarded upstream (ADR 0003, and the `_drop_client_credentials`
rule: the client's credentials never ride along).

## 5. Risks

- **Dialect drift** (section 2): the biggest, and not a Mojolicious problem. Mitigation:
  Task 0 fixtures from the deployed servers; dialect table in one module; tests assert on
  those recordings, not on the docs.
- **Policy bypass via `session.update`** (4.3): addressed by decoding and refusing.
- **Slot held for minutes**: capacity planning, 4.6; `max_session_seconds`.
- **Backpressure primitives** in Mojolicious are limited (no read-side flow control on the
  server tx); the bounded queue + `1013` is the safety net, not a smooth throttle.
- **Test fidelity**: a fake upstream WebSocket proves the relay, not the real backends'
  quirks; the recorded fixtures are the bridge.

## 6. Testing

`Test::Mojo` `websocket_ok`, fake upstream WebSocket route in a second app on an ephemeral
port (the t/68 pattern, with `websocket` instead of `post`). Offline.

Handshake: `401` without upgrade for a bad key, key via subprotocol accepted and not echoed,
`400` without model, `403` by policy, `429` when saturated (and queued under `route_wait`),
`502` when upstream refuses, client abort during the upstream wait returns the slot.
Relay: frames both ways in order, text + a refused binary, close code mapping both ways,
alias model rewritten in `session.update`, foreign model refused with an `error` event,
`.`-escaped `session.update` still decoded, oversize frame → `1009`, queue overflow →
`1013`, idle timeout, session lifetime, shutdown closes `1001`.
Accounting: slot taken at handshake and freed exactly once on every path, one usage event with
summed usage, `status` per path, no key in the event or the log.
Mutations listed in the plan.

## 7. Documentation touched when built

README, CONTEXT.md (**Session**, **Realtime route**), `Skeid.pm` POD (`realtime:` section),
`Proxy.pm` POD, `bin/skeid` POD (graceful stop with open sessions), `skeid-protocols`,
`skeid-core` and `skeid-service-stack` skills, example config, ADR (session admission/
metering), ADR 0021 *Update* (a relayed route may be a session), `Changes`.

## 8. Order and effort

After k91 is in use and a real client asks (card). Three worker passes: (1) handshake +
relay + close, (2) policy frames, limits, timeouts, graceful stop, (3) metering + docs +
ADR. About 400 lines plus about as many of tests; risk medium.

## Decisions Getty has to make

1. **Model naming at the handshake.** Recommendation: `model` in the query is required;
   `intent=transcription` alone is refused with `400`. Alternative: hold the upgraded socket
   until the first `session.update` names the model (route planning, admission and policy
   then happen mid-socket, a slot is promised to a client that has not said what it wants) —
   more state, no use case yet.
2. **Which dialect(s) to support.** Recommendation: relay both beta and GA client frames as the
   node speaks them and translate nothing; support exactly what the deployed backends
   recorded in Task 0, refuse binary client frames. Alternative: a normalising layer (accept GA,
   send beta) — only if two deployed backends demand opposite dialects.
3. **A foreign model in `session.update`.** Recommendation: refuse that frame with an `error`
   event and keep the session on the handshake model. Alternatives: close the session
   (`1008`), or silently pin the handshake model.
4. **Metering granularity.** Recommendation: one usage event per session at close (summed
   usage, duration, status), via an ADR that widens "one event per forwarded request" to
   "per request or per session". Alternative: one event per completed transcription — crash
   safe and finer for per-turn billing, but then `request.finish` (per session) and events (per
   turn) no longer pair, and `duration_ms` loses its meaning.
5. **Limits.** Recommendation: defaults `idle_timeout 300 s`, `max_session_seconds 3600`
   (OpenAI's own session cap), `max_message_bytes 1 MiB`, `max_queued_bytes 4 MiB`, all under
   `realtime:` and hot-reloadable. Alternative: none configurable until a client needs it.
6. **Capacity story.** Recommendation: document that a realtime node is its own node with
   `max_conns` = concurrent sessions and `max_conns >= workers`; do not build the shared
   scoreboard (ADR 0014) for this card. Alternative: make k95 wait for the scoreboard.
7. **Browser clients.** Recommendation: accept the key in the `openai-insecure-api-key.<key>`
   subprotocol (the convention of the OpenAI SDKs) behind the same client gate. Alternative:
   header-only — then browser clients need their own backend, which is OpenAI's recommended
   pattern for exactly this reason (the key is visible in the page).
