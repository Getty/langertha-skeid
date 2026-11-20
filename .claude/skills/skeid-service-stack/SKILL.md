---
name: skeid-service-stack
description: Use when deploying or operating Skeid, or when a change touches how it gets upstream keys — KeyBroker/OpenBao, the examples/service compose stack, the Docker image, ENV variables, node keys, the customer source or usage store setup.
user-invocable: false
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

How Skeid runs in production and what `examples/service/` does. Vocabulary (**Key broker**,
**Key reference**, **Customer key ID**, **AppRole token lifecycle**) is in `CONTEXT.md`.

## Security model

The container boots with an AppRole `role_id` + `secret_id` in its environment, logs into
OpenBao, keeps the resulting token **in memory only**, and renews it on a timer. Provider keys
are read from OpenBao when a node needs one, cached in memory only, and never persisted.
Customer keys are never looked up at all: a caller's identity is the digest of the key it
presented (`skeid keyid`). If renewal fails the process dies and the orchestrator restarts it,
which forces a fresh login.

## Rules every change here needs

- **No disk cache of token or key, at any TTL; no key in a config file; no "reuse the old
  token if renewal fails" fallback.** Each destroys the property the design exists for (ADR 0003).
- **The request path calls `key_async` and nothing else.** `resolve_key` from a handler blocks
  every in-flight request for a vault round-trip; `t/27-keybroker-nonblocking.t` guards it.
- **A failed read logs the reference and the HTTP status — never the response body.**
- **Secrets in config are named, never written** (`api_key_env`, `password_env`, `secret_env`,
  `read_key_env`); `customer_source` refuses `password:` outright.
- **Key references use the logical form** (`secret/skeid/remote/groq`); the broker rewrites to
  `secret/data/…`. But OpenBao *policies* must name KV-v2 paths (`secret/data/skeid/*`) — a
  policy on the logical path denies every read.
- **No fallback to the client's key** when the broker is missing: a node with `api_key_ref` and
  no set `api_key_env` gets `503 upstream_key_unavailable`. Pass-through is only for a node that
  names no key source.
- **Only `examples/service/.env.example` is tracked** — `git ls-files examples/service/.env`
  must print nothing.
- **Keep `STOPSIGNAL SIGQUIT`.** `SIGTERM` loses the usage write-behind queue and drops realtime
  sessions without their events. Never run `dzil release` or push an image yourself.

## Where to read

| For | Read |
|---|---|
| `KeyBroker`/`::OpenBao` methods, token refresh, `verify_ssl`, key cache and coalescing, `build_app` auto-wiring | `references/openbao.md` |
| The compose stack, ports, bring-up commands, `init-skeid.sh`, dev-mode restarts, `.env` | `references/compose.md` |
| Every ENV variable, secrets-by-name, config-vs-ENV and admin-key precedence | `references/env.md` |
| Node entries with `api_key_ref`/`api_key_env`, realtime nodes and `max_conns` under prefork | `references/node.md` |
| Customer source deployment (view, role, connections), usage schema, `auto_migrate`, write-behind | `references/config.md` |
| `Dockerfile` stages, tags, local test image, uid 10001, volumes and mounts | `references/image.md` |
