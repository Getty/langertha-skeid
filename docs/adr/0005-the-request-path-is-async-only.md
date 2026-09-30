# ADR 0005 — The request path is async-only; no synchronous twins

- Status: accepted — the KeyBroker blocking spot is gone (skeid #3); DBI usage writes can be
  written behind (skeid k78, opt-in) — see Updates
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

## Update (skeid #3): key resolution is off the event loop

Of the two blocking spots named above, the KeyBroker round-trip is resolved: the request path
calls `KeyBroker->key_async`, which answers from an in-memory cache, coalesces concurrent misses
for one reference, and reaches `KeyBroker::OpenBao->resolve_key_async` on `Mojo::UserAgent`;
the token is renewed on a timer (`start_renewal`). `t/27-keybroker-nonblocking.t` guards it.
DBI usage writes remain synchronous, and `jsonlog` stays the recommended default for that
reason. Multiple workers exist since ADR 0010 (`serve --workers N`).

## Update (skeid k78, 2026-09-30): DBI usage writes can be written behind

The second blocking spot, looked at from its callers: every exit path of the proxy writes its
usage event *before* it renders the answer, so with a DBI store the client's own answer and
every other stream on the loop wait for an `INSERT` and its commit — on SQLite an fsync per
event, on PostgreSQL a network round-trip plus the server's commit.

`usage_store.flush_interval_ms` (sqlite and postgresql) turns on write-behind in
`UsageStore::DBI`. While the loop runs, `store` queues the event and answers
`{ ok => 1, queued => 1 }` at once; the first queued event arms a `Mojo::IOLoop->timer`, and when
it fires the whole queue is written in **one transaction**. The request no longer waits for the
database, and a burst of N events costs one commit instead of N. Queued events are written as
well when the store is let go (a reload replacing it — to *its* table, not the new one's —, the
Skeid being destroyed), before a `report` (so it counts them), before a synchronous write (so the
table keeps arrival order), by `$skeid->flush_usage`, and from an `END` block in `bin/skeid`
when the server stops.

It stays within this ADR and within the store contract of ADR 0004:

- **It is amortised, not off the loop.** The flush is still a synchronous DBI call on the event
  loop — once per interval instead of once per request. Truly asynchronous writes need
  `DBD::Pg`'s `pg_async` with a reactor watcher on its socket (what `Mojo::Pg` does), which
  exists for PostgreSQL only, cannot be exercised by an offline test suite, and would still
  have a blocking connect. Not done; `jsonlog` remains the recommended default because it has
  nothing to amortise.
- **Every event gets the same one attempt it had before.** A failing batch is rolled back.
  With the handle still alive the events are written one by one, so a single event a constraint
  rejects loses only itself; with the handle dead it is reconnected once and the batch retried
  once (skeid k71), and a reconnect that fails loses the batch after one attempt, not one per
  event. Nothing is retried later, nothing waits.
- **A lost event is still said.** It can no longer come back through the request's own
  `usage.record` answer — that went out as "queued" — so the store hands it to
  `Skeid->on_usage_lost`, which the proxy sets to the same `usage event lost: request_id=…
  store=… api_key_id=… model=… status=…` error line as before (skeid k70); never a DSN or key.
- **No new dependency.** `DBI` stays a runtime `require`; the timer is Mojolicious, already
  required.

The price is the loss window, which is why it is **off by default** (`0` = the synchronous
write every deployment had). ADR 0004 accepts losing the one event of a request that was
in flight when the process crashed; with write-behind a process that dies without a flush loses
every event queued in the last interval — requests that were answered and are billable. What
still flushes: a single process on `SIGINT`/`SIGTERM`, a prefork worker on a graceful stop
(`SIGQUIT`). What does not: `SIGKILL`, an OOM kill, and a prefork server stopped with
`SIGTERM`/`SIGINT`, whose manager `SIGKILL`s its workers (Mojolicious's own behaviour — the
in-flight requests of those workers are lost today as well). An operator choosing write-behind
chooses the interval as the size of that window. Whether the saving is worth it on a given
database is a measurement for `bench/` (ADR 0007), not a claim this update makes.

`t/66-usage-dbi-write-behind.t` guards it: the default still inserts at once; with write-behind
the proxy answers before the row exists and `request.start`/`request.finish` stay paired; the
timer, `disconnect`, a store replaced on reload, destroying the Skeid, a report and
`flush_usage` all write the queue; three queued events take one transaction; a bad event, a
dropped table and a dead database each end in reported, never silent, losses.

**Stopping (skeid k84).** The Docker image sets `STOPSIGNAL SIGQUIT`, so `docker stop` is the
graceful stop and write-behind loses nothing on it. Under prefork the manager answers
`SIGTERM` by `SIGKILL`ing its workers, which is where the queue would go; `SIGQUIT` lets them
finish and run `END`. A single process handled `SIGINT`/`SIGTERM` only — `Mojo::Server::Daemon`
installs no `SIGQUIT` handler, so the image's stop signal would have killed it unflushed —
and `bin/skeid` now stops the loop on `SIGQUIT` as well. `docker stop` still `SIGKILL`s after
its grace period (10 s by default), which loses the queue again for a stream that outlives it;
whoever enables write-behind sets `stop_grace_period` (compose) or `--time` to match. Under
compose the image's signal is used as is; `examples/service/` sets no `stop_signal`.
