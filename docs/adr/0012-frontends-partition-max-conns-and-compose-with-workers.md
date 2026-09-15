# ADR 0012 — Frontends partition max_conns too, and compose with workers

- Status: accepted
- Date: 2026-09-15
- Tags: admission, deployment, partitioning, multi-instance

## Context

`inflight` is per-process (ADR 0009). One Skeid in front of one node counts exactly what it
sent; the moment a second counter shares the node — a prefork worker, or a second Skeid host —
each sees only its own share and together they over-admit. ADR 0009 named both cases and offered
**static partitioning** as the interim answer: configure each instance with `max_conns / N`.
ADR 0010 built one half of that, the prefork-worker axis — `worker_max_conns` is
`max_conns / worker_count`, floored, minimum 1, with a startup warning when the split cannot be
honoured.

The other half was never built. Two Skeid hosts in front of one node, no capacity probe, is a
different kind of ignorance from prefork: there the shared thing is one process's own admission
state, so `worker_count` is a launch parameter this process already knows. Here the frontends
are separate processes on separate machines with nothing between them — no shared state (rejected
in ADR 0009 for the round-trip it puts on the admission path) and, by assumption, no probe. So
nothing can *detect* how many frontends there are. Only the operator knows, and each frontend
has to be told its share.

This was deferred on 2026-09-10 (karr k14) as low value: the manual workaround already exists
(set `max_conns` to the per-frontend share by hand), and a Prometheus probe makes the question
vanish because both frontends then read the node's real occupancy. **The user overruled that
deferral on 2026-09-15 — build the divisor now.** Recorded here so the history stays honest: the
reasons for deferring still hold for a deployment that has a probe, and this field is for the one
that does not.

## Decision

Add an explicit `frontend_count`, the frontend-axis twin of `worker_count`.

- Configured as `routing.frontend_count` (or `SKEID_FRONTEND_COUNT`), default **1** — a
  single-frontend deployment is unchanged, byte for byte.
- The two divisors **multiply**. `worker_max_conns` is now
  `max_conns / (frontend_count * worker_count)`, floored, minimum 1 when a limit is set. So the
  whole deployment — F frontends each running N workers — never admits more than the operator
  configured for the node.
- Partitioning reads as "across frontends first, then across workers", but integer division
  composes: `floor(floor(max/F)/N) == floor(max/(F*N))`, and the min-1 clamp lands on the same
  value either way, so the order is a description, not a computation. The combined divisor is the
  only number admission needs.
- `max_conns` below that combined process count cannot be honoured — each process floors to 1, so
  the group admits at least F×N. Skeid warns loudly at startup, naming which axes do not divide
  (frontends, workers, or both) and the matching fix, because the operator can only shed what
  they configured.

**A divisor, not hand-set `max_conns`.** The manual workaround works, but it is the value already
pre-divided — it cannot warn when it stops fitting, and it does not compose: an operator running
frontends *and* prefork would have to divide by both axes themselves and redo it whenever either
changes. An explicit divisor is the same declared-state config every frontend already carries, it
warns, and it stacks with the worker divisor for free.

**It is not scaled on any timer** — and this is the one place it diverges from ADR 0010. There,
everything on a timer runs once per worker, so probe intervals are multiplied by `worker_count`
to keep the node's poll rate what was configured. Frontends are separate processes on separate
hosts: each runs its own probes against the node and holds its own vault token, exactly the
reason vault renewal is deliberately *not* scaled per worker in ADR 0010. F frontends polling a
node F times per interval is the correct rate, not an inefficiency — each is an independent
observer. `frontend_count` therefore touches admission arithmetic only, never a timer.

## Consequences

- Every frontend host carries the same `frontend_count` in the same declared config, the same way
  they already share nodes, policies and aliases. A host that disagrees mis-sizes its own share;
  the file is the source of truth (ADR 0010).
- A node with a **capacity probe** (ADR 0009) does not need this. Both frontends read the node's
  real occupancy, including each other's traffic, so the divisor is redundant there — it is for
  the node with no metrics endpoint. Partitioned `max_conns` stays the guardrail, and a probe may
  still only ever narrow it, never widen it.
- The divisor wastes capacity under uneven load — one frontend can be at its share while another
  idles — which is the same accepted cost as ADR 0010. Over-admitting a GPU is a timeout for every
  request on it; under-admitting is some idle capacity, and for a rented node `max_conns` is a
  spend limit that must hold.
- `worker_max_conns` keeps its name and its role as "this process's share"; a process is one
  worker of one frontend, and the method now accounts for both axes. `worker_share_warnings`
  likewise reports the combined split.

## As implemented

| piece | where |
|---|---|
| `frontend_count` attribute, `SKEID_FRONTEND_COUNT` default | `Langertha::Skeid` |
| combined divisor, share, min-1 | `_admission_divisor`, `worker_max_conns` |
| startup warning naming the axes | `worker_share_warnings`, printed by `bin/skeid` |
| `routing.frontend_count` on config load and reload | `Langertha::Skeid::reload_config` |
| tests | `t/35-frontend-share.t` (default unchanged, division, warning, admission, composition, config reload); `t/30-worker-share.t` still covers the worker axis alone |

Not decided here: nothing new. The open questions from ADR 0009 and 0010 — poll interval, whether
a reading should influence weighting, whether workers should ever share admission state — are
unchanged, and none of them is reopened by adding a second static divisor.
