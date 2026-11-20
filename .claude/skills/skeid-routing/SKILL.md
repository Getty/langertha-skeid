---
name: skeid-routing
description: Use when working on how Skeid chooses where a request may go — model aliases and tiers, per-key policies and deny_tags, prefork workers and per-process limits, capacity probes (prometheus, ratelimit, registry, custom).
user-invocable: false
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

Builds on `skeid-core` (nodes, eligibility, admission, `inflight` pairing). Terms are defined
in `CONTEXT.md`.

## Rules

- **The two ways a tier fails differ.** No eligible node → next tier immediately (waiting cannot
  conjure a node). Eligible but none admitted → wait this tier's `wait_ms` (default **0**), then
  fall through. Plan exhausted with no tier ever eligible → `503 model_not_found`; some tier was
  → `429 rate_limit_error`.
- **Not permitted is `403`, never a capacity code.** `route_plan` returns
  `{ tiers, permitted, reason }`; `permitted => 0` (`model_not_permitted` or `all_tiers_denied`)
  is `403 permission_error`. Running out of *permitted* capacity stays `429` — never fall through
  to a denied node because everything else is full.
- **`deny_tags` filters node selection, not only the plan.** An alias is a product name, not a
  security boundary: a key denied `cloud` must not reach a cloud node by asking for its raw model
  name. `t/26-key-policies.t` proves both halves.
- **Policy fails closed.** Naming an undefined policy croaks at load. A customer source with no
  or a stale snapshot merges nothing.
- **Identity is derived, never asserted.** The policy hangs off the customer key id from the
  presented key (`key_id_for_key`), not from `x-skeid-key-id` — unless
  `routing.trust_key_id_header` says a gateway in front authenticated the caller.
- **Limits are per process.** Each process takes `max_conns / (frontend_count × N)`
  (`worker_max_conns`); anything on a timer runs once per worker.
- **A capacity probe may only narrow what `max_conns` allows, never widen it.** On any probe
  failure forget the reading and let `inflight` decide — never keep the last reading. A
  `429`/`Retry-After` backoff **never touches `healthy`**. Probing never happens on the request
  path.
- **The customer-source database is never on the request path, and its connect never runs in the
  loop's process** (`Mojo::IOLoop->subprocess`).
- **The catch-all kind is the route's, not a node kind** — never pass it as `kind` to
  `route_plan`.

## Router

- Aliases and tiers, `routing.catch_all`, node `kind` and the `documents` routing key →
  `references/aliases-and-kinds.md`.
- `policies` / `keys` / `default_policy`, key ids (full vs legacy short), per-key `rate` →
  `references/key-policy.md`.
- `customer_source` (database view, fetcher, merge, fail-closed, tests) →
  `references/customer-source.md`.
- `serve --workers`, `frontend_count`, prefork and the usage store, capacity probes (config,
  probe table, expiry, backoff, rebuild) → `references/workers-and-capacity.md`.
