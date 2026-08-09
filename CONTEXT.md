# Skeid Routing, Metering & Key Resolution

The vocabulary Skeid is written in. Exists because three strands meet in one process and each
brings a word the others already use for something else: **routing** (which upstream serves
this request), **metering** (what did it cost and who owes it), and **key resolution** (how a
secret reaches a request without ever touching disk). Use these words in code, tests, tickets
and ADRs.

## Language

### Topology and routing

**Node**:
One upstream LLM endpoint — url + model + engine id + weight + max_conns + health + tags, as
declared in the YAML config or pushed through the admin API. The unit of routing.
_Avoid_: server, instance, backend, provider.

**Engine ID**:
The Langertha engine that defines a node's *upstream* wire dialect (`openai`, `vllm`,
`sglang`, `anthropic`, `ollama`, …). A property of the node, never of the client.
_Avoid_: provider, vendor, driver, type.

**Model**:
The model name a client asks for and a node advertises. The primary routing key; a node with
no model matches any model.
_Avoid_: engine, deployment.

**Tag**:
A label on a node (`local`, `gb10`, `cloud`, `groq`) that policy and tiers group by. Grouping is
always by tag, never by node id — ids name machines, tags name properties, and policy is written
about properties. A **selector** lists the tags a node must carry, all of them.
_Avoid_: label, group, class, pool.

**Alias**:
A client-facing model name defined as an ordered list of **tiers**. This is how a made-up
product name and "that cloud is the fallback for this model" become one mechanism. A model with
no alias is not special-cased — it resolves to a single implicit tier.
_Avoid_: virtual model, mapping, route.

**Tier**:
One step of an alias: a tag selector, the model to ask those nodes for, and how long to wait
for capacity before falling through to the next. Ordering encodes preference — cheapest or
closest first.
_Avoid_: fallback, priority, level.

**Served model** vs **requested model**:
The name a node is asked for, versus the name the client used. They differ whenever an alias is
involved. Cost is priced on the served model; a customer is billed for the requested one. Usage
events carry both, and neither may be dropped in favour of "the model".
_Avoid_: bare "model" anywhere an alias could be in play.

**Route key**:
The `model|engine` tuple under which one weighted round-robin cursor lives. Two different
route keys never share a cursor.
_Avoid_: session, channel, pool.

**Routing**:
Choosing which node serves a request: weighted round-robin across the eligible nodes.
Load balancing is one routing strategy, not the concept.
_Avoid_: load balancing, dispatch, scheduling.

**Eligibility**:
Static fitness — the node matches the requested model and engine and is flagged healthy. Says
nothing about whether it can take the request *now*.
_Avoid_: availability (that is the dynamic half).

**Admission**:
Dynamic fitness — an eligible node has a free slot. Both the local guardrail (`inflight <
max_conns`; `max_conns <= 0` means unlimited) and the node's **capacity reading**, if there is
a current one, have to allow it. Routing picks among eligible nodes; admission decides whether
the pick stands.
_Avoid_: rate limiting, throttling, quota.

**Inflight**:
Per-node count of started-but-unfinished requests, raised by `request.start` and lowered by
`request.finish`. What *this process* sent — exact for one Skeid in front of one node, and an
undercount the moment anything else shares it.
_Avoid_: load, queue depth, connections.

**Worker share**:
This process's slice of a node's `max_conns` under `--workers N` — the configured value divided
by N. `max_conns` names what the *node* may take; the share is what one process may send.
_Avoid_: quota, limit, per-worker max_conns.

**Capacity probe**:
How a node's real occupancy is found: `inflight` (default), `ratelimit` (read off responses
already in hand), `prometheus` (polled from vLLM/SGLang metrics), or `custom`. Never runs on
the request path.
_Avoid_: health check, monitor, scraper.

**Capacity reading**:
What a probe reported — `used`, `limit`, an optional `retry_after`, when it was taken, and
which probe took it. Expires after `capacity_max_age_ms`, because a stale reading is worse than
none. May only ever *narrow* what `max_conns` allows.
_Avoid_: metrics (that word means the usage/ops counters), load average.

**Backoff** (`retry_after`):
A node is not to be sent anything until a moment in the future — what a provider's `429` or
`Retry-After` means. Distinct from **Saturation**: nothing of ours is outstanding, so waiting
for a slot would not help. It never touches **Health**.
_Avoid_: cooldown, circuit breaker, ban.

**Saturation**:
Every eligible node is at `max_conns`. The client waits up to `route_wait_timeout_ms` for a
slot and then gets `429 rate_limit_error`. Distinct from *no eligible node*, which is an
immediate `503 model_not_found`.
_Avoid_: overload, backpressure, queueing.

**Health**:
An operator-set flag on a node (`set_node_health`, admin API), not a probe result. Skeid does
not poll upstreams; an unreachable node stays "healthy" until someone says otherwise.
_Avoid_: liveness, readiness, up/down.

### Protocols

**API format** (client protocol):
The dialect the *client* speaks to Skeid: OpenAI (`/v1/chat/completions`, `/v1/embeddings`),
Anthropic (`/v1/messages`), Ollama (`/api/chat`, `/api/tags`). A property of the request.
_Avoid_: engine, provider, frontend API.

**Translation**:
Mapping a non-OpenAI client request into the OpenAI request Skeid forwards upstream, and the
upstream response back into the client's format. One direction pair per API format, and the
only place a format-specific field name may appear.
_Avoid_: adapter, shim, conversion layer.

**Upstream**:
The node side of a request. The client side is the *client* or *caller* — never "backend".
_Avoid_: backend, origin, remote (except in `SKEID_REMOTE_KEY_REF`, kept for compatibility).

**SSE relay**:
Streaming responses pass through byte-for-byte; Skeid parses the chunks only to accumulate
usage and content size. Only the OpenAI **API format** streams — a `stream: true` request in
the Anthropic or Ollama format is refused with `501`, because streaming and **Translation**
have not been made to coexist yet.
_Avoid_: proxying, piping (too vague about the parse-but-don't-modify contract).

**TTFT**:
Time to first token — request received to first content byte written to the client. The
latency number that matters for a proxy; distinct from **duration**, the whole-request time
that lands in the usage event.
_Avoid_: latency (unqualified), response time.

### Metering

**Usage event**:
One record per forwarded request: identity, node, model, status, duration, tokens, cost. The
billing unit and the reason Skeid exists between a client and a node.
_Avoid_: log line, metric, sample.

**Usage store**:
The pluggable sink for usage events — `jsonlog` (recommended), `sqlite`, `postgresql`, or a
caller-supplied callback. Swapping it must never change what an event *means*.
_Avoid_: database, logger, backend (that word is taken by the store's own `backend` key,
which names the driver, not the concept).

**Node metrics**:
In-memory per-node counters (started / ok / error / duration total) for operational visibility.
Volatile, never billed, lost on restart. Not a usage event.
_Avoid_: usage, stats, telemetry.

**Metrics normalization**:
Turning whatever token counts an upstream reports into input / output / total. Cost is priced
from `model_pricing` at record time and stored on the event, so a later price change never
rewrites history.
_Avoid_: parsing, mapping.

### Keys and identity

**Key broker**:
The contract that resolves a key reference into a secret, in memory, at the moment it is
needed. `KeyBroker::OpenBao` is the implementation; the interface is what code depends on.
_Avoid_: vault client, secret manager, key store.

**Key reference** (`api_key_ref`):
An opaque path that *names* a secret (`secret/skeid/remote/openai`). Config, ticket text and
log lines may carry a key reference; they may never carry what it resolves to.
_Avoid_: key path, secret name, key id (that word means the caller).

**Customer key ID** (`api_key_id`):
The caller's identity, derived from the API key they presented (`skeid keyid` prints it). It
selects whose usage this is *and* which routing policy applies; it is not itself a credential.
A client-supplied `x-skeid-key-id` names it only where `trust_key_id_header` says something in
front of Skeid already authenticated the caller.
_Avoid_: API key, user, tenant, account.

**Policy**:
What a customer key may reach: an optional list of models it may ask for, and the node tags it
may not be served from. Named profiles are the standard setups; a key takes one, optionally
overriding single fields, or takes the default.
_Avoid_: plan, tier (that word means a step in an alias), quota, permission set.

**Denied tag** (`deny_tags`):
A tag a key's policy forbids. Filters node *selection*, not merely the plan — so a denial
holds however the request is spelled.
_Avoid_: blocklist, excluded tag.

**Refusal**:
The answer when a policy does not grant what was asked: `403`, `permission_error`. Distinct
from saturation (`429`) and from nothing being able to serve the model (`503`) — the three
tell a client three different things to do.
_Avoid_: rejection, denial (as a status).

**Admin API key**:
The single shared secret gating `/skeid/*` control-plane routes. Never a customer identity,
never an upstream credential.
_Avoid_: master key, root token.

**AppRole token lifecycle**:
Container boots with `role_id`/`secret_id` → logs in → holds the token in memory → renews on a
timer. Renewal failure kills the process so the container restarts with a fresh login. The
absence of an on-disk token is the feature.
_Avoid_: session, login cache.

### Control surface

**Function dispatch** (`call_function`):
Skeid's internal command surface — `route.state`, `route.next`, `request.start`,
`request.finish`, `usage.record`, … Every dispatch also triggers a config staleness check.
_Avoid_: API, RPC, tool call (that means an LLM tool call here).

**Config reload**:
The YAML config is re-read when its mtime changed, on function dispatch. Node inventory is
live state; the file is one of its sources, the admin API is the other.
_Avoid_: hot reload, restart, refresh.

## Relationships

- A **Node** carries exactly one **Engine ID** and at most one **Model**; **Routing** groups
  nodes by **Route key**, never by node id.
- **Eligibility** is computed from config state; **Admission** from **Inflight**. A request is
  routed only when both hold — that is why `route.next` and `request.start` are two calls and
  the second may fail after the first succeeded.
- **Saturation** is a property of the eligible set, not of a node: one busy node is not
  saturation if a sibling can take the request.
- A **Capacity probe** narrows **Admission** and never **Health**. A rate-limited or full node
  is busy, not broken — and an error-driven health flag would have nothing to flip it back.
- A **Usage event** is written once per forwarded request, after `request.finish`, whatever the
  outcome — errors are billable events too, with `ok = 0`.
- **Node metrics** and **Usage events** count the same requests and are never reconciled: one
  is volatile operations data, the other is durable billing data. Don't derive one from the
  other.
- The **Key broker** is consulted per request for a **Customer key ID** and per node for an
  `api_key_ref`. Neither result is cached to disk, and only the **Key reference** — never the
  resolved value — appears in config, logs, or usage events.
- A **Policy** attaches to a **Customer key ID**, and that id is derived from what the caller
  presented. Anything a client can set freely must never name it: the policy would be advice,
  not a boundary.
- A **Policy** narrows **Eligibility**, never **Admission**. A denied node is not a busy node,
  so a policy failure is a **Refusal**, and running out of permitted capacity stays a 429 —
  falling through to a denied node "because everything else is full" is the failure this
  distinction exists to prevent.
- **API format** governs the client edge, **Engine ID** the upstream edge. A request can enter
  as Anthropic and leave as OpenAI; that crossing is **Translation** and it happens in exactly
  one place.

## Example dialogue

> **Dev:** "All three nodes for `gpt-4o-mini` are busy. Do I mark them unhealthy so routing
> skips them?"
> **Owner:** "No — busy is **Admission**, unhealthy is **Health**. Health is an operator
> statement about a node; **Inflight** is what capacity looks like right now. Flipping health
> on load would make a transient full queue look like an outage, and nothing would flip it
> back."
> **Dev:** "So the client just gets a 503?"
> **Owner:** "It gets nothing yet — that is **Saturation**, so it waits up to
> `route_wait_timeout_ms` and then gets a 429. A 503 means no **eligible** node exists at all,
> which is a config or model-name problem, not a load problem. Two different failures, two
> different fixes, so they must never share a status code."

## Flagged ambiguities

- **"engine"** was used for three things: the Langertha engine class, a node's upstream
  dialect, and the client's request format. Resolved: **Engine ID** is the upstream dialect
  only; the client edge is **API format**. Config keys keep the name `engine` for the node
  field — that one is correct.
- **"key"** covers four unrelated things: **Customer key ID** (identity), the upstream
  provider secret behind a **Key reference**, the **Admin API key** (gate), and the **Route
  key** (cursor bucket). Never write bare "key" in new code; take the qualified name.
- **"health"** currently only ever changes by hand. ADR 0009 settles the narrow case: a
  provider's `429` adjusts a capacity probe and a backoff timer, never the health flag — a
  rate-limited node is busy, not broken. Whether repeated *errors* should demote a node is
  still open, and still needs its own ADR before an error handler writes to that flag.
- **"model"** becomes two things once aliases exist (ADR 0008): the name a client asks for and
  the name a node serves. Where both can appear — usage events, reports, log lines — they are
  **requested model** and **served model**. Bare "model" is only safe where no alias layer is
  involved.
- **"backend"** appears both as the usage-store driver name (`backend: postgresql`, correct)
  and colloquially for an upstream node (wrong). Upstream side is **Node**.
