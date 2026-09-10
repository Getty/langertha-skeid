# ADR 0011 — Customer key names live in the config, keyed by readable name

- Status: accepted — implemented (`names:` registry, `key_id_for_name`)
- Date: 2026-09-10
- Tags: policy, keybroker, config, identity

---

## Context

ADR 0008 names customers by the id their API key derives to — `k_<12 hex>`, printed by
`skeid keyid`. That keeps customer keys out of config, which ADR 0003 requires, but it costs
readability: a `keys:` section is a column of digests, and rotating one customer's key means
finding and rewriting every policy line that named them by the old id.

ADR 0008 left one question open on purpose: where a readable-name-to-key mapping belongs. It
sketched one answer — next to the key in OpenBao, at `secret/skeid/customer/<name>`, resolved
by the key broker — and blocked it on karr #3, because the broker had no cache and a per-request
vault round-trip on the routing path is exactly what ADR 0008's "a request costs one hash
lookup" forbids.

karr #3 is done: the broker caches, so a vault-resolved mapping is now technically possible.
That reopens the question rather than answering it. Feasibility was never the objection to
weigh — *where the mapping should live* is, and that is karr #17.

## Decision

The mapping lives in the config, as an optional `names:` section from a readable name to a
**customer key id**, resolved to ids once at config load and never consulted again.

```yaml
names:
  alice:   k_5f0e1a2b3c4d          # an id from `skeid keyid`, never a customer key
  bigcorp: k_9c8b7a6f5e4d
keys:
  alice: burstable                 # a keys: entry may be written by name ...
  bigcorp: { policy: standard, deny_tags: [] }
  k_1122334455aa: burstable        # ... or still by the raw key id
```

At load, each `keys:` label is resolved through `names:` if it is a known name, and taken as an
id otherwise; the resolved id is what `key_policies` is keyed by. So the request path is
unchanged from ADR 0008: a request still carries the id the caller's key derives to, and
`policy_for_key` is still one hash lookup with no vault call. The name is erased before any
request is served — it is a config-authoring convenience, not a runtime identity.

Two invariants are held loud, at load, rather than failing quietly later:

- A `names:` value must be a non-empty scalar. A name points at one id, not a structure, and
  never at an empty string.
- No two `keys:` labels may resolve to the same id. A name and its own id both appearing is a
  config mistake, and last-write-wins on a policy assignment is the kind of silent wrong-grant
  this layer exists to prevent (ADR 0008).

**Why the config, and not OpenBao — even now that the broker caches.**

- The name-to-id mapping is not a secret. The id is a truncated digest that *identifies*; what
  *authenticates* is the key the caller presents (ADR 0008). The one secret — the key itself —
  stays in the vault. Moving a public lookup table into the vault buys nothing and couples a
  readability aid to vault availability.
- The whole routing-policy picture — profiles, the default, per-key assignment, and now the
  names that make those lines legible — stays in one file. That file is the security boundary
  for data residency (ADR 0008); splitting the name registry into a second system scatters the
  story a reviewer has to hold in their head to answer "what may this customer reach".
- The config must load and be checkable offline. The proxy tests build the app with an inline
  fake upstream and no OpenBao; resolving names through the broker at load would make config
  validity depend on a running vault, for no gain over a hash in the file.
- Erasing names at load keeps ADR 0008's core property intact with nothing new to reason about:
  no per-request name lookup, no second cache, no staleness window between the vault and the
  routing path.

karr #3 removed the "vault round-trip" objection to the OpenBao route. The decision here is that
removing that objection does not change *where* the mapping belongs.

## Consequences

- Config gains an optional `names:` registry. `keys:` entries may be labeled by name or by raw
  id, and both resolve to the same id-keyed `key_policies`. Existing id-only configs are
  unchanged — the section is absent and nothing resolves.
- Rotating a customer's key is a one-line edit: repoint the name at the new id, and every policy
  line that named the customer follows. Before, the id was written into each of those lines.
- The config still holds no customer key. `names:` values are `skeid keyid` outputs, which the
  documentation and the example config state — a 12-hex digest is indistinguishable from any
  other opaque string, so this is discipline, not a check the loader can make.
- The OpenBao route is not taken and not foreclosed. A future `secret/skeid/customer/<name>`
  source could still feed the same registry, but as another thing resolved to an id *at config
  load*, never a lookup on the request path. The resolution point stays where ADR 0008 put it.
- `key_id_for_name` exposes the registry for tooling and tests. `t/26-key-policies.t` proves a
  named `keys:` entry attaches its policy to the mapped id, a raw-id entry alongside it still
  resolves, the name is not itself an identity (looked up as an id it takes the default, so it
  cannot leak onto the request path), and the three config errors croak instead of granting the
  wrong access.
