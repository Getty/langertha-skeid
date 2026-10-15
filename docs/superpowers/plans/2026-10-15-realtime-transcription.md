# Realtime transcription over WebSocket — Implementation Plan

> **For agents:** execute task by task; steps use `- [ ]`. Code → `skeid-protocol-worker`,
> tests → `skeid-proxy-test-writer`, commit/card → `skeid-release-manager`. One test run at a
> time, `/proc/loadavg` first, always `prove -lr t/`. No live suites (`TEST_LANGERTHA_*`).

**Spec:** `docs/superpowers/specs/2026-10-15-realtime-transcription-design.md` (k95)
**Goal:** `GET /v1/realtime` — a client WebSocket relayed to a node's realtime endpoint,
gated, routed, admitted per session, bounded, metered once per session.
**Architecture:** `Langertha::Skeid::Proxy::Realtime` (session) +
`Langertha::Skeid::Protocol::Realtime` (wire names, dialect table, usage reader); `Proxy.pm`
mounts the route and extends `_extract_request_api_key` with the subprotocol source.
**Decisions assumed** (spec end): 1 model in query, 2 relay both dialects/no binary, 3 refuse
foreign model, 4 one event per session, 5 limits under `realtime:`, 6 capacity documented,
7 subprotocol key accepted. Nothing before Task 0 may start building.

---

## Task 0 — Facts from the deployed backends (no lib/ change)

- [ ] With `websocat` against the deployed vLLM and speaches, record full transcripts of one
      session each (handshake URL/headers, accepted setup event — `session.update` vs
      `transcription_session.update`, server events incl. whether `.completed` has `usage` and
      of which `type`, error events, close codes on bad input). Store as
      `t/data/realtime/<backend>.jsonl` (audio payloads truncated, **no keys**).
- [ ] Verify with a throwaway script (not committed): Mojolicious 9.x on this box
      — (a) `$tx->max_websocket_size` per tx, (b) `$c->inactivity_timeout` on an upgraded
      connection, (c) whether `$app->ua->request_timeout` (300 s) cuts an established
      upstream WebSocket, (d) any read-side flow control on `Mojo::Transaction::WebSocket`,
      (e) `with_protocols` selection, (f) behaviour of the prefork manager on SIGQUIT with an
      open WebSocket. Run under `systemd-run --user --scope -q -p MemoryMax=1G -p MemorySwapMax=0 -- timeout 120`.
- [ ] Write results into the card note; correct spec sections 2 and 4.4 where they differ.

## Task 1 — Config: `realtime:` section

**Files:** `lib/Langertha/Skeid.pm`, `t/79-realtime-config.t`

- [ ] **Red test**: defaults (`idle_timeout 300`, `max_session_seconds 3600`,
      `max_message_bytes 1048576`, `max_queued_bytes 4194304`); an unknown key, a non-integer or
      `< 1` value croaks; a reload changes the values (same style as `uploads`).
- [ ] Implement attributes + parse + reload reset; POD in the config reference.

## Task 2 — `Protocol::Realtime` (pure functions, no I/O)

**Files:** `lib/Langertha/Skeid/Protocol/Realtime.pm` (new), `t/00-load.t`, `t/79-realtime-protocol.t`

- [ ] **Red tests** from the Task 0 recordings: `client_frame($json_text, $requested, $served)`
      returns `{action => forward|refuse|close, text, error}`:
      - `session.update` naming the requested model → forward with served model written
      - a foreign model → refuse with an error event body
      - `"type":"session.update"` is decoded like the plain spelling
      - non-JSON / non-object → close `1003`
      - `input_audio_buffer.append` → forward untouched (the same bytes)
      - both dialects' model locations covered
- [ ] `server_frame($text)` → `{usage => {...}|undef, delta_text => ..., error => 0|1}` from
      `.completed` / `.delta` / `error`; usage normalised the way `Protocol::Audio->usage_units`
      reads `usage.type: duration` and tokens.
- [ ] `routes`, `upstream_ws_url($node_url, $served_model, $query)`.

## Task 3 — Handshake (client gate, route, upstream first, upgrade)

**Files:** `lib/Langertha/Skeid/Proxy.pm`, `lib/Langertha/Skeid/Proxy/Realtime.pm` (new),
`t/79-realtime-handshake.t`

- [ ] Fake upstream WebSocket helper (Test::Mojo app on an ephemeral port; echoes recorded
      server events; records handshake headers).
- [ ] **Red tests**: bad key → plain `401`, no upgrade (`websocket_ok` fails with `401`);
      key only in subprotocol → accepted, response `Sec-WebSocket-Protocol` is not the key
      entry; no `model` → `400`; policy-denied model → `403`; `max_conns 1` with one session
      open → second `429`; upstream refuses (HTTP 401/500 on its handshake) → client gets
      `502`, **no** slot left (`request.finish` seen once); client gives up during the upstream
      wait → slot back; node key reaches upstream, client's subprotocol key does not.
- [ ] Extend `_extract_request_api_key` with the subprotocol source (lowest priority);
      never log `Sec-WebSocket-Protocol`.
- [ ] Mount `$openai->websocket('/v1/realtime')`; `_begin_route_async`, then
      `$app->ua->websocket` with headers from `_forward_headers` + `_inject_node_auth_async`;
      upgrade the client only after the upstream is up.
- [ ] Verify: nothing synchronous on the path (ADR 0005) — no `sleep`, no blocking `->start`.

## Task 4 — The relay and close handling

**Files:** `lib/Langertha/Skeid/Proxy/Realtime.pm`, `t/79-realtime-relay.t`

- [ ] **Red tests**: text frames both ways in order; the bytes of a server frame arrive
      identical; binary client frame → close `1003`; client closes `1000` → upstream closed
      `1000`; upstream closes `1011` → client `1011`; abnormal (no close frame) → peer `1011`
      resp. `1000`; each side's close ends exactly one `request.finish`.
- [ ] Implement the two-way relay with `client_frame`/`server_frame`, a once-only `$finish`
      closure (guards `request.finish`, usage event, both closes), weak references so the
      session does not leak (leak check: loop 50 open/close cycles, `Test::LeakTrace`-free —
      count live `Mojo::IOLoop` streams).

## Task 5 — Bounds: size, queue, idle, lifetime, shutdown

**Files:** `lib/Langertha/Skeid/Proxy/Realtime.pm`, `bin/skeid` (POD only if Task 0f needs it),
`t/79-realtime-limits.t`

- [ ] **Red tests** (small configured limits, short timers): frame above
      `max_message_bytes` → `1009`; a stalled consumer (fake upstream that does not read) +
      a fast client → `1013` once `max_queued_bytes` is exceeded and process memory of the test
      stays flat (count queued bytes in the session object, assert ≤ limit + one frame);
      silent socket closes at `idle_timeout`, not at 30 s; `max_session_seconds` → `1000`
      with the reason; app shutdown closes open sessions `1001` and the usage event is written.
- [ ] Implement with `Mojo::IOLoop->timer` only (ADR 0005); cancel timers in `$finish`.

## Task 6 — Metering

**Files:** `lib/Langertha/Skeid/Proxy/Realtime.pm`, `t/79-realtime-usage.t`

- [ ] **Red tests**: a session with two `.completed` events (usage blocks of type tokens) →
      one event with summed tokens, `endpoint /v1/realtime`, `duration_ms` ≈ session length,
      `status ok`; `duration`-typed usage → `audio_seconds` summed; no usage in answers →
      event with status and duration only (no zero-filled fields); upstream error path →
      `status error`; alias tier → `model` served, `requested_model` asked; no key material in
      the event or in the captured log; all three stores (`jsonlog`, sqlite) write and report
      it.
- [ ] Implement via `_record_usage_event` + `_merge_usage`; priced through `_priced_metrics`.

## Task 7 — Policy hole regression (mutations, house rule 7)

Each run `systemd-run --user --scope -q -p MemoryMax=1G -p MemorySwapMax=0 -- timeout 120 prove -l t/79-realtime-*.t`;
each mutation must turn a named subtest red.

- [ ] forward frames without decoding (substring check instead) → the `.` subtest fails
- [ ] forward a foreign model unchanged → the foreign-model subtest fails
- [ ] skip `request.finish` on upstream close → slot-leak subtest fails
- [ ] unbounded queue (no `1013`) → overflow subtest fails
- [ ] echo the key subprotocol → the handshake subtest fails
- [ ] write the usage event per completed transcription → "one event" subtest fails

## Task 8 — Docs, ADR, bench note, hand-over

- [ ] README, CONTEXT.md, POD (`Skeid.pm`, `Proxy.pm`, `Proxy::Realtime`, `bin/skeid`),
      `skeid-protocols` / `skeid-core` / `skeid-service-stack` skills, example config,
      `Changes`. A new tracked top-level directory: none (`t/data/` exists).
- [ ] ADR (number from the coordinator): session admission and metering; ADR 0021 *Update*:
      a relayed route may be a session.
- [ ] skeid-perf-tester: cost of decoding every client frame (one run, `nice -n 19 ionice -c3`,
      fakellm-like WebSocket echo on `127.0.0.1`, not in the background) and the
      per-session memory — before a release note claims anything.
- [ ] `skeid-release-manager`: commit, card k95 → review.

## Done when

All `t/79-*` subtests green and each mutation of Task 7 observed red; `prove -lr t/` PASS
(report Files/Tests); Task 0 findings recorded; docs and ADR written. *Folge in langertha:* a
realtime/transcription engine, if Langertha grows one, would replace the dialect table; none
required now. *Folge in deployment docs:* a realtime node of its own, `max_conns >= workers`.
