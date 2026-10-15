# ADR 0025 — The route table registers the routes and describes them; the Swagger UI is fetched, never shipped

- Status: accepted — implemented (skeid k105)
- Date: 2026-10-15
- Tags: protocols, api, documentation, openapi, supply-chain

---

## Context

An operator who exposes Skeid as a public model API wants a machine-readable description of it
that cannot drift from what the proxy serves. The routes were registered one call at a time in
`build_app` and listed again, by hand, in POD. A document generated from POD would be as stale
as the POD; one written beside the registrations would drift the day a route is added.

A browsable UI is wanted too. Swagger UI is a 1.4 MB JavaScript bundle: vendoring it under
`share/` would put third-party minified code into the CPAN tarball and the git history, and
make every Skeid release carry a release of someone else's UI. Loading it from a CDN in the
page would send every operator's browser to a third party and break behind a closed network.

## Decision

**One table registers and describes.** `Langertha::Skeid::Proxy->route_table` returns one entry
per route (id, bridge group, methods, patterns, handler, and what the document says: tag,
summary, request and response schema). `build_app` registers every route from it, in table
order, behind the bridge of its group -- the client gate, the face's error dialect, the admin
gate. `Langertha::Skeid::OpenAPI` builds the documents from the same entries. A route that
exists without an entry is therefore a route the documents do not describe, and
`t/78-route-table.t` walks the real router and compares it to the table in both directions
(it also proves the walk can see a rogue route, so the test is not vacuous).

**Two documents.** `GET /openapi.json` is OpenAPI 3.1 for the client routes the configuration
enables: the manifest route only with `manifest.enabled`, the MCP routes only with an `mcp:`
section. It sits behind the client gate like `/v1/models` -- its examples carry model names, and
those are per key -- and takes them from the same `list_models` call. It documents `client_auth`
as an HTTP bearer scheme, required when a `client_auth:` section exists and optional otherwise.
The admin routes are a separate document, `GET /skeid/openapi.json`, behind `_authorize_admin`
like everything under `/skeid` (404 without an admin key, 401 for a wrong one); the registry
snapshot is listed there when `registry.enabled`. A document contains paths, fixed text and one
model name per example -- no key, key reference, node URL or environment variable name.

**The UI is fetched on first use and cached.** `openapi.swagger_ui: true` (default off) turns on
`/docs`. Skeid ships no asset. The first request for the UI downloads two files of the pinned
`swagger-ui-dist@5.17.14` from `cdn.jsdelivr.net` (`swagger-ui.css`, `swagger-ui-bundle.js`),
non-blocking (ADR 0005), checks each against a SHA-256 digest compiled into
`Langertha::Skeid::SwaggerUI` (and a size cap), writes them atomically into the cache directory
(`openapi.cache_dir`, default `$XDG_CACHE_HOME/skeid/swagger-ui-5.17.14`, then
`~/.cache/skeid/...`, then a per-uid directory under the temp dir; created `0700`), and serves
them from there. Concurrent first requests share one download. A fetch that fails answers
`502`; the failure is remembered for 60 s and requests in that window answer `503` with
`Retry-After` without starting another download; a fetch that never answers fails after 60 s.
Switched off, `/docs` is an unknown path and Skeid makes no network request for it.

The page is plain HTML with no inline script (`/docs/init.js` bootstraps it), loads
`/openapi.json` with the key the user types (kept in `sessionStorage` only), and sends try-it-out
requests with it.

## Consequences

- Adding a route is adding an entry; the entry is also its documentation. A route table entry
  with no `tag` / `summary` fails the table test.
- The UI paths are outside the client gate on purpose: they hold no data, and the browser that
  loads them has no key yet. An unauthenticated caller can therefore cause the one download; the
  failure window bounds what repeated calls can cost.
- The digests are a supply-chain pin: raising the version needs new digests, and a CDN serving
  other bytes yields a `502`, not a UI. The cost is a deliberate edit per UI upgrade.
- The UI needs outbound HTTPS once per cache directory. An air-gapped deployment points
  `cache_dir` at a directory that already holds the two files.
- Tests fetch through an injected `SwaggerUI` object (`build_app(swagger_ui => ...)`) with
  digests of fake bodies; none reaches the network.
- Not done: the document does not describe every request field (the relayed and translated
  faces take what their upstream takes), and there is no `servers` entry -- the UI resolves
  against the page it is served from, so a path-prefixing reverse proxy has to map `/docs`,
  `/openapi.json` and `/docs/*` at the root.
