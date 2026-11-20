Read when touching the upstream URL, forwarded headers, node key injection (KeyBroker, `api_key_env`, `api_key_header`), customer key IDs or client authentication.

# Upstream call

`POST {node.url}/chat/completions` or `/embeddings`; a relayed route posts to its own path; a
`rerank_format: tei` node is called at its server root (`_root_url_for_node`).
`_endpoint_url_for_node($base, $path)` appends `/v1` unless the node url already ends in `/v1`.
A node url is a base, never a full endpoint.

`_forward_headers` passes the client's headers minus the hop-by-hop set (`connection`,
`keep-alive`, `proxy-authenticate`, `proxy-authorization`, `te`, `trailer`, `transfer-encoding`,
`upgrade`) and `host`, `content-length`, `accept-encoding`. `_inject_node_auth_async` then
overrides `Authorization`:

1. **KeyBroker**, if the node has `api_key_ref` — per request through `key_async` (in-memory
   cache, coalesced misses; never `resolve_key` on the request path).
2. **`api_key_env`** fallback — key from that environment variable.
3. Neither **configured** → the client's own `Authorization` survives (pass-through deployments).

A node with `api_key_header` (docling's `X-Api-Key`) gets the raw key in that header instead of
`Authorization: Bearer`; dropping the client's credentials and the fail-closed rule are the same.
- When a key is injected, the client's `Authorization` and `x-api-key` are dropped first, in any
  spelling (`_drop_client_credentials`; Mojolicious hands `X-Api-Key` on as written, and an
  exact-case delete forwards it beside the node's key) — an Anthropic-style client never leaks
  its key upstream.
- A resolve failure warns with the reference — never the key or a vault response body — and falls
  through to `api_key_env`.
- **A configured key source that yields no key fails closed.** Broker error or cached failure, no
  broker at all (failed OpenBao login at boot), variable unset or empty, or a node that left the
  inventory after selection: the callback gets a reason, both callers answer through
  `_refuse_unkeyed_node` — no upstream call, `request.finish` with `ok => 0`, one failed usage
  event, `503 upstream_key_unavailable` in the face's error shape. Pass-through is only for a node
  naming *no* key source; taking it for a node whose key went missing sends the customer's key to
  the provider. The reason (reference, variable name) goes to log and usage event, not to the
  client. `t/61-node-key-fail-closed.t` fails if the pass-through comes back.

# Caller identity

- **Customer key ID** derives from the presented key (`Authorization` bearer, else `x-api-key`):
  `k_` + full SHA-1 hex (`Langertha::Skeid->key_id_for_key`, ADR 0016), or `anonymous`. A legacy
  12-hex id in the config still matches by prefix. The raw key is never stored, logged or
  reported — the hash exists so metering works without keeping it.
- `x-skeid-key-id` (or `x-api-key-id`) overrides **only** when `routing.trust_key_id_header` is
  set (callers authenticated before Skeid). Never the default, never a second way in: the ADR 0008
  routing policy hangs off this id, so a client-settable id turns permissions into a suggestion.
  `t/26-key-policies.t` fails if that check goes away.
- **A key can also arrive in the subprotocol** (`Sec-WebSocket-Protocol:
  openai-insecure-api-key.<key>`, a browser's WebSocket cannot set a header): only on
  `/v1/realtime`, only when neither `Authorization` nor `x-api-key` is present, never answered,
  logged or forwarded (`_extract_request_api_key`; skill `skeid-relay-routes`).
- **Client authentication** (`client_auth:`, ADR 0020) is the only place a key is refused for
  *who* it is: every client route's `under` bridge (`_authorize_client`) reloads the config, then
  answers `401` + `WWW-Authenticate` in the face's dialect to an id not on the list — before body
  parsing, `request.start`, broker, upstream or usage event. A new client route goes behind its
  face's bridge, or it is an open door. `/health` and `/skeid/*` stay outside.
  `t/67-client-auth.t`. The MCP routes call the same gate from their own bridge.
- `x-request-id` is honoured if present, else a `req_<ms>_<rand>` id is generated.
