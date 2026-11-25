# Benchmark 2026-11-25 — RawBody string tokens unrolled (k140)

k140 changes only `lib/Langertha/Skeid/Protocol/RawBody.pm` (uncommitted on `main`, sha256
`7a5fd7bb…`, the same before the first run and after the last): the three JSON string matches in
`_top_level_spans` and `_skip_value` use the unrolled `$STRING_TOKEN`
(`"[^"\\]*+(?:\\.[^"\\]*+)*+"`) instead of `"(?:[^"\\]|\\.)*"`, one alternation per character.
These are the matches `with_top_level` uses on every OpenAI chat and embeddings request (the
ADR 0023 byte relay), filter or not. Baseline: HEAD `5908149`.

Short answer:

- **Small bodies: unchanged.** Chat 192 B and embeddings 539 B are within ±0.4 % req/s at c=16
  and c=64, except embeddings at c=64 (+2.5 %, 6 of 6 rounds faster, at the edge of the
  run-to-run spread).
- **~21 KB: +18 % (chat) and +34 % (embeddings) req/s at c=16, +34 % and +42 % at c=64.** TTFT
  p50 drops by 25 ms at c=16 and by 101 ms at c=64.
- **~209 KB: 2.4× (chat) and 3.7× (embeddings) req/s at c=16, 3.2× and 4.1× at c=64.** TTFT p50
  drops by about 1 s at c=64. At c=64 the request costs 15.6–15.9 ms less CPU.
- **The scan itself** (`with_top_level` in-process) is 10× faster on chat bodies and 23–25× on
  embeddings bodies at 21–209 KB, with byte-identical output.
- Every round favoured the tree in every cell from 21 KB up (6 of 6). No request failed.

## Setup

| | |
|---|---|
| Host | shared box, Linux 7.0.14, 8 CPUs, other users' work resident (load average 1.7–3.1 during the runs) |
| Perl | system perl 5.40.1, Mojolicious 9.49 |
| Upstream | `bench/fakellm --tokens 64 --port 18080 --host 127.0.0.1 --ttft-ms 20 --tokens-per-second 1000`, started fresh for every item |
| Proxy | `perl -Ilib bin/skeid serve --listen 127.0.0.1:18090 --config $S/cfg.yaml`, **one process**, from `$S/head` (head) or the repo (wt) |
| Client | `llmbench2` from the 2026-11-25 filter-seam report (`bench/llmbench.c` + `--body-file`, `--marker`), `--warmup 5` |
| Revs | head = `git archive 5908149 \| tar -x -C $S/head`; wt = working tree. `lib/` differs only in `RawBody.pm`, `bin/` not at all |

`$S` is `/tmp/claude-1001/-home-frank-langertha-skeid/e010b437-50ee-463a-96bd-09b7e33f1be3/scratchpad/k140`.
`$S/cfg.yaml` is `bench/skeid.bench.yaml` with `usage_store.path` set to `$S/usage/` (jsonlog,
`mode: dir`), deleted after every item. Everything ran under `nice -n 19 ionice -c3`, one call at
a time, each call under 180 s (`timeout`, a `flock` and a port guard in the driver).

Bodies: `small`, `m20`, `m200` and `emb` are the filter-seam bodies. `e20` / `e200` are
embeddings bodies whose `input` is the 20 / 200 message texts of `m20` / `m200`.

| body | bytes | path |
|---|---|---|
| small | 192 | chat, 1 message |
| m20 | 20 987 | chat, 20 messages of ~1 KB |
| m200 | 208 958 | chat, 200 messages |
| emb | 539 | embeddings, 4 strings |
| e20 | 20 322 | embeddings, 20 strings of ~1 KB |
| e200 | 202 623 | embeddings, 200 strings |

```bash
# $S/drive.sh GROUP ROUND ITEM...   (ITEM = direct | head | wt; c = 16 then 64)
llmbench2 --port P --requests $((40*c)) --concurrency c --body-file {small,m20}.json --json          # sm group
llmbench2 --port P --requests $((40*c)) --concurrency c --path /v1/embeddings \
          --body-file {emb,e20}.json --marker '"embedding"' --json                                    # sm group
llmbench2 --port P --requests $((10*c)) --concurrency c --body-file m200.json --json                 # lg group
llmbench2 --port P --requests $((10*c)) --concurrency c --path /v1/embeddings \
          --body-file e200.json --marker '"embedding"' --json                                         # lg group
```

Six rounds per group. Order: lg rounds alternate `head wt` / `wt head` in one call. sm rounds run
one item per call (an sm item for head takes ~73 s) in the order `head wt`, `wt head`, `head wt`,
… . 160 runs, 188 800 requests, 0 failed. No run fell below 60 % of its cell's median, so none
was discarded.

## Instrument check

Direct chat total p50 was 83.2–83.3 ms (20 + 63/1000 s) and direct req/s 191.7 at c=16 and 766
at c=64 (c / 83 ms). Direct embeddings TTFT was 20.2–20.3 ms. Body size barely moved fakellm
(m200 191.1 / 759.0, e200 776 / 3042 req/s).

## Results

Medians over 6 rounds, range in brackets. TTFT p50/p95/p99 are medians of the per-run
percentiles. "wt/head" is the median of the per-round ratios. CPU per request is read at c=64,
where the one process is saturated: 1 / req/s.

| c=16 | direct | head `5908149` | wt | wt/head |
|---|---|---|---|---|
| small req/s | 191.7 | 119.2 [118.3–119.8] | 118.9 [118.5–120.2] | 0.998 [0.989–1.011], 2/6 faster |
| small TTFT p50/p95/p99 ms | 83.3 / 83.7 / 83.8 | 132.6 / 134.5 / 136.3 | 132.3 / 134.9 / 138.0 | p50 −0.0 ms |
| m20 req/s | 191.8 | 96.9 [95.4–98.0] | 114.2 [113.4–115.3] | **1.18** [1.17–1.20], 6/6 |
| m20 TTFT p50/p95/p99 ms | 83.3 / 83.6 / 83.8 | 162.2 / 167.0 / 172.6 | 137.3 / 142.7 / 147.8 | p50 −25.0 ms |
| m200 req/s | 191.1 | 38.1 [37.0–38.8] | 90.2 [89.3–90.8] | **2.36** [2.32–2.45], 6/6 |
| m200 TTFT p50/p95/p99 ms | 83.3 / 83.7 / 84.0 | 415.5 / 435.9 / 436.5 | 174.8 / 184.2 / 184.4 | p50 −240 ms |
| emb req/s | 785.9 | 225.3 [221.5–227.3] | 226.8 [225.0–229.3] | 1.004 [0.998–1.035], 4/6 |
| emb TTFT p50/p95/p99 ms | 20.2 / 20.6 / 20.7 | 69.1 / 70.9 / 72.1 | 68.5 / 70.3 / 74.1 | p50 −0.4 ms |
| e20 req/s | 786.1 | 162.7 [157.4–163.8] | 218.7 [209.6–221.6] | **1.34** [1.30–1.37], 6/6 |
| e20 TTFT p50/p95/p99 ms | 20.2 / 20.5 / 20.6 | 96.0 / 99.5 / 104.2 | 70.9 / 74.1 / 81.8 | p50 −25.4 ms |
| e200 req/s | 776.2 | 46.0 [44.3–46.8] | 167.4 [164.0–203.8] | **3.66** [3.58–4.46], 6/6 |
| e200 TTFT p50/p95/p99 ms | 20.3 / 20.5 / 20.6 | 344.3 / 355.0 / 355.3 | 93.4 / 96.0 / 98.2 | p50 −251 ms |

| c=64 | direct | head `5908149` | wt | wt/head | CPU/req head → wt |
|---|---|---|---|---|---|
| small req/s | 766.2 | 219.4 [217.1–222.3] | 220.9 [220.1–225.5] | 1.004 [0.994–1.030], 5/6 | 4.56 → 4.53 ms |
| small TTFT p50/p95/p99 ms | 83.2 / 84.1 / 84.3 | 271.4 / 290.1 / 301.3 | 264.9 / 284.3 / 297.6 | p50 −4.1 ms | |
| m20 req/s | 766.4 | 155.8 [153.2–156.9] | 207.8 [205.4–210.0] | **1.34** [1.32–1.36], 6/6 | 6.42 → 4.81 ms |
| m20 TTFT p50/p95/p99 ms | 83.2 / 84.4 / 84.8 | 394.3 / 410.9 / 432.8 | 293.2 / 304.0 / 318.9 | p50 −101 ms | |
| m200 req/s | 759.0 | 43.5 [42.5–45.5] | 136.4 [134.6–154.6] | **3.16** [2.96–3.55], 6/6 | 22.96 → 7.33 ms |
| m200 TTFT p50/p95/p99 ms | 83.3 / 85.1 / 85.9 | 1442 / 1529 / 1531 | 453.3 / 478.2 / 478.4 | p50 −991 ms | |
| emb req/s | 3121.2 | 282.9 [277.6–283.4] | 289.1 [283.9–292.0] | 1.025 [1.003–1.039], 6/6 | 3.53 → 3.46 ms |
| emb TTFT p50/p95/p99 ms | 20.2 / 20.9 / 21.5 | 210.5 / 223.4 / 230.5 | 205.1 / 215.2 / 221.4 | p50 −4.9 ms | |
| e20 req/s | 3130.4 | 190.3 [186.5–192.9] | 272.5 [269.5–274.9] | **1.42** [1.42–1.47], 6/6 | 5.25 → 3.67 ms |
| e20 TTFT p50/p95/p99 ms | 20.2 / 20.6 / 21.8 | 321.3 / 331.8 / 346.3 | 220.1 / 231.9 / 245.6 | p50 −101 ms | |
| e200 req/s | 3042.2 | 47.5 [46.5–48.2] | 194.2 [191.5–196.6] | **4.10** [4.01–4.18], 6/6 | 21.03 → 5.15 ms |
| e200 TTFT p50/p95/p99 ms | 20.3 / 20.4 / 20.6 | 1322 / 1373 / 1374 | 315.8 / 321.8 / 327.1 | p50 −1009 ms | |

Noise: a variant's req/s spans 1–3 % across rounds in the sm cells. In the lg cells one wt run
each in m200 c64 and e200 c16 came out 13–22 % above the others; the medians absorb it. The
small-body deltas (−0.2 to +2.5 %) are inside or at the edge of that spread. The 21 KB and
209 KB deltas are 6–100× wider than it.

The single-process ceiling explains why c=64 gains more than c=16: at c=16 the 20 ms upstream
still hides part of the CPU cost, at c=64 the process is saturated and req/s is 1 / CPU.

### The scan in isolation (`$S/micro.pl`, `Benchmark` −2 s per body, niced)

`with_top_level($bytes, model => 'fakellm')`; the output was byte-identical between the trees
(md5 per body):

| body | head µs | wt µs | ratio |
|---|---|---|---|
| small | 30.3 | 26.9 | 1.1× |
| m20 | 1 763 | 177 | 10× |
| m200 | 16 232 | 1 666 | 9.7× |
| emb | 48.1 | 18.5 | 2.6× |
| e20 | 1 506 | 66.6 | 23× |
| e200 | 15 056 | 594 | 25× |

The end-to-end CPU saving at c=64 (1.6 ms at 21 KB, 15.6–15.9 ms at 209 KB) is close to the
scan saving (1.4–1.6 ms, 14.5–14.6 ms), so the scan accounts for nearly all of the gain. The remaining cost of a 209 KB chat request over a small one
(7.33 vs 4.53 ms) is decoding and copying the body, not the scan.

A body that is one long string shows the old pattern's shape most clearly (`perl -e`, one call
each): 100 000 characters take 23 ms at head and 0.19 ms in the tree, 1 000 000 characters take
251 ms and 1.65 ms. That is how long the event loop stood still for every other request in the
process. Both trees returned the right bytes; no regex limit was hit.

## On the Changes claim

"Large chat and embeddings bodies are scanned several times faster" is true, but it undersells
the scan (10–25×) and leaves the reader to guess the request-level effect, which is what a user
notices. Honest wording, with the numbers above behind it:

> OpenAI chat and embeddings requests match a JSON string in one step instead of one character at
> a time when relaying the body: the scan of a 21–209 KB body is 10–25× faster, which raises
> single-process throughput by 18–42 % at ~21 KB and 2.4–4.1× at ~209 KB. Small bodies are
> unchanged.

Avoid "several times faster" without the word *scanned*: at ~21 KB the request gets +18–42 %,
not several times.

## Not measured

Streamed chat requests (`stream: true` bodies take the same relay but were not driven here);
the Anthropic and Ollama faces; the filter path (its `substitute` also calls `with_top_level`);
escape-dense strings; `serve --workers N`; a real upstream, TLS, network, cold start; any usage
store other than jsonlog. NYTProf is still not installed on this host, so the attribution above
rests on the in-process timing, not a profile.
