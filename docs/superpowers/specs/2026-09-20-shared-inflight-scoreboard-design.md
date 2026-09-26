# Design — Shared inflight scoreboard for same-box worker admission

- Status: approved design, not yet implemented
- Date: 2026-09-20
- Companion ADR: `docs/adr/0014-same-box-worker-admission-uses-a-shared-inflight-scoreboard.md`
- Vocabulary: `CONTEXT.md` (Node, Admission, Inflight, Worker share, Capacity probe, Capacity reading)

## 1. Problem

`inflight` is per-process (ADR 0009). Under `--workers N` prefork, `max_conns` is
statically partitioned into a **worker share** of `max_conns / (frontend_count *
worker_count)`, floored, minimum 1 (ADR 0010, ADR 0012). Partitioning needs no
coordination and never over-admits, but it wastes capacity under uneven load: one
worker refuses at its share while siblings idle below theirs.

A throwaway discrete-event simulation (documented in the ADR) quantified how much
node throughput an **exact shared count** recovers over the static share, near
saturation (offered load ~0.9x capacity), as *good balancer -> imperfect
balancer*:

| worker share = `max_conns/N` | example (1 host) | throughput recovered |
|---|---|---|
| 1 | `max_conns 8`, 8 workers | 16 - 28 pp |
| 2 | `max_conns 8`, 4 workers | 10 - 18 pp |
| 4 | `max_conns 16`, 4 workers | 8 - 14 pp |
| 8 | `max_conns 32`, 4 workers | 6 - 11 pp |
| 16 | `max_conns 64`, 4 workers | 5 - 8 pp |

Rows assume a single host (`frontend_count = 1`), which is the axis the scoreboard
addresses; with multiple frontends it recovers only the worker-axis share of this.
The waste is governed by the per-process share: below ~8 it is double digits under
imperfect balancing. LLM serving has inherently small concurrency limits (long,
streaming requests), so small shares are the normal case here, not a corner — the
ADR 0010 worked example itself (`max_conns 8`, 4 workers -> share 2) sits in the
10-18 pp band.

## 2. Goals and non-goals

**Goals**
- Make admission across the prefork workers of **one host** use the exact node-wide
  inflight instead of a static per-worker share.
- Reintroduce **no** new failure mode that partitioning did not have — in
  particular, no unrecoverable count drift when a worker dies mid-request.
- Plug into the existing admission path (ADR 0009); a capacity probe still only
  ever narrows what admission allows.
- Correctness and fitness for our purposes first; performance is measured later and
  does not drive design decisions.

**Non-goals**
- The **frontend axis** (separate Skeid hosts, ADR 0012). Shared memory cannot
  cross hosts; multi-frontend deployments keep `frontend_count` partitioning or a
  capacity probe.
- A general-purpose shared-memory library. This is a single purpose-built primitive
  living inside Skeid.
- Cross-process rate limiting, shared capacity readings, or any structure beyond the
  inflight scoreboard (explicitly deferred; the segment leaves room to add them).
- Windows / non-fork servers, and 32-bit platforms.

## 3. Decisions carried in from brainstorming

1. **Per-worker rows, never one shared counter.** Each worker owns a row and is the
   sole writer of its own cells. A shared per-node counter would be multi-writer and
   its increments unattributable, so a dead worker's outstanding count could never
   be reclaimed — the exact unrecoverable drift partitioning avoids. Per-worker rows
   keep every increment attributable to a pid the manager can zero.
2. **The scoreboard replaces the worker (N) divisor, not the frontend (F)
   divisor.** For a node with an active scoreboard, admission is `sum of this
   host's worker inflight < max_conns / frontend_count` (floored, minimum 1).
   Shared memory cannot cross hosts, so the frontend divisor stays; the scoreboard
   removes only the `worker_count` division, by measuring one host's workers
   exactly. When `frontend_count = 1` (single host — the primary target) that is
   the full, undivided `max_conns`. Keeping the per-worker static share on top would
   leave the worker-axis loss in place. External capacity probes (ADR 0009) still
   narrow further; the scoreboard replaces the *static worker divisor*, not the
   probe contract.
3. **Node -> slot via a shared, CAS-claimed registry.** A small `node_id -> column`
   registry, claimed on first contact by whichever worker sees the node first
   (config or admin API). Columns are stable for the segment's lifetime, so config
   reload causes no re-layout churn.
4. **Mandatory XS, POSIX/fork only.** Skeid becomes an XS distribution. The segment
   is an anonymous `mmap(MAP_SHARED|MAP_ANONYMOUS)`, so there is no name, no
   registry file, no relocatable offsets, and no ABI negotiation between strangers.

## 4. Architecture and lifecycle

New XS module: `Langertha::Skeid::Scoreboard`.

- **Segment creation.** The segment is created once, when the Skeid app is built in
  the prefork **manager**, before `Mojo::Server::Prefork->run`. Because the manager
  forks workers after the app is built, the anonymous `MAP_SHARED` mapping is
  inherited by every worker (verified against Mojo::Server::Prefork 9.49).
- **Manager role.** Owns the segment; touches no counters. Subscribes to the reap
  event — `$prefork->on(reap => sub { my ($prefork, $pid) = @_; ... })` — and on
  each reaped pid zeroes and frees that worker's row (`Prefork.pm:64` emits `reap`
  with the pid). The manager restarts dead-heartbeat workers (`Prefork.pm:123`), so
  reap fires for SIGKILLed workers too.
- **Worker role.** On startup, claims a row keyed by its pid. On `request.start` /
  `request.finish` it increments / decrements only its own cell for the node. For
  admission it reads the column sum.
- **Respawn.** Mojo respawns workers dynamically, so rows are claimed by pid at
  worker startup and freed by the manager on reap — never fixed by worker number.

Lifecycle order: build Skeid -> create segment -> prefork forks -> each worker
claims a row -> serve. Worker dies -> manager reap zeroes+frees its row -> Mojo
respawns -> new worker claims a free row.

## 5. Memory layout and claim mechanics

```
header    : magic, version, W (rows), MAX_NODES (cols), generation
row-dir   : W entries  { pid, state }                         # row claimed by pid
registry  : MAX_NODES entries { node_id[NAME_MAX], used }      # column claimed by node_id
matrix    : W x MAX_NODES  _Atomic uint64_t                    # cell[row][col] = inflight
```

- **Row claim.** Worker CASes its pid into a free `row-dir` entry (state
  empty -> claimed). O(W).
- **Column claim.** `hash(node_id)` -> open addressing in `registry`; found -> use
  the column; empty -> CAS-claim (write id, then set `used` with a release store).
  A reader sees `used` with an acquire load, so it never observes a half-written id.
  The resolved `node_id -> col` is cached per worker, so lookup is O(1) amortized.
- **Fixed caps, no dynamic allocation.** `W = worker_count + headroom` (respawn
  overlap), `MAX_NODES` default 256 (configurable), `NAME_MAX` for a node id (e.g.
  64 bytes). No freelist, no relocatable pointers — the whole segment is a fixed
  array addressed by base + index.

## 6. Data flow and admission integration

- `request.start(node)`: `col = resolve(node_id); cell[myrow][col] += 1`. Single
  writer, so a plain atomic store of the new value — no CAS. `request.finish`
  decrements.
- **Admission for a node with an active scoreboard:** `used = sum over rows of
  atomic_load(cell[row][col])`; admit if `used < max_conns / frontend_count`
  (floored, minimum 1) — the full `max_conns` when `frontend_count = 1`. This
  replaces the `worker_count` division in `worker_max_conns`, but keeps the
  `frontend_count` division, since the scoreboard sees only this host's workers. A
  capacity probe (ADR 0009) still narrows on top.
- **Seam.** Hooks the existing `request.start` / `request.finish` dispatches and a
  small change in the `_capacity_allows` / `worker_max_conns` path. No new admin or
  config concept beyond an on/off switch (Section 8).
- **Transient sum.** The summed `used` can breathe by a few counts while writers
  move — the same tolerance ADR 0009 already accepts for a reading; the error is
  bounded by W and self-correcting.

## 7. Concurrency and correctness

- **Single-writer invariant** carries the whole design: each cell has exactly one
  writer, so the counter is an `_Atomic uint64_t` updated with a plain
  load-modify-store, never a CAS. Readers use atomic loads; aligned 64-bit is
  tear-free on the target platforms.
- **CAS only on the two claims** (row and column), each once per lifetime. The
  column claim's write-id-then-set-used is the one release/acquire pair in the
  design.
- **ABA / pid reuse.** The manager frees a row (clears pid, state -> empty) on reap
  *before* any respawn can claim one, so a reused pid cannot inherit another
  worker's row. Columns are keyed by node id, not index, so ABA does not arise.
- **No memory ordering beyond the claim pair.** Cells are independent; admission
  tolerates slight staleness, so counter loads/stores need only atomicity and
  eventual visibility.

## 8. Crash and edge handling

- **Worker dies mid-request** (including a SIGKILL from Mojo's heartbeat restart):
  `waitpid` -> `reap` -> manager zeroes and frees the row. No leak; restart heals
  fully.
- **Registry or rows full** (`MAX_NODES` / `W` exceeded): fail open to today's
  behavior — that node uses per-process inflight plus the static share, with a
  `worker_share_warnings`-style warning. Never an error, never a crash.
- **`workers = 1` / non-prefork daemon** (`bin/skeid` uses `Mojo::Server::Daemon`):
  no manager, no sharing needed. The scoreboard is a no-op and admission uses exact
  per-process inflight. The feature engages only under prefork.
- **On/off switch.** A config flag (default following ADR style: unchanged behavior
  unless asked) turns the scoreboard on. This subsumes the spike's "is it worth it
  for this flotte?" decision rule — deployments with large shares or a good probe
  simply leave it off.
- **Config reload / node removed then re-added.** Columns are stable for the
  segment's lifetime; a removed node's column rests harmlessly, a re-added node with
  the same id hits the same column. No churn.
- **Teardown.** The anonymous mapping is released on process exit — no cleanup file,
  no restart leak.

## 9. XS surface and build

- **C API (small):** `sb_create(W, max_nodes)`, `sb_claim_row(pid)`,
  `sb_free_row(pid)`, `sb_col(node_id, len)`, `sb_incr(row, col)`,
  `sb_decr(row, col)`, `sb_used(col)`. Atomics via C11 `<stdatomic.h>` with a GCC
  `__atomic` fallback; no MSVC path (POSIX only).
- **Build:** Dist::Zilla + XS via `[MakeMaker::Awesome]`, which generates an
  XS-capable `Makefile.PL`; configure-requires added to `cpanfile` / dist. The
  `[@Author::GETTY]` bundle stays; only the MakeMaker portion becomes XS-aware. The
  Docker image (`perl:5.38-slim` + `build-essential`) already has a compiler; a CPAN
  install now needs one (intended — "XS is mandatory").
- **Portability guard:** build/load asserts `MAP_ANONYMOUS` and 64-bit atomics; if
  absent, the build fails rather than silently doing the wrong thing. 32-bit is out
  of scope.

## 10. Testing (correctness gates; performance later)

- **Unit:** claim / incr / decr / used; column-claim idempotence; registry-full
  fallback.
- **Fork race:** N workers hammer incr/decr on one node; the invariant `used == sum
  of actual inflight` holds; made deterministic via test timing hooks (the
  Skeid / Shared::Arena style), not luck.
- **Crash:** kill a worker with open inflight -> assert the manager zeroes its row
  and `used` recovers; counter-check that a slow worker is not mistaken for a dead
  one.
- **Integration:** an ADR 0009 probe still narrows *above* the scoreboard;
  `workers = 1` is a no-op; the static share remains the fallback.
- **Performance:** a dedicated `bench/` entry measures the admission path with and
  without the scoreboard against `fakellm` — done **later**, not a design gate.

## 11. Deferred / open

- Column reclamation for long-lived processes that churn many distinct node ids
  (harmless leak of columns until segment reset; revisit only if `MAX_NODES` proves
  tight).
- Frontend axis and shared capacity readings — out of scope here; the segment
  leaves room to add readings later (ADR 0010's open "manager distributes readings"
  question).
- `MAX_NODES`, `W` headroom, and `NAME_MAX` defaults — set conservatively, tune if a
  real deployment needs it.

## References

- ADR 0009 (capacity is probed, not only counted), ADR 0010 (workers partition
  max_conns), ADR 0012 (frontends partition and compose).
- `CONTEXT.md` vocabulary.
- Throwaway simulation `partition_vs_shared.py` (spike, not committed); results
  summarized in Section 1 and ADR 0014.
