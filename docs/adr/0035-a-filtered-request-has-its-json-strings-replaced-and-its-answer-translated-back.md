# ADR 0035 — A filtered request has its JSON strings replaced, and its answer translated back

- Status: proposed — implemented (skeid k118), for the maintainer to accept
- Date: 2026-11-25
- Tags: protocols, filter, privacy, proxy, streaming, usage, architecture

---

## Context

A deployment wants a privacy filter (PII) on whichever Skeid layer it runs: an edge Skeid, one
per organization, one next to the GPUs, a sidecar. The filter itself is the deployment's — what
counts as personal data, which placeholders it writes, who may see what. Skeid must stay
generic: it knows texts, spans and placeholders, not PII (maintainer decision, 2026-11-05).

What Skeid has to do around such a filter is protocol work: find the texts of a request in every
face, hand them out, put the filtered texts back where they came from without changing anything
else, and turn the placeholders in the answer back into the original values — in a JSON answer,
in an SSE stream whose placeholders can be cut across chunks, and inside tool-call arguments,
which are JSON in a string, streamed in fragments.

ADR 0023 says the OpenAI face forwards the client's bytes with only `model` replaced. A filtered
request cannot: its texts change. ADR 0030 gives a deployment its own Skeid class with versioned
dispatch hooks; the filter is one more hook of the same kind.

## Decision

**A deployment's filter is asked after the node pick, for a node it applies to, through one hook.
For a request it replaced, only the JSON string values it named change, substituted at their
string-token offsets in the original bytes; the answer's placeholders are translated back
before the face translators.**

1. **The hook is a versioned contract**, `filter_hooks_version` 1, documented in
   `Langertha::Skeid` ("Filter Hooks"):
   - `filter_request_p($ctx)` — a `Mojo::Promise` of the filter's answer. The default is a no-op
     (`{ decision => 'pass' }`), or `Langertha::Skeid::Filter::HTTP` when the config has a
     `filter:` section.
   - `filter_tags` — the node tags the filter applies to: the config's `filter.when`; none means
     every node.
   - `$ctx` is `{ version, face, route, kind, model, node => { id, tags }, api_key_id,
     organization, mark, headers, texts => [{ id, text }] }`: the face (`openai`, `anthropic`,
     `ollama`), the route's path, `chat` or `embeddings`, the requested model, the node picked,
     the customer key id, the configured organization, the incoming mark header
     (`X-Skeid-Filter`), the client headers `pass_headers` names, and the texts. A text's `id` is
     a JSON path into the request in the OpenAI shape (`$.messages[0].content`); inside a string
     that carries JSON (tool-call arguments) the path goes on into that JSON.
   - It answers `{ decision, texts, map, headers, usage }`. `decision` is `pass`, `replace`,
     `local` or `refuse`. `texts` is `[{ id, text }]`, a subset of the request's ids, with the
     filtered text. `map` is `[{ text, start, end, placeholder }]` (optionally with the text's
     `id`): which original span a placeholder stands for. `headers` are added to the upstream
     request (`X-` names only, never a credential header). `usage` goes into the usage event.
   - A change to the context, the answer or when the hook is called raises the version.
2. **The proxy asks only when it has to.** Without a `filter:` section and without a class that
   overrides `filter_request_p`, no text is extracted, nothing is asked, and the request goes the
   path it went before, byte for byte (`filters_requests`, one boolean per request). With a
   filter, a node outside `filter_tags` is served as before, too: the texts are found only when
   a node the filter applies to first admits the request, so a request no such node takes pays
   nothing for the filter.
3. **It runs after admission**, holding the node's slot, so the context can name the node.
   - `pass` forwards the request unchanged (with the filter's headers and usage).
   - `replace` forwards it with the texts replaced.
   - `local` gives the slot back and plans the request again with `filter_tags` as denied tags,
     unchanged, so it can only go to a node the filter does not apply to; when there is none it
     answers `503 filter_local_unavailable` ("This request must stay local, and no node outside
     the filter's zone can serve model '…'"). When the filter applies to every node, `local` is
     that 503 at once.
   - `refuse` gives the slot back and answers `403 filter_refused`.
   - **Fail-closed**: a filter that answers anything but a 200 with a JSON object, times out
     (`timeout_ms`), answers an unknown decision, an unknown text id or a malformed field, or
     whose `token_env` is not set, refuses the request: `503 filter_unavailable`, nothing is
     forwarded. The log says why in a few words, never the body, the texts, the map or a
     placeholder.
   - Every admitted request gets its `request.finish` on each of these paths, and when the client
     leaves while the filter is out. A refused request records one usage event (`ok = 0`,
     `error_type` `filter_refused` or `filter_unavailable`); a request sent back to planning
     records none for the node it left — nothing went upstream there.
4. **Texts are extracted per face, from the request in the OpenAI shape** — the client's body on
   the OpenAI face, the translated body on the Anthropic and Ollama faces, so their `system`,
   tool results and tool inputs are messages, tool messages and tool-call arguments by then:
   - chat: `messages[].content` (a string, or the `text` of its text parts), `messages[].name`,
     and every string value inside `messages[].tool_calls[].function.arguments`;
   - embeddings: `input` (a string or a list of strings).

   Never a key, a schema, `tools`, a function name, or any other field. A content part that is
   not text (an image, audio, a file), a token-id input, or tool-call arguments that are not
   JSON cannot be filtered: when such a request is admitted on a node the filter applies to, the
   slot is given back at once, in the same turn of the loop, and the request is planned again as
   for `local`, without asking the filter. The relayed routes — audio, documents, rerank, realtime — cannot be filtered either and
   are planned the same way when a filter is configured. (The MCP gateway relays to MCP servers,
   which are not nodes and have no tags; it is outside the filter, see Consequences.)
5. **An exception to ADR 0023, scoped to replaced requests.** On the OpenAI face the body that
   goes upstream is the client's bytes with `model` replaced and each named string value
   replaced at its string-token offsets — the scanner of `Protocol::RawBody` locates every
   string value with its path; everything else, key order, whitespace and escapes included,
   stays as the client spelled it. Inside tool-call arguments the inner JSON is substituted the
   same way and the string re-encoded. Bytes the scanner cannot follow, or an object with a key
   spelled twice (the node might read the copy the decoder did not), fall back to the decoded
   body with the texts set, encoded. On the translated faces the body is new anyway (ADR 0023):
   the texts are set in it before it is encoded as before, tool schemas verbatim included.
6. **Back-translation.** From each map entry and the original text Skeid builds the reverse
   table — placeholder to original — in memory, for this request only; it is dropped with the
   answer. It is applied to the answer before the face translators, so every face gets the
   originals:
   - the answer's `content`, `reasoning_content`, `reasoning` and `refusal`, the legacy `text`,
     and tool-call `arguments`, where each original is inserted JSON-escaped, so the arguments
     stay valid JSON;
   - the placeholder as the filter wrote it, and its lenient forms — `[` or `⟦` around it, a
     space for the underscore, spaces inside, either case — for a placeholder the table knows. A
     placeholder-shaped text of a known kind the table does not know is left alone and counted
     as `pii_unknown`;
   - in a stream, each channel (a choice's content, reasoning, refusal, and each tool call's
     arguments) holds back from its last `[` or `⟦` for up to 40 characters until it is closed,
     so a placeholder cut across chunks is still found; what is held is flushed in a frame of its
     own before the frame that ends the choice, and before `[DONE]` or the end of the stream;
   - once a filter has replaced text, the OpenAI stream is no longer relayed untouched: a frame
     whose text changed or was held is re-encoded, every other line goes out as it came.
7. **Usage.** The filter's `usage` and Skeid's own counts (`filter_restored`, `pii_unknown`) go
   into the usage event, allowlisted: keys `pii_*` and `filter_*`, a number, a short token
   string (`[A-Za-z0-9_.:-]`, at most 64), or a flat hash of numbers. Anything else is dropped,
   so a field cannot carry a text or a placeholder into the usage store.
8. **`Langertha::Skeid::Filter::HTTP`** is the shipped filter, configured by
   `filter: { url, token_env, timeout_ms, when, organization, pass_headers }`. It POSTs the
   context as JSON, with `Authorization: Bearer` the value of the variable `token_env` names —
   the token never stands in the config or a log — through a non-blocking `Mojo::UserAgent`
   (ADR 0005), and resolves with the decoded answer.

## Consequences

- A filtered request is not the client's bytes any more where the filter changed a text, and a
  re-encoded stream frame is not the node's. Both are scoped to the texts and the frames that
  change; ADR 0023 stands for every other request.
- A filtered request holds its slot for the filter's round trip, and pays for the extraction,
  one scan of the body and of the answer, and a frame decode per changed stream frame. A request
  without a filter pays one boolean; with a filter, a request served outside its zone pays no
  extraction. A stream frame without an opening bracket, while nothing is held, is passed on
  without a look for placeholders (when every placeholder in the map opens with one).
- An unfilterable request picked for a node of the filter's zone takes that node's slot for an
  instant and gives it back as `aborted` (the node's `aborted` count rises) before it is planned
  away; the pick also moves that tier's round-robin cursor on.
- `content_bytes` of a filtered stream on the OpenAI face counts what the node generated, with
  the placeholders, as before; on a translated face it is the translator's count of what the
  client got.
- The `pii_*` / `filter_*` fields reach `jsonlog` and a `store_usage_event` sink as they are. The
  DBI stores have no columns for them and drop them; a column (or a JSON column) is a decision
  for later.
- The MCP gateway is not gated: its upstreams are MCP servers, not nodes, and carry no tags for
  `when` to match. Gating it needs tags on MCP servers, or a gateway-wide switch.
- A filter that needs more than one round per request, or that wants to see the answer, needs a
  new version of the contract.

## Alternatives

- **Decode, replace, encode.** Simple, but it sorts every key of the request (ADR 0023), and a
  filter would change the prompt beyond its texts.
- **Filtering before the pick.** No slot held during the round trip, but the context could not
  name the node, and a filter for "cloud only" could not be expressed.
- **Re-planning a `local` request inside the filter's zone.** A filter that says "keep it local"
  would then be asked again by the next node of its own zone.
- **Back-translation in each face translator.** Three copies of the holdback; putting it before
  the translators keeps them format-only (ADR 0001).

## Tests

`t/104-filter-seam.t` against `build_app` with a fake upstream and a fake filter
(`t/lib/Test/Skeid/Filter.pm`, and a fake HTTP filter on the same app): the default path
unchanged byte for byte and the filter never asked; the texts of every face and the fields never
extracted; substitution keeping key order, whitespace and escapes; the non-stream answer and an
SSE stream translated back with placeholders cut across chunk borders; tool-call argument
fragments per call with JSON-escaped values; lenient forms and `pii_unknown`; `local`, `refuse`,
a failing, slow and malformed filter, a client leaving while the filter is out, all leaving every
slot free; the relayed routes and non-text parts refused or kept local; the usage allowlist.
`t/105-filter-restore.t` unit-tests the reverse table, the holdback and the substitution.
