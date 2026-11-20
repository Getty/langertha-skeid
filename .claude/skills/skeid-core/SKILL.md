---
name: skeid-core
description: Load when working on the Langertha::Skeid control plane — node inventory, weighted routing, admission control, config reload, the function dispatch surface, the admin API.
user-invocable: false
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

`Langertha::Skeid` is the control plane (nodes, routing, admission, config, pricing, usage,
registry snapshot); `Langertha::Skeid::Proxy` is the Mojolicious app on top (routes, auth,
handlers, upstream I/O). Moo, no singletons. Terms are defined in `CONTEXT.md` — use them exactly.

Beside them: `::UsageStore` (config normalization + backend factory; `::JsonLog` = append-only
JSON events, `::DBI` = sqlite + postgresql), `::CapacityProbe` (timer-driven; `::Prometheus`,
`::Registry`, `::Custom`), `::Registry` (signed Skeid-to-Skeid snapshot: encode, sign, verify,
ADR 0017), `::Secret` (constant-time compare for keys, tokens, signatures), `::KeyBroker`
(resolve($ref) contract; `::OpenBao` implements it).

Other skills: aliases, tiers, per-key policy, prefork workers, capacity probes → `skeid-routing`.
Usage accounting, pricing, usage stores → `skeid-usage`. The wire (`Protocol*`) → translated faces
`skeid-protocols`; `::Proxy::RelayContent` (upstream body relayed as raw bytes, skeid #30),
`::Proxy::Realtime` (one realtime session, ADR 0029) → `skeid-relay-routes`.

## Rules

- **Routing and admission are two steps; both can fail.** `route.next` picks a node;
  `request.start` may still refuse it — another request may have taken the last slot in between.
  Not redundancy.
  - **Eligible** = model matches (or node/request model empty) AND engine matches (or either
    empty) AND carries every selector tag AND no denied tag AND `healthy`.
  - **Admitted** = `inflight < worker_max_conns` (or `max_conns <= 0`) AND the node's current
    capacity reading allows it (skeid-routing).
- **Status codes are not interchangeable.** No eligible node → `503 model_not_found` at once.
  Eligible but none admitted → wait `route_wait_timeout_ms` (poll `route_wait_poll_ms`), then
  `429 rate_limit_error`. `429` = saturation, `503` = no-such-model: different fixes. `403` is a
  third — not a capacity answer at all. Wait with `Mojo::IOLoop->timer`, never `usleep`.
- **`inflight` is authoritative and paired:** every `request.start` that returned ok MUST get a
  `request.finish`, on every path including errors and upstream timeouts. A missed finish leaks
  a slot until restart.
- **Every inventory change must call `_bump_inventory`.** Derived lists are cached per
  `_inventory_generation`; a broken invariant is silent — miss one and traffic keeps going to a
  drained or removed node, with nothing logged.
- **Tags group nodes; ids never do.** Tags are part of the route key.
- **Health is operator state.** Never derive it from errors (flagged ambiguity in `CONTEXT.md`);
  write an ADR before changing it.
- **Never let anything a client controls decide the customer key id.** It selects both the
  routing policy and the invoice.
- **Add a function to `call_function` dispatch** rather than reaching into the object from the
  app. Unknown name croaks.
- **Reload from dispatch never dies; a reload makes the running config equal to the file** —
  except a removed `usage_store`, which keeps running until restart (ADR 0004).
- **No admin key → the whole `/skeid/*` surface answers `404`, not `401`.**

## Router

- Node fields, `add_node` validation, tag selection, the derived-list cache, round-robin walk →
  `references/nodes.md`.
- Function dispatch list, config sections and reload semantics, admin key precedence, ENV
  defaults, admin API endpoints, `/health` → `references/config-and-admin.md`.
