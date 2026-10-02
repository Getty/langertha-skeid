# ADR 0020 — Client authentication is an opt-in allowlist of customer key ids

- Status: accepted — implemented (skeid k90)
- Date: 2026-10-03
- Tags: auth, identity, config, proxy, security

---

## Context

Skeid identifies every caller — the presented key derives a **customer key id** (ADR 0008,
ADR 0016) — but never refuses one. That was right for a Skeid behind a gateway that
authenticates. It is wrong for a Skeid that is itself the public entry, with only nginx in
front for TLS: any string in `Authorization` gets in, and unlisted keys route under
`default_policy`.

The only workaround was the policy mechanics: `default_policy` with `models: []` and the known
key ids given an open policy. That refuses unknown keys, but with `403` instead of `401`, leaves
`/v1/models`, `/api/tags` and the manifest open to everyone, and reads as a model policy rather
than as authentication.

## Decision

An optional top-level `client_auth:` section lists the customer key ids that may use the client
routes:

```yaml
names:
  shared: k_5f0e1a2b3c4de5f60718293a4b5c6d7e8f901a2b   # `skeid keyid <key>`
client_auth:
  keys: [shared]
```

- **Absent means off**, exactly as before — Skeid behind another gateway is unchanged. Removed
  on reload, it is off again.
- **Its own section, not `keys:`.** `keys:` is the per-key policy table. Allowing a key in and
  deciding what it reaches are two decisions; folding the first into the second is the
  workaround this replaces. Being on the list grants nothing the policy does not.
- **Entries are key ids or `names:` names, in the config, not resolved through the key
  broker.** A key id identifies, it does not authenticate (ADR 0008) — what authenticates is
  that the caller presented the key the id derives from. The list holds no secret, so the
  reasoning of ADR 0011 applies: it belongs in the one file that already says who may reach
  what, checkable offline, resolved at config load, one hash lookup per request, no vault on
  the request path. The key broker stays for upstream secrets.
- **An entry that is neither a name nor a key id fails the load, named by position only.** Such
  a value is most likely a key pasted where its id belongs; the reload error reaches the log and
  `/skeid/config`, so it must not repeat the value (ADR 0003).
- **Gated:** every client route — `/v1/models`, `/v1/chat/completions`, `/v1/embeddings`,
  `/v1/messages`, every `/api/*` route, `/.well-known/langertha.json`. **Not gated:** `/health`
  (an orchestrator's probe has no key) and `/skeid/*` (its own admin and registry keys).
- **The gate is a route bridge that runs first.** A refused request is answered before its body
  is parsed, before `request.start`, a key broker call, an upstream call or a usage event —
  nothing to finish, nothing to bill. It is not logged: the routes are public and a line per
  refusal would be anybody's to flood.
- **`401` with `WWW-Authenticate: Bearer realm="skeid"`, in the route's dialect**: OpenAI's
  `invalid_request_error` / `invalid_api_key`, Anthropic's `authentication_error`, Ollama's
  `{"error": "..."}` — each face's SDK raises its own authentication error. Missing key and
  unknown key differ only in the message; neither answer names the key or its id.
- **Identity is the one routing uses.** With `routing.trust_key_id_header` the trusted header's
  id is what has to be on the list: the gateway in front authenticated, Skeid narrows.
- **The gate reloads the config before it checks**, on every client route, GETs included. A
  list change — turning auth on, rotating an id, locking a client out — must hold from the next
  request, not from the next routed POST that happens to trigger a reload. The reload is
  throttled by `config_reload_interval` and a no-op on an unchanged config, which is what keeps
  an anonymous GET from rerunning the loader. This supersedes ADR 0015's "the route
  never reloads the config" (see the update there).

## Consequences

- An edge deployment starts with one shared client key — one id on the list — and moves to a
  key per client by adding `names:` entries; locking a client out is deleting a line.
- `/v1/models`, `/api/tags`, `/api/ps` and the manifest route now pick up a changed config file
  themselves, with or without `client_auth`. Responses under an unchanged config are the same.
- With `client_auth` on, the manifest's own no-key `401` (`unauthorized`) is replaced by the
  gate's (`invalid_api_key`); its cache headers are kept.
- Routed POSTs call `maybe_reload_config` twice — in the gate and in `call_function`. The second
  is a no-op on an unchanged config.
- Not covered, on purpose: per-key rate limits, key expiry, and keys from an external source.
  A future source of ids (a file, OpenBao) would feed the same set at config load, never a
  lookup on the request path.
- `t/67-client-auth.t` proves the unchanged behaviour without the section, the `401` per route
  and dialect, that a refused request starts, calls and meters nothing, `names:`/raw/short ids,
  the trusted header, hot reload on GETs, rollback of a failed reload, and that a bad entry's
  value never appears in an error.
