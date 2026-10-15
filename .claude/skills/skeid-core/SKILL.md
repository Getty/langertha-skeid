---
name: skeid-core
description: Load when working on the Langertha::Skeid control plane — node inventory, weighted routing, admission control, config reload, usage accounting, the admin API.
user-invocable: false
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

`Langertha::Skeid` is the control plane; `Langertha::Skeid::Proxy` is the Mojolicious app on
top of it. Moo, no singletons. Terms are defined in `CONTEXT.md` — use them exactly. Aliases,
tiers, per-key policy, prefork workers and capacity probes: skill `skeid-routing`.

## Shape

```
Langertha::Skeid          nodes, routing, admission, config, pricing, usage, registry snapshot
  ::Proxy                 Mojolicious app: routes, auth, handlers, upstream I/O
  ::Proxy::RelayContent   upstream body always relayed as raw bytes (skeid #30)
  ::Protocol              shared translation helpers, OpenAI manifest face
  ::Protocol::Anthropic   /v1/messages <-> OpenAI (+ ::Stream)
  ::Protocol::Ollama      /api/chat, /api/generate <-> OpenAI (+ ::Stream)
  ::Protocol::Audio       /v1/audio/* relayed, not translated: form fields, usage units (ADR 0021)
  ::Protocol::Rerank      /v1/rerank relayed; a rerank_format: tei node translated upstream (ADR 0021)
  ::Protocol::MCP         MCP gateway wire: relayed headers, upstream URL, listing entry (ADR 0022)
  ::UsageStore            config normalization + backend factory
  ::UsageStore::JsonLog   append-only JSON events (recommended default)
  ::UsageStore::DBI       sqlite + postgresql
  ::CapacityProbe         timer-driven probes; ::Prometheus, ::Registry, ::Custom
  ::Registry              signed Skeid-to-Skeid snapshot: encode, sign, verify (ADR 0017)
  ::Secret                constant-time compare for keys, tokens, signatures
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
api_key_env: VAR       # fallback: key from this environment variable
capacity: { probe: … } # optional capacity probe (skeid-routing)
rerank_format: tei     # optional: the node's rerank endpoint speaks TEI's dialect, not the client's
```

- `rerank_format` is validated in `add_node` by `Protocol::Rerank->normalize_format`; an unknown
  value croaks (failed config load), like an unknown `engine`. Absent = rerank is relayed. A node
  option, not an engine branch — `engine` still changes no call.
- Mutators: `add_node`, `remove_node`, `list_nodes`, `set_node_health`.
- **Tags group nodes; ids never do.** `select_nodes(tags => [...])` = nodes carrying *every* tag
  (AND); no tags = all. Tags are lowercased, trimmed, de-duplicated, order-preserving;
  `normalize_tags` takes a list or a comma/space string. Routing takes the same `tags`
  (`pick_node`, `route_state`, `route.next`, `route.state`) and they are part of the route key —
  two selections over one model never share a round-robin cursor (base of ADR 0008 tiers).
- **Derived lists are cached; a broken invariant is silent.** Matches, order and weights are
  reused until `_inventory_generation` changes. Every inventory change must call
  `_bump_inventory` — `add_node` and `set_node_health` do (a no-op health call does not bump), a
  `trigger` on `nodes` catches direct assignment. Miss one and traffic keeps going to a drained or
  removed node, with nothing logged. Tripwire: `t/24-node-tags.t` (verified to fail without the
  bump). Cache + cursors are bounded at 256 route keys per generation, FIFO-evicted together
  (skeid #55), so client-chosen model names cannot grow them.
- `pick_node` is protected twice (admission re-reads `healthy` from the live node), so a stale
  cache shows in `route_state`, not there — and `has_eligible` decides `503` (no wait) vs waiting
  for capacity and `429`.

## Routing and admission — two steps, both can fail

`route.next` picks a node; `request.start` may still refuse it — another request may have taken
the last slot in between. Not redundancy.

- **Eligible** = model matches (or node/request model empty) AND engine matches (or either empty)
  AND carries every selector tag AND no denied tag AND `healthy`.
- **Admitted** = `inflight < worker_max_conns` (or `max_conns <= 0`) AND the node's current
  capacity reading allows it (skeid-routing).
- Weighted round-robin walks a per-route-key cursor (`model|engine`, plus tags and denied tags
  when present) over nodes sorted by id, skipping nodes that fail admission; each node is checked
  at most once per selection whatever its weight (skeid #56). The cursor advances only on a
  successful pick.
- No eligible node → `503 model_not_found` at once. Eligible but none admitted → wait
  `route_wait_timeout_ms` (poll `route_wait_poll_ms`), then `429 rate_limit_error`. Wait with
  `Mojo::IOLoop->timer`, never `usleep`.
- `inflight` is authoritative and paired: every `request.start` that returned ok MUST get a
  `request.finish`, on every path including errors and upstream timeouts. A missed finish leaks
  a slot until restart.

## Function dispatch

`$skeid->call_function($name, \%args)` is the internal command surface. Every call first runs
`maybe_reload_config` — staleness is checked on the request path, not by a timer.

```
nodes.add nodes.remove nodes.list nodes.select nodes.set_health nodes.metrics
alias.set policy.set policy.for_key route.plan route.next route.state
request.start request.finish capacity.set capacity.get capacity.observe capacity.forget
usage.record usage.report usage.configure
pricing.set metrics.estimate_cost metrics.normalize
engines.list config.reload config.status
```

Unknown name croaks. Add a function here rather than reaching into the object from the app.

## Config

YAML, re-read when its mtime changed (`maybe_reload_config`), or a `config_loader` coderef re-run
from dispatch at most once per `config_reload_interval` (default 1s).

- A load whose fingerprint (loader's optional second return value, else a canonical digest)
  matches the last applied one is a no-op (skeid #38).
- A reload from dispatch never dies (skeid #39): failure is logged and kept in `reload_status`,
  the request runs under the kept config, a failing loader or broken file backs off (interval
  doubling from >=1s, cap 60s; a new file mtime is read at once — skeid #54), the same broken
  result is never applied twice. Construction and explicit `config.reload` still die.

```yaml
nodes:      [ … ]                # replaces the whole inventory on reload
pricing:    { model: {…} }       # replaced wholesale; optional cached_input_per_million / cache_write_per_million
aliases:    { name: {tiers: […]} }   # replaced wholesale on reload (skeid-routing)
policies:   { name: {…} }        # with default_policy:, names: and keys: (skeid-routing)
routing:    { wait_timeout_ms: 2000, wait_poll_ms: 25, trust_key_id_header: false, frontend_count: 1 }
admin_api_key: "…"               # or admin_api_key_env:, or admin: { api_key | api_key_env }
usage_store: { backend: …, … }
manifest:   { enabled, public_url, … }   # provider manifest, per-key grants in keys: (ADR 0015)
registry:   { enabled, secret_env, read_key_env, … }   # publish a snapshot (ADR 0017)
uploads:    { max_bytes: 26214400 }      # body limit of the upload routes (/v1/audio/*); ADR 0021
client_auth: { keys: [name-or-key-id] }   # only these callers may use the client routes; 401 otherwise (ADR 0020)
mcp:        { public_url, servers: { … } }   # MCP gateway (ADR 0022; skill skeid-relay-routes)
```

- **Admin key**, resolved on every applied config: explicit (`serve --admin-api-key`,
  `build_app(admin_api_key)`, `new(admin_api_key)`, `set_admin_api_key`) > config (first of the
  four spellings present; empty disables) > `SKEID_ADMIN_API_KEY` > off (skeid k64). Off =
  `/skeid/*` answers 404, not 401 — the feature is absent, not a failed login.
- **A reload makes the running config equal to the file** (skeid k65): a declared section
  replaces what is loaded; a section the last applied config declared and this one drops returns
  to its default (`_config_declared`); same per `routing` key. A section no applied config ever
  declared is left to the API that set it (admin-pushed nodes, `pricing.set`).
- Exception `usage_store`: removal keeps the running store until restart and warns once —
  stopping billing on reload is silent data loss (ADR 0004); a *changed* store swaps live.
- A changed `nodes:` section replaces the list wholesale; admin-API pushes are lost, deliberately
  (the file is the declared state). An unchanged `nodes:` keeps the list, its inventory
  generation (probes keep running) and admin-set health.

ENV defaults: `SKEID_ROUTE_WAIT_TIMEOUT_MS`, `SKEID_ROUTE_WAIT_POLL_MS`, `SKEID_USAGE_DB`,
`SKEID_ADMIN_API_KEY`, `SKEID_TRUST_KEY_ID_HEADER`, `SKEID_CAPACITY_MAX_AGE_MS`,
`SKEID_CONFIG_RELOAD_INTERVAL`, `SKEID_FRONTEND_COUNT`.

## Usage

One usage event per forwarded request, written after `request.finish`, failures included
(`ok = 0`). `record_usage` normalizes metrics, prices them from `model_pricing` at record time,
hands the event to the store.

- Cache rates price the provider-verbatim usage block through `Langertha::Usage`/`Pricing` into
  `cost_cache_read_usd` / `cost_cache_write_usd` (part of `cost_total_usd`; ADR 0013 update).
- A stream keeps the upstream usage block verbatim (frames merged key by key, later wins — counts
  are running totals, never summed) and prices it through the same `metrics.normalize` as a
  non-streamed answer, on every face (skeid #41).
- **Requested vs served model**: the event carries `model` (served — what costs money) *and*
  `requested_model` (what the customer bought). Dropping either breaks cost attribution silently.
  `UsageStore::DBI` adds a missing column to a pre-existing table on `prepare` — that is the
  whole migration story; it never drops or rewrites a column.
- Optional fields say "not measured" by being **absent, never `0`** (ADR 0021): `content_bytes`
  (streams only), `audio_seconds` (audio, only when the node reports a duration), `documents`
  (rerank, counted off the request, only when the node answered); the last two recorded, not
  priced. A new usage unit follows the same path: `record_usage` argument, nullable column via
  `@ADDED_COLUMNS` in `UsageStore::DBI`, a key `jsonlog` writes as is, and a sum in the report's
  `totals` / `by_key` / `by_model` that `skeid usage` prints only when non-zero.
- Backend selection (`UsageStore->normalize_config`) is inference-first: explicit `backend` wins,
  else `sqlite_path`/`path`/`db_path` → sqlite, `dbi:Pg:` dsn → postgresql, `log_path` →
  jsonlog. `password_env` keeps the password out of the file. Schema from
  `share/sql/usage_events.<backend>.sql` when `auto_migrate` (default on).
- Override points, in order of preference: `usage_store` config → `store_usage_event` /
  `query_usage_report` callbacks → subclass. `jsonlog` is the recommended default: it never
  blocks the event loop on a database.
- `usage_store.flush_interval_ms` (sqlite/postgresql only; ADR 0005 update, skeid k78): `0`
  (default) = synchronous write per event. `> 0` = write-behind: queued, written by a timer in one
  transaction; also flushed on config reload (store swap), shutdown (`END` in `bin/skeid`),
  before a usage report, and by `flush_usage`. Price: a kill without flush (`SIGKILL`, OOM) loses
  the queue and the billed requests in it. Under prefork `SIGTERM`/`SIGINT` make the manager
  `SIGKILL` the workers (queue lost); `SIGQUIT` (the Docker image's `STOPSIGNAL`) flushes. A lost
  event is reported on `on_usage_lost`, never silent. `jsonlog` stays the recommendation.
- `node_metrics` is different: volatile in-memory ops counters, never billed.

## Admin API

`/skeid/*` under bearer auth against `admin_api_key` (constant-time, `Skeid::Secret`):
`GET /skeid/nodes`, `POST /skeid/nodes`, `POST /skeid/nodes/:id/health`,
`GET /skeid/metrics/nodes`, `GET /skeid/usage`, `GET /skeid/config` (`reload_status`: last reload
error, `failed_at`, `failures`). `GET /skeid/registry/snapshot` sits outside that block: registry
read key or admin key, 404 unless `registry.enabled`. Public `GET /health` carries
`config_reload` without the message and stays `status: ok` while a reload fails.

## Traps

- A synchronous helper next to an async one. Handlers are async-only; a blocking call stalls
  every concurrent request.
- Deriving health from errors. Health is operator state (flagged ambiguity in `CONTEXT.md`);
  write an ADR before changing it.
- Logging a resolved key. Only key *references* may appear in logs, config and usage events.
- Treating `429` and `503` as interchangeable: saturation vs no-such-model, different fixes.
  `403` is a third — not a capacity answer at all.
- Letting anything a client controls decide the customer key id. It selects both the routing
  policy and the invoice.
