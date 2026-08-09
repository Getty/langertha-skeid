# Benchmark 2026-08-09 — key resolution moved off the request path

Regression check for karr #3: key resolution became asynchronous and cached, which put an
extra callback between routing and the upstream call on **every** request, brokered or not.
The question here is only whether that callback costs anything. It does not.

This run says nothing about the KeyBroker itself — `bench/skeid.bench.yaml` has no
`api_key_ref`, so no broker is consulted. Measuring the vault path needs a real OpenBao and
belongs in an example script, not here.

## Setup

| | |
|---|---|
| Host | shared development box, Linux 6.1, other services resident |
| Upstream | `bench/fakellm`, `--ttft-ms 20 --tokens-per-second 1000 --tokens 64` |
| Proxy | `bin/skeid serve`, `bench/skeid.bench.yaml`, one node, `max_conns 256`, jsonlog usage |
| Client | `bench/llmbench`, `--tokens 64`, `nice -n 19 ionice -c3` |
| Rev | `46ce87c` plus this session's working tree |

```bash
cd bench
nice -n 19 ionice -c3 ./run-bench.sh --requests 320 --concurrency 16   # twice
```

## Results

Two consecutive runs, 320 requests each at concurrency 16, against the 2026-08-08 baseline:

| | baseline 08-08 | run 1 | run 2 |
|---|---|---|---|
| json, throughput | 118.8 req/s | 124.3 | 131.0 |
| json, TTFT p50 | 129.70 ms | 121.71 | 120.25 |
| stream, throughput | 136.1 req/s | 129.7 | 127.4 |
| stream, TTFT p50 | 48.23 ms | 48.64 | 49.27 |
| fakellm direct, stream | 189 req/s | 185.2 | 185.4 |

No failures in any run (320/320 each).

## What this says

**The extra callback is free in the JSON path.** 124–131 req/s against a baseline of 118.8,
and TTFT p50 improved by ~8 ms. Both runs land above the baseline point, so if the indirection
costs anything it is smaller than the ~5% spread between two runs of identical code.

**The streaming path is 5% below the baseline point, and this run cannot say whether that is
real.** 129.7 / 127.4 against a single 136.1 measurement whose own spread was never
established. TTFT is unchanged (48.6 / 49.3 vs 48.23), which is what an added synchronous step
before the upstream call would have moved first — so this looks like run-to-run variance
rather than the change. Worth a look if streaming throughput matters enough to measure
properly; not worth a claim either way from this data.

**The ceiling has not moved.** The fake upstream still serves 185 req/s while Skeid tops out
around 130, unchanged from 08-08. One event loop remains the constraint (karr #7), and nothing
in this change touched that.

## What was not measured

- The KeyBroker path itself: cold-cache latency, cache hit rate, coalescing under a real
  vault. Needs an OpenBao; `t/27-keybroker-nonblocking.t` covers the behaviour, not the cost.
- Whether the token renewal timer disturbs latency when it fires. It runs every 300s by
  default and a run here lasts 2.5s, so no run has ever seen one.
