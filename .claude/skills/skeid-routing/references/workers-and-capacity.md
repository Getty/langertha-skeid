Read this when working on `serve --workers`, per-process limits, `frontend_count`, or a capacity probe (inflight, ratelimit, prometheus, registry, custom).

## Workers

`serve --workers N` runs `Mojo::Server::Prefork`; default 1. Measured 170.7 req/s at 4 workers vs
128.1 at one, TTFT p50 88ms vs 120ms (`docs/bench/2026-08-09-prefork-workers.md`).

- **`inflight` and `max_conns` are per-process**: each process takes
  `max_conns / (frontend_count × N)` (`worker_max_conns`, floor 1; `routing.frontend_count` =
  Skeid hosts sharing the node, ADR 0012). Without it `max_conns: 8` over 4 workers permits 32,
  silently. A `max_conns` below the process count cannot be honoured; `worker_share_warnings`
  says so at startup. A shared scoreboard replacing the divisor is designed (ADR 0014), not built.
- Anything on a timer runs **once per worker**. Probe intervals are multiplied by the worker
  count (`poll_interval_seconds`) so the node sees the configured rate from the group; a probe
  whose scaled interval is not below `capacity_max_age_ms` warns at start. `frontend_count`
  scales no timer. Vault renewal is deliberately *not* scaled — each process keeps its own token.
- Under prefork the usage store is multi-writer: `jsonlog` (dir mode) and `postgresql` are fine,
  **SQLite is not**. Admin API writes reach one worker only, so the config file is the only
  workable source of truth (ADR 0010).

## Capacity probes

`inflight` counts what *this process* sent: exact for one Skeid in front of one node, an
undercount once a second frontend, a prefork worker or a batch job shares it — together they
over-admit. A probe reports what the node says instead (ADR 0009).

```yaml
nodes:
  - id: gpu-1
    max_conns: 32
    capacity:
      probe: prometheus                 # inflight (default) | ratelimit | prometheus | registry | custom
      url: http://gpu-1:8000/metrics    # or path: /metrics, resolved against the node URL
      interval_ms: 2000
      running: vllm:num_requests_running    # optional; defaults cover vLLM/SGLang/TGI
      limit: 32                             # optional; falls back to max_conns
```

| probe | how | cost |
|---|---|---|
| `inflight` | default; no probe object exists | none |
| `ratelimit` | `x-ratelimit-*` / `anthropic-ratelimit-*` / `Retry-After` off responses already held; requests **and** tokens read separately, tightest quota (as a fraction) decides; read for every node, `probe: ratelimit` starts nothing | none |
| `prometheus` | poll a metrics endpoint on a timer | one request per node per interval |
| `registry` | poll a downstream Skeid's signed snapshot (`secret_env`, `read_key_env` or `admin_key_env`; ADR 0017) | one request per node per interval |
| `custom` | a `code` callback or a `class` to load | caller's |

**A probe may only narrow what `max_conns` allows, never widen it.** `_node_can_take` asks both.
A reading that could raise the ceiling turns a stale probe into an overload, and for a rented
node `max_conns` is a spend limit.

- Readings expire after `capacity_max_age_ms` (5s). Every failure — unreachable endpoint,
  unrecognised metric names, bad or stale snapshot, a dying probe — forgets that probe's reading
  and lets `inflight` decide. Never keep the last reading: unknown is imprecise, stale is
  confidently wrong.
- Two sources on one node: the tighter reading wins while current — it carries a pending backoff,
  or is younger than the longer of the two poll intervals (ADR 0017).
- Prometheus `used` = `running + waiting`. A queued request occupies the node.
- A `429`/`Retry-After` sets a **backoff**: it outlives the age limit (a statement about the
  future) and **never touches `healthy`** — busy is not broken, and nothing would flip an
  error-driven flag back.
- Probing never happens on the request path; `ratelimit` reads a response already in hand.
- Dispatch: `capacity.set`, `capacity.get`, `capacity.observe`, `capacity.forget`. Probes are
  started by `build_app` and rebuilt when `_probe_inventory_key` moves (worker count plus id, URL
  and `capacity` block of every probed node) — not on a health flip, which would forget every
  reading (skeid #40).
