# ADR 0004 — Usage events are the billing unit; node metrics are not

- Status: accepted
- Date: 2026-08-08
- Tags: usage, metering, storage, pricing, backfill

## Context

Skeid exists between a client and a node because someone needs to know what was spent and by
whom. That makes metering a correctness concern, not an observability concern — and the two
have opposite requirements. Observability data may be sampled, aggregated, and lost on
restart. Billing data may not.

Both kinds of counter are trivially easy to conflate, because they count the same requests.

## Decision

Two separate things, never derived from each other:

- A **usage event** is written once per forwarded request, after `request.finish`, into the
  configured usage store. It carries identity, node, model, status, duration, tokens and cost.
  It is durable and it is the billing unit.
- **Node metrics** are volatile in-memory counters (started / ok / error / duration total) for
  operational visibility. They are lost on restart and are never billed.

Further:

- **Failures are billable events.** An error writes an event with `ok = 0`; it is not skipped.
  A request that consumed upstream tokens before failing consumed real money.
- **Cost is priced at record time** from `model_pricing` and stored on the event. A later price
  change never rewrites history.
- The store is pluggable — `jsonlog`, `sqlite`, `postgresql`, or a caller-supplied callback —
  and swapping it must never change what an event *means*. Backend selection infers from the
  config shape (`log_path` → jsonlog, `dbi:Pg:` → postgresql, a path → sqlite) with an explicit
  `backend` key winning.
- `jsonlog` is the recommended default because appending a line does not block the event loop
  on a database, and because an append-only file is the easiest thing to reconcile after an
  incident.

## Consequences

- Usage writes sit on the request path and are therefore a latency risk. Keeping them cheap is
  a hard constraint on any future store, and a store that can block must be opt-in.
- A crash between the upstream response and the usage write loses that event. Accepted: the
  alternative — a write-ahead step before forwarding — doubles the cost of every request to
  protect against a rare failure whose blast radius is one request.
- Reconciling node metrics against usage events will show drift, and that is expected. Do not
  "fix" it by deriving one from the other; they answer different questions.
- Schema lives in `share/sql/usage_events.<backend>.sql` and is applied via `auto_migrate`,
  which makes the shipped sharedir a runtime dependency of the DBI backends.
