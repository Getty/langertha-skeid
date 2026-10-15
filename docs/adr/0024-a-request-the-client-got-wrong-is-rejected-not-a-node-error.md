# ADR 0024 — A request the client got wrong is `rejected`, not a node error

- Status: accepted — implemented (skeid k99)
- Date: 2026-10-15
- Tags: core, admission, registry, metrics

---

## Context

`request.finish` knew three outcomes: `ok`, failed, and `aborted` (the client hung up, k81).
Every other non-ok finish counted as a node error: the error counter, the registry snapshot's
`errors_in_window` and `last_failure_at`. That included an upstream 400, 404, 413 or 422 and,
since k92, a request refused after admission because the node's dialect had no place for it.
A client that sends bad requests made a healthy node look failing to a fronting Skeid.

## Decision

`request.finish` has a fourth outcome, `rejected`:

- Statuses 400, 404, 413 and 422 -- the request's to fix -- and a request refused after
  admission as unsendable (400) finish `rejected`. 401, 403 and 429 are *not* among them: they
  say something about the node's key or capacity and stay node errors, as does every 5xx.
- `rejected` counts in its own counter (`node_metrics` `rejected`), in no error counter, not in
  `errors_in_window`, not in `last_failure_at`. Like `aborted`, it never touches `healthy`.
  Precedence: `aborted` over `rejected` over `ok`.
- The registry snapshot gains one node field, `rejected_in_window`, over the same window as
  `errors_in_window`. Existing fields keep their meaning. The schema `version` stays 1: the
  field is additive, a consumer reads the fields it knows (`reading_from_snapshot`) and ignores
  the rest, and the signature covers the whole body, so an older fronting Skeid verifies and
  accepts a snapshot that carries it.
- The usage event is unchanged: `ok = 0`, with the status the client got. Billing and the
  node's health are different questions; only the second moved.

Every `request.start` still gets exactly one `request.finish`: `rejected` replaces the failed
flag on paths that already finished, it adds no path.

## Consequences

- `ok + error + aborted + rejected = started` is the pairing invariant for a quiet node.
- A fronting tier that wants the client-fault rate reads `rejected_in_window`; one that does not
  sees fewer, truer errors.
- Amends ADR 0017's node field list by one additive field.
