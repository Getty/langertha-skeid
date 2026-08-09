# Benchmark 2026-08-09 — `serve --workers`

Confirms that the prefork numbers from the 08-08 baseline hold for the flag as shipped, not
just for a hand-rolled launcher (karr #7, ADR 0010).

## Setup

| | |
|---|---|
| Host | shared development box, Linux 6.1, other services resident |
| Upstream | `bench/fakellm --host 127.0.0.1 --port 18080 --ttft-ms 20 --tokens-per-second 1000 --tokens 64` |
| Proxy | `bin/skeid serve --listen 127.0.0.1:18090 --config bench/skeid.bench.yaml --workers 4` |
| Client | `bench/llmbench`, `nice -n 19 ionice -c3` |
| Rev | `648e14f` plus the working tree of this change |

```bash
cd bench
nice -n 19 ionice -c3 ./llmbench --host 127.0.0.1 --port 18090 --model fakellm \
  --tokens 64 --requests 320 --concurrency 16 --warmup 5
nice -n 19 ionice -c3 ./llmbench --host 127.0.0.1 --port 18090 --model fakellm \
  --tokens 64 --requests 640 --concurrency 32 --warmup 5
```

The bench node has `max_conns: 256`, so each of 4 workers admits 64 — well above the
concurrency used here. This run does **not** exercise the partitioning; `t/30-worker-share.t`
does that.

## Results

| | one process (08-08) | `--workers 4` |
|---|---|---|
| json c=16, throughput | 128.1 req/s | **170.7** |
| json c=16, TTFT p50 | 120.4 ms | **87.9** |
| json c=32, throughput | — | **334.5** |
| json c=32, TTFT p50 | — | 89.9 ms |

960 requests total, 0 failures. Upstream direct at c=16 was 185–188 req/s in earlier runs.

## What this says

**The flag delivers what the hand-rolled prefork measured.** 170.7 vs the 177.7 the baseline
saw at c=16, and 334.5 vs 350.2 at c=32 — both a few percent under, which is within the
run-to-run spread this box shows and not worth reading as a difference.

**TTFT stops growing with concurrency.** 87.9 ms at c=16 and 89.9 ms at c=32, against an
upstream floor of ~83 ms. Single-process TTFT was 120 ms at c=16 and rising. Skeid's overhead
per request goes from +37 ms to roughly +5 ms simply by having four loops instead of one.

**The ceiling moved rather than disappeared.** At c=32 the fake upstream is now the constraint
again, so this run cannot say where four workers top out — only that it is above 334 req/s.
Finding the new ceiling needs a faster upstream or more concurrency, and neither is worth doing
on a shared box.

## What was not measured

- The partitioning itself. Every worker here had 64 slots and used a handful.
- Whether four workers' capacity probes cost anything measurable. The interval is multiplied by
  the worker count for exactly this reason, but nothing here polls a real metrics endpoint.
- Behaviour when `max_conns` is genuinely the constraint under prefork — that is where
  partitioning trades throughput for not over-admitting, and it deserves its own run against a
  node that actually saturates.
