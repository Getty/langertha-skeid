# Skeid — LLM routing service

![Langertha Skeid](assets/github.jpg)

`Langertha::Skeid` is one Mojolicious process in front of many LLM nodes. Clients talk to it
in the OpenAI, Anthropic or Ollama format; Skeid picks a node, forwards the request in the
OpenAI dialect, translates the answer back, and writes one usage event per request for
billing. Upstream keys are resolved at request time and live only in memory.

- **Routing**: weighted round-robin over the nodes that serve the requested model, with
  admission control (`max_conns`), node tags, model aliases with fallback tiers, and a
  per-key routing policy.
- **Three client formats**: OpenAI, Anthropic (`/v1/messages`) and Ollama (`/api/chat`,
  `/api/generate`), all with streaming and tool calls.
- **Metering**: one usage event per forwarded request, priced at record time, including prompt
  cache reads and writes; stored as JSON files, SQLite or PostgreSQL, or handed to your own
  code.
- **Capacity**: optional probes (rate-limit headers, Prometheus metrics, a downstream Skeid's
  registry) so admission follows what the node reports, not only what this process sent.
- **Keys**: `api_key_ref` resolved through the OpenBao KeyBroker, or `api_key_env`; never
  written to disk, logs or usage events.
- **Operations**: live config reload, admin API, prefork workers, a provider manifest per
  customer key.

The words used here (node, tier, admission, saturation, customer key id, ...) are defined in
[`CONTEXT.md`](CONTEXT.md).

## Install

```bash
cpanm --installdeps .
```

Optional modules:

- `DBI` + `DBD::SQLite` for the `sqlite` usage store, `DBI` + `DBD::Pg` for `postgresql`.
  The `jsonlog` store needs neither.
- A Langertha newer than 0.503 (`Langertha::Tool->classify`, `Langertha::Manifest`,
  cache-aware `Langertha::Cost`). With the released 0.503 Skeid runs, but a `/v1/messages`
  request that carries `tools` is answered with `400`, the manifest route answers `404`, and
  pricing cache rates are ignored with a warning.

## Quick start

A minimal config, `skeid.yaml`:

```yaml
nodes:
  - id: vllm-a
    url: http://127.0.0.1:8000/v1
    model: qwen2.5-7b-instruct
    engine: vllm
    max_conns: 32

pricing:
  "*":
    input_per_million: 0.10
    output_per_million: 0.40

usage_store:
  backend: jsonlog
  path: ./skeid-events/
```

Run it and send a request:

```bash
bin/skeid serve --listen 127.0.0.1:8090 --config skeid.yaml

curl -s http://127.0.0.1:8090/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer sk-alice' \
  -d '{"model":"qwen2.5-7b-instruct","messages":[{"role":"user","content":"Hello"}]}'

bin/skeid usage --config skeid.yaml
```

### Docker

The image `raudssus/langertha-skeid` has `ENTRYPOINT ["perl", "-Ilib", "bin/skeid"]` and by
default runs `serve --listen 0.0.0.0:8090 --config /etc/skeid/skeid.yaml`. Arguments after the
image name replace the default command, so they start with the subcommand (`serve`, `usage`,
`keyid`), not with `bin/skeid`. The default command needs a config mounted at
`/etc/skeid/skeid.yaml` and exits with `config file not found` without one; to start without a
config, run `serve --listen 0.0.0.0:8090`.

```bash
mkdir -p skeid-config
cat > skeid-config/skeid.yaml <<'YAML'
nodes:
  - id: vllm-a
    url: http://host.docker.internal:8000/v1
    model: qwen2.5-7b-instruct
    engine: vllm
usage_store:
  backend: jsonlog
  path: /var/log/skeid/events/
YAML

docker run -d --name skeid -p 8090:8090 \
  -v "$PWD/skeid-config:/etc/skeid:ro" \
  -v skeid-events:/var/log/skeid/events \
  raudssus/langertha-skeid

# or, with options: repeat the default command and add to it
docker run -d --name skeid -p 8090:8090 -v "$PWD/skeid-config:/etc/skeid:ro" \
  raudssus/langertha-skeid serve --listen 0.0.0.0:8090 --config /etc/skeid/skeid.yaml --workers 4

curl -s http://127.0.0.1:8090/health
docker exec skeid bin/skeid usage --config /etc/skeid/skeid.yaml
```

The image installs what `cpanfile` requires and what it recommends, so `DBI`, `DBD::Pg` and
`DBD::SQLite` are there and every usage store works. It carries no compiler.

Skeid runs as the unprivileged user `skeid` (uid and gid 10001). The image gives it two
directories to write to: `/var/log/skeid/events` for a `jsonlog` store and `/var/lib/skeid` for
a `sqlite` database. Mount a volume there, or the usage events go with the container. A named
volume, as above, takes the ownership the image set. A host directory mounted instead has to
be writable for uid 10001, and a mounted config readable for it.

## Configuration

Skeid reads one YAML file (`--config`). On every request it checks the file's mtime and
applies a changed file in full or not at all:

- A config that fails to load or validate keeps the previous one in force. The failure is
  logged, the request is served under the kept config, and a file version that failed is
  retried with a back-off (1s, doubling up to 60s). A new mtime is always read at once.
  `GET /health` shows `config_reload.ok` and `failed_at`; `GET /skeid/config` also shows the
  error.
- A file touched without a change applies nothing.
- `nodes` is replaced wholesale when that section changes, so nodes added through the admin
  API are lost; an unchanged `nodes` section keeps the node list, its probes and any health
  set through the admin API.
- The running config becomes what the file says, as a restart with that file would. A section
  present replaces what is loaded — `pricing` too, so a model removed from it loses its price.
  A section removed from the file (`nodes`, `pricing`, `aliases`, the policy sections) is
  cleared, and a `routing` key removed from it goes back to its default.
- Removing `usage_store` is the exception: the running store stays until restart and the
  reload logs a warning, because a reload must not silently stop recording billing data. A
  changed `usage_store` is swapped at once.
- A section the file has never had is left alone, so nodes added only through the admin API
  survive reloads of a file without `nodes`.

### Nodes

```yaml
nodes:
  - id: gpu-1                        # required, unique
    url: http://gpu-1:8000/v1        # required; base URL, /v1 is appended if missing
    model: qwen3-32b                 # empty or absent: serves any requested model
    engine: vllm                     # Langertha engine id (default: openaibase)
    weight: 3                        # round-robin weight (default 1)
    max_conns: 32                    # admission limit; 0 or absent: unlimited
    healthy: true                    # operator flag (default true)
    tags: [local, gb10]              # or "local, gb10"
    api_key_ref: secret/skeid/remote/gpu   # upstream key via the KeyBroker, or
    # api_key_env: GPU_API_KEY             # upstream key from this environment variable
    # capacity: { probe: prometheus, path: /metrics }   # see "Capacity"
    # rerank_format: tei                   # a reranker that speaks TEI's dialect, see below
    # metadata: { ... }                    # free-form, returned by the admin API
```

Every node is called in the OpenAI dialect: `POST {url}/chat/completions` or
`{url}/embeddings` ([ADR 0001](docs/adr/0001-one-upstream-call-shape-all-client-formats-translated.md)),
and `{url}/audio/transcriptions` or `{url}/audio/translations` for the audio routes and
`{url}/rerank` for the rerank route
([ADR 0021](docs/adr/0021-non-chat-routes-are-relayed-not-translated.md)).
`engine` does not change the call. It must match an engine id of the installed Langertha
(the lowercased class name: `OpenAI` → `openai`, `OpenAIBase` → `openaibase`,
`vLLM` → `vllm`, `SGLang` → `sglang`, `Groq` → `groq`, ...); an unknown id fails the load, and
legacy names like `openai-compatible` are rejected. Use `openaibase` for a generic
OpenAI-compatible server. To see the ids your Langertha knows:

```bash
perl -Ilib -MLangertha::Skeid -E 'say for @{ Langertha::Skeid->supported_engine_ids }'
```

**Upstream authentication.** A node with `api_key_ref` or `api_key_env` gets
`Authorization: Bearer <key>` and any client `x-api-key` is dropped, in any spelling.
`api_key_ref` needs the OpenBao KeyBroker (see
[Service stack](#service-stack-openbao--postgresql)); when it resolves nothing, `api_key_env`
is the fallback. A node with neither forwards the client's own
`Authorization` / `x-api-key` header unchanged. A node that names a key source and gets no key
from it (the broker fails or is not running, the variable is unset or empty) is never called:
the request is answered `503` (`upstream_key_unavailable`) in the error shape of the face that
was called, the log names the key reference, and the client's key stays with Skeid. Hop-by-hop headers are never forwarded.

`healthy` is only ever changed by an operator (config or admin API). Skeid does not poll
nodes, and neither errors nor rate limits mark a node unhealthy.

**A Whisper node** is a node like any other; what it serves is decided by the model name a
client asks for. vLLM serves one model per process, speaches loads models on demand:

```yaml
nodes:
  - id: whisper-vllm                 # vllm serve openai/whisper-large-v3
    url: http://gpu-2:8000/v1
    model: openai/whisper-large-v3
    engine: vllm
    max_conns: 4
  - id: whisper-speaches             # speaches (faster-whisper)
    url: http://gpu-3:8000/v1
    model: Systran/faster-whisper-large-v3
    engine: openaibase
    max_conns: 2
aliases:
  whisper:                           # one product name: vLLM first, speaches when it is full
    tiers:
      - model: openai/whisper-large-v3
      - model: Systran/faster-whisper-large-v3
```

Clients reach it through [`/v1/audio/transcriptions`](#client-protocols).

**A reranker node** is a node like any other as well. vLLM, infinity, Jina and Cohere speak
the request shape clients send and are relayed; a Hugging Face text-embeddings-inference (TEI)
server speaks its own and needs `rerank_format: tei`:

```yaml
nodes:
  - id: rerank-vllm                  # vllm serve BAAI/bge-reranker-v2-m3
    url: http://gpu-4:8000/v1        # serves /v1/rerank
    model: BAAI/bge-reranker-v2-m3
    engine: vllm
    max_conns: 16
  - id: rerank-infinity              # infinity, started with --url-prefix /v1
    url: http://gpu-5:7997/v1        # without the prefix infinity serves /rerank at its root
    model: BAAI/bge-reranker-v2-m3
    max_conns: 16
  - id: rerank-tei                   # Hugging Face text-embeddings-inference
    url: http://gpu-6:8080           # called at /rerank, with or without a /v1 here
    model: BAAI/bge-reranker-v2-m3
    rerank_format: tei               # translated: documents -> texts, the bare array -> results
    max_conns: 16
```

Without `rerank_format` the request is relayed to `{url}/rerank` as the client sent it. `tei`
is the only other value; an unknown one fails the load. The three nodes above serve one model
and share its load, each asked in its own dialect. Clients reach them through
[`/v1/rerank`](#client-protocols).

**An embedding node** is a node like any other too: `POST /v1/embeddings` is routed, admitted
and metered like a chat request, so several servers of one model share its load, `healthy`,
`max_conns`, `weight`, capacity probes, aliases and tiers all apply, and the answer is relayed
untouched:

```yaml
nodes:
  - id: embed-vllm                   # vllm serve BAAI/bge-m3 --task embed
    url: http://gpu-7:8000/v1
    model: BAAI/bge-m3
    engine: vllm
    max_conns: 16
  - id: embed-tei                    # Hugging Face text-embeddings-inference
    url: http://gpu-8:8080           # TEI serves /v1/embeddings (OpenAI-compatible)
    model: BAAI/bge-m3
    max_conns: 16
  - id: embed-infinity               # infinity, started with --url-prefix /v1
    url: http://gpu-9:7997/v1        # without the prefix infinity serves /embeddings at its root
    model: BAAI/bge-m3
    max_conns: 16
```

- The usage event takes `usage.prompt_tokens` / `usage.total_tokens` as input and total tokens
  (an embedding has no output tokens) and prices them with the model's `input_per_million`.
  infinity counts characters, not tokens, unless it runs with `lengths_via_tokenize`; what it
  reports is what is recorded.
- The default Prometheus capacity probe knows the metric names of vLLM, SGLang and TGI. A TEI or
  infinity node names its own in the `capacity` block (`running`, `waiting`, see
  [Capacity](#capacity-admission-and-saturation)), or runs on `inflight` admission, which needs
  nothing from the server.
- One request is one slot, whatever its batch size: a request with 1000 inputs weighs like one
  with a single input. Choose `max_conns` with that in mind.
- A JSON body above Mojolicious' 16 MiB message limit is refused as invalid JSON.
- There is no Ollama embeddings face (`/api/embed`); only `/v1/embeddings` exists.

### Routing

```yaml
routing:
  wait_timeout_ms: 2000        # how long a saturated request waits for a slot (default 2000)
  wait_poll_ms: 25             # how often it re-checks (default 25, minimum 1)
  frontend_count: 1            # separate Skeid hosts sharing these nodes (default 1)
  trust_key_id_header: false   # believe x-skeid-key-id from the client (default false)
```

See [Capacity, admission and saturation](#capacity-admission-and-saturation) for what these
do.

### Model aliases and tiers

An alias is a client-facing model name that resolves to an ordered list of tiers. Each tier
selects nodes by tags, names the model to ask them for, and may wait for capacity before the
next tier is tried
([ADR 0008](docs/adr/0008-routing-policy-is-per-key-and-resolved-at-config-load.md)).

```yaml
aliases:
  house-model:
    tiers:
      - tags: [local]
        model: qwen3-32b          # the served model; default: the alias name itself
        wait_ms: 200              # wait for a local GPU before paying for cloud (default 0)
      - tags: [cloud, groq]       # a node needs every listed tag
        model: llama-3.3-70b-versatile
        # engine: groq            # optional engine constraint
```

- A tier with no eligible node is skipped at once; a tier whose nodes are all busy waits its
  `wait_ms` and then falls through.
- A model without an alias is a single implicit tier that waits `routing.wait_timeout_ms`, so
  a config without aliases routes as it always did.
- The usage event records both the served model (`model`, what is priced) and the
  requested model (`requested_model`, what the customer asked for).
- `GET /v1/models` and `GET /api/tags` list the node models and the alias names, each once,
  narrowed by the policy of the key presented (no key: the default policy) -- a key is not
  shown a name it would be refused. A node without a `model` matches any name and has none of
  its own, so it is not listed.

### Customer key ids and per-key policy

Skeid identifies the caller by the key it presents (`Authorization: Bearer ...` or
`x-api-key`). Every key derives a **customer key id**, `k_` + the full SHA-1 hex of the key,
and a request with no key is `anonymous`. The id selects the routing policy and is what the
usage event is billed under. Skeid does not check the key against a list unless the config
has a `client_auth` section (see [Client authentication](#client-authentication)); without
one, authenticate callers in front of Skeid or rely on the upstream checking the forwarded
key.

```bash
bin/skeid keyid sk-alice-secret-key     # prints k_28f8389e824f2273c846b9562cffc72a4f10a651
echo sk-alice-secret-key | bin/skeid keyid   # keeps the key out of the shell history
```

A policy decides which models a key may ask for and which node tags it may not be served
from:

```yaml
policies:
  standard:  { deny_tags: [cloud] }        # our hardware only
  burstable: {}                            # cloud is fine when local is full
  trial:     { models: [house-model] }     # one product, anywhere
default_policy: standard                   # unlisted keys take this
names:                                     # readable name -> key id (never a key)
  alice:   k_28f8389e824f2273c846b9562cffc72a4f10a651
  bigcorp: k_9c8b7a6f5e4de5f60718293a4b5c6d7e8f901a2b
keys:
  alice: burstable                         # a profile name ...
  bigcorp:                                 # ... or a profile plus sparse overrides
    policy: standard
    deny_tags: [cloud, eu-outside]
  k_1122334455aae5f60718293a4b5c6d7e8f901a2b: trial   # a raw key id works too
```

- Resolved once at config load; a request costs one hash lookup. An undefined policy name
  fails the load.
- `deny_tags` filters node selection, so a denied node cannot be reached by asking for its
  raw model name instead of an alias.
- A refusal is `403 permission_error`. Running out of *permitted* capacity stays `429`; Skeid
  never falls through to a denied node.
- `names:` makes `keys:` legible and turns key rotation into a one-line change
  ([ADR 0011](docs/adr/0011-customer-key-names-live-in-the-config.md)).
- Ids are the full digest since [ADR 0016](docs/adr/0016-customer-key-id-is-the-full-digest-short-ids-match-by-prefix.md).
  An old 12-hex id in `keys:` or `names:` still matches the key it is the prefix of, with a
  one-time warning; listing a short id and the full id it prefixes is a load error. Usage
  events keep the id they were recorded under, so query both for a customer's full history.
- `routing.trust_key_id_header: true` makes Skeid take the id from `x-skeid-key-id` (or
  `x-api-key-id`). Only turn it on when a gateway in front of Skeid authenticates the caller
  and sets that header; otherwise any client can name itself into another customer's policy
  and invoice.

### Client authentication

When Skeid is the public entry itself -- nginx in front for TLS, nothing that checks keys --
list the customer key ids that may come in
([ADR 0020](docs/adr/0020-client-authentication-is-an-allowlist-of-key-ids.md)):

```yaml
names:
  shared: k_5f0e1a2b3c4de5f60718293a4b5c6d7e8f901a2b   # bin/skeid keyid <key> -- never the key
client_auth:
  keys: [shared]          # names: entries or raw key ids
```

- Every client route -- `/v1/models`, `/v1/chat/completions`, `/v1/embeddings`,
  `/v1/audio/*`, `/v1/rerank` and `/rerank`, `/v1/messages`, every `/api/*` route and `/.well-known/langertha.json` --
  answers `401` with
  `WWW-Authenticate: Bearer realm="skeid"` to a request without a key (`Missing API key`) or
  with a key whose id is not listed (`Invalid API key`). The body is in the route's dialect:
  OpenAI `{"error":{"type":"invalid_request_error","code":"invalid_api_key",...}}`, Anthropic
  `authentication_error`, Ollama `{"error":"..."}`.
- A refused request is not routed, forwarded, metered or logged, and the answer names neither
  the key nor its id. `/health` and the `/skeid/*` routes keep their own rules.
- Without the section nothing is checked, as before. Being let in widens nothing: the key's
  routing policy still applies.
- The list is hot-reloaded like the rest of the config, on every client route: adding,
  rotating or removing an id holds from the next request (within
  `SKEID_CONFIG_RELOAD_INTERVAL`). Start with one shared key, one id; give clients keys of
  their own later by adding `names:` entries.
- An entry that is neither a `names:` entry nor a key id fails the load, and the error names
  it by position only -- it is most likely a key pasted where its id belongs. `keys: []` lets
  nobody in.
- With `routing.trust_key_id_header` the header's id is what has to be on the list.

### Uploads

```yaml
uploads:
  max_bytes: 26214400     # default: 25 MiB, OpenAI's own limit for an audio file
```

The largest request body the upload routes (`/v1/audio/transcriptions`,
`/v1/audio/translations`) accept: the file and the form around it. A larger one is answered
`413` (`invalid_request_error`) without touching a node and without a usage event. The limit
holds while the body arrives, not after it was stored: a request that declares a larger
`Content-Length` is answered at once and its connection closed, and with
[client authentication](#client-authentication) a caller that is not on the list gets its
`401` the same way, before its upload is received. The section is hot-reloaded; removed, the
default applies again. An unknown key in it or a value that is not an integer of at least 1
fails the load. Every other route keeps the server's own request limit (16 MiB,
`MOJO_MAX_MESSAGE_SIZE`).

Behind a reverse proxy, its own body limit applies first (nginx: `client_max_body_size`).

### Pricing

```yaml
pricing:
  "*":                              # fallback for models without a rule
    input_per_million: 0.10
    output_per_million: 0.40
  gpt-4o-mini:
    input_per_million: 0.15
    output_per_million: 0.60
    cached_input_per_million: 0.075   # optional, prompt-cache reads
    cache_write_per_million: 0.1875   # optional, prompt-cache writes
```

Rules are looked up by the served model and applied when the event is recorded, so a later
price change never rewrites history. With the two cache rates, cache reads and writes are
priced into `cost_cache_read_usd` and `cost_cache_write_usd` (both part of `cost_total_usd`)
and `cost_input_usd` covers only the uncached input; without them cached tokens bill at
`input_per_million`. The cache rates need a Langertha newer than 0.503; an older one ignores
them with a warning. A rate that is not a number >= 0 fails the load
([ADR 0013](docs/adr/0013-cached-tokens-are-recorded-pricing-is-deferred.md)).

### Admin API key

```yaml
admin:
  api_key_env: SKEID_ADMIN_API_KEY   # recommended: keep the key out of the file
  # api_key: change-me               # or inline
# admin_api_key: ... / admin_api_key_env: ...   # top-level spellings, same meaning
```

The admin key comes from the first of these that has one:

1. `serve --admin-api-key` (or `build_app(admin_api_key => ...)`): wins over the config, on
   every reload.
2. The config: the first of the four spellings above that is present decides. Set empty, or
   naming an unset variable, it turns the admin API off.
3. `SKEID_ADMIN_API_KEY`, when the config names none of them.

With none of them `/skeid/*` answers `404`. Every reload re-applies this order, so removing
the key from the config falls back to `SKEID_ADMIN_API_KEY`. A key on the command line shows up
in the process list; in production, name the variable in the config.

### Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `SKEID_ROUTE_WAIT_TIMEOUT_MS` | `2000` | default for `routing.wait_timeout_ms` |
| `SKEID_ROUTE_WAIT_POLL_MS` | `25` | default for `routing.wait_poll_ms` |
| `SKEID_FRONTEND_COUNT` | `1` | default for `routing.frontend_count` |
| `SKEID_TRUST_KEY_ID_HEADER` | off | default for `routing.trust_key_id_header` (`1`/`true`/`yes`/`on`) |
| `SKEID_CAPACITY_MAX_AGE_MS` | `5000` | how long a capacity reading is trusted (`0`: forever) |
| `SKEID_USAGE_DB` | — | SQLite path used when the config has no `usage_store` |
| `SKEID_ADMIN_API_KEY` | — | admin key when the config names none (see above) |
| `SKEID_UPSTREAM_POOL` | `100` | upstream connection pool size |
| `SKEID_UPSTREAM_TIMEOUT` | `300` | seconds an upstream request may take and may be silent for; the client's connection is kept open as long |
| `SKEID_CONFIG_RELOAD_INTERVAL` | `1` | seconds between runs of a Perl `config_loader` (not used for files) |
| `OPENBAO_ADDR` | `http://127.0.0.1:8200` | OpenBao address |
| `OPENBAO_ROLE_ID`, `OPENBAO_SECRET_ID` | — | AppRole credentials; both set enables the KeyBroker |
| `OPENBAO_VERIFY_SSL` | on | `0` disables TLS verification (dev vault only) |

Variables named in the config (`api_key_env`, `password_env`, `admin.api_key_env`,
`registry.secret_env`, `registry.read_key_env`, a probe's `secret_env` / `read_key_env`) are
read when the config is applied.

Upstream requests time out after 10s to connect and `SKEID_UPSTREAM_TIMEOUT` seconds in total,
and may be silent for all of that time: a model that thinks sends nothing until its first token.
On the routes that call an upstream, the client's connection gets the same time on top of the
server's inactivity timeout (30s), for that request only, so Skeid never closes a request its
upstream is still working on. Every other route stays under the server's timeout. A proxy or load
balancer in front of Skeid needs a read timeout at least as long.

## Client protocols

| Route | Format | Notes |
| --- | --- | --- |
| `POST /v1/chat/completions` | OpenAI | passed through; streaming relayed byte for byte |
| `POST /v1/embeddings` | OpenAI | passed through |
| `POST /v1/audio/transcriptions` | OpenAI | multipart upload, relayed to the node's own endpoint; answer and stream relayed as they are |
| `POST /v1/audio/translations` | OpenAI | the same, to the node's translations endpoint |
| `POST /v1/rerank`, `POST /rerank` | OpenAI | one route under two names; relayed to the node's own endpoint, translated for a `rerank_format: tei` node |
| `GET /v1/models` | OpenAI | node models and alias names, per key policy |
| `POST /v1/messages` | Anthropic | translated to and from OpenAI |
| `POST /api/chat` | Ollama | translated; streams unless `"stream": false` |
| `POST /api/generate` | Ollama | translated; streams unless `"stream": false` |
| `GET /api/tags` | Ollama | the same names as `/v1/models` (size, digest etc. left empty) |
| `GET /api/ps` | Ollama | always an empty list |
| `GET /health` | — | `{status, proxy, config_reload}`; no auth |
| `GET /.well-known/langertha.json` | — | provider manifest for the calling key |

All faces use the same routing, policy, usage event and pricing, and the same
[client authentication](#client-authentication) when it is configured. Errors come back in the
client's format: OpenAI error objects on the OpenAI face, `{"type":"error","error":{...}}` on
`/v1/messages`, `{"error":"<message>"}` on `/api/*`. An upstream error carries the upstream's
own message.

**OpenAI.** Requests go upstream unchanged except for the model name. A stream is relayed as
is and parsed only for metering; Skeid does not add `stream_options.include_usage`, so ask
for it if streamed requests should carry token counts. Otherwise the event records only
`content_bytes`.

**Audio** (`/v1/audio/transcriptions`, `/v1/audio/translations`). OpenAI's
`multipart/form-data` upload, for a node that serves Whisper through vLLM or
[speaches](https://github.com/speaches-ai/speaches). Nothing is translated
([ADR 0021](docs/adr/0021-non-chat-routes-are-relayed-not-translated.md)):

```bash
curl -s http://127.0.0.1:8090/v1/audio/transcriptions -H "Authorization: Bearer $KEY" \
  -F model=whisper -F file=@meeting.wav -F language=de -F response_format=verbose_json
```

- The request is routed by the form's `model` field like a chat request: aliases, tiers, key
  policy, `max_conns`, health. `model` has to be there exactly once (otherwise `400`); an alias
  tier's served model replaces it. Every other part goes to `{url}/audio/transcriptions` (or
  `/audio/translations`) as the client sent it, in the client's order, unknown and repeated
  fields (`timestamp_granularities[]`) included.
- The upload is not copied in memory: a part above 256 KiB is spooled to a temporary file by
  the server and sent upstream from there. Its size limit is [`uploads.max_bytes`](#uploads).
- The answer is the node's, whatever `response_format` made it: JSON, `verbose_json`, `text`,
  `srt`, `vtt`.
- `stream=true` (also `1`, `on`, `yes`, in any case) relays the node's event stream byte for
  byte, in the node's dialect: `transcript.text.delta` / `transcript.text.done` from OpenAI and
  speaches (which ends without `[DONE]`), `transcription.chunk` frames and `data: [DONE]` from
  vLLM. Skeid adds nothing to the form; a vLLM node sends its usage frame only when the form
  carries `stream_include_usage=true`.
- Metering is what the node reports, see [`audio_seconds`](#usage-and-billing). A chat request
  that names a Whisper model is routed to that node and refused there; Skeid does not know
  what a model can do.

**Rerank** (`/v1/rerank`, also `/rerank`). The request shape Cohere set and vLLM, Jina and
infinity took over; there is no stream:

```bash
curl -s http://127.0.0.1:8090/v1/rerank -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' -d '{
    "model": "BAAI/bge-reranker-v2-m3", "query": "What is the capital of Germany?",
    "documents": ["Cologne is on the Rhine", "Berlin is the capital"], "top_n": 1,
    "return_documents": true }'
```

- `400` before a node is touched: a body that is no JSON object, a `model` that is not a
  non-empty string, a `query` that is not a string, `documents` that is not a non-empty array.
  Then it is routed by `model` like a chat request: aliases, tiers, key policy, `max_conns`,
  health.
- By default the body goes to `{url}/rerank` with every field as sent and `model` replaced by
  the served model, and the node's answer comes back byte for byte
  ([ADR 0021](docs/adr/0021-non-chat-routes-are-relayed-not-translated.md)). What the nodes do
  differently stays different: `document` is `{"text": ...}` from vLLM and Cohere and a plain
  string from infinity; vLLM returns the documents whether `return_documents` asked or not;
  `top_n` and unknown fields are the node's to interpret.
- A [`rerank_format: tei`](#nodes) node is translated. Up: `POST /rerank` at the server root
  with `query`, `texts` (each document a string, or the `text` of an object), `return_text` for
  `return_documents` and `truncate` when sent; everything else is dropped. Down:
  `{"model": <served model>, "results": [{"index", "relevance_score", "document": {"text"}}],
  "usage": {"total_tokens"}}`, sorted by score, cut to `top_n`, `document` only when
  `return_documents` asked for it, `usage` only when TEI sent its `x-compute-tokens` header. A
  document that is not text, or a `top_n` that is not a whole number of at least 0, is a `400`
  with one failed usage event (the node was admitted by then, the slot is given back).
- Metering: [`documents`](#usage-and-billing) and the node's tokens as input tokens.

**Anthropic** (`/v1/messages`). Messages, system prompt, images (base64 or URL source) and
function tools are translated; `tool_use` / `tool_result` round-trips work, including images
inside a tool result. Streaming emits the Anthropic event sequence (`message_start`,
`content_block_*` including `tool_use` blocks with `input_json_delta`, `message_delta`,
`message_stop`). A stream that fails after it opened ends with an `event: error` frame. The
node only ever sees one system message, at the start: `system` plus any `role: system` messages
before the first turn. A `role: system` message later in `messages` (Claude Code's
mid-conversation system messages) is sent as `<system-reminder>...</system-reminder>` text of
the adjacent user turn — appended to the user message before it, else prepended to the one
after it, else as its own user message — so chat templates that want the system message first
or strict role alternation accept it, and the prompt prefix stays the same from turn to turn.
Not supported: images from the Files API and provider built-in tools (`web_search_*`,
`bash_*`, `text_editor_*`, `computer_*`, `mcp_toolset`, ...), both answered with `400`. Tools
on this face need a Langertha newer than 0.503 (see [Install](#install)).

**Ollama** (`/api/chat`, `/api/generate`). Streams newline-delimited JSON unless the request
says `"stream": false`, as Ollama does. `tools` and replayed tool round-trips are translated
into OpenAI's shape, streamed tool calls come back as `message.tool_calls`. `images` become
image parts; `format: "json"` or a JSON schema becomes `response_format`. On `/api/generate`,
`system`, `prompt` and `images` become one chat conversation; `think`, `suffix`, `template`,
`raw`, `context` and `keep_alive` are not forwarded and no `context` is returned.

### Provider manifest

`GET /.well-known/langertha.json` publishes a [Langertha manifest](https://metacpan.org/pod/Langertha)
per customer key: only the models that key's `keys:` entry lists, on the faces Skeid serves,
claiming only capabilities that face carries. It is off until enabled, needs a Langertha with
`Langertha::Manifest` (otherwise `404`), answers `401` without a key and `403` for a key
without a grant, and never shows a node URL
([ADR 0015](docs/adr/0015-provider-manifest-is-per-key-opt-in-and-resolved-at-config-load.md)).

```yaml
manifest:
  enabled: true
  public_url: https://llm.example.com   # where clients reach Skeid; required
  provider_id: example-llm              # default: skeid
  faces: [openai, anthropic, ollama]    # default: all three
  capabilities:                         # optional claims per model; default chat + streaming
    house-model: { tools_native: true, tool_choice_auto: true }
keys:
  alice:
    policy: burstable
    manifest: { models: [house-model, qwen3-32b] }
```

A listed model the key's policy cannot reach, an unknown capability or face, or an enabled
manifest without `public_url` fails the load.

## Usage and billing

Every forwarded request writes one usage event after it finishes, failures included
(`ok = 0`) ([ADR 0004](docs/adr/0004-usage-events-are-the-billing-unit.md)). An event carries:

- identity and route: `created_at`, `request_id` (from `x-request-id` or generated),
  `api_format`, `endpoint`, `api_key_id`, `provider`, `engine`, `model` (served),
  `requested_model`, `node_id`, `route_url`
- outcome: `status_code`, `ok`, `duration_ms`, `error_type`, `error_message`
- tokens: `input_tokens`, `output_tokens`, `total_tokens`, `cached_tokens`,
  `cache_write_tokens`, `tool_calls`
- cost in USD: `cost_input_usd`, `cost_output_usd`, `cost_cache_read_usd`,
  `cost_cache_write_usd`, `cost_total_usd`
- streamed requests only: `content_bytes`, the UTF-8 size of the relayed content (an
  observation, never turned into tokens)
- audio routes only, and only when the node reports it: `audio_seconds`, the seconds of audio
  the node worked on
- the rerank route only, on a request the node answered: `documents`, the number of documents
  the request carried

Streamed requests are priced from the upstream's usage frame exactly like a non-streamed
answer. A stream cut short is recorded as failed, and billed from its usage frame if one
arrived.

`audio_seconds` is taken from the node's answer: `usage.seconds` when `usage.type` is
`duration` (vLLM's JSON answer, OpenAI's `whisper-1`), else the top-level `duration` of a
`verbose_json` answer (vLLM, speaches). An answer with neither -- speaches' plain JSON, any
`text` / `srt` / `vtt` answer, a vLLM translation, most streams -- leaves the field out: not
measured, never `0`. Ask for `response_format=verbose_json` where seconds are what you bill.
A node that reports tokens instead (OpenAI's `gpt-4o-transcribe`, vLLM's stream usage frame)
fills the token fields as on a chat request. Seconds are recorded, not priced: `pricing` has
no per-second rate ([ADR 0021](docs/adr/0021-non-chat-routes-are-relayed-not-translated.md)).

`documents` is counted by Skeid off the request, so it is there whatever the node reports; a
failed rerank request has no such field. The event's `endpoint` is `/v1/rerank` for both
spellings of the route. A reranker's tokens are input tokens: they are recorded as
`input_tokens` (and `total_tokens`) and priced with the served model's `input_per_million`,
from wherever the node reports them:

| Node | Where the count is read |
| --- | --- |
| vLLM, infinity, Jina | `usage.prompt_tokens`, else `usage.total_tokens` (older vLLM and Jina send only the total) |
| Cohere | `meta.tokens.input_tokens` |
| TEI (`rerank_format: tei`) | the `x-compute-tokens` response header |

A node that reports none leaves the token fields at 0. Two caveats: **infinity counts
characters, not tokens**, unless it runs with `lengths_via_tokenize` -- Skeid records what the
node says, so price such a node per character or turn the option on; and Cohere's
`meta.billed_units.search_units` is not recorded. `documents` is recorded, not priced: there
is no per-document or per-search rate.

Without a `usage_store` (and without `SKEID_USAGE_DB`) nothing is recorded. When the store
cannot write an event (a full disk, a dropped table, a lost database), the request is still
answered, and the proxy logs `usage event lost: request_id=... store=<backend> api_key_id=...
model=... status=...: <reason>` at `error` level, so the event can be reconciled by hand. The
line never carries a key, a DSN or a password. A SQLite or PostgreSQL store whose connection
dropped reconnects once and retries that event, so a database restart loses only the events
that arrive while the database is down, not every event until Skeid restarts.

### jsonlog (recommended)

No database, no DBI, never blocks the event loop.

```yaml
usage_store:
  backend: jsonlog
  path: /var/log/skeid/events/   # a directory: one <id>.json per event
  # mode: file                   # or one JSON line per event in a single file, under flock
  # fsync: true                  # flush each event to disk before returning (slower)
```

Directory mode is chosen when the path is an existing directory or ends in `/`. It needs no
lock and a crash loses at most the event in flight; it is also the right choice with
`--workers`. Each file is a complete event:

```bash
jq -s 'group_by(.model)[] | {model: .[0].model, requests: length, tokens: (map(.total_tokens) | add)}' \
  /var/log/skeid/events/*.json
```

### SQLite and PostgreSQL

```yaml
usage_store:
  backend: sqlite
  sqlite_path: /data/skeid/usage.sqlite    # or path: / db_path:
```

```yaml
usage_store:
  backend: postgresql
  dsn: dbi:Pg:dbname=skeid;host=postgres;port=5432   # or host/port/dbname
  user: skeid
  password_env: SKEID_USAGE_DB_PASSWORD             # or password: (avoid)
  # auto_migrate: true                              # default
  # schema_file: /path/to/schema.sql
```

The backend is inferred when `backend` is absent: a sqlite path key means `sqlite`, a
`dbi:Pg:` DSN means `postgresql`, `log_path` means `jsonlog`. The schema is applied from
`share/sql/usage_events.<backend>.sql` when `auto_migrate` is on, and columns added in later
versions (`requested_model`, `cached_tokens`, ...) are added to an existing table; nothing is
ever dropped. SQLite is single-writer: do not use it with `--workers` above 1.

### Reports

```bash
bin/skeid usage --config skeid.yaml [--since 2026-09-01T00:00:00Z] [--api-key-id k_...] \
  [--model NAME] [--limit 20] [--json]
bin/skeid usage --log-path /var/log/skeid/events/    # a jsonlog store, without a config
curl -s -H "Authorization: Bearer $SKEID_ADMIN_API_KEY" \
  'http://127.0.0.1:8090/skeid/usage?since=2026-09-01T00:00:00Z&limit=50'
```

A report has `totals`, `by_key`, `by_model` and the most `recent` events (limit 1..500; the
CLI defaults to 20, the admin route to 50). The first three sum `audio_seconds` and
`documents` beside the tokens; the CLI prints them (`Audio:  seconds=...` and
`Rerank: documents=...` after the totals, `audio_seconds=...` and `documents=...` on a row)
only where there are some.

### Your own usage sink

Replace the store from Perl, without a subclass:

```perl
my $skeid = Langertha::Skeid->new(
  config_file       => 'skeid.yaml',
  store_usage_event => sub {
    my ($skeid, $event) = @_;          # the event described above
    publish_to_nats($event);
    return { ok => 1 };
  },
  query_usage_report => sub {
    my ($skeid, $filters) = @_;        # since, api_key_id, model, limit
    return { ok => 1, enabled => 1, totals => { ... } };
  },
);
my $app = Langertha::Skeid::Proxy->build_app(skeid => $skeid);
```

or subclass `Langertha::Skeid` and override `_store_usage_event` / `_query_usage_report`.
With a callback or override no database connection is made.

## Deployment

### Workers and frontends

`serve --workers N` runs N prefork workers (default 1). `inflight` is per process, so each
worker admits `max_conns / N` of every node (at least 1); a `max_conns` smaller than the
worker count cannot be honoured and is warned about at startup. Probe intervals are multiplied
by N so the node sees the configured poll rate. Admin API writes reach only the worker that
answered, so with several workers the config file is the only reliable source of node state
([ADR 0010](docs/adr/0010-workers-partition-max-conns-and-background-work.md)). Measurements:
`docs/bench/2026-08-09-prefork-workers.md`.

Several Skeid hosts in front of the same nodes cannot see each other's `inflight`. Set
`routing.frontend_count` to their number and each admits `max_conns / frontend_count`; it
multiplies with `--workers`
([ADR 0012](docs/adr/0012-frontends-partition-max-conns-and-compose-with-workers.md)). A
frontend that forgets it over-admits by that factor. A capacity probe makes every frontend see
the node's real occupancy; the division still applies.

### Building the image

```bash
docker build -t raudssus/langertha-skeid .
```

The Dockerfile has two stages. The first has the compiler and installs `cpanfile` with `cpm`
from MetaCPAN, recommended modules included; the second is the image, and takes the installed
modules and the checkout from the first. When the required Langertha is released but not yet
resolvable (right after a release), or to build against a local Langertha, install that
tarball first:

```bash
docker build -t raudssus/langertha-skeid \
  --build-arg LANGERTHA_SRC=GETTY/Langertha-X.YYY.tar.gz .   # CPAN path or tarball URL
```

`dzil release` tags and pushes the image itself (`latest`, `<major>`, `<version>`) through
`Dist::Zilla::Plugin::Docker::API`, which `docker_image` in `dist.ini` switches on. It talks to
the container engine at `DOCKER_HOST` over the Engine HTTP API, so rootless Podman works and no
`docker` binary is needed. The image is built in every `dzil build` and `dzil test` as well;
`DZIL_DOCKER_API_SKIP=1` skips that for those two, and `dzil release` refuses to run with it.
`LANGERTHA_SRC` cannot be given from the environment on that path.

### Service stack (OpenBao + PostgreSQL)

`examples/service/` is a compose stack for development: OpenBao in dev mode for upstream keys,
PostgreSQL for usage events, and Skeid.

![Skeid service stack: client, Skeid, OpenBao, PostgreSQL, LLM nodes](assets/service-stack.jpg)

The client sends `Authorization: Bearer <customer key>` to Skeid on `:5591`; Skeid reads
upstream keys from OpenBao (`:5501`), writes usage events to PostgreSQL (`:5533`) and
forwards to the LLM nodes.

1. `cd examples/service && cp .env.example .env`, and set `SKEID_GROQ_KEY` there for the
   sample node (`groq-main`, `api_key_ref: secret/skeid/remote/groq`). `SKEID_OPENAI_KEY` and
   `SKEID_ANTHROPIC_KEY` are stored the same way at `secret/skeid/remote/openai` and
   `.../anthropic`, for nodes you add.
2. The `skeid` service runs `raudssus/langertha-skeid:latest`. For a local build, build it
   from the repository root and set `SKEID_IMAGE` in `.env` to its tag.
3. `docker compose up -d openbao postgres`
4. `docker compose run --rm skeid-init` (the service is in the `init` profile and runs in the
   OpenBao image with its `bao` CLI). It writes a `skeid-keys` policy reading
   `secret/skeid/*`, enables AppRole, creates the `skeid-service` role, stores each provider
   key that is set, and prints `OPENBAO_ROLE_ID` and `OPENBAO_SECRET_ID`: put both into
   `.env`. Keys go into `bao kv put` on stdin, never as an argument.
5. `docker compose up -d skeid`, then
   `curl -s http://localhost:5591/v1/chat/completions -H 'Authorization: Bearer sk-alice-secret-key' ...`

Skeid creates the `usage_events` table in PostgreSQL itself on start, from
`share/sql/usage_events.postgresql.sql` (`auto_migrate`); the init job touches no database.
Customer keys are stored nowhere: any bearer key is accepted and routed and billed under its
key id (see [Customer key ids](#customer-key-ids-and-per-key-policy)). Policies in
`skeid.yaml` name that id. `docker run --rm -i raudssus/langertha-skeid keyid` prints it for
a key typed or piped on stdin.

OpenBao runs in dev mode: in memory, root token from `.env`. Every restart of the `openbao`
container loses the AppRole and the stored keys, so run `skeid-init` again and replace both ids
in `.env`. Do not use this stack as it is for production.

`examples/service/skeid.yaml` carries commented examples for aliases, policies and probes.

**KeyBroker.** When `OPENBAO_ROLE_ID` and `OPENBAO_SECRET_ID` are both set, Skeid logs in with
AppRole and resolves each node's `api_key_ref` from KV v2 (`secret/skeid/remote/groq` reads
`secret/data/skeid/remote/groq`, field `api_key`). Keys are cached in memory only, resolution
never blocks the event loop, and the token is renewed on a timer. If renewal fails after the
token has expired the process exits, so the container restarts and logs in again
([ADR 0003](docs/adr/0003-secrets-live-in-memory-only.md)). The TLS certificate is verified
unless `OPENBAO_VERIFY_SSL=0`. Only key references appear in config, logs and usage events.

## Capacity, admission and saturation

Routing picks a node in two steps
([ADR 0002](docs/adr/0002-eligibility-and-admission-are-two-decisions.md)):

- **Eligible**: the node serves the model (or has none), matches the engine if one is asked
  for, carries the tier's tags, none of the key's denied tags, and is `healthy`.
- **Admitted**: its `inflight` is below this process's share of `max_conns`, and its current
  capacity reading, if any, has room.

Weighted round-robin walks the eligible nodes, skipping those that are not admitted. When a
tier has eligible nodes but none admits, the request waits (non-blocking, polling every
`wait_poll_ms`) for that tier's `wait_ms`, or `routing.wait_timeout_ms` for a model without an
alias. Then:

| Answer | When |
| --- | --- |
| `503 model_not_found` | no tier had any eligible node — a config or model-name problem |
| `429 rate_limit_error` | nodes existed but none had a free slot in time — saturation |
| `403 permission_error` | the key's policy does not allow the model or any node serving it |

### Capacity probes

`inflight` counts only what this process sent. A probe reports what the node itself says, and
may only narrow what `max_conns` allows, never widen it
([ADR 0009](docs/adr/0009-node-capacity-is-probed-not-only-counted.md)).

```yaml
nodes:
  - id: gpu-1
    url: http://gpu-1:8000/v1
    max_conns: 32
    capacity:
      probe: prometheus            # prometheus | registry | custom | inflight (default)
      path: /metrics               # resolved against the node URL; or url: for a sidecar
      interval_ms: 2000            # default 2000
      # running: vllm:num_requests_running   # override metric names (also waiting:)
      # limit: 32                            # default: max_conns
```

- **Rate-limit headers** are read off every upstream response of every node, with no probe
  configured: `x-ratelimit-*`, `anthropic-ratelimit-*`, `ratelimit-*`, requests and tokens
  separately, the tightest quota decides. A `429` or `Retry-After` sets a backoff (1s when no
  `Retry-After` is given). `probe: ratelimit` is accepted and changes nothing.
- **`prometheus`** polls the node's metrics; `used` is running + waiting. Defaults cover vLLM
  (`vllm:num_requests_running` / `vllm:num_requests_waiting`), SGLang (`sglang:num_running_reqs`
  / `sglang:num_queue_reqs`) and TGI (`tgi_batch_current_size` / `tgi_queue_size`).
- **`registry`** reads a downstream Skeid, see below.
- **`custom`** loads `class:` (a probe class, see `Langertha::Skeid::CapacityProbe`) or takes
  a `code` callback when the config comes from Perl.

A reading expires after `SKEID_CAPACITY_MAX_AGE_MS` (5s); a failing probe forgets its reading
and `inflight` decides again. A backoff outlives that age. Nothing a probe sees ever changes
`healthy`. Keep `interval_ms` × workers below the max age; the probe warns at start otherwise.

### Skeid in front of Skeids: the registry

When a node is itself a Skeid, `capacity.probe: registry` reads that Skeid's own view of its
load: per upstream node, what is in flight and what it may admit. Both sides are off unless
configured ([ADR 0017](docs/adr/0017-skeid-to-skeid-registry-is-a-signed-pulled-capacity-probe.md)).

Downstream (publishes the snapshot):

```yaml
admin:
  api_key_env: SKEID_ADMIN_API_KEY
registry:
  enabled: true                       # default false: GET /skeid/registry/snapshot answers 404
  secret_env: SKEID_REGISTRY_SECRET   # required; at least 32 bytes (openssl rand -hex 32)
  ttl_s: 10                           # optional, default 10
  instance_id: skeid-b                # optional, default: hostname
  error_window_s: 60                  # optional, default 60
  read_key_env: SKEID_REGISTRY_READ_KEY   # optional; bearer for the snapshot route only
```

Fronting tier (one node per downstream):

```yaml
nodes:
  - id: skeid-b
    url: http://skeid-b:8090/v1
    model: qwen3-32b
    max_conns: 64                     # still this process's guardrail; the reading only narrows it
    capacity:
      probe: registry
      read_key_env: SKEID_B_READ_KEY            # the downstream's registry read key
      # admin_key_env: SKEID_B_ADMIN_KEY        # or its admin API key (avoid: write-capable)
      secret_env: SKEID_REGISTRY_SECRET         # the same secret as the downstream
      interval_ms: 2000
      # url: http://skeid-b:8090/skeid/registry/snapshot   (default: derived from the node url)
      # tags: [local]                 # count only downstream nodes with these tags
      # max_skew_s: 5                 # default 5
```

Operator contract:

- The snapshot is signed: `X-Skeid-Registry-Signature: sha256=<HMAC-SHA256 of the exact body>`.
  Per node it carries `id`, `tags`, `healthy`, `inflight`, `max_conns`, `errors_in_window`,
  `last_failure_at` and a current `capacity` reading if there is one — never node URLs, key
  references, metadata, customer key ids, policies or usage.
- The fronting tier believes a snapshot only if the signature verifies, it is younger than its
  `ttl`, not more than `max_skew_s` ahead of the local clock, and not older than the last one
  accepted. Otherwise it forgets the reading and admission falls back to `inflight`. Keep the
  clocks in sync (NTP).
- Free slots of a downstream = the sum over its healthy (and tag-matching) nodes of
  `max_conns - inflight`, taking each node's own tighter reading into account. A pending
  backoff counts as no free slots, an unlimited node makes the downstream unbounded, no healthy
  node reads as full.
- The snapshot is never added to the fronting tier's own `inflight`. When two sources disagree
  about one node, the tighter reading wins while it is current: a pending `429` backoff always
  holds, any other tighter reading only while it is younger than the longer of the two
  sources' poll intervals.
- Errors in the snapshot are informational; they never change admission or health.
- With `--workers N` on the downstream, a snapshot describes only the worker that answered.
  The fronting tier can over-admit until the next poll; each downstream worker still admits
  only its share, and the surplus waits there and gets `429`.

Security:

- Serve the snapshot route over TLS only; the fronting tier sends a bearer key on every poll.
- Give the fronting tier the registry read key, not the admin key. The read key opens
  `GET /skeid/registry/snapshot` and no other route. With `read_key_env` set the probe never
  sends the admin key, even when that variable is empty. The admin key is still accepted on
  the route, but whoever holds it can add nodes with any `url` and make the downstream send its
  provider keys there.
- `registry.enabled` needs a read key or an admin key and a secret of at least 32 bytes, or the
  config does not load; so does a `read_key_env` naming an empty variable.
- Rotating the secret: there is one secret per pair and no overlap window. Restart the
  downstream and the fronting tier with the new value; in between the probe reports
  `bad_signature` and admission falls back to `inflight`.

## Admin API

All `/skeid/*` routes need `Authorization: Bearer <admin key>`; without an admin key
configured they answer `404`, with a wrong one `401`.

| Route | Does |
| --- | --- |
| `GET /skeid/nodes` | the node inventory |
| `POST /skeid/nodes` | add or replace a node (JSON body with the node fields) |
| `POST /skeid/nodes/:id/health` | `{"healthy": false}` takes a node out of rotation |
| `GET /skeid/metrics/nodes` | per-node `inflight`, `started`, `ok`, `error`, `duration_ms_total` and any current capacity reading; volatile, not billing data |
| `GET /skeid/usage` | usage report: `since`, `api_key_id`, `model`, `limit` |
| `GET /skeid/config` | last reload result: error, `failed_at`, consecutive failures |
| `GET /skeid/registry/snapshot` | the signed registry snapshot; also takes the registry read key |

Changes made here live in memory: they are lost on restart and on the next change to (or
removal of) the config's `nodes:` section, and reach only one worker under `--workers`.

## CLI

```
skeid serve [--listen host:port] [--config skeid.yaml] [--admin-api-key KEY] [--workers N]
skeid usage [--config skeid.yaml] [--since ISO8601] [--limit N] [--json]
            [--backend jsonlog|sqlite|postgresql] [--log-path /path/to/events/]
            [--db /path/to.sqlite] [--dsn dbi:Pg:...]
            [--db-user USER] [--db-pass PASS | --db-pass-env ENV]
            [--api-key-id ID] [--model NAME]
skeid keyid [KEY ...]
```

- `serve` (the default subcommand): `--listen` defaults to `127.0.0.1:8090`, `--workers` to
  1. A `--config` that is not an existing file is an error (exit 2), not an empty config;
  without `--config`, `./skeid.yaml` is read when it exists, and Skeid otherwise starts with
  no config and no nodes. A config file that disappears while Skeid runs keeps the config in
  force and is warned about once.
- `usage` prints a report from the configured usage store; the
  `--backend`/`--log-path`/`--db`/`--dsn` options override it (`--log-path` implies jsonlog,
  `--db` sqlite, `--dsn` postgresql). `--config` behaves as for `serve`.
- `keyid` prints the customer key id for each key, or for each line of stdin.

## Examples and lab recipes

[`examples/README.md`](examples/README.md) describes the scripts under `examples/`: a
parallel smoke client, a one-box run (temporary config, start, smoke, stop), the Vast.ai GPU
image and rental script, and the service stack.

## Further reading

- [`CONTEXT.md`](CONTEXT.md) — the vocabulary
- [`docs/adr/`](docs/adr/) — why things are the way they are
- [`Changes`](Changes) — what changed in which release
- POD: `perldoc Langertha::Skeid`, `Langertha::Skeid::Proxy`,
  `Langertha::Skeid::CapacityProbe`, `Langertha::Skeid::KeyBroker::OpenBao`
