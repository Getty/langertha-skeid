Read this when bringing up, debugging or changing the example stack in `examples/service/` (`docker-compose.yml`, `init-skeid.sh`, `.env`).

`examples/service/docker-compose.yml` — three services plus a one-shot init:

| Service | Host port | Purpose |
|---|---|---|
| `openbao` | 5501 → 8200 | dev-mode vault: **in memory**, root token `BAO_DEV_ROOT_TOKEN_ID` |
| `postgres` | 5533 → 5432 | usage store |
| `skeid` | 5591 → 8090 | the proxy, `${SKEID_IMAGE:-raudssus/langertha-skeid:latest}` |
| `skeid-init` | — | `profiles: [init]`, runs `init-skeid.sh` once in the **openbao** image |

```bash
cd examples/service && cp .env.example .env   # set SKEID_GROQ_KEY
docker compose up -d openbao postgres
docker compose run --rm skeid-init            # prints OPENBAO_ROLE_ID / OPENBAO_SECRET_ID -> .env
docker compose up -d skeid
docker compose logs -f skeid
```

`init-skeid.sh` (POSIX sh, `bao` CLI, root token as `BAO_TOKEN`): writes the `skeid-keys` policy
(`read` on `secret/data/skeid/*`, `list` on `secret/metadata/skeid/*` — KV v2 paths; a policy on
the logical `secret/skeid/*` would deny every read), enables `approle`, creates role
`skeid-service`, stores `SKEID_GROQ_KEY` / `SKEID_OPENAI_KEY` / `SKEID_ANTHROPIC_KEY` at
`secret/skeid/remote/<provider>` when set (value on stdin, `api_key=-`), and prints `role_id` +
`secret_id`. It needs nothing from the Skeid image, whose `perl:*-slim` base has no PostgreSQL
client and promises no `curl` — which is also why the `skeid` healthcheck is a
`perl -MHTTP::Tiny` one-liner. It creates no table and stores no customer keys: Skeid never
looks a customer key up, and `names:`/`keys:` in `skeid.yaml` hold ids from `skeid keyid`.

Dev mode forgets everything on restart: after the `openbao` container restarts, run
`skeid-init` again and replace both ids in `.env`. The role's `secret_id` has no use limit and
no TTL, so a Skeid restart after `token_max_ttl` (24h) logs in again with the same one.

The printed `role_id`/`secret_id` go into a **local, untracked** `.env`; only `.env.example`
may be committed — `git ls-files examples/service/.env` must print nothing (ADR 0003). The dev
root token and the Postgres password (`POSTGRES_PASSWORD`, also handed to Skeid as
`SKEID_USAGE_DB_PASSWORD`) are placeholders — a real deployment overrides both and does not run
OpenBao in dev mode.

The stack must not override the image's `STOPSIGNAL SIGQUIT` (see `config.md` and `node.md`).
It writes nothing locally (usage goes to PostgreSQL) and mounts its config `:ro`.
