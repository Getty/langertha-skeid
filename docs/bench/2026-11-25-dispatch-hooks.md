# Benchmark 2026-11-25 — dispatch hooks (k111)

Answers k111's open perf question for the rebuilt dispatch hooks (ADR 0030, uncommitted on
`main`). There are two questions:

1. Does plain Langertha::Skeid lose anything? The new route path pays one `picks_async` lookup
   and one extra closure call per request (`Proxy.pm` `_begin_route_async`).
2. What does a class cost that overrides `pick_node_p` with a promise that is already resolved,
   served with `skeid serve --class`? The lost build of 2026-11-04 measured 3.6–5.7 % req/s.

Short answer:

- **Plain Skeid is within noise of the baseline.** The median req/s delta is +0.1 / −0.6 / −0.5 /
  −1.0 % (json c16 / stream c16 / json c64 / stream c64). In every cell the per-round range
  straddles zero, and the TTFT p50 delta is under ±2.1 ms in every cell.
- **Overriding `pick_node_p` costs 3.7–4.3 % req/s at c=16 and 6.6–7.1 % at c=64.** TTFT p50 is
  +5–6 ms at c=16 and +22–24 ms at c=64. Async was slower in every round of every cell (35 of 35
  paired rounds). The 2026-11-04 range of 3.6–5.7 % matches the c=16 figures. At c=64 the cost is
  larger.
- **About half of that cost is avoidable, and has nothing to do with the promise.** On the
  async path the action returns before anything calls `render_later`. Mojolicious then runs
  `render_maybe` on every request: a template lookup for `v1chatcompletions.html.ep` plus a
  trace log line. One `$c->render_later` ahead of `route.next_p` (a scratch copy, not the
  repo) gets back +2.6 to +3.6 % req/s and 3–13 ms of TTFT p50, in 24 of 24 paired rounds.

## Setup

| | |
|---|---|
| Host | shared box, Linux 7.0.14, 8 CPUs, 64 GB, other users' work resident (load average 1.6–6.0 during the runs) |
| Perl | system perl 5.40.1; Mojolicious 9.49, EV 4.37, Cpanel::JSON::XS 4.43 |
| Upstream | `bench/fakellm --port 18080 --ttft-ms 20 --tokens-per-second 1000 --tokens 64`, started fresh every round |
| Proxy | `perl -Ilib bin/skeid serve --listen 127.0.0.1:18090 --config <bench config>`, **one process**, stdout and stderr to `/dev/null` (as `run-bench.sh` does) |
| Client | `bench/llmbench --requests (40×c) --concurrency c --tokens 64 [--stream] --json`, `--warmup 5` (default) |
| Config | `bench/skeid.bench.yaml` with only `usage_store.path` changed to a scratch directory, the same file for every variant |
| Revs | baseline `b03e801` (HEAD); working tree = HEAD + the uncommitted k111 diff (`git diff HEAD -- lib bin \| sha256sum` → `bbc94f6fb649fe32`) |

The working-tree files were last modified at 05:43 and did not change during the runs
(05:53–06:29).

The whole driver ran under `nice -n 19 ionice -c3`, so the server, fakellm and the client all
ran niced, the same way for every variant. Only one run was active at a time.

### Variants

| variant | tree | command |
|---|---|---|
| base | `git archive b03e801 lib bin` in scratch | `perl -Ilib bin/skeid serve --listen 127.0.0.1:18090 --config $CFG` |
| plain | working tree | same |
| async | working tree | `perl -Ilib bin/skeid serve --class Bench::Skeid::AsyncPick -I $S/lib --listen 127.0.0.1:18090 --config $CFG` |
| async+rl | working tree copy + one line (see below), scratch only | as async |

`Bench::Skeid::AsyncPick` is the cheapest override possible. It returns the same node as the
default pick, so the only difference from plain is that `picks_async` is true and the proxy
takes the promise path:

```perl
package Bench::Skeid::AsyncPick;
use Moo;
use Mojo::Promise;
use namespace::clean;
extends 'Langertha::Skeid';

sub pick_node_p {
  my ($self, %selector) = @_;
  return Mojo::Promise->resolve($self->pick_node(%selector));
}

1;
```

`picks_async` was checked as 1 for this class and 0 for Langertha::Skeid. `serve` printed
`Class: Bench::Skeid::AsyncPick` at start.

### Driver

Each round:

1. Start fakellm.
2. Measure fakellm directly: json and stream, at c=16 then c=64.
3. Run the three variants in an order that rotates each round
   (`base plain async` / `plain async base` / `async base plain`).
4. Start each variant fresh, measure json and stream at c=16 and then c=64, and stop it.
   The driver waits for the process to exit before starting the next.

That makes 9 rounds, each order three times, so a variant cannot look better because of its
position in the round. Requests per run: 640 at c=16, 2560 at c=64. Every variant has a fakellm
baseline from the same round, taken minutes earlier with the same client.

```bash
llmbench --port 18080|18090 --requests $((c*40)) --concurrency $c --tokens 64 [--stream] --json
```

**Discard rule:** a run below 60 % of its variant's median req/s for that cell counts as a
box disturbance. Four runs met it:

- base json c16 (r4): 18.0 req/s
- base stream c16 (r4): 17.8 req/s
- plain json c64 (r2): 116.4 req/s, p95 1261 ms
- direct stream c64 (r4): 409.5 req/s

The r4 load average rose to 5.95 at the same time, and the direct baseline collapsed with
those runs, so this is the box, not Skeid. The plain json c64 stall (p95 ≈ 1.26 s) appeared once
more in a set-aside sanity round, but base also showed it in r4. Plain never showed it in the
other 8 rounds. It is not a plain-only effect.

Across the 9 rounds, the 108 Skeid runs and 36 direct runs had 0 failed requests. That covers
the 4 discarded runs too.

## Instrument check

The instrument agrees with its own settings. Direct streaming TTFT p50 was 20.14–20.17 ms for
`--ttft-ms 20`. Direct JSON total p50 was 83.2 ms, which is 20 + 63 tokens / 1000 tok/s. Direct
req/s was 191.8 at c=16 and 766 at c=64, which is c / 83 ms.

## Results

Each cell is the median over the kept rounds (n). The range is in brackets. TTFT p50/p95/p99 are
the medians of the per-run percentiles, and the p99 range is over runs.

### c=16

`llmbench --requests 640 --concurrency 16 --tokens 64 [--stream]`

| c=16 | direct | base `b03e801` | plain | async |
|---|---|---|---|---|
| json n | 9 | 8 | 9 | 9 |
| json req/s | 191.8 | 119.1 [118.0–120.8] | 119.0 [118.3–120.5] | **114.4** [113.0–116.0] |
| json TTFT p50 / p95 / p99 ms | 83.2 / 83.6 / 84.0 | 131.9 / 135.8 / 138.0 | 132.1 / 136.3 / 139.1 | 137.6 / 141.3 / 144.4 |
| json TTFT p99 range ms | | 134.1–155.1 | 133.3–150.9 | 139.4–163.9 |
| stream n | 9 | 8 | 9 | 9 |
| stream req/s | 192.0 | 114.5 [112.7–115.6] | 114.2 [112.4–115.2] | **109.3** [107.6–111.1] |
| stream TTFT p50 / p95 / p99 ms | 20.2 / 20.3 / 20.5 | 60.6 / 65.9 / 69.7 | 60.7 / 64.4 / 66.2 | 66.9 / 71.5 / 72.7 |
| stream TTFT p99 range ms | | 62.9–81.8 | 64.3–87.8 | 69.3–80.5 |
| stream total p50 ms | 83.2 | 139.7 | 139.8 | 145.9 |

### c=64

`llmbench --requests 2560 --concurrency 64 --tokens 64 [--stream]`

| c=64 | direct | base `b03e801` | plain | async |
|---|---|---|---|---|
| json n | 9 | 9 | 8 | 9 |
| json req/s | 766.2 | 223.8 [218.4–230.3] | 221.3 [220.4–227.2] | **205.8** [200.2–212.1] |
| json TTFT p50 / p95 / p99 ms | 83.2 / 84.0 / 84.9 | 264.1 / 285.9 / 302.1 | 264.3 / 286.6 / 292.3 | 286.9 / 307.1 / 322.5 |
| json TTFT p99 range ms | | 279.2–630.5 | 279.9–311.2 | 302.7–400.3 |
| stream n | 8 | 9 | 9 | 9 |
| stream req/s | 767.5 | 187.9 [181.3–191.3] | 187.0 [181.1–188.1] | **174.8** [171.0–177.7] |
| stream TTFT p50 / p95 / p99 ms | 20.1 / 20.4 / 21.1 | 199.4 / 213.0 / 245.3 | 201.1 / 216.4 / 237.3 | 223.3 / 238.8 / 253.2 |
| stream TTFT p99 range ms | | 209.2–299.5 | 212.6–284.2 | 239.7–326.6 |
| stream total p50 ms | 83.2 | 340.1 | 341.7 | 363.2 |

### Paired deltas (same round, both runs kept)

These are the medians over rounds of the per-round delta. The brackets give the range. "slower"
counts the rounds in which the first variant had fewer req/s.

| | plain vs base | async vs plain | async vs base |
|---|---|---|---|
| json c16 req/s | +0.1 % [−0.9..+0.6], 3 of 8 slower | **−3.7 %** [−5.4..−3.0], 9 of 9 | −4.0 % [−5.2..−2.5], 8 of 8 |
| json c16 TTFT p50 | +0.16 ms [−0.77..+0.72] | +5.07 ms [+4.65..+6.64] | +5.53 ms |
| stream c16 req/s | −0.6 % [−1.1..+1.9], 5 of 8 | **−4.3 %** [−5.6..−2.0], 9 of 9 | −3.7 % [−6.5..−2.3], 8 of 8 |
| stream c16 TTFT p50 | +0.36 ms [−1.40..+1.02] | +6.11 ms [+4.81..+7.74] | +6.02 ms |
| json c64 req/s | −0.5 % [−2.7..+3.1], 5 of 8 | **−7.1 %** [−10.3..−5.0], 8 of 8 | −7.9 % [−11.8..−5.0], 9 of 9 |
| json c64 TTFT p50 | −2.10 ms [−4.79..+4.42] | +24.0 ms [+15.4..+29.1] | +23.6 ms |
| stream c64 req/s | −1.0 % [−3.6..+3.1], 6 of 9 | **−6.6 %** [−7.9..−2.9], 9 of 9 | −6.4 % [−10.6..−3.7], 9 of 9 |
| stream c64 TTFT p50 | +1.10 ms [−4.29..+7.53] | +22.5 ms [+15.1..+26.6] | +23.6 ms |

Base and plain run to run: base vs base across rounds spans about 2–3 % at c=16 and about 6 %
at c=64 (the req/s ranges above). That is the noise floor any plain-vs-base claim has to clear,
and none does.

## Where the async cost goes: a missing `render_later`

The sanity round logged trace output to files. The async server wrote two lines per request
that plain and base never wrote:

```
[trace] Template "v1chatcompletions.html.ep" not found
[trace] Nothing has been rendered, expecting delayed response (see FAQ for more)
```

Every handler calls `$c->render_later` inside the `_begin_route_async` callback (`Proxy.pm`,
e.g. lines 1447, 1488, 2005). On the synchronous pick, that callback runs before the action
returns. On the promise path it runs a turn later. By then Mojolicious has seen an action
return with nothing rendered. It has called `render_maybe`, looked for a template and logged
its way out, and it does all of this for every request. The responses are correct: every
response was 200, with no early empty render. The cost is wasted work.

To size it, a scratch copy of the working tree (not the repo) gets one line ahead of the
promise in `_begin_route_async`:

```perl
    $c->render_later;   # k111 bench experiment only

    $c->skeid->call_function('route.next_p', \%selector)->then(sub {
```

With that line, the two trace lines are gone: 0 in 20 requests. Six rounds with the order
alternating (`async async+rl` / `async+rl async`), same driver and flags, no run discarded:

| | async req/s | async+rl req/s | Δ req/s | Δ TTFT p50 | rounds faster |
|---|---|---|---|---|---|
| json c16 | 114.2 | 117.1 | **+2.6 %** [+2.0..+3.4] | −3.4 ms | 6 of 6 |
| stream c16 | 108.7 | 112.0 | **+3.0 %** [+1.4..+4.0] | −4.0 ms | 6 of 6 |
| json c64 | 204.9 | 211.7 | **+2.6 %** [+1.7..+6.3] | −8.1 ms | 6 of 6 |
| stream c64 | 174.2 | 181.3 | **+3.6 %** [+0.4..+5.7] | −12.9 ms | 6 of 6 |

Compared with the plain figures above, taken 10–30 minutes earlier in other rounds (an
estimate, not a paired measurement), this recovers about two thirds of the async cost at c=16
and about half at c=64. What remains (roughly −1.5 % at c=16, −3 to −4.5 % at c=64) is the
promise itself: one more loop turn per request, plus the `then` / `catch` chain.

This is a finding, not a fix. The line is recorded on k111 for the worker. It would also
improve any real `pick_node_p` override, whose promise resolves later still.

## What this says

**Question 1: plain is free.** The `picks_async` lookup and the extra closure do not show up.
All four plain-vs-base medians are within ±1 %, and every range crosses zero. The choice on the
2026-11-04 card stands: call `pick_node` directly unless the class overrides `pick_node_p`.

**Question 2: the async pick costs about 4 % at c=16 and about 7 % at c=64.** That is one
process and the cheapest override possible, so a real one can only cost more. The cost rises
with concurrency because every request goes through the loop one more time, and at c=64 the
loop is the ceiling. About half of the cost is the missing `render_later`, a one-line fix in
`_begin_route_async`. The rest is the price of asking through a promise. The ADR's reason for
keeping the sync pick as the default holds.

## What was not measured

- **A real `pick_node_p`** that waits on something outside the process: a timer, an HTTP call to
  a GPU manager. Only an already-resolved promise was measured. It is the lower bound.
- **The other hooks**: `route_plan`, `pick_node`, `start_request` and `finish_request`
  overrides (`t/lib/Test/Skeid/Dispatch.pm`). These are synchronous method overrides, probably
  the cost of an `around`. That is an inference, not a measurement.
- **`--workers N`**: one process only. Prefork divides the connections per loop, so the c=64
  figures show the cost at its worst.
- **c=1**, so there is no serial per-request figure. Only c=16 and c=64 were asked for.
- **The Anthropic and Ollama faces**, rerank and audio. Only `/v1/chat/completions`
  (OpenAI face) was measured.
- **`skeid pack`**: the packed file's request path and startup. The card has container
  numbers from `xt/author/pack.t`, which were not taken here.
- **TLS, a real upstream, KeyBroker, database usage stores, cold start**, as in every `bench/`
  report (ADR 0007).
- **Noise.** This is a shared box with other users' processes. Four runs were discarded and are
  named above. The remaining spread is in the ranges.
