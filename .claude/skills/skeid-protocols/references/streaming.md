Read when changing `_proxy_openai_stream`, a `Protocol::*::Stream` translator, relayed stream headers, or how a stream ends, fails or is metered.

# Streaming mechanics

`_proxy_openai_stream` serves every face. The upstream body is read raw (`Proxy::RelayContent`, so
an unchunked `text/event-stream` is not swallowed by Mojolicious's SSE parser); `data: {…}` lines
are parsed across read boundaries for content size and the verbatim `usage` block; one usage event
on completion. Without a translator the bytes are relayed as they came; with one
(`Protocol::*::Stream`) each parsed chunk goes through `->delta` and the client gets the
translator's framing and content type.

- Never rewrite a chunk on the OpenAI face. The relay is byte-transparent; anything else breaks
  client parsers and makes TTFT unmeasurable.
- `content-length`, `transfer-encoding`, `content-encoding` are stripped from relayed headers (a
  translated stream also drops `content-type`); `x-skeid-node` is added.
- Chunks go out through a drain queue, not one `write_chunk` per read — a dynamic response with no
  drain callback ends when its queue empties.
- Headers go out on the first chunk. On a translated face an upstream error status before that is
  a plain HTTP error in the client's shape; after it the failure travels in-band (Anthropic
  `error` event, Ollama error line) and the stream is `ok = 0`, as is a body cut short of its own
  framing. Every path calls `request.finish` exactly once.
- Anthropic and Ollama streams go upstream with `stream_options.include_usage`; the OpenAI face
  forwards the client's body as is. Missing usage is expected: the event gets zeroed tokens.
