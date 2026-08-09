# ADR 0009 — Node capacity is probed, not only counted

- Status: accepted — implemented (`inflight`, `ratelimit`, `prometheus`, `custom`)
- Date: 2026-08-08
- Tags: admission, capacity, observability, multi-instance

## Context

`inflight` is a per-process counter: Skeid increments on `request.start`, decrements on
`request.finish`, and admits while it stays under the node's `max_conns`. With one Skeid in
front of two local GPUs that is exact.

It stops being exact the moment anything else sends work to the same node — a second Skeid
frontend, a prefork worker (ADR 0005, karr #7), a batch job, or an engineer with `curl`. Each
counter then sees only its own share and every instance believes the node is less loaded than
it is, so they collectively over-admit. Two frontends with `max_conns: 8` push 16.

The usual answer is shared state: Redis with an atomic counter per node. That puts a network
round-trip on the admission path — the exact path measured as latency-critical in
`docs/bench/2026-08-08-baseline.md` — and makes routing depend on another service being up.

The better observation is that Skeid is reconstructing, by counting, a number the upstream
already publishes. vLLM and SGLang export running and waiting request counts and KV-cache
utilisation. That is ground truth, it includes traffic Skeid never saw, and reading it is a
background poll rather than per-request work.

Commercial providers do not publish queue depth. What they do publish, on every response, are
rate-limit headers (`x-ratelimit-remaining-requests` / `-tokens`, `anthropic-ratelimit-*`,
provider-specific spellings) plus `Retry-After` on `429`. Those arrive on responses Skeid
already receives, so reading them costs nothing at all.

## Decision

Capacity is a **probe** on the node, with a normalized reading, and `inflight` becomes one
implementation of that contract rather than the only source of truth.

| probe | for | cost |
|---|---|---|
| `inflight` | default; preserves today's behaviour | none |
| `prometheus` | vLLM, SGLang, TGI — URL and metric names configurable | one poll per node per interval |
| `ratelimit_headers` | commercial providers; read passively from responses | none |
| `custom` | anything else — coderef or class name | caller's problem |

Rules:

- **Probing never happens on the request path.** Polling is a timer; header reading is a
  by-product of a response already in hand.
- All probes answer in one shape, so admission does not know or care where the number came
  from. `unknown` is a valid answer and falls back to `inflight`.
- Skeid is generic, so `custom` is part of the contract, not an escape hatch bolted on later.
  The built-in probes are conveniences for the common engines.
- A stale probe reading is worse than none. Readings carry an age, and one older than a
  configured limit degrades to `inflight` rather than being trusted.

Until probing exists, multiple frontends and multiple workers use **static partitioning**: each
instance is configured with `max_conns / N`. Capacity is wasted when load is uneven, but it
needs no coordination and introduces no new failure mode. It is also the same answer the
prefork question needs.

Shared state (Redis/Valkey) is explicitly **not** chosen: it buys accuracy that probing gets
for free, at the price of a round-trip on the admission path and a dependency whose outage
takes routing with it.

## Consequences

- Multiple frontends stop needing to know about each other. They read the same truth from the
  node instead of exchanging estimates.
- Reacting to a provider's `429` / `Retry-After` means an error path starts writing node state.
  `CONTEXT.md` flags exactly this as needing a decision before it happens: **this ADR is that
  decision, and it is narrow.** A `429` adjusts a probe reading and a backoff timer. It does
  **not** touch the `healthy` flag, which stays operator state — a rate-limited node is busy,
  not broken, and nothing would ever flip it back.
- Two admission regimes now exist, and they map onto the tiers of ADR 0008: nodes we run are
  measured, nodes we rent are inferred. Reports must not present the two as equally reliable.
- `max_conns` keeps a distinct meaning per regime: a capacity limit for self-hosted nodes, a
  cost guardrail for rented ones.
- Not decided here: what the poll interval should be, and whether a probe should influence
  weighting as well as admission (routing preferentially to the emptier of two healthy nodes).
  Both need measurement first.

## As implemented

One rule was added that this ADR did not state and that everything else rests on: **a probe may
only narrow what `max_conns` already allows, never widen it.** `_node_can_take` asks both, and
they are not symmetric — `max_conns` is this process's own guardrail and always applies. If a
reading could raise it, a stale or broken probe would become an overload, and for a rented node
`max_conns` is a spend limit that a provider reporting spare capacity must not be able to lift.

| piece | where |
|---|---|
| reading, staleness, admission rule | `Langertha::Skeid` — `set_capacity_reading`, `capacity_reading`, `forget_capacity`, `capacity_max_age_ms` (5s) |
| `ratelimit` | `observe_response_headers`, called by the proxy from responses it already holds |
| `prometheus`, `custom` | `Langertha::Skeid::CapacityProbe` and its subclasses, started by `build_app`, polled on a timer |
| tests | `t/28-capacity-probe.t`, `t/29-capacity-probe-prometheus.t` |

Details that turned out to matter:

- `used` for a Prometheus node is `running + waiting`. A queued request occupies the node as
  surely as a running one; admitting more because they are "only waiting" turns a queue into a
  timeout.
- Every failure path reports *nothing* rather than something old — unreachable endpoint,
  unrecognised metric names, a probe that dies. Admission then degrades to `inflight`, which is
  imprecise; a kept reading would be confidently wrong.
- A pending backoff deliberately outlives `capacity_max_age_ms`. An observation goes stale; a
  provider saying "not for another 30 seconds" is a statement about the future.
- A rate-limit header with no matching limit header is read as "one more than remains", which
  is enough to stop admitting at zero without inventing a ceiling.
- Providers meter requests *and* tokens, and for an LLM API the token budget is normally what
  runs out first — a node with requests to spare and no tokens left answers `429` all the same.
  Both quotas are read and the one closest to exhausted decides, compared as a fraction since
  the units differ.
- Probes follow a config reload: the inventory generation is compared per request and probes
  are rebuilt when it moves, or they poll for nodes that no longer exist.

Still open, unchanged: the poll interval (2s is a starting point, not a finding) and whether a
reading should influence weighting as well as admission.
