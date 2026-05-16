# CLAUDE.md — Langertha::Skeid

## Overview

Skeid ist der LLM Routing Service. Proxy für Multi-Node LLM calls mit Usage-Tracking und Key-Management via OpenBao.

## Die 12 Regeln

Diese Regeln kommen aus dem Goldmine Projekt und gelten für alle Tasks:

### Rule 1 — Think Before Coding
State assumptions explicitly. If uncertain, ask rather than guess. Present multiple interpretations when ambiguity exists. Push back when a simpler approach exists. Stop when confused. Name what's unclear.

### Rule 2 — Simplicity First
Minimum code that solves the problem. Nothing speculative. No features beyond what was asked. No abstractions for single-use code. Test: would a senior engineer say this is overcomplicated? If yes, simplify.

### Rule 3 — Surgical Changes
Touch only what you must. Clean up only your own mess. Don't "improve" adjacent code, comments, or formatting. Don't refactor what isn't broken. Match existing style.

### Rule 4 — Goal-Driven Execution
Define success criteria. Loop until verified. Don't follow steps. Define success and iterate. Strong success criteria let you loop independently.

### Rule 5 — Use the model only for judgment calls
Use me for: classification, drafting, summarization, extraction. Do NOT use me for: routing, retries, deterministic transforms. If code can answer, code answers.

### Rule 6 — Token budgets are not advisory
Per-task: 4,000 tokens. Per-session: 30,000 tokens. If approaching budget, summarize and start fresh. Surface the breach. Do not silently overrun.

### Rule 7 — Surface conflicts, don't average them
If two patterns contradict, pick one (more recent / more tested). Explain why. Flag the other for cleanup. Don't blend conflicting patterns.

### Rule 8 — Read before you write
Before adding code, read exports, immediate callers, shared utilities. "Looks orthogonal" is dangerous. If unsure why code is structured a way, ask.

### Rule 9 — Tests verify intent, not just behavior
Tests must encode WHY behavior matters, not just WHAT it does. A test that can't fail when business logic changes is wrong.

### Rule 10 — Checkpoint after every significant step
Summarize what was done, what's verified, what's left. Don't continue from a state you can't describe back. If you lose track, stop and restate.

### Rule 11 — Match the codebase's conventions, even if you disagree
Conformance > taste inside the codebase. If you genuinely think a convention is harmful, surface it. Don't fork silently.

### Rule 12 — Fail loud
"Completed" is wrong if anything was skipped silently. "Tests pass" is wrong if any were skipped. Default to surfacing uncertainty, not hiding it.

## Skeid Service Stack

Das ist der Produktiv-Stack mit OpenBao + PostgreSQL:

```
openbao     → Secrets Vault (AppRole auth, KV v2)
postgres    → Usage storage + config storage
skeid       → LLM Proxy
```

### AppRole Token Lifecycle (Sicherheitsmodell)

1. Container bootet mit AppRole credentials (role_id + secret_id) — als ENV injected
2. Skeid bootet → zieht token aus OpenBao via AppRole → in memory gespeichert
3. Token wird alle 5min renewed (background loop)
4. **Wenn renewal stirbt → Skeid stirbt → Docker restart** (gewollt, kein token auf disk)

**Wichtig:** AppRole secret ist nur 1x verwendbar pro token. Wenn der token weg is, muss der container neu starten.

### Customer API Keys

Keys liegen in OpenBao unter `secret/skeid/customer/<key-id>`:

- Request mit `x-skeid-key-id: "alice"` → Lookup `secret/skeid/customer/alice`
- Key wird pro-request aus OpenBao gelesen, nie persisted auf disk

### Usage Storage

PostgreSQL backend via `usage_store` config:

```yaml
usage_store:
  backend: postgresql
  dsn: dbi:Pg:dbname=skeid;host=postgres;port=5432
  user: skeid
  password_env: SKEID_USAGE_DB_PASSWORD
```

Schema: `share/sql/usage_events.postgresql.sql`

### ENV Variablen

**OpenBao:**
- `OPENBAO_ADDR` — Default: http://openbao:8200
- `OPENBAO_ROLE_ID` — AppRole role_id
- `OPENBAO_SECRET_ID` — AppRole secret_id (einmalig verwendbar)

**Skeid:**
- `SKEID_ADMIN_API_KEY` — Admin API key für /skeid/* routes
- `SKEID_USAGE_DB_PASSWORD` — PostgreSQL password
- `SKEID_REMOTE_KEY_REF` — OpenBao path für den LLM provider API key (z.B. `secret/skeid/remote/openai`)

### Node Config mit OpenBao Keys

In der skeid.yaml:

```yaml
nodes:
  - id: openai-main
    url: https://api.openai.com/v1
    model: gpt-4o-mini
    engine: openai
    api_key_ref: secret/skeid/remote/openai  # ← KeyBroker lookup
```

Skeid resolved `api_key_ref` via KeyBroker → OpenBao. Key wird in memory gehalten, nie auf disk.

## Architektur

```
Client Request (x-skeid-key-id: alice)
       │
       ▼
   ┌─────────┐
   │  Skeid  │ ◄── Admin API key (OPENBAO_TOKEN_PATTERN für lookup)
   │  Proxy  │
   └────┬────┘
        │
        ├──────────────────┬────────────────────┐
        │                  │                    │
        ▼                  ▼                    ▼
┌──────────────┐   ┌──────────────┐    ┌──────────────┐
│   OpenBao    │   │  PostgreSQL  │    │  LLM Nodes   │
│  (Keys/Certs)│   │   (Usage)    │    │ (OpenAI/etc) │
└──────────────┘   └──────────────┘    └──────────────┘
```

## Shell Commands

```bash
# Stack starten
docker compose -f examples/service/docker-compose.yml up -d

# Status prüfen
docker compose -f examples/service/docker-compose.yml ps

# Logs
docker compose -f examples/service/docker-compose.yml logs -f skeid

# Usage abfragen
docker compose -f examples/service/docker-compose.yml exec skeid bin/skeid usage --json

# OpenBao Status
docker compose -f examples/service/docker-compose.yml exec openbao bao status

# Container neustarten (nach token renewal failure)
docker compose -f examples/service/docker-compose.yml restart skeid
```

## Dates and Versions

- today: 2026-05-16