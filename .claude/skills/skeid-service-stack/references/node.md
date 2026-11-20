Read this when writing a node entry that needs an upstream key, or a realtime (`/v1/realtime`) node.

## Node config with keys

```yaml
nodes:
  - id: groq-main
    url: https://api.groq.com/openai/v1
    model: llama-3.3-70b-versatile
    engine: openai
    api_key_ref: secret/skeid/remote/groq   # KeyBroker (preferred)
  - id: local-vllm
    url: http://vllm:8000/v1
    model: qwen2.5-7b
    engine: vllm
    api_key_env: VLLM_TOKEN                 # fallback when there is no broker
```

## A realtime node

`/v1/realtime` (ADR 0029) holds a node's slot for a whole WebSocket session, minutes long, so
`max_conns` of such a node means **concurrent sessions**. Give it a node of its own (a Whisper
node serving file transcription *and* live sessions has two meanings of `max_conns`), with its
own model name:

```yaml
nodes:
  - id: whisper-live
    url: http://speaches:8000/v1        # Skeid calls ws://speaches:8000/v1/realtime
    model: whisper-live
    engine: openaibase
    max_conns: 8                         # concurrent sessions; at least the worker count
realtime:
  idle_timeout: 300
  max_session_seconds: 3600
```

Under `serve --workers N` each worker admits `max_conns / N` sessions (floor 1, ADR 0010), and a
session stays on the worker that accepted it: `max_conns: 4` with 4 workers admits one session per
worker, so a fifth is refused when one worker has two clients — size `max_conns` above what you
mean to allow. `SIGQUIT` (the image's `STOPSIGNAL`) closes open sessions `1001` and writes their
events; `SIGTERM` does not. Behind a reverse proxy the WebSocket needs `Upgrade`/`Connection`
forwarded and read/idle timeouts above `realtime.idle_timeout`.
