---
name: skeid-core
description: "Langertha::Skeid control plane — node inventory, weighted routing, admission control, config reload, usage accounting, admin API. Vocabulary is CONTEXT.md."
user-invocable: false
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

`Langertha::Skeid` is the control plane; `Langertha::Skeid::Proxy` is the Mojolicious app on
top of it. Moo, no singletons. Terms below are defined in `CONTEXT.md` — use them exactly.

## Shape

```
Langertha::Skeid          nodes, routing, admission, config, pricing, usage
  ::Proxy                 Mojolicious app: routes, auth, handlers, upstream I/O
  ::Protocol::Anthropic   /v1/messages   <-> OpenAI translation
  ::Protocol::Ollama      /api/chat      <-> OpenAI translation
  ::UsageStore::JsonLog   append-only JSON events (recommended default)
  ::UsageStore::DBI       sqlite + postgresql
  ::KeyBroker             resolve($ref) contract; ::OpenBao implements it
```

## Node

A node is a plain hashref in `->nodes`:

```yaml
id: openai-main        # required, unique
url: https://…/v1      # required, base url without endpoint path
model: gpt-4o-mini     # empty/absent = matches any requested model
engine: openai         # Langertha engine id, normalized via normalize_engine_id
weight: 3              # round-robin weight, min 1, integer
max_conns: 8           # admission limit; <= 0 means unlimited
healthy: 1             # operator flag, never set by error handling
tags: [local, gb10]    # grouping for selection; also accepts "local, gb10"
api_key_ref: secret/…  # key reference resolved through the KeyBroker per request
```

Mutating helpers: `add_node`, `remove_node`, `list_nodes`, `set_node_health`.

**Tags group nodes; ids never do.** `select_nodes(tags => [...])` returns nodes carrying *every*
listed tag (AND, not OR); no tags selects everything. Tags are lowercased, trimmed, de-duplicated
and order-preserving, and `normalize_tags` accepts either a list or a comma/space-separated
string because hand-written configs use both. Routing takes the same `tags` argument
(`pick_node`, `route_state`, `route.next`, `route.state`), and it is part of the route key —
two selections over one model must not share a round-robin cursor. This is the foundation the
tiers of ADR 0008 sit on.

**Derived lists are cached, and the invariant is silent when broken.** Which nodes a selection
matches, their order and their weights are computed once and reused until
`_inventory_generation` changes. Anything that touches the inventory must call
`_bump_inventory` — `add_node` and `set_node_health` do it explicitly, and a `trigger` on the
`nodes` attribute catches a direct assignment. Miss one and routing keeps sending traffic to a
node that was drained or removed, with nothing in the logs. `t/24-node-tags.t` is the tripwire;
it has been verified to fail when the bump is removed.

Note `pick_node` is protected twice — admission re-reads `healthy` from the live node — so a
stale cache shows up in `route_state`, not there. That matters because `has_eligible` is what
makes the proxy answer `503` instead of waiting for capacity and answering `429`.

## Aliases and tiers

A requested model resolves to an ordered **plan** of tiers, tried until one admits the request
(ADR 0008). A model with no alias resolves to a single implicit tier selecting on its own name
with the global wait — which is why an aliasless config routes exactly as it did before.

```yaml
aliases:
  house-model:
    tiers:
      - tags: [local]
        model: qwen3-32b            # the model the node is asked for
        wait_ms: 200                # wait this long for a local GPU before paying for cloud
      - tags: [cloud, groq]
        model: llama-3.3-70b-versatile
```

`wait_ms` defaults to **0**: writing tiers means "try here, then there", and waiting is opt-in.
A tier without `model` selects on the alias name itself. `tiers` may also be given as a bare
arrayref.

The two ways a tier fails are not the same, and the distinction is the whole design:

- **No eligible node** → skip to the next tier immediately. Waiting cannot conjure a node.
- **Eligible but none admitted** → wait out this tier's `wait_ms`, then fall through.
- Plan exhausted, no tier ever had an eligible node → `503 model_not_found`.
- Plan exhausted, some tier did → `429 rate_limit_error`.

**Requested vs served model.** Once aliases exist, the name the client used and the name the
node is asked for are different strings. The upstream body carries the served model; the usage
event carries `model` (served, what costs money) *and* `requested_model` (what the customer
bought). Dropping either breaks cost attribution silently. `requested_model` was added to the
schema after the fact, so `UsageStore::DBI` adds the column to a pre-existing table on
`prepare` — that is the entire migration story, and it never drops or rewrites a column.

## Per-key policy

Who is asking narrows what the plan may contain (ADR 0008). Resolved once at config load into
immutable policy objects; a request costs one hash lookup.

```yaml
policies:
  standard:  { deny_tags: [cloud] }        # our hardware only
  burstable: {}                            # cloud is fine when local is full
  trial:     { models: [house-model] }     # one product, anywhere
default_policy: standard
keys:
  k_5f0e1a2b3c4d: burstable                # `skeid keyid <key>` prints the id
  k_9c8b7a6f5e4d: { policy: standard, deny_tags: [cloud, eu-outside] }
```

- A key entry is a profile name, or a hash with `policy` plus **sparse** overrides — an absent
  field keeps the profile's value.
- Unlisted keys take `default_policy`. Ten thousand identical customers are zero entries.
- Identical resolutions are interned, so keys on one profile share one object.
- Naming an undefined policy **croaks** at load. Failing open here would hand out access.

`route_plan` returns `{ tiers, permitted, reason }`. `permitted => 0` means either
`model_not_permitted` or `all_tiers_denied` — both are `403 permission_error`, never a
capacity code. Running out of *permitted* capacity stays `429`: falling through to a denied
node because everything else is full is the exact failure this design exists to prevent.

`deny_tags` filters **node selection**, not only the plan. An alias is a product name, not a
security boundary — without the node-level filter, a key denied `cloud` reaches a cloud node
by asking for its raw model name. `t/26-key-policies.t` proves both halves and was verified to
fail when either is removed.

**Identity is derived, never asserted.** The policy hangs off the customer key id, so that id
comes from the key the caller presented (`key_id_for_key`), not from `x-skeid-key-id` —
unless `routing.trust_key_id_header` says a gateway in front of Skeid authenticated the caller.

## Routing and admission — two steps, both can fail

`route.next` picks a node; `request.start` may still refuse it. That is not redundancy:
between the two, another request may have taken the last slot.

- **Eligible** = model matches (or node/request model empty) AND engine matches (or either
  empty) AND `healthy`.
- **Admitted** = `inflight < max_conns` (or `max_conns <= 0`) **and** the node's capacity
  reading allows it, if there is a current one. See the probe section below.
- Weighted round-robin walks a per-`route_key` (`model|engine`) cursor over nodes sorted by
  id, skipping nodes that fail admission; the cursor only advances on a successful pick.
- No eligible node → `503 model_not_found` immediately.
- Eligible but none admitted → wait `route_wait_timeout_ms` (poll `route_wait_poll_ms`), then
  `429 rate_limit_error`. Waiting is `Mojo::IOLoop->timer`, never `usleep`.

`inflight` is authoritative and paired: every `request.start` that returned ok MUST get a
`request.finish`, on every path including errors and upstream timeouts. A missed finish leaks
a slot until restart.

## Capacity probes

`inflight` counts what *this process* sent. Exact for one Skeid in front of one node, an
undercount the moment a second frontend, a prefork worker or a batch job shares it — every
counter sees its own share and together they over-admit. A probe reports what the node says
instead (ADR 0009).

```yaml
nodes:
  - id: gpu-1
    max_conns: 32
    capacity:
      probe: prometheus                 # inflight (default) | ratelimit | prometheus | custom
      url: http://gpu-1:8000/metrics    # or path: /metrics, resolved against the node URL
      interval_ms: 2000
      running: vllm:num_requests_running    # optional; defaults cover vLLM/SGLang/TGI
      limit: 32                             # optional; falls back to max_conns
```

| probe | how | cost |
|---|---|---|
| `inflight` | the default; no probe object exists | none |
| `ratelimit` | `x-ratelimit-*` / `anthropic-ratelimit-*` / `Retry-After` read off responses the proxy already holds | none |
| `prometheus` | poll a metrics endpoint on a timer | one request per node per interval |
| `custom` | a `code` callback or a `class` to load | caller's |

**The rule everything rests on: a probe may only narrow what `max_conns` allows, never widen
it.** `_node_can_take` asks both. A reading that could raise the ceiling would turn a stale
probe into an overload, and for a rented node `max_conns` is a spend limit.

- Readings expire after `capacity_max_age_ms` (5s). Every failure — unreachable endpoint,
  unrecognised metric names, a probe that dies — calls `forget_capacity` and lets `inflight`
  decide. Never keep the last reading: unknown is imprecise, stale is confidently wrong.
- `used` for Prometheus is `running + waiting`. A queued request occupies the node.
- A `429`/`Retry-After` sets a **backoff**, which outlives the age limit (it is a statement
  about the future) and **never touches `healthy`** — busy is not broken, and nothing would
  flip an error-driven flag back.
- Probing never happens on the request path. `ratelimit` is the exception that proves it: it
  reads a response already in hand and issues nothing.

Dispatch: `capacity.set`, `capacity.get`, `capacity.observe`, `capacity.forget`. Probes are
started by `build_app` and rebuilt when the inventory generation moves.

## Function dispatch

`$skeid->call_function($name, \%args)` is the internal command surface. Every call first runs
`maybe_reload_config`, so config staleness is checked on the request path, not by a timer.

```
nodes.add nodes.remove nodes.list nodes.select nodes.set_health nodes.metrics
alias.set route.plan route.next route.state request.start request.finish
usage.record usage.report usage.configure
pricing.set metrics.estimate_cost metrics.normalize
engines.list config.reload
```

Unknown name croaks. Add a function here rather than reaching into the object from the app.

## Config

YAML, re-read when mtime changed (`maybe_reload_config`), or a `config_loader` coderef which
is treated as always-dynamic and re-run on every dispatch.

```yaml
nodes:      [ … ]                # replaces the whole inventory on reload
pricing:    { model: {…} }       # merged per model
aliases:    { name: {tiers: […]} }   # replaced wholesale on reload
policies:   { name: {…} }        # with default_policy: and keys:
routing:    { wait_timeout_ms: 2000, wait_poll_ms: 25, trust_key_id_header: false }
admin_api_key: "…"               # or admin: { api_key: … }
usage_store: { backend: …, … }
```

In config-managed mode an absent `admin_api_key` **disables** the admin API (`/skeid/*` then
answers 404, not 401 — absence of the feature, not a failed login). Nodes are replaced
wholesale on reload: anything pushed through the admin API is lost when the file changes.
That is deliberate — the file is the declared state.

ENV defaults: `SKEID_ROUTE_WAIT_TIMEOUT_MS`, `SKEID_ROUTE_WAIT_POLL_MS`, `SKEID_USAGE_DB`,
`SKEID_ADMIN_API_KEY`, `SKEID_TRUST_KEY_ID_HEADER`, `SKEID_CAPACITY_MAX_AGE_MS`.

## Usage

One usage event per forwarded request, written after `request.finish`, including failures
(`ok = 0`). `record_usage` normalizes metrics, prices them from `model_pricing` at record
time, and hands the event to the configured store.

Backend selection in `_configure_usage_store` is inference-first: explicit `backend` wins,
otherwise `sqlite_path`/`path`/`db_path` → sqlite, `dbi:Pg:` dsn → postgresql, `log_path` →
jsonlog. `password_env` reads the password from the environment so it stays out of the file.
Schema is applied from `share/sql/usage_events.<backend>.sql` when `auto_migrate` (default on).

Override points, in order of preference: `usage_store` config → `store_usage_event` /
`query_usage_report` callbacks → subclass. `jsonlog` is the recommended default because it
never blocks the event loop on a database.

`node_metrics` is a *different* thing: volatile in-memory counters for ops, never billed.

## Admin API

`/skeid/*` under bearer auth against `admin_api_key`:
`GET /skeid/nodes`, `POST /skeid/nodes`, `POST /skeid/nodes/:id/health`,
`GET /skeid/metrics/nodes`, `GET /skeid/usage`.

## Traps

- Adding a synchronous helper next to an async one. The handlers are async-only; a blocking
  call in a handler stalls every concurrent request. See the event-loop rule.
- Deriving health from errors. Health is operator state; see the flagged ambiguity in
  `CONTEXT.md` and write an ADR before changing it.
- Logging a resolved key. Only key *references* may appear in logs, config and usage events.
- Treating `429` and `503` as interchangeable. Saturation vs. no-such-model are different
  failures with different fixes. `403` is a third: not a capacity answer at all.
- Letting anything a client controls decide the customer key id. It selects both the routing
  policy and the invoice.
