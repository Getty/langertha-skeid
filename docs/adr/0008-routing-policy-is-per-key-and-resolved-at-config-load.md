# ADR 0008 — Routing policy is per key, resolved at config load

- Status: accepted — implemented (node tags, aliases and tiers, per-key policy assignment)
- Date: 2026-08-08
- Tags: routing, policy, config, tiers, aliases

## Context

Skeid today routes on the request alone: a model name filters the node inventory, and weighted
round-robin picks from what matches. Who is asking is irrelevant except for metering.

That cannot express what the service actually sells. Customers differ in where their traffic
may go: some spill to a specific cloud when the local GPUs are full, some must never leave the
local cluster, some want a different cloud per model, and some buy a model name that does not
correspond to any single upstream. These are not a handful of flags — every factor is set
deliberately per customer, on top of a small number of standard setups that most customers
take unchanged.

A naive shape (a policy object per API key) makes ten thousand keys with identical settings
cost ten thousand copies, and puts config parsing on the request path.

## Decision

Introduce **routing policy** as a first-class thing between the request and the node set, with
three layers:

- **Node tags.** Nodes carry `tags` (`[local, gb10]`, `[cloud, groq]`). Grouping is by tag,
  never by node id — ids are too brittle to build policy on, and tags also carry data
  residency and hardware class later.
- **Model alias.** A client-facing model name maps to an ordered list of **tiers**. This is
  how "our own made-up model names" and "this cloud is the fallback for that model" become the
  same mechanism.
- **Tier.** A tag selector plus its own wait window. The wait becomes per tier, not global:
  "wait up to 200ms for a local GPU before paying for cloud" is the operationally interesting
  knob, and `route_wait_timeout_ms` cannot express it.

**Policies are named profiles; keys reference them.**

```yaml
policies:
  standard-local-only: { deny_tags: [cloud] }
  standard-with-cloud: {}
default_policy: standard-local-only
keys:
  k_5f0e1a2b3c4d: standard-with-cloud                                  # alice
  k_9c8b7a6f5e4d: { policy: standard-with-cloud, models: [house-model] } # bigcorp
```

Keys not listed take `default_policy`, so ten thousand identical customers are zero entries.
Profiles and overrides are resolved **once, at config load**, into immutable policy objects;
identical resolutions are shared by reference. A request costs one hash lookup — no parsing, no
copying, no vault round-trip.

Derived node lists — which nodes a selection matches, their round-robin order and their weights
— are computed once per selection and reused until the inventory changes. Every path that can
change the inventory bumps a generation counter that drops the cache, including a direct
assignment through the public `nodes` accessor.

This is a correctness-shaped mechanism, not a performance one, and the measurement says so: at
8 nodes it makes no difference at all (127.3 vs 126.5 req/s, less than the spread between two
runs of the same code), and only at 100 nodes does it show as ~4% (127.5 / 126.5 vs 122.5).
It is kept because tier fall-through performs several selections per request and because the
policy layer needs resolved selections anyway — not because routing was slow.

Fall-through between tiers is triggered by **failed admission**, not failed eligibility. The
failure modes stay distinct, as in ADR 0002:

- alias unknown → `503`
- alias known but not granted to this key → `403`
- all *permitted* tiers saturated → wait per tier, then `429`

A tier the policy forbids is not merely deprioritised — it is invisible to eligibility for that
key, so no ordering bug can route a request into a cloud the customer excluded. The denial is
applied at node selection as well as to the plan: an alias is a product name, not a security
boundary, and denying the cloud tier of an alias would be worthless if the same node still
answered to its own model name.

**Identity is derived, never asserted.** A policy hangs off the customer key id, so that id may
only come from something the caller had to prove — the API key they presented
(`Langertha::Skeid->key_id_for_key`, printed by `skeid keyid`). Skeid previously took
`x-skeid-key-id` from the client, which was already a way to bill a request to somebody else
and would now be a way to select somebody else's permissions in one header line. The header is
honoured only under `routing.trust_key_id_header`, for deployments that authenticate in front
of Skeid and set it themselves.

The cost is that the config names customers by a derived id rather than by name, which is why
`skeid keyid` exists. A mapping from real keys to readable names belongs next to the keys in
OpenBao, not in a file — that is left open here.

## Consequences

- Config becomes the security boundary for data residency. `t/26-key-policies.t` exists to
  prove a forbidden node is unreachable for a key — by the alias, by the node's own model name,
  and when the permitted nodes are full — and was verified to fail when the node-level filter
  or the header check is removed.
- Naming customers by derived key id makes the config less readable and makes key rotation a
  config change. Accepted: the alternative is either customer keys in a file or an
  authorization decision based on a header the customer writes.
- `usage_report` gains a natural grouping by policy, which is what billing actually wants.
- YAML is the source of truth. A per-key policy field in OpenBao, next to the customer key,
  can be added later without changing this model — the resolution point stays the same.
- The alias layer means the model a client asks for and the model a node serves are no longer
  the same string. Usage events must record both, or cost attribution silently breaks.
- Per-tier waiting multiplies worst-case latency by the number of tiers. Tier wait windows must
  be small and their sum bounded by the request timeout.
- The derived-list cache introduces an invariant that fails silently when broken: a stale list
  keeps routing to a node that was drained or removed. Every inventory mutation must bump the
  generation, and `t/24-node-tags.t` exists to prove it — verified to fail when the bump is
  removed.
