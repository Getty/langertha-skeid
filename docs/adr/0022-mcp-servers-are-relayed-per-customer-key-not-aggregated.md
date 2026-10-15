# ADR 0022 — MCP servers are assigned per customer key and relayed, not aggregated; an MCP server is not a node

- Status: accepted — implemented (skeid k103)
- Date: 2026-10-04
- Tags: mcp, relay, auth, identity, config, proxy, secrets, usage

---

## Context

A customer of a Skeid deployment holds one client key. The operator wants to hand the same
customer MCP servers — a retrieval server over the customer's documents, say — and have the
customer wire each of them into its client (Claude Code, Codex, Hermes Agent) with that one
key. The MCP servers themselves sit on an internal network and know nothing of customers.

Skeid already has the three things this needs: a **customer key id** derived from the presented
key (ADR 0008, ADR 0016), an allowlist that answers `401` (ADR 0020), and upstream credentials
that exist in memory only (ADR 0003). What it lacked was a place to say which key has which MCP
server, and a route that carries MCP's "Streamable HTTP" transport to it.

Two shapes were possible. An *aggregating* gateway presents one MCP endpoint per customer and
merges the tools of all assigned servers behind it; it has to speak MCP — initialise sessions,
rewrite tool names, fan out `tools/list`, route `tools/call`, track every protocol revision. A
*relaying* gateway gives each server its own URL and passes HTTP through. MCP clients take a
list of servers natively, so aggregation buys the customer nothing a second config line does
not, and costs Skeid a protocol implementation.

## Decision

**An optional `mcp:` section assigns MCP servers to customer key ids. Each assigned server is
reachable at `/mcp/<name>` with the customer's own Skeid key, and Skeid relays the request and
the answer without reading either. `GET /v1/mcp/servers` tells a key what it was assigned.**

```yaml
mcp:
  public_url: https://llm.example.com
  servers:
    bookrag:
      url: http://bookrag-mcp.internal:8080/mcp
      description: Book search over the house library
      api_key_ref: secret/skeid/mcp/bookrag
      keys: [alice]
    files:
      transport: stdio
      command: mcp-files
      args: ["--root", "/srv/data"]
      keys: [alice]
```

- **Relayed, and not even read.** ADR 0021 relays a non-chat route but still reads `model` to
  route by. Here there is nothing to route, so there is no field Skeid reads: the method, the
  body as bytes and a fixed set of headers go up; the status, the headers and the body or event
  stream come down. No JSON-RPC, no tool list, no session table. A new MCP revision that keeps
  the transport needs no change in Skeid.
- **One name, one server; nothing is merged.** A key with three servers configures three URLs.
- **An MCP server is not a node.** A node serves a model and is routed to; routing, eligibility,
  admission, `max_conns`, health and capacity probes are all about choosing among nodes. An MCP
  server is addressed by name and there is exactly one of it. Declaring it under `nodes:` would
  put a thing without a model into the model router. It gets its own section and none of the
  routing machinery.
- **So the relay is its own function**, `_relay_mcp`, and this does not reopen ADR 0001 or ADR
  0021. Their rule — no second upstream code path — protects what every node call must do
  exactly once: `request.start` / `request.finish`, capacity observation, metering from the
  usage frame. None of that exists for an MCP server. What does exist in both is shared: the
  upstream key lookup (`_upstream_key_async`, split out of the node path), the raw-bytes
  response content, cancelling the upstream when the client leaves, the client timeout, the
  usage event writer, the error shape.
- **The assignment is `keys:` on the server**, a list of key ids or `names:` entries resolved
  at config load into an id set, by the same code as `client_auth.keys`: the same entry check,
  the same error by position, the same short-id prefix match (ADR 0016). It is a third
  decision beside "may this key come in" (ADR 0020) and "which models may it reach" (ADR
  0008), and independent of both. The servers are few and the customers many, so the list
  lives where the server is declared; `keys:` (the policy table) stays the policy table.
- **Not assigned is `404`, never `403`.** An unknown name, a server assigned to other keys, a
  `stdio` entry and a sub-path that climbs out of the configured path all get one body. A `403`
  would tell a key that the name exists. This is the one place Skeid prefers hiding to
  explaining; a model name is not a secret, a customer's server name may be.
- **The same gate, then a key.** The routes run `_authorize_client` like every client route.
  After it, a request without any key is `401` even when `client_auth` is off: a server is
  assigned to a key id, and no key has none. An unlisted key under no `client_auth` is simply a
  key without servers — `404`, or an empty listing.
- **Without the section the routes do not exist**, and that check comes *before* the gate: a
  Skeid with `client_auth` and no `mcp:` answers `/mcp/x` as the unknown path it always was,
  not `401`.
- **The client's key never goes upstream.** Request headers are an allowlist — `Content-Type`,
  `Accept`, `Last-Event-ID`, every `Mcp-*` — not the "everything but hop-by-hop" of a node
  call. A node without a key of its own forwards the client's `Authorization` because the
  client's key may *be* the provider's key; for an MCP server that is never true, so there is
  no pass-through at all.
- **The upstream credential is named like a node's**, `api_key_ref` through the key broker,
  else `api_key_env`, sent as `Authorization: Bearer`, and fails closed the same way: a named
  source that yields no key means no call and `503`. A credential written under `headers:`
  would be a secret on disk (ADR 0003); `Authorization`, `Proxy-Authorization`, `X-Api-Key` and
  `Cookie` there fail the load. `headers:` remains for what is no secret.
- **The answer is the upstream's, with two exceptions.** Status, headers (but the hop-by-hop
  ones, `Content-Length` and `Content-Encoding`) and body come back as they are — a `404` for
  an expired session must reach the client, which re-initialises on it. But an upstream `401`
  becomes `502 upstream_error` and an error log line. Towards the client `401` is ADR 0020's
  "your key is not let in", and MCP clients act on it by starting an authorisation flow against
  the host. The upstream's `401` is about the key *Skeid* presented. And a redirect becomes
  `502` as well: its `Location` is an upstream URL, which the listing takes care never to
  show, and following it would carry the server's key to wherever it points. The log names the
  target, so the operator configures it (the common case is a server that redirects `/mcp` to
  `/mcp/`).
- **Opened at once, never buffered.** The response is opened — status and headers flushed —
  when the upstream's headers are parsed, and each chunk is written as it is read. A standing
  `GET` stream may have no event for minutes; a client that waits for response headers must not
  wait for the first event.
- **A sub-path is appended, never normalised.** `/mcp/<name>/<path>` exists for an upstream
  with more than one endpoint. A `.` or `..` segment or a backslash is refused (`404`) rather
  than resolved: the operator configured a path, and a key must not climb out of it by way of
  the upstream's own normalisation.
- **A `stdio` entry is a hint.** It describes a server on the customer's machine — every
  customer has its own — so that the listing can say "run this locally". Skeid does not start
  it and there is nothing to proxy. Its `command`, `args` and `env` are shown to the assigned
  key, so they are a message, not a place for secrets.
- **The listing shows what a client needs to connect and nothing of the inside**: the public
  URL (`mcp.public_url`, else the request's scheme and host), never the upstream URL, the key
  reference or a static header.
- **One usage event per relayed request, in the existing schema** (ADR 0004): `api_format:
  mcp`, `endpoint: /mcp/<name>`, the customer key id, status, duration, the server's `url` as
  `route_url`. No model, no node, no tokens, no cost, no new column. A stream that was opened
  as `text/event-stream` is recorded under its status however it ends — client, upstream or
  the time limit — because Skeid cannot tell a complete stream from a cut one without reading
  MCP, and closing it is how a standing stream ends. Any other answer follows the rules of
  every route: `499` for a client that left, failed for a body cut short.

## Consequences

- A customer's MCP client needs one line per server and the key it already has. Taking a
  server away from a key is deleting an id from a list, in force from the next request.
- Skeid holds no MCP state. Two frontends, or `--workers N`, relay the same server without
  coordination — provided the server itself does not need a session to stick to a connection.
- **Sessions are not bound to keys.** `Mcp-Session-Id` is the upstream's. Two keys assigned the
  same server could use each other's session if they knew its id. With a server per customer
  this does not arise; a server shared between customers would need Skeid to remember which key
  opened which session, which is state this decision avoids.
- **No limit protects an MCP server from a customer**: no `max_conns`, no backoff, no health.
  If one is needed it is a new mechanism, not a node attribute borrowed.
- **MCP events sit in the same ledger as LLM events.** They add to request counts in reports
  and appear under an empty model. A report that should count LLM requests only filters on
  `api_format`. The request method is not on the event, so a standing stream and a call differ
  only by duration.
- **Standing streams are cut at the upstream timeout** (`SKEID_UPSTREAM_TIMEOUT`, 300 s): the
  user agent has one time limit for every upstream call. Clients reconnect with
  `Last-Event-ID`. A longer limit for MCP alone would need a second user agent.
- **Only `Authorization: Bearer` upstream credentials.** A secret in another header has no
  config form yet; it would be a map of header name to key reference or variable.
- The upstream `401` → `502` rule would have to be revisited before any per-end-user OAuth is
  passed through Skeid. That is out of scope here, with tool aggregation, starting `stdio`
  processes and an admin API for assignments.
- `routing.trust_key_id_header` applies: behind a gateway that authenticates, the header's id
  is what a server has to be assigned to.
- `t/72-mcp-gateway.t` proves it against a fake MCP upstream: the unknown-path answer without
  the section (with and without `client_auth`), the load errors without a value in them, the
  listing per key and what it leaves out, body and headers both ways, the allowlist, the
  upstream key from the variable and from the broker, the event stream arriving event by event
  while the upstream still holds it, the standing `GET` stream and a client that leaves, `202`,
  the upstream's own `404` and `500`, `401` and a redirect → `502`, the `503` without a key, the `502` for an
  unreachable server, sub-paths and the refused ones, the one `404`, both `401`s, hot reload
  with rollback, and the usage events.
