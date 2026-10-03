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

## Update (skeid #36, 2026-09-25): streamed events carry `content_bytes`

A streamed request's usage event gains an optional `content_bytes`: the UTF-8 byte count of the
content Skeid relayed (OpenAI face, counted off the deltas it reads along) or translated (Anthropic
and Ollama faces, the translator's own count of the text it wrote). The field is additive — an
event without it means exactly what it meant before, and a non-streamed event omits it — so
existing sinks and reports are unaffected. `UsageStore::DBI` keeps it in a nullable column added
the ADR 0013 way (`@ADDED_COLUMNS`), `NULL` for "not measured".

It is set on every stream, including one whose upstream reported token counts: it is an
observation of what crossed the wire, not a substitute for them. It is not a billing quantity —
Skeid derives no token count and no cost from it, because a byte-to-token ratio is model- and
language-specific and an invented estimate on the billing unit would be worse than a recorded
zero next to an honest byte count.

## Update (skeid k65, 2026-09-29): a reload never removes the usage store

A reload makes the running config equal to the file: a section removed from it is cleared. The
usage store is the one exception. A *changed* `usage_store` is swapped on reload, the new store
prepared before the old one is let go, so events keep flowing to a named destination. A
*removed* one names no destination: honouring it would stop recording usage events on a reload,
with every later request unbilled and nothing but the missing rows to show for it. So the
running store stays in force until restart, and the reload logs once that it was removed. A
restart applies the absence — at start-up, where it is visible, not in the middle of traffic.

## Update (skeid k78, 2026-09-30): write-behind is opt-in and widens the loss window

The Consequences above accept that a crash loses the one event of the request in flight, and
require a store that can block to be opt-in. A DBI store with `usage_store.flush_interval_ms`
answers `store` with `{ ok => 1, queued => 1 }` and writes the queue later, in one transaction
per interval (ADR 0005, Update skeid k78). An event means the same thing wherever it is written,
and every event still gets one write attempt, a failure is still reported — through
`Skeid->on_usage_lost`, since the request's answer has gone out — but a process that dies
without a flush loses every event queued since the last one, not only the request in flight.
That changes what an outage can cost the billing record, so it is off by default and an
operator opts into it with the interval that bounds the window.

## Update (skeid k91, ADR 0021): a route's own usage unit is an optional event field

The audio routes count seconds of audio, not tokens. Their events carry `audio_seconds` when
the node reports a duration and no such key when it does not — optional and nullable like
`content_bytes`, recorded as reported, summed in the report, not priced (ADR 0021). The event
is still one per forwarded request and means the same in every store.
