# ADR 0017 — The Skeid-to-Skeid registry is a signed, pulled capacity probe

- Status: accepted — implemented (skeid #18); updated (skeid #49)
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
required when `enabled` is true, and an empty variable at config load is a load error, as is a
secret shorter than 32 bytes (the HMAC-SHA256 output size) and an enabled registry without an
admin API key, which no fronting tier could read. A snapshot that fails to build for any other
reason is logged and answered with a generic `500`; the answer says nothing about the cause.

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

A missing secret or admin key variable on the fronting side also forgets, and so does a secret
shorter than 32 bytes.

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
- Every probe forgets **only its own reading** (`forget_capacity($id, source => $probe->source)`),
  on a rejected snapshot, an unreachable endpoint, a poll that dies and a stop. A probe going
  blind must not wipe a `429` backoff that the passive rate-limit probe recorded from a
  response. A `custom` callback has no fixed source and still forgets whatever is there.
- **The tighter reading wins across sources, while it is current.** This amends ADR 0009 "As
  implemented" for every probe, not only this one. A reading from the same source always
  replaces its own last reading. A reading from a different source is held off by the current
  one only when the current one is tighter (a pending backoff above everything, else
  `used / limit`, else 0) **and** either
  - it carries a pending backoff, or
  - it is younger than the longer of the two sources' poll intervals (`interval_ms` × workers,
    passed with each reading and stored with it; a passive reading has none, 0). Within that
    window neither source has had a full poll since the tighter reading was taken, so the two
    describe the same moment and the tighter one is the safer view.

  Otherwise the incoming reading replaces it. A registry that says "empty" while a response
  just said `429` loses. A fresh, tight probe reading is not lifted by a roomy response that
  arrives right after it, nor by a faster, looser probe before the slow one has polled again:
  the window is the longer interval, not the incoming one's. Two probes on timers that
  disagree leave the tighter one deciding, because each refreshes within the longer interval.
  But a passive reading that nobody refreshes -- `remaining: 0` from the last response before
  traffic stopped, no reset header -- holds a probe off for at most one of that probe's polls. "Tighter" alone let it block the node until
  `capacity_max_age_ms`, and forever with `capacity_max_age_ms: 0`; that was a review finding
  on the first implementation. Two passive readings never hold each
  other off: with no interval on either side the window is 0.
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

- **The fronting tier holds the downstream's full admin API key.** That key is not read-only:
  it can flip health and add nodes with an arbitrary `url` plus `api_key_env` / `api_key_ref`.
  Whoever holds it can register a node pointing at a host they control, under a key reference
  the downstream resolves, and the downstream then sends that provider secret there. A
  compromised fronting tier therefore exfiltrates the downstream's provider keys, not only its
  telemetry. The snapshot route must be served over TLS, and the fronting tier's copy of the
  key needs the same care as the downstream's own. A read-only registry credential is the fix
  and is tracked as skeid #49. *(Resolved: see the Update below. The admin key remains accepted
  for compatibility, so this consequence still holds for a fronting tier configured with it.)*
- With `--workers N` on the downstream, the snapshot samples one worker: the one that answered,
  with its own `inflight` and its own share of `max_conns`. It is representative only when the
  workers are evenly loaded. When the answering worker is emptier than the others, the fronting
  tier reads free room that is not there and can **over-admit** until the next poll, because a
  reading below its limit admits up to the fronting tier's own `max_conns`. The guardrail is
  the downstream's per-worker share (ADR 0010): each worker still admits only its share, and
  the excess waits there and gets `429`. The snapshot carries `workers` so that a report can
  say so. An aggregated snapshot across workers would need shared state, which ADR 0009
  declined.
- **Replay protection does not survive a restart.** The last accepted `generated_at` lives in
  the probe, so a fronting-tier restart, or a probe rebuilt after a reload changed the node,
  starts with none. An attacker who recorded a signed snapshot can have it accepted once more
  in that moment, and only while it is still inside its own `ttl` (default 10 s); after that it
  is stale. The window is ttl-bounded and the reading can only narrow `max_conns`, so it was
  left unfixed rather than persisted.
- **Secret rotation has no overlap window.** One secret per pair, read from the environment at
  start. Rotating means restarting both sides; in between the fronting probe sees
  `bad_signature`, forgets and falls back to `inflight`. A second, accepted-while-rotating
  secret is left until a deployment needs zero-gap rotation.
- The poll interval has to stay below `capacity_max_age_ms` and the downstream's `ttl`, or the
  reading expires between polls and `inflight` decides in the gaps. Every probe warns at start
  when its effective interval is not below `capacity_max_age_ms`; the downstream `ttl` is only
  known from the first snapshot and is documented, not checked.
- The TTL, the skew allowance and the poll interval are starting points, not measurements.
- `last_failure_at` and the error window cost one timestamp and one per-second bucket map per
  node. They are written on every failed request whether or not the registry is enabled.
- Default config is unchanged: no `registry` block means no route, no probe, and no extra
  work.

## Update (skeid #49, 2026-09-25): a registry read key for the snapshot route

The consequence above -- the fronting tier holding a write-capable admin key -- is closed by a
dedicated credential for the snapshot route.

- **Downstream:** `registry.read_key_env` names the environment variable holding the registry
  read key. The key itself is never in the config (an unknown `read_key` is refused, like
  `secret`). A named variable that is empty fails the config load.
- **The route** `GET /skeid/registry/snapshot` accepts a bearer that is either the read key or
  the admin API key (kept for compatibility). Both are compared in constant time over SHA-256
  digests, so neither the position of the first difference nor the key length shows in the
  timing. The route is registered outside the `/skeid` admin block: **the read key authorizes
  that one route and nothing else**. Every other `/skeid/*` route still takes only the admin key.
  With neither key configured the route answers `404`, like every closed `/skeid` route.
- **Load check relaxed:** an enabled registry needs *a* credential to read it -- the read key or
  an admin API key -- instead of requiring the admin key. A downstream can now publish its
  snapshot with no admin API at all.
- **Fronting side:** the `registry` probe takes `read_key_env` besides `admin_key_env`; one of
  the two is required. When `read_key_env` is configured the probe sends the read key and
  **never falls back** to the admin key, not even when the read key variable is empty (it
  forgets with `missing_secret` instead): an operator who named a read key does not want the
  admin key on the wire.

Consequences:

- Leaking the read key exposes the snapshot, which is operational telemetry by construction
  (the "Never in a snapshot" list above), and nothing more. The HMAC still decides whether the
  fronting tier believes a snapshot; the read key only decides who may fetch one.
- The read key has the same rotation model as the secret: one value per pair, from the
  environment, rotated by restart. A missed rotation shows as `unreachable` (`401`) on the probe
  and admission falls back to `inflight`.
- A deployment that keeps `admin_key_env` on the probe keeps the old exposure. It is documented,
  not refused, so existing configs load unchanged.
