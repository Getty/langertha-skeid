# ADR 0007 — Benchmarks measure against a deterministic fake model, in C

- Status: accepted
- Date: 2026-08-08
- Tags: benchmark, performance, ttft, tooling

## Context

The number that matters for a routing proxy is what it *adds*: overhead per request, and how
much TTFT degrades as concurrency rises. Measuring that against a real model is close to
useless — the generation dominates by two to three orders of magnitude, GPU scheduling jitter
swamps the signal, results are not reproducible between runs, and every measurement costs
money or a GPU booking.

A benchmark also cannot be written in the language under test. A Perl load generator competing
for the same interpreter, event loop and CPU as the proxy measures the harness as much as the
target, and its timing resolution is worst exactly where TTFT lives.

## Decision

`bench/` holds a self-contained C harness with two programs:

- **`fakellm`** — an OpenAI-compatible server that simulates a model with a configurable
  time-to-first-token and token rate (`--ttft-ms`, `--tokens-per-second`, `--tokens`), serving
  both plain JSON and SSE streaming. It is deterministic: the same flags produce the same
  timing envelope, so a difference between two runs is a difference in the thing being
  measured.
- **`llmbench`** — a measuring client that reports TTFT and inter-token latency as
  distributions (p50/p95/p99), not means, at a chosen concurrency.

Rules that make the numbers mean something:

- **Baseline first.** Every Skeid measurement is paired with the same client hitting `fakellm`
  directly. The reported figure is the delta.
- **One variable per comparison**, and every figure travels with the full invocation and git
  rev.
- The harness targets any OpenAI-compatible endpoint, so comparisons against other proxies are
  the same command with a different port.
- `bench/` is **not** shipped to CPAN. It needs a C compiler, it is a development tool, and a
  CPAN tester should never be asked to build it.

## Consequences

- What is measured is the proxy's own cost — routing, admission, translation, relaying, usage
  accounting — with model time held constant and known. That is the question the harness exists
  to answer, and it answers it reproducibly.
- What is *not* measured: real model behaviour, GPU contention, network paths, TLS termination,
  and how a real provider's rate limits interact with admission. Reports must say so rather
  than let a reader assume coverage.
- A fake upstream that is faster than any real model is deliberate: it puts the proxy on the
  critical path, where overhead is visible instead of hidden under generation time.
- The harness can saturate a shared machine. Its resource discipline is a house rule, not a
  suggestion in a README.
