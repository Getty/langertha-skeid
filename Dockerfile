FROM perl:5.38-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/skeid

COPY . .
RUN cpanm --notest App::cpm \
    && if [ -f cpanfile.snapshot ]; then SNAP="--snapshot=./cpanfile.snapshot"; else SNAP=""; fi \
    && cpm install --cpanfile=./cpanfile $SNAP \
      --resolver metacpan \
      --workers=$(nproc) \
      --show-build-log-on-failure \
    && rm -rf /root/.perl-cpm/ /tmp/*

EXPOSE 8090

ENTRYPOINT ["perl", "-Ilib", "bin/skeid"]
CMD ["serve", "--listen", "0.0.0.0:8090", "--config", "/etc/skeid/skeid.yaml"]
