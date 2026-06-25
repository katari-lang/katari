// Substrate: the bus. The sole owner of the transactional machinery every reactor's turn flows through — the
// serial mailbox, the lazy-load gate, routing by `to`, and the one atomic commit per turn. A turn is: run the
// reacting reactor (it mutates its warm state and buffers `send`s), then in a single transaction persist that
// reactor and the transactional outbox (consume the inbound row, produce the buffered sends), then deliver
// the produced events back into the mailbox and run the reactor's strictly-post-commit side effects. Holding
// all of this in one place is what makes "one turn = one atomic commit" enforceable, and keeps reactors
// DB-free (see docs/2026-06-25-reactor-persist-redesign.md).
//
// Routing is self-contained: an inbound external event names its destination (`event.to`), so the substrate
// dispatches purely by `registry[event.to]` — no api|core oracle. FFI completions and api commands are turns
// that *originate* here (no inbound row to consume): a command additionally settles a promise so an
// out-of-loop caller can await its turn.

import type { ExternalEvent, ReactorName } from "../event/types.js";
import { newOutboxSeq, type OutboxSeq, type ProjectId } from "../ids.js";
import type { OutboxMessage, Persistence } from "./persistence.js";
import type { Reactor } from "./reactor.js";

/** The substrate's one collaborator on its owner: how to rebuild the project's warm domain state from durable
 *  rows (and replay the undrained outbox) on first use. */
export interface SubstrateHost {
  reactivate(): Promise<void>;
}

/** One unit of serial work: run `reactor` (its `react` for an inbound event, or a command / FFI closure),
 *  then commit it. `event` is set only for an inbound external event — it consumes `consumed` and gets
 *  `afterCommit`. `settle` is set only for an api command, whose out-of-loop caller awaits the turn. */
interface Turn {
  reactor: Reactor;
  run: () => void | Promise<void>;
  event: ExternalEvent | null;
  consumed: OutboxSeq | null;
  settle: { resolve: () => void; reject: (error: unknown) => void } | null;
}

export class Substrate {
  /** The serial inbox; each turn is processed to completion (run + commit) before the next. */
  private readonly mailbox: Turn[] = [];
  private pumping = false;
  /** Whether the project's persisted state has been reloaded into the warm reactors (lazy, on first use). */
  private loaded = false;
  /** The in-flight reactivation, so concurrent first-use callers share one load. Loading MUST complete before
   *  any commit — otherwise a just-produced outbox row would be re-read by `reactivate` and replayed. */
  private loadingPromise: Promise<void> | null = null;

  constructor(
    private readonly projectId: ProjectId,
    private readonly persistence: Persistence,
    private readonly registry: Record<ReactorName, Reactor>,
    private readonly host: SubstrateHost,
  ) {}

  /** Submit an originated turn (an FFI completion, or the first leg of any out-of-loop work) and pump. Fire-
   *  and-forget — errors propagate out of the loop like an inbound event's. */
  submit(reactor: Reactor, run: () => void | Promise<void>): void {
    this.mailbox.push({ reactor, run, event: null, consumed: null, settle: null });
    void this.pump();
  }

  /** Submit an api command turn (start / cancel / answer) and pump, returning a promise that settles after
   *  the turn commits — so the façade can `await` an answer / a cancel. */
  enqueueCommand(reactor: Reactor, run: () => void | Promise<void>): Promise<void> {
    return new Promise((resolve, reject) => {
      this.mailbox.push({ reactor, run, event: null, consumed: null, settle: { resolve, reject } });
      void this.pump();
    });
  }

  /** Append a replayed outbox event WITHOUT pumping — used by `reactivate` to re-enqueue the undrained outbox
   *  while the load is still in flight (the load's triggering pump drains it once `loaded`). */
  enqueueOutbox(event: ExternalEvent, seq: OutboxSeq): void {
    this.mailbox.push(this.eventTurn(event, seq));
  }

  /** Activate a (possibly recovered) project: reload and drain the replayed outbox without an inbound message
   *  to trigger it. Idempotent — the warm path also self-activates on its first `submit`. */
  async activate(): Promise<void> {
    await this.pump();
  }

  /** Reactivate once, before any commit. `loaded` flips true only once reactivation FULLY succeeds; a failure
   *  clears `loadingPromise` so the next caller retries rather than proceeding on a half-initialised project. */
  ensureLoaded(): Promise<void> {
    if (this.loaded) return Promise.resolve();
    if (this.loadingPromise === null) {
      this.loadingPromise = this.host.reactivate().then(
        () => {
          this.loaded = true;
        },
        (error) => {
          this.loadingPromise = null;
          throw error;
        },
      );
    }
    return this.loadingPromise;
  }

  /** Build the turn for an inbound external event: route by `to`, react, and consume its outbox row. */
  private eventTurn(event: ExternalEvent, consumed: OutboxSeq | null): Turn {
    const reactor = this.registry[event.to];
    return { reactor, run: () => reactor.react(event), event, consumed, settle: null };
  }

  /** The serial loop: load once, then run + commit one turn at a time. Reentrancy-guarded so only one pump
   *  drains the mailbox; the events a turn produces are delivered back into the mailbox and drained here too. */
  private async pump(): Promise<void> {
    if (this.pumping) return;
    this.pumping = true;
    try {
      await this.ensureLoaded();
      while (this.mailbox.length > 0) {
        const turn = this.mailbox.shift();
        if (turn === undefined) break;
        try {
          await turn.run();
          await this.commit(turn.reactor, turn.consumed);
          if (turn.event !== null) turn.reactor.afterCommit(turn.event);
          turn.settle?.resolve();
        } catch (error) {
          // A command turn rejects its caller's promise; an inbound / FFI turn has no awaiter, so its error
          // propagates out of the loop (the project is in an inconsistent state — matching the prior model).
          if (turn.settle !== null) turn.settle.reject(error);
          else throw error;
        }
      }
    } finally {
      this.pumping = false;
    }
  }

  /** Commit one reactor turn atomically: drain its buffered sends, mint an outbox seq per produced event,
   *  then write the reactor's own state plus the outbox bookkeeping (consume the inbound row, produce the
   *  sends) in one transaction. Deliver the produced events back into the mailbox after the commit. */
  private async commit(reactor: Reactor, consumed: OutboxSeq | null): Promise<void> {
    const sends = reactor.drainSends();
    const produced: OutboxMessage[] =
      sends.length === 0
        ? []
        : sends.map((event) => ({
            seq: newOutboxSeq(),
            issuer: reactor.currentTurnOwner(),
            event,
          }));
    await this.persistence.transaction(this.projectId, async (tx) => {
      await reactor.persist(tx);
      if (consumed !== null) await tx.consumeOutbox(consumed);
      if (produced.length > 0) await tx.produceOutbox(produced);
    });
    for (const message of produced) this.mailbox.push(this.eventTurn(message.event, message.seq));
  }
}
