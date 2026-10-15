# ADR 0028 — The documents routes are relayed over nodes of a kind, authorised under one routing key, metered in pages

- Status: accepted (skeid k94)
- Date: 2026-10-15
- Tags: protocols, relay, documents, docling, routing, policy, uploads, usage, ssrf, node-auth

---

## Context

An OCR / document-conversion service joins the cluster: docling-serve, behind its own HTTP API.
It has to come in through Skeid like everything else — behind client authentication (ADR 0020),
routed over nodes with admission and health (ADR 0002, 0009), one usage event each (ADR 0004).

Its synchronous calls are `POST /v1/convert/file` (multipart: the files plus option fields) and
`POST /v1/convert/source` (JSON: sources by URL or inline base64, options). The answer is a JSON
document (markdown, JSON, HTML, text, doctags) or, for several inputs or outputs, a zip.

Four things differ from every route so far:

1. **There is no `model` field.** Routing, policy (ADR 0008) and usage are keyed on a model
   string.
2. **The node authenticates by `X-Api-Key`**, not `Authorization: Bearer`.
3. **A request can make the node fetch a URL or call a webhook** from inside the cluster
   network (`http_sources`, `callbacks`, a `target` to put to): a server-side request forged by
   whoever holds a Skeid key.
4. **Documents are large**, larger than audio, and the unit that matters to whoever pays is
   the page.

ADR 0021 settled that a non-chat route is relayed in the node's shape and its unit is an
optional event field. This ADR applies that to a face that has its own paths and no model.

## Decision

**docling's synchronous conversion is a relayed route under docling's own paths. It is planned
over nodes of a `kind`, authorised under one fixed routing key, and metered in pages read off the
answer.**

### Routes and wire

`POST /v1/convert/file` and `POST /v1/convert/source`, docling's own paths, so a docling client
changes its base URL and nothing else. Relayed (ADR 0021): the form goes upstream part for part
from the spooled file; a source body is decoded once and written again, as rerank does, so the
node reads exactly the object Skeid read — the same one-parser argument as `model` in the audio
form. The answer comes back byte for byte, JSON or zip, at the node's status. The wire knowledge
is `Langertha::Skeid::Protocol::Documents`; there is no second proxy function — the handler
passes a `$relay` to `_proxy_openai_json_async`. Only the synchronous calls are offered; see
*Not decided here*.

### Routing by node kind, authorised under `documents`

A node option `kind` (`chat`, the default and every node there was; `documents`) says what a node
serves. The route plans over nodes of kind `documents`, and **only** them; chat routing, the model
lists (`/v1/models`, `/api/tags`) and the manifest take nodes of kind chat only. The kind is part
of the route key, so a chat model that happens to be called `documents` and the documents route
never share a round-robin cursor. An unknown kind fails the load, like an unknown `rerank_format`
(ADR 0021 Update): a node of a kind nobody spelled right would be sent the wrong sort of request.

No fixed model name is configured (the spec's `documents.model` was rejected): the node's `model`
is not read, a documents node needs none, and a deployment cannot rename the route into a
collision with a chat model. Instead, **the route is a fixed routing key, `documents`, that stands
where the model name stands**:

- A key policy with `models:` grants it like a model (`models: [qwen3-32b, documents]`). A key
  whose policy lists models and does not list `documents` is answered `403 permission_error`
  before a node is picked — the conservative reading: a restricted key has no documents by
  accident. A key with no restriction (`models` absent or `*`) has it.
- `deny_tags` apply to documents nodes as to any node, and `403` vs `503` is told apart the same
  way.
- An alias named `documents` tiers the nodes by tags (`{tags: [local]}`, then `{tags: [cloud]}`),
  with `wait_ms` — the existing alias machinery, since the plan's tiers carry the kind of the
  route whatever the alias says. The alias is not a chat model and is left out of `/v1/models`.
- The usage event has `model: documents`, `requested_model: documents`, the node in `node_id`.

The alternative considered was `kind` as a policy dimension of its own (`kinds: [chat,
documents]`). It is the larger change — a second axis in `resolve_policy`, `_policy_fingerprint`,
key overrides and the manifest — for a question one more entry in `models:` answers. When a third
kind or a need to grant "all documents nodes, whatever they are called" appears, it is revisited.

### Node auth by a named header

A node option `api_key_header` names the header the node's key goes in, raw, instead of
`Authorization: Bearer <key>`. `X-Api-Key` is docling-serve's. The key source (`api_key_ref`,
`api_key_env`) is unchanged and nothing about a key reaches disk or a message (ADR 0003). The
value must be an RFC 7230 token — no space, colon or line break — checked at load before the old
node is removed (k98 order); `Authorization` is the default spelled out. The client's
`Authorization` and `x-api-key` are dropped in every spelling as for any node with a key, and a
configured key source that yields no key still fails closed (`503 upstream_key_unavailable`,
no pass-through to the node).

### Remote sources and callbacks are refused unless the operator allows them

`http_sources`, `callbacks`, and — since docling's newer API spells the same things as `sources`
of `kind: http` and a `target` of `kind: put` — a `sources` entry that is not an inline file and a
`target` that is not `inbody` or `zip`, make the **node** call an address the **client** names, from
inside the cluster network: an SSRF through the relay. They are `400 invalid_request_error` before
admission (no slot, no event), by default. `documents.allow_remote_sources: true` lifts it.

- The message names the field, never what it holds.
- The names are read as liberally as a form parser reads them (case, white space, `[]`, a
  `name*` spelling is refused outright, a file part named so counts) and in JSON, a field named
  twice is refused whichever occurrence wins — two parsers may pick different ones. Empty lists
  are not remote sources.
- This is the one place Skeid reads docling's request beyond routing. The list is a default-deny
  list of names, and a docling release that adds another address-taking field needs an entry.

### Limits

`uploads.documents_max_bytes`, default 104857600 (100 MiB), an integer of at least 1, its own
setting because documents are larger than audio; `uploads.max_bytes` stays audio's. Applied as for
audio on the request's `body` event: declared too large, or refused by `client_auth`, and
`413` / `401` is answered without the body. `/v1/convert/source` is JSON but falls under the same
limit, which counts the body, not the file: base64 is a third larger. `_limit_upload` is now a
route table (path → limit). The upstream timeout (`SKEID_UPSTREAM_TIMEOUT`, 300 s) is unchanged.
A conversion that takes longer fails like any slow upstream.

### Usage: `documents` and `pages`

- `documents` is the number of input documents the request held (file parts; `file_sources`,
  `http_sources`, `sources` entries), counted by Skeid off the request, on the event of a request
  the node answered — the rerank rule (ADR 0021 Update).
- **`pages`**, a nullable field of the event, is the billing unit. It is read off the answer's
  `document.json_content.pages` (a `DoclingDocument` holds one entry per page) and only when
  the answer is a successful JSON answer **and** at most 8 MiB. A zip is not decoded at all; a
  larger answer, a `json_content` that is absent or `null`, an empty `pages` (a format without
  pages) and a body that is not JSON leave `pages` absent: not measured, never `0` (ADR 0021). A
  `json_content` that is a string holding the document is decoded too, within the same bound.
  Recorded, not priced (ADR 0013): there is no per-page rate in `Langertha::Pricing`.
- **Cost of reading it.** The proxy decodes every relayed JSON answer once already; the bound
  makes that one decode at most 8 MiB on the event loop, roughly tens of milliseconds, instead of
  an unbounded one. A route may name `max_parse_bytes`; documents does, and an answer above it
  is relayed without being decoded at all. Reading `pages` is a hash lookup on the result. A
  deployment that converts large documents to markdown + JSON + HTML in one answer will see most
  of its answers above the bound and get no `pages`; then `documents` is what there is, or the
  client asks for `json` only. This should be measured with `bench/` before a number is quoted
  (not done here: no benchmark was run).
- The DBI stores get a nullable `pages` column in both schemas (`share/sql/`) and by the additive
  migration (`@ADDED_COLUMNS`, which an existing table gets on `prepare`); the usage spool writes
  it with the event's other columns (ADR 0027); `jsonlog` writes the key; the report sums it in
  `totals`, `by_key` and `by_model`; `skeid usage` prints it where there are pages.

## Consequences

- A docling node is a node: `max_conns`, `weight`, `tags`, health, capacity and key broker work
  as for any. docling has no Prometheus gauges Skeid knows, so capacity is inflight only, and
  `max_conns` should be at least the number of Skeid workers (ADR 0010).
- The route is open to every key without a `models` restriction. An operator that runs a
  documents node next to chat nodes and restricts keys by `models:` must add `documents` to the
  keys that may convert — a change to existing policies that is explicit, never silent.
- A node of kind `documents` that gets a chat request is impossible by construction; a chat node
  asked for a document is too. Before this ADR a node with no `model` served every model, and
  would have taken a chat request meant for another.
- `/v1/models` lists nothing for documents nodes. There is no capability field (ADR 0021 already
  noted this for Whisper and rerank).
- `api_format: docling` is a new value in the event. Reports group by key and model, so
  conversions appear under the model `documents`.
- The 100 MiB limit is above Mojolicious' 16 MiB server default and is held through the request
  head, as for audio; a chunked body is cut 1 MiB past it. A source body of that size is
  decoded in memory (and encoded again): large files go to `/v1/convert/file`, which spools.
- `t/88-documents-convert.t` proves the relay against a fake docling node: bytes in and out, zip
  answer identical, the key header, 413/401 before the body, the refused spellings, pages with and
  without `json_content`, request.finish on every exit path, admission, policy, kind separation,
  config validation and the stores.

## Not decided here

- **Asynchronous conversion** (`/v1/convert/*/async`, `GET /v1/status/poll/{id}`,
  `GET /v1/result/{id}`) needs task affinity: status and result must reach the node that took the
  task, which Skeid, routing every request on its own, has no concept of. It is a later phase and
  gets an ADR of its own. The direction it would take is a stateless task id — `<node>.<task>`,
  the prefix added to the answer and stripped on the way up, the node re-checked against the key's
  policy — not an in-memory table, which is wrong under `--workers N` and lost on restart. Until
  then a conversion holds a slot and the client's connection for as long as it takes, up to the
  upstream timeout.
- The status WebSocket (`/v1/status/ws/{id}`) and `GET /v1/capabilities` are not relayed.
- Rasterising PDFs or a Mistral-style `/v1/ocr` convenience route: Way B of k94, not Skeid's.
