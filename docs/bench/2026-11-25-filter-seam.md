# Benchmark 2026-11-25 — the filter seam (k118)

Answers k118's perf questions for the filter seam (ADR 0035, uncommitted on `main`):

1. With no `filter:` section and the plain class, is the default path unchanged? Checked on
   OpenAI chat JSON, streamed chat and embeddings, tree vs. baseline `1f1e847`.
2. With a filter configured but the node not carrying its `when` tag, what does the per-request
   text extraction cost? Checked with the small default body, a 20-message / 21 KB body and a
   200-message / 209 KB body.
3. On the filtered path (an in-process filter that answers `replace` at once, no network), what
   does a replaced non-stream request cost, and what does a 512-token stream on the OpenAI face
   cost?

Short answer:

- **Default path: within per-cell noise, with a small consistent lean.** Per cell, plain vs.
  base is −0.8 to −1.5 % req/s, every range straddles zero, and TTFT p50 moves by +0.6 to +5 ms.
  Pooled over the 54 paired runs, though, plain was slower in 39 (sign test p = 0.0015, pooled
  median −1.0 %). It is about 1 %, below the 2–3 % run-to-run spread of a single variant. The
  diff gives no obvious cause, and I could not profile it (NYTProf is not installed on this
  host).
- **Filter configured, node outside `when`: nothing measurable on small bodies, and a cost that
  grows with the body.** Small bodies: −0.3 % pooled, 32 of 54 slower, p = 0.22. On large bodies
  the extraction shows clearly: **+0.23 ms per request at 21 KB (−3.4 % req/s at c=64) and
  +1.8 ms at 209 KB (−7.1 %)**, slower in every round.
- **Filtered path, non-stream: +0.64 ms per request (small body) and +1.25 ms (21 KB).** That is
  −12.2 % and −16.2 % req/s at c=64.
- **Filtered path, 512-token stream on the OpenAI face: −37 % req/s at c=64, +8.7 ms CPU per
  request, about 17 µs per frame.** Re-encoding is not the cost. An answer with no placeholder
  at all, where no frame is re-encoded, costs exactly the same (−37.9 %). The cost is the
  restore pass that every frame goes through.
- **Two clear fixes, both measured from scratch copies (the repo is untouched):**
  - **Stream:** a fast path in `Restore::feed` for a chunk without an opening bracket, plus
    `_frame` recorded once instead of per frame. This gets back **+19.6 % req/s** at c=64 (3 of
    3 rounds) and cuts the filter's stream cost from −39 % to −26 %.
  - **Not k118's, found on the way:** `RawBody::with_top_level`, the ADR 0023 byte relay on
    every OpenAI chat and embeddings request since k104, matches a string one character at a
    time. Swapping in the unrolled string pattern that the same file already uses for
    `string_values` gives **3.1× req/s at 209 KB and +33 % at 21 KB** (c=64), and +18 % at 21 KB
    at c=16. The scratch copy passed every test file that covers RawBody or the filter.

## Setup

| | |
|---|---|
| Host | shared box, Linux 7.0.14, 8 CPUs, other users' work resident (load average 1.4–4.6 during the runs) |
| Perl | system perl 5.40.1, Mojolicious 9.49 |
| Upstream | `bench/fakellm --port 18080 --host 127.0.0.1 --ttft-ms 20 --tokens-per-second 1000 --tokens 64`, started fresh for every item; for phase C and F, a scratch build that emits a placeholder (below) |
| Proxy | `perl -Ilib bin/skeid serve --listen 127.0.0.1:18090 --config <cfg>`, **one process**, stdout/stderr to `/dev/null` |
| Client | `bench/llmbench`, and for embeddings and custom bodies a scratch build `llmbench2` (below); `--warmup 5` (default) |
| Revs | baseline `1f1e847` (HEAD, `git archive HEAD lib bin` in scratch); working tree = HEAD + uncommitted k118 (`git diff HEAD -- lib bin` + untracked `lib/` files, sha256 prefix `16013d4965963953`, the same before the first run and after the last) |

Everything ran under `nice -n 19 ionice -c3`, one run at a time (but see *Run log* for one
overlap and the data it cost). The scratch directory was
`/tmp/claude-1001/-home-frank-langertha-skeid/e010b437-50ee-463a-96bd-09b7e33f1be3/scratchpad/k118`
(`$S` below).

### Configs

`$S/cfg-plain.yaml` is `bench/skeid.bench.yaml` with only `usage_store.path` moved to
`$S/usage/` (jsonlog, `mode: dir`). That directory was deleted after every item.
`$S/cfg-fcfg.yaml` adds:

```yaml
filter:
  url: http://127.0.0.1:9/filter
  when: [cloud]
```

`bench-1` has no tags, so the filter never applies to it. The URL is a closed port, and no
request failed, so it was never asked.

### Variants

| variant | tree | command |
|---|---|---|
| base | `1f1e847` | `cd $S/base && perl -Ilib bin/skeid serve --listen 127.0.0.1:18090 --config $S/cfg-plain.yaml` |
| plain | working tree | `perl -Ilib bin/skeid serve --listen 127.0.0.1:18090 --config $S/cfg-plain.yaml` |
| fcfg | working tree | same, `--config $S/cfg-fcfg.yaml` |
| filt | working tree | `perl -Ilib bin/skeid serve --class Bench::Skeid::Filter -I $S/lib --listen 127.0.0.1:18090 --config $S/cfg-plain.yaml` |
| sfilt | working tree copy + stream fast path (scratch only) | as filt, from `$S/sfix` |
| plainfix | working tree copy + RawBody regex (scratch only) | as plain, from `$S/fix` |

`Bench::Skeid::Filter` is about the cheapest real filter there is. It replaces the first text
that names a person, with a one-entry map:

```perl
package Bench::Skeid::Filter;
use Moo;
use Mojo::Promise;
use namespace::clean;
extends 'Langertha::Skeid';

my $WORD = 'Max Mustermann';
my $PH   = "\x{27E6}PERSON_1\x{27E7}";

sub filter_request_p {
  my ($self, $ctx) = @_;
  for my $t (@{$ctx->{texts}}) {
    my $at = index($t->{text}, $WORD);
    next if $at < 0;
    (my $out = $t->{text}) =~ s/\Q$WORD\E/$PH/g;
    return Mojo::Promise->resolve({
      decision => 'replace',
      texts    => [ { id => $t->{id}, text => $out } ],
      map      => [ { id => $t->{id}, text => $WORD, start => $at, end => $at + length($WORD), placeholder => $PH } ],
      usage    => { pii_found => 1 },
    });
  }
  return Mojo::Promise->resolve({ decision => 'pass' });
}

1;
```

Correctness was checked once per variant before the runs. With filt, a placeholder in the
answer comes back as `Max Mustermann` in both JSON and SSE. The usage event carries
`pii_found: 1` and `filter_restored` (2 for the JSON answer, 16 for the 512-token stream). No
variant logged the `Nothing has been rendered` trace that the 2026-11-25 dispatch-hooks report
found: `$ask_filter` calls `render_later` itself.

### Scratch instruments (not in `bench/`)

- **`llmbench2`** is `bench/llmbench.c` plus `--body-file FILE` (sends the file as the body;
  `--stream` then only switches the TTFT detection) and `--marker STR` (a non-stream response
  counts as content once it contains STR, so embeddings use `--marker '"embedding"'`).
  Everything else, timing included, is unchanged.
- **`fakellm-ph`** is `bench/fakellm.c` with the 28th of its 32 tokens, `known `, replaced by
  `⟦PERSON_1⟧ `. A 64-token JSON answer carries 2 placeholders, and a 512-token stream carries
  16 frames whose text the filter restores.
- **Bodies** (`$S/bodies`) are generated prose with occasional `\n`, `"…"` and `Müller`, and
  `Please write a short note to Max Mustermann.` in the first message:

| body | bytes | texts | shape |
|---|---|---|---|
| default (`llmbench`) | 105 | 1 | `"content":"benchmark"`, 64 tokens |
| `small.json` | 192 | 1 | one system message, 64 tokens |
| `m20.json` | 20 987 | 20 | 20 messages of ~1 KB, 64 tokens |
| `m200.json` | 208 958 | 200 | 200 messages of ~1 KB, 64 tokens |
| `s512.json` | 190 | 1 | as small, `stream: true`, `max_tokens: 512` |
| `emb.json` | 539 | 4 | `input`: 4 strings of ~120 B |

### Driver and cells

`$S/drive.sh PHASE ROUND ITEM...`: for each item it starts fakellm fresh, then measures either
fakellm directly (`direct`) or one variant started fresh, every cell at c=16 and then c=64. The
variant order rotates (phase A) or alternates (others) by round. Requests are 40×c per run,
except s512 at 10×c.

```bash
llmbench  --port P --requests $((40*c)) --concurrency c --tokens 64 [--stream] --json        # json / stream
llmbench2 --port P --requests $((40*c)) --concurrency c --path /v1/embeddings \
          --body-file emb.json --marker '"embedding"' --json                                 # emb
llmbench2 --port P --requests $((40*c)) --concurrency c --body-file {small,m20,m200}.json --json
llmbench2 --port P --requests $((10*c)) --concurrency c --body-file s512.json --stream --json
```

The discard rule is the same as last time: a run below 60 % of its variant's median for that
cell is a box disturbance. No run in any phase met it, and **no request failed in any phase**
(A 345 600, B 115 200, C 129 600, D 7 200, E 57 600, F 9 600 requests).

## Instrument check

Direct streaming TTFT p50 was 20.14–20.20 ms (setting: 20). Direct JSON total p50 was 83.2 ms
(20 + 63/1000 s). A direct 512-token stream took 531.2 ms total (20 + 511 ms). Direct req/s was
191.8 at c=16 and 766 at c=64, which is c / 83 ms. Embeddings direct: TTFT 20.2 ms, 786 / 3131
req/s. Body size did not move the fakellm baseline (m200: 191.5 / 765.0 req/s).

## Results

Each cell is the median over the rounds (n), with the range in brackets. TTFT p50/p95/p99 are
medians of the per-run percentiles. Paired deltas are the median of the per-round deltas, with
the range and "slower" = rounds in which the first variant had fewer req/s. Per-request CPU is
read at c=64, where the single process is saturated: Δ(1 / req/s).

### Q1 — default path (phase A, 9 rounds, rotated `base plain fcfg` / `plain fcfg base` / `fcfg base plain`)

| c=16 | direct | base `1f1e847` | plain | fcfg |
|---|---|---|---|---|
| json req/s | 191.8 | 119.5 [118.5–120.4] | 118.9 [116.9–119.7] | 118.8 [117.5–119.3] |
| json TTFT p50/p95/p99 ms | 83.2 / 83.7 / 83.8 | 131.8 / 133.8 / 135.7 | 132.7 / 135.0 / 137.1 | 132.7 / 135.8 / 139.5 |
| stream req/s | 192.1 | 114.5 [113.4–115.0] | 113.0 [112.4–114.5] | 113.1 [111.4–113.5] |
| stream TTFT p50/p95/p99 ms | 20.2 / 20.3 / 20.4 | 60.9 / 63.8 / 65.1 | 61.8 / 65.6 / 69.4 | 61.7 / 65.4 / 68.2 |
| emb req/s | 786.5 | 228.0 [224.2–233.6] | 225.0 [220.4–230.1] | 221.9 [219.6–226.0] |
| emb TTFT p50/p95/p99 ms | 20.2 / 20.6 / 20.7 | 68.4 / 69.9 / 72.2 | 69.3 / 71.4 / 76.1 | 69.8 / 72.7 / 75.3 |

| c=64 | direct | base `1f1e847` | plain | fcfg |
|---|---|---|---|---|
| json req/s | 766.5 | 222.4 [219.6–224.3] | 219.5 [215.8–225.8] | 219.8 [213.6–223.3] |
| json TTFT p50/p95/p99 ms | 83.2 / 83.9 / 85.0 | 264.8 / 282.9 / 291.6 | 269.1 / 287.2 / 295.0 | 270.6 / 285.6 / 291.7 |
| stream req/s | 767.5 | 186.9 [183.5–189.5] | 185.4 [182.0–187.9] | 183.1 [174.4–187.3] |
| stream TTFT p50/p95/p99 ms | 20.1 / 20.3 / 21.2 | 200.4 / 212.4 / 232.1 | 202.6 / 217.5 / 223.1 | 206.1 / 217.6 / 251.9 |
| emb req/s | 3130.9 | 282.3 [278.6–285.5] | 280.5 [274.7–288.0] | 277.0 [271.0–282.6] |
| emb TTFT p50/p95/p99 ms | 20.2 / 20.8 / 21.6 | 210.3 / 222.4 / 231.2 | 212.3 / 222.3 / 231.5 | 215.3 / 227.0 / 235.4 |

| paired | plain vs base | fcfg vs plain |
|---|---|---|
| json c16 | −0.9 % [−1.6..+1.0], 8/9; TTFT p50 +0.57 ms | +0.2 % [−1.8..+0.6], 4/9; +0.12 ms |
| stream c16 | −1.2 % [−2.0..+0.5], 7/9; +1.10 ms | +0.2 % [−1.4..+0.5], 4/9; +0.22 ms |
| emb c16 | −1.1 % [−3.7..+1.9], 6/9; +0.92 ms | −1.9 % [−3.8..+2.1], 7/9; +1.09 ms |
| json c64 | −1.5 % [−2.7..+2.6], 7/9; +5.10 ms | −0.1 % [−3.4..+3.5], 5/9; +0.96 ms |
| stream c64 | −0.9 % [−2.9..+1.4], 5/9; +2.48 ms | −0.3 % [−6.5..+1.3], 5/9; +0.40 ms |
| emb c64 | −0.8 % [−3.2..+2.0], 6/9; +1.02 ms | −0.9 % [−5.9..+0.5], 7/9; +2.55 ms |
| **pooled, 54 pairs** | **median −1.0 %, 39 slower, sign test p = 0.0015** | median −0.3 %, 32 slower, p = 0.22 |

Reading: no single cell clears the noise. The same variant's req/s spans 2–3 % at c=16 and
3–6 % at c=64 across rounds. Pooled, the tree leans about 1 % slower than HEAD, which is more
than chance. (The six cells of one round share a server process, so the 54 pairs are not
fully independent and the p-value is optimistic.) In code, the default path adds one
`filters_requests` call per handler, the `$ask_filter` closure built in every
`_begin_route_async`, and a few per-line `$rewrite` tests. None of these is anywhere near
80 µs per request. I am reporting the lean, not explaining it. Finding where 1 % goes needs a
NYTProf diff, which this host cannot run today.

The fcfg stream c64 p99 range reaches 435 ms in one run (the median is 252 ms). It is a single
tail, and plain and base show the same shape in other rounds (base 273 ms, plain 251 ms).

### Q2 — extraction on large bodies (phase B, 6 rounds, alternating, `llmbench2 --body-file`)

| | direct | plain | fcfg | fcfg vs plain |
|---|---|---|---|---|
| m20 c16 req/s | 191.8 | 98.0 [96.9–98.2] | 95.7 [95.5–97.1] | −1.8 % [−2.7..−1.1], 6/6 |
| m20 c16 TTFT p50/p95/p99 ms | 83.3 | 161.3 / 164.1 / 165.7 | 164.8 / 167.4 / 171.5 | p50 +3.4 ms |
| m200 c16 req/s | 191.5 | 37.4 [37.3–45.9] | 35.2 [34.9–42.7] | −5.9 % [−8.1..+14.2], 5/6 |
| m200 c16 TTFT p50/p95/p99 ms | 83.4 | 423.6 / 443.2 / 464.0 | 451.2 / 459.9 / 480.2 | p50 +28.3 ms |
| m20 c64 req/s | 766.3 | 156.2 [154.8–158.1] | 150.9 [149.4–152.2] | **−3.4 %** [−5.2..−2.1], 6/6 |
| m20 c64 TTFT p50/p95/p99 ms | 83.2 | 393.0 / 407.0 / 431.8 | 406.4 / 423.1 / 444.1 | p50 +13.8 ms |
| m200 c64 req/s | 765.0 | 43.3 [42.9–45.6] | 40.1 [39.3–42.5] | **−7.1 %** [−12.3..−1.8], 6/6 |
| m200 c64 TTFT p50/p95/p99 ms | 83.3 | 1449 / 1506 / 1547 | 1569 / 1631 / 1656 | p50 +114 ms |

Per request at c=64: **+0.23 ms at 21 KB, +1.84 ms at 209 KB**, about 9 µs per extracted text.
In-process (`$S/micro.pl`), `Filter->extract` on the decoded body takes 6.8 µs (1 text),
128 µs (20) and 1 297 µs (200). That is 3–4× the cost of decoding the same JSON (38 / 381 µs for
m20 / m200). This is what every request pays once any filter is configured, on every node.
Note the `ADR 0035` line "a request without a filter pays one boolean" is about requests with
no filter *configured*. With a filter configured, every request pays the extraction, including
those that go to nodes outside `when`. Doing the extraction lazily, on the first node that
`filter_applies` to, would make the fcfg case free. Whether that is worth the restructure is
the maintainer's call; the cost is above.

### Q3 — the filtered path (phase C, 6 rounds, `fakellm-ph`, plain vs filt)

| | direct | plain | filt | filt vs plain |
|---|---|---|---|---|
| small c16 req/s | 191.8 | 119.6 [118.1–120.9] | 109.3 [108.6–111.0] | −8.3 % [−9.5..−7.0], 6/6 |
| small c16 TTFT p50/p95/p99 ms | 83.3 | 131.2 / 134.8 / 139.1 | 143.4 / 148.9 / 151.3 | p50 +12.6 ms |
| m20 c16 req/s | 191.8 | 97.3 [95.6–97.6] | 86.3 [85.5–87.3] | −11.3 % [−12.2..−9.2], 6/6 |
| m20 c16 TTFT p50/p95/p99 ms | 83.3 | 161.9 / 167.0 / 176.9 | 182.0 / 187.7 / 196.3 | p50 +20.0 ms |
| s512 c16 req/s | 30.1 | 27.2 [27.1–27.2] | 26.7 [26.5–26.8] | −1.7 % [−2.6..−1.5], 6/6 |
| s512 c16 TTFT p50/p95/p99 ms | 20.2 / 20.3 / 20.4 | 61.9 / 65.7 / 66.5 | 69.7 / 75.4 / 79.9 | p50 +8.3 ms |
| s512 c16 total p50 ms | 531.2 | 589.0 | 598.5 | |
| small c64 req/s | 766.6 | 221.8 [218.0–224.2] | 194.2 [192.2–196.3] | **−12.2 %** [−13.2..−11.6], 6/6 |
| small c64 TTFT p50/p95/p99 ms | 83.2 | 265.6 / 284.2 / 290.9 | 300.2 / 325.1 / 335.5 | p50 +34.0 ms |
| m20 c64 req/s | 766.2 | 155.2 [153.4–158.8] | 129.9 [128.9–130.9] | **−16.2 %** [−18.3..−15.7], 6/6 |
| m20 c64 TTFT p50/p95/p99 ms | 83.2 | 394.3 / 417.3 / 439.2 | 467.5 / 495.1 / 504.7 | p50 +73.9 ms |
| s512 c64 req/s | 120.3 | 68.7 [67.6–71.6] | 43.0 [41.9–44.0] | **−37.4 %** [−40.4..−35.5], 6/6 |
| s512 c64 TTFT p50/p95/p99 ms | 20.2 / 21.1 / 21.5 | 204.7 / 223.0 / 230.6 | 274.1 / 305.7 / 324.4 | p50 +69.8 ms |
| s512 c64 total p50 ms | 531.2 | 903.7 | 1477.8 | |

Per request at c=64: **+0.64 ms (small), +1.25 ms (21 KB), +8.7 ms (512-token stream, ≈17 µs
for each of its 514 frames)**. At c=16 the stream barely shows in req/s because the process is
not saturated there. It shows as +8 ms TTFT p50.

**Phase D: the same stream with no placeholder in the answer** (stock fakellm, 3 rounds). The
filter still replaces the request, so `restore` and `$rewrite` are active, but no frame
changes and none is re-encoded:

| s512 | plain | filt | filt vs plain |
|---|---|---|---|
| c16 req/s | 27.1 [27.0–27.1] | 26.7 [26.7–26.8] | −1.5 %, 3/3; TTFT p50 +8.4 ms |
| c64 req/s | 69.7 [69.6–72.6] | 43.3 [43.3–43.3] | **−37.9 %** [−40.4..−37.8], 3/3; TTFT p50 +73.2 ms |
| c64 TTFT p50/p95/p99 ms | 204.2 / 225.2 / 229.0 | 277.4 / 355.2 / 406.8 | |

Identical to phase C. **Re-encoding the 16 changed frames costs nothing measurable. The cost
is the per-frame restore pass on every frame.**

#### Where the filtered cost goes (in-process, `$S/micro3.pl` – `micro5.pl`, `perl -Ilib`, niced)

Stream, per frame (a fakellm frame, `content` "measured "):

| | µs |
|---|---|
| `decode_json` of the frame (paid with and without a filter) | 1.6 |
| decode + `Restore->frames` + the `"$line\n"` relay | 10.3 |
| of that: `_frame({...})` rebuilt for every frame (Moo `rw` set + hash slice) | ≈1.6 |
| of that: `feed` → `restore_text` regex on a chunk without any bracket | 3.0 |

That accounts for about half of the 17 µs measured end to end. The rest is the rewrite relay
in `_proxy_openai_stream` (line splitting into `$translated` instead of pushing the read
chunk) plus allocator and cache effects that a microbenchmark does not see.

Non-stream, per request: `extract` 8.7 µs; `check_result` + `set_texts` + `substitute` 87 µs
(small) / 450 µs (21 KB, mostly `string_values` scanning the body: 276 µs); `restore` object +
`_table` (a `qr//` compiled per request) 12 µs; `restore_bytes` on the 600-byte answer 124 µs,
of which `string_values(answer)` is 68 µs. That is ≈ 250 µs of the 640 µs. The remainder is the
promise round trip (one more tick, as in k111), `_filter_context` (`_node_by_id`, header copy)
and the per-request closures.

## Fixes with evidence (scratch copies only; nothing in the repo was changed)

### 1. Stream restore fast path (k118) — +19.6 % req/s on a filtered 512-token stream

Two changes in a copy of `lib/Langertha/Skeid/Filter/Restore.pm` (`$S/sfix`):

```perl
# _build__table: remember whether every exact placeholder starts with an opening bracket
    bracketed => (!grep { !/\A[\Q$OPEN\E]/ } @exact) ? 1 : 0,

# feed: nothing held, no opening bracket in the chunk -> nothing to restore or hold
  return $chunk if !exists($self->_held->{$channel}) && defined($chunk)
    && index($chunk, '[') < 0 && index($chunk, "\x{27E6}") < 0 && $self->_table->{bracketed};

# frames: the stream's id/object/created/model once, not per frame
  $self->_frame({ ... }) unless $self->_frame;
```

The `bracketed` guard keeps a filter whose placeholders have no bracket on the regex path. The
lenient forms (`$CANDIDATE`) all need a bracket. `t/104-filter-seam.t` and
`t/105-filter-restore.t` pass against the copy (21 tests). `frames` drops from 10.3 to 5.6 µs
per frame (decode included).

Phase F, 3 rounds, `fakellm-ph` (16 placeholder frames per answer), orders
`plain filt sfilt` / `sfilt plain filt` / `filt sfilt plain`:

| s512 | plain | filt | sfilt | sfilt vs filt |
|---|---|---|---|---|
| c16 req/s | 27.1 | 26.7 | 26.8 | +0.4 % [+0.0..+0.4] |
| c64 req/s | 70.0 [69.3–71.5] | 42.9 [42.6–43.5] | **51.8** [51.3–51.9] | **+19.6 %** [+19.3..+21.6], 3/3 |
| c64 TTFT p50/p95/p99 ms | 205.2 / 220.9 / 225.5 | 275.5 / 332.6 / 334.7 | 252.0 / 261.9 / 265.5 | p50 −22.4 ms |
| c64 total p50 ms | 914.0 | 1481.4 | 1234.9 | |

The filter's stream cost goes from −39 % to −26 % (≈17 → ≈10 µs per frame). The rest is the
rewrite relay's per-line work. A further lever there would be to skip `frames` for a frame
whose raw payload has no `⟦` bytes and no `[` after `"content":"`, while nothing is held. I
did not measure it.

One filt run in phase F had a TTFT p99 of 1 458 ms (the other two: 293 and 335 ms). It is a
single tail, and the medians above absorb it.

### 2. `RawBody::with_top_level` string regex (pre-existing since k104 `98541df`, not k118) — 3.1× at 209 KB

`_top_level_spans` and `_skip_value` (`lib/Langertha/Skeid/Protocol/RawBody.pm` lines 75, 125,
130) match a JSON string as `"(?:[^"\\]|\\.)*"`, an alternation per character. The new
`string_values` in the same file uses the unrolled `"[^"\\]*+(?:\\.[^"\\]*+)*+"`. Swapping
the three patterns in a copy (`$S/fix`):

| `with_top_level` in-process | tree | unrolled |
|---|---|---|
| small (192 B) | 30.9 µs | 21.4 µs |
| m20 (21 KB) | 1 711 µs | 140 µs |
| m200 (209 KB) | 16 363 µs | 1 255 µs |

Seventeen test files that touch RawBody, the byte relay or the filter pass against the copy
(`prove -I$S/fix/lib -It/lib` over `t/00-load.t t/31 t/32 t/33 t/39 (both) t/40 t/52 t/68
t/69 t/70 t/72 t/73 t/88 t/90 t/104 t/105`, 1 762 tests; `$INC` confirmed the copy was loaded).
The full suite was not run against it.

Phase E, 3 rounds, stock fakellm, plain vs plainfix:

| | plain | plainfix | plainfix vs plain |
|---|---|---|---|
| m20 c16 req/s | 97.8 [97.2–97.9] | 114.6 [114.4–115.4] | +17.9 %, 3/3; TTFT p50 −23.7 ms |
| m200 c16 req/s | 37.4 [37.4–45.9] | 91.3 [90.8–91.6] | +144 %, 3/3; TTFT p50 −252 ms |
| m20 c64 req/s | 156.8 [156.2–157.1] | 208.5 [208.1–211.4] | **+33.0 %**, 3/3; TTFT p50 −101 ms |
| m200 c64 req/s | 45.6 [43.5–45.6] | 140.8 [140.5–141.3] | **+209 %**, 3/3; TTFT p50 −956 ms |

Every OpenAI chat and embeddings request pays this, filter or not. A 20-message conversation
spends 1.7 ms of its ~6.4 ms per-request CPU on it. It is not k118's regression, so it is
reported here with its numbers and left for its own card. The filter's `substitute` path also
calls `with_top_level` (on the substituted bytes), so a filtered large request gains from it
too.

## Side finding (correctness, not perf)

A re-encoded stream frame on the OpenAI face carries keys the node never sent:

```
upstream: {"id":"chatcmpl-fake",...,"choices":[{"index":0,"delta":{"content":"⟦PERSON_1⟧ "},"finish_reason":null}]}
client:   {"choices":[{"delta":{"content":"Max Mustermann ","reasoning":null,"reasoning_content":null},...}],...}
```

The TTFT check at `Proxy.pm` line 3188, `grep { defined($_) && length($_) } $delta->{content},
$delta->{reasoning_content}, $delta->{reasoning}, ...`, autovivifies the two missing keys
(`grep` aliases its list; `perl -e` confirms). At HEAD this is invisible because the decoded
frame is never re-encoded. With k118 every frame the filter changes now carries
`reasoning: null` and `reasoning_content: null`. This goes beyond ADR 0035's "a frame whose
text changed … is re-encoded", which says nothing about new keys. The fix is to read the
fields as values instead of aliasing them: `grep { defined($_) && length($_) } map {
$delta->{$_} } qw(content reasoning_content reasoning)` leaves `%$delta` as it was (checked
with `perl -e`).

## Run log and what was discarded

- **One overlap, caught and discarded.** The tool harness moved the 2–3-round phase A call
  into the background after 180 s. Before I noticed, I had issued three more driver calls
  (rounds 4–9), which ran against the same ports while round 3 was in progress. They then
  failed. Every phase A row from round 3 on was dropped (`$S/out/A.contaminated.jsonl` keeps
  them). Rounds 3–9 were measured again afterwards, one call at a time. From then on the driver
  takes a `flock` and refuses to start when 18080 or 18090 already answers, and every call was
  sized under the 180 s limit. One later phase D call still ran past its limit. Nothing else
  was started until it had exited, and `pgrep` confirmed that no benchmark process was left.
  Rounds 1–2 finished before the overlap and were kept.
- Load average was 1.4–4.6, varying with other users' work. No run met the discard rule.
- After the last run: no `fakellm`, `llmbench` or `skeid serve` process left, and
  `$S/usage` deleted.

## Not measured

- A real filter over HTTP (`Filter::HTTP`): its round trip and the slot it holds while it is out.
  Everything here is an in-process filter that resolves at once, so the cost is Skeid's alone.
- The Anthropic and Ollama faces on the filtered path: there the restore runs before the
  translator, and no `$rewrite` relay applies.
- Tool-call arguments (inner JSON substitution and restore), `local` and `refuse` decisions,
  multiple placeholders per text, and a map larger than one entry.
- `serve --workers N`, TLS, cold start, a real model, database usage stores.
- A profile. NYTProf is not installed on this host, so the 1 % default-path lean and the
  non-stream remainder (~390 µs of the 640 µs) are unattributed.

## Reproduction

The scripts are in the scratchpad (`$S/drive.sh`, `$S/analyze.py`, `$S/micro*.pl`,
`$S/bin/llmbench2.c`, `$S/bin/fakellm-ph.c`, `$S/lib/Bench/Skeid/Filter.pm`), which a cleanup
can remove. The patches and the class are quoted above in full.

```bash
nice -n 19 ionice -c3 $S/drive.sh A 1 direct base plain fcfg   # Q1/Q2 small
nice -n 19 ionice -c3 $S/drive.sh B 1 direct plain fcfg         # Q2 large bodies
nice -n 19 ionice -c3 $S/drive.sh C 1 direct plain filt         # Q3, fakellm-ph
nice -n 19 ionice -c3 $S/drive.sh D 1 direct plain filt         # Q3 stream, no placeholders
nice -n 19 ionice -c3 $S/drive.sh F 1 direct plain filt sfilt   # stream fix
nice -n 19 ionice -c3 $S/drive.sh E 1 direct plain plainfix     # RawBody fix
python3 $S/analyze.py $S/out/A.jsonl base,plain,fcfg plain:base,fcfg:plain json,stream,emb
```
