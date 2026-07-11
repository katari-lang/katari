# Katari

Katari is a language for writing orchestration logic for AI agents. You write a Katari program;
the compiler (Haskell) lowers it to an intermediate representation (IR) that a persistent runtime
server (TypeScript) executes and manages. Parallelism and concurrency are first-class, and the
runtime persists every step of a run — so programs can run for a long time, park on a human
question, and recover from a crash without losing their place.

> **Status: pre-release, under active development.** This is the `scrap-and-build` line: the
> language, IR, runtime APIs, and standard library all still change without notice, and there is
> no stability guarantee yet. Expect breaking changes between commits.

## A taste

Agents are Katari's unit of execution — think "function". They call each other (a *delegation*),
fan out across threads with `parallel`, and *escalate* a `request` that has no handler in scope out
of the run as an open question a human answers from the console or the CLI.

```katari
// A tiny taste: agents delegate, `parallel for` fans work out across threads, and a `request`
// with no handler in scope escalates to a human — the run parks until the question is answered.

@"Ask a human to weigh in; the run waits until this question is answered."
request ask(question: string) -> string

@"Review one source by asking a human what stands out in it."
agent review(source: string) -> string with ask {
  let note = ask(question = f"What stands out in ${source}?")
  f"${source}: ${note}"
}

@"Review every source in parallel, then join the findings into one report."
agent main(sources: array[string]) -> string with ask {
  let notes = parallel for (let source in sources) {
    next review(source = source)
  }
  string.join(parts = notes, separator = "\n")
}
```

The `with ask` in each signature is the effect row: it tracks that these agents may perform the
`ask` request. Because nothing handles `ask`, it escalates — the runtime shows the blocked
delegation tree on the run page, and `katari answer` (or the console's inbox) supplies each reply.

For a full tour — data types and `match`, stateful inline handlers, typed errors, the FFI, and
more — see [`examples/playground`](examples/playground) and its
[README](examples/playground/README.md).

## Features

- **Agents, effects, and handlers.** An agent is a function with a JSON schema for its input and
  output. A `request` declares an effect; a `use handler` block implements it. Effect rows
  (`with ask`, `with prelude.throw[T]`) are part of every signature and checked by the compiler.
- **Delegation and escalation.** Calling an agent is a *delegation*; performing a request with no
  handler in scope is an *escalation* that surfaces as an open question, answerable from the
  console or with `katari answer`.
- **First-class parallelism.** `parallel for` and `parallel [...]` fan work out so each element
  runs on its own thread.
- **Durable execution.** The runtime persists run state, so programs can run for a long time, wait
  on external input, and recover from failure. Uploading a program creates an immutable *snapshot*
  you can roll back to.
- **Agents as AI tools.** Schema derivation (`reflection.get_metadata`) and dynamic dispatch
  (`reflection.call_agent`), plus a typed JSON boundary (`json.parse_as[T]`), let an AI loop pick
  and call agents as tools with arguments validated against their schemas.
- **MCP integration.** Consume any MCP server's tools as agents with `use mcp.provide` — a scoped
  provider whose tools live exactly as long as the block that opened them, enforced by the type
  system; publish your own agents as an MCP server with `mcp.serve`; generate typed `.ktr` bindings
  from a live server with `katari mcp pull`; and authorize outbound servers with OAuth via
  `katari mcp login`.
- **Typed errors.** `prelude.throw[T]` raises a typed, catchable error the signature tracks;
  `panic` is the runtime's separate failure channel, also catchable.
- **First-class files.** File blobs flow through agents and the FFI in both directions, with an MCP
  image bridge for multimodal flows.
- **Partial application.** `scale(factor = 2.0, value = _)` fixes some arguments now and yields a
  residual agent that takes only the remaining holes.
- **`finally`.** Arms instance finalizers (Go-`defer`-like) that run at a run's terminal.
- **Inbound webhooks.** `webhook.inbound` mints a public URL and turns each POST into a validated
  callback call.
- **Tooling.** A CLI (`katari`), an LSP server and VSCode extension, a TypeScript FFI, and an admin
  web console with a run trace and delegation tree.

## Project layout

This is a monorepo of Haskell and TypeScript packages.

| Path                    | What it is                                                             |
| ----------------------- | --------------------------------------------------------------------- |
| `haskell/compiler`      | The Katari compiler: source (`.ktr`) to IR, plus the standard library |
| `haskell/project`       | Project configuration and dependency handling                         |
| `haskell/lsp`           | Language Server Protocol implementation (editor features)             |
| `haskell/cli`           | The `katari` command-line interface                                   |
| `typescript/runtime`    | The runtime server: executes IR and persists run state                |
| `typescript/port`       | FFI library for interacting with the runtime from TypeScript          |
| `typescript/bundle`     | Bundler for FFI code (invoked by the CLI during `apply`)              |
| `typescript/mcp`        | The `katari-mcp` helper used by `katari mcp login` / `pull`           |
| `typescript/cli`        | npm wrapper around the Haskell `katari` binary                        |
| `typescript/admin-web`  | Web console for managing the runtime                                  |
| `typescript/vscode`     | VSCode extension                                                      |
| `typescript/types`      | Shared TypeScript types                                                |
| `docs`                  | Design notes and reference                                             |
| `examples/playground`   | A runnable tour of the standard features                              |

The standard library lives in [`haskell/compiler/stdlib/prelude`](haskell/compiler/stdlib/prelude)
(`string`, `array`, `math`, `json`, `http`, `file`, `mcp`, `webhook`, `reflection`, …).

## Getting started

### Prerequisites

- [Stack](https://docs.haskellstack.org/) (Haskell toolchain)
- [pnpm](https://pnpm.io/) (Node package manager)
- Docker (the runtime uses PostgreSQL and S3-compatible storage)

### Build

```sh
pnpm install
pnpm run build          # builds Haskell (stack) and TypeScript (pnpm) packages
pnpm run typecheck      # typecheck both toolchains
pnpm run test           # run Haskell and TypeScript tests
```

Other useful scripts: `pnpm run format`, `pnpm run lint`. See `package.json` for the full list.

`pnpm run build` also builds the `katari` CLI. Put it on your PATH with `stack install` (then use
`katari` directly, as the examples below do), or run it in place from the repo as
`stack exec katari -- <command>`.

### Write and check a program

The compile-only commands need no running server:

```sh
mkdir my_project && cd my_project
katari init                # scaffold a new project (package name defaults to the directory name)
katari check               # compile and report diagnostics
katari build               # compile to IR JSON
```

### Run against a runtime

Deploying and running a program needs a live runtime. Bring one up locally, then deploy and run:

```sh
# From the repo root: start PostgreSQL + storage and the runtime + web console.
pnpm run dev

# In your project directory:
katari apply               # compile, bundle, and deploy a snapshot
katari run main.main       # start the entry agent and wait for its result
```

Run `pnpm run dev:down` to stop the local services. The scaffolded project's own README explains
setting `KATARI_API_KEY` (how the CLI authenticates with the runtime), and
[`examples/playground/README.md`](examples/playground/README.md) is a fully worked end-to-end
session. Run `katari --help` for the full command list (`apply`, `run`, `status`, `cancel`,
`answer`, `ls`, `env`, `file`, `mcp`, `project`, …).

## Documentation and examples

- [`docs/`](docs) — dated design notes covering the runtime domain model, the IR, generics
  inference, composability and reflection, MCP integration, and more.
- [`examples/playground`](examples/playground) — one project, several independently runnable
  modules, each demonstrating a core feature.

## License

MIT. See [LICENSE](LICENSE).
