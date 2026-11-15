# ADR 0032 — A node is internal or external, and an external node hears only what it needs

- Status: accepted — implemented (skeid k128)
- Date: 2026-11-15
- Tags: nodes, privacy, security, secrets, node-files

---

## Context

Skeid forwarded nearly every client header to the node: only hop-by-hop headers, `Host`,
`Content-Length`, `Accept-Encoding`, `Expect` and the correlation header (k121) stayed
behind. When the node is a cloud provider, that hands it the client's IP
(`X-Forwarded-For`, `X-Real-IP`, `Forwarded`), cookies, trace ids and whatever id headers the
deployment in front of Skeid adds — data the provider has no use for and should not get.

A node with no key source of its own also got the client's `Authorization` / `X-Api-Key`
passed through (the documented pass-through). Toward a provider that is the customer's
credential — with `client_auth`, the customer's Skeid key.

Nodes from a node file (ADR 0031) are usually a deployment's own infrastructure, but the file's
writer is less trusted than the main config and must not be the one to say so.

## Decision

**Every node is `trust: internal` or `trust: external`, default `external`. An external node gets
an allowlist of headers and must have a key of its own; an internal node gets today's headers
minus the client's address and cookies. Only the main config says a node is internal.**

- **external** — the client headers that go on are `Content-Type`, `Accept` and the provider
  protocol headers `anthropic-version`, `anthropic-beta` and `OpenAI-Beta`. Skeid adds the key it
  sets for the node and a fixed `User-Agent: Langertha-Skeid`. Everything else stays behind,
  among them `X-Forwarded-*`, `Forwarded`, `X-Real-IP`, `Cookie`, `x-skeid-*`, `x-api-key-id`,
  `X-Request-Id`, `traceparent`, `tracestate`, `baggage` and any header a deployment prefixes.
  An allowlist, because the headers a deployment adds in front of Skeid are not known here.
- **internal** — the previous exclusion list, plus `X-Forwarded-*`, `Forwarded`, `X-Real-IP`
  and `Cookie`. Trace and request ids still reach the node; that is what an internal node is
  for. The correlation header stays behind for both, as before (k121).
- **An external node needs a key source** (`api_key_env` or `api_key_ref`). Without one the main
  config fails to load or reload. The pass-through of the client's credential is only left to
  internal nodes. **Incompatible:** a config with a keyless node and no `trust` stops loading
  until the node gets a key or `trust: internal`.
- **Node files.** The `node_files` entry in the main config carries `trust` (default
  `external`) and sets it for every node of that file. A node in the file may name `trust` only
  with the entry's value; any other value rejects the node with rule `trust`. An external node of
  a node file without a key source is rejected with rule `key_required` — per node, as ADR 0031
  rejects what the main config would refuse, so a less trusted file cannot fail the load.
- **One rule on every route that relays to a node**: chat completions, the JSON and stream
  relays, audio, rerank, uploads, documents and the realtime handshake. The MCP gateway relays
  to MCP servers, not nodes; it already sends an allowlist (`Content-Type`, `Accept`,
  `Last-Event-ID`, `Mcp-*`) and is unchanged.
- `GET /skeid/config` shows each node's `trust`.

## Alternatives

- **Default `internal`.** Compatible, but the safe state would need every operator to act, and
  a forgotten provider node keeps leaking. The incompatible default is the cheaper mistake.
- **A denylist for external nodes.** Every header a deployment invents would leak until someone
  adds it to the list.
- **Trust named in the node file itself.** The writer the file belongs to would grant itself the
  wider header set and the credential pass-through.

## Consequences

- A provider sees the request body, its key and a generic agent — not who called, from where, or
  under which trace.
- A client feature relying on another header toward a provider (a new beta header) needs that
  header on the allowlist, a code change.
- Configs with keyless nodes need `trust: internal` written out before upgrading.
