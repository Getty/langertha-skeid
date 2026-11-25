# ADR 0030 — A deployment carries its dispatch logic in its own Skeid class, and may pack it into one file

- Status: proposed — implemented (skeid k111), for the maintainer to accept
- Date: 2026-11-25
- Tags: architecture, routing, admission, deployment, packaging

---

## Context

Every deployment-specific dispatch decision so far became a generic config key (`route_column`,
`routed_only`, `node_source`, `documents`), and every downstream deployment then pinned the
capabilities that key needs. The next ones do not fit a key at all: ask a GPU manager where a
model is loaded, wake it, queue or refuse while the card is full. That is code, and it belongs
to the deployment, not to Skeid.

Skeid already had most of the seams. `Proxy->build_app` took `skeid => $obj`, the usage sinks
were documented override points, and `route_plan`, `pick_node`, `start_request` and
`finish_request` were methods the proxy reaches through `call_function`. But they were no
contract — nothing said which a subclass may override or what it must keep — and the pick was
synchronous, so a class could not wait on an outside answer without blocking the loop
(ADR 0005). `bin/skeid` built `Langertha::Skeid` by name.

ADR 0019 decision 3 had rejected a packed binary, measured with PAR::Packer: the same request
path, a slower start, 80 MB unpacked, `PAR_VERBATIM=1` and whole-namespace `-M` needed, and
still linked against the host's libc and libssl. That decision was about performance and about
shipping Skeid itself; a deployment that wants its class and Skeid as one file to copy onto a
host is a distribution question, which 0019 left open.

## Decision

**A deployment's dispatch logic is a `Langertha::Skeid` subclass that overrides documented
dispatch hooks. `skeid serve` serves such a class, and `skeid pack` packs it with Skeid into one
executable.**

1. **The dispatch hooks are a versioned contract**, `dispatch_hooks_version` 1, documented in
   `Langertha::Skeid` ("Dispatch Hooks"). They are the methods that already did the work, so the
   defaults are what Skeid did before, unchanged:
   - plan — `route_plan`: the tiers of a request;
   - pick — `pick_node`: one node of a tier's selector, or nothing (then the tier is waited on
     within its `wait_ms` and left, as for a full tier);
   - pick, asynchronous — `pick_node_p`: the same as a `Mojo::Promise`; the default is
     `pick_node` in a resolved promise;
   - admit or refuse — `start_request`: 1 takes the slot, 0 refuses and the proxy goes on as
     for a full node;
   - on finish — `finish_request`: exactly once per admitted request, on every path.

   An override of admit or on-finish must call the original: it is what counts and gives back
   the slot. A change to the arguments, returns or order of these calls raises the version.
   Everything else in the class may change without notice.
2. **The proxy picks through a promise only for a class that overrides `pick_node_p`**
   (`picks_async`, decided once per class). Every other request calls `pick_node` directly, as
   before. A promise on the default path costs every request a turn of the loop, and that was
   measured (below).
3. **An asynchronous pick is a path like any other.** The proxy calls it through the dispatch
   function `route.next_p`, which never dies: a `pick_node_p` that dies or returns nothing is a
   rejected promise. A rejected pick answers `502 api_error` ("Node selection failed for model
   …"), logs the reason, and admits nothing — no `request.start`, so no `request.finish` is
   owed. A client that leaves while its pick is out is let go when the pick settles, and the
   late answer admits nothing. Admission after an asynchronous pick is the same `request.start`
   as after a synchronous one: another request may have taken the slot meanwhile (ADR 0002).
4. **`skeid serve --class My::Skeid [-I DIR]`** and the config key **`skeid_class`**: the class
   `Proxy->build_app` builds. `--class` wins over the config, a packed file's class sits in
   between as the default of `--class`, and without any it is `Langertha::Skeid`. Read once at
   start; a reload does not change the class of a running Skeid. A name that is no Perl class
   name, a class not found or failing to compile, and a class that is not a `Langertha::Skeid`
   subclass stop the start with `ERROR: skeid_class …` and exit 2 — the operator asked for that
   class, as for a missing `--config` (k68).
5. **`skeid pack --class My::Skeid [-I DIR] -o FILE`** builds the file with PAR::Packer's `pp`:
   `bin/skeid` with a preamble that `use`s the class (so the scan finds it) and makes it the
   default of `--class`. It sets `PAR_VERBATIM=1` and `-M Langertha:: Mojo:: Mojolicious::
   YAML::PP::`, what ADR 0019 found it needs. PAR::Packer is a `suggests`, not a dependency and
   not in the image; without it `skeid pack` ends with an `ERROR:` line and exit 2. Two notices
   of Module::ScanDeps are dropped from pp's output, because they say nothing about the pack:
   its parser warns on an empty module name when a string literal holds a `use` (Mojo::Loader's
   deprecation message does), and it notes that Module::Runtime and Module::Implementation load
   modules at run time — which the `-M` namespaces answer.
6. This **supersedes ADR 0019 decision 3 for this purpose only**: a deployment may pack its
   class and Skeid into one file. Skeid itself still ships no packed binary, and the image stays
   the default deployment.

## Measured

On k111's first implementation (2026-11-04, dev box, `bench/`, the report
`docs/bench/2026-11-04-async-pick.md` was lost with that branch; the numbers are the card's):

- A promise-based pick on **every** request cost **−2.7 … −7.6 % req/s** against the commit
  before the change. Hence decision 2: with the direct path the default was back within noise.
- A class that **overrides `pick_node_p`** pays **3.6 – 5.7 % req/s** for its promise.
- `skeid pack` in a throwaway `perl:5.40` container, PAR::Packer 1.064: **12.7 MB**, start until
  listening **3.03 s cold** (empty PAR cache), **0.96 s warm**.

The rebuild (2026-11-25) ran `xt/author/pack.t` in the same kind of container, with Skeid's
`recommends` installed, PAR::Packer 1.064: **19.3 MB, 3.44 and 3.52 s cold, 0.98 s warm** (two
runs). The size depends on what the
packing host has installed — DBD::SQLite alone puts 12 MB, uncompressed, into the archive (its
`sqlite3.c` and `sqlite3.h` share files and its `.so`) — and the pack also carries Moose and
Class::MOP (359 files), which some dependency loads. The
request-path numbers of the rebuild are still to be measured; the defaults' path is the same
shape as on the first implementation (one boolean per request decides).

## Alternatives

- **More config keys.** What every earlier deployment decision became; it does not reach code
  that talks to a GPU manager, and every key is a capability pin downstream.
- **A role instead of a subclass.** Roles compose well, but the hooks are overrides of existing
  methods with `around`; a subclass names that relation and `isa` is checkable at start.
- **Always pick through a promise.** One code path, but a measured cost on every request of
  every deployment for a feature few use.
- **Pack a module instead of `bin/skeid`.** Would need the CLI moved into a module; the preamble
  keeps the packed file exactly `skeid`.

## Consequences

- A deployment's routing logic is Perl it owns, tested against the hook contract; Skeid's config
  stays generic. The contract is small on purpose: anything a class reaches beyond it may break.
- `skeid usage` and `skeid usage-purge` still build `Langertha::Skeid`: a class that overrides
  the usage sinks (`_store_usage_event`, `_query_usage_report`) is not used there.
- A packed file is not static (libc; libssl and libcrypto for TLS) and is built on the system it
  is to run on. It unpacks into a PAR cache on first start. A DBI usage store in a pack has no
  shipped schema file (`share/sql/` is not packed): use `jsonlog`, or `auto_migrate: false` with
  the table made beforehand.
- `skeid capabilities` lists `skeid_class`.

## Tests

`t/101-dispatch-hooks.t`: the contract and its version; without a subclass the round-robin is
unchanged and `pick_node_p` is never called on the request path; a subclass
(`t/lib/Test/Skeid/Dispatch.pm`) whose plan, pick, refuse and on-finish change routing; a
delayed `pick_node_p` that serves and finishes, while the loop serves others; a rejected and a
dying pick that answer `502` and leave every slot free; a client that hangs up while its pick is
out; `skeid_class` in the config and its errors. `t/102-cli-serve-class.t`: `serve --class -I`,
the config's `skeid_class`, `--class` winning, the error exits, and `skeid pack`'s checks.
`xt/author/pack.t` (`AUTHOR_TESTING`, needs PAR::Packer): packs a class, removes its source, and
runs the file — it listens, serves a chat request from the node only the packed class picks, and
reports size and cold and warm start.
