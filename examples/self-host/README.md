# Self-hosting katari-runtime

Minimum viable production setup for the Katari runtime. Spins up:

- `katari-runtime` from `ghcr.io/<owner>/katari-runtime`
- Postgres 17

## Quickstart

```sh
cd examples/self-host
cp .env.example .env
$EDITOR .env             # set POSTGRES_PASSWORD
docker compose up -d
```

The runtime exposes its HTTP API on `http://localhost:8000` (or whatever
`KATARI_PORT` you set). Point `katari apply` / `katari run` at it via:

```sh
katari apply --api http://localhost:8000 ...
```

## Pinning a version

Edit `.env` and set `KATARI_VERSION=0.1.0` (matching a published GHCR
tag). `latest` is fine for trying things out but rolls forward on every
release — pin for prod.

## Database

Postgres data lives in the `pgdata` named volume; `init/` is applied
exactly once on first boot (creates the `katari_runtime` database).

Schema migration (`schema.sql`) ships inside the image at
`/app/share/schema.sql`. Apply it after the first boot:

```sh
docker compose exec -T db \
  psql -U katari -d katari_runtime \
  < <(docker compose exec runtime cat /app/share/schema.sql)
```

(Re-running is idempotent for the current schema.)

## Reverse proxy / TLS

This compose intentionally leaves TLS termination to whatever you
already have (Caddy, nginx, Cloudflare Tunnel, ...). Expose only the
proxy to the internet; the runtime port should stay bound to localhost
or your private network.

## Logs

```sh
docker compose logs -f runtime
```

## Upgrading

```sh
docker compose pull runtime
docker compose up -d runtime
```

Re-apply `schema.sql` if the release notes call for it.
