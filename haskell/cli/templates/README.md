# {{name}}

A Katari project. Katari programs orchestrate AI agents: agents call agents, escalate
questions to their operator, and the runtime keeps every run durable.

## Quickstart

1. Start a local runtime (once — see the note in `compose.yaml` about building the image):

   ```sh
   docker compose up -d
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
   run, and `katari run` lets you answer it right in the terminal.

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
