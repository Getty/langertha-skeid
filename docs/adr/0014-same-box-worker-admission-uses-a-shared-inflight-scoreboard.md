# ADR 0014 — Same-box worker admission uses a shared inflight scoreboard

- Status: accepted — design approved, not yet implemented
- Date: 2026-09-20
- Tags: admission, capacity, prefork, performance, xs, shared-memory

## Context

`inflight` is per-process (ADR 0009). Under `--workers N` prefork, `max_conns` is
statically partitioned into a **worker share** of `max_conns / (frontend_count *
worker_count)`, floored, minimum 1 (ADR 0010, ADR 0012). Partitioning needs no
coordination and never over-admits, but it wastes capacity under uneven load: one
worker refuses at its share while its siblings idle below theirs.

A throwaway discrete-event simulation measured how much node throughput an exact
shared count recovers over the static share, near saturation (offered load ~0.9x
capacity), as *good balancer -> imperfect balancer*:

| worker share = `max_conns/N` | example (1 host) | throughput recovered |
|---|---|---|
| 1 | `max_conns 8`, 8 workers | 16 - 28 pp |
| 2 | `max_conns 8`, 4 workers | 10 - 18 pp |
| 4 | `max_conns 16`, 4 workers | 8 - 14 pp |
| 8 | `max_conns 32`, 4 workers | 6 - 11 pp |
| 16 | `max_conns 64`, 4 workers | 5 - 8 pp |

(Rows assume `frontend_count = 1` — the axis the scoreboard addresses.)

The waste is governed by the per-process share; below ~8 it is double digits under
imperfect balancing. LLM serving keeps concurrency limits small (long, streaming
requests), so small shares are the normal case here — the ADR 0010 worked example
itself (`max_conns 8`, 4 workers -> share 2) sits in the 10-18 pp band.

ADR 0009 rejected shared admission state on the request path when the shared thing
would be Redis — a round-trip on the latency-critical path and an outage dependency.
That reasoning holds for a network service. It does not hold for the prefork workers
of **one process on one host**, which already share a parent, a fork, and a manager
that reaps them. There the shared state can be a page of memory the workers inherit,
with no round-trip and no new daemon.

The naive form of that — one shared counter per node that every worker
increments — is rejected for a different reason: a shared counter is multi-writer
and its increments are unattributable, so a worker that dies mid-request leaks an
increment that can never be reclaimed. That is a worse failure than partitioning
(silent, monotonic under-admission versus some idle capacity), and it is exactly the
crash-recovery problem the rest of Skeid is designed to avoid.

## Decision

Add an optional, purpose-built **shared inflight scoreboard** for the prefork
workers of one host, as new mandatory XS (`Langertha::Skeid::Scoreboard`). Full
design in `docs/superpowers/specs/2026-09-20-shared-inflight-scoreboard-design.md`.

- **Per-worker rows, not a shared counter.** The segment is a `W x MAX_NODES` matrix
  of 64-bit counters in an anonymous `MAP_SHARED` mapping created by the manager
  before it forks, inherited by every worker. Each worker owns one row and is the
  sole writer of its own cells, so a plain atomic store suffices and every
  increment stays attributable to a pid. Node `used` is the sum of the column.
- **The scoreboard replaces the worker (N) divisor, not the frontend (F) divisor.**
  For a node with the scoreboard active, admission is `sum of this host's worker
  inflight < max_conns / frontend_count` (floored, minimum 1) — the full,
  undivided `max_conns` when `frontend_count = 1`. Shared memory cannot cross hosts,
  so the frontend divisor stays; the scoreboard removes only the `worker_count`
  division by measuring one host's workers exactly. Keeping the per-worker static
  share on top would leave the worker-axis loss in place. A **capacity probe still
  only ever narrows** on top (ADR 0009 unchanged); the scoreboard replaces the
  *static worker divisor*, not the probe contract.
- **Node -> column via a small CAS-claimed registry** (`node_id -> col`), claimed on
  first contact by whichever worker sees the node first, config or admin API.
  Columns are stable for the segment's lifetime, so config reload causes no
  re-layout churn.
- **The manager reaps, so it reclaims.** On `reap => $pid` it zeroes and frees that
  worker's row, which is why a shared counter's unrecoverable leak does not happen
  here. Rows are claimed by pid at worker startup, never fixed by worker number,
  because Mojo respawns workers dynamically.
- **Mandatory XS, POSIX/fork only.** Anonymous inherited mapping means no name, no
  registry file, no relocatable offsets, no ABI negotiation. No Windows path, no
  32-bit.
- **Off by default.** A config flag turns it on; unchanged deployments behave byte
  for byte as before. This is where the "is it worth it for this flotte?" decision
  lives: a deployment with large shares or a good capacity probe leaves it off.

## Consequences

- **Skeid becomes an XS distribution.** Every install now needs a C compiler; the
  Docker image already has one (`perl:5.38-slim` + `build-essential`). This is the
  real cost of the decision — the C itself is a page of memory and one atomic
  add.
- **Same-box only.** The scoreboard fixes the `worker_count` axis. The
  `frontend_count` axis (separate hosts, ADR 0012) cannot be helped by shared memory
  and keeps partitioning or a capacity probe. Reports must not present a
  scoreboard-corrected node and a partitioned one as equally precise.
- **`max_conns` keeps its meaning.** It is still the node-wide limit; the scoreboard
  just measures occupancy against it exactly instead of dividing it. A probe may
  still only narrow it, never widen it (ADR 0009).
- **A new failure is deliberately avoided, not traded in.** Registry/row exhaustion
  and non-prefork mode fail open to today's per-process behavior; a dead worker's
  row is reclaimed by the manager. The scoreboard never admits more than `max_conns`
  and never leaks a permanent count.
- **Not decided here:** column reclamation for processes that churn many distinct
  node ids, shared capacity readings (ADR 0010's open "manager distributes readings"
  question), and the `MAX_NODES` / row-headroom defaults. All deferred; the segment
  leaves room for readings later.

## As implemented

Not yet implemented. To be filled in when the XS lands, in the manner of ADR
0009/0012: the module, the admission seam, the config flag, and the tests.
