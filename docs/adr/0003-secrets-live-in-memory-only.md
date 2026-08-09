# ADR 0003 — Secrets live in memory only; renewal failure kills the process

- Status: accepted
- Date: 2026-08-08
- Tags: security, keybroker, openbao, deployment, backfill

## Context

Skeid holds three classes of secret at once: the upstream provider keys it injects into
forwarded requests, the customer keys whose usage it meters, and the credential it uses to
obtain both. A proxy that writes any of them to disk turns one compromised container image,
one stray volume mount or one `docker cp` into a full key disclosure — and unlike a database
password, an LLM provider key is directly monetisable by whoever finds it.

The usual mitigation, "encrypt the key file", moves the problem to the decryption key. The
alternative is to never have the file.

## Decision

No secret is ever written to disk by Skeid.

- Keys are named in config by **key reference** only (`api_key_ref: secret/skeid/remote/groq`).
  The reference is not sensitive; config, logs, tickets and usage events may carry it.
- A `KeyBroker` resolves a reference to a secret **in memory, at the moment it is needed**.
  `KeyBroker::OpenBao` is the implementation; the contract is what code depends on.
- The container boots with AppRole `role_id` + `secret_id` from the environment, logs in, keeps
  the token in memory, and renews it on a timer.
- **Renewal failure is fatal.** `refresh` dies, the process dies, the orchestrator restarts it,
  and the restart performs a fresh AppRole login. There is no retry-with-old-token and no
  cached token to fall back to.

  Refined when renewal moved onto a timer: a failed renewal while the current token is still
  valid warns and is retried on the next tick, because dropping every in-flight request over a
  network blip is not what this rule is for. Once the token has actually expired the process
  dies as stated. The distinction is "can this still serve traffic", not "did a call fail".
- Resolved keys never reach a log line, an error message, a usage event or a test fixture.
  Injected keys replace the client's `Authorization` header and delete its `x-api-key`, so a
  client's own credential cannot leak upstream.

## Consequences

- A restart is the recovery path for every credential problem. That is cheap here — Skeid is
  stateless apart from `inflight` — and it is why "restart to fix it" is an acceptable answer
  in this design rather than an admission of defeat.
- Every process start costs one AppRole login and every key use costs a vault round-trip.
  Caching a resolved key **in memory** with a TTL is compatible with this ADR; caching it on
  disk is not, at any TTL, for any reason.

  Implemented in `KeyBroker` (base class, so every broker gets it): `cache_ttl` 300s,
  `negative_cache_ttl` 5s, and concurrent misses for one reference coalesced into a single
  resolution. The cost is that a rotated key keeps working for up to `cache_ttl` — rotation
  should call `forget_key`, and `cache_ttl` is the knob for a deployment that would rather pay
  the round-trip. The negative cache is what keeps a vault outage from becoming one round-trip
  per request at exactly the moment the vault is least able to serve them.

  Resolution is also **non-blocking** on the request path (`key_async`, `resolve_key_async`),
  because a synchronous vault round-trip inside a handler stalls every other in-flight request
  (ADR 0005). The token is renewed on a timer rather than when a request discovers it expired,
  so the request least able to afford the round-trip — the first one after a quiet period —
  does not pay for it. `t/27-keybroker-nonblocking.t` proves the process still answers other
  requests while a resolution is outstanding.
- Losing OpenBao means losing the ability to serve requests that need a brokered key. That is
  the intended failure mode: fail closed, not fall back to a stale local copy.
- `examples/service/.env` is a local artifact of the operator's machine and must never be
  tracked; only `.env.example` with placeholders is committed.
