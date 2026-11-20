Read when touching `/mcp/<name>`, `_relay_mcp`, `_authorize_mcp_client`, `Protocol::MCP` or the `mcp:` config section.

# MCP gateway

`/mcp/<name>` relays MCP Streamable HTTP to an **MCP server** assigned to the presented key;
`Langertha::Skeid::Protocol::MCP` owns the wire. Skeid reads nothing of MCP. It is **not** a
relayed route in ADR 0021's sense and does not go through `_begin_route_async` or
`_proxy_openai_*`: no node, so no `request.start` / `request.finish`, no capacity headers, no usage
frame. `_relay_mcp` is its own function.

Config (skeid k103, ADR 0022):

```yaml
mcp: { public_url, servers: { name: { url, description, api_key_ref, api_key_env, headers, keys } } }
```

- `_load_mcp` resolves it after the policies into `mcp_servers` (name → entry with a `keys` id
  set) and `mcp_public_url`, both in `@CONFIG_STATE`. An **MCP server** is not a **Node**: no
  routing, no admission, no health, no probe. `mcp_server_for_key($name, $id)` answers undef for an
  unknown name and for another key's server alike. A server's `keys:` and `client_auth.keys` share
  `_key_id_set` (entry check, error by position, short-id prefix).
- Strict section: unknown keys, keys of the other transport (`stdio` vs `streamable-http`), a URL
  with userinfo and a credential under `headers:` fail the load.

Request path:

- Bridge `_authorize_mcp_client`, in this order: reload; no `mcp:` section → `reply->not_found`
  (the unknown path it was, **before** the client gate); `_authorize_client`; no key → `401` even
  without `client_auth`.
- `404 not_found`, one body, for an unknown name, another key's server, a `stdio` entry and a
  sub-path with a `.`/`..` segment or a backslash (`upstream_url` returns nothing). Never tell these
  apart in an answer.
- Up: method, body bytes (`$c->req->body`), `Content-Type`, `Accept`, `Last-Event-ID`, every
  `Mcp-*` header — an allowlist (`request_headers`), not `_forward_headers`. Then the server's
  static `headers`, then `Authorization: Bearer` from `_upstream_key_async` (the broker / env
  lookup `_inject_node_auth_async` uses too). A named key source without a key: `503`, no call. No
  key source: no `Authorization` at all — the client's is never passed through.
- Down: the response is opened on the first `read` (upstream headers parsed) and flushed with an
  argument-less `$c->write_chunk`, then every chunk is written as read. An answer without a body
  (`202`) never emits `read` and is rendered in the completion callback. Hop-by-hop headers,
  `Content-Length` and `Content-Encoding` are not copied.
- Upstream `401` → `502 upstream_error` + error log (`upstream_unauthorized` on the event); an
  upstream `3xx` likewise (`upstream_redirect`; no redirect is followed, `Location` never relayed).
  Every other status is the server's, `404` for an expired session included.
- Usage event: `api_format: mcp`, `endpoint: /mcp/<name>`, no model/node/tokens. An opened event
  stream is recorded under its status however it ends; a plain answer the client abandons is
  `499 client_abort`.
- `t/72-mcp-gateway.t`; 14 mutations of the logic were checked to fail it.
