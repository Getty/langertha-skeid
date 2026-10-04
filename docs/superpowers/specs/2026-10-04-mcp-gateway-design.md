# Design — MCP gateway: assigned MCP servers behind the customer's Skeid key

- Status: implemented on branch `mcp-gateway` (skeid k103), awaiting review
- Date: 2026-10-04
- Companion ADR: `docs/adr/0022-mcp-servers-are-relayed-per-customer-key-not-aggregated.md`
- Vocabulary: `CONTEXT.md` (Customer key ID, Customer name, Client authentication, Key reference,
  Key broker, Usage event, Relayed route; new: MCP server, MCP assignment, MCP relay, Local MCP
  server)

## 1. Problem

CitiAI hands every customer one Skeid client key. The operator wants to give a customer MCP
servers as well, and have the customer wire each of them into its client (Hermes Agent, Claude
Code, Codex) with that same key — one credential, one place that says who may reach what.

Skeid is the place: it already derives a **Customer key ID** from the presented key, already
answers `401` to a key that may not come in (ADR 0020), and already holds upstream credentials
in memory only (ADR 0003). What is missing is a route that relays MCP "Streamable HTTP" to an
upstream the operator assigned to that key, and a route that tells a key what it was assigned.

## 2. Scope

In: an authenticating reverse proxy for MCP Streamable HTTP per assigned server; a listing of
a key's assigned servers; the config section; a usage event per relayed request.

Out: merging the tool lists of several servers, starting stdio processes, OAuth per end user,
an admin API that changes assignments at run time, deployment.

Skeid does not read MCP. It relays HTTP: a method, a body, a handful of headers, a status, a
body or an event stream. That is the stance of ADR 0021 (relayed, not translated), taken one
step further — there is not even a field Skeid has to read.

## 3. Configuration

```yaml
names:
  alice: k_5f0e1a2b3c4de5f60718293a4b5c6d7e8f901a2b      # `skeid keyid <key>` -- never the key

mcp:
  public_url: https://llm.citilan.de       # optional: where clients reach Skeid
  servers:
    bookrag:                               # the name in /mcp/bookrag
      url: http://bookrag-mcp.internal:8080/mcp
      description: Book search over the house library
      api_key_ref: secret/skeid/mcp/bookrag   # upstream credential through the key broker ...
      api_key_env: BOOKRAG_MCP_KEY            # ... or from this variable; sent as Authorization: Bearer
      headers: { X-Tenant: citilan }          # static headers that are no secret
      keys: [alice, k_9c8b7a6f5e4de5f60718293a4b5c6d7e8f901a2b]
    files:
      transport: stdio                     # a hint: runs on the customer's machine
      command: mcp-files
      args: ["--root", "/srv/data"]
      env: {}
      description: Files on your own machine
      keys: [alice]
```

Decisions, each against the form proposed in the brief:

- **`public_url`, not `public_base_url`.** The manifest section already calls "where clients
  reach Skeid" `public_url`. Optional here: without it the listing builds its URLs from the
  request (scheme and host as the server sees them — behind a TLS proxy that is `http://`
  unless Mojolicious runs in reverse-proxy mode, so an edge deployment sets it).
- **The upstream credential is `api_key_ref` / `api_key_env`, not a `headers` value.** A header
  value in the YAML would be a secret on disk, which ADR 0003 rules out. These are the two keys
  a node already has, with the same order (broker first, then the variable) and the same
  fail-closed rule: a server that names a key source which yields no key is not called (`503`).
  The key goes upstream as `Authorization: Bearer <key>`.
- **`headers:` stays, for what is no secret.** `Authorization`, `Proxy-Authorization`,
  `X-Api-Key` and `Cookie` are refused there at load, as are the headers the relay owns
  (framing, `Host`, and the ones passed through from the client). The error names the header,
  never its value.
- **`keys:` is the assignment**: `names:` entries or key ids, resolved at config load into a set
  per server, exactly like `client_auth.keys` — the same entry check, the same error by
  position, the same short-id prefix match (ADR 0016). A server without `keys` is assigned to
  nobody and says so once at load.
- **`transport`** is `streamable-http` (default, needs `url`) or `stdio` (needs `command`;
  `args` a list of strings, `env` a map of strings). A `stdio` entry is a hint only (section 6).
  Keys of the other transport on an entry fail the load.
- **Strict section**, like `client_auth` and `uploads`: an unknown key, a server name that is
  not `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`, a `url` that is not absolute `http(s)` or carries
  userinfo, fail the load and keep the previous config in force.
- **Absent means off**, removed on reload means off again. Without the section both routes
  answer exactly what an unknown path answers (section 4).

Resolved once at config load into `mcp_servers` (name → resolved entry) and `mcp_public_url`;
both are part of the state a failed reload rolls back. A request costs two hash lookups.

## 4. Routes

```
GET             /v1/mcp/servers        the servers assigned to the presented key
POST|GET|DELETE /mcp/<name>            relayed to the server's url
POST|GET|DELETE /mcp/<name>/<path>     relayed to url + /<path>
```

One bridge in front of both, in this order:

1. Pick up a changed config (`maybe_reload_config`), as every client route does.
2. No `mcp:` section → the answer of an unknown path (`reply->not_found`), **before** client
   authentication. A Skeid without the section must not start answering `401` on a path that
   was a `404` yesterday.
3. Client authentication (`_authorize_client`, ADR 0020): `401` in the OpenAI shape with
   `WWW-Authenticate: Bearer realm="skeid"`.
4. No key at all → the same `401` (`Missing API key`), also when `client_auth` is off. An MCP
   server is assigned to a key id; `anonymous` can hold none, and "you sent no key" is the more
   useful answer than an empty list or a `404`. (The provider manifest does the same.)

Identity is `_request_api_key_id`, the one routing uses — so `routing.trust_key_id_header`
applies here as it does everywhere.

### 4.1 `GET /v1/mcp/servers`

```json
{"object":"list","data":[
  {"name":"bookrag","transport":"streamable-http","url":"https://llm.citilan.de/mcp/bookrag","description":"…"},
  {"name":"files","transport":"stdio","command":"mcp-files","args":["--root","/srv/data"],"env":{},"description":"…"}
]}
```

Sorted by name; `description` always present (empty when the config has none). Only what is
assigned to the presented key. Never the upstream `url`, the key reference, the variable name
or the static headers. `Cache-Control: private, no-store` and the manifest's `Vary`, because
the answer depends on who asks.

### 4.2 The relay

- **`404` for everything that is not a server of this key**: an unknown name, a name assigned
  to another key, a `stdio` entry, a sub-path with a `.` or `..` segment or a backslash. One
  body for all of them (`not_found`), so a key cannot learn which names exist.
- **Request.** Method and body as they came; the body is the bytes the client sent. Passed
  upstream: `Content-Type`, `Accept`, `Last-Event-ID` and every `Mcp-*` header
  (`Mcp-Session-Id`, `Mcp-Protocol-Version`, and whatever the protocol adds under that
  prefix). Nothing else of the client's — in particular not `Authorization`, `X-Api-Key`,
  `Cookie`, `x-skeid-key-id` or forwarding headers. Then the server's `headers`, then
  `Authorization: Bearer <key>` when the server names a key source. The client's query string
  is appended to the configured URL's.
- **Sub-paths** exist for an upstream that needs more than one endpoint. `<path>` is appended
  to the configured URL's path segment by segment; dot segments are refused rather than
  normalised, so a key cannot climb out of the path the operator configured.
- **Answer.** Status and headers as the upstream gave them, but for the framing ones
  (`Content-Length`, `Transfer-Encoding`, `Content-Encoding`) — the rule every relayed answer
  follows — plus Skeid's `x-request-id`. The headers go out the moment the upstream's arrive,
  before any body byte, and every chunk is written as it is read: an event stream is not
  buffered, and a standing `GET` stream is open for the client before its first event.
- **One exception to "as the upstream gave it": an upstream `401` becomes `502`.** Towards the
  client `401` means "your Skeid key is not let in", and MCP clients act on it (they start an
  OAuth discovery against the host). An upstream `401` means *Skeid's* credential is wrong — an
  operator fault. It is logged with the server name and answered `502 upstream_error`.
- **No key for the upstream** (a named `api_key_ref` / `api_key_env` yields nothing): `503
  upstream_key_unavailable`, no upstream call, logged with the reference — a node's rule.
- **Unreachable upstream**: `502 upstream_error`.
- **Time limit.** The upstream call runs under `SKEID_UPSTREAM_TIMEOUT` (default 300 s) and
  the client connection is extended by the same amount, as for an LLM stream. A standing
  stream is therefore cut after that time; MCP clients reconnect with `Last-Event-ID`.
- **A client that hangs up** closes the upstream connection, as on every other route.
- **A body over the server's request limit** (16 MiB) is `413`; it is never relayed truncated.

No routing, no admission: an MCP server is not a **Node**. There is no `request.start`, no
`max_conns`, no capacity probe and no health flag.

## 5. Usage

One **Usage event** per request that got as far as an upstream call or its refusal for want
of a key, in the existing schema with no new field:

| field | value |
| --- | --- |
| `api_format` | `mcp` |
| `endpoint` | `/mcp/<name>` (the server, without the sub-path) |
| `api_key_id` | the customer key id |
| `route_url` | the server's configured `url` |
| `status_code`, `ok`, `duration_ms` | as below |
| `model`, `requested_model`, `node_id`, `engine`, tokens, costs | empty / zero |

`status_code` is the upstream's status and `ok` is `status < 500`, with these cases apart:

- upstream `401` → `502`, `ok = 0`, `error_type: upstream_unauthorized`
- no upstream key → `503`, `ok = 0`, `error_type: upstream_key_unavailable`
- no answer at all → `502`, `ok = 0`, `error_type: upstream_error`
- client hung up before or during a plain answer → `499`, `ok = 0`, `error_type: client_abort`
- an answer with framing that was cut short → the status, `ok = 0`, `error_type: upstream_error`
- **an event stream that was opened**: the status, `ok` by the status, however it ends —
  client, upstream or the time limit. An SSE stream has no end Skeid could verify without
  reading MCP, and a standing stream normally ends by one side closing it. `duration_ms` is
  how long it was open.

`401` and `404` write nothing: nothing was forwarded.

## 6. `stdio` entries

A `stdio` entry describes a server that runs on the customer's own machine. Skeid neither
starts nor reaches it; the entry exists so the listing can tell a client "configure this
locally". It has no `/mcp/<name>` route (`404`). `command`, `args` and `env` are shown to the
assigned key as written — they are a message to the customer, so they must not hold secrets.

## 7. Code

- `Langertha::Skeid` — `_load_mcp` (after the policies, so `names:` resolve), attributes
  `mcp_servers` and `mcp_public_url`, methods `mcp_enabled`, `mcp_server_for_key`,
  `mcp_servers_for_key`. The entry check of `client_auth.keys` is shared (`_key_id_set`).
- `Langertha::Skeid::Protocol::MCP` — what Skeid knows of the wire: the transports, which
  request headers travel, the listing entry, the upstream URL of a sub-path.
- `Langertha::Skeid::Proxy` — the bridge, `_handle_mcp_servers`, `_handle_mcp` and `_relay_mcp`.
  The key lookup of `_inject_node_auth_async` is split out as `_upstream_key_async` and used by
  both. The relay is its own function: `_proxy_openai_stream` is built around a node — its
  slot, its capacity headers, the usage frames of an LLM stream — and none of that exists here.

## 8. Tests

`t/72-mcp-gateway.t`, against a fake MCP upstream (a Mojolicious app that answers JSON, an
event stream it holds open on command, `202`, `401`, and records the headers it received):
assigned → `200` with body and headers both ways; the stream arrives event by event while the
upstream still holds it; `Mcp-Session-Id` there and back; the client's `Authorization` never
arrives upstream and the server's does; unassigned, unknown, `stdio` and dot-segment paths →
the same `404`; no key and unlisted key → `401`; the listing per key without upstream details;
no `mcp:` section → the unknown-path answer, with and without `client_auth`; reload on and off;
load errors; the usage events.

## 9. Open — decisions for the maintainer

1. **MCP events share the ledger with LLM events.** They add to `totals.requests` and to each
   key's `requests` in `skeid usage`, and appear under model `(none)`. Nothing is priced. If the
   report should count LLM requests only, it needs a filter on `api_format` — a report change,
   not a schema change. An MCP session is many small requests, so a `jsonlog` directory store
   gets many small files.
2. **The method is not on the event.** A standing `GET` stream and a `POST` look alike in the
   ledger but for their duration. Adding it would be a new column.
3. **Upstream credentials are `Authorization: Bearer` only.** A secret in another header or
   scheme has no config form yet (it would be a map of header name to variable or key
   reference).
4. **No per-server concurrency limit and no health flag.** A server is not a node; if one has
   to be protected from a customer, that is a new mechanism.
5. **Sessions are not bound to keys.** `Mcp-Session-Id` is the upstream's. Two keys assigned
   the same server could use each other's session if they knew its id. With one server per
   customer, as planned, this does not arise; a shared server would need Skeid to remember
   which key opened which session.
6. **No "every key" assignment.** `keys:` lists ids; there is no `'*'`.
7. **Standing streams are cut at `SKEID_UPSTREAM_TIMEOUT`.** The user agent has one time limit
   for all upstream calls. A separate, longer limit for MCP streams would need a second user
   agent.
8. **The upstream `401` → `502` mapping** is the one place the relay changes an answer. If a
   deployment ever wants per-end-user OAuth passed through, this is the line to revisit.
