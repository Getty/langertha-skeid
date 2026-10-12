# ADR 0022 — Customer keys can come from a database view, fetched in the background and merged at reload

- Status: proposed (skeid k108) — design only, nothing implemented
- Date: 2026-10-12
- Tags: config, auth, identity, policy, postgresql, keys, async

---

## Context

The caller side of Skeid's config says who may come in and what they may reach. It is made of
`client_auth:` (ADR 0020), `keys:` (the per-key policy assignment, ADR 0008) and `names:`
(ADR 0011). All three live in the YAML file. That works while an operator edits the file by
hand. It does not work when customer keys are issued and revoked by another application, such
as a self-service console. That application should not have to write Skeid's YAML or restart
Skeid, and an operator should not have to copy ids from one system into the other.

The application owns a database, and Skeid can already reach PostgreSQL for usage events
(`UsageStore::DBI`). The obvious step is to let Skeid read the caller side from there. The
existing ADRs constrain how:

- **ADR 0003.** Only customer key ids are stored (`k_` + full SHA-1 hex, ADR 0016), never keys.
- **ADR 0008, 0011, 0020.** Policy and the allowlist are resolved at config load. A request
  costs one hash lookup and never consults anything external.
- **ADR 0005.** Nothing synchronous on the request path. `maybe_reload_config` runs on the
  request path today (from `call_function` and from the client-auth gate). So a database query
  inside the reload is ruled out, however fast it is.
- **ADR 0011.** The config must load and be checkable offline.

Skeid must not know which application owns the database. So Skeid defines the shape it reads,
and the owner provides it, typically as a view over its own tables.

## Decision

### 1. A `customer_source:` section in the YAML file

```yaml
customer_source:
  backend: postgresql                  # the only backend for now
  dsn: dbi:Pg:dbname=console;host=db   # or host / port / dbname, as in usage_store
  user: skeid_reader
  password_env: SKEID_CUSTOMER_DB_PASSWORD   # never a password in the file (ADR 0003)
  # from_usage_store: true             # instead of the four lines above: same connection
  #                                    # parameters as usage_store (see 7.)
  relation: skeid.customer_keys        # table or view; schema-qualified allowed
  refresh_interval_s: 30               # default 30; the poll that always runs
  listen: skeid_customer_keys          # optional NOTIFY channel; absent = poll only
  max_stale_s: 0                       # default 0 = keep the last good set during an outage
  connect_timeout_s: 5                 # default 5; also bounds each query
```

- The section sits in the file, so the file still says where the caller side comes from. It
  is part of the declared state like any other section. A changed `customer_source` restarts
  the fetcher, and the new source is fetched before the old snapshot is dropped. A
  `customer_source` removed from the file drops the source's rows at that reload.
- `relation` must be a plain or schema-qualified SQL identifier, and the load checks it. It is
  quoted as an identifier, never interpolated as text.
- Connection parameters are normalized by the same code as `usage_store`
  (`UsageStore->normalize_config`), so `password_env`, `host`/`port`/`dbname` and the defaults
  mean the same in both sections.

### 2. The contract: one row per customer key id

Skeid runs exactly one statement:

```sql
SELECT key_id, name, policy, models FROM <relation>
```

| column   | type             | null? | meaning |
|----------|------------------|-------|---------|
| `key_id` | `text`           | no    | `k_` + 40 lowercase hex digits (ADR 0016, `skeid keyid`). Unique in the relation. |
| `name`   | `text`           | yes   | A readable label. Shown in `/skeid/config` and used in warnings about the row. Never an identity, and never resolvable from the file (see 3.). |
| `policy` | `text`           | yes   | The name of a profile in the file's `policies:`. `NULL` takes `default_policy`. |
| `models` | `text[]`         | yes   | Overrides the profile's model list, as `keys: <id>: {models: [...]}` does. `NULL` keeps the profile's. `'{}'` means no models. |

- **A row present means the key is active.** There is no `revoked`/`enabled` column. The owner
  revokes a key by making its row disappear from the relation, typically through a view
  filtered on `revoked_at IS NULL`. Skeid sees one state, and there is nothing to
  misinterpret.
- **Columns are selected by name.** Extra columns in the relation are ignored. A missing column
  is a fetch failure (see 5.), not a config error.
- **Whole snapshot, no deltas.** Every fetch reads the whole relation. Deltas would need a
  version contract from the owner. A few ten thousand short rows per fetch is cheap. This can be
  revisited with a measurement if it ever is not.
- **The relation carries only what is per customer.** Profiles (`policies:`), `default_policy`,
  `deny_tags`, aliases, nodes and the provider manifest (ADR 0015) stay in the file. In
  particular, data residency (`deny_tags`) stays a file-only decision (ADR 0008: the file is
  the residency boundary). The owning application picks a profile per key; it cannot invent
  one or loosen one.

A view an owner might provide (illustrative only, Skeid does not ship or require it):

```sql
CREATE VIEW skeid.customer_keys AS
  SELECT k.key_id, c.display_name AS name, c.plan AS policy, NULL::text[] AS models
    FROM console.api_keys k JOIN console.customers c ON c.id = k.customer_id
   WHERE k.revoked_at IS NULL;
GRANT SELECT ON skeid.customer_keys TO skeid_reader;
-- optional, for fast revocation (see 4.):
-- AFTER INSERT OR UPDATE OR DELETE ON console.api_keys ... PERFORM pg_notify('skeid_customer_keys', '');
```

Skeid needs `SELECT` on the relation and nothing else. A role that can only read that view is
the recommended setup.

### 3. Merge with the file: rows are validated first, the file wins per key id

At reload, the latest **source snapshot** (the rows of the last successful fetch) is merged into
the file's config before `_apply_config` runs.

1. **Rows are validated on their own, before the merge.** A row is rejected when its `key_id`
   is not a full id (a short id, uppercase, any other shape), when two rows share a `key_id`
   (both are rejected), when `policy` names no profile in the file, or when `models` is not a
   list of non-empty strings. A rejected row grants nothing: its key is not on the allowlist
   and gets no policy entry.
2. **No database content can fail a reload.** Rejected rows are counted and reported, never
   croaked. Otherwise a bad row written by the owning application would freeze the file's
   config too, because every reload would fail on it.
3. **A rejected row is reported without its values.** It is reported by `name` if the row has
   one, else by its position in the snapshot. An invalid `key_id` may be a key pasted where its
   id belongs (the ADR 0020 rule, for the same reason).
4. **The file wins per key id.** If the file's `keys:` names an id (directly, through `names:`,
   or as a short id that is a prefix of it, ADR 0016), the row's `policy` and `models` are
   ignored and the row is reported as shadowed. Reaching file-declared customers is a file edit.
   This also keeps ADR 0016's ambiguity rule intact, because no id ends up with two entries.
5. **The allowlist is a union.** Every accepted row's id joins `client_auth`, alongside the
   file's own entries. The database cannot revoke an id the file lists.
6. **`client_auth` stays a file decision.** The source adds ids only when the file declares
   `client_auth:` (`client_auth: { keys: [] }` is enough). If `customer_source` is configured
   and `client_auth` is absent, the load warns once: without the gate, a revoked key is not
   refused, it just falls back to `default_policy`.
7. **Names in the database are labels, not `names:` entries.** The file can't refer to a
   database name. If it could, the file's validity would depend on the database being up
   (ADR 0011: checkable offline), and an unresolved name would fall back to being read as an id.

The merged result is what ADR 0008's resolution sees, so the request path is unchanged: one hash
lookup for the policy and one for the allowlist.

### 4. Refresh: a background fetcher, never the request path

- **The fetcher runs on the event loop.** It is a `Mojo::IOLoop->recurring` poll every
  `refresh_interval_s`, and the query is non-blocking (`Mojo::Pg`, which uses DBD::Pg's async
  mode and watches the socket on the reactor). A fetch never blocks the loop and never runs
  inside `maybe_reload_config`.
- **A snapshot that changed triggers a reload from the fetcher's callback.** A snapshot is
  "changed" when its digest (rows sorted by `key_id`) changed. The reload is the existing
  all-or-nothing `reload_config` with the file plus the new snapshot. It is in-memory work only,
  the same as a reload a request triggers today. An unchanged snapshot does nothing: no
  reload, no inventory bump, no probe restart (skeid #38).
- **The config fingerprint covers both inputs.** It is file fingerprint plus snapshot digest.
  So `_config_fingerprint` and `_failed_fingerprint` keep their meaning, and a request-triggered
  `maybe_reload_config` still only rereads the file. The snapshot it merges is whatever is
  already in memory.
- **`LISTEN/NOTIFY` makes the next fetch come sooner.** It does not replace the poll. With
  `listen:` set, the fetcher holds one connection that `LISTEN`s on the channel (`Mojo::Pg`
  pubsub, which reconnects). A notification schedules a fetch after a short debounce (about
  250 ms), so a burst of changes costs one fetch. The payload is ignored, because Skeid always
  refetches the whole relation. The poll keeps running: notifications sent while the connection
  is down are lost, and the poll is what bounds that.
- **Every worker fetches for itself.** Policy and the allowlist are per-process memory, like a
  vault token (ADR 0010). The poll interval is *not* multiplied by the worker count, unlike
  capacity probes. Revocation latency is the point of the interval, and N small `SELECT`s per
  interval is negligible. With `listen`, that is N persistent connections, which the owner's
  connection limit has to allow for. Handles are opened after the fork, never inherited from the
  prefork manager.
- **Startup.** `skeid serve` runs one bounded fetch (`connect_timeout_s`) before it starts
  listening. That is outside the request path, so ADR 0005 does not apply. When the fetch
  fails, startup proceeds as in 5.

### 5. When the database is unreachable

- **At startup:** Skeid starts **degraded, fail-closed**. The file's config is in force, no
  source rows are. With `client_auth`, source customers are refused (`401`). Without it, they
  route under `default_policy`. The fetcher retries with the config-reload back-off (doubling
  from `refresh_interval_s`, at most 60 s, as `_reload_retry_delay`). Starting is the right
  call because refusing to start would also take down every customer declared in the file.
- **At refresh:** **the last good snapshot stays in force**, the same rule as a failing config
  reload. The failure is recorded and retried with the same back-off. It is logged when the
  reason is new, not on every retry.
- **`max_stale_s` bounds how long a revoked key can stay valid during an outage.** Above 0,
  once the last good snapshot is older than that, the source's rows are dropped (fail-closed)
  until a fetch succeeds again. The default 0 keeps the last good set indefinitely: an outage
  of the console's database then does not lock out paying customers. The operator picks the
  trade-off.
- **Visibility:** `GET /skeid/config` (admin) gets a `customer_source` block with `ok`, last
  success and failure times, consecutive failures, the error message, and rows accepted,
  rejected and shadowed. `/health` carries only `ok`, `failed_at` and `failures`, never the
  message, as for the config reload (ADR 0020 and `reload_status`). `/health` stays `ok` while
  the source is failing, because the proxy is serving.

### 6. Revocation latency

The time from the owner's commit until the revoked key is refused is, per worker:

- **with `listen` and a healthy connection:** debounce + one query + the in-memory reload.
  That is well under a second.
- **poll only, or notification lost:** at most `refresh_interval_s` + one query.
- **database unreachable:** unbounded with `max_stale_s: 0`, else at most `max_stale_s` +
  `refresh_interval_s`.

Revocation applies from the next request. Requests that were already admitted, including
streams in flight, run to completion. Revoking does not cut them, and their usage events are
recorded as usual. Workers converge independently, each within the same bound.

These bounds only hold under `client_auth`. Without it, a revoked key loses its row's policy but
is still let in.

### 7. Relation to `UsageStore::DBI`

- **Same database, separate connection.** `from_usage_store: true` reuses the usage store's
  normalized connection parameters (backend must be `postgresql`). The fetcher still opens its
  own connection. The usage store's handle is synchronous DBI, and the fetcher's is async
  `Mojo::Pg`. They share neither handle nor transaction, and the usage store's write-behind
  flush is not affected.
- **A separate role is recommended even on the same DSN.** The usage store writes
  `usage_events` and may migrate its schema (`auto_migrate`). The customer source only needs
  `SELECT` on one relation. With `from_usage_store`, `user`/`password_env` set in
  `customer_source` override the usage store's.
- Usage events are unchanged: they carry the key id, never the database's `name` (ADR 0004).
  The owning application joins its own names onto the ledger.

### 8. Dependencies

`Mojo::Pg` becomes a `recommends`, like `DBD::Pg`. It is loaded only when `customer_source` is
configured. A configured source without it fails the load with a message that names the module.

## Test plan

Offline, by construction (house rules): no network, no real PostgreSQL. The seam is the
**fetcher**: a small object with `fetch(cb)` and an optional `on_notify(cb)`. `Mojo::Pg` sits
behind it, and tests inject a fake that answers rows, errors, or nothing at all, on loop timers.

- **Row validation (unit).** Valid row; `NULL` policy → default; `NULL` vs `'{}'` models; short
  id, uppercase, raw-key-looking `key_id`; duplicate `key_id` rejects both; unknown policy;
  non-list `models`. A rejected value never appears in any warning or status, which is asserted
  on the captured output.
- **Merge.** The file's `keys:` (raw, via `names:`, short-id prefix) shadows a row. The
  allowlist is a union. Without `client_auth` there is a warning and no gate. A database name
  is not resolvable from the file. No row content can make `reload_config` die.
- **Lifecycle (fake fetcher on `Mojo::IOLoop`).** The first snapshot is applied. An unchanged
  snapshot is a no-op: no fingerprint change, no inventory bump. A changed snapshot reloads. A
  fetch failure keeps the last good set, backs off and reports. `max_stale_s` drops the rows
  after the limit and they come back on success. A changed `customer_source` restarts the
  fetcher, and a removed one drops the rows. Startup with a failing fetch is degraded and
  fail-closed.
- **Notify.** A fake notification triggers a fetch after the debounce, a burst coalesces into
  one fetch, and the poll still runs without notifications.
- **Proxy (`Test::Mojo` against `build_app`).** A source key is let in. Removing its row from
  the fake makes the next request after the refresh `401` in each dialect. Changing its
  `policy` turns a model into `403`. 100 requests cause zero fetches, so no database is on the
  request path. A fetcher that never answers leaves requests served, so the loop is not
  blocked. Every `request.start` still has its `request.finish`.
- **Statement shape.** The SQL `Mojo::Pg` would receive is asserted as a string: the identifier
  is quoted, a hostile `relation` value is rejected at load, and only the four columns are
  selected.
- **Regression intent.** Each test is checked to fail when its property is removed: the union,
  file-wins, fail-closed on rejection, keep-last-good, and no fetch on the request path.

A check against a real PostgreSQL (view, grant, `NOTIFY` trigger) belongs in the
`examples/service` compose stack as a manual procedure, not in `t/`.

## Consequences

- An application that owns customer keys provides one view and, optionally, a `NOTIFY`. Skeid
  learns nothing about it beyond the relation name and connection.
- The file stays the security boundary for residency and profiles. The database decides only
  which ids exist and which profile each takes. An attacker who can write the owner's tables
  can let a key in and give it any existing profile, but cannot create a profile or loosen
  `deny_tags`.
- Two inputs now make up the config. The fingerprint, `/skeid/config` and the reload log must
  say which input changed. A reload can now be triggered by a timer, not only by a request or
  `config.reload`.
- Revocation latency becomes a documented, configurable property (`refresh_interval_s`,
  `listen`, `max_stale_s`) instead of "the next time someone edits the file".
- Each worker holds one more database connection, two with `listen`.
- `CONTEXT.md` gains **Customer source** and **Source snapshot** when this is accepted. The
  `skeid-core` and `skeid-service-stack` skills gain the section and the deployment notes then.

## Open questions

1. **Async driver.** `Mojo::Pg` as a new `recommends` vs. hand-rolled DBD::Pg async with a
   reactor watcher. `Mojo::Pg` is proposed because it brings reconnecting pubsub.
2. **Startup when the database is down.** Degraded fail-closed start (proposed) vs. refusing to
   start. Should there be a `required_at_start` switch?
3. **`max_stale_s` default.** 0 (availability, proposed) vs. a finite default (revocation holds
   during outages).
4. **Should rows be able to carry `deny_tags` or a manifest?** Proposed no: residency stays in
   the file.
5. **Is `name` useful enough?** It is display-only. It could be dropped from the contract, or
   later carried into usage reports.
6. **Should a database name be referenceable from the file** (key rotation without touching the
   file, ADR 0011)? Proposed no, because of offline checkability.
7. **Is a real-PostgreSQL check wanted** beyond the manual compose procedure, for example an
   env-gated `xt/` test? The house rules currently say no.
