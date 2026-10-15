# ADR 0027 — Usage events spool to a local directory while the database is down, and connects back off

- Status: accepted (skeid k110)
- Date: 2026-10-13
- Tags: usage, metering, dbi, postgresql, sqlite, resilience, async, security

---

## Context

A usage event is the billing unit (ADR 0004). `UsageStore::DBI` writes it to SQLite or
PostgreSQL, synchronously or write-behind (`flush_interval_ms`, ADR 0005 Update k78). What it
cannot write is reported lost through `on_lost`: an `error` line naming the request id and the
key id, for an operator to reconcile by hand.

CitiAI runs Skeid on an edge machine so it keeps serving when the database machine fails. The
caller side already survives that: `customer_source` keeps its last good snapshot (ADR 0026).
The usage side did not:

- **Every event of the outage was lost.** There was nothing to reconcile from but the log lines.
- **Every event paid a connect.** A failed write on a dead handle reconnects once (k71). With
  the database host unreachable, that blocking connect ran once per event, or once per flush,
  each time up to the connect timeout. ADR 0005 accepts one connect. It does not accept the
  loop stalling over and over for as long as the outage lasts.

The operator's request (card k110): put what the flush cannot write into a local spool on the
volume, JSON Lines, key ids only. Replay it when the database is back, idempotently with
`request_id` as the key. Back off reconnects while the database is down. Later several Skeid
instances run behind a load balancer, and the spool is per instance.

## Decision

### 1. `usage_store.spool_dir`, off by default

```yaml
usage_store:
  backend: postgresql
  host: db.internal
  password_env: SKEID_USAGE_DB_PASSWORD
  flush_interval_ms: 500
  spool_dir: /var/lib/skeid/usage-spool   # on the volume; one directory per instance
```

Unset, nothing changes: what the database cannot take goes to `on_lost`, as before. Set, an
event that could not be written **because the database is unreachable** goes to the spool:

- the connect failed;
- the handle died and the one reconnect failed;
- the reconnect backoff (3.) is still running.

This covers a synchronous `store` and a write-behind `flush`. A synchronous `store` then answers
`{ ok => 1, spooled => 1 }`, and a flush counts it in `spooled`. Neither is a lost event, so
nothing is logged as lost. The first event spooled after a connect warns once that the database
is unreachable and where the events go. The operator learns of the outage once, not once per
event.

An event the database **refuses on a live connection** (a constraint, a dropped table) is not
spooled. A replay would be refused again, forever. It stays an `on_lost` report. A spool write
that fails (disk full, permissions) also reports the event lost, with both errors. A spool never
turns a loss into a silent one.

### 2. The spool: JSON Lines, columns only, one file per process

- **Format.** One event per line, as `encode_json` of the event's **columns** (the
  `usage_events` columns `_insert` binds) and nothing else. One list feeds both the insert and
  the spool. An event carries key ids (ADR 0016), never a key. The DSN, user and password are
  not event fields and cannot reach the file. A stray field a caller put on the event hash is
  not written either (ADR 0003).
- **Durability.** Each append is flushed and `fsync`'d before the write counts. The spool is
  the only copy.
- **Files.** Each process appends to `usage-spool-<host>-<pid>.jsonl` under an exclusive
  `flock`. The workers of one Skeid (ADR 0010) share the directory without sharing a file. The
  host in the name keeps two machines from colliding on a pid. Even so, the decision is **one
  directory per instance**. The spool belongs to the instance, and `flock` on a network
  filesystem is not something to build on.

### 3. Reconnect backoff, with and without a spool

After a connect fails, the store does not connect again before a deadline: 1 s after the first
failure, doubling with each further failure, capped at 60 s. Until then every write fails at
once with `usage database unreachable (next connect attempt in …)` and the last connect error
(masked, ADR 0003). The network is not touched. The first connect that succeeds clears the
backoff. An outage therefore costs one blocking connect per deadline, not one per event or per
flush tick. This applies whether or not `spool_dir` is set. Without a spool, the window's
events are reported lost as before, only without the stall. The constants are fixed (ADR
0005's "keep it simple"). Nothing has asked for them to be configurable.

### 4. Replay: after a successful write, and at prepare

- **When.** After a write that succeeded (`store`, `flush`), and when the store is prepared.
  Prepare is how a restarted process picks up what an earlier one left behind. Nothing
  replays while the database is unreachable, so replay never adds connect attempts of its own.
- **Bounded.** One replay writes at most 500 events, in one transaction. Inside the loop the
  next batch runs on the next tick (`Mojo::IOLoop->timer(0)`) for as long as there is progress.
  Outside the loop (prepare at start, a script) one batch runs, and the rest follow with later
  writes. A large spool never holds the loop for more than one batch.
- **Claim, then work.** A replay claims a writer's file by renaming it to
  `<name>.replay-<host>-<pid>-<n>` under the file's lock. It then works on the claimed file
  under that file's own lock, which only replays take. A writer that was waiting for the lock
  sees that the path no longer names its file and opens a new one. A writer waits at most for a
  rename, never for a database transaction. A claimed file whose process died is picked up by
  the next replay, in any process.
- **Removal after commit.** Lines leave the spool only after their batch committed. The
  remainder is rewritten to a temporary file, `fsync`'d and renamed over the claimed file, or
  the file is removed when nothing remains. If that step fails, the lines stay and are skipped
  next time (5.).
- **A refusal does not block the rest.** A batch the database refuses on a live connection is
  retried one event at a time. An event it refuses is reported to `on_lost` and dropped. The
  database going away mid-replay stops the replay and leaves the spool file as it was.
- **A torn line** (the process died mid-append, the disk filled) does not parse. It is dropped
  with a warning, and the rest of the file is replayed.

### 5. Idempotent by `request_id` (with `created_at`), via a non-unique index

Replay inserts an event only when no row with the same `request_id` **and** `created_at`
exists, checked in the replay's transaction before the plain insert. The extra column matters
because a client's own `x-request-id` is taken over as the request id (Proxy `_request_id`).
A client that reuses its id would otherwise have its second, real request skipped on replay.
The spool holds the event exactly as it was built, so a copy that did make it in carries both
values. This covers:

- a replay interrupted after its commit and repeated;
- the ambiguous corner of k71, where a connection drops after the server committed but before
  it answered, and the batch is also spooled;
- the same event in two spool files.

The check is a `SELECT` before a plain `INSERT`, not `INSERT … SELECT … WHERE NOT EXISTS`.
That way the insert stays the one `_insert` every other write uses. PostgreSQL also gets no
untyped parameters in a select list to resolve. Concurrent replays of the same file are already
excluded by the file lock.

The schema gains `CREATE INDEX IF NOT EXISTS usage_events_request_id_idx ON
usage_events(request_id)`, so the check does not scan the table. It is **not unique**. A
deployment's existing table may already hold duplicate request ids (the k71 corner, reused
client ids), and a unique index would fail `auto_migrate` on exactly those deployments. A plain
index is always safe on existing data. On a large PostgreSQL table, its one-time build at the
first start after the upgrade blocks writes to the table while it runs.

**An event without a `request_id`** (only a direct `usage.record` that gave none; the proxy
always sets one) has no key. It is inserted on every replay that reaches it. A repeated replay
can duplicate it: at least once rather than lost.

### 6. A store with a spool starts while the database is down

`prepare` with a failing connect used to die, which fails startup or the reload. With
`spool_dir` set it warns, starts with the backoff running, and spools. The schema
(`auto_migrate`) is applied on the first connect that succeeds. That connect is a write's
connect, so the DDL runs on the loop once, like the connect ADR 0005 accepts. Without a spool,
prepare still dies. A missing schema file still croaks at once in both cases.

## What is still lost

The spool narrows the loss window. It does not close it. Events are still lost when:

- the spool write itself fails (disk full, read-only volume, permissions). Each event is
  reported through `on_lost` with the database error and the spool error;
- the process is killed hard while events sit in the write-behind queue in memory
  (`flush_interval_ms`, unchanged from k78). A graceful stop flushes, and with the database
  down that flush spools;
- the host loses power between an append and its `fsync`. The directory entry of a newly
  created spool file is not `fsync`'d separately;
- a line is torn by a crash mid-append. It is dropped with a warning;
- the replay finds an event the database refuses on a live connection. It is reported and
  dropped;
- `spool_dir` is changed or removed in the config while it holds events. The new store does not
  look in the old directory. The files stay on disk for an operator to move into the new one.

## Consequences

- An outage of the usage database costs no billing data under normal conditions. It costs one
  warning and one blocking connect per backoff deadline.
- Rows replayed from the spool get later `id`s than events written live after the outage. Their
  `created_at` is preserved, so time-filtered reports are right. `recent` (ordered by `id`) shows
  them where they were written.
- A report taken during the outage or before the replay finishes does not count spooled events.
- The usage-store contract gains `{ ok => 1, spooled => 1 }` from `store` and a `spooled`
  count from `flush`. Neither is a loss.
- The spool directory holds billing data. It needs the same care as the database volume
  (backups, permissions), but never a secret.
- `CONTEXT.md` should gain **Usage spool**. The `skeid-core` and `skeid-service-stack` skills
  should name `spool_dir`, and the compose example could mount a volume for it.
