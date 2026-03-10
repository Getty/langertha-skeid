# Skeid — Langertha Routing Control Plane

`Langertha::Skeid` is the dynamic control-plane companion to Knarr.

- Live node inventory and weighted routing
- OpenAI/Anthropic/Ollama proxy frontends
- Normalized usage + cost accounting
- Dynamic YAML reload on each task dispatch
- Built-in usage store: `sqlite` or `postgresql`

## Install

```bash
cpanm --installdeps .
```

## Run Proxy

```bash
bin/skeid serve --listen 127.0.0.1:8090 --config skeid.yaml
```

Supported routes:

- OpenAI: `POST /v1/chat/completions`, `POST /v1/embeddings`, `GET /v1/models`
- Anthropic: `POST /v1/messages`
- Ollama: `POST /api/chat`, `GET /api/tags`, `GET /api/ps`

Admin routes:

- `GET /skeid/nodes`
- `POST /skeid/nodes`
- `POST /skeid/nodes/:id/health`
- `GET /skeid/metrics/nodes`
- `GET /skeid/usage`

## Cloud Provider Scenario (Multi-API + Billing)

Skeid can run as a provider gateway in front of many upstream APIs (cloud + local),
route requests by model, and persist normalized token/cost usage for billing.

Typical setup:

1. Register many upstream nodes (for example OpenAI-compatible cloud endpoints and local vLLM/SGLang).
2. Define model pricing in `pricing` to normalize cost per request.
3. Send a tenant key id in `x-skeid-key-id` (or `x-api-key-id`) on each request.
4. Read tenant/model totals via `GET /skeid/usage` or `bin/skeid usage --json`.

This gives you one unified API edge and one usage ledger for invoice/export workflows.

## YAML Config

```yaml
pricing:
  "*":
    input_per_million: 0.10
    output_per_million: 0.40

nodes:
  - id: vllm-a
    url: http://127.0.0.1:21001/v1
    model: qwen2.5-7b-instruct
    engine: openai-compatible
    weight: 1
    max_conns: 128

usage_store:
  backend: sqlite
  sqlite_path: /data/skeid/usage.sqlite

routing:
  wait_timeout_ms: 2000
  wait_poll_ms: 25
```

Cloud-mix example:

```yaml
nodes:
  - id: cloud-openai
    url: https://api.openai.com/v1
    model: gpt-4o-mini
    engine: openai-compatible
    max_conns: 64
  - id: cloud-groq
    url: https://api.groq.com/openai/v1
    model: llama-3.3-70b-versatile
    engine: openai-compatible
    max_conns: 64
  - id: local-vllm-a
    url: http://vllm-a:8000/v1
    model: qwen2.5-7b-instruct
    engine: openai-compatible
    max_conns: 128
```

`sqlite_path` is required for `backend: sqlite`. Skeid creates the SQLite file and applies schema automatically.

PostgreSQL option:

```yaml
usage_store:
  backend: postgresql
  dsn: dbi:Pg:dbname=skeid;host=postgres;port=5432
  user: skeid
  password_env: SKEID_USAGE_DB_PASSWORD
```

Schema SQL files (simple and explicit):

- `sql/usage_events.sqlite.sql`
- `sql/usage_events.postgresql.sql`

## Docker Quickstart (SQLite)

1. Config + Data-Verzeichnis anlegen:

```bash
mkdir -p ./skeid-config ./skeid-data
cat > ./skeid-config/skeid.yaml <<'YAML'
pricing:
  "*":
    input_per_million: 0.10
    output_per_million: 0.40

nodes:
  - id: vllm-a
    url: http://host.docker.internal:21001/v1
    model: qwen2.5-7b-instruct
    engine: openai-compatible

usage_store:
  backend: sqlite
  sqlite_path: /data/skeid/usage.sqlite
YAML
```

2. Container starten:

```bash
docker run -d --name skeid \
  -p 8090:8090 \
  -v "$PWD/skeid-config:/etc/skeid:ro" \
  -v "$PWD/skeid-data:/data/skeid" \
  raudssus/langertha-skeid \
  bin/skeid serve --listen 0.0.0.0:8090 --config /etc/skeid/skeid.yaml
```

3. Schnell prüfen:

```bash
curl -s http://127.0.0.1:8090/health
docker exec -it skeid bin/skeid usage --config /etc/skeid/skeid.yaml
```

Hinweis: `sqlite_path` muss auf ein beschreibbares Volume zeigen, damit Usage-Daten persistent bleiben.

## Beispiel: Avatar Setup (2x vLLM + 2x SGLang)

Fertige Config:

- `examples/avatar-skeid.yaml`

Schnellstart:

```bash
mkdir -p ./skeid-config ./skeid-data
cp ./examples/avatar-skeid.yaml ./skeid-config/skeid.yaml

docker run -d --name skeid \
  -p 8090:8090 \
  -v "$PWD/skeid-config:/etc/skeid:ro" \
  -v "$PWD/skeid-data:/data/skeid" \
  raudssus/langertha-skeid \
  bin/skeid serve --listen 0.0.0.0:8090 --config /etc/skeid/skeid.yaml
```

Wenn deine Ports anders sind, nur die `url`-Felder in der YAML anpassen.

## Docker: Usage aus SQLite abrufen

Skeid intern:

```bash
docker exec -it skeid bin/skeid usage --config /etc/skeid/skeid.yaml
docker exec -it skeid bin/skeid usage --config /etc/skeid/skeid.yaml --json
```

Direkt per SQL (separater sqlite3-Container):

```bash
docker run --rm -v "$PWD/data:/data" keinos/sqlite3 \
  sqlite3 /data/skeid/usage.sqlite \
  "SELECT created_at, api_key_id, model, status_code, total_tokens, cost_total_usd FROM usage_events ORDER BY id DESC LIMIT 50;"
```

## Docker: PostgreSQL Report

```bash
docker exec -it skeid bin/skeid usage \
  --backend postgresql \
  --dsn 'dbi:Pg:dbname=skeid;host=postgres;port=5432' \
  --db-user skeid \
  --db-pass-env SKEID_USAGE_DB_PASSWORD \
  --json
```

## Usage CLI

```bash
skeid usage [--config skeid.yaml] [--since 2026-03-10T00:00:00Z] [--limit 100] [--json]
```

Optional filters:

- `--api-key-id k_...`
- `--model qwen2.5-7b-instruct`

## Saturation Behavior

Wenn alle passenden Nodes auf `max_conns` stehen, wartet Skeid kurz auf einen freien Slot:

- `routing.wait_timeout_ms` (Default: `2000`)
- `routing.wait_poll_ms` (Default: `25`)

Das Waiting ist non-blocking (Mojo IOLoop Timer), sodass der Proxy parallel weitere Requests bedienen kann.

Bei Erfolg wird die Anfrage normal weitergeleitet. Wenn bis Timeout kein Slot frei wird, gibt Skeid `429 rate_limit_error` zurueck.
