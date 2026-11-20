Read this when changing the `Dockerfile`, building a local test image, or debugging file ownership and mounts in the container.

Built in every `dzil build` and pushed by `dzil release` through the bundle's
`docker_image` (`Dist::Zilla::Plugin::Docker::API`; see the release rule — never run a release
yourself). Tags: `raudssus/langertha-skeid:<version>`, `:<major>`, `:latest`. The release path
passes no build arguments; a source override for an unreleased Langertha
(`--build-arg LANGERTHA_SRC=…`, a CPAN author path or tarball URL) only works with a manual
`docker build`. For a local test image:
`docker build -t raudssus/langertha-skeid:test .`, then `SKEID_IMAGE=raudssus/langertha-skeid:test`
in `examples/service/.env` to run the compose stack on it.

Two stages: `build` has `build-essential` and `libpq-dev` and runs `cpm` with
`--top-level-relationship requires,recommends`, so `DBI`, `DBD::Pg` and `DBD::SQLite` come
from the `cpanfile` and nowhere else; the final stage takes `site_perl` and `/opt/skeid` from
it and adds only `libpq5` and `jq`. What the `perl:*-slim` base brings stays (`make`,
`libssl-dev`, `zlib1g-dev`, no compiler). The final stage is the default target, so
`docker build` needs no `--target`. A module with XS that links a new shared library needs
that library in the final stage too — the `perl -M…` line there fails the build when one is
missing.

The process runs as `skeid`, uid and gid 10001 (`USER` is numeric so an orchestrator can verify
non-root). It owns `/var/log/skeid/events` (jsonlog) and `/var/lib/skeid` (sqlite) and nothing
else; `/opt/skeid` is root's and read-only to it. A named volume mounted on either directory
takes that ownership, a bind mount keeps the host's — the directory must be writable, and a
mounted `skeid.yaml` readable, for uid 10001. The compose stack writes nothing locally (usage
goes to PostgreSQL) and mounts its config `:ro`.
