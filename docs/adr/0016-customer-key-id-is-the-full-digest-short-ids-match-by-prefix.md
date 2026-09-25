# ADR 0016 — The customer key id is the full digest; short ids still match by prefix

- Status: accepted — implemented (skeid #37)
- Date: 2026-09-25
- Tags: keys, identity, policy, billing, manifest, security

---

## Context

The customer key id (`key_id_for_key`, printed by `skeid keyid`) is derived from the API key
the caller presents (ADR 0008). It is the only thing separating one customer from another in
routing policy, in the usage ledger (ADR 0004) and, since skeid #29, in the provider manifest
(ADR 0015). It was `k_` plus the first 12 hex digits of the key's SHA-1: 48 bits. At that width
the chance that two customers collide is no longer negligible for a large key population
(around 2^24 keys), and a short id is cheap to search for.

The #29 review offered two fixes. The first was to widen the digest. The second was to derive
the id with a keyed HMAC and a server secret, so that nobody holding a key list could map keys
to ids offline. Both change every existing id. That breaks `keys:` and `names:` entries and
splits the usage history.

## Decision

**Widen the id to the full SHA-1 hex digest: `k_` + 40 hex digits, 160 bits. No HMAC.**

- **Same digest, longer.** The old id is exactly the first 14 characters of the new one. A
  config written with old ids can keep working without a table mapping old ids to new ones.
- **Full digest, not a truncated 128 bits.** 160 bits is more than the ≥128-bit floor we set,
  and it leaves no cut point to argue about later. SHA-1's collision weakness does not apply
  here. Nobody gets to choose two customers' keys, and a second preimage against a given key
  is not practical.
- **No HMAC.** Mapping a key to its id offline would require already holding the key, and the
  key is the credential. A server secret would add something that has to be distributed to
  every frontend (ADR 0012) and rotated, and whose loss would re-key every customer. The id
  identifies; it never authenticates (ADR 0008). What authenticates is presenting the key.
- **Short ids keep working, deprecated.** A key id in `keys:` or `names:` that has the old shape
  (`k_` + 12 hex) matches every request whose full id starts with it. The lookup is exact
  first, then the 12-digit prefix. It happens only when the config still holds a short id, so
  it costs at most one extra hash lookup. Each short id is warned about once per process at
  config load, with a pointer to `skeid keyid`. The same fallback covers the routing policy
  and the manifest, because both are keyed on the id.
- **Ambiguity is a load error.** If a config lists both a short id and a full id it is the
  prefix of, one key would match both entries. That config does not load, whether the short
  id is written directly or comes in through `names:`. Two different short ids cannot
  overlap.
- **Usage events are not migrated.** An event keeps the id it was recorded under: events from
  before the change carry the short id, later ones the full id. To report one customer across
  the change, query both ids (the short one is the full id's first 14 characters). Rewriting
  the ledger would mean touching the billing record (ADR 0004) for no billing gain.

A client-supplied `x-skeid-key-id` (only with `routing.trust_key_id_header`) is used as given.
An authenticating front end that sends a full id finds a short-id config entry by the same
prefix fallback. One that still sends short ids matches short-id entries exactly.

## Consequences

- `skeid keyid` prints 42-character ids. Existing configs load unchanged, with one
  deprecation warning per short id. Operators replace short ids at their own pace.
- The prefix fallback is permanent code until short ids are removed. Removing them is a
  breaking change that needs its own Changes entry.
- Usage reports filtered by `api_key_id` split at the upgrade for every customer. This is
  documented, not fixed.
- Collision margin: 2^80 birthday bound instead of 2^24.
