Read when touching `/v1/rerank` / `/rerank`, `Protocol::Rerank`, `rerank_format: tei` or `Protocol::Refusal`.

# Relayed route: rerank

`POST /v1/rerank` and `POST /rerank` are one handler (`_handle_openai_rerank`); the event's
`endpoint` is `/v1/rerank` for both. `Langertha::Skeid::Protocol::Rerank` owns the wire — `query`,
`documents`, `top_n`, `return_documents`, TEI's `texts` / `return_text` / `score`,
`x-compute-tokens`, `meta.tokens` appear nowhere else.

- Before a node is picked, `request_problem` answers `400` for: a body that is no JSON object, a
  `model` that is not a non-empty string, a `query` that is not a string, `documents` that is not
  a non-empty array. No slot, no event. What a document may be is the node's to say.
- **Default: relayed.** The body goes to `{node.url}/rerank` re-encoded with `model` = served
  model and every other field as sent; the answer comes back byte for byte
  (`_render_upstream_response`). vLLM, infinity (`--url-prefix /v1`), Jina, Cohere. Do not
  normalise what they do differently (`document` as `{text}` vs a plain string, vLLM returning
  documents unasked). Re-encoding is deliberate: one `model` reaches the node, the one Skeid
  routed by — never pass the client's bytes through.
- **`rerank_format: tei` on the node: translated on the upstream side** (ADR 0021 Update; the only
  translation not at the client edge). `POST <node url without /v1>/rerank` with
  `{query, texts, return_text?, truncate?}`; the bare array becomes
  `{model: served, results: [{index, relevance_score, document: {text}?}], usage: {total_tokens}?}`,
  sorted by score, cut to `top_n` (absent / `null` / `0` = all). A node option, never an `engine`
  branch. A new upstream dialect is a row in `Protocol::Rerank`'s `%FORMAT`.
- The dialect is known only after admission. A request a TEI node cannot take (a document that is
  not a string or `{text: string}`, a bad `top_n`) throws a `Protocol::Refusal` from
  `request_to_upstream`; the handler answers through `_refuse_unsendable_request`:
  `request.finish`, one failed event (`400`, `invalid_request_error`), no upstream call.
- `$relay` keys rerank added, both called with `($payload, $res)`: `usage` (returns the usage
  block to meter, or nothing — instead of pricing the body's own `usage`) and `answer` (response
  translator for a node with a format; a `die` is the `translation_error` path, `500`). `units`
  gets `$res` as second argument too.
- Usage: `documents` = documents in the request, on the event of a request the node answered 2xx,
  absent otherwise; recorded, not priced. Tokens are **input** tokens (`prompt_tokens` = total,
  `completion_tokens` 0) so `input_per_million` prices them, read from `usage.prompt_tokens`, else
  `usage.total_tokens`, else `meta.tokens.input_tokens` (Cohere); for `tei` from the
  `x-compute-tokens` header only. infinity counts characters unless `lengths_via_tokenize`. No
  `search_units`, no streaming, no `/v2/rerank`.
- `t/69-rerank.t`; 26 mutations of the logic were checked to fail it.
