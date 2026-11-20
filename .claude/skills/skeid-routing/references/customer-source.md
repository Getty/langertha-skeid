Read this when working on `customer_source` — customer key ids, names and policies fetched from a database view.

## Customer source

Customer key ids, names and policies from a database view (ADR 0026,
`Langertha::Skeid::CustomerSource`, fetcher `::CustomerSource::DBI`). The section is
`customer_source: { backend: postgresql, dsn | host / port / dbname, user, password_env,
from_usage_store, relation, refresh_interval_s, listen, max_stale_s, connect_timeout_s }` —
`from_usage_store: true` takes the usage store's PostgreSQL connection instead of a `dsn`, the
password always comes from `password_env`. The relation gives
`key_id, name, policy, models` per active key. The rule everything rests on: **the database is
never on the request path, and its connect never runs in the loop's process.** The fetcher polls
on `Mojo::IOLoop` every `refresh_interval_s`; each fetch is a `Mojo::IOLoop->subprocess` that
connects with blocking DBI, runs the one statement and returns the rows (k109); with `listen` a
second child waits for `NOTIFY` (+ 250 ms debounce). Back-off like `_reload_retry_delay`;
`connect_timeout_s` bounds each fetch (libpq `connect_timeout`, `statement_timeout`, and the
parent kills an overrunning child). The **source snapshot** is the last good fetch; a changed
digest calls `reload_config` from the fetch callback, an unchanged one does nothing. The
fingerprint is the file's + `;customer_source:<digest>`, so `maybe_reload_config` still only
reads the file and merges whatever snapshot is in memory.

- Merge happens first in `_apply_config` (`merge_into`): rows are checked (`check_rows` — full id
  only, duplicates reject both, policy must exist in the file, models a list of names), the file
  wins per id (`keys:` directly, via `names:`, short-id prefix → shadowed), the rest become
  `keys:` entries. Accepted ids are added to `client_auth_keys` **after** `_load_client_auth`
  and only when the file declares `client_auth` — a union. No row can make a reload die;
  rejected rows are reported by name or position, never by value (a key may be pasted there).
- Fail-closed: no snapshot (startup failure) or a stale one (`max_stale_s`) merges nothing.
  A failing fetch keeps the last good snapshot. A removed section drops it; a changed one
  restarts the fetcher and keeps the snapshot until the new source answered.
- `build_app` calls `start_customer_source`; `skeid serve` runs `customer_source_startup_fetch`
  (bounded, before listening) and `customer_source_release` before prefork forks (kills the
  children). Tests inject `customer_source_fetcher => sub { $fake }`; `t/83`–`t/87`. `t/87`
  runs the real DBI fetcher on SQLite and against a listener that never answers.
- Not verified offline: the LISTEN child and a real PostgreSQL (`text[]` for `models`) — the
  manual procedure sits in `examples/service/skeid.yaml`.
