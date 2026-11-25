# ADR 0034 — The jsonlog store in dir mode writes one directory per UTC day

- Status: accepted (skeid k131)
- Date: 2026-11-25
- Tags: usage, jsonlog, storage, retention, operations

---

## Context

`UsageStore::JsonLog` in `mode: dir` (the default) wrote one `<id>.json` per usage event,
all into `<path>`. Each file is created exclusively, so it needs no lock and is safe with
several writers. ADR 0004 makes the usage event the billing unit; this store is the recommended
one because a write is an append that cannot stall the loop (ADR 0005).

On a fleet host the flat directory held ~28k files (113 MB) after five days of light traffic.
`ls events/*` failed with "Argument list too long". Disk was fine, but the directory grew
without bound. `skeid usage-purge --retention` already worked on it, but nothing runs it on a
schedule, and every listing and every purge scanned all files ever written.

The options on the card were rotation (a new directory or file when one gets large) or daily
directories. The maintainer chose daily directories (2026-11-25).

## Decision

### 1. Layout: `<path>/YYYY-MM-DD/<id>.json`

An event goes into the directory of the **UTC day of the time in its event id**. That is when
it was written, not its `created_at`. A caller can supply `created_at` (backfills, tests with
2020 dates), while the id and its directory come from the same clock reading and so always
agree, midnight included.

`mode: file` (one JSON Lines file) is unchanged.

### 2. The write path stays cheap

A store remembers the last day directory it made or found, so it calls `mkdir` once per day
and per process, not once per event. `EEXIST` from another writer is fine. If a purge removed
the cached day directory, the exclusive create fails with `ENOENT`. The store forgets the cached
day, makes the directory again, and retries within the existing attempt limit.

### 3. Old flat files keep working, with no migration

`report` and `purge` read the day directories **and** the flat `<path>/*.json` files a store
wrote before this change, ordered by id across both. An existing directory needs no migration.
New events go into day directories only.

Listing uses `readdir`, not `glob`, because `glob` splits a path that contains a space.

### 4. A purge removes the day directories it empties

After a purge (not a dry run), each day directory left with no events is removed with `rmdir`.
`ENOTEMPTY`/`EEXIST` (a writer put an event in it meanwhile) and `ENOENT` are ignored. Any other
error fails the purge with the directory named. A repeated purge completes the removal, because
purges are idempotent.

## Consequences

- **The on-disk layout is a promise.** Operators and external tooling that read
  `<path>/*.json` directly must look one level deeper (`<path>/*/*.json`). Changing the layout
  again needs a new ADR, plus a read path for this layout.
- A retention purge still reads every event to apply its filter. The layout does **not** let a
  purge drop a day by name, because the directory is the write day, not `created_at`. That is
  deliberate: billing filters on `created_at`, and a purge must not delete an event just because
  of where it was written. Dropping whole days without reading them would be a later
  optimisation with its own decision.
- A single directory never holds more than one day's events, so `ls` and shell globs work on it
  again, and an operator can see at a glance which days are on disk.
- Nothing purges on its own: retention is still `skeid usage-purge --retention` on a schedule.
- `report` still reads and aggregates every event in memory (the store's documented limit). A
  deployment that outgrows that needs a database backend, not an index on this directory.
