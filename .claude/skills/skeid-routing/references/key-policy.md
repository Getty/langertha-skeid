Read this when working on `policies`, `keys`, `default_policy`, `deny_tags`, key ids, `route_plan`'s permission answer or the per-key rate limit.

## Per-key policy

Who asks narrows what the plan may contain (ADR 0008). Resolved once at config load into
immutable policy objects; a request costs one hash lookup.

```yaml
policies:
  standard:  { deny_tags: [cloud] }        # our hardware only
  burstable: {}                            # cloud is fine when local is full
  trial:     { models: [house-model] }     # one product, anywhere
default_policy: standard
keys:
  k_5f0e1a2b3c4de5f60718293a4b5c6d7e8f901a2b: burstable  # `skeid keyid <key>` prints the id
  k_9c8b7a6f5e4de5f60718293a4b5c6d7e8f901a2b: { policy: standard, deny_tags: [cloud, eu-outside] }
```

- A key entry is a profile name, or a hash with `policy` plus **sparse** overrides (an absent
  field keeps the profile's value). Unlisted keys take `default_policy` — ten thousand identical
  customers are zero entries.
- Key id = `k_` + the key's full SHA-1 hex (ADR 0016). A legacy 12-hex id in `keys:` / `names:`
  still matches by prefix (`_configured_key_id`, warned once); a short id plus the full id it
  prefixes is a load error. Usage events keep their recorded id — no migration.
- Identical resolutions are interned: keys on one profile share one object.
- Naming an undefined policy **croaks** at load. Failing open would hand out access.
- `route_plan` returns `{ tiers, permitted, reason }`. `permitted => 0` (`model_not_permitted`
  or `all_tiers_denied`) is `403 permission_error`, never a capacity code. Running out of
  *permitted* capacity stays `429` — falling through to a denied node because everything else is
  full is the exact failure this design prevents.
- `deny_tags` filters **node selection**, not only the plan. An alias is a product name, not a
  security boundary: without the node filter a key denied `cloud` reaches a cloud node by asking
  for its raw model name. `t/26-key-policies.t` proves both halves (verified to fail when either
  is removed).
- **Identity is derived, never asserted.** The policy hangs off the customer key id, which comes
  from the presented key (`key_id_for_key`), not from `x-skeid-key-id` — unless
  `routing.trust_key_id_header` says a gateway in front authenticated the caller.

## Key rate (k125)

A policy or keys entry may carry `rate: { per_s, burst, per_min }`; `rate_admit` (token buckets
per key id, in memory per process, divided by `_admission_divisor` like `max_conns`) runs in
`_begin_route_async` after the `403` check and before any tier: over it `_refuse_rate_limited`
answers `429` + `Retry-After` and records one usage event (`key_rate_limited`, no node, no
content). Buckets reset when the rate changes and are pruned at policy load. Counters on
`GET /skeid/metrics/keys`. `t/92-key-rate-limit.t`.
