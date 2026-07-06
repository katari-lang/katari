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

import type { Logger } from "../../lib/logger.js";
import type { ExternalEvent, ReactorName } from "../event/types.js";
import { type BlobId, newOutboxSeq, type OutboxSeq, type ProjectId } from "../ids.js";
import type { BlobStore } from "../value/blob-store.js";
import { isTransientError, messageOf } from "./failure.js";
import type { OutboxMessage, Persistence } from "./persistence.js";
import type { Reactor } from "./reactor.js";
import type { ResourcePool } from "./resource-pool.js";

/** How many times a *commit* failure (transient infrastructure) replays its event before the substrate
 *  gives up in-process. Backoff caps the spin; a persistent failure stops here and is retried only on the
 *  next activation. (A *react* failure — a deterministic bug — is never retried; see `onReactFailure`.) */
const MAX_COMMIT_RETRIES = 8;

/** Exponential backoff (ms) for the nth commit retry, capped — so a repeated commit failure does not spin. */
function commitBackoffMs(attempt: number): number {
  return Math.min(20 * 2 ** (attempt - 1), 1000);
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** How `pump` proceeds after a turn: `ok` (continue), `retry` (back off, then replay from durable),
 *  `reload` (re-pump now — warm was dropped and any dead event consumed), `stop` (stay dormant). */
type TurnOutcome = "ok" | "retry" | "reload" | "stop";

/** The substrate's collaborators on its owner: how to rebuild the project's warm domain state from durable
 *  rows (and replay the undrained outbox) on first use, and how to discard the non-durable in-process state
 *  (the run-result promises) when a commit is poisoned. */
export interface SubstrateHost {
  reactivate(): Promise<void>;
  /** Tear down the non-durable in-process notification hooks after a poisoned commit (reject the run-result
   *  promises). The durable-derived warm state is rebuilt by the following `reactivate`. */
  onPoison(error: unknown): void;
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
  /** Per durable inbound event (its outbox seq), how many times its turn has hit a retryable failure (a commit
   *  throw, or a transient infra throw out of react). Survives reactivation (the substrate object persists;
   *  only warm reactor state is dropped), so the retry bound spans replays. */
  private readonly commitRetries = new Map<OutboxSeq, number>();

  constructor(
    private readonly projectId: ProjectId,
    private readonly persistence: Persistence,
    private readonly registry: Record<ReactorName, Reactor>,
    private readonly pool: ResourcePool,
    /** The blob byte store — the substrate frees a reclaimed blob's bytes strictly after the turn that dropped
     *  its rows commits (the pool reports them out of `persist`). */
    private readonly blobStore: BlobStore,
    private readonly host: SubstrateHost,
    private readonly logger: Logger,
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
   *  drains the mailbox; the events a turn produces are delivered back into the mailbox and drained here too.
   *
   *  Failure handling (the "warm store advances only when the durable commit advances" rule): a turn runs
   *  `react` (mutating the warm store) *before* its commit. If that commit fails, the warm store has advanced
   *  past durable — so the actor is poisoned: reject this turn's awaiter and every other pending command,
   *  drop the warm state, and reactivate from durable (the unconsumed outbox row replays the lost turn). A
   *  `reactivate` failure (e.g. the DB is unreachable) is caught the same way — pending commands reject, the
   *  load is retried on the next call — so a commit / load error is never an unhandled rejection. */
  private async pump(): Promise<void> {
    if (this.pumping) return;
    this.pumping = true;
    let after: TurnOutcome | null = null;
    try {
      await this.ensureLoaded();
      while (this.mailbox.length > 0) {
        const turn = this.mailbox.shift();
        if (turn === undefined) break;
        const outcome = await this.runOne(turn);
        if (outcome !== "ok") {
          after = outcome;
          break;
        }
      }
    } catch (loadError) {
      // `ensureLoaded` (reactivate) failed: reject anything queued so callers do not hang; the cleared
      // `loadingPromise` means the next caller retries the load. No re-pump — the next use retries.
      this.logger.error("reactivation failed; queued work rejected", {
        error: messageOf(loadError),
      });
      this.rejectPending(loadError);
    } finally {
      this.pumping = false;
    }
    // Re-enter as the outcome dictates. `retry` backs off first (a transient commit failure replays from the
    // durable outbox); `reload` re-pumps immediately (state was dropped + the dead event consumed); `stop`
    // leaves the actor dormant (the event stays durable, retried on the next activation).
    if (after === "retry") {
      await delay(this.pendingBackoffMs);
      this.pendingBackoffMs = 0;
      void this.pump();
    } else if (after === "reload") {
      void this.pump();
    }
  }

  /** The backoff (ms) the next `retry` re-pump waits — set by `onRetryableFailure`, consumed by `pump`. */
  private pendingBackoffMs = 0;

  /** Run one turn through its three phases — react / commit / afterCommit — each with its own failure
   *  policy. Returns how `pump` should proceed. */
  private async runOne(turn: Turn): Promise<TurnOutcome> {
    // Phase 1 — react: compute the reaction (mutate warm state, buffer sends). A *transient* infra failure
    // here (a `TransientError` — e.g. an IR DB read blip on a resume turn) is retryable exactly like a commit
    // failure: nothing committed, so drop + reload + replay. Any other throw is a deterministic bug (a
    // deterministic failure is supposed to surface as a panic, not a throw) — never replay-loop it.
    try {
      await turn.run();
    } catch (reactError) {
      if (isTransientError(reactError)) return this.onRetryableFailure(turn, reactError, "react");
      return this.onReactFailure(turn, reactError);
    }
    // Phase 2 — commit: the one atomic durable write. A failure here means the warm store advanced past
    // durable, so it must be dropped + rebuilt; the (unconsumed) event replays as the retry.
    try {
      await this.commit(turn.reactor, turn.consumed);
    } catch (commitError) {
      return this.onRetryableFailure(turn, commitError, "commit");
    }
    if (turn.consumed !== null) this.commitRetries.delete(turn.consumed); // committed → clear its retry count
    // Phase 3 — afterCommit: strictly-post-commit side effects (FFI dispatch, etc.). The turn is already
    // durable, so a failure here must NOT poison — it would discard a committed turn. Log and move on; the
    // side effect (e.g. an FFI dispatch) is re-driven on the next reactivation from durable state.
    if (turn.event !== null) {
      try {
        turn.reactor.afterCommit(turn.event);
      } catch (afterError) {
        this.logger.error("post-commit side effect failed (turn already committed)", {
          kind: turn.event.kind,
          error: messageOf(afterError),
        });
      }
    }
    turn.settle?.resolve();
    return "ok";
  }

  /** A `react` throw: a deterministic failure should have surfaced as a panic, so this is a bug. Do not
   *  poison-loop it — log loudly, reject the awaiter, consume the dead inbound event so it cannot replay into
   *  the same throw, and drop + reload the (possibly partially mutated) warm state. */
  private async onReactFailure(turn: Turn, error: unknown): Promise<TurnOutcome> {
    this.logger.error(
      "reactor threw while computing a turn (a bug: a deterministic failure should panic, not throw) — dropping the event",
      { to: turn.event?.to, kind: turn.event?.kind, error: messageOf(error) },
    );
    turn.settle?.reject(error);
    if (turn.consumed !== null) await this.consumeDeadEvent(turn.consumed);
    this.dropWarm(error);
    return "reload";
  }

  /** A retryable failure: a `commit` throw, or a *transient* infra throw out of `react` (a `TransientError`).
   *  Either way the warm store may have advanced past durable, so drop + reload; the unconsumed event replays
   *  as the retry. Bounded with backoff so a non-transient failure does not spin — on exhaustion it stops
   *  in-process (the event stays durable, retried on the next activation). An originated turn (a command / FFI
   *  completion) has nothing durable to replay, so its rejected caller retries it. */
  private async onRetryableFailure(
    turn: Turn,
    error: unknown,
    phase: "react" | "commit",
  ): Promise<TurnOutcome> {
    turn.settle?.reject(error);
    this.dropWarm(error);
    if (turn.consumed === null) {
      this.logger.warn(`${phase} failed for an originated turn; reloading`, {
        error: messageOf(error),
      });
      return "reload";
    }
    const attempts = (this.commitRetries.get(turn.consumed) ?? 0) + 1;
    if (attempts <= MAX_COMMIT_RETRIES) {
      this.commitRetries.set(turn.consumed, attempts);
      this.pendingBackoffMs = commitBackoffMs(attempts);
      this.logger.warn(`${phase} failed; will replay the event`, {
        attempts,
        error: messageOf(error),
      });
      return "retry";
    }
    this.commitRetries.delete(turn.consumed);
    this.logger.error(`${phase} kept failing; giving up in-process (retries on next activation)`, {
      attempts,
      error: messageOf(error),
    });
    return "stop";
  }

  /** Consume a dead inbound event (a minimal commit) so reactivation does not replay it. If even this fails
   *  (the DB is down), the event survives and replays on the next activation — logged, not looped. */
  private async consumeDeadEvent(seq: OutboxSeq): Promise<void> {
    try {
      await this.persistence.transaction(this.projectId, (tx) => tx.outbox.consumeOutbox(seq));
      this.commitRetries.delete(seq);
    } catch (error) {
      this.logger.error("could not consume a dead event; it will replay on next activation", {
        error: messageOf(error),
      });
    }
  }

  /** Drop the warm state after a failure: reject every queued command (none survive a reactivate — they are
   *  not durable), discard the mailbox (inbound / produced events replay from the durable outbox), settle the
   *  non-durable in-process hooks (run-result promises), and mark unloaded so the next pump reactivates. */
  private dropWarm(error: unknown): void {
    this.rejectPending(error);
    this.host.onPoison(error);
    this.loaded = false;
    this.loadingPromise = null;
  }

  /** Reject every queued command's awaiter and clear the mailbox (inbound / produced events have no awaiter
   *  and replay from the outbox). */
  private rejectPending(error: unknown): void {
    for (const pending of this.mailbox) pending.settle?.reject(error);
    this.mailbox.length = 0;
  }

  /** Commit one reactor turn atomically: drain its buffered sends, mint an outbox seq per produced event,
   *  then write the reactor's own state plus the outbox bookkeeping (consume the inbound row, produce the
   *  sends) in one transaction. Deliver the produced events back into the mailbox after the commit. */
  private async commit(reactor: Reactor, consumed: OutboxSeq | null): Promise<void> {
    const sends = reactor.drainSends();
    const produced: OutboxMessage[] = sends.map((event) => ({ seq: newOutboxSeq(), event }));
    let reclaimedBytes: BlobId[] = [];
    await this.persistence.transaction(this.projectId, async (tx) => {
      await reactor.persist(tx);
      // The pool flushes after the reactor so an in-transit scope (released as the run / sub-call result
      // left its instance) is re-written AFTER that instance's drop cascade removed its stale row. It reports
      // the blobs whose rows it dropped, whose bytes are freed below once this commit is durable.
      reclaimedBytes = await this.pool.persist(tx);
      if (consumed !== null) await tx.outbox.consumeOutbox(consumed);
      if (produced.length > 0) await tx.outbox.produceOutbox(produced);
      // The journal — the run's execution trace — mirrors the produce in the same commit: an event is
      // journaled exactly iff it was durably sent (a failed commit rolls both back). After the reactor's
      // persist, so a run's launching commit writes its `runs` row before the FK-referencing trace rows.
      if (produced.length > 0) await tx.journal.appendEvents(sends);
    });
    // Strictly post-commit (durable-first): the rows referencing these blobs are now durably gone, so their
    // bytes are unreferenced and safe to delete. Fire-and-forget — the serial loop must not gate on object-store
    // latency — and a failed delete is a harmless storage leak, logged (never thrown: the turn is committed, so
    // throwing here would poison durable state). On a failed commit the transaction throws above and this is
    // never reached, so live bytes are never orphaned.
    for (const blobId of reclaimedBytes) {
      void this.blobStore.delete(this.projectId, blobId).catch((error: unknown) => {
        this.logger.warn("post-commit blob byte deletion failed (row dropped; bytes leak)", {
          blobId,
          error: messageOf(error),
        });
      });
    }
    for (const message of produced) this.mailbox.push(this.eventTurn(message.event, message.seq));
  }
}
