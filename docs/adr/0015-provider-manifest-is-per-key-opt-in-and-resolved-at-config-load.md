# ADR 0015 — The provider manifest is per key, opt-in, and resolved at config load

- Status: accepted — implemented (skeid #29); Ollama face carries `format` since skeid #46 (see Update)
- Date: 2026-09-25
- Tags: manifest, provider-discovery, policy, config, security

---

## Context

langertha-raider ADR 0007 has a provider publish `/.well-known/langertha.json` so that
`raider --provider host.tld` can find the endpoints, dialects, models and auth mechanism. For
Skeid, "a filtered manifest per authorisation context" is the whole requirement. Core ADR 0029
fixes the schema, the value objects and the Builder. Skeid decides what it publishes to whom.

Skeid has no notion of an authenticated customer beyond the key it is shown. Any key derives
an id (ADR 0008), and an unlisted key routes under `default_policy`. So "may use Skeid" cannot
mean "may see a catalog". If the manifest were derived from the routing policy, every key on
the default policy would be shown every model that policy allows, and a customer given a
richer policy would advertise it to anyone who asked with their key.

## Decision

**Nothing is published unless the config opts in, and then only per key, by explicit list.**

```yaml
manifest:
  enabled: true
  public_url: https://llm.example.com
keys:
  alice: { policy: burstable, manifest: { models: [house-model, qwen3-32b] } }
```

- The global `manifest:` section switches the route on. It holds the public URL, and
  optionally `provider_id`, the faces to publish and per-model capability claims. It does not
  grant anything by itself.
- A key sees models only through its own `keys:` entry's `manifest.models`. There is no
  default grant, no wildcard and no "everything the policy allows". A key on the default
  policy is not listed at all, so it has no manifest.
- The grant cannot exceed the policy. At load, each listed model must be reachable for that
  key: the policy grants the name, and a node a permitted tier selects serves it (deny_tags
  applied, health ignored). A listed model the key could not route to fails the load. That
  includes a raw node model behind a denied tag. Otherwise the manifest would promise
  something the request path then refuses with a 403.
- **Resolved at config load, keyed by key id.** Each key's manifest is built with
  `Langertha::Manifest::Builder` and validated by core's value objects once. It is stored as
  canonical JSON under the key id its key derives to. This map is the cache, and it can only
  answer for the id of the key the caller actually presented. A reload rebuilds it
  wholesale, and all or nothing: a config that fails anywhere, the manifest check included,
  leaves the previous config in force, manifests and node inventory alike.
- **The route never reloads the config.** Like `/v1/models`, it serves what the last load
  resolved. A public route must not be a way to run the config loader, which also restarts
  the node probes, on every anonymous GET.
- The HTTP answers are `Cache-Control: private, no-store` and vary on every
  identity-carrying header, so no cache in front of Skeid can mix them up either. 401 and 403
  answers are included.
- **Unauthenticated: 401, not a minimal manifest.** ADR 0029 would allow a manifest with
  endpoints and auth but no models. That manifest would still publish Skeid's faces and
  public URL to anyone, and the ticket's rule is "only what is explicitly enabled". A key
  without a grant gets 403 (ADR 0008's refusal status). A disabled manifest, or a Langertha
  without `Langertha::Manifest`, gets 404 whoever asks.
- **What goes in.** One endpoint per face Skeid serves, all under `public_url` with one
  `api_key` auth entry, because every face takes `Authorization: Bearer` / `x-api-key`:
  - `openai`: `openai-chat` at `/v1`;
  - `anthropic`: **`anthropic-compat`**, because `/v1/messages` is translated to the OpenAI
    upstream call and carries no `output_config.format`, which is the shim contract of
    ADR 0029;
  - `ollama`: `ollama` at the root.

  Capabilities default to `chat` + `streaming`, which every face supports. Other claims are
  the operator's and are limited to the Builder's model-capability allowlist. They are then
  **cut per face** to what that face's translator carries upstream. A claim holds "at that
  endpoint" (ADR 0029) or is not made there. Each face's list lives with its translator
  (`manifest_endpoint`, as in knarr k14), per ADR 0001:
  - the OpenAI face passes the body through, so it carries every openai-chat flag;
  - `/v1/messages` drops `output_config`, `thinking`, `cache_control` and
    `disable_parallel_tool_use`;
  - `/api/chat` drops `format` and `options.seed`, and its dialect has no `tool_choice`.

  A claim that no face carries fails the load. Never published: node URLs, node ids,
  upstream key references, internal hosts, customer keys.

## Consequences

- The manifest stays a claim, not a probe (raider ADR 0007): it lists what a key may ask for,
  not what is healthy right now. Nodes added later through the admin API do not change it
  until the next config load.
- A translator that starts carrying a field (say `output_config.format` on `/v1/messages`)
  has to add the flag to its `manifest_endpoint`, or the manifest under-claims it.
  `t/46-provider-manifest.t` pins each face's published set.
- Core's manifest is newer than the released Langertha (0.503) the cpanfile pins. The code is
  runtime-gated (`eval require`), and the route answers 404 until core ships it; the cpanfile
  pin moves with that release.
- `t/46-provider-manifest.t` proves the separation with two keys served alternately: the
  narrower key's manifest never names the richer key's models. It also proves the leak
  checks (no node URL, id or key reference in the body) and the load errors. Serving the
  wrong key's cached entry was verified to fail it.

## Update (skeid #42, #46): what the faces carry now

`/api/chat` and `/api/generate` no longer drop `format`: it goes upstream as `response_format`,
so the Ollama face publishes `response_format_json_object` and `response_format_json_schema`.
Every face may publish `image_input` since images are translated on the Anthropic and Ollama
faces. `options.seed` is still not carried. The per-face lists stay in each translator's
`manifest_endpoint`, as decided.
