# ADR 0031 — Nodes from a less trusted file are checked against constraints the main config sets

- Status: accepted — implemented (skeid k112)
- Date: 2026-11-12
- Tags: config, nodes, security, secrets

---

## Context

A GPU manager knows where models run and wants Skeid to route to them. The natural interface
is a file it writes — a ConfigMap `nodes.yaml` that Skeid reloads on change. Until now Skeid
read one config file, and a node entry could name any `api_key_env` and any `api_key_ref`.
Whoever can write the node list could therefore make Skeid resolve an environment variable or a
broker secret of their choosing — the admin key, a cloud provider's key — and send it as the node
key to a URL of their choosing (a security review of a downstream deployment, finding H2). The
writer of that list is less trusted than the writer of the main config: it is a running service,
not an operator.

## Decision

**The main config names each further node file together with what a node from it may say.
Skeid checks every node of such a file against those constraints; a node that breaks one is left
out, the rest of the file loads. A node file contributes nodes and nothing else.**

```yaml
node_files:
  - path: /etc/skeid/gpm/nodes.yaml
    allow_api_key_env: '^SKEID_NODE_GPM_[A-Z0-9_]+_API_KEY$'   # default: none allowed
    allow_api_key_ref: false                                   # default false
    allow_url_hosts: [ '*.cai-gpm.svc' ]                       # required
    allow_kinds: [ documents, chat ]                           # default [chat]
```

- **Deny by default.** Without `allow_api_key_env` no node of the file may name a variable;
  `api_key_ref` is off unless switched on; `allow_url_hosts` is required. `*` is exactly one DNS
  label, the host is matched whole, the URL must be `http(s)` and carry no credentials.
- **Fields are allowlisted.** `capacity` is not among them: a probe polls a URL of the node's
  choosing and a custom probe names code. Values the main config would refuse (unknown engine,
  rerank format, a key header that is no token) reject the node instead of failing the load —
  a less trusted file must not be able to break the trusted config.
- **No client credential.** A node from a node file that names no key source does not get the
  documented pass-through of the client's `Authorization` / `X-Api-Key`: its URL was chosen by
  the less trusted writer, and with `client_auth` that header is the customer's Skeid key.
- **Reading is bounded.** A node file larger than 1 MiB, nested deeper than 16 levels or using a
  YAML alias is refused whole: a few hundred bytes of nested aliases expand beyond what the
  config digest, which walks every node on the event loop, can afford.
- **The main config wins ids.** A node whose id the main config or an earlier node file already
  uses is rejected (`id_taken`); a node file cannot shadow a trusted node.
- **Per node, then per file.** A broken node is rejected alone. A file version that does not
  parse, says anything but `nodes`, or is gone keeps that file's last good nodes — whole or
  nothing. Neither fails the reload of the main config.
- **Reported by position and rule, never value.** `GET /skeid/config` lists per file the nodes
  accepted and each rejection as `{position, rule}`; the log says the same once per read. The
  value that broke a rule may be the very secret name the rule exists to keep out.
- **Change detection is the file's own.** A node file is re-read when its mtime, size or inode
  changes (a ConfigMap swaps a symlink) — with a `config_file` on the next dispatch, with a
  `config_loader` on its next run. What the files contributed is part of the config fingerprint,
  so a loader's version does not hide a node file change.
- The merged nodes are the `nodes` section: an unchanged contribution keeps the node list (skeid
  #38), and nodes from the admin API are replaced as by any declared `nodes` section. When only
  the node files' contribution changed, every node whose entry is unchanged keeps the health an
  admin set on it; a changed main `nodes` section is the declared state again, as before.

## Alternatives

- **A deployment's own Skeid class reading the list itself** (ADR 0030, proposed). It would keep
  the logic in the deployment, but every deployment with a second writer needs the same
  constraint; it belongs in generic Skeid. A class can still read nodes from elsewhere.
- **A sidecar merging the two files with the allowlist.** What a downstream deployment does until
  this exists; it moves the check out of the process that resolves the keys.
- **Reject the whole file on one bad node.** One bad entry from a manager would take every model
  it serves offline; rejecting per node keeps the rest serving and the report says which.

## Consequences

- A GPU manager can publish nodes without being able to choose which key goes where.
- One `stat` per node file per dispatch with a `config_file`.
- The constraints are per file; a node file that needs a broker reference must be trusted with
  every reference (`allow_api_key_ref: true`) — a reference pattern is left for when it is needed.
