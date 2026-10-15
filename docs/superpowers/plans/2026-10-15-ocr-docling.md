# OCR through Skeid (docling-serve face) — Implementation Plan

> **For agents:** execute task by task; steps use `- [ ]`. Behavior-relevant code goes to
> `skeid-protocol-worker` (face, protocol module), tests to `skeid-proxy-test-writer`, the
> commit and card move to `skeid-release-manager` (house rules). One test run at a time, check
> `/proc/loadavg` first, always `prove -lr t/`.

**Spec:** `docs/superpowers/specs/2026-10-15-ocr-docling-design.md` (k94)
**Goal:** `POST /v1/convert/file` and `/v1/convert/source` of docling-serve reachable through
Skeid — gated, routed, admitted, relayed byte for byte, metered (`documents`). Phase 2: async
calls with task affinity.
**Architecture:** a relayed route (ADR 0021) in a new `Langertha::Skeid::Protocol::Documents`;
a handler of its own reusing `_begin_route_async`, `_proxy_openai_json_async` with `$relay`,
`_limit_upload`; node option `api_key_header`; config `uploads.documents_max_bytes` and
`documents:` section.
**Blocked on decisions** (spec, end): 1 usage unit, 2 SSRF default, 3 async mechanism,
4 routing name, 5 limits/timeout, 6 paths, 7 auth option. The plan assumes every
recommendation; a different answer changes only the named task.

---

## Task 0 — Pin the deployed docling-serve (no code)

- [ ] Against the deployed instance: `GET /v1/capabilities`, then one `POST /v1/convert/file`
      (small PDF) and one `/v1/convert/source` with `file_sources` — record the exact request
      field names, whether `X-Api-Key` is required, answer for several files (zip?), the
      status codes of an oversize/invalid file.
- [ ] Save the observed requests/answers as fixtures' source in the card note (no secrets).
- [ ] If the field names differ from the spec (`sources` vs `http_sources`/`file_sources`),
      update spec 4.5 before Task 3.

## Task 1 — Node option `api_key_header` (decision 7)

**Files:** `lib/Langertha/Skeid.pm` (`add_node`, node POD), `lib/Langertha/Skeid/Proxy.pm`
(`_inject_node_auth_async`), `t/78-documents-node-auth.t` (new)

- [ ] **Red test** — a node `api_key_header: X-Api-Key, api_key_env: K`; fake upstream records
      headers; a client sending `Authorization: Bearer client-secret` and `x-api-key: client-secret`
      must produce upstream `X-Api-Key: <node key>`, no `Authorization`, no client value anywhere:
      ```perl
      is $seen->{headers}{'x-api-key'}, 'node-key', 'node key in the named header';
      ok !exists $seen->{headers}{authorization}, 'no Bearer authorization';
      unlike join("\n", %{$seen->{headers}}), qr/client-secret/, 'client credential dropped';
      ```
      Run against HEAD: fails. Also: default node (no option) still `Authorization: Bearer`.
- [ ] Validate at load: value must be an RFC 7230 token; an invalid value croaks in `add_node`
      before `remove_node` (k98 order). Test: bad value keeps the old node.
- [ ] Implement in `_inject_node_auth_async` `$apply`: after `_drop_client_credentials`, set
      `$headers_ref->{$header} = $key` for a named header, `Authorization => "Bearer $key"`
      otherwise. No key value in any message (ADR 0003).
- [ ] `prove -lr t/` green; WIP commit via release-manager.

## Task 2 — Per-route upload limits (decision 5)

**Files:** `lib/Langertha/Skeid.pm` (`uploads` parsing, `upload_max_bytes` neighbours),
`lib/Langertha/Skeid/Proxy.pm` (`_limit_upload`), `t/78-documents-limits.t`

- [ ] **Red test** — `uploads: {documents_max_bytes: 1048576}`: a 2 MiB body declared to
      `/v1/convert/file` → `413` before the body is read (same technique as t/68's early 413);
      `/v1/audio/transcriptions` still limited by `max_bytes`; unknown key in `uploads` still
      refused; `documents_max_bytes: 0` refused. Fails against HEAD (route unknown).
- [ ] Add attribute `documents_max_bytes` (default 104857600), parse like `max_bytes`
      (`Skeid.pm` ~3330), include in `reload` reset (~1834) and the config-state list (~1571).
- [ ] `_limit_upload`: replace the `Protocol::Audio->upstream_path` test by a lookup in a route
      table `{ path => attr }` built from `Protocol::Audio->routes` and
      `Protocol::Documents->routes`; the 401-cut-off logic is untouched.
- [ ] Regression: `t/68-audio-transcription.t` unchanged and green.

## Task 3 — `Protocol::Documents` and the sync face

**Files:** `lib/Langertha/Skeid/Protocol/Documents.pm` (new), `lib/Langertha/Skeid/Proxy.pm`
(routes, `_handle_documents`), `t/00-load.t`, `t/78-documents-convert.t`

- [ ] **Module** (POD with `=method`): `routes`, `upstream_path` (identity),
      `remote_sources_in_form($content)` / `remote_sources_in_json($data)` returning the names
      found (`callbacks`, `http_sources`; extend per Task 0), `document_count`.
      Reuse `Protocol::Audio->form_fields` and `upstream_parts` — if their audio-only wording
      gets in the way, move the two into `Protocol::RawBody`'s neighbour without behaviour
      change, guarded by t/68.
- [ ] **Red test (file route)** — fake docling node in the test app (pattern of t/68: inline
      Mojolicious app on an ephemeral port): 2 files + options form fields come through part
      for part, answer bytes identical, a zip answer identical, usage event has
      `endpoint /v1/convert/file`, `model docling`, `documents => 2`, no token fields.
- [ ] **Red test (source route)** — `file_sources` JSON relayed re-encoded, one document
      counted; invalid JSON / non-object → `400`, no slot taken, no event.
- [ ] **Handler** `_handle_documents($c, $endpoint)`: `_extend_client_timeout`, the same
      413/multipart checks as audio, remote-source refusal (`400 invalid_request_error`, text
      names the field, not its value) unless `documents.allow_remote_sources`, model =
      `skeid->documents_model`, then `_begin_route_async` → `$relay{request}` builds the
      multipart (or JSON) upstream tx → `_proxy_openai_json_async` → `_render_upstream_response`.
      No streaming branch (docling sync answers are one body).
- [ ] **Config**: `documents: {model: docling, allow_remote_sources: false}` parsed with the
      strictness of `uploads` (unknown key croaks), reload-safe.
- [ ] **Red tests (hazards)**: `callbacks` spelled `Callbacks`, `callbacks ` and `name*=` in a
      form; `http_sources` twice in JSON — all `400`, none reaches the node; with
      `allow_remote_sources: true` they pass untouched.
- [ ] **Red tests (admission)**: `max_conns 1` + a held request → second gets `429`/waits per
      `route_wait`; client abort and upstream `500` each end in exactly one `request.finish`
      and one failed event; key policy not granting `docling` → `403`; `client_auth` unknown
      key → `401` before any byte reached the node.
- [ ] `prove -lr t/` green.

## Task 4 — Mutation checks (house rule 7)

Each run: `systemd-run --user --scope -q -p MemoryMax=1G -p MemorySwapMax=0 -- timeout 120 prove -l t/78-documents-convert.t`.
Each mutation must turn a named subtest red; restore after.

- [ ] remove the remote-source refusal → hazard subtests fail
- [ ] count `documents` from the answer instead of the request → count subtest fails
- [ ] keep client `x-api-key` in `_drop_client_credentials` order (set before drop) → auth fails
- [ ] skip the `_limit_upload` table entry → early-413 subtest fails
- [ ] leak the upload asset (no spool cleanup) → spool-directory subtest fails

## Task 5 — Docs and ADR (docs lane, but POD/skills go to a worker)

- [ ] README, `CONTEXT.md` (**Documents**, `api_key_header`, widen **Documents** unit entry),
      POD in `Skeid.pm` / `Proxy.pm` / `bin/skeid`, `skeid-protocols` + `skeid-core` skills,
      `examples/` config (a docling node with `api_key_header: X-Api-Key`).
- [ ] ADR 0021 *Update* section for the face; number from the coordinator.
- [ ] `Changes` entry; `dist.ini` untouched (no new top-level dir).
- [ ] Benchmark note: skeid-perf-tester measures the `_limit_upload` table cost once (not in
      background, `nice -n 19 ionice -c3`).
- [ ] Hand to `skeid-release-manager`: commit, card k94 → review.

## Task 6 — Phase 2: async + affinity (only after decision 3 and its ADR)

- [ ] ADR: stateless `<node>.<task>` task id; policy re-check; removed node → `404`; what
      "inflight" means for a submitted task.
- [ ] **Red tests**: submit → answer `task_id` is prefixed; poll and result reach the same
      node (two nodes, round-robin would otherwise miss); poll for a task whose node was
      removed → `404`; a forged prefix naming a node outside the key's policy → `404`; the
      prefix is stripped upstream; result body streamed, not buffered.
- [ ] Implement routes in `Protocol::Documents`, handler `_handle_documents_task`
      (no `_begin_route_async`: the node is named by the id; still `request.start/finish`
      against that node via `route.state` check).
- [ ] Mutation: skip the policy re-check → forged-prefix subtest fails.

## Done when

Sync calls proven against the fake node (Task 3 subtests), mutations red/green (Task 4),
`prove -lr t/` PASS with the file count and test count reported, docs written, card at
`review` with commit hashes in the note. *Folge in langertha:* none; *Folge in deployment
docs:* `max_conns >= workers` for the docling node (spec 4.8).
