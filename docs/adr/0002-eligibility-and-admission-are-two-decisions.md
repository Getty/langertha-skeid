# ADR 0002 — Eligibility and admission are two decisions, with two failure codes

- Status: accepted
- Date: 2026-08-08
- Tags: routing, admission, capacity, backfill

## Context

An LLM node is not a stateless web backend. It has a small, hard concurrency limit: past a
handful of simultaneous generations, an inference server does not degrade gracefully, it
collapses — latency multiplies and TTFT becomes unusable for everyone on the box. So a router
in front of it cannot treat "which node" and "can it take this now" as one question, the way a
round-robin HTTP balancer does.

Two failures also look identical to a naive router and are not: *nobody serves this model* is a
configuration error that will never resolve on its own, and *everyone who serves this model is
busy* is a transient state that usually resolves in seconds.

## Decision

Routing is two decisions, taken in order, and either can fail:

- **Eligibility** is static: the node matches the requested model and engine, and is flagged
  healthy. Computed from config state.
- **Admission** is dynamic: `inflight < max_conns` (or `max_conns <= 0` for unlimited).
  Computed from live counters.

`route.next` picks among eligible nodes by weighted round-robin, skipping nodes that fail
admission; `request.start` then confirms the slot and may still refuse it, because another
request may have taken the last one in between. The two-call shape is the design, not
redundancy.

The failures map to different responses:

- No eligible node → **`503 model_not_found`**, immediately. Waiting cannot help.
- Eligible but none admitted (**saturation**) → wait up to `route_wait_timeout_ms`, polling on
  the IO loop, then **`429 rate_limit_error`**.

`inflight` is the only capacity signal, it is owned by Skeid, and every successful
`request.start` must be paired with exactly one `request.finish` on every exit path.

## Consequences

- Clients can act on the distinction: `429` means retry, `503` means fix your config. Merging
  them would make both untreatable.
- A leaked `request.finish` permanently removes capacity from a node until restart. This is
  the single most damaging bug class in the router, which is why it is a house rule and a
  test invariant rather than a code comment.
- Skeid never learns real upstream capacity — `max_conns` is declared, not discovered. A node
  configured above its true limit will be saturated without Skeid knowing.
- **Health** stays operator state: it is not derived from errors. Demoting a node on upstream
  failures would make a transient full queue look like an outage with nothing to flip it back.
  Whether an error-driven demotion should exist is deliberately left open, and needs its own
  ADR before any error handler writes to the health flag.
