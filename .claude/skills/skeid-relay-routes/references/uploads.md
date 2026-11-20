Read when touching a multipart upload route, `_limit_upload`, `%UPLOAD_ROUTE` or the `uploads:` limits.

# Uploads and multipart forms

- The upload is not copied: parts above 256 KiB are file assets, and `upstream_parts` hands the
  same asset to the user agent's `multipart` generator. `$part->asset->slurp` on the file is the
  regression (`t/68` counts it).
- Upload limit = `uploads.max_bytes` (default 26214400, 25 MiB) for audio,
  `uploads.documents_max_bytes` (default 104857600, 100 MiB) for `/v1/convert/*`; set per request
  by `_limit_upload` on the request content's `body` event (head parsed, body unread), through
  the `%UPLOAD_ROUTE` table it reads. Declared too large, or refused by `client_auth`: limit set
  to 1, the parser stops, the route (or the gate) answers `413` / `401` without the body.
- A new upload route must be an entry in `%UPLOAD_ROUTE`, or it runs under the server's 16 MiB
  and gets no early `413` / `401`.
- `Expect` is dropped from an upload's upstream headers: a node's `100 Continue` makes
  Mojo::UserAgent start a fresh response object while the stream relay listens on the old one.
- A form with nothing to rewrite (documents): `upstream_parts($content, {})`.
