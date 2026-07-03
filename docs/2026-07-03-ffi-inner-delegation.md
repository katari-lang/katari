# FFI inner delegation — a handler calling agents, generically

2026-07-03. Builds on the FFI-reactor phase (doc `2026-06-25-reactor-persist-redesign.md` §11): an external
call is a `delegate` to the `ffi` reactor, whose per-delegation callee instance owns the call. This phase
makes the callee a *caller* too: a running FFI handler can call back into the runtime — any agent, on any
call-taking reactor — and the whole protocol lives in the reactor base classes, so a concrete reactor stays
a thin transport adapter.

## The channel

The sidecar wire protocol gains one conversation per direction:

- sidecar → runtime `delegate { delegation, call, agent, reactor?, argument }` — run another agent on the
  in-flight handler's behalf. `delegation` names the parent call; `call` is a sidecar-minted token
  (`crypto.randomUUID()` — it must be unique **across** sidecar processes, see *Recovery*). `reactor`
  selects who runs the callee — `core` (default; `agent` is a qualified name), `ffi` or `http` (`agent` is
  an external key). `api` is not a callee.
- runtime → sidecar `delegateResult { delegation, call, outcome }` — the settled outcome
  (`result | error | cancelled`), delivered strictly post-commit.

The `FfiTransport` carries both (`onDelegate` sink in, `deliverDelegateResult` out); `SubprocessFfiTransport`
frames them over stdio, `SnapshotFfiTransport` routes by the parent delegation's snapshot,
`InProcessFfiTransport` gives test handlers the same `context.call` shape in-process.

## Reactor design — everything in the base

`FfiReactor.innerDelegate` only resolves the request to a `DelegateTarget` against the **parent call's
snapshot** (an agent and its FFI handlers deploy together) and converts JSON↔Value; everything else is
`ExternalCallReactor` + `Reactor` machinery:

- **Issuing** (`openInnerDelegation`): an ordinary `delegate` with the call's instance as caller — the base
  `Reactor.send` opens the caller-owned delegation row, exactly like a core sub-call. Refused (settled back
  as `cancelled`) when the call is gone / cancelling / already completed.
- **Results** (`onDelegateAck`): the base retires the row, re-owns the result's resources onto the call's
  instance (reclaimed at its drop unless the call's own result ascends them — `markInstanceDropped` now also
  reclaims scopes via `ResourcePool.reclaimScopesOwnedBy`), and stages the post-commit delivery through the
  `innerCalls` bridge (child delegation → transport token).
- **Escalations** (`onEscalate`): a child's **panic settles the inner call as an error** — the handler's own
  try/catch is its panic handle (core's `handle … with panic` analog); the dead callee is terminated (caught
  panics never resume — catch-and-break semantics), and an uncaught JS error re-raises through the handler's
  own failure. Every **other** ask (a user-facing request, a control escape) is proxied **up** under the
  call's own delegation with a fresh escalation id, bridged in `relays`; the answering `escalateAck` is
  proxied back **down** the same bridge. The transport never sees escalations — a handler needs no
  escalation protocol.
- **Terminate distribution** (`onTerminate`): a terminate from above moves the call to `cancelling`,
  cancels every still-running child, and the upward `terminateAck` waits for the transport's abort
  confirmation AND the children's drain — the same graceful-cancel barrier as core's cascade.
- **Held completions**: a transport completion landing while children are still live (a fire-and-forget
  `context.call`) is held in memory and the children cancelled first; the call settles once drained. Held
  state need not be durable — after a crash the reload converges to the same shape (the refused call's
  error outcome cancels the children the same way).

## Persistence and recovery — at-most-once, like http

The runtime NEVER re-runs external work: retrying is katari-level policy (`handle … with panic`), not the
runtime's. The old `redispatch` mechanism is gone entirely (no wire flag, no handler dedupe hook, and the
call argument is no longer persisted — like http). On reload, a `running` call is reconciled with the
transport via `recover(delegation)`, and the transport can tell the two restart shapes apart because its
own lifetime IS the process's lifetime:

- **Warm reset** (a poisoned commit): the transport still holds the call in flight → it is left alone; the
  surviving handler's completion arrives later and resumes the reloaded project seamlessly. The durable
  bridges (`ffi_instances.relays` / `.inner_calls`, jsonb) are what make this safe with inner delegations
  in flight: a result / answer landing after the reset still finds its route to the living sidecar.
- **Process death**: the transport does not know the call → it refuses with an `error` completion
  (`INTERRUPTED_MESSAGE`) → the call panics. That error path runs the same held-outcome machinery, which
  **cancels the call's inner delegations** — so a dead handler's children are torn down, not orphaned
  (their heavy work and side effects stop with the graceful terminate cascade). The delegation rows reload
  through the base (`from = ffi` self-select), which is where the distribution finds them.

The narrow honest window: a handler that completed and replied just before a poison whose completion turn
never committed is refused on reload although its work succeeded — the call fails rather than silently
re-running; at-most-once + katari-level retry is still at-least-once *end to end* when the program chooses
to retry (exactly-once side effects need idempotence at the effect itself — that is now an explicit,
language-level decision).

Known pre-existing gap (unchanged, now shared with core): an acceptance-surface panic (unresolvable name /
schema violation — no instance is born) cannot consume an `escalateAck`, so a katari handler answering such
a panic with `next(v)` strands the answer. For inner calls the panic→error mapping makes this reachable only
through the proxied-request path, not the common try/catch one.

## The port, redesigned

`@katari-lang/port` is rewritten one level up (PureScript-style assumed typing — the compiler already
checked the katari side of the boundary; no runtime re-validation):

- `katari.agent<Argument>(name, handler)` — the argument arrives **decoded**: record keys unescaped,
  `file` → `KatariFile` (`.bytes()` / `.text()` download over the blob side channel; no raw `$ref`),
  blob-backed strings → `KatariString` (type a string parameter as `KatariText = string | KatariString`,
  read with `text(…)`), data values → `KatariData(name, value)`, received callables → `KatariAgent`.
- `context.call<Result>(agent, argument?, { reactor? })` — the inner agent call; rejects with
  `KatariCallError` (callee failed) / `KatariCancelledError` (cancelled). `KatariAgent.call(args)` runs a
  received callable via `prelude.ai.call_agent`, carrying its own snapshot + generics.
- `context.file(bytesOrText, { contentType? })` replaces `uploadBlob`; returning the `KatariFile` (or any
  value containing it) hands the file on. The handler's return value is encoded blindly (wrappers → wire
  forms, `$`-keys escaped, cycles/bigints/raw bytes rejected per-call).
- Abort: the signal fires, pending inner calls reject with `KatariCancelledError` (an awaiting handler
  unwinds by itself), and the settled reply becomes the `cancelled` confirmation. A handler that returns
  with calls still pending just settles — the runtime holds its completion and cancels the children.
