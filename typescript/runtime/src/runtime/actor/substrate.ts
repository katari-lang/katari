// Substrate: the bus. The sole owner of the transactional machinery every reactor's turn flows through — the
// serial mailbox, the lazy-load gate, and the one atomic commit per turn. A reactor computes its turn in
// memory and hands back a `Reaction`; the substrate stamps the outbox bookkeeping onto it and writes Layer 1
// + Layer 2 + outbox in a single transaction, then delivers the produced events. Holding all of this in one
// place is what makes "one turn = one atomic commit" enforceable, and keeps reactors DB-free (see
// docs/2026-06-25-reactor-bus-redesign.md).
//
// Transitional seam (R1.3): the *routing* — which reactor handles an inbound message — is still the
// `SubstrateHost.dispatch` callback its owner (the ProjectActor) supplies, and the domain half of
// reactivation is its `reactivate` callback. R2 adds `from`/`to` to events plus a reactor registry, at which
// point `dispatch` collapses to `registry[message.to].react` inside the substrate itself.

import type { ActorMessage } from "../event/types.js";
import { newOutboxSeq, type OutboxSeq, type ProjectId } from "../ids.js";
import type { Persistence } from "./persistence.js";
import type { OutboxMessage, Reaction, TurnCommit } from "./turn-commit.js";

/** The substrate's two collaborators on its owner (until the reactors are fully split out): how to rebuild
 *  domain state on first use, and how to route one inbound message to the reactor that owns it. Both are the
 *  transitional seams described in the file header. */
export interface SubstrateHost {
  /** Rebuild the project's warm domain state (the engine store, routing maps, open escalations) from durable
   *  rows, and `enqueue` the undrained outbox. Called once, lazily, before any commit. */
  reactivate(): Promise<void>;
  /** Route one inbound message to its reactor and run its turn (which commits through `commit`). `seq` is the
   *  durable outbox row it came from (`null` for an ephemeral FFI completion). */
  dispatch(message: ActorMessage, seq: OutboxSeq | null): Promise<void>;
}

export class Substrate {
  /** The serial inbox. Each entry carries the durable outbox row it came from (`seq`) so the turn that
   *  processes it consumes that row in its commit; `null` for an ephemeral completion (no outbox row). The
   *  mailbox is just the warm cache of the outbox — replayed into on recovery. */
  private readonly mailbox: { message: ActorMessage; seq: OutboxSeq | null }[] = [];
  private pumping = false;
  /** Serialises every commit against the others, so no two DB transactions interleave in the single
   *  (event-loop-concurrent) actor. */
  private commitChain: Promise<unknown> = Promise.resolve();
  /** Whether the project's persisted state has been reloaded into the warm domain (lazy, on first use). */
  private loaded = false;
  /** The in-flight reactivation, so concurrent first-use callers share one load. Loading MUST complete before
   *  any commit — otherwise a just-produced outbox row would be re-read by `reactivate` and replayed. */
  private loadingPromise: Promise<void> | null = null;

  constructor(
    private readonly projectId: ProjectId,
    private readonly persistence: Persistence,
    private readonly host: SubstrateHost,
  ) {}

  /** Inject an inbound message (an external command's first event, or an ephemeral FFI completion) and pump.
   *  Produced follow-on events ride a Reaction and reach the mailbox through `commit`, not here. */
  feed(message: ActorMessage, seq: OutboxSeq | null): void {
    this.mailbox.push({ message, seq });
    void this.pump();
  }

  /** Append a message to the mailbox WITHOUT pumping — used by `reactivate` to replay the undrained outbox
   *  while the load is still in flight (the load's triggering pump drains it once `loaded`). */
  enqueue(message: ActorMessage, seq: OutboxSeq | null): void {
    this.mailbox.push({ message, seq });
  }

  /** Activate a (possibly recovered) project: reload and drain the replayed outbox without an inbound message
   *  to trigger it. Idempotent — the warm path also self-activates on its first `feed`. */
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

  /** Commit one reactor turn atomically: reactivate first so loading can never race a just-produced row, mint
   *  an outbox seq per `outbound` event (issued by the turn's instance), then write the whole turn — its
   *  Reaction plus the inbound `consumed` row — in one transaction and deliver. This is the one funnel every
   *  commit flows through, so "load before any commit" and "seqs are the bus's" hold in one place. */
  async commit(reaction: Reaction, consumed: OutboxSeq | null): Promise<void> {
    await this.ensureLoaded();
    const produced: OutboxMessage[] = reaction.outbound.map((event) => ({
      seq: newOutboxSeq(),
      issuer: reaction.instanceId,
      event,
    }));
    await this.transact({
      instanceId: reaction.instanceId,
      layer2: reaction.layer2,
      transitions: reaction.transitions,
      consumed,
      produced,
    });
  }

  /** The single atomic write (Layer 1 + Layer 2 + outbox), serialised against every other commit so no two
   *  transactions interleave; then deliver its produced events to the mailbox. */
  private async transact(commit: TurnCommit): Promise<void> {
    const run = this.commitChain.then(() => this.persistence.commitTurn(this.projectId, commit));
    this.commitChain = run.then(
      () => undefined,
      () => undefined,
    );
    await run;
    this.deliver(commit.produced);
  }

  /** Deliver produced events to the mailbox (after their commit) and kick the loop. */
  private deliver(produced: OutboxMessage[]): void {
    for (const message of produced) {
      this.mailbox.push({ message: message.event, seq: message.seq });
    }
    if (produced.length > 0) void this.pump();
  }

  /** The serial loop: load once, then route one message at a time to its reactor (each commits through
   *  `commit`). Reentrancy-guarded so only one pump drains the mailbox at a time. */
  private async pump(): Promise<void> {
    if (this.pumping) return;
    this.pumping = true;
    try {
      await this.ensureLoaded();
      while (this.mailbox.length > 0) {
        const entry = this.mailbox.shift();
        if (entry === undefined) break;
        await this.host.dispatch(entry.message, entry.seq);
      }
    } finally {
      this.pumping = false;
    }
  }
}
