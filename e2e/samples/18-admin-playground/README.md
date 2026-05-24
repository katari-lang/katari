# 18-admin-playground

A scratch project for exercising every shape the admin web's SchemaForm
knows how to render. Apply this snapshot, then poke at the agents in
`/admin/.../definitions`.

## Apply

```sh
pnpm dev                                            # full HMR stack (db + api + web)
stack exec katari -- apply -p e2e/samples/18-admin-playground
```

Open <http://localhost:5173/admin/> (vite HMR) or
<http://localhost:8000/admin/> (baked image) and walk the Definitions tree
for the `playground` project.

## What each agent exercises

| Agent | Form shape tested |
|---|---|
| `echo_string` | StringField |
| `double_int` | NumberField (integer) |
| `halve` | NumberField (number) |
| `flip` | BooleanField |
| `point_sum` | ObjectField + auto-hidden `$ctor` |
| `describe_pair` | TupleField (= `prefixItems`) |
| `build_ok` returns | Single tagged-data return (= `$ctor` rendered cleanly on Returns card) |
| `describe_result` | Tagged-union ARGUMENT — admin dropdown of `playground.ok` / `playground.err` |
| `paint` | String-literal union → EnumField (= dropdown of `"red" / "green" / "blue"`) |
| `ask_name` | Escalation flow → answer form is a StringField (= the req's `string` return) |
| `check_proceed` | Escalation flow → answer form is a BooleanField |
| `trigger_never` | Escalation flow → never UX (= no input, only "Acknowledge & dismiss") |

Plus: invoke `prim.array_get` / `prim.get_field` directly from the
Definitions page (toggle "Show stdlib & libraries") to exercise the
**AnyField** type picker on the `unknown` argument.

## Known gap (intentional)

Tagged-union return types (e.g. `agent maybe_fail() -> ok | err`) are
**not** in this playground because of a current Solver bug that corrupts
unrelated `to_string(value = n)` typing in the same module. See
[`project_solver_union_return_secret_taint.md`](../../../.claude/memory)
for the repro. Re-add a union-return agent once the Solver refactor lands.
