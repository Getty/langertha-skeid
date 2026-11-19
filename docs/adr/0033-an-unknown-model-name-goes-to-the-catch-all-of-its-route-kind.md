# ADR 0033 — An unknown model name goes to the catch-all of its route's kind

- Status: accepted — not yet implemented (skeid k129)
- Date: 2026-11-19
- Tags: routing, config, aliases, policy, usage

---

## Context

A small Skeid often fronts exactly one chat model and one embedding model. Its clients are
tools that were configured with some model name — `gpt-4o`, `qwen3`, `text-embedding-3-small`,
`nomic-embed` — and many of them cannot be told another one. Today such a request ends as
`503 model_not_found`: the name selects no node.

An alias (ADR 0008) solves this for names known in advance, one entry per name. It cannot say
"whatever name comes in": the operator does not know the names, and the list never ends.

What the request is for is not in doubt, though. A request to `/v1/embeddings` wants
embeddings whatever it calls the model, and with one embedding model there is one place it can
go.

## Decision

**`routing.catch_all` names, per kind of route, the model an unknown model name is routed to.
Only a name that matches nothing is bent; from there the request is the request for the
target.**

```yaml
routing:
  catch_all:
    chat: qwen3.8-flash          # a node model or an alias
    embeddings: qwen3-embedding-4b
```

- **Off by default.** Without the key, and for a kind the key does not name, nothing changes:
  routing, answers and usage events are what they were. Removing the key with a reload turns
  it off again, like every `routing` key.
- **The kind comes from the route, never from the name.**
  - `chat`: `/v1/chat/completions`, Anthropic `/v1/messages`, Ollama `/api/chat` and
    `/api/generate`.
  - `embeddings`: `/v1/embeddings`, Ollama `/api/embed` and `/api/embeddings`.
  - `/v1/completions` and `/v1/responses` are not routes of Skeid today; a text or responses
    route added later counts as `chat`.
  - Every other route is not bent: audio, rerank, documents, realtime and the MCP gateway keep
    answering an unknown name as before. `chat` and `embeddings` are the only keys; any other
    key in `catch_all`, and a target that is not a non-empty string, fails the config load.
- **Only an unknown name is bent.** A name is known when it is an alias, or the `model` of a
  chat-kind node in the inventory — healthy or not, reachable for this key or not. A known
  name keeps its normal routing in every respect: a model whose nodes are down stays `503`, a
  model the key may not reach stays `403`. A chat-kind node without a `model` serves every
  name, so with such a node no name is unknown and the catch-all never applies. A request with
  no model name at all carries a name that matches nothing and is bent as well.
- **Bent once, then an ordinary request for the target.** The target replaces the requested
  name before routing and is not looked up in the catch-all again. Everything after that is
  what a client asking for the target by name gets: the alias tiers, the wait, admission, the
  node's served model in the upstream body (ADR 0023).
- **Policies keep priority.** The key's policy is applied to the target, not to the name the
  client sent: a key whose `models` do not grant the target, or whose `deny_tags` forbid every
  node serving it, gets the same `403` it would get asking for the target by name. The
  catch-all grants nothing. The key's request rate applies unchanged.
- **The target is not checked at config load.** Like an alias tier's model it may name
  something no node serves yet — a node file (ADR 0031) or a later reload can bring it. Until
  then a bent request ends as the target's `503 model_not_found`.
- **The answer names the real target.** The `model` field of the answer is the one a request
  for the target gets — the served model on the OpenAI face, the target on the translated
  faces — never the name the client made up. An error names the target too.
- **The usage event carries both names.** `requested_model` stays the name the client sent.
  A new field `routed_model` is the catch-all target the request was routed under; `model` is
  the served model as always. `routed_model` is set only on a bent request: an event without
  it was not bent, which is what tells a bent request from an alias request (both have
  `requested_model` differing from `model`). The DBI stores get a nullable `routed_model`
  column, added to an existing table like the columns before it; `jsonlog` writes the key only
  when it is set.
- **The model lists do not change.** `/v1/models` and `/api/tags` list the node models and the
  aliases, as before; the catch-all is not a name. The provider manifest (ADR 0015) is
  unchanged. `GET /skeid/config` shows the `catch_all` in effect.

## Alternatives

- **A wildcard alias (`"*"`).** One mechanism less, but an alias has no notion of the route:
  one wildcard would send an embeddings request to the chat model. And an alias is a name a
  client may ask for and sees in `/v1/models`; the catch-all is neither.
- **Deriving the target instead of configuring it** ("if there is exactly one chat model, use
  it"). Skeid cannot tell a chat model from an embedding model — both are chat-kind nodes
  matched by `model` — and a routing rule that silently switches off when a second node is
  added is a surprise. The operator names the target.
- **Applying the policy to the requested name.** A key with a `models` list would never be
  bent, since no made-up name is on it; and a key without one would be bent past nothing. The
  target is what the request reaches, so the target is what the policy judges.
- **Keeping the requested name in the answer.** Some clients compare the answer's `model` with
  what they sent, most do not. Reporting a model that was not the one that answered hides the
  bend from the one party that could notice it.
- **No new usage field: `model` already is the served model.** Then a bent request looks like
  an alias request, and when the target is an alias its name is in no field at all.

## Consequences

- A typo in a model name no longer fails; it gets the catch-all's model. That is the feature,
  and the reason it is opt-in.
- A name stops being bent the moment a node or an alias of that name appears — also through a
  node file. A node file that adds a model-less node switches the catch-all off for everyone;
  such a node already takes every unknown name today.
- A typo in the catch-all target shows up as `503` on the first bent request, not at load.
- Reports that group by `requested_model` grow one row per made-up name; `routed_model` is the
  column to group bent traffic by.
- The usage schema gains a column (ADR 0004); stores of an older Skeid get it on the next
  start with `auto_migrate`.
