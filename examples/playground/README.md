# playground — a tour of Katari's standard features

One project, six modules, each independently runnable. Use it to smoke-test a runtime and to see
every core feature in a small, deterministic form.

| Module                                   | Entry              | Shows                                                                                                                              |
| ---------------------------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| [`basics.ktr`](src/basics.ktr)           | `basics.main`      | data + `match`, `for` (map + accumulator), `parallel for`, stateful inline handlers, prelude (string / array / math / json)         |
| [`tools.ktr`](src/tools.ktr)             | `tools.main`       | agents as AI tools: `reflection.get_metadata` schema derivation, the typed JSON boundary (`json.parse_as[T]`), dynamic dispatch (`reflection.call_agent`) |
| [`errors.ktr`](src/errors.ktr)           | `errors.main`      | the typed error model: `prelude.throw[T]` raised + caught (incl. `env.missing_secret` config fallback), and the ambient `panic` clause catching a runtime failure |
| [`interactive.ktr`](src/interactive.ktr) | `interactive.main` | escalation: unanswered `request`s bubble out as open questions; parallel delegations — watch the **delegation tree** on the run page |
| [`ffi.ktr`](src/ffi.ktr) + [`ffi.ts`](src/ffi.ts) | `ffi.main` | the FFI: plain values, `file` blobs both directions, inner delegation (`context.call`), typed throws (`katari.throw`)               |
| [`webhook.ktr`](src/webhook.ktr)         | `webhook.main`     | dynamic inbound endpoints: `webhook.inbound` mints a public URL, POSTs become validated callback calls — self-contained (the subscriber POSTs to its own URL) |

## Run it

From the repo root, with the runtime already up (see the repo README / `compose.yaml`):

```sh
# The runtime URL comes from katari.toml's [runtime].url. The CLI authenticates with the runtime's
# KATARI_API_KEY (the same one in the repo `.env`), so export it once:
export KATARI_API_KEY="$(grep -m1 '^KATARI_API_KEY=' ../../.env | cut -d= -f2-)"
cd examples/playground

katari apply                                  # compile + bundle the sidecar + deploy a snapshot
katari run basics.main                        # => areas=… | ticks=[0,1,2] | sum(squares(4))=30 | …
katari run tools.main                         # => tools=[…]; result=5
katari run webhook.main                       # => delivered: 42 and 8 (a minted URL, called by itself)
katari run errors.main                        # => 7 is odd — no half | half=6 | panic caught: … | no secret under …
katari run ffi.main --arg '{"name":"world"}'  # => Hello, world! | bytes=13 | compute(20)=41 | fallback_port=8080
katari run interactive.main                   # blocks on two questions — answer them:
katari ls escalations                         #    …or answer from the console's Escalations inbox
katari answer <escalation-id> '"be careful"'
```

`interactive.main` is the delegation-tree showcase: while it waits, the run page in the console
shows `main` → `panel` → two parallel `consult` nodes, each holding an open `ask` question.
