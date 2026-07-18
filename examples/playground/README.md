# playground — a tour of Katari's standard features

One project, eight modules, each independently runnable. Use it to smoke-test a runtime and to see
every core feature in a small, deterministic form. Every module lives under the package's own
namespace (`src/playground/`), so its qualified name is `playground.<module>`.

| Module                                   | Entry              | Shows                                                                                                                              |
| ---------------------------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| [`basics.ktr`](src/playground/basics.ktr)           | `playground.basics.main`      | data + `match`, `for` (map + accumulator), `parallel for`, stateful inline handlers, partial application (`scale(factor = 2.0, value = _)`, incl. an omitted `?=`-defaulted parameter filled through the residual), prelude (string / array / math / json) |
| [`tools.ktr`](src/playground/tools.ktr)             | `playground.tools.main`       | agents as AI tools: `reflection.get_metadata` schema derivation, the typed JSON boundary (`json.parse_as[T]`), dynamic dispatch (`reflection.call_agent`) |
| [`errors.ktr`](src/playground/errors.ktr)           | `playground.errors.main`      | the typed error model: `prelude.throw[T]` raised + caught (incl. `env.missing_secret` config fallback), and the ambient `panic` clause catching a runtime failure |
| [`interactive.ktr`](src/playground/interactive.ktr) | `playground.interactive.main` | escalation: unanswered `request`s bubble out as open questions; parallel delegations — watch the **delegation tree** on the run page |
| [`ffi.ktr`](src/playground/ffi.ktr) + [`ffi.ts`](src/playground/ffi.ts) | `playground.ffi.main` | the FFI: plain values, `file` blobs both directions, inner delegation (`context.call`), typed throws (`katari.throw`)               |
| [`webhook.ktr`](src/playground/webhook.ktr)         | `playground.webhook.main`     | dynamic inbound endpoints: `webhook.inbound` mints a public URL, POSTs become validated callback calls — self-contained (the subscriber POSTs to its own URL) |
| [`finalizers.ktr`](src/playground/finalizers.ktr)   | `playground.finalizers.run`   | `finally { ... }` arms instance finalizers (Go-`defer`-like): reverse arming order, run at the terminal, never on a panic; a finalizer's net effect must stay within `io` (a locally-handled request is fine, an escalating one is rejected K3021) |
| [`scoped.ktr`](src/playground/scoped.ktr)           | `playground.scoped.main`      | scope-tagged capabilities in the type system: string literal singleton types (`"fast"` as a type), `[literal name]` generics binding a literal argument's singleton, and `effect scoped[resource]` markers that ride effect rows, gate calls, and are discharged by a provider-shaped signature (`with_scope`) |

## Run it

From the repo root, with the runtime already up (see the repo README / `compose.yaml`):

```sh
# The runtime URL comes from katari.toml's [runtime].url. The CLI authenticates with the runtime's
# KATARI_API_KEY (the same one in the repo `.env`), so export it once:
export KATARI_API_KEY="$(grep -m1 '^KATARI_API_KEY=' ../../.env | cut -d= -f2-)"
cd examples/playground

katari apply                                             # compile + bundle the sidecar + deploy a snapshot
katari run playground.basics.main                        # => areas=… | ticks=[0,1,2] | sum(squares(4))=30 | …
katari run playground.tools.main                         # => tools=[…]; result=5
katari run playground.webhook.main                       # => delivered: 42 and 8 (a minted URL, called by itself)
katari run playground.errors.main                        # => 7 is odd — no half | half=6 | panic caught: … | no secret under …
katari run playground.ffi.main --arg '{"name":"world"}'  # => Hello, world! | bytes=13 | compute(20)=41 | fallback_port=8080
katari run playground.interactive.main                   # blocks on two questions — answer them:
katari ls escalations                                    #    …or answer from the console's Escalations inbox
katari answer <escalation-id> '"be careful"'
```

`playground.interactive.main` is the delegation-tree showcase: while it waits, the run page in the
console shows `main` → `panel` → two parallel `consult` nodes, each holding an open `ask` question.
