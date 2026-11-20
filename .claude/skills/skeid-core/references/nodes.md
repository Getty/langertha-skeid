Read this when adding or changing a node field, node validation, tag selection, the derived-list cache or the round-robin walk.

## Node

A node is a plain hashref in `->nodes`:

```yaml
id: openai-main        # required, unique
url: https://…/v1      # required, base url without endpoint path
model: gpt-4o-mini     # empty/absent = matches any requested model
engine: openai         # Langertha engine id, normalized via normalize_engine_id
weight: 3              # round-robin weight, min 1, integer
max_conns: 8           # admission limit; <= 0 means unlimited
healthy: 1             # operator flag, never set by error handling
tags: [local, gb10]    # grouping for selection; also accepts "local, gb10"
api_key_ref: secret/…  # key reference resolved through the KeyBroker per request
api_key_env: VAR       # fallback: key from this environment variable
capacity: { probe: … } # optional capacity probe (skill skeid-routing)
rerank_format: tei     # optional: the node's rerank endpoint speaks TEI's dialect (skeid-relay-routes)
kind: documents        # optional: a docling-serve node (skill skeid-routing)
api_key_header: X-Api-Key  # optional: the key goes raw in this header (skeid-protocols)
```

- Mutators: `add_node`, `remove_node`, `list_nodes`, `set_node_health`.
- `kind`, `rerank_format` and `api_key_header` are validated in `add_node`
  (`Protocol::Documents->normalize_kind`, `Protocol::Rerank->normalize_format`,
  `normalize_key_header`): an unknown value croaks (a failed config load), and so does a header
  that is no RFC 7230 token. `Authorization` is the default, spelled out and not kept. An absent
  `rerank_format` means the rerank route is relayed, not translated. Every check runs **before**
  `remove_node`, so a bad re-add keeps the working node (k98). They are node options, never an
  `engine` branch.

## Tags

`select_nodes(tags => [...])` = nodes carrying *every* tag (AND); no tags = all. Tags are
lowercased, trimmed, de-duplicated, order-preserving; `normalize_tags` takes a list or a
comma/space string. Routing takes the same `tags` (`pick_node`, `route_state`, `route.next`,
`route.state`) and they are part of the route key — two selections over one model never share a
round-robin cursor (base of ADR 0008 tiers).

## Derived-list cache

Matches, order and weights are reused until `_inventory_generation` changes. `add_node` and
`set_node_health` call `_bump_inventory` (a no-op health call does not bump), a `trigger` on
`nodes` catches direct assignment. Tripwire: `t/24-node-tags.t`. Cache + cursors are bounded at
256 route keys per generation, FIFO-evicted together (skeid #55), so client-chosen model names
cannot grow them.

`pick_node` is protected twice (admission re-reads `healthy` from the live node), so a stale
cache shows in `route_state`, not there — and `has_eligible` decides `503` (no wait) vs waiting
for capacity and `429`.

## Weighted round-robin

Walks a per-route-key cursor (`model|engine`, plus tags and denied tags when present) over nodes
sorted by id, skipping nodes that fail admission; each node is checked at most once per selection
whatever its weight (skeid #56). The cursor advances only on a successful pick.
