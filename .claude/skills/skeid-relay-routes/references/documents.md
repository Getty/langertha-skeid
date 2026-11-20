Read when touching `/v1/convert/file` / `/v1/convert/source` (docling-serve), `Protocol::Documents` or `kind: documents` nodes.

# Relayed route: documents (docling-serve)

`POST /v1/convert/file` (multipart) and `POST /v1/convert/source` (JSON, base64 files) under
docling's own paths (ADR 0028). `Langertha::Skeid::Protocol::Documents` owns the wire — field
names, `json_content.pages`, `callbacks`, `http_sources` appear nowhere else. Handler
`_handle_documents`, reusing `_begin_route_async` (with `kind => 'documents'`),
`_proxy_openai_json_async` with a `$relay`, `_render_upstream_response`; no second relay.

- **No model.** Planned over nodes of `kind: documents`, authorised under the routing key
  `documents` (a policy's `models`; else `403`), event `model` = `documents`, `api_format: docling`.
  Chat nodes never serve it and it never reaches chat nodes (skill `skeid-routing`).
- **Remote sources are a `400` before admission** (no slot, no event) unless
  `documents.allow_remote_sources`: `http_sources`, `callbacks` (liberal names: case, white space,
  `[]`, a file part named so, `name*` refused; in JSON a key named twice is refused whichever wins,
  also by its raw bytes), `target` not `inbody`/`zip`, a `sources` entry that is not an inline
  file. The text names the field, never the value. A new address-taking docling field is an entry
  in `Protocol::Documents`.
- Form: `upstream_parts($content, {})` — nothing to rewrite. Source body: decoded once
  (`$req->json`), written again as `json =>`; CPU on the loop grows with the body, which is why
  big files belong on `/v1/convert/file`.
- Limit `uploads.documents_max_bytes` (default 104857600, 100 MiB) through the `%UPLOAD_ROUTE` table that
  `_limit_upload` reads; both routes get the early `413` / `401`. A new upload route is an entry
  there.
- `$relay` keys used: `request` (form only), `units`, `usage` returning nothing (no tokens), and
  **`max_parse_bytes`** (new): `_proxy_openai_json_async` leaves an answer larger than that
  undecoded, so `units` sees no payload. Documents sets 8 MiB.
- Usage: `documents` = file parts / source entries of the request, on a 2xx answer only; `pages` =
  `document.json_content.pages` (hash keys or array length; `json_content` may be a string), only
  from a successful JSON answer of at most 8 MiB; absent for a zip, `null`, a format without pages
  (empty) — never `0`. Recorded, not priced.
- An upstream 4xx/5xx takes the existing error path (`upstream_error`, the node's message), as on
  every relayed route; a conversion `status: failure` inside a 200 is the node's to judge.
- Not offered: the `/async` calls, status polling, results, the WebSocket (ADR 0028: task affinity
  needs its own ADR, stateless `<node>.<task>` id).
- `t/88-documents-convert.t`.
