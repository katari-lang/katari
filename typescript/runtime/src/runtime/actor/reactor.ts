// Reactor: one module on the substrate (the bus). A reactor reacts to inbound external events by computing
// its whole turn *in memory* and returning a `Reaction` for the substrate to commit atomically, with
// optional strictly-post-commit side effects. Reactors hold no DB — the substrate is the sole committer.
// This restores the prototype's API / CORE / FFI module separation over the typed, transactional bus (see
// docs/2026-06-25-reactor-bus-redesign.md). The base captures only the two universal hooks; each concrete
// reactor (api / core / ffi) keeps its own in-memory view of the entities it owns.

import type { ExternalEvent } from "../event/types.js";
import type { Reaction } from "./turn-commit.js";

export abstract class Reactor {
  /** React to one inbound external event: run the turn in memory (updating this reactor's own view of the
   *  entities it owns) and return the `Reaction` the substrate commits — its Layer 1 transitions, Layer 2,
   *  and the events to emit. Pure with respect to the DB: it persists nothing, so the same turn can be
   *  re-run if its commit fails. May be async (the core engine's drive awaits the IR); the api root, which
   *  runs no engine threads, reacts synchronously. */
  abstract react(event: ExternalEvent): Reaction | Promise<Reaction>;

  /** Strictly-post-commit side effects (durable-first): settle an in-process promise, dispatch an FFI call,
   *  drop a routing edge. Runs only after the Reaction is durably committed, so recovery is always possible
   *  from durable state alone. Default: no effect. */
  afterCommit(_event: ExternalEvent, _reaction: Reaction): void {}
}
