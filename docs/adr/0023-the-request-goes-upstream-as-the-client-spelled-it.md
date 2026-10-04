# ADR 0023 — The request goes upstream as the client spelled it: bytes on the OpenAI face, tool schemas on the translated faces

- Status: accepted — implemented (skeid k104)
- Date: 2026-10-04
- Tags: protocols, proxy, tools, prompt, relay

---

## Context

Every chat route decoded the client's body into a Perl structure and encoded that structure
for the node. A Perl hash has no key order, and the encoder writes keys sorted, so the node
received a different text than the client sent: the same data, every object's keys in
alphabetical order.

That text is not neutral. A node renders the tool definitions into the prompt with its chat
template, in the order they arrive. A JSON schema the client wrote as `type`, `properties`,
`required` reached the model as `properties`, `required`, `type`, with `description` ahead of
`type` in every property. Two things follow:

- The prompt is not the one the client wrote, and not the spelling the model was trained on.
  On 2026-10-04 one node (Qwen3.6-35B-A3B-FP8 on vLLM) answered a request with twenty tool
  definitions in gibberish when it came through Skeid, and correctly when the client's own
  bytes were sent to the same node. Sorting the keys inside `parameters` was the whole
  difference.
- A client that reaches a node directly and through Skeid produces two prefixes for the node's
  prompt cache.

The first finding points at a fragile node, and that is being looked into on its own. It does
not change what Skeid should do: a proxy that only has to replace `model` has no business
rewriting the rest.

## Decision

**The OpenAI face forwards the client's bytes.** `/v1/chat/completions` and `/v1/embeddings`
send the request body as it arrived, with the value of the top-level `model` replaced by the
served model (ADR 0008) and nothing else touched — not the order, not the whitespace, not the
escapes. The decoded body is still what routing, admission and metering read.

Every top-level `model` is replaced, not one. A body may spell the key twice, parsers disagree
on which one counts, and a node that read the other one would be asked for a model the request
was not routed or authorized for.

**The translated faces carry the tool definitions over.** A body from the Anthropic or Ollama
face is translated (ADR 0001), so the upstream body is new and cannot be the client's bytes.
What reaches the prompt verbatim is the tool definitions, so those are kept: each tool's JSON
schema is taken out of the client's bytes and written into the upstream body as it was, inside
a definition spelled the way the function-calling wire spells it — `type`, `function`, then
`name`, `description`, `parameters`. A schema the translation changed is encoded from the data
instead; the text is only used when it still says what the translated tool carries.

Both live in `Langertha::Skeid::Protocol::RawBody`, a scanner that follows JSON structure
(strings, nesting, separators) without building anything. Bytes it cannot follow fall back to
the encoded body, so nothing that was served before is refused now.

## Consequences

- A request through Skeid and the same request sent to the node are the same prompt.
- The rest of a translated body — messages, sampling parameters — is still encoded with sorted
  keys. Chat templates read those by name, so their order does not reach the prompt.
- Rerank is unchanged: it re-encodes the body with `model` replaced. Nothing in a rerank body
  is rendered into a prompt.
- The scanner is a second reader of the body next to the decoder. It never decides what a
  request means; it only locates spans in bytes the decoder already accepted.

## Alternatives

- **An order-preserving decoder** (tied hashes, or a parser that keeps key order) would fix
  every route at once, at the cost of a slower body on every request and an encoder that has
  to honour the order too. Byte forwarding is cheaper and exact where it applies.
- **Sorting nothing but tools** on the OpenAI face would leave whitespace and escapes
  rewritten, and with them the prompt-cache prefix.
