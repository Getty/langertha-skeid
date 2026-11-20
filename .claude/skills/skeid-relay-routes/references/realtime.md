Read when touching `GET /v1/realtime`, `_handle_openai_realtime`, `Proxy::Realtime`, `Protocol::Realtime` or the `realtime:` config section.

# Relayed route: realtime (a session)

`GET /v1/realtime` upgraded to a WebSocket, relayed to `{node.url}/realtime` as a **session**
(ADR 0029, k95). It is a relayed route that is not one request and one answer, so it brings no
`$relay` and does not go through `_proxy_openai_*`: `_handle_openai_realtime` (handshake, in
`Proxy.pm`) and `Langertha::Skeid::Proxy::Realtime` (the relay). `Protocol::Realtime` owns the
wire — `intent`, `openai-insecure-api-key.`, `session.update`, `transcription_session.update`,
`…input_audio_transcription.delta` / `.completed` appear nowhere else.

- **Handshake = a request**, upgrade last. Order: client gate (`$openai` bridge, `401`, never a
  socket) → `model` in the query, exactly once (`400`; `intent=transcription` alone is a `400`) →
  `_begin_route_async` (`403`/`503`/`429`, `route_wait` before the upgrade) → node key
  (`_inject_node_auth_async`, fail closed `503`) → **open the node's WebSocket first** →
  `with_protocols('realtime')` + `$c->rendered(101)` → `start_session`. A node that refuses is
  `502`, slot given back, one failed event. A client that leaves while the node is opened: the
  handshake transaction (not the WebSocket one — `$c->tx->handshake`) closes; `_begin_route_async`
  and the handler both listen on it.
- **The node's handshake headers are not `_forward_headers` as is**: `Sec-WebSocket-*` (the
  subprotocol list carries a browser's key), `Origin`, `Cookie` are removed after it. The node
  gets its own key and no subprotocol. Do not forward them back in.
- **The key in a subprotocol** (`openai-insecure-api-key.<key>`) is read by
  `_extract_request_api_key` at the lowest priority and **for this route's path only**, so the
  client gate and the key id see it. It is never answered (`realtime` or none), logged or
  forwarded. `t/90-realtime-handshake.t` greps answer, node headers, log and event for it.
- **Frames.** Every client text frame is JSON-decoded (`Protocol::Realtime->client_frame`),
  never substring-filtered; every string `model` anywhere in it is compared: the handshake's
  → served model written in, any other → `error` event to the client, frame **not forwarded**,
  session goes on. What is forwarded is the decoded document encoded again (so Skeid and the node
  read one thing). Not an object, or a binary frame → close `1003`. Node frames: relayed as the
  bytes they came in, read for `.completed` usage / `.delta` text / `error`. Both dialects
  (beta, GA) relayed unchanged — translate nothing.
- **Ends once**: `_end` runs the finish callback (`request.finish`, one usage event) and then
  closes what is still open. Client close frame = ok whatever the code; no close frame = `499
  client_abort`; node close other than 1000/1001, or error event then close = `502`; `1009` from
  the client = `413`; `1003` = `400`. `1005`/`1006`/`1015` never go on the wire (client went →
  node `1000`; node died → client `1011`).
- **Bounds** (`realtime:`, read when a session opens, hot): `max_message_bytes` (default 1048576,
  1 MiB) is the transaction's own limit per session (`1009`); `max_queued_bytes` (default 4194304,
  4 MiB) counts bytes sent and not yet drained per direction (`1013`); `idle_timeout` (300) and
  `max_session_seconds` (3600) are timers
  (`Mojo::IOLoop->timer`, ADR 0005). The user agent's `inactivity_timeout` (300) would cut an
  idle upstream socket, so the session sets both streams' timeout itself; `request_timeout` does
  not cut an established WebSocket (checked).
- **Slot**: one per session, held until it closes: a realtime node is a node of its own and its
  `max_conns` means concurrent sessions; `max_conns >= workers`, each worker admits its share
  (ADR 0010) and a session stays on the worker that accepted it. No scoreboard.
- **Usage**: one event per session at close. Tokens = the `.completed` `usage` blocks **summed**
  (`add_usage`; not `_merge_usage`, that is for running totals), `audio_seconds` from
  `type: duration` blocks, `content_bytes` from the deltas — each absent when not seen, never
  `0`. Priced through `_stream_metrics`.
- **Graceful stop**: `Mojo::IOLoop->singleton->on(finish)` (what a prefork worker emits on
  `SIGQUIT`) → `shutdown` closes sessions `1001` first. A killed worker loses the events in flight.
- Fixtures in `t/data/realtime/` are synthetic (hand-written after OpenAI's guide); what vLLM and
  speaches really send and accept is **not verified** — see the README there. `t/lib/RealtimeHarness.pm`
  is the shared fake node and raw client. `t/90-realtime-*.t`; 10 mutations were checked red.
