# discord_bot

Katari project.

## Quickstart

```sh
cp .env.example .env
docker compose up -d
katari apply
```

The runtime listens on `http://localhost:8000` by default. Point
`katari apply` / `katari run` at it via `--api` or `KATARI_API_URL`.

For production, generate strong values for `KATARI_API_KEY` and
`KATARI_SECRET_KEY` in `.env` (see comments there).
