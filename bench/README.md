# bench — measuring what Skeid costs

Two C programs and a runner. `fakellm` is an OpenAI-compatible server that pretends to be a
model with a timing envelope you choose; `llmbench` measures TTFT and throughput against any
OpenAI-compatible endpoint. Put a proxy between them and the difference is the proxy's cost.

Not shipped to CPAN (`gather_exclude_match` in `dist.ini`) — it needs a C compiler and it is a
development tool.

```bash
make
./run-bench.sh                 # baseline + Skeid, json and stream, c=8
```

## Why a fake model

A real model's generation dominates a proxy's overhead by two to three orders of magnitude and
varies run to run, so a benchmark against one measures the GPU. Here the model's timing is a
parameter — `--ttft-ms 20 --tokens-per-second 1000` means the first token lands at 20ms and the
rest arrive every 1ms, exactly, every run. Anything left over is the thing you are measuring.

The reasoning is in `docs/adr/0007-benchmarks-use-a-deterministic-fake-model.md`.

## fakellm

```bash
./fakellm --port 18080 --ttft-ms 20 --tokens-per-second 1000 --tokens 64
```

Serves `POST /v1/chat/completions` (JSON and SSE), `POST /v1/embeddings`, `GET /v1/models`,
`GET /health`. Threaded, keep-alive, honours `Connection: close`.

| Flag | Meaning |
|---|---|
| `--ttft-ms` | delay before the first token |
| `--tokens-per-second` | rate for every token after the first |
| `--tokens` | tokens per response (a request's `max_tokens` wins) |
| `--prompt-tokens` | what to report as `prompt_tokens` |
| `--model`, `--port`, `--host`, `--verbose` | |

A request body may also carry `fake_ttft_ms`, `fake_tokens_per_second` and `fake_tokens`, so one
running server can serve several scenarios and a client can prove the server, not the proxy,
chose the timing.

**No authentication. Binds to `127.0.0.1` by default. Do not expose it.**

## llmbench

```bash
./llmbench --port 18080 --requests 200 --concurrency 8 --tokens 64 --stream
```

Reports TTFT and total latency as p50/p95/p99, plus requests/s and tokens/s. TTFT is measured
to the first *content* byte, not to the headers — a proxy that sends headers early and content
late is not fast, and counting headers would hide exactly that.

`--warmup N` (default 5) discards the first requests: the first connection to a freshly started
proxy pays for lazy initialisation nothing else repeats, and leaving it in makes p99 a story
about startup.

Useful flags: `--stream`, `--concurrency`, `--api-key`, `--key-id` (sets `x-skeid-key-id`),
`--path`, `--label`, `--json`.

## Method

1. **Baseline first.** Measure `fakellm` directly with the same client and the same flags. A
   proxy number without its baseline is an anecdote.
2. **One variable per comparison.** Server flags, client flags, git rev — change one.
3. **Distributions, not means.** A mean TTFT hides the tail where one blocked request stalled
   twenty others, which is the failure this harness exists to find.
4. **Quote the invocation.** Every figure travels with the command that produced it and the git
   rev. A number without its command must not be repeated.
5. **Say what you did not measure.** Real models, GPU contention, TLS, network paths, cold
   start. Name the gaps instead of letting a reader assume coverage.

## Comparing against other systems

`llmbench` targets any OpenAI-compatible endpoint, so a comparison is the same command with a
different port. Point the other gateway at `fakellm` too — then every system under test is
serving an identical model and the only difference is the gateway.

```bash
./fakellm --port 18080 --ttft-ms 20 --tokens-per-second 1000 &
# start LiteLLM / vLLM router / whatever, pointed at http://127.0.0.1:18080/v1
./run-bench.sh --no-start --proxy-port 4000 --label "LiteLLM 1.x"
```

Keep the comparison fair and say so in the report: same host, same concurrency, same token
count, and note what each gateway was doing that the others were not (usage accounting, key
resolution, protocol translation). A gateway that meters every request is not slower "for no
reason" — it is doing more work, and the report should say which work.

## Resource discipline

This is a small shared machine. One benchmark run at a time, never in the background, never
fanned out across agents. Bind to localhost. Raise `--concurrency` deliberately and write the
number into the report. `nice -n 19 ionice -c3` for anything long. Clean up processes you
started — the runner does this on exit, a manual run is your responsibility.

## Results

Measured findings live in `docs/bench/`. The first run is
`docs/bench/2026-08-08-baseline.md`, which is also the run that found the SSE relay bug.
