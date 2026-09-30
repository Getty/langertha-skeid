# Benchmark 2026-09-30 — EV, Cpanel::JSON::XS and a packed binary

Answers karr k79, the maintainer's question from 2026-09-29: can Skeid ship as one static
binary, and is that faster? The Docker image runs `Mojo::Reactor::Poll` (no EV) with
Cpanel::JSON::XS 4.53, while the dev box, where every earlier report in `docs/bench/` was taken,
has both EV and Cpanel::JSON::XS. So this report also answers whether dev-box numbers describe
the image.

Short answer:

- **Cpanel::JSON::XS matters.** Without it a single process streams **43 % fewer requests**
  per second at c=16 and the streaming TTFT p99 doubles. The image has it only because
  JSON::MaybeXS pulls it in as a dynamic prerequisite; `cpanfile` now names it.
- **EV does not buy a consistent gain.** Poll is *faster* for JSON at c=16 (141.5 vs 119.7
  req/s, median of 5 rounds), EV has the better streaming tail at c=64 (p99 247–300 vs
  356–435 ms, 3 rounds), and 256 slow streams are equal. That is not enough evidence to change
  the image, which today runs Poll.
- **A packed binary does not change the request path.** Same numbers within run-to-run spread.
  It starts slower: +0.2 s when its cache is warm, +3.7 s cold. It is also not static: it
  unpacks 80 MB and still needs the host's glibc, libssl, libcrypto and libz.

## Setup

| | |
|---|---|
| Host | shared dev box, Linux 6.12, 4 CPUs, 8 GB, other agents' tests and builds resident |
| Perl | system perl 5.40.1; Mojolicious 9.49, EV 4.37, Cpanel::JSON::XS 4.52, JSON::PP 4.16, JSON::MaybeXS 1.004008, PAR::Packer 1.064 |
| Upstream | `bench/fakellm --port 18080 --ttft-ms 20 --tokens-per-second 1000 --tokens 64` (via `run-bench.sh`) |
| Proxy | `perl -Ilib bin/skeid serve --listen 127.0.0.1:18090 --config bench/skeid.bench.yaml`, **one process** |
| Client | `bench/llmbench`, `--warmup 5` |
| Rev | `2e10552` (k78-dbi-write-behind), clean tree for every run |

Every run is `run-bench.sh`, so every Skeid figure has a baseline from the same client straight
at fakellm, taken seconds earlier. The whole script ran under `nice -n 19 ionice -c3`, so the
Skeid process ran niced too, the same way for every variant. Only one run was active at a time.

### The four variants

The variants differ only in the environment the Skeid process inherits:

| variant | environment | what it is |
|---|---|---|
| EV+XS | nothing | dev box default |
| Poll+XS | `MOJO_REACTOR=Mojo::Reactor::Poll` | **what the image runs today** |
| EV+PP | `PERL5LIB=/tmp/k79-nojsonxs:$PERL5LIB` | no JSON XS module |
| Poll+PP | both | neither |

`/tmp/k79-nojsonxs` holds two stub files, `Cpanel/JSON/XS.pm` and `JSON/XS.pm`, whose only line
is `die "... blocked for k79 bench\n";`. They sit ahead of `site_perl` in `@INC`, so
`require Cpanel::JSON::XS` fails. That is the same thing that happens when the module is not
installed. JSON::MaybeXS does not read `PERL_JSON_BACKEND` (JSON.pm does), so no environment
variable can do this. Stubs block both JSON backends Skeid touches:

- `JSON::MaybeXS`, used in `Proxy.pm`, `Protocol.pm`, `JsonLog.pm` and others, falls back to
  `JSON::PP`.
- `Mojo::JSON`, which renders `json =>` and serves `->json`, tries Cpanel::JSON::XS 4.20+ and
  falls back to its own pure-Perl code.

Checked once on a live server per variant. `/proc/PID/maps` of the running `bin/skeid serve`
showed `EV/EV.so` 5/0/5/0 and `Cpanel/JSON/XS/XS.so` 5/5/0/0 mappings for
EV+XS/Poll+XS/EV+PP/Poll+PP. In-process, with the stubs, `JSON::MaybeXS::JSON()` returns
`JSON::PP` and `Mojo::JSON::JSON_XS` is false.

### Driver

This loop is `/tmp/k79/drive.sh ROUNDS REQUESTS CONCURRENCY [rev]`, reproduced here because
`/tmp` does not survive:

```bash
cd bench
NX=/tmp/k79-nojsonxs:$PERL5LIB
for v in "EV+XS|K79=1" "Poll+XS|MOJO_REACTOR=Mojo::Reactor::Poll" \
         "EV+PP|PERL5LIB=$NX" "Poll+PP|MOJO_REACTOR=Mojo::Reactor::Poll PERL5LIB=$NX"; do
  settle   # wait until 18080/18090 are free (see "Harness findings")
  env ${v#*|} nice -n 19 ionice -c3 ./run-bench.sh --requests 320 --concurrency 16 \
    --label "Skeid ${v%%|*}"
done
```

The c=16 set is 3 rounds in this order plus 2 rounds in reverse order (`rev`). Reversing the
order rules out a position effect: a variant does not look better because it always ran second.

## Results

### Concurrency 16: the comparison that settles JSON

`./run-bench.sh --requests 320 --concurrency 16`, 5 rounds per variant, 320 requests each.
Each figure is the median over the 5 rounds, with the range in brackets. Baseline straight at
fakellm in the same runs: json 186–191 req/s, TTFT p50 83.2–84.0 ms; stream 188–192 req/s,
TTFT p50 20.1–20.3 ms.

| c=16 | EV+XS | Poll+XS (image) | EV+PP | Poll+PP |
|---|---|---|---|---|
| json req/s | 119.7 [107.5–122.4] | **141.5** [131.8–146.6] | 105.0 [103.8–118.1] | 135.7 [129.7–138.4] |
| json TTFT p50 ms | 128.3 | **103.5** | 138.4 | 108.3 |
| json TTFT p99 ms | 156.6 | 159.8 | 185.4 | 157.7 |
| stream req/s | **116.9** [103.5–122.6] | 113.4 [100.9–125.8] | 67.2 [54.1–77.3] | 75.8 [41.0–76.4] |
| stream TTFT p50 ms | 54.6 | 54.8 | 82.2 | 97.9 |
| stream TTFT p99 ms | 99.3 | 99.3 | 209.2 | 224.4 |
| stream total p50 ms | 132.4 | 128.0 | 230.3 | 208.8 |

Across all 40 Skeid runs (5 rounds × 4 variants × json/stream), 12,798 of 12,800 requests
succeeded. The two failures (Poll+PP stream, round 3) are harness finding 2 below.

### Concurrency 1: serial cost per request

`./run-bench.sh --requests 150 --concurrency 1`, one round. Figures are p50, with the delta
over the baseline in the same run in brackets.

| c=1 | EV+XS | Poll+XS | EV+PP | Poll+PP |
|---|---|---|---|---|
| json TTFT p50 ms | 87.70 (+4.5) | 88.41 (+5.2) | 93.19 (+10.0) | 95.02 (+11.5) |
| stream TTFT p50 ms | 24.24 (+4.0) | 24.63 (+4.4) | 25.23 (+4.8) | 25.36 (+4.9) |
| stream total p50 ms | 88.47 (+5.3) | 88.75 (+5.6) | 90.19 (+6.8) | 90.18 (+6.7) |

The reactor makes no difference with one request in flight. Pure-Perl JSON adds about 5 ms to a
JSON request and about 1.4 ms to a 64-token stream.

### Concurrency 64: where EV looks better

`./run-bench.sh --requests 640 --concurrency 64`, EV+XS and Poll+XS only. Rounds 1 and 2 ran EV
first, round 3 ran Poll first. Baseline: json 737–759 req/s, stream 697–753 req/s.

| c=64 | EV+XS r1 / r2 / r3 | Poll+XS r1 / r2 / r3 |
|---|---|---|
| json req/s | 257.3 / 204.3 / 214.2 | 245.4 / **308.1** / 277.8 |
| json TTFT p50 ms | 218 / 271 / 265 | 224 / 177 / 209 |
| stream req/s | 207.2 / 191.4 / 201.7¹ | 164.0 / 205.9 / 182.0 |
| stream TTFT p50 ms | 174 / 199 / 241 | 284 / 198 / 245 |
| stream TTFT p99 ms | **247 / 259 / 300** | 435 / 356 / 382 |

¹ 588 ok / 52 failed. Every failure was a 502 "Premature connection close" from the upstream
(see "Harness findings"), not a Skeid fault.

Round 4 was aborted. The box went into box-wide memory thrash (PSI full 92 %) and the fakellm
baseline itself collapsed to 4.3 req/s, so none of round 4 is usable.

### 256 slow streams: many open file descriptors, little work each

This is the case EV is supposed to win: 256 connections open at once, each mostly idle. Command:
`./run-bench.sh --requests 1024 --concurrency 256 --rate 50`, where 64 tokens at 50 tok/s makes
a request last about 1.3 s. Baseline: json and stream 196–198 req/s.

| c=256, 50 tok/s | EV+XS r1 / r2 / r3 | Poll+XS r1 / r3 |
|---|---|---|
| json req/s | 128.2 / 126.3 / 126.1 | 139.2 / 135.3 |
| json TTFT p50 ms | 1909 / 1832 / 1973 | 1581 / 1720 |
| stream req/s | 124.9 / 116.2 / 126.6 | — / 124.6 |
| stream TTFT p50 / p99 ms | 490/602 · 606/850 · 564/646 | — · 560/634 |
| stream total p50 ms | 2037 / 2210 / 2014 | — / 2052 |

Poll r2 and the Poll r1 stream half were discarded because memory pressure from other work
collapsed their own fakellm baselines (TTFT p95 of 54 s and 8 s against fakellm directly).

### Control: a minimal Mojolicious pass-through with no Skeid code

`/tmp/k79/minproxy.pl` is about 15 lines. `Mojolicious::Lite` takes the request, and a
non-blocking `$ua->start` forwards the body to fakellm and renders the answer, with no JSON
decode. Command: `./run-bench.sh --no-start --requests 320 --concurrency 16`, json only, 2 rounds.

| c=16 json | EV r1 / r2 | Poll r1 / r2 |
|---|---|---|
| req/s | 160.4 / 153.4 | 168.5 / 163.0 |
| TTFT p50 ms | 94.2 / 95.2 | 89.6 / 91.8 |

So Poll's JSON lead at c=16 is not something in Skeid. Mojolicious shows it too on this box, at
about a third of the size (+5 % against Skeid's +18 %).

### Packed binary (PAR::Packer)

The build that works:

```bash
PAR_VERBATIM=1 nice -n 19 ionice -c3 pp -I lib \
  -M 'Langertha::**' -M 'YAML::PP::**' -M 'Mojolicious::**' -M 'Mojo::**' \
  -M Cpanel::JSON::XS -M EV -o /tmp/k79/skeid-pp bin/skeid
```

It took 16 s and produced a 30 MB file. Getting there took three attempts, and each failure is a
maintenance cost a release would pay again:

1. **Without `PAR_VERBATIM=1` the binary does not start.** PAR's POD stripper does not know the
   `[@Author::GETTY]` POD commands (`=seealso`, `=attr`, …). It leaves `=seealso` behind and
   drops the `=cut` after it, so the module's trailing `1;` ends up inside POD. The result is
   `Langertha/Skeid/CapacityProbe.pm did not return a true value`.
2. **Static scanning misses runtime loads.** YAML::PP loads its schemas through `Module::Load`
   (`Can't locate YAML/PP/Schema/Core.pm`). Mojolicious loads plugins and reactors by name.
   Only whole-namespace `-M` wildcards fixed that.
3. **The wildcards drag in everything else.** Every DBD driver on the box ended up in the
   archive (Oracle, DB2, Sybase, ODBC, Firebird, …), and each one links its own client
   libraries.

**It is not a static binary.** `ldd` on the file shows only libc. At first start it unpacks
80 MB into `$PAR_TEMP`, including `libperl.so.5.40`, and the unpacked XS objects link the host's
`libssl.so.3`, `libcrypto.so.3` and `libz.so.1` (Net::SSLeay), plus `libpq.so.5` and more for
DBD::Pg. Target hosts need a compatible glibc and those libraries, the same as today, plus a
writable temp directory that can take 80 MB. On a tmpfs `/tmp` that is 80 MB of RAM.

It ran from `/tmp` with `PERL5LIB` unset, and nothing under `~/perl5` was mapped into the
process. It picked EV and Cpanel::JSON::XS, the same as plain perl on this box.

#### Startup

Measured by `/tmp/k79/startup.sh 10` under `nice -n 19 ionice -c3`: exec until the first `200`
from `/health` (curl polled every 10 ms), and wall time of the one-shot `skeid keyid bench-key`.
10 starts per variant, strictly one after another. "Cold" deletes the PAR cache before every
start.

| startup | plain `perl -Ilib bin/skeid` | packed, cache warm | packed, cache cold |
|---|---|---|---|
| serve → /health, median ms [min–max] | 867 [752–1163] | 1074 [968–1348] | 4521 [3582–5558] |
| `keyid`, median ms [min–max] | 696 [622–760] | 828 [720–896] | 3788 [3072–4178] |
| VmRSS once healthy | 77.6 MB | 89.0 MB | 89.5 MB |

The absolute values are inflated: the processes ran at nice 19 on a loaded box. Only the
differences mean anything.

#### Request path

2 rounds each, alternating: plain perl through `run-bench.sh`, then the packed binary started by
hand on 18090 (niced the same way) and measured with
`./run-bench.sh --no-start --requests 320 --concurrency 16`. Both variants ran EV+XS.

| c=16 | plain r1 / r2 | packed r1 / r2 |
|---|---|---|
| json req/s | 116.3 / 118.8 | 116.8 / 112.8 |
| json TTFT p50 ms | 132.6 / 130.5 | 131.7 / 138.9 |
| stream req/s | 107.0 / 115.6 | 107.6 / 107.3 |
| stream TTFT p50 / p99 ms | 65.1/95.2 · 57.6/73.9 | 62.8/87.7 · 61.2/96.7 |

The two are the same within the spread. This matches the expectation on the card, which is now
measured: packing changes distribution and startup, not the loop.

## What this says

**Cpanel::JSON::XS carries the streaming path.** The stream relay parses every `data:` frame to
count content and pick up the usage block. With JSON::PP that is 64 pure-Perl decodes per
request, and it shows: streaming throughput drops from 116.9 to 67.2 req/s (EV) and from 113.4
to 75.8 (Poll). TTFT p99 doubles from 99 to 209–224 ms, and the spread between rounds grows,
with one Poll+PP round at 41 req/s. The JSON path loses less (−12 % EV, −4 % Poll) because it
decodes one body. The image has the module today only because JSON::MaybeXS's `Makefile.PL`
adds it as a *dynamic* prerequisite when a compiler is present. A build without a compiler, or
a resolver that ignores dynamic config, would ship pure Perl without saying so. Hence
`recommends 'Cpanel::JSON::XS', '4.20'` in `cpanfile`: 4.20 is the minimum `Mojo::JSON`
accepts. The Dockerfile installs `requires,recommends` as top-level dependencies, so it needs
no change, and a failed install fails the build.

**EV is not a free win, and today's image (Poll) is not handicapped.** Poll is ahead for JSON
at c=16 in 5 of 5 rounds. The minimal pass-through shows the same direction, so this is
Mojolicious's reactor on this box, not Skeid. EV is ahead on the streaming tail at c=64 in 3 of
3 rounds. At 256 slow connections, the case EV exists for, the two are indistinguishable. The
effects point in opposite directions, are each 15–30 %, and all come from one process. A
production deployment runs `--workers N`, which divides the open connections per loop by N and
moves every process toward the c=16 regime. That is not enough to change the image's reactor.
Because the image installs `recommends`, adding EV to `cpanfile` would change the image's
reactor; leaving it out is a decision, not an oversight.

**Dev-box numbers are close enough to the image, with one caveat.** Earlier reports ran EV+XS.
For JSON at c=16 they are pessimistic by about 15 % compared with the image's Poll+XS. For
streaming they are the same.

**A packed binary buys nothing on the request path and costs startup, 11 MB of RSS, and a
fragile build.** "One file" is not "one static file": it still depends on the host's glibc and
TLS libraries and needs 80 MB of scratch space. The image already gives a self-contained
deployment. A PAR binary is not worth maintaining for speed. A single-file build would only be
worth doing for distribution to hosts without Docker, and that is a different question from
the one asked.

## Harness findings

These showed up while measuring and are recorded on k79 for whoever picks them up.

1. **fakellm outlives SIGTERM.** `signal(SIGTERM, on_signal)` installs the handler with glibc's
   BSD semantics (`SA_RESTART`), so a blocked `accept()` restarts and the loop only sees
   `running = 0` when the next connection arrives. `run-bench.sh` kills fakellm on exit
   without waiting, so a second run started straight after fails with "fakellm did not become
   healthy". The driver above works around it: `settle` sends one `GET /health` to wake the old
   process, then waits for the ports to be free.
2. **fakellm advertises keep-alive on a stream and then closes.** The SSE response sends
   `Connection: keep-alive` (`fakellm.c`, streaming branch of the completion handler), but the
   connection thread always closes after a streamed answer. Mojo::UserAgent pools the
   connection, the next request on it gets "Premature connection close", and Skeid answers
   `502`. This caused the 2 failures at c=16 (Poll+PP) and the 52 at c=64 (EV+XS r3). A real
   upstream that drops idle keep-alive connections would produce the same `502`, which may be
   worth a look on its own.
3. **Usage events land on tmpfs.** `bench/skeid.bench.yaml` writes one jsonlog file per request
   to `/tmp/skeid-bench-usage/`. On this box `/tmp` is tmpfs, so every file costs a 4 KB page
   of RAM. This session's runs wrote 40,817 events, about 160 MB, deleted afterwards. Another
   154 MB from earlier sessions is still there.

## What was not measured

- **The image itself.** No Docker build or run, by instruction. The image has perl 5.38 and
  Cpanel::JSON::XS 4.53, this box perl 5.40.1 and 4.52. The Poll+XS column is the image's
  module set on the dev box's perl, not the image.
- **`--workers N`.** Every run is one process. Whether EV's streaming-tail advantage at c=64
  survives four workers (16 connections each) is open. It is the one follow-up that could
  change the EV recommendation.
- **Concurrency above 64 with a fast upstream**, and anything above 256 connections.
- **The Anthropic and Ollama faces.** Their streams go through a translator that encodes every
  frame again, so the Cpanel::JSON::XS effect is likely larger there. This is an inference, not
  a measurement.
- **staticperl and App::FatPacker.** Neither is installed. staticperl builds its own perl from
  source, which is too heavy for this box under memory pressure. FatPacker only packs pure-Perl
  code and cannot carry the XS modules measured here (EV, Cpanel::JSON::XS, Net::SSLeay, DBD::*),
  so it cannot produce a working single file for Skeid. Neither is measured, so no numbers.
- **TLS, a real upstream, network paths, KeyBroker, database usage stores**, as in every
  `bench/` report (ADR 0007).
- **Noise.** Other agents' builds and tests ran for much of this session. Runs with a disturbed
  baseline were discarded and are named above. The remaining spread is in the ranges.
