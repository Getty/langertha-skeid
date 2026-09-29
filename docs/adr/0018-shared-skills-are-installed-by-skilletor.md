# ADR 0018 — Shared skills are installed by skilletor, not hardlinked

- Status: accepted — amends ADR 0006
- Date: 2026-09-29
- Tags: tooling, skills, agents, conventions

---

## Context

ADR 0006 put the shared skills (`getty-perl-*`, `perl-release-dist-ini`, the karr skills,
`perl-ai-langertha`) into `.claude/skills/` as **hardlinks** to their source of truth,
maintained with `manage-skills`, and committed them. Two costs came with that:

- The hardlink chain breaks silently. Any tool that rewrites a file instead of truncating it
  in place forks the copy from every other repo; ADR 0006 already records one such drift.
- Every shared-skill update became a commit in this repo ("skills: take over the shared skill
  updates"), unrelated to Skeid's own history, and a fresh checkout on another machine got
  whatever snapshot was last committed.

Meanwhile the house rules file ADR 0006 names, `.claude/rules/skeid-rules.md`, never reached
the repository: the root `.gitignore` whitelisted `.claude/agents/` and `.claude/skills/` but
not `.claude/rules/`, so it stayed a local file and was lost.

## Decision

- Shared skills are declared in `.claude/skilletor.json` (sources `getty`, `karr`,
  `langertha`, all `git`) and installed by `skilletor sync`. The installed copies are
  gitignored; `.claude/skilletor.lock.json` (also ignored) records what is installed.
- Repo-owned instruction files stay tracked, unchanged from ADR 0006: `skeid-*` skills,
  `skeid-*` agents, `.claude/rules/skeid-rules.md`.
- A shared skill is changed in its source repository and re-synced — never edited under
  `.claude/skills/`.
- The root `.gitignore` whitelists `.claude/rules/`, `.claude/skilletor.json` and
  `.claude/.gitignore`.

## Consequences

- A fresh checkout needs `skilletor sync` (the skilletor plugin runs it at session start)
  before the agents' `briefing.skills` resolve; without it, `briefing` denies the spawn and
  names the missing skill — a loud failure, not a silent one.
- Shared-skill churn leaves this repo's history. Skeid commits touch `.claude/` only for its
  own skills, agents and rules.
- The maintainer's user config may point a source at a local checkout (author mode); the
  committed config always names the public `git` source.
