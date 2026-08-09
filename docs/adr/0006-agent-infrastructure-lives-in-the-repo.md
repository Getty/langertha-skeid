# ADR 0006 — Agent, skill and rule infrastructure lives in the repo

- Status: accepted
- Date: 2026-08-08
- Tags: tooling, skills, agents, conventions

## Context

Skeid's agent instructions had drifted into three places that could not see each other: a
157-line `CLAUDE.md` carrying house rules, ENV tables and an architecture diagram; a 667-line
`README.md` repeating the same ENV tables and diagram; and a `perl-ai-proxy-skeid` skill in the
maintainer's *private, unversioned* `~/.claude/skills/`, repeating them a third time.

Three copies of the same paragraph do not stay equal. Worse, the only copy with the operational
detail was invisible to the repository: a collaborator, a fresh checkout or a subagent without
that home directory got the two stale copies and no way to know a third existed.

## Decision

Instruction infrastructure is part of the distribution, laid out as in the DBIO repos:

- `.claude/rules/skeid-rules.md` — house rules, loaded automatically for the main agent and
  every subagent. The 12 discipline rules live here, not in `CLAUDE.md`.
- `CLAUDE.md` — a pointer file: what this repo is, which agent owns which lane, repo-specific
  build and test facts. It references skills; it does not restate them.
- `CONTEXT.md` — the domain vocabulary (**Node**, **Eligibility**, **Admission**, **Key
  reference**, **Usage event**, …), with the words each term replaces.
- `.claude/skills/skeid-*` — repo-owned skills, versioned with the code they describe:
  `skeid-core`, `skeid-protocols`, `skeid-service-stack`, `skeid-benchmark`.
- `.claude/agents/skeid-*` — five agents, each force-loading its skills via `briefing.skills`:
  worker, protocol worker, test writer, perf tester, release checker.
- Shared skills (`perl-core`, `perl-moo`, `perl-release-*`, `karr`, `perl-ai-langertha`) are
  **hardlinked** from their source of truth, never copied.
- `README.md` stays hand-maintained and human-facing; it is excluded from the tarball
  (`include_readme = 0`) and is never generated from POD.

The private `perl-ai-proxy-skeid` skill is deleted; its content is split across the repo skills
above.

## Consequences

- Instructions version with the code and arrive in a fresh checkout. A change to routing and
  the change to the skill that describes it land in one commit and one review.
- The hardlink discipline becomes load-bearing: editing a shared `SKILL.md` with a tool that
  rewrites the file (rather than truncating in place) silently forks it from every other repo.
  This has already happened once here — the local `langertha` skill had drifted to a stale
  245-line variant of the canonical 366-line `perl-ai-langertha`.
- `.claude/`, `bench/` and `docs/` are excluded from the CPAN tarball via `gather_exclude_match`.
  `Git::GatherDir` ships tracked files, so this exclusion must be maintained as directories are
  added.
- Skill content is now duplicated nowhere, which means a wrong skill is wrong everywhere. That
  is the trade being made: one place to fix instead of three places to disagree.
