# ffi-hello — an FFI end-to-end example

`main` (in [`src/main.ktr`](src/main.ktr)) calls `external agent greet`, whose FFI implementation lives in
[`src/main.ts`](src/main.ts). Because both are the module `main` (the file path under `src`, no extension),
the handler registers under the key `main.greet` — exactly the key the compiler lowers the external agent to.

```
agent main(name: string) -> string { greet(name = name) }   // main.ktr
katari.agent("greet", (a) => `Hello, ${a.name}!`)            // main.ts  → registers main.greet
```

`katari apply` compiles the IR and bundles the sidecar (`@katari-lang/bundle`); `katari run` starts the
agent; the runtime spawns the snapshot's sidecar bundle as a `node` process and dispatches `greet` to it.

## Run it

From the repo root:

```sh
# 1. Postgres (the runtime auto-migrates on boot).
docker run -d --name katari-pg \
  -e POSTGRES_USER=katari -e POSTGRES_PASSWORD=katari -e POSTGRES_DB=katari \
  -p 5432:5432 postgres:16

# 2. Build the bundler CLI and start the runtime server (listens on :3000).
pnpm --filter @katari-lang/bundle build
pnpm --filter @katari-lang/runtime exec tsx src/bin.ts &

# 3. Deploy and run. The agent's qualified name is <module>.<agent> = main.main.
export KATARI_BUNDLE_BIN="$PWD/typescript/bundle/dist/cli.mjs"
export KATARI_API_URL="http://localhost:3000"
stack exec katari -- apply --project examples/ffi-hello
stack exec katari -- run main.main --arg '{"name":"world"}' --project examples/ffi-hello
# => Result: "Hello, world!"

# 4. Tear down.
docker rm -f katari-pg
```

`KATARI_BUNDLE_BIN` points the CLI at the built bundler (a `.mjs`, run via `node`); in a published install
the `katari-bundle` binary is on `PATH` and this is unnecessary.
