Read this when touching config loading or reload, a config section, ENV defaults, the function dispatch list or the `/skeid/*` admin API.

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
routing:    { wait_timeout_ms: 2000, wait_poll_ms: 25, trust_key_id_header: false, frontend_count: 1 }
admin_api_key: "…"               # or admin_api_key_env:, or admin: { api_key | api_key_env }
manifest:   { enabled, public_url, … }   # provider manifest, per-key grants in keys: (ADR 0015)
registry:   { enabled, secret_env, read_key_env, … }   # publish a snapshot (ADR 0017)
```

The other sections live with their topic: `aliases`, `policies`, `customer_source` (skill
`skeid-routing`), `client_auth` (skill `skeid-protocols`), `uploads`, `documents`, `realtime`,
`mcp` (skill `skeid-relay-routes`), `usage_store` (skill `skeid-usage`).

- **Admin key**, resolved on every applied config: explicit (`serve --admin-api-key`,
  `build_app(admin_api_key)`, `new(admin_api_key)`, `set_admin_api_key`) > config (first of the
  four spellings present; empty disables) > `SKEID_ADMIN_API_KEY` > off (skeid k64).
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

## Admin API

`/skeid/*` under bearer auth against `admin_api_key` (constant-time, `Skeid::Secret`): with no
admin key the whole surface answers `404`, not `401` — the feature is absent, not a failed login.
`GET /skeid/nodes`, `POST /skeid/nodes`, `POST /skeid/nodes/:id/health`,
`GET /skeid/metrics/nodes`, `GET /skeid/usage`, `GET /skeid/config` (`reload_status`: last reload
error, `failed_at`, `failures`). `GET /skeid/registry/snapshot` sits outside that block: registry
read key or admin key, 404 unless `registry.enabled`. Public `GET /health` carries
`config_reload` without the message and stays `status: ok` while a reload fails.
