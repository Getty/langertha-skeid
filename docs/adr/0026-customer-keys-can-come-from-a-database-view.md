# ADR 0026 — Customer keys, names and policies can come from a database view, fetched in the background

- Status: accepted — implemented (skeid k108, k109)
- Date: 2026-10-15
- Tags: config, auth, postgresql, keys, async
- Karr: k108 (source), k109 (blocking connect)

---

## Context

The caller side of the config — `names:`, `keys:` (per-key policy and model access) and the
`client_auth:` allowlist (ADR 0020) — lives in the YAML file. That is right for a handful of
customers and wrong for a service whose customers are created and revoked by *another
application* that owns a database. Editing a file from a second system is the integration
nobody wants to run.

Constraints already fixed elsewhere:

- Only customer key **ids** (`k_` + full SHA-1, ADR 0016) are stored, never keys (ADR 0003).
- The policy table is resolved once at config load and a request costs one hash lookup
  (ADR 0008, ADR 0020). No database round trip may sit on the request path.
- The request path is async-only (ADR 0005): a blocking connect or query stalls every in-flight
  stream in the process while single-request tests stay green.
- Skeid must not know who owns the database. It defines the *shape it reads*; the owner provides
  a view.

## Decision

An optional top-level `customer_source:` section names a database relation Skeid reads. The
source feeds the same structures the file feeds, at config load, through a background fetcher.

```yaml
customer_source:
  dsn: dbi:Pg:dbname=customers;host=db.internal    # or from_usage_store: true (see below)
  user: skeid_ro
  password_env: SKEID_CUSTOMERS_PASSWORD           # never a literal, as usage_store
  relation: skeid_customer_keys                    # table or view, schema-qualified allowed
  poll_interval_s: 30
  max_stale_s: 0                                   # 0 = keep the last good snapshot forever
  connect_timeout_s: 5
  listen: skeid_customers                          # optional NOTIFY channel; poll stays the floor
```

### The contract

```sql
SELECT key_id, name, policy, models FROM <relation>
```

One row per **active** key id. A key that is revoked is a row that is *absent* — there is no
status column to forget to filter on.

| column   | meaning |
|----------|---------|
| `key_id` | `k_` + 40 hex (ADR 0016). Required, unique. |
| `name`   | display name, informational: it appears in admin output, it is not referenceable from the file and grants nothing. May be NULL. |
| `policy` | name of a profile in the **file's** `policies:`. NULL means `default_policy`. |
| `models` | optional model allowlist for this key, a JSON array (`jsonb`/`json`/text) or NULL for "the policy decides". |

The relation is the whole interface. The owning application provides a view with these four
columns; Skeid never writes, never DDLs, and the role it uses needs `SELECT` on that one view.

### Merging

- **Rows are validated before the merge, one by one.** A row with a malformed `key_id`, an
  unknown `policy`, a `models` value that is not a list of strings, or a duplicate `key_id`
  is **rejected**: it grants nothing, and it never fails a reload. The rejection is counted and
  logged with the row's position and the *reason*, never the offending value (ADR 0003 — a
  pasted key in a `key_id` column must not reach a log).
- **The file wins per key id.** An id present in the file's `keys:` or `names:` is taken from
  the file; the database row for the same id is ignored (and counted as shadowed). A
  database can add customers; it cannot override what an operator pinned in the file.
- **The allowlist is a union, and only when `client_auth:` is declared.** With `client_auth`
  present, the file's list plus the snapshot's key ids may use the client routes. Without
  `client_auth`, the database does **not** turn authentication on — that is an operator
  decision (ADR 0020), not a side effect of a source.
- **`deny_tags`, `policies:` profiles, `aliases:` and the manifest stay file-only.** A row can
  *select* a profile and *narrow* its models; it cannot define routing semantics. What a
  customer may reach stays reviewable in the file; the database says who and which profile.

### Fetching

- **A background fetcher, never on the request path.** It polls every `poll_interval_s`
  (plus jitter) and, if `listen:` is set, re-fetches on a `NOTIFY` as a wake-up hint — poll
  stays the floor, because a notification can be lost.
- **The fetch runs in a child process** (`Mojo::IOLoop->subprocess`): connect and query are
  ordinary blocking DBI there, and the parent loop only receives the finished snapshot. See
  *The blocking connect* below.
- **The snapshot is swapped atomically** and takes part in the config fingerprint, so a
  changed snapshot is applied by the next `maybe_reload_config` exactly like a changed file —
  one code path, one rollback.
- **Last good snapshot on outage.** A failed fetch keeps the previous snapshot and reports the
  failure (`/skeid/config`, log). With `max_stale_s > 0`, a snapshot older than that is
  dropped and the file alone is in force again — fail-closed for customers that exist only in
  the database. Default `0` (keep): an outage must not log every customer out.
- **Degraded start.** If the very first fetch has not succeeded, Skeid starts with the file
  alone and database-only customers get `401` (with `client_auth`) or `default_policy`
  (without). It does not refuse to start: the file's customers and `/health` still work.
- **A separate connection and role**, even with `from_usage_store: true`, which only means
  "reuse that store's DSN and credentials references" — the usage writer and the key reader
  never share a handle, and a slow customer query cannot back-pressure usage events.

### The blocking connect (k109)

DBD::Pg has no asynchronous connect. Opening a connection blocks the worker up to
`connect_timeout_s` (libpq rounds anything below ~2 s up), once per process and once per
retry while the database is unreachable — a blackholed host would stall all in-flight
streams per retry.

Options considered:

1. **TCP pre-check on the reactor, then connect.** `Mojo::IOLoop->client` is non-blocking, so
   an unreachable host is detected without blocking. But it is only a pre-check: a host that
   accepts TCP and then stalls in the startup packet or authentication still blocks the
   `connect` that follows, and DNS inside libpq is synchronous regardless.
2. **Connect and query in `Mojo::IOLoop->subprocess`.** Everything that can block — DNS,
   TCP, TLS, auth, query — happens in a child; the parent sees only a result or a timeout.
   Costs a fork per fetch (30 s interval: irrelevant) and a result serialized over a pipe
   (a few thousand rows: irrelevant).
3. Mojo::Pg on the parent loop. Its queries are async, but its connect is the same
   blocking `DBI->connect`; it solves the query half and not the half that hurts, and it is
   not a dependency of this distribution today.

**Chosen: 2.** It is the only option that closes the whole class, not one failure mode.
A TCP pre-check is kept as a *complement*, not the fix: before forking, a non-blocking
connect to host:port (from the DSN) with a short timeout skips the fork and backs off
immediately when the port is closed or blackholed, so a dead database costs no processes.
The parent also enforces a deadline on the child (`connect_timeout_s` + a margin) and kills
a child that overruns it.

Mojo::Pg is therefore not used: in a child, plain `DBI` with `DBD::Pg` (already
`recommends`) does the work, and the same code path runs against `DBD::SQLite` in the offline
tests. `DBD::Pg` stays an optional dependency, needed only when a `dbi:Pg:` DSN is configured.

## Consequences

- A deployment can run entirely from the file (unchanged), entirely from the view plus a
  file holding `policies:`, or both; the file is the override layer.
- Revocation latency is `poll_interval_s` (or the NOTIFY round trip) plus the config reload
  throttle. It is documented, not hidden; a customer that must be cut *now* is deleted from
  the file (a file edit applies on the next request, ADR 0020).
- A broken row costs one customer, never the service; a broken *relation* (missing column,
  wrong type) fails the fetch, which keeps the last good snapshot.
- One child process per fetch exists for a few milliseconds; an unreachable database costs
  one TCP probe per interval, not a fork and not a stalled loop.
- Not covered, on purpose: per-row `deny_tags`/profiles/manifest, writing back to the
  database, and a database holding *upstream* secrets (the key broker's job, ADR 0011).

## Implementation notes (as built)

Where the code made the decision sharper than the text above:

- **`models` only narrows.** It is intersected with the profile's (or `default_policy`'s) list;
  a disjoint, empty or `*` value rejects the row. A row can never widen what the file allows.
- **A duplicated `key_id` rejects every row that carries it** — no "first wins" arbitrariness.
- **The `policy` name is checked at merge, not at fetch**, because `policies:` comes from the
  file and can change between two fetches.
- **Only the full id (`k_` + 40 hex) is valid** in the view. A database id whose short form the
  file lists is counted as shadowed rather than failing the load.
- **Status carries counts and `error_kind` only** (`tcp`/`connect`/`query`/`timeout`), never
  error text: `/health` prints `reload_status`. `from_usage_store` reuses the store's DSN, user
  and password in a connection of its own.
- **The TCP pre-check runs only for an IP literal, or when `Net::DNS::Native` is installed**
  (otherwise Mojo resolves the host name synchronously); the child covers the rest.
- **In loader-only mode** (`config_loader`, no file) a new snapshot is applied at the next
  `config_reload_interval` tick.
- **Not verified offline:** libpq against a real server and `LISTEN/NOTIFY`; the manual
  procedure is in `examples/service/skeid.yaml`. The fetcher starts in `build_app` before the
  fork, like the capacity probes, so under prefork it runs per worker — unchecked.

## Tests

Offline by construction (house rules): a fake source object and a
`DBD::SQLite` file stand in for PostgreSQL; the fetch path including the subprocess is
exercised against SQLite. The one thing no offline test proves — libpq against a real server
and `LISTEN/NOTIFY` — is documented as a manual procedure next to the example config.
