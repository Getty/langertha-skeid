# ADR 0010 — Workers partition max_conns, and everything in the background scales with them

- Status: accepted
- Date: 2026-08-09
- Tags: performance, deployment, admission, prefork

## Context

`bin/skeid serve` runs one `Mojo::Server::Daemon`: one process, one event loop, one CPU. For an
async proxy that never blocks that is further than it sounds, but it is still one core, and
the measurements say the ceiling arrives early.

From `docs/bench/2026-08-08-baseline.md`, json at concurrency 16:

| | throughput | TTFT p50 |
|---|---|---|
| upstream direct | 188.1 req/s | 83.3 ms |
| Skeid, one process | 128.1 req/s | 120.4 ms |
| Skeid, prefork 4 | 177.7 req/s | 87.2 ms |

At concurrency 32 prefork reaches 350 req/s. The decomposition is the part that settles it: a
*minimal* Mojolicious pass-through that does nothing but forward costs 6.57 ms of loop time per
request, and Skeid costs 7.81 ms. Only 1.2 ms of that is Skeid's own logic. There is no
micro-optimisation available worth 40% — the remaining cost is HTTP and JSON, and the only way
past it is more loops.

The reason this was not simply switched on is that `inflight` and `max_conns` are per-process
state. With N workers each admits up to `max_conns` to a node that can only serve one number,
so `max_conns: 8` with 4 workers permits 32. Silently. That is the actual design question.

## Decision

`serve --workers N` runs `Mojo::Server::Prefork`, and **each worker's `max_conns` is the
configured value divided by N**, rounded down, minimum 1.

- Partitioning needs no coordination and adds no failure mode. It is the same answer ADR 0009
  gives for multiple frontends, and it is deliberately the conservative one: N workers never
  admit more than the operator configured.
- The cost is wasted capacity under uneven load — one worker can be at its share while another
  idles. That is accepted. Over-admitting a GPU is a timeout for every request on it;
  under-admitting is some idle capacity.
- **`max_conns` below the worker count cannot be honoured.** Each worker needs at least 1, so
  `max_conns: 2` with 4 workers admits 4. Skeid warns loudly at startup rather than pretending;
  the fix is fewer workers or a larger `max_conns`, and only the operator can pick.
- A node with a **capacity probe** (ADR 0009) is not subject to this arithmetic in any
  meaningful way: every worker reads the same truth from the node itself, including the other
  workers' traffic. Partitioned `max_conns` stays the per-worker guardrail, and a probe may
  still only narrow it. Probing is the better answer where it is available; partitioning is
  what works everywhere.

**Everything that runs on a timer runs once per worker**, and that is the part that is easy to
miss. With 4 workers, a 2-second capacity probe polls a node every 500 ms, and the vault sees 4
token renewals per period.

- Capacity probe intervals are **multiplied by the worker count**, so the aggregate poll rate
  across the process group matches what the operator configured. `interval_ms: 2000` with 4
  workers means each worker polls every 8 s.
- Vault token renewal is *not* scaled: each worker holds its own token in its own memory and
  each one has to keep its own alive (ADR 0003). N logins is the correct number, not an
  inefficiency to optimise away.
- Each worker keeps its own probe readings and its own `inflight`. They are not merged, and
  `/skeid/metrics/nodes` therefore answers for whichever worker took the request. A report that
  needs the whole picture has to come from the usage store, which is shared.

## Consequences

- The usage store becomes a multi-writer store. `jsonlog` in directory mode is safe by
  construction (one file per event) and stays the recommended default. `postgresql` is fine.
  **SQLite under prefork is a lock contention risk** and is not recommended above one worker.
- `--workers` defaults to 1, so nothing changes for an existing deployment until it is asked
  for. It is a flag, not a new default: a box that is running Skeid next to other services
  should not silently take four cores.
- Admin API writes (`nodes.add`, health flips) reach **one** worker. They were already
  process-local and already lost on config reload; with workers they are also inconsistent
  between them. The config file is the declared state — this makes that stop being a stylistic
  preference and start being the only workable path.
- Node inventory and policy are re-read per worker from the same file, so they agree. Anything
  that is *only* in memory does not.
- Not decided here: whether workers should share admission state at all (rejected for now for
  the reasons in ADR 0009 — a round-trip on the admission path), and whether the manager
  process should own the probes and distribute readings. The second is worth revisiting if
  probe load ever shows up in a measurement.
