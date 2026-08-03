# Journal relay elision — one payload per logical escalation

## Problem

`run_events` journals every `escalate` / `escalateAck` at every instance boundary it crosses. An ask
that bubbles through N instances unserved is journaled N times, each copy carrying the full payload.
For `ai.infer_step` the payload is the whole conversation history, and the bubble depth is the
delegation depth from the performing fiber to the provider install at the app root.

Measured on the tsukasa run (43h, run `613f3cfd`):

- 86 hops per logical escalation (min 86 / median 86 / max 89; no growth over time — it is the
  program's instance depth, not a leak).
- 13,855 journaled `infer_step` escalates for 161 real model steps.
- 4.72 GB of the 6.3 GB logical trace is `infer_step` escalate copies — 98.8 % of that is the same
  payload re-journaled per hop. Trace growth ≈ 2.2 GB/day logical.

The journal is observation-only: the engine never reads `run_events` (the only reader is the events
API / console). The outbox — the same events as transport — must keep full payloads: the relay
mechanism needs the ask to serve it, and the returning value must reach the raiser. So the cut is at
journal time: journal a redacted copy of relay-hop events, keep the wire untouched.

## Semantics: origin vs relay

The distinction is structural, not heuristic. `escapeAsk` (engine/common.ts) runs only when NO
handle in the instance served the ask. Therefore:

- **origin** — the ask was born in this instance: the walk from the escaping ask terminates at a
  `request` thread (user code performed it), or at a proxy whose relays entry was synthesized
  in-process (the conform-failure panic at core-reactor.ts:292, an ffi error panic) — there is no
  inbound escalate event behind it, so nothing else journals this payload.
- **relay** — the walk terminates at a `delegate` / `external` proxy whose relays entry was recorded
  by the actor's real `onEscalate` (core-reactor.ts:347): this instance received escalation E as an
  event, re-raised it verbatim, nobody served it, and it is now leaving again. The payload is
  byte-identical to E's, which was already journaled one hop down.

A handler that SERVES a request and then performs another — even a rephrased twin of the same
request — runs user code and starts a new origin. This is not an edge case to defend against; it is
the common case working correctly: `ai.with_context` and `ai.with_breaker` both serve `infer_step`
and re-perform it with a modified history, and their escalates must journal in full (the injected
history IS different bytes). A logical model step therefore journals ~3 origins (the fiber's
perform, plus one per middleware re-perform), not 1 — and that is correct.

## Change

### 1. Event vocabulary (`runtime/event/types.ts`)

Both additions are optional fields — additive, no migration, old rows and hand-built test events
unaffected.

- `escalate` gains `relayOf?: EscalationId` — the inbound escalation this event re-raises, absent on
  an origin.
- `escalateAck` gains `relayed?: true` — set when this ack answers a relay-hop escalate (its value
  is a copy of the ack one hop up the chain).

### 2. Engine

- The proxy `relays` entry (engine/types.ts:306) becomes
  `Record<AskId, { escalation: EscalationId; inbound: { relayOf: EscalationId | null } | null }>`.
  `inbound` is non-null only when the entry was recorded from a real inbound escalate event
  (`relayEscalate` called from the actor's `onEscalate`, passing the event's own `relayOf ?? null`).
  The two synthesized call sites (conform panic, ffi error panic) record `inbound: null`.
- `escapeAsk` (engine/common.ts:158): walk `(from, fromAskId)` back through `forwardRoutes` to the
  terminal thread — read-only, O(bubble depth), all entries still present at escape time. Terminal
  is a proxy with a relays entry whose `inbound !== null` → stamp `relayOf = entry.escalation` on
  the emitted escalate. Anything else → origin, no stamp.
- `dispatchAskAck` (engine/thread-ops.ts:208): when answering through a relays entry, emit
  `relayed: true` iff `entry.inbound !== null && entry.inbound.relayOf !== null`. Read: the ack of
  an ORIGIN escalate (the answer the raiser actually consumes) keeps its value in the journal;
  every deeper hop's ack is the copy and elides. A synthesized entry (`inbound: null`) never marks —
  elision must be positively known, or the only journaled copy of a payload is lost.

### 3. Journal view (`actor/row-store.ts:250`)

A pure `journalView(event): ExternalEvent` applied before `sealForStorage` in `journal.appendEvents`
only — `produceOutbox` is untouched:

- escalate with `relayOf` → replace the ask's payload (`argument` for a request, `value` for a
  control escape) with the null value, keep `ask.kind` and the request name, add `elided: true`.
- escalateAck with `relayed` → replace `value` with the null value, add `elided: true`.

The request name survives so the events API `kind` / `search` filters and the console's per-request
grouping keep working on elided rows; `relayOf` survives so the chain is reconstructible end to end.
Nothing is lost that existed only once: every payload is journaled exactly once, at its origin.

### 4. Events API / console

No schema change — the event JSON gains fields. The console may later render an elided row as a
link to its origin; not required for this change to land.

## Not in scope (follow-ups, separate tasks)

- Trimming ORIGIN payloads (lossy; only worth revisiting if origins alone still dominate).
- Retention for never-ending runs (`run_events` rows currently live as long as the run; a resident
  run never ends).
- Splitting `ai.types.usage` into uncached / cache-read / cache-write (today's summed field cannot
  reconstruct cost; the anthropic.ktr docstring already promises the split it doesn't deliver).

## Expected effect

Per logical model step: ~3 full escalates (~1 MB) + ~170 elided rows (~100 KB) instead of ~29 MB.
Trace growth ~2.2 GB/day → ~100 MB/day logical before Postgres compression.

## Tests

1. **Chain elision** (actor-level, in the style of `escalation-uniform.test.ts`): a 3-instance chain
   raiser → middle (no handler) → top (handler). Journal must hold: 1 origin escalate (full ask),
   1 relay escalate (`relayOf` linking to the origin's id, `elided`, null payload), 1 full ack (the
   origin's), 1 elided ack. The run still resolves with the handler's answer (wire untouched).
2. **Serve-and-re-perform is a new origin**: middle SERVES the request and performs a modified twin
   upward. Both escalates journal full, no `relayOf` between them — the rephrase case from review is
   pinned as semantics, not left to interpretation.
3. **Synthesized panic stays origin**: a conform-failure (or ffi error) panic relays through a proxy
   with no inbound event; its escalate journals full with no dangling `relayOf`.
4. **Filters over elided rows**: the events API `kind=escalate` + `search=<request name>` still
   match an elided row.
