Read this when adding, renaming or looking up an environment variable, or deciding whether a value comes from ENV or the config.

| Variable | Used by | Meaning |
|---|---|---|
| `OPENBAO_ADDR` | broker | default `http://127.0.0.1:8200` |
| `OPENBAO_ROLE_ID` / `OPENBAO_SECRET_ID` | broker | AppRole credentials; both present ⇒ broker is wired |
| `OPENBAO_TOKEN_FILE` | broker | instead of AppRole (k127): token from a file a starter keeps current; read at start (missing/empty dies), again on change and every `renew_secs`; never renewed by Skeid; both modes set ⇒ `build_app` dies |
| `OPENBAO_VERIFY_SSL` | broker | `0` disables TLS verification — dev vault only |
| `SKEID_ADMIN_API_KEY` | control plane | bearer token for `/skeid/*` |
| `SKEID_USAGE_DB` | control plane | sqlite path, used only when the config has no `usage_store` |
| `SKEID_USAGE_DB_PASSWORD` | example stack | what its `usage_store.password_env` names |
| `SKEID_CUSTOMER_DB_PASSWORD` | example stack | what its (commented) `customer_source.password_env` names: the read-only role of the customer view |
| `SKEID_ROUTE_WAIT_TIMEOUT_MS` / `SKEID_ROUTE_WAIT_POLL_MS` | routing | saturation wait defaults |
| `SKEID_FRONTEND_COUNT` | routing | Skeid hosts sharing the nodes (ADR 0012), default 1 |
| `SKEID_CAPACITY_MAX_AGE_MS` | admission | capacity reading lifetime, default 5000 |
| `SKEID_CONFIG_RELOAD_INTERVAL` | control plane | `config_loader` re-run interval in seconds, default 1 |
| `SKEID_TRUST_KEY_ID_HEADER` | proxy | believe the client's `x-skeid-key-id` — only behind an authenticating gateway |
| `SKEID_UPSTREAM_POOL` | proxy | upstream connection pool size (default 100) |
| `SKEID_UPSTREAM_TIMEOUT` | proxy | seconds an upstream request may take and be silent for (default 300); the client connection of a proxied request gets the same on top of the server's inactivity timeout |

Secrets the config needs are named, never written: a node's `api_key_env`,
`admin.api_key_env`, a usage store's and a customer source's `password_env`, and the
registry's `secret_env` / `read_key_env`. `customer_source` refuses a `password:` outright.

**Precedence:** a value in the config wins over its ENV default. The admin key is resolved on
every reload as `serve --admin-api-key` > the config's key (any of its four spellings; set empty
it disables `/skeid/*`, 404) > `SKEID_ADMIN_API_KEY` > off (skeid k64).
