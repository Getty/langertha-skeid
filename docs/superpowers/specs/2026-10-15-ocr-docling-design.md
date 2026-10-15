# Design — OCR through Skeid: a docling-serve face (Way A)

- Status: proposed design, not implemented — planning only (k94)
- Date: 2026-10-15
- Plan: `docs/superpowers/plans/2026-10-15-ocr-docling.md`
- Builds on: ADR 0021 (non-chat routes are relayed, not translated), k91 (upload relay), k92 (rerank)
- Vocabulary: `CONTEXT.md` (Relayed route, Node, Admission, Usage event, Client authentication)
- Companion ADR: not written here. A number is assigned by the coordinator; ADR 0021 gets an
  *Update* for the face, and task affinity (phase 2) needs an ADR of its own (decision 3).

## 1. Problem

An OCR/document-conversion service joins the cluster. Getty decided (2026-10-15): the backend
is **docling-serve**, behind its own HTTP API ("Way A" of k94). It must be reachable through
Skeid like everything else — behind `client_auth`, routed over nodes with admission and health,
one usage event per forwarded request, key injected from the key broker.

Way B (a vision model over `/v1/chat/completions`) needs nothing here and is out of scope. Its
one missing piece, a configurable JSON body limit for the chat routes, is independent of this
design (note on k94).

## 2. What docling-serve speaks (to verify against the deployed version — task 0)

Read from the upstream usage docs on 2026-10-15; the card's text names slightly different
fields (`sources`), so the deployed version must be checked before any code is written.

| Call | Shape |
|---|---|
| `POST /v1/convert/source` | JSON: `options` (partial or absent), `http_sources[{url, headers?}]`, `file_sources[{base64_string, filename}]` |
| `POST /v1/convert/file` | multipart: `files` (one or more) plus option fields as form fields; `callbacks` repeatable |
| `POST /v1/convert/source/async`, `/v1/convert/file/async` | same bodies, answer a task: `task_id`, `task_status`, `task_position`, `task_meta` |
| `GET /v1/status/poll/{task_id}` | `task_status`: `pending`, `started`, `success`, `failure` |
| `GET /v1/result/{task_id}` | the conversion answer |
| `WS /v1/status/ws/{task_id}` | status push (out of scope, see 8) |
| `GET /v1/capabilities` | deployment capabilities, **exempt from the API key** |

Sync answer: JSON `{document: {md_content, json_content, html_content, text_content,
doctags_content}, status: success|partial_success|skipped|failure, processing_time, timings?,
errors[]}`; several inputs or outputs come back as a **zip** (binary). Key header:
`X-Api-Key`, only when the server runs with `DOCLING_SERVE_API_KEY`. **No page count** is in
the answer.

## 3. Goals and non-goals

**Goals**
- The sync calls (`/v1/convert/file`, `/v1/convert/source`) behind the client gate, routed,
  admitted, metered, relayed byte for byte (ADR 0021's rule).
- Node auth by the header the node names (`X-Api-Key`).
- Per-route upload limit for documents, which are bigger than audio.
- Async calls with task affinity as a **second phase**, after its ADR.

**Non-goals**
- Translating docling's options or answer (no client wants a different shape).
- Rasterising PDFs, or a Mistral-style `/v1/ocr` convenience route (Way B territory).
- A second upstream dialect (ADR 0021's "a third route with dialects makes it a pattern").
- Relaying the status WebSocket (belongs with the realtime relay, k95, if at all).

## 4. Design

### 4.1 The face: same paths as docling, one new protocol module

Routes are mounted under the existing client gate (`$openai` bridge) at **docling's own
paths** — `POST /v1/convert/file`, `POST /v1/convert/source`; phase 2 adds the `/async` twins,
`GET /v1/status/poll/:id`, `GET /v1/result/:id`. Using the upstream's names means an existing
docling client (docling-python, `docling-serve` SDKs) only changes its base URL. The upstream
path is the same path below `{node.url}`, as for audio (`_endpoint_url_for_node`).

The wire knowledge lives in a new `Langertha::Skeid::Protocol::Documents` (routes, form field
reading, source inspection, unit counting) and nowhere else — ADR 0021's one-module rule. The
handler is a handler of its own (`_handle_documents`), not a parameterisation of
`_handle_openai_audio`: the audio handler is built around a mandatory `model` field that docling
does not have. What is shared is the existing machinery — `_begin_route_async`,
`_proxy_openai_json_async` with a `$relay` hash, `_render_upstream_response`,
`_limit_upload` — so there is still no second proxy function.

### 4.2 Routing key: a fixed model name per route family

A docling request has no `model`. Routing, policy (ADR 0008) and usage are all keyed on a
model string, so the route supplies one: the node is written `model: docling`, and the route
plans with the name from config `documents.model` (default `docling`). Consequences, all wanted:

- **Key policy works unchanged**: a customer key is granted `docling` or not.
- Several docling nodes share load by weight, `max_conns`, health, tags, tiers like any model.
- The usage event carries `model: docling`, `endpoint: /v1/convert/file`.
- `/v1/models` lists `docling` as a model (Whisper and rerank nodes already show up there; no
  capability field exists). Noted, not fixed.

### 4.3 Node auth by a named header

`_inject_node_auth_async` sets `Authorization: Bearer <key>` only. A node gets an optional
`api_key_header` (default: the Bearer scheme as today); `api_key_header: X-Api-Key` sends the
raw key in that header. Validated at load like `rerank_format` (a header-name token, an
unknown/invalid value fails the load; `Authorization` stays the default and the only header
spelled with `Bearer`). `_drop_client_credentials` already strips `x-api-key` case-insensitively,
so the client's own credentials cannot ride along. The key source (`api_key_ref`, `api_key_env`)
is untouched — ADR 0003.

### 4.4 Request limits

`_limit_upload` today asks `Protocol::Audio->upstream_path($path)` and applies
`uploads.max_bytes`. It becomes a small route table (audio → `max_bytes`; documents →
`documents_max_bytes`), so the early `413`/`401` before the body also holds for documents:

```yaml
uploads:
  max_bytes: 26214400            # audio, unchanged
  documents_max_bytes: 104857600 # new; default 100 MiB, integer >= 1
```

The load check ("unknown key in `uploads`") accepts the new key. `/v1/convert/source` carries
base64 in JSON: it is a JSON route that still needs the larger limit, so it is in the same
table — the base64 inflation (4/3) means the limit counts the body, not the file. The rest of
the JSON routes keep Mojolicious' 16 MiB.

### 4.5 What Skeid reads in a request (and refuses)

Minimum, as ADR 0021 says. Skeid parses just enough to enforce two rules a relay must not leave
to the node:

1. **No server-side fetch on the client's behalf unless the operator allows it.**
   `http_sources` and `callbacks` make the *docling node* fetch a URL / call a webhook, from
   inside the cluster network. A client with a Skeid key could point a node at internal
   services — an SSRF through the relay. Default: such a request is `400` before admission
   (no slot, no event); `documents.allow_remote_sources: true` lifts it. (Decision 2.)
2. **One parser, one reading.** As for audio (`model` twice), `callbacks`/`http_sources` must
   be found however a node's parser would spell them: the form-field name is read liberally
   (the `Protocol::Audio->form_fields` reader is reused as is), a `name*=` part is refused,
   and the JSON body is decoded and re-encoded exactly as rerank does, so a duplicate key
   cannot hide a source from Skeid that the node reads.

Everything else — options, unknown fields, repeated fields, file parts — goes upstream as sent.
The multipart relay is `Protocol::Audio->upstream_parts` generalised (it takes the parsed parts
and a replace map; the documents face passes an empty one). There is no model field, so there is nothing to rewrite for an alias tier; it only changes which
node serves.

### 4.6 Answer, errors, timeouts

The answer is relayed as the node gave it (JSON or zip, any status). Upstream errors keep the
existing mapping. Conversions of big documents are slow: the sync call is bounded by
`SKEID_UPSTREAM_TIMEOUT` (default 300 s) and the client's connection is extended by the same
(`_extend_client_timeout`). Nothing new; the doc states the knob, and decision 5 covers whether
a per-route timeout is wanted.

### 4.7 Usage

- Tokens: none (docling reports none). `cost_*_usd` is therefore 0, as for audio: recorded, not
  priced.
- Unit: `documents` — the number of input documents of the request, counted by Skeid off the
  request (files parts, or `file_sources` + `http_sources`), as k92 counts rerank documents.
  The column already exists in every store and the report (`totals`, `by_key`, `by_model`).
  It means "documents the request carried" in both uses (the CONTEXT entry is widened).
- `pages` is **not** added now. docling's answer has no page count; reading
  `document.json_content` just for it would mean decoding a body that can be many MiB. Add the
  nullable column the day a backend reports it (decision 1).
- Status: from the HTTP status, as everywhere. docling's own `status: failure` inside a `200`
  is not Skeid's to judge.

### 4.8 Admission and capacity

`request.start`/`request.finish` pairing is the existing path: every exit incl. client abort
and an oversize/refused request that never reached a node. docling-serve has no Prometheus
running/waiting gauges Skeid knows, so capacity is inflight-only with a small `max_conns`
(its own worker count, `DOCLING_SERVE_ENG_LOC_NUM_WORKERS`); per-process worker shares
(ADR 0010) apply, so `max_conns` must be at least `workers` for any share to be ≥ 1 — a note
for the deployment docs, not code.

### 4.9 Phase 2: async calls and task affinity

`/async` returns a `task_id` that only the accepting node knows; poll and result must reach it.
Skeid routes every request on its own today, so affinity is new and needs an ADR before code.
Options:

| | Mechanism | Survives restart | Across prefork workers | Cost |
|---|---|---|---|---|
| a | in-memory `task_id → node_id` table | no | **no** | cheap, wrong under `--workers N` |
| b | stateless: answer's `task_id` becomes `<node_id>.<task_id>`; poll/result strip it | yes | yes | rewrite of one small JSON answer; node id is client-visible; must re-check the key may reach that node |
| c | shared store (DBI) | yes | yes | a new stateful dependency on the request path |

Recommended: **b**, with the policy re-check (route state for `documents.model` under the
key's policy, node still in inventory) instead of signing. A task whose node left the inventory
answers `404`. Admission: the submit request holds its slot only for the submit call, so the
node can be busy converting with `inflight` 0 — documented; `max_conns` bounds submissions in
flight, not conversions. The result (`GET /v1/result/:id`) is one more relayed request and may
be large, hence the same `documents_max_bytes`-independent *response* path (streamed relay,
not buffered).

## 5. Risks

- **Version drift of docling-serve** (field names, `/v1alpha` history): Skeid reads only
  `http_sources`/`callbacks` (and their older spellings) — the rest is opaque. Task 0 pins
  what the deployed version accepts; the test's fake node documents it.
- **SSRF** (4.5) is the one security-relevant part; default-deny.
- **Hot path**: the `_limit_upload` route table adds a hash lookup to every upload request;
  skeid-perf-tester confirms noise before a release note claims anything (k91's open point h).
- **Memory**: a 100 MiB upload is spooled to disk (as audio); the upstream request is sent from
  that file. Verified by the same spool-directory test as t/68.

## 6. Testing

Offline by construction (`Test::Mojo`, inline fake docling node): both routes' bytes in/out,
`X-Api-Key` set and client's header gone, `413`/`401` before the body, `400` for a remote
source/callback (all spellings), zip answer relayed byte for byte, `documents` counted,
every exit path's `request.finish` and one usage event, load sharing + `max_conns`, alias
tier, config validation of `api_key_header` and `documents_max_bytes`. Phase 2: task-id
rewrite round trip, a poll for a removed node, a forged prefix naming a node the key may not
reach. Mutation checks per house rule 7 (listed in the plan).

## 7. Documentation touched when built

README, CONTEXT.md (**Documents**, **Relayed route**, `api_key_header`), `Langertha::Skeid`
POD (nodes, uploads), `Proxy.pm` POD, `skeid-protocols` and `skeid-core` skills, the example
config, ADR 0021 Update (+ the phase 2 ADR), `Changes`.

## 8. Out of scope / follow-ups

- Status WebSocket `/v1/status/ws/:id`: only worth it with the realtime relay (k95).
- `GET /v1/capabilities`: unauthenticated on docling; not exposed.
- Langertha has no document-conversion engine; nothing to pin. If it gains one, the relayed
  module shrinks (as ADR 0021 says of rerank). *Folge in langertha:* none required.

## Decisions Getty has to make

1. **Usage unit: `documents` now, `pages` later?** Recommendation: count `documents` (request
   side, existing column), add a nullable `pages` only when the deployed docling reports one.
   Alternative: parse pages out of `json_content` — rejected (decodes MiB of body per request).
2. **Remote sources and callbacks (SSRF).** Recommendation: refuse `http_sources` and
   `callbacks` with `400` by default; `documents.allow_remote_sources: true` opt-in. Clients
   send files or base64. Alternative: allow always — only if the cluster network is flat and
   trusted.
3. **Async + task affinity: phase 2, and which mechanism?** Recommendation: ship the sync calls
   first; async only after an ADR choosing the stateless `<node>.<task>` id (table row b).
   Alternative: never offer async — a 5-minute conversion then holds a client connection.
4. **Routing name.** Recommendation: fixed `documents.model` (default `docling`), the node's
   `model: docling`. Alternative: a node *kind* (`kind: documents`) that skips the model
   string — more code, no benefit while policy is keyed on model names.
5. **Limits and timeout.** Recommendation: `uploads.documents_max_bytes` default 100 MiB and the
   global `SKEID_UPSTREAM_TIMEOUT` unchanged. Alternative: a per-route timeout
   (`documents.timeout`) if 300 s proves too short for real documents — decide after a first
   measurement on the deployed node.
6. **Route paths.** Recommendation: docling's own `/v1/convert/*` (client compatibility).
   Alternative: a Skeid namespace (`/v1/documents/convert`) — avoids squatting docling's
   names but breaks every docling client.
7. **Node auth option name and scope.** Recommendation: `api_key_header` per node, default
   unchanged. Alternative: a node `auth: {scheme: header, name: X-Api-Key}` block — only if a
   third scheme appears.
