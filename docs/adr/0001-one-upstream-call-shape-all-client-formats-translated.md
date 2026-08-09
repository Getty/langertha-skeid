# ADR 0001 — One upstream call shape; all client formats are translated

- Status: accepted
- Date: 2026-08-08
- Tags: protocols, translation, routing, backfill

## Context

Skeid accepts requests in three client dialects — OpenAI (`/v1/chat/completions`,
`/v1/embeddings`), Anthropic (`/v1/messages`) and Ollama (`/api/chat`) — and forwards them to
nodes that may be OpenAI, vLLM, SGLang, Groq, Ollama-in-OpenAI-mode or anything else Langertha
knows. The naive shape for that is a matrix: every client format times every upstream engine.
With three client formats and a growing engine list, that matrix is where a proxy goes to die
— every new engine multiplies the number of code paths that can be subtly wrong, and each of
them has to be tested against a real provider to know.

## Decision

There is exactly **one** upstream call: `POST {node.url}/chat/completions` (or `/embeddings`)
with an OpenAI-shaped body. Every non-OpenAI client format is translated into that call on the
way in and back into its own dialect on the way out.

- The **Engine ID** on a node is metadata — it gates eligibility and lands in the usage event.
  It is never a branch in the request builder.
- Format-specific field names (`system`, `tool_use`, `prompt_eval_count`, …) may appear only
  inside that format's translator, which lives in `Langertha::Skeid::Protocol::*`.
- Adding a client format means one request translator, one response translator, one route and
  one `api_format` string. It never means a second upstream code path.
- Tool calls are modelled by `Langertha::Tool` / `ToolCall` / `ToolChoice`, not by Skeid. A
  format Langertha cannot express is a Langertha ticket, not a parser in the proxy.

## Consequences

- Skeid's blast radius per new engine is zero: an engine that speaks the OpenAI dialect works
  by configuration alone.
- The OpenAI dialect is load-bearing. If a provider diverges from it in a way translation
  cannot absorb, that is an architectural event, not a patch — it needs a new ADR.
- Anthropic and Ollama streaming is refused with `501` rather than half-supported (ADR 0005
  explains why the seam is drawn there): translation and SSE re-chunking have not been made to
  coexist, and a partially correct stream is worse than a clear refusal.
- Response fidelity is bounded by the translation, not by the upstream. Fields no translator
  maps are dropped, deliberately and visibly, rather than leaking a foreign dialect to a client
  that cannot parse it.
