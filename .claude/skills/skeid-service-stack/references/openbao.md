Read this when changing or debugging key resolution — `KeyBroker`, `KeyBroker::OpenBao`, the token lifecycle, the key cache, or how `build_app` wires the broker.

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
leaves Skeid running without a broker — a node with `api_key_ref` then needs a set
`api_key_env`, or every request routed to it is refused with `503 upstream_key_unavailable`.
It never falls back to the client's key; pass-through is only for a node that names no key
source.

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
