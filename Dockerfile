# Build stage: compiler and libpq headers for the XS modules. Only what cpm installed and
# the checkout leave this stage.
FROM perl:5.38-slim AS build

ARG LANGERTHA_SRC=""

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/skeid

COPY . .
# requires,recommends: DBI, DBD::Pg and DBD::SQLite are what the cpanfile recommends, at the
# versions it names. chmod: the runtime user is not the owner, and a checkout made under a
# tight umask would otherwise be unreadable to it.
RUN cpanm --notest App::cpm \
    && if [ -n "$LANGERTHA_SRC" ]; then cpanm --notest "$LANGERTHA_SRC"; fi \
    && if [ -f cpanfile.snapshot ]; then SNAP="--snapshot=./cpanfile.snapshot"; else SNAP=""; fi \
    && cpm install --cpanfile=./cpanfile $SNAP \
      --global \
      --top-level-relationship requires,recommends \
      --resolver metacpan \
      --workers=$(nproc) \
      --show-build-log-on-failure \
    && chmod -R a+rX /opt/skeid

# Runtime stage: the same perl, the shared libraries the XS modules link against (libssl
# comes with the base image), no compiler.
FROM perl:5.38-slim

# A numeric USER below, so an orchestrator can verify it is not root. The two directories
# are the ones the image offers for writing: jsonlog events and a sqlite database. A named
# volume mounted there takes this ownership.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    jq \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 skeid \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /opt/skeid \
      --shell /usr/sbin/nologin skeid \
    && mkdir -p /var/log/skeid/events /var/lib/skeid \
    && chown -R 10001:10001 /var/log/skeid /var/lib/skeid

COPY --from=build /usr/local/lib/perl5/site_perl /usr/local/lib/perl5/site_perl
COPY --from=build /opt/skeid /opt/skeid

WORKDIR /opt/skeid

# Fails the build when a shared library an XS module needs is missing from this stage.
RUN perl -MDBI -MDBD::Pg -MDBD::SQLite -MIO::Socket::SSL -e 1

USER 10001:10001

EXPOSE 8090

ENTRYPOINT ["perl", "-Ilib", "bin/skeid"]
CMD ["serve", "--listen", "0.0.0.0:8090", "--config", "/etc/skeid/skeid.yaml"]
