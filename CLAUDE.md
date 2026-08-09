# CLAUDE.md — Langertha::Skeid

Canonical instruction file for the Skeid repo. Skeid is the LLM routing service: one
Mojolicious process that fronts many LLM nodes, speaks three client protocols, meters what it
forwards, and never keeps a key on disk.

This distribution ships its own agent skills (`.claude/skills/`), agents (`.claude/agents/`),
and house rules (`.claude/rules/`); every `skeid-*` skill and `skeid-*` agent named here refers
to those. The discipline, event-loop, secrets, benchmark and release rules live in
`.claude/rules/skeid-rules.md` — loaded automatically by Claude Code, for the main agent and
all subagents. The domain vocabulary is `CONTEXT.md`; use its words in code, tickets and ADRs.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself —
principle and lane are in `.claude/rules/skeid-rules.md`. Agents in this repo:

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `skeid-worker` (default) |
| Wire protocols & services: OpenAI/Anthropic/Ollama formats, SSE, Langertha engines, MCP tools | `skeid-protocol-worker` |
| Write/extend tests (`Test::Mojo`, fake upstream, usage stores) | `skeid-proxy-test-writer` |
| Measure TTFT / throughput, run `bench/`, compare against other proxies | `skeid-perf-tester` |
| Pre-release audit (cpanfile pins, dist.ini, Docker tags, Changes) | `skeid-release-checker` |

The agents carry their skills via `briefing.skills` (see `.claude/agents/`); the main agent
delegates rather than loading them. Skill sources live under `.claude/skills/`.

## Repo map

```
lib/Langertha/Skeid.pm            control plane: config, nodes, routing, admission, usage, pricing
lib/Langertha/Skeid/Proxy.pm      Mojolicious app: routes, auth, protocol handlers, upstream I/O
lib/Langertha/Skeid/Protocol/     wire-format translation (Anthropic, Ollama <-> OpenAI)
lib/Langertha/Skeid/UsageStore/   usage backends: JsonLog, DBI (sqlite/postgresql)
lib/Langertha/Skeid/KeyBroker.pm  key resolution contract; ::OpenBao is the implementation
bin/skeid                         `serve` and `usage` CLI
share/sql/                        usage_events schema per backend
examples/service/                 OpenBao + PostgreSQL + Skeid compose stack
bench/                            C fake-LLM server + measuring client (not shipped to CPAN)
docs/adr/                         architecture decision records
```

Which skill covers what: `skeid-core` (routing, config, usage, admin API), `skeid-protocols`
(the three client formats, streaming, Langertha engine IDs), `skeid-service-stack` (OpenBao,
compose, ENV, deployment), `skeid-benchmark` (`bench/`, TTFT methodology, comparisons). Do NOT
duplicate skill content here — reference it.

## Build specifics

`[@Author::GETTY]` with `include_readme = 0` (default): `README.md` is a hand-maintained
GitHub file, excluded from the tarball, and never generated from POD. `Git::GatherDir` ships
only git-tracked files — `.claude/`, `bench/` and `docs/` are excluded via
`gather_exclude_match` in `dist.ini`.

Releasing also builds and pushes Docker images (`run_after_release`). See the release rule.

## Testing

`prove -lr t/` or `dzil test` — both recursive. Proxy tests run `Test::Mojo` against
`Langertha::Skeid::Proxy->build_app` with an inline fake upstream; no network, no OpenBao, no
real database. Details in `.claude/rules/skeid-rules.md`.

## Tracking

`karr` board in `refs/karr/*` for tickets, `docs/adr/` for decisions that constrain future
work. Record an ADR when a change fixes an architectural seam — the protocol translation
boundary, the usage-store contract, the key-resolution path, the async-only rule.
