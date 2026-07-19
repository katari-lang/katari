// Substrate: the bus. The sole owner of the transactional machinery every reactor's turn flows through — the
// serial mailbox, the lazy-load gate, routing by `to`, and the one atomic commit per BATCH of turns. A turn
// runs the reacting reactor (it mutates its warm state and buffers `send`s); consecutive turns fold into one
// batch — each turn's produced events join the same mailbox and are consumed by later turns of the same
// batch — and the batch commits once: every touched reactor's accumulated state, the consumed inbound rows,
// outbox rows only for events still unprocessed at the batch bound, and the journal of every event sent. An
// event produced AND consumed within one batch never touches the outbox table, and an instance born and torn
// down within one batch never touches its tables — the transactional-outbox guarantee holds at the batch
// boundary (a crash mid-batch replays the whole batch from its durable inputs). Holding all of this in one
// place is what makes "one batch = one atomic commit" enforceable, and keeps reactors DB-free (see
// docs/2026-06-25-reactor-persist-redesign.md).
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

/** The most turns one batch folds into a single commit. Bounds the replay cost after a failure (the whole
 *  batch re-runs from its durable inputs) and the memory a burst can pin; a longer burst simply splits,
 *  its seam events riding the outbox like any inter-batch traffic. */
const MAX_BATCH_TURNS = 256;

/** Exponential backoff (ms) for the nth commit retry, capped — so a repeated commit failure does not spin. */
function commitBackoffMs(attempt: number): number {
  return Math.min(20 * 2 ** (attempt - 1), 1000);
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** How `pump` proceeds after a batch. The failure variants carry their own follow-up data so no mutable
 *  side channel has to smuggle it to the next pump: `ok` continues; `retry` waits `backoffMs`, then
 *  replays the batch from its durable inputs; `reload` re-pumps now (warm was dropped and any dead event
 *  consumed), with `nextBatchLimit` capping the next batch so a failed batch's good prefix replays alone;
 *  `stop` leaves the actor dormant. */
type BatchOutcome =
  | { kind: "ok" }
  | { kind: "retry"; backoffMs: number }
  | { kind: "reload"; nextBatchLimit?: number }
  | { kind: "stop" };

/** The substrate's collaborators on its owner: how to rebuild the project's warm domain state from durable
 *  rows (and replay the undrained outbox) on first use, and how to discard the non-durable in-process state
 *  (the run-result promises) when a commit is poisoned. */
export interface SubstrateHost {
  reactivate(): Promise<void>;
  /** Tear down the non-durable in-process notification hooks after a poisoned commit (reject the run-result
   *  promises). The durable-derived warm state is rebuilt by the following `reactivate`. */
  onPoison(error: unknown): void;
}

/** One unit of serial work: run `reactor` (its `react` for an inbound event, or a command / FFI closure).
 *  `event` is set only for an inbound external event — it consumes `consumed` and gets `afterCommit`.
 *  `settle` is set only for an api command, whose out-of-loop caller awaits the enclosing batch's commit. */
interface Turn {
  reactor: Reactor;
  run: () => void | Promise<void>;
  event: ExternalEvent | null;
  consumed: OutboxSeq | null;
  settle: { resolve: () => void; reject: (error: unknown) => void } | null;
}

/** What a batch accumulates across its turns, flushed by one `commitBatch`. */
interface Batch {
  /** Reactors that reacted this batch — each persists its accumulated dirty state once. */
  touched: Set<Reactor>;
  /** Durable inbound rows the batch's turns consumed (rows from EARLIER commits — an in-batch event has
   *  no row; see `pendingProduced`). */
  consumed: OutboxSeq[];
  /** Events produced this batch and not (yet) consumed by one of its own turns: the only ones that need
   *  outbox rows at commit. A later turn of the same batch consuming one deletes it from here instead of
   *  adding to `consumed` — the produce/consume pair cancels to zero rows. */
  pendingProduced: Map<OutboxSeq, ExternalEvent>;
  /** Every event sent this batch, in production order — the run-trace journal keeps ALL hops, including
   *  the in-batch ones that never touch the outbox. */
  journal: ExternalEvent[];
  /** Post-commit notifications (FFI / transport dispatches, run-promise settlement), in turn order. */
  afterCommits: Array<{ reactor: Reactor; event: ExternalEvent }>;
  /** Command awaiters resolved once the batch is durable (rejected if it fails). */
  settles: Array<NonNullable<Turn["settle"]>>;
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
  /** Per durable inbound event (its outbox seq), how many times a batch it originated has hit a retryable
   *  failure — a commit throw, or a transient infra throw out of react (see `onRetryableBatchFailure`).
   *  Survives reactivation (the substrate object persists; only warm reactor state is dropped), so the
   *  retry bound spans replays. */
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

  /** The serial loop: load once, then run + commit one BATCH at a time. Reentrancy-guarded so only one
   *  pump drains the mailbox; the events a batch's turns produce are delivered back into the mailbox and
   *  join the same batch (up to its bound).
   *
   *  Failure handling (the "warm store advances only when the durable commit advances" rule): a batch's
   *  turns run `react` (mutating the warm store) *before* the batch commit. If anything fails, the warm
   *  store has advanced past durable — so the actor is poisoned: reject the batch's awaiters and every
   *  other pending command, drop the warm state, and reactivate from durable (the batch's unconsumed
   *  inbound rows replay the lost work). A `reactivate` failure (e.g. the DB is unreachable) is caught the
   *  same way — pending commands reject, the load is retried on the next call — so a commit / load error
   *  is never an unhandled rejection.
   *
   *  `firstBatchLimit` caps only the FIRST batch of this pump: a `reload` after a mid-batch failure passes
   *  the failed batch's good-prefix length here, so the prefix replays as its own batch and the offending
   *  event lands at position 0 of the following one (where the single-turn policies apply precisely). The
   *  reload re-pump follows the failing pump synchronously, so no other caller can slip in and pump
   *  without the bound. */
  private async pump(firstBatchLimit?: number): Promise<void> {
    if (this.pumping) return;
    this.pumping = true;
    let interruption: BatchOutcome | null = null;
    try {
      await this.ensureLoaded();
      let batchLimit = firstBatchLimit;
      while (this.mailbox.length > 0) {
        const outcome = await this.runBatch(batchLimit);
        batchLimit = undefined;
        if (outcome.kind !== "ok") {
          interruption = outcome;
          break;
        }
        // The mailbox drained — GLOBAL QUIESCENCE. Offer every reactor the chance to flush work it defers to
        // this point (the region nursery flushes a watch-less scope's held fiber escalations up). A reactor
        // that schedules follow-on here re-fills the mailbox, so the loop runs it and re-quiesces; each hook
        // acts only when it has real work, so this converges to a true fixpoint rather than spinning.
        if (this.mailbox.length === 0) this.fireQuiesce();
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
    if (interruption === null) return;
    // Re-enter as the outcome dictates. `retry` backs off first (a transient failure replays the batch
    // from its durable inputs); `reload` re-pumps immediately (state was dropped + any dead event
    // consumed), carrying the prefix-replay bound; `stop` leaves the actor dormant (the events stay
    // durable, retried on the next activation).
    if (interruption.kind === "retry") {
      await delay(interruption.backoffMs);
      void this.pump();
    } else if (interruption.kind === "reload") {
      void this.pump(interruption.nextBatchLimit);
    }
  }

  /** Fire the global-quiescence hook on every reactor (the mailbox has drained). A reactor may `schedule`
   *  follow-on work, which re-fills the mailbox for the surrounding `pump` loop; the hook contract is that it
   *  acts only when it has real deferred work, so this cannot spin. */
  private fireQuiesce(): void {
    for (const reactor of Object.values(this.registry)) reactor.onQuiesce();
  }

  /** Run one batch through its three phases — the react loop / one commit / the afterCommits — each with
   *  its own failure policy. Returns how `pump` should proceed. */
  private async runBatch(turnLimit?: number): Promise<BatchOutcome> {
    // A non-positive bound would make the react loop run zero turns and report `ok`, spinning `pump` on a
    // non-empty mailbox forever — so the bound is clamped to at least one turn.
    const limit = Math.max(1, turnLimit ?? MAX_BATCH_TURNS);
    const batch: Batch = {
      touched: new Set(),
      consumed: [],
      pendingProduced: new Map(),
      journal: [],
      afterCommits: [],
      settles: [],
    };
    // Phase 1 — the react loop: run consecutive turns against the warm store, folding each turn's
    // produced events back into the mailbox where later turns of this same batch consume them. A
    // *transient* infra failure (a `TransientError` — e.g. an IR DB read blip on a resume turn) is
    // retryable exactly like a commit failure: nothing committed, so drop + reload + replay. Any other
    // throw is a deterministic bug (a deterministic failure is supposed to surface as a panic, not a
    // throw) — never replay-loop it.
    let position = 0;
    while (this.mailbox.length > 0 && position < limit) {
      const turn = this.mailbox.shift();
      if (turn === undefined) break;
      // An event produced within THIS batch has no durable row — consuming it just cancels the pending
      // produce (the pair nets to zero outbox writes). A row from an earlier commit is consumed for real.
      if (turn.consumed !== null && !batch.pendingProduced.delete(turn.consumed)) {
        batch.consumed.push(turn.consumed);
      }
      try {
        await turn.run();
      } catch (reactError) {
        // A failure deeper in the batch replays the good prefix as its own batch first, which lands the
        // offender at position 0 of a following batch — so only two cases remain here. At position 0
        // nothing else is in flight and the batch degenerates to this one turn (`batch.consumed` holds at
        // most its row, `batch.settles` is empty): a transient infra throw goes through the same
        // retryable policy as a commit failure, and any other throw is a deterministic bug, never
        // replay-looped.
        if (position > 0) return this.onMidBatchFailure(batch, turn, reactError, position);
        if (isTransientError(reactError)) {
          const settles = turn.settle === null ? [] : [turn.settle];
          return this.onRetryableBatchFailure(settles, batch.consumed[0], reactError, "react");
        }
        return this.onReactFailure(turn, reactError);
      }
      batch.touched.add(turn.reactor);
      for (const event of turn.reactor.drainSends()) {
        const seq = newOutboxSeq();
        batch.pendingProduced.set(seq, event);
        batch.journal.push(event);
        this.mailbox.push(this.eventTurn(event, seq));
      }
      if (turn.event !== null)
        batch.afterCommits.push({ reactor: turn.reactor, event: turn.event });
      if (turn.settle !== null) batch.settles.push(turn.settle);
      position += 1;
    }
    if (position === 0) return { kind: "ok" };
    // Phase 2 — commit: the one atomic durable write for the whole batch. A failure here means the warm
    // store advanced past durable, so it must be dropped + rebuilt; the (unconsumed) inbound rows replay.
    try {
      await this.commitBatch(batch);
    } catch (commitError) {
      return this.onRetryableBatchFailure(batch.settles, batch.consumed[0], commitError, "commit");
    }
    for (const seq of batch.consumed) this.commitRetries.delete(seq); // committed → clear retry counts
    // Phase 3 — afterCommit: strictly-post-commit side effects (FFI dispatch, run-promise settlement).
    // The batch is already durable, so a failure here must NOT poison — it would discard committed work.
    // Log and move on; the side effect is re-driven on the next reactivation from durable state.
    for (const { reactor, event } of batch.afterCommits) {
      try {
        reactor.afterCommit(event);
      } catch (afterError) {
        this.logger.error("post-commit side effect failed (batch already committed)", {
          kind: event.kind,
          error: messageOf(afterError),
        });
      }
    }
    for (const settle of batch.settles) settle.resolve();
    return { kind: "ok" };
  }

  /** A `react` throw: a deterministic failure should have surfaced as a panic, so this is a bug. Do not
   *  poison-loop it — log loudly, reject the awaiter, consume the dead inbound event so it cannot replay into
   *  the same throw, and drop + reload the (possibly partially mutated) warm state. */
  private async onReactFailure(turn: Turn, error: unknown): Promise<BatchOutcome> {
    this.logger.error(
      "reactor threw while computing a turn (a bug: a deterministic failure should panic, not throw) — dropping the event",
      { to: turn.event?.to, kind: turn.event?.kind, error: messageOf(error) },
    );
    turn.settle?.reject(error);
    if (turn.consumed !== null) await this.consumeDeadEvent(turn.consumed);
    this.dropWarm(error);
    return { kind: "reload" };
  }

  /** THE retryable policy — a batch of one turn is still a batch, so a `commit` throw and a *transient*
   *  infra throw out of a first-turn `react` (a `TransientError`) share it. Either way the warm store may
   *  have advanced past durable, so drop + reload; the batch's unconsumed durable inputs replay as the
   *  retry. Bounded with backoff so a non-transient failure does not spin, counting against `origin` (the
   *  batch's first consumed row) — on exhaustion it stops in-process, and the events stay durable for the
   *  next activation. An originated-only batch (commands / FFI completions) has nothing durable to replay
   *  or count against, so it just reloads and its rejected callers retry. */
  private onRetryableBatchFailure(
    settles: Array<NonNullable<Turn["settle"]>>,
    origin: OutboxSeq | undefined,
    error: unknown,
    phase: "react" | "commit",
  ): BatchOutcome {
    for (const settle of settles) settle.reject(error);
    this.dropWarm(error);
    if (origin === undefined) {
      this.logger.warn(`${phase} failed for an originated-only batch; reloading`, {
        error: messageOf(error),
      });
      return { kind: "reload" };
    }
    const attempts = (this.commitRetries.get(origin) ?? 0) + 1;
    if (attempts <= MAX_COMMIT_RETRIES) {
      this.commitRetries.set(origin, attempts);
      this.logger.warn(`${phase} failed; will replay the batch from its durable inputs`, {
        attempts,
        error: messageOf(error),
      });
      return { kind: "retry", backoffMs: commitBackoffMs(attempts) };
    }
    this.commitRetries.delete(origin);
    this.logger.error(`${phase} kept failing; giving up in-process (retries on next activation)`, {
      attempts,
      error: messageOf(error),
    });
    return { kind: "stop" };
  }

  /** A react failure at batch position N > 0: the earlier turns' warm effects are uncommitted, so
   *  everything drops and replays — bounded, by replaying the good PREFIX as its own batch first (the
   *  outcome's `nextBatchLimit`). The offending event then sits at position 0 of a following batch, where
   *  the precise single-turn policies (dead-event consumption for a deterministic bug, bounded retries
   *  for a transient) take over. */
  private onMidBatchFailure(
    batch: Batch,
    turn: Turn,
    error: unknown,
    position: number,
  ): BatchOutcome {
    this.logger.warn("a turn failed mid-batch; replaying the prefix as its own batch", {
      position,
      error: messageOf(error),
    });
    turn.settle?.reject(error);
    for (const settle of batch.settles) settle.reject(error);
    this.dropWarm(error);
    return { kind: "reload", nextBatchLimit: position };
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

  /** Commit one batch atomically: every touched reactor's accumulated state, then the pool, the consumed
   *  inbound rows, outbox rows ONLY for events still unprocessed at the batch bound (a produce/consume
   *  pair inside the batch cancelled to nothing), and the journal of everything sent this batch — the run
   *  trace keeps every hop, including the in-batch ones the outbox never sees. */
  private async commitBatch(batch: Batch): Promise<void> {
    const produced: OutboxMessage[] = [];
    for (const [seq, event] of batch.pendingProduced) {
      produced.push({ seq, event });
    }
    let reclaimedBytes: BlobId[] = [];
    await this.persistence.transaction(this.projectId, async (tx) => {
      // Reactors persist in first-touch (= causal) order, so a producer's rows land before a consumer's
      // FK-referencing ones — the same order the per-turn commits used to write them in.
      for (const reactor of batch.touched) {
        await reactor.persist(tx);
      }
      // The pool flushes after the reactors so an in-transit scope (released as the run / sub-call result
      // left its instance) is re-written AFTER that instance's drop cascade removed its stale row. It reports
      // the blobs whose rows it dropped, whose bytes are freed below once this commit is durable.
      reclaimedBytes = await this.pool.persist(tx);
      for (const seq of batch.consumed) {
        await tx.outbox.consumeOutbox(seq);
      }
      if (produced.length > 0) await tx.outbox.produceOutbox(produced);
      // The journal — the run's execution trace — commits with the work it records: an event is journaled
      // exactly iff the turns around it durably happened (a failed commit rolls both back). After the
      // reactors' persist, so a run's launching commit writes its `runs` row before the FK-referencing
      // trace rows.
      if (batch.journal.length > 0) await tx.journal.appendEvents(batch.journal);
    });
    // Strictly post-commit (durable-first): the rows referencing these blobs are now durably gone, so their
    // bytes are unreferenced and safe to delete. Fire-and-forget — the serial loop must not gate on object-store
    // latency — and a failed delete is a harmless storage leak, logged (never thrown: the batch is committed, so
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
  }
}
