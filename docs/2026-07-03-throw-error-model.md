# throw[T] — the typed error model, and panic's retreat into the runtime

2026-07-03. Before this phase katari had one error channel: `prelude.panic`, a declared request any
program could raise and catch, and the same name the runtime raised on a prim failure, a bad delegate
target, an FFI error. That conflated two different things — *anticipated, domain-specific failures a
program should recover from* and *invariant violations that mean the program (or its infrastructure) is
broken*. This phase splits them:

- **`throw[T]` is the error channel for programs.** A single generic request in the prelude; the payload
  type `T` is a domain-specific error `data` declared next to the operation that fails (`json.parse_error`,
  `http.fetch_error`, `ai.call_error`). Raised explicitly (`throw(error = …)`), caught by an ordinary
  handler, typed end to end.
- **`panic` is the runtime's own failure signal, and only the runtime's.** Its declaration leaves the
  prelude, so a program can neither raise nor name-a-handler-for it — an unhandled invariant violation
  (non-exhaustive match, engine backstop, FFI infrastructure error, division by zero) fails the run,
  period. Recovery from a broken invariant is not a program-level concern; re-running is.

## The declaration

```katari
@"Signal a typed error. …"
request throw[T](error: T) -> never
```

One request, generic in its payload. `-> never` makes non-resumability a type fact: a handler cannot
`next` (no value inhabits `never`), so catching a throw always means escaping the handle (`break`) or
re-throwing — catch-and-break semantics, the same shape panic recovery had.

## Static semantics — entirely existing machinery

No compiler change was needed; `test/Katari/Typechecker/ThrowSpec.hs` pins each of these on the shipped
checker:

- **A raise is a call.** `throw(error = parse_error(message = "…"))` infers `T = parse_error` exactly like
  a generic agent call; `throw[parse_error](…)` is the explicit form.
- **One row entry per request name; instantiations join.** The effect row is
  `Map QualifiedName (Map Text NormalizedKindedType)` — so a scope that throws `oops` on one path and
  `other` on another carries `throw[oops | other]`, not two entries. This is sound because request
  generics in *parameter* position are **covariant in the row** (the variance stage already models a
  request as the dual of a function — the performer supplies the parameter, the handler consumes it), so
  the lattice join unions payloads.
- **A handler discharges the instantiation its parameter names.**
  `use handler { request throw(error: parse_error) -> never { break fallback } }` removes
  `throw[parse_error]` from the row. A handler narrower than the joined payload is rejected (K3001) — you
  handle the whole union or you don't handle.
- **Rethrow escapes.** A raise in the handler body is an effect of the *enclosing* scope (the handler's
  effects ride out on the generic `E`), so catch-some-rethrow-rest is:
  `request throw(error: oops | other) -> never { match … re-raise … }` with the residual instantiation in
  the enclosing row.
- **`never` composes.** A raise typechecks in any expression position; a branch that throws contributes
  nothing to the branch join.

The one modelling consequence: because instantiations of one name join, *all* throws in a scope are one
row entry, and a handler is all-or-nothing over that union. Distinct row entries per instantiation (Koka's
labelled exceptions) would need a multi-entry row and were rejected — the union model is simpler, and the
payload union plus `match` gives the same expressiveness at the recovery site.

Schema lowering already substitutes request generics per instantiation (`requestDescriptor` /
`buildSubstitution`), so a snapshot's request schemas show `throw` at each concrete payload type.

## What throws, what panics

The dividing line: **could a correct program meet this failure at runtime and sensibly continue?** Yes →
`throw` with a domain error data. No (it means the program, deployment, or engine is broken) → runtime
panic.

| surface | failure | now |
| --- | --- | --- |
| `json.parse` | malformed text | `throw[json.parse_error]` |
| `json.decode[T]` | document does not conform to `T` | `throw[json.decode_error]` |
| `json.parse_as[T]` | either of the above | `throw[json.parse_error \| json.decode_error]` |
| `http.fetch` | no response (DNS, refused, timeout, restart) | `throw[http.fetch_error]` |
| `ai.call_agent` | bad target / non-conforming args | `throw[ai.call_error]` |
| `divide` / `modulo` | zero divisor | panic (was: silent `Infinity` / `NaN`) |
| `json.stringify` / `encode` / `to_text` | non-finite number | panic (numeric invariant; unreachable once divide panics) |
| `env.get_secret` | key not set | panic (a deployment error, not program logic) |
| non-exhaustive match, engine backstops | — | panic |
| FFI handler error | `katari.throw(payload)` | `throw[T]` (declared on the agent: `with prelude.throw[T]`) |
| FFI handler error | any other JS error | panic (infrastructure failure, not program logic) |

Each error data lives in its domain module and carries at least `message: string`
(`prelude.json.parse_error(message)`, `prelude.json.decode_error(message)`,
`prelude.http.fetch_error(message)`, `prelude.ai.call_error(message)`).

Divide-by-zero stays a panic deliberately: making `/` effectful would strip arithmetic of purity
everywhere (no pure-call attribute lifting, no pure positions), a heavy price for an error that a program
guards with one comparison. The prim now fails fast instead of minting `Infinity` that poisons data and
surfaces far away at a JSON boundary.

## Runtime

- **Raising from a prim.** Prims signal a typed error by throwing `KatariThrow` (an `Error` subclass
  carrying the payload `Value`); the prim seam raises `prelude.throw` with `{ error: payload }` for it,
  and keeps wrapping every other JS error as a panic. Payload data values are records with the domain
  error's `ctor` tag, so the boundary codec serializes them with their `$constructor`.
- **Raising from a reactor.** `Reactor.raiseThrow` mirrors `raisePanic` — an `escalate` whose ask is
  `prelude.throw` — for failures owned by a reactor rather than a thread: the http reactor's no-response
  error, core's `call_agent` unwrap/validation errors.
- **Handler matching is unchanged** — by qualified name, which is exactly the union model: the one
  `throw` handler in scope receives every payload, as the checker guaranteed.
- **The self-catch fix (pre-existing bug).** `handleAsk` matched a request ask against its handlers no
  matter which child sent it — so a handler body re-raising the request it handles would be caught by its
  own handle, forever. Statically the rethrow escapes (handler effects ride the enclosing `E`); the engine
  now agrees: a request ask arriving *from a handler thread* proxies up instead of re-matching. Control
  asks (`break` / `next` targeting the handle) still match — a handler's `break` is how it completes.
- **At the run root, throw fails the run.** `isUserFacingRequest` excludes `prelude.throw` alongside
  panic — an unanswerable `never` question must not sit as an open escalation. The run's `errorMessage`
  serializes the payload through the redacting codec (`throw: {json}`), so a tainted payload degrades to
  `$redacted` fields rather than leaking (the same fail-closed boundary as run results).

## Typed throws over the FFI boundary (follow-up slice, same day)

The port follow-up landed as its own slice. The wire gains a `throw` variant in both directions —
`{ kind: "throw", delegation, error }` as a call outcome, and a `throw` `DelegateOutcome` on inner
`delegateResult`s — and the payload stays typed end to end, never flattened to a message:

- **Raising**: a sidecar handler calls `katari.throw(payload)` (it throws a `KatariThrowError`); the
  dispatch reply is a `throw` whose payload is blind-encoded like a return value. The katari side declares
  the effect as usual (`external agent ... with prelude.throw[my_error]` — the `http.fetch` precedent), so
  the checker forces callers to handle it; the ffi reactor decodes the payload at its transport seam and
  re-raises via `raiseThrow`, exactly the http reactor's shape. Any other JS error stays a panic.
- **Catching**: a katari callee's throw reaching a handler's `context.call` rejects with
  `KatariThrowError` carrying the *decoded* payload (previously it was flattened into an error message →
  panic). Uncaught, it propagates out of the handler and becomes the call's own `throw` reply — a rethrow
  that carries the payload katari → sidecar → katari unchanged.
- **In-process twin**: `FfiThrow` (plain wire JSON payload) plays both roles on the
  `InProcessFfiTransport`, so the whole circle is testable without a subprocess.

## Follow-ups (deliberately out of this slice)

- **`env.get_secret` as throw** — defensible either way; revisit if a real program wants in-program
  fallback for missing config.
- **Retry/backoff combinators over `throw[http.fetch_error]`** — stdlib sugar once real orchestration
  programs show the shape.
