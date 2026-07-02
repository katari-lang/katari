# JSON boundary + AI interop: schema-checked delegation, `json`, `get_metadata`, `call_agent`

2026-07-02. The slice that makes the `tools = [agent_foo, agent_bar, ...]` pattern work: an AI can
be handed each agent's schema, reply with a tool pick + arguments, and have that pick dispatched —
with the runtime, not the program, enforcing that the AI-built arguments fit.

Live-verified end to end: `examples/agent-tools` (`katari apply` + `katari run main.main` →
tool list with schemas/descriptions, canned reply dispatched, `result=5`; a malformed argument →
`panic: main.add_numbers: ... $.x: expected a value of type integer, got a value of type string`).

## 1. Schema conformance (`typescript/runtime/src/runtime/value/validation.ts`)

`conformValue(value, schema)` / `parseJson(json, schema)` — the requested
`parse :: json × schema → value | error`, split into the JSON lift (the existing `jsonToValue`) and
a `Value`-level conformance walk, so the same check serves both wire JSON and in-flight values.

- Subtype-tolerant, never re-tagging: `integer` satisfies `number`; a semantic-string blob ref
  satisfies `string`; a `file` ref satisfies the `$ref` reference schema; an agent/closure satisfies
  the `$agent` reference schema; a residual `$generic` constrains nothing.
- The single repair: a record *missing* its `$constructor` against a schema that pins exactly one
  gets the tag attached (an AI naturally omits the discriminator on a non-union `data` argument).
  Inside an `anyOf` branch trial the repair is disabled — the tag is what picks the arm, so an
  untagged `{}` must not "match" whichever tag-only branch comes first.
- Failure messages carry path + expected + offending *kind*, never value content (the message
  crosses the user boundary as a panic; the value may be `private`).
- Untouched subtrees keep their object identity (blob refs / closures are never cloned — the
  resource-ownership machinery relies on it).
- `fillGenericSchema` / `typeSubstitutionOf` are the runtime half of the compiler-shared generic
  instantiation (`Katari.Schema.fillGenericSchema`'s TS mirror).

## 2. The delegate acceptance surface validates every argument

`CoreReactor.onDelegate` resolves the target, reads its `AgentBlock.schema.input` (generics filled
from the delegate's carried substitution), and conforms the argument. A violation is a `panic` to
the caller — the same deterministic-failure channel as an unresolvable name, catchable with a
`panic` handler. Statically checked call sites conform by construction; this is the enforcement
point for the dynamic entries (a run command's JSON, `call_agent` args, future FFI→core calls).

Follow-up found and fixed here: a panic raised at the acceptance surface births no instance, so a
later `terminate` for that delegation found no callee and the cancel cascade hung. `onTerminate`
now acks a terminate for an instance-less delegation.

## 3. `primitive.json` — the `json` data type and four conversions

Seven `data` constructors (`json_null` … `json_object(entries: record[json])`) closed into the
synonym `type json = ...` (recursion is fine: the synonym expands to nominal data references, and
`Katari.Schema` already breaks data-reference cycles). Two inverse pairs:

- text boundary: `parse : string -> json` (malformed → panic) / `stringify : json -> string`;
- value boundary: `encode[T] : T -> json` / `decode : json -> unknown`.

`encode` folds in the value codec's wire conventions (a data value keeps `$constructor` as an
entry, file → `$ref` handle object, agent → `$agent` reference, blob strings materialise, closures
panic) and **passes values that are already `json` through unchanged** — that pass-through is what
lets `json.encode(value = { name = m.name, input_schema = m.input })` mix plain fields with schemas
from `get_metadata`. `decode` is `jsonValueToJson ∘ jsonToValue`, so `$constructor` re-tags,
`$ref` reconstructs, `$agent` refuses. Shape errors in decoded values are the delegation
boundary's job (§2), which is why `decode` can honestly return `unknown`.

## 4. `primitive.ai` — `get_metadata` and `call_agent`

Root-module members are unreachable from user code (`primitive` is a keyword, and the default
import opens nothing unqualified — every stdlib reference is `qualifier.name`), so the AI bridge
lives in `primitive.ai`:

- `data agent_metadata(name, description, input: json.json, output: json.json, requests: json.json)`
  — schemas are `json` values (not strings), so they embed into tool lists by composition.
- `get_metadata(value: agent never -> unknown with all) -> agent_metadata`. Runtime impl follows
  the callable value's own snapshot/module through `IrSource` (`PrimContext` now carries
  `ir` + `blobs`), fills `$generic` from the value's carried substitution, and reads the new
  `AgentBlock.description` (stamped by lowering from the declaration's `@"..."` annotation —
  IR `Agent` gained a `description` field; optional on the TS side for pre-description snapshots).
  A closure works too (empty `name`).
- `call_agent[R, effect E](target: agent never -> R with E, args: unknown) -> R with E`. The type
  is the proven `runWith[effect E]` shape, so R/E infer from the target. The runtime never runs its
  body: `onDelegate` unwraps a delegate to `primitive.ai.call_agent` into a delegation to the
  callable its argument carries — same delegation id, so proxies / escalation relays / cancel see
  an ordinary sub-call — and §2 then validates `args` against the real target. Its registered prim
  implementation only throws (unreachable-by-construction guard).

## 5. Stdlib surface review (the I/O-type pass)

- `primitive.record`: `get[T] -> T | null`, `set`, `remove`, `keys`, `has`, `size`,
  `entries[T] -> array[[string, T]]` (the `for`-iterable view), `empty`. Parameter is uniformly
  `target` (`record` the word stays usable, but `target` keeps it uniform with `array`).
- `primitive.array`: `get[T] -> T | null`, `length`, `append`, `concat`, `slice`, `empty`.
- `primitive.string`: `length`, `split`, `join`, `slice`, `contains` — indices are Unicode code
  points — plus `to_string(value: null | boolean | number | string)` (the previously undeclared
  runtime leftover `primitive.to_string`, now declared scalar-only and moved; composites go through
  `json.stringify(json.encode(...))`).
- Every string-accepting prim materialises blob-backed strings through the context's `BlobStore`.
- Privacy is unchanged: the prim layer's monotonic taint marks any result from a private argument.

## Known gaps / deferred

- ~~`primitive.panic` is *declared* in the root module, which user code cannot reference~~ →
  resolved by the `prelude` rename (addendum below): `prelude.panic` raises and handles from source.
- Escalation *answers* are not yet schema-validated (`deriveAnswerSchema` exists; wiring the
  check into the answer surface is a small follow-up).
- `json_integer` vs `json_number` splits on `Number.isInteger` at parse time (JSON has one number
  type); `1.0` round-trips as `1`.

## Addendum (same day): `prelude`, inferred instantiation in the IR, the typed JSON boundary

Follow-up slice, superseding some names above (`primitive.*` → `prelude.*`).

1. **The stdlib root is now `prelude`.** `primitive` is a declaration keyword, so the root module's
   own name could never be referenced from source — neither `primitive.panic` nor
   `import ... from primitive.x` parsed. As `prelude`, the root resolves like any default-import
   qualifier; `prelude.panic(msg = ...)` raises and `use handler { request prelude.panic(...) }`
   recovers (both live-verified). Every wired-in qualified name follows: `prelude.add`,
   `prelude.json.parse`, `prelude.ai.call_agent`, ...

2. **Inferred generic instantiations reach the IR.** The checker already solved a generic call's
   substitution; now it records it on the typed `CallExpression` (composing the scheme's
   metavar-opening with the solver's answer — exactly what an explicit `callee[T]` writes), and
   lowering stamps it on the `delegate` operation as runtime schemas
   (`DelegateOperation.generics`, the `applyGenerics` encoding). The runtime merges it with the
   substitution the callee value carries; the acceptance surface therefore validates against
   *instantiated* schemas (`pick[T](x: T)` called with an integer now rejects a string argument),
   and schema-directed prims read their own `[T]` from `PrimContext.generics`.

3. **The JSON boundary is typed.** `json.decode` is now `decode[T](value: json) -> T` — validated
   against T's schema, `panic` on mismatch; the untyped `-> unknown` form is gone (T appears only
   in the result, so an uninstantiated call is already a K3016 compile error). `json.parse_as[T]
   (text: string) -> T` is the fused text boundary: `JSON.parse -> value lift -> conform`, with no
   intermediate tagged `json` tree (cheaper than `decode(parse(text))`, which builds and then
   flattens one). `json.stringify` generalised to `stringify[T](value: T) -> string` (embed first;
   a `json` value passes through, so it subsumes the old form and fuses `stringify(encode(x))`).

4. **A latent `use`-provider convention mismatch, exposed by validation and fixed.** The provider's
   *type* (and schema) says its argument is `{ continuation: agent ... }`, but `use` lowering
   delegated the bare continuation closure — the acceptance check rejected it at the first live
   `use handler`. Lowering now wraps (`{continuation = k}`) and the provider body reads the field,
   so the convention matches the type — which also makes a provider callable directly
   (`p(continuation = f)`) coherent with `use p`.

Also fixed en route: a panic raised at the acceptance surface births no instance, so a later
`terminate` for that delegation found no callee and the cancel cascade hung; `onTerminate` now acks
an instance-less delegation (see §2 of the main text).
