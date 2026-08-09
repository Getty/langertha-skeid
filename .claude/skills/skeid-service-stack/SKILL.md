---
name: skeid-service-stack
description: "Deploying Skeid — OpenBao KeyBroker and AppRole token lifecycle, the docker compose stack (openbao + postgres + skeid), ENV surface, customer keys, usage schema, Docker image build."
user-invocable: false
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

How Skeid runs in production and what the example stack under `examples/service/` actually
does. Vocabulary (**Key broker**, **Key reference**, **Customer key ID**, **AppRole token
lifecycle**) is in `CONTEXT.md`.

## The security model in one paragraph

The container boots with an AppRole `role_id` + `secret_id` in its environment, logs into
OpenBao, keeps the resulting token **in memory only**, and renews it on a timer. Provider keys
and customer keys are read from OpenBao per use and never persisted. If renewal fails the
process dies and the orchestrator restarts it, which forces a fresh login. Nothing here is an
optimisation target: a disk cache of the token, a key written to a config file, or a "reuse
the old token if renewal fails" fallback each destroy the property the design exists for.

## KeyBroker::OpenBao

Two clients on purpose: `Mojo::UserAgent` for the request path, `HTTP::Tiny` for boot and for
callers with no IO loop (CLI, tests, setup scripts).

| Method | Does |
|---|---|
| `BUILD` | AppRole login → stores the returned token |
| `needs_refresh` | true within 60s of expiry, or when no client token exists yet |
| `refresh` | `auth/token/renew-self` → new client token + new expiry; **dies** on failure |
| `resolve_key($ref)` | blocking: refresh-if-needed, then KV-v2 read; returns `data.data.api_key` |
| `resolve_key_async($ref, $cb)` | the same, non-blocking; falls back to the blocking path with no IO loop running |
| `start_renewal` | renews on a timer instead of when a request notices; called by `build_app` |
| `list_secrets($path)` | `LIST` under a path; returns key names |

**The request path calls `key_async` and nothing else** — that is the base class's entry point
(see below), and `resolve_key` from a handler blocks every other in-flight request for a whole
vault round-trip. `t/27-keybroker-nonblocking.t` fails if that ever comes back.

`verify_ssl` defaults to **1**. `OPENBAO_VERIFY_SSL=0` exists for a dev vault with a
self-signed certificate; on a real `https://` address it hands the AppRole token to anyone who
can intercept the connection.

Path handling: a **Key reference** is written in logical form (`secret/skeid/remote/groq`) and
rewritten to the KV-v2 API path (`secret/data/skeid/remote/groq`) on read. Config, tickets and
logs use the logical form. A failed read logs the reference and the HTTP status — never the
response body, which may carry what was being read.

Auto-wiring: `Proxy->build_app` constructs the broker when `OPENBAO_ROLE_ID` and
`OPENBAO_SECRET_ID` are both set, then starts its renewal timer. A failure there warns and
leaves Skeid running without a broker — nodes then fall back to `api_key_env` or client
pass-through.

## KeyBroker base class — what every broker gets

A subclass implements `resolve_key` (blocking, one reference, dies or returns undef when it
cannot). Everything else lives in `Langertha::Skeid::KeyBroker`:

| Method | Does |
|---|---|
| `key_async($ref, $cb)` | **the request path's entry point**: cache, coalescing, then `resolve_key_async` |
| `resolve_key_async` | default implementation calls the blocking `resolve_key`; override to do better |
| `cached_key($ref)` | the live cache entry, distinguishing "cached failure" from "not cached" |
| `forget_key([$ref])` | drop one or all — what a key rotation calls |

`cache_ttl` 300s, `negative_cache_ttl` 5s (a vault outage must not become a round-trip per
request), and concurrent misses for one reference collapse into a single resolution — without
that, a cold start at concurrency 64 is 64 identical vault calls. A memory cache is explicitly
allowed by ADR 0003; a disk cache is not, at any TTL, for any reason.

## Compose stack

`examples/service/docker-compose.yml` — three services plus a one-shot init:

| Service | Host port | Purpose |
|---|---|---|
| `openbao` | 5501 → 8200 | dev-mode vault, file backend |
| `postgres` | 5533 → 5432 | usage store |
| `skeid` | 5591 → 8090 | the proxy |
| `skeid-init` | — | `profiles: [init]`, runs `init-skeid.sh` once |

```bash
cd examples/service
docker compose --profile init up skeid-init   # once: approle, policy, keys, schema
docker compose up -d                          # the stack
docker compose logs -f skeid
docker compose exec openbao bao status
```

`init-skeid.sh` (root token, one shot): enables `approle`, creates role `skeid-service`, prints
`role_id` + `secret_id`, writes the read policy for `secret/skeid/*`, stores provider keys from
`SKEID_OPENAI_KEY` / `SKEID_ANTHROPIC_KEY`, seeds demo **Customer key IDs** (`alice`, `bob`,
`charlie`, `testuser123`), and applies `usage_schema.sql`.

The printed `role_id`/`secret_id` go into a **local, untracked** `.env`; only `.env.example`
is committed. The dev root token, the Postgres password and the demo customer keys in the
compose file and init script are placeholders — a real deployment overrides every one of them
and does not run OpenBao in dev mode.

## ENV surface

| Variable | Used by | Meaning |
|---|---|---|
| `OPENBAO_ADDR` | broker | default `http://127.0.0.1:8200` |
| `OPENBAO_ROLE_ID` / `OPENBAO_SECRET_ID` | broker | AppRole credentials; both present ⇒ broker is wired |
| `OPENBAO_VERIFY_SSL` | broker | `0` disables TLS verification — dev vault only |
| `SKEID_ADMIN_API_KEY` | control plane | bearer token for `/skeid/*` |
| `SKEID_USAGE_DB` | control plane | sqlite path / DSN for the usage store |
| `SKEID_USAGE_DB_PASSWORD` | usage store | target of `password_env` in the YAML |
| `SKEID_REMOTE_KEY_REF` | deployment | key reference a node config points at |
| `SKEID_ROUTE_WAIT_TIMEOUT_MS` / `SKEID_ROUTE_WAIT_POLL_MS` | routing | saturation wait defaults |
| `SKEID_TRUST_KEY_ID_HEADER` | proxy | believe the client's `x-skeid-key-id` — only behind an authenticating gateway |
| `SKEID_UPSTREAM_POOL` | proxy | upstream connection pool size (default 100) |

**Precedence trap:** an ENV default only survives while no config file sets the same thing.
`reload_config` rewrites `admin_api_key` from the file on every reload, and in config-managed
mode an absent key means empty — which disables `/skeid/*` (404). ENV plus config file is not
"whichever is set wins".

## Node config with keys

```yaml
nodes:
  - id: groq-main
    url: https://api.groq.com/openai/v1
    model: llama-3.3-70b-versatile
    engine: openai
    api_key_ref: secret/skeid/remote/groq   # KeyBroker (preferred)
  - id: local-vllm
    url: http://vllm:8000/v1
    model: qwen2.5-7b
    engine: vllm
    api_key_env: VLLM_TOKEN                 # fallback when there is no broker
```

## Usage schema

`share/sql/usage_events.postgresql.sql` and `usage_events.sqlite.sql` are the shipped schemas;
`examples/service/usage_schema.sql` is the copy the init container applies. `auto_migrate`
(default on) applies the shipped file at configure time, so the init step is a convenience,
not a requirement. Reports: `bin/skeid usage --json`, or `GET /skeid/usage`.

## Docker image

Built and pushed by `dzil release` via `run_after_release` (see the release rule — never run
that yourself). Tags: `raudssus/langertha-skeid:<version>`, `:<major>`, `:latest`. Source
overrides for unreleased Langertha/Knarr go through `SKEID_DOCKER_BUILD_ARGS`, documented at
the top of `dist.ini`. For a local test image: `docker build -t raudssus/langertha-skeid:test .`
— which is the tag the compose file's `skeid` service actually references.
