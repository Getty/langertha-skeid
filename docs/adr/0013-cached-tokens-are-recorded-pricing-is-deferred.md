# ADR 0013 — cached_tokens is recorded on the usage event; cache-aware pricing waits on Langertha::Pricing

- Status: accepted — recording implemented (k27); cache-aware pricing implemented (skeid #28, see Update)
- Date: 2026-09-15
- Tags: usage, metering, schema, pricing, langertha

---

## Context

Providers meter a prompt-cache hit separately: the tokens read from a warm prompt cache cost a
fraction of a fresh input token, and they report that count on the usage payload — OpenAI nests
it under `prompt_tokens_details.cached_tokens`. Skeid forwards those requests and writes one
usage event per request (ADR 0004), but the event had no field for the cache count, so a customer
paying for a cache-heavy workload looked identical on the ledger to one paying full rate for
every token.

Two things could be built from that count, and they are not the same size:

1. **Recording it** — carry `cached_tokens` from the upstream usage onto the event and into every
   store, so the number is on the ledger and can be reported on.
2. **Pricing it** — discount cached tokens at the provider's reduced cache rate when computing
   `cost_*_usd`, so the stored cost reflects what was actually billed.

The second depends on a Langertha capability that does not exist yet. `Langertha::Pricing->cost_for`
in the installed 0.503 models one input rate and one output rate per model; it has no
cache-discount rate, and the installed `Langertha::Usage` 0.503 has no `cached_tokens` accessor at
all — the count never survives `metrics.normalize`, which routes through `Langertha::Usage`. So
pricing the count correctly is blocked upstream, while recording it is standalone.

## Decision

**Record the count now; leave cost computation exactly as it was.**

- The usage event carries `cached_tokens`, read off the raw upstream usage payload the same way
  the other token counts are read: normalized name first, then the OpenAI wire spelling
  (`prompt_tokens_details.cached_tokens`), then a flat `cached_tokens` some OpenAI-compatible
  servers use, then a flattened metrics fallback. Missing → 0, the same fault-tolerance every
  other token field has. It is read on both the streaming path (accumulated off the SSE `usage`
  frame) and the non-streaming path (pulled off the decoded payload, because `metrics.normalize`
  drops it).
- Reading the count off an OpenAI-shaped upstream response is control-plane accounting, not
  protocol translation: every node answers Skeid in the OpenAI dialect (ADR 0001), so there is
  one wire spelling to read, not three to translate.
- `usage_events` gains a **nullable** `cached_tokens` column in both the sqlite and postgresql
  schemas, and `UsageStore::DBI` adds it to a pre-existing table on `prepare` — the same additive
  migration as `requested_model` (ADR 0004 / k17), which never drops or rewrites a column. Nullable
  on purpose: a row that predates the column reads `NULL` ("not measured"), which a report must be
  able to tell apart from a measured zero. Events written after this change always carry a number.
- The count flows through both stores (`JsonLog` totals + recent, `DBI` insert + totals + recent),
  the usage report, `GET /skeid/usage`, and `bin/skeid usage`.
- **Cost is unchanged.** `cost_input_usd` / `cost_output_usd` / `cost_total_usd` are still priced
  from `model_pricing` with no cache discount, so cached tokens currently bill at the normal input
  rate. This is a known, deliberate gap: the number is on the ledger to be reconciled and reported,
  not yet to be discounted.

## Consequences

- Cost attribution for a cache-heavy workload is recorded but not yet corrected. The raw
  `cached_tokens` is available to reconcile against a provider invoice by hand, and it is the input
  the pricing change will consume once it lands.
- The billing correction is a separate, upstream-blocked piece of work: it needs
  `Langertha::Pricing` to model a cache-discount rate (and, to price it from the normalized path
  rather than the raw payload, `Langertha::Usage` to expose the count). Until then Skeid must not
  invent a discount of its own — a cost figure that disagreed with both the provider's invoice and
  a future Langertha pricing model would be worse than an honest full-rate number with the cache
  count recorded beside it. This stays an open item on k27.
- Swapping the usage store still does not change what an event *means* (ADR 0004): every backend
  carries the same `cached_tokens`, and an old row or an old JSON event without it reads as zero in
  reports through the usual `num()` coercion.
- The additive-migration precedent set by `requested_model` now has a second instance, which fixes
  it as the pattern for growing the usage schema: add the column to both shipped schemas, register
  it in `@ADDED_COLUMNS`, insert and select it by name, never by position.

## Update (skeid #28, 2026-09-25): cached tokens are priced at the configured cache rates

The upstream blocker is gone: Langertha after 0.503 prices the prompt cache (core ADR 0031).
A `Langertha::Pricing` rule may carry `cached_input_per_million` and `cache_write_per_million`;
`Langertha::Usage` reads the cache read/write counts from every wire spelling and records
whether they are counted inside the input count (`input_includes_cache`); `Langertha::Cost` has
`cache_read_usd` / `cache_write_usd`, part of `total_usd`. Pricing is no longer deferred:

- A per-model `pricing` rule gains the two optional rates, validated at config load (a number
  `>= 0`; anything else fails the load, and a failed reload keeps the old pricing).
  `pricing_for_model` returns them.
- Skeid still invents no rate of its own. It hands the **provider-verbatim** usage block to
  `Langertha::Usage` (`metrics.normalize` with the decoded response, as before) and prices it with
  `Langertha::Pricing`, so whether a cache count sits inside `prompt_tokens` (OpenAI Chat, an
  `/anthropic` shim that says `input_includes_cache`) or beside `input_tokens` (Anthropic) is
  core's decision, and every token is priced once. A rule with only one of the two rates bills
  the other at `input_per_million` — no discount the rule did not state.
- The usage event carries `cost_cache_read_usd` and `cost_cache_write_usd` next to
  `cost_input_usd` / `cost_output_usd`; `cost_total_usd` includes them and `cost_input_usd`
  covers only the uncached input. `UsageStore::DBI` adds both as nullable columns the way this
  ADR fixed (`@ADDED_COLUMNS`, both schemas, by name): an old row reads `NULL`, "not priced
  apart". The event's `cached_tokens` is now the count `Langertha::Usage` read, so it matches the
  count that was priced, whatever the upstream's spelling; the raw-payload read stays as the
  fallback.
- A rule without cache rates prices exactly as before: every input token at
  `input_per_million`, both cache amounts `0`.
- On Langertha 0.503, which cannot price the cache, the two keys are accepted but dropped at
  config load with a one-time warning, so the stored rule and every cost are what they were.
  The capability is detected, not version-compared (`Langertha::Cost->can('cache_read_usd')`).

Still open: a streamed request's usage event is not priced at all (its cost fields are `0` — the
streaming accumulator never runs `metrics.normalize`), so neither its input nor its cache tokens
are billed. That predates this change and is its own ticket (skeid #41); the fix is to price the
accumulated provider-verbatim usage the same way.
