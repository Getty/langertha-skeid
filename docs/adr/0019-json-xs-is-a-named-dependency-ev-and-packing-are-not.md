# ADR 0019 — Cpanel::JSON::XS is a named dependency; EV and a packed binary are not

- Status: proposed — the cpanfile half is implemented (skeid k79); the rest is a decision not to act
- Date: 2026-09-30
- Tags: performance, deployment, docker, dependencies

## Context

The maintainer asked (k79) whether Skeid can ship as one static binary, and whether that would
be faster. Packing does not change which perl runs or which event loop it drives. What can
change the request path is which XS modules the process finds at run time:

- **EV.** Without it, Mojolicious falls back to `Mojo::Reactor::Poll`, which is what the Docker
  image runs today.
- **Cpanel::JSON::XS.** Without it, `JSON::MaybeXS` and `Mojo::JSON` fall back to pure Perl.

Neither module was named in `cpanfile`. Cpanel::JSON::XS reached the image only as a dynamic
prerequisite of JSON::MaybeXS, which its `Makefile.PL` adds when a compiler is present.

`docs/bench/2026-09-30-ev-json-binary.md` measured all three questions with `bench/`, on one
process:

- **Pure-Perl JSON** costs 43 % of streaming throughput at c=16 (116.9 → 67.2 req/s) and
  doubles the streaming TTFT p99 (99 → 209 ms). The stream relay decodes every SSE frame. JSON
  requests lose 4–12 %.
- **EV versus Poll** has no consistent winner. Poll handles JSON at c=16 faster (141.5 vs
  119.7 req/s, 5 of 5 rounds), and a bare Mojolicious pass-through shows the same direction. EV
  has the better streaming tail at c=64 (p99 247–300 vs 356–435 ms, 3 of 3 rounds). The two
  are equal with 256 slow streams.
- **A PAR-packed binary** matches plain perl on the request path. It starts 0.2 s slower with
  a warm cache and 3.7 s slower cold, and uses 11 MB more RSS. It is not static: it unpacks
  80 MB, including libperl, and still links the host's glibc, libssl, libcrypto and libz. It
  only builds with `PAR_VERBATIM=1`, because PAR's POD stripper breaks the `[@Author::GETTY]`
  POD commands, and with whole-namespace `-M` wildcards, because YAML::PP and Mojolicious load
  modules by name at run time.

## Decision

1. `cpanfile` names `recommends 'Cpanel::JSON::XS', '4.20'`. 4.20 is the minimum `Mojo::JSON`
   will use. The Dockerfile already installs `requires,recommends` as top-level dependencies,
   so the image gets it by name instead of by accident, and a failed install fails the build.
   It stays a recommendation: Skeid is correct without it, only slower.
2. **EV is not added** to `cpanfile` or the image. Because the image installs `recommends`, an
   EV entry *is* a change of the image's reactor, and the measurements do not justify one in
   either direction.
3. **Skeid does not ship a packed binary.** The container image is the self-contained
   deployment. A packed file adds nothing to the request path and brings a build that breaks on
   the house POD style and on runtime module loading.

## Consequences

- Earlier dev-box reports ran EV+XS. For JSON at c=16 they are about 15 % pessimistic compared
  with the image. For streaming they are the same. Future reports should state which reactor
  was loaded.
- The EV question stays open in one place: whether its streaming-tail advantage at c=64
  survives `--workers N`, where each loop holds fewer connections. That measurement would
  reopen decision 2. Nothing else should.
- A single-file build for hosts without Docker is a distribution question, not a performance
  one. If it comes back, start from what the report records: `PAR_VERBATIM=1`, explicit
  namespaces, trim the DBD drivers, and the host still needs libssl and a compatible glibc.
