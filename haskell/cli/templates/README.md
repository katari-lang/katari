# {{name}}

A Katari project. Katari programs orchestrate AI agents: agents call agents, escalate
questions to their operator, and the runtime keeps every run durable.

## Quickstart

1. Start a local runtime (Postgres + a blob store + the runtime, from the published image):

   ```sh
   cp .env.example .env
   echo "KATARI_API_KEY=$(openssl rand -hex 32)"       >> .env
   echo "KATARI_SECRET_KEY=$(openssl rand -base64 32)" >> .env
   docker compose up -d
   ```

   The web console is now at <http://localhost:3000> (it prompts for the `KATARI_API_KEY`). The CLI
   reads `KATARI_API_KEY` from its environment — not from `.env` — so export it in the shell you run
   `katari` from:

   ```sh
   export $(grep '^KATARI_API_KEY=' .env)
   ```

2. Deploy this project:

   ```sh
   katari apply
   ```

3. Run it:

   ```sh
   katari run
   ```

   Pick `main.main`. It asks for your name — that question is an escalation leaving the
   run, and `katari run` lets you answer it right in the terminal (or from the console).

## Everyday commands

| Command | What it does |
| --- | --- |
| `katari check` | Compile and report diagnostics |
| `katari apply` | Deploy a new snapshot |
| `katari run [AGENT]` | Start a run and wait (Ctrl-C detaches) |
| `katari ls` | Recent runs (`ls agents`, `ls escalations`, ... for the rest) |
| `katari status <run>` | One run's state, outcome and open questions |
| `katari answer <escalation>` | Answer a question a run escalated |
| `katari cancel <run>` | Cancel a running run |
| `katari env set KEY --secret` | Store a secret programs read via `env.get_secret` |
| `katari add PKG` | Add a dependency from the registry |
