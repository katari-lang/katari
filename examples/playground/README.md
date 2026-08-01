# playground — a tour of Katari's standard features

One project, eighteen modules, each independently runnable. Use it to smoke-test a runtime and to see
every core feature in a small, deterministic form. Every module lives under the package's own
namespace (`src/playground/`), so its qualified name is `playground.<module>`.

| Module                                   | Entry              | Shows                                                                                                                              |
| ---------------------------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| [`basics.ktr`](src/playground/basics.ktr)           | `playground.basics.main`      | data + `match`, `for` (map + accumulator), `parallel for`, stateful inline handlers, partial application (`scale(factor = 2.0, value = _)`, incl. an omitted `?=`-defaulted parameter filled through the residual), prelude (string / array / math / json) |
| [`match_string.ktr`](src/playground/match_string.ktr) | `playground.match_string.main` | matching on STRING values: `case "literal"` arms with a bare-identifier catch-all, plus input normalisation (trim + lowercase before matching) — the value-level twin of `scoped`'s string-literal singleton types |
| [`records_and_rows.ktr`](src/playground/records_and_rows.ktr) | `playground.records_and_rows.main` | object (record) LITERALS `{ field = value }` and their `{ field: type }` types (named once with a synonym), plus EFFECT-ROW SYNONYMS (`type conversation = ask \| note`) used after `with` and as an `effect` type argument — the two features newcomers most often misread as absent |
| [`tools.ktr`](src/playground/tools.ktr)             | `playground.tools.main`       | agents as AI tools: `reflection.get_metadata` schema derivation, the typed JSON boundary (`json.validate[T]` over `json.parse`), dynamic dispatch (`reflection.call_agent`) |
| [`errors.ktr`](src/playground/errors.ktr)           | `playground.errors.main`      | the typed error model: `prelude.throw[T]` raised + caught (incl. `env.missing_secret` config fallback), and the ambient `panic` clause catching a runtime failure |
| [`interactive.ktr`](src/playground/interactive.ktr) | `playground.interactive.main` | escalation: unanswered `request`s bubble out as open questions; parallel delegations — watch the **delegation tree** on the run page |
| [`ffi.ktr`](src/playground/ffi.ktr) + [`ffi.ts`](src/playground/ffi.ts) | `playground.ffi.main` | the FFI: plain values, `file` blobs both directions, inner delegation (`context.call`), typed throws (`katari.throw`)               |
| [`webhook.ktr`](src/playground/webhook.ktr)         | `playground.webhook.main`     | dynamic inbound endpoints: `webhook.inbound` mints a public URL, POSTs become validated callback calls — self-contained (the subscriber POSTs to its own URL) |
| [`finalizers.ktr`](src/playground/finalizers.ktr)   | `playground.finalizers.run`   | `finally { ... }` arms instance finalizers (Go-`defer`-like): reverse arming order, run at the terminal, never on a panic; a finalizer's net effect must stay within `io` (a locally-handled request is fine, an escalating one is rejected K3021) |
| [`scoped.ktr`](src/playground/scoped.ktr)           | `playground.scoped.main`      | scope-tagged capabilities in the type system: string literal singleton types (`"fast"` as a type), `[literal name]` generics binding a literal argument's singleton, and `effect scoped[resource]` markers that ride effect rows, gate calls, and are discharged by a provider-shaped signature (`with_scope`) |
| [`time.ktr`](src/playground/time.ktr)               | `playground.time.main`        | durable wall-clock time as built-in reactor calls (no FFI sidecar): `time.now` reads a durably-recorded clock a recovered run agrees with, `time.sleep` waits a persisted deadline that re-arms across a restart, and `time.watch` fires an agent per schedule occurrence — with termination composed *around* the watch (a stateful handler throws to tear it down) |
| [`store.ktr`](src/playground/store.ktr) | `playground.store.main` | the durable key-value store — state that outlives a run: `store.get` (`found` / `absent`) / `store.get_or` (the typed read, T off the fallback) / `store.set` / `store.list`, a `store.workspace` that prefixes every key AND serves `store.exclusive`, a read-modify-write taking its atomicity from that one critical section (and `main_root`, the same section served by the runtime at the project root), plus `store.safe_segment` vs. the panicking bad path |
| [`credentials.ktr`](src/playground/credentials.ktr) | `playground.credentials.main` | the one credential shape (WHERE a secret lives, never its value): a package's `credential` request discharged by a `provider` resolving a `credentials.source` (an `env` key or an `oauth` name), and the `string of private` taint that keeps a resolved secret to an http `Authorization` header |
| [`supervise_demo.ktr`](src/playground/supervise_demo.ktr) | `playground.supervise_demo.main` | failure recovery composed, with the `supervise` provider (mechanism) split from a user *converter* (policy) that decides which throws / panics become `supervise.interrupted`: exponential backoff with selective retry, `supervise.forever` re-arming a `time.watch` daemon, and `supervise.immediate` + a converter that performs its own human-in-the-loop escalation |
| [`region.ktr`](src/playground/region.ktr)           | `playground.region.main`      | structured-concurrency nursery: `region.provide` opens a scope, `region.fork` fans out as a *deferred call* (`argument` is the task's whole parameter record), and `region.watch` is the *white hole* re-emitting fibers' escalations at a surrounding handler (a subscription that forks a second emitter from inside the white hole). There is deliberately NO join — a fiber carries no result, so its output leaves as an escalation — and the contrast with `parallel for` (fork-JOIN, results in fork order) is spelled out beside it |
| [`deferred_callback.ktr`](src/playground/deferred_callback.ktr) | `playground.deferred_callback.main` | a request whose PAYLOAD is a callback: the raiser carries on after its callback-carrying request is answered and dropped, and a parked callback is run LATER from a fiber — after the agent that built it has returned — which is the async-approval shape and the hardest case for the runtime's scope ownership |
| [`mcp_demo.ktr`](src/playground/mcp_demo.ktr)       | `playground.mcp_demo.main`    | the built-in MCP client: `mcp.provide` lists a server's tools as a scoped toolbox of agents, and the reflection loop (`reflection.get_metadata` reads a tool's schema, `reflection.call_agent` dispatches it) runs inside the `provide` scope the tool calls are gated by (pass a server URL via `--arg`) |
| [`mcp_serve_demo.ktr`](src/playground/mcp_serve_demo.ktr) | `playground.mcp_serve_demo.main` | publishing agents over MCP: `mcp.serve` mints a fresh capability URL serving a record's agents as MCP tools for a subscriber's extent — self-contained (the subscriber connects back with the built-in client), so mint → list → call → deactivate runs with no external service |

## Run it

From the repo root, with the runtime already up (see the repo README / `compose.yaml`):

```sh
# The runtime URL comes from katari.toml's [runtime].url. The CLI authenticates with the runtime's
# KATARI_API_KEY (the same one in the repo `.env`), so export it once:
export KATARI_API_KEY="$(grep -m1 '^KATARI_API_KEY=' ../../.env | cut -d= -f2-)"
cd examples/playground

katari apply                                             # compile + bundle the sidecar + deploy a snapshot
katari run playground.basics.main                        # => areas=… | ticks=[0,1,2] | sum(squares(4))=30 | …
katari run playground.match_string.main                  # => red -> stop | GREEN -> go | amber -> brake gently | blue -> unknown signal: blue
katari run playground.records_and_rows.main              # => Ada <ada@example.org> [new] | Grace <grace@example.org> [new] || warmly, Ada
katari run playground.credentials.main                   # => env:EXAMPLE_API_KEY | oauth:example-service
katari run playground.store.main                         # => visits=2 | greeting="hello" | nickname=(unnamed) | keys=["greeting","visits"]  (the counter persists, so a later run shows more)
katari run playground.tools.main                         # => tools=[…]; result=5
katari run playground.region.main                        # => fan_out=[4,9,16] | parallel=[4,9,16] | subscription saw four messages across two emitters
katari run playground.webhook.main                       # => delivered: 42 and 8 (a minted URL, called by itself)
katari run playground.errors.main                        # => playground.errors.not_even: 7 is odd — no half | half=6 | 9 is odd — no half | panic caught: … | no secret under …
katari run playground.ffi.main --arg '{"name":"world"}'  # => Hello, world! | bytes=13 | compute(20)=41 | fallback_port=8080
katari run playground.interactive.main                   # blocks on two questions — answer them:
katari ls escalations                                    #    …or answer from the console's Escalations inbox
katari answer <escalation-id> --value '"be careful"'     #    (omit --value to be prompted for it)
```

`playground.interactive.main` is the delegation-tree showcase: while it waits, the run page in the
console shows `main` → `panel` → two parallel `consult` nodes, each holding an open `ask` question.
