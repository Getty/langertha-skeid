Read this when deploying the customer source or the usage store — the customer view and its database role, the usage schema, `auto_migrate`, write-behind and what a stop loses.

## Customer source in deployment (ADR 0026)

The application that owns customer keys provides
a relation (a view, typically filtered on `revoked_at IS NULL`) and grants `SELECT` on it to a
role of its own — recommended even with `from_usage_store: true`, since the usage store's role
writes and migrates. Every fetch connects from a short-lived child process and disconnects
again; with `listen` (LISTEN/NOTIFY) a second child holds one connection: the owner's
`max_connections` must allow `workers × frontends × 2` at peak. No connection is shared with the
parent or inherited across the prefork fork. The driver is DBD::Pg, already in the image — no
extra module. A database outage at start is a degraded, fail-closed start, not a failed one;
during a run the last good keys stay (`max_stale_s: 0`) or expire after `max_stale_s`. The
manual check against the stack's PostgreSQL is in `examples/service/skeid.yaml` next to the
commented section.

## Usage schema

`share/sql/usage_events.postgresql.sql` and `usage_events.sqlite.sql` are the shipped schemas
and the only ones. `auto_migrate` (default on) applies the shipped file on `prepare` — when the
config is applied, so at start — and adds any column an older table is missing; the example
stack relies on that and carries no schema of its own. Reports: `bin/skeid usage --json`, or
`GET /skeid/usage`.

`usage_store.flush_interval_ms` (sqlite/postgresql only, default `0` = synchronous write) turns
on write-behind: events queue in memory and are written every that many ms, and on reload,
shutdown, report and `flush_usage`. A kill without flush loses the queue. Prefork stopped with
`SIGTERM` loses it too (the manager `SIGKILL`s its workers); `SIGQUIT` flushes, which is why the
image sets `STOPSIGNAL SIGQUIT` and the compose stack must not override it. `docker stop`
`SIGKILL`s after its grace period (10 s default): set `stop_grace_period` when streams run
longer. `jsonlog` remains the recommended default.
