# ADR 0005 — The request path is async-only; no synchronous twins

- Status: accepted
- Date: 2026-08-08
- Tags: performance, mojolicious, event-loop, ttft

## Context

Skeid runs as a single Mojolicious process driving one IO loop, and the requests it forwards
are unusually long-lived: an LLM call takes seconds, a streamed one tens of seconds. That
inverts the usual web-server economics. A blocking call that costs 20ms in a normal app is
noise; here, a handler that blocks for the duration of an upstream generation stalls *every*
other in-flight request behind it, and the proxy's whole value — fanning many clients across
many nodes — disappears.

The failure is invisible in the obvious test. One `curl` against a blocking handler returns
perfectly. The stall only appears under concurrency, as a TTFT distribution with a long tail
that nobody can explain later.

The repository had accumulated exactly the shape that produces this: `_begin_route` (a
`usleep` poll loop) next to `_begin_route_async`, and `_proxy_openai_json` (a callback-less
`$ua->start`) next to `_proxy_openai_json_async`. The handlers all called the async ones; the
synchronous twins sat unused, waiting for someone to reach for the shorter name.

## Decision

The request path is asynchronous, and there is no synchronous alternative kept "for
simplicity".

- No `sleep`/`usleep` in a handler. Waiting for capacity is `Mojo::IOLoop->timer`.
- No callback-less `$ua->start($tx)` in a handler.
- Blocking work that cannot be avoided (a vault round-trip, a usage write) is minimised,
  documented, and measured — not hidden behind a helper that looks cheap.
- **The synchronous twins are deleted, not deprecated.** An unused blocking function next to
  an async one is a bug with a delay fuse: the next person greps for the name, finds the short
  one, and calls it.

Regressions here are proven with `bench/` (ADR 0007), not argued from the code.

## Consequences

- Every new upstream interaction has to be written in callback style, which is more work and
  is the price of the property.
- Two known blocking spots remain and are tracked rather than silently tolerated: the
  `HTTP::Tiny` KeyBroker round-trip on the request path, and DBI usage writes when a database
  backend is configured. Both are ticketed; `jsonlog` is the recommended default partly
  because it sidesteps the second.
- A single process still has a single CPU. This ADR removes *stalls*, not the need to run
  multiple workers when throughput demands it; that is a deployment decision, and one the
  benchmark harness exists to inform.
