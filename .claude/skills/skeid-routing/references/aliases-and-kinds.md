Read this when working on model aliases and tiers, `routing.catch_all`, a node `kind` or the `documents` routing key.

## Aliases and tiers

A requested model resolves to an ordered **plan** of tiers, tried until one admits the request
(ADR 0008). A model without alias is one implicit tier selecting on its own name with the global
wait — so an aliasless config routes exactly as before.

```yaml
aliases:
  house-model:
    tiers:
      - tags: [local]
        model: qwen3-32b            # the model the node is asked for
        wait_ms: 200                # wait this long for a local GPU before paying for cloud
      - tags: [cloud, groq]
        model: llama-3.3-70b-versatile
```

`wait_ms` defaults to **0** — tiers mean "try here, then there"; waiting is opt-in. A tier
without `model` selects on the alias name. `tiers` may be a bare arrayref.

The two ways a tier fails differ, and that is the whole design:

- **No eligible node** → next tier immediately. Waiting cannot conjure a node.
- **Eligible but none admitted** → wait this tier's `wait_ms`, then fall through.
- Plan exhausted, no tier ever had an eligible node → `503 model_not_found`.
- Plan exhausted, some tier did → `429 rate_limit_error`.

Requested vs served model diverge here: the upstream body carries the served model, the usage
event both (`model`, `requested_model` — skill `skeid-usage`).

## Catch-all

`routing.catch_all: { chat: <name>, embeddings: <name> }` (ADR 0033) routes an **unknown** model
name to the target of the route's kind. Off unless configured; a routing key like the others
(`%ROUTING_SETTINGS`, a removed key turns it off), only `chat` and `embeddings`, anything else
fails the load. The target's existence is not checked.

- The kind is the **route's**, not a node kind: `chat` = `/v1/chat/completions`, `/v1/messages`,
  `/api/chat`, `/api/generate`; `embeddings` = `/v1/embeddings`, `/api/embed`, `/api/embeddings`.
  No other route is bent. Never pass it as `kind` to `route_plan` — that one is the node kind.
- `catch_all_target($name, $route_kind)` answers the target or nothing. Known = an alias or the
  `model` of a chat-kind node, health and policy ignored; a model-less chat-kind node makes every
  name known; an empty name is unknown. The node models are cached per inventory generation
  (`_known_node_models`) — no inventory scan per request.
- The proxy bends once, before `_begin_route_async` (`_catch_all` in `Proxy.pm`), so nothing sits
  between `request.start` and `request.finish`. From there it is a request for the target: the
  policy `403`, the rate, admission, the errors and the translated answer all name the target.
- Usage: `requested_model` = what the client sent, `routed_model` = the target, only on a bent
  request (skill `skeid-usage`). `/v1/models`, `/api/tags` and the manifest do not show the
  catch-all; `GET /skeid/config` does (`catch_all`, only the kinds configured).

## Node kind and the routing key `documents`

A node's `kind` (`chat` default; `documents` = docling-serve, ADR 0028) is a selector axis beside
model, engine and tags. `route_plan(kind => …)` puts the kind on **every** tier, whatever an alias
says; `_route_entry` keeps only nodes of exactly that kind, and a documents selection ignores the
node's `model`. The kind is part of `_route_key`, so a chat model called `documents` and the
documents route never share a cursor. A chat selection no longer takes a node with an empty
`model` of another kind — the invariant the separation rests on (`t/88`, "kind keeps chat and
documents nodes apart").

The documents routes have no model name: they are planned and authorised under the fixed **routing
key** `documents` (`Protocol::Documents->routing_key`). It goes through the same policy check as a
model: `models: [qwen, documents]` grants it, a key whose `models` list leaves it out gets `403`
before a node is picked, `deny_tags` apply, an alias named `documents` tiers the nodes by tags.
The alias is excluded from `list_models`, documents nodes list no model, `_manifest_model_reachable`
selects `kind => ''`. A new kind is a row in `Protocol::Documents`'s `%KIND`, not a branch.
