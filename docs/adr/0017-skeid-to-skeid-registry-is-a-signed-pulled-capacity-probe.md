# ADR 0017 — The Skeid-to-Skeid registry is a signed, pulled capacity probe

- Status: accepted — implemented (skeid #18)
- Date: 2026-09-25
- Tags: admission, capacity, multi-instance, registry, security

---

## Context

A Skeid can front other Skeids: a fronting tier behind a VIP, N downstream Skeids each in
front of their own GPUs. The fronting tier then picks a downstream without knowing which one
is hot. Its own `inflight` per downstream undercounts the moment any other path sends traffic
there — the over-admission ADR 0009 describes, one tier up.

ADR 0009's answer for a node that publishes its load is a probe. The Prometheus probe does
not fit here: a downstream Skeid does not speak Prometheus, and making it publish a metric
just to feed the fronting tier would be wrong. Skeid already knows its per-node `inflight`,
its per-node errors and its own capacity readings, in memory, in real time.

The ticket left the transport open (webhook push, a NATS/Redis dependency, or a Skeid route).
The ruling of 2026-09-25 settled it: pull over a Skeid admin route, polled by a probe, with no
new dependency.

## Decision

**A downstream Skeid publishes a signed snapshot on an admin route. The fronting tier pulls it
with `CapacityProbe::Registry`. The probe has the same lifecycle and staleness rules as the
Prometheus probe. It is off unless configured, on both sides.**

### Publishing (downstream)

```yaml
registry:
  enabled: true                      # default false: no route, 404
  secret_env: SKEID_REGISTRY_SECRET  # HMAC key, from the environment only
  ttl_s: 10                          # how long a snapshot may be believed (default 10)
  instance_id: skeid-b               # optional; default hostname
  error_window_s: 60                 # errors_in_window counts this far back (default 60)
```

`GET /skeid/registry/snapshot` sits behind the admin API key like every `/skeid/*` route. It
answers `404` when the registry is not enabled. It never answers unsigned: `secret_env` is
required when `enabled` is true, and an empty variable at config load is a load error.

The body is canonical JSON (sorted keys). The signature goes in a header:

```
X-Skeid-Registry-Signature: sha256=<hex HMAC-SHA256 over the exact body bytes>
```

Snapshot schema, version 1:

```json
{
  "version": 1,
  "instance": "skeid-b",
  "generated_at": 1790000000.123,
  "ttl": 10,
  "workers": 1,
  "nodes": [
    {
      "id": "gpu-1",
      "tags": ["local"],
      "healthy": 1,
      "inflight": 3,
      "max_conns": 8,
      "errors_in_window": 0,
      "last_failure_at": null,
      "capacity": { "used": 5, "limit": 8, "source": "prometheus" }
    }
  ]
}
```

- `generated_at` and `ttl` are inside the signed body, so neither can be changed without
  breaking the signature.
- `max_conns` is the answering process's share (ADR 0010, ADR 0012). It is what that process
  will admit.
- `capacity` appears only when the node has a current reading. `retry_after` is included when
  a backoff is pending.
- **Never in a snapshot:** node URLs, `api_key_ref` / `api_key_env`, node metadata, customer
  key ids, policies, usage events or their totals. It is operational telemetry only (ADR 0003,
  ADR 0004). Node ids and tags name machines and properties. They are not secrets.

### Consuming (fronting tier)

```yaml
nodes:
  - id: skeid-b
    url: http://skeid-b:8090/v1
    model: qwen3-32b
    max_conns: 64
    capacity:
      probe: registry                         # `type:` is accepted too
      url: http://skeid-b:8090/skeid/registry/snapshot   # optional; derived from the node URL
      admin_key_env: SKEID_B_ADMIN_KEY
      secret_env: SKEID_REGISTRY_SECRET
      interval_ms: 2000
      tags: [local]                           # optional: only count downstream nodes with these tags
```

A snapshot is accepted only if all of these hold. Otherwise the probe forgets its reading:

1. The answer is `200` and the signature header verifies (constant-time compare) against the
   exact body.
2. `version` is 1.
3. It is fresh: `now - generated_at <= ttl`, and `generated_at <= now + max_skew_s` (default
   5 s, `capacity.max_skew_s`). The two clocks have to be roughly in step (NTP), the same
   assumption the TTL of any signed token makes.
4. It is not a replay: `generated_at` is not older than the last snapshot this probe accepted.
   A replayed older snapshot inside its TTL is rejected, and so is a reordered one.

A missing secret or admin key variable on the fronting side also forgets.

**Mapping to a reading.** Over the downstream nodes that are healthy and carry every tag in
`capacity.tags`:

- `free_n = max_conns_n - inflight_n`. If the node has a current capacity reading with a
  limit, `free_n` is at most `limit - used` (the tighter of the two). A pending backoff means
  `free_n = 0`. Floored at 0.
- `limit = Σ max_conns_n` and `used = limit - Σ free_n`.
- A selected node with `max_conns: 0` (unlimited) and no reading with a limit has no ceiling.
  The whole reading then has no limit and does not narrow admission, but it is still recorded
  for reports.
- No healthy selected node: reported as full (`used 1, limit 1`). The downstream would answer
  `503`, so routing should go elsewhere.

Rules the mapping follows:

- **Never counted alongside own inflight.** `used` comes from the snapshot alone. Requests
  this process sent are already in the downstream's `inflight`, and adding our own counter on
  top is the double count this feature exists to avoid. The node's own `max_conns` stays the
  guardrail, as ADR 0009 requires. A reading may narrow it and never widen it. That is a
  separate limit, not a sum.
- **Errors do not decide admission.** `errors_in_window` and `last_failure_at` are carried for
  reports and future use. Health is operator state. Demoting a node on errors needs its own
  ADR (CONTEXT.md, flagged ambiguity "health").

### Staleness and combining with other readings

- The reading is stamped `at = generated_at`, not the time it arrived. It also expires at
  `generated_at + ttl`. Whichever comes first ends it: that expiry or `capacity_max_age_ms`.
  A registry that goes silent degrades to `inflight`. It does not keep saying what it said
  30 s ago.
- The probe forgets **only its own reading** (`forget_capacity($id, source => 'registry')`).
  A rejected snapshot must not wipe a `429` backoff that the passive rate-limit probe recorded
  from a response.
- **The tighter reading wins across sources.** This amends ADR 0009 "As implemented" for every
  probe, not only this one. A reading from a different source than the current one replaces it
  only if it is at least as tight. Tightness is 1 for a pending backoff, else `used / limit`,
  else 0. A reading from the same source always replaces its own last reading. Expiry still
  applies, so a tighter reading from another source holds for at most its own age limit. A
  registry that says "empty" while a response just said `429` loses.
- A state change of the probe is logged once, not every poll. The states are: accepted, bad
  signature, stale, replayed, unreachable, missing secret.

## Alternatives rejected

- **Push (webhook).** The downstream would have to know every fronting tier and retry
  deliveries. A downstream that cannot publish would look broken when it is only busy.
- **NATS / Redis pub-sub.** A new runtime dependency on the admission path's input. ADR 0009
  already declined shared state for the same reason.
- **The admin key alone, without a signature.** The admin key says who may *read*. It says
  nothing about whether the body is authentic and unaltered through a TLS-terminating proxy or
  a cache, and nothing about its age. The HMAC plus the signed `generated_at`/`ttl` covers
  both.
- **OpenBao as the transport or identity.** That is a sibling repo and out of scope. The
  secret comes from the environment, so a deployment can inject it from OpenBao the same way
  it injects the admin key.

## Consequences

- The fronting tier holds the downstream's admin API key. That key can also write (add nodes,
  flip health). A read-only registry credential would be narrower, and it is left open until a
  deployment needs it.
- With `--workers N` on the downstream, the snapshot describes the worker that answered: its
  own `inflight` and its own share of `max_conns`. The fronting tier then sees about 1/N of the
  downstream's capacity and under-admits. ADR 0010 accepts under-admitting over
  over-admitting. The snapshot carries `workers` so that a report can say so.
- The TTL, the skew allowance and the poll interval are starting points, not measurements.
- `last_failure_at` and the error window cost one timestamp and one per-second bucket map per
  node. They are written on every failed request whether or not the registry is enabled.
- Default config is unchanged: no `registry` block means no route, no probe, and no extra
  work.
