Read when adding or changing a client route, or when you need which route belongs to which API format and whether it streams.

# Client edge

| API format | Routes | Streaming |
|---|---|---|
| OpenAI | `POST /v1/chat/completions`, `POST /v1/embeddings`, `GET /v1/models` | yes, SSE relay |
| OpenAI, relayed (ADR 0021) | `POST /v1/audio/transcriptions`, `POST /v1/audio/translations` | yes, SSE relay in the node's own event dialect |
| OpenAI, relayed (ADR 0021) | `POST /v1/rerank`, `POST /rerank` (one route) | no |
| OpenAI, relayed session (ADR 0029) | `GET /v1/realtime` (WebSocket upgrade; `model` in the query) | yes — frames both ways, the node's own events |
| Anthropic | `POST /v1/messages` | yes — OpenAI SSE re-chunked into Anthropic events (`Protocol::Anthropic::Stream`) |
| Ollama | `POST /api/chat`, `POST /api/generate`, `POST /api/embed`, `POST /api/embeddings`, `GET /api/tags`, `GET /api/ps` | yes — NDJSON (`Protocol::Ollama::Stream`, `shape => 'generate'` for `/api/generate`) |
| API description, not a face (ADR 0025) | `GET /openapi.json` (client routes the config enables, behind the client gate), `GET /skeid/openapi.json` (admin key), `GET /docs` + `/docs/*` (Swagger UI, `openapi.swagger_ui`, fetched on first use and cached, else 404) | no |
| Relayed, docling's own paths (ADR 0028) | `POST /v1/convert/file`, `POST /v1/convert/source` (sync only) | no — JSON or zip answer as the node gave it |
| MCP gateway, not a face (ADR 0022) | `POST|GET|DELETE /mcp/<name>[/<path>]`, `GET /v1/mcp/servers` | yes — whatever the MCP server sends, unbuffered |

- Embeddings take the chat path (`_begin_route_async`): nodes of one model share load with health,
  `max_conns`, capacity readings, aliases and tiers; one request = one slot whatever its batch
  size; the answer is relayed byte for byte, `usage.prompt_tokens` / `total_tokens` metered as
  input tokens. No Ollama `/api/embed`. `t/70-embeddings-nodes.t`.
- `GET /health` is unauthenticated and cheap (also with `client_auth`); `/skeid/*` is the admin
  surface (skill `skeid-core`). `GET /.well-known/langertha.json` serves the per-key provider
  manifest (ADR 0015).
- Streams on every face are metered and priced like non-streamed requests (verbatim upstream
  usage frame through `metrics.normalize`, skeid #41); images become OpenAI `image_url` parts on
  the Anthropic and Ollama faces (skeid #42/#43).
