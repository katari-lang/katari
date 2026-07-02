# agent-tools — agents as AI tools

One tool-calling turn, end to end, without a real AI (so the loop is deterministic). The three
pieces this example exercises, all from [`src/main.ktr`](src/main.ktr):

1. **Schema derivation** — `ai.get_metadata(value = tool)` turns a callable *value* into its
   `agent_metadata`: qualified name, `@"..."` description, and the JSON Schemas of its input /
   output as `json` values. `tool_list` embeds them into the request body an AI tool-calling API
   would receive (`json.encode` passes `json` values through unchanged, so schemas compose with
   plain fields).
2. **The json boundary** — a canned "AI reply" (`{"tool": ..., "arguments": {...}}` as text) goes
   through `json.parse`, is taken apart with `match` over the `json.json_*` constructors and
   `record.get`, and its arguments come back out as a plain value via `json.decode`.
3. **Dynamic dispatch** — `ai.call_agent(target = tool, args = args)` invokes the picked callable
   value. The runtime validates the AI-built `args` against the tool's input schema at the
   delegation boundary; a mismatch fails as a `panic` naming the offending path.

With a real AI, step 2's canned reply becomes an `http.fetch` of the tool-calling API with step 1's
body — the rest is unchanged.

## Run it

From the repo root (Postgres up, runtime dev server on `localhost:3000`):

```sh
cd examples/agent-tools
katari apply
katari run main.main
```

Expected output (one line): the AI-facing tool list, then the dispatched result —

```
"tools=[{\"name\":\"main.add_numbers\",...},{\"name\":\"main.greet\",...}]; result=5"
```

The validation panic is easy to see live:

```sh
katari run main.add_numbers --arg '{"x": "not-a-number", "y": 3}'
# run failed: panic: main.add_numbers: the argument does not conform to the input schema —
#   $.x: expected a value of type integer, got a value of type string
```
