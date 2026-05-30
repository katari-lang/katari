// FfiModule — runtime-side FFI Runner. Implements the `Module` interface.
//
// Role (protocol v2, 11 message variants):
//
//   1. Receive CORE -> FFI inbound events and forward them to the sidecar
//      or bus:
//
//        - `delegate` (CORE called ext): store insert + `ipcDelegate`
//        - `terminate` (CORE cancelled ext): store setState + `ipcTerminate`
//        - `delegateAck` / `terminateAck` (= child agent spawned by ext finished):
//          look up the "parent ext delegation" from the store and send
//          `ipcChildDelegateAck` / `ipcChildTerminateAck` to the sidecar
//        - `escalate` (= escalate emitted by ext-spawned child agent):
//          re-push to the bus targeting "the caller of the parent ext delegation"
//          (do not deliver to the sidecar; reaches the DelegateThread handle scope chain)
//        - `escalateAck` (reverse-direction ack for the above escalate): look up
//          the original child's endpoint from the in-memory escalation map and
//          likewise re-push to the bus
//
//   2. Receive `ChildToParent` from the sidecar and update bus / store:
//
//        - `ipcReady`: absorbed by start() during handshake, so only spurious here
//        - `ipcDelegateAck` / `ipcDelegateError` / `ipcTerminateAck`:
//          end of ext invocation. Look up peer from store and emit reverse bus event
//        - `ipcChildDelegate`: ext launched a child agent on the CORE side.
//          store insert with parentExtDelegationId + fire
//          `{from: FFI, to: CORE, kind: delegate}` on the bus
//        - `ipcChildTerminate`: ext cancelled a child. Fire terminate on the bus
//
//   3. Recovery right after startup (`recoverInflight`):
//
//        - parent ext delegation (= `parentExtDelegationId === null`): send
//          `ipcDelegateRestarted` to inform the handler "after restart"
//        - child delegation (= one spawned by ext via katari.delegate): the
//          ext-side Promise is lost, so fire terminate on the CORE side + delete
//          from store (orphan cleanup)
//        - any remaining escalation rows are deleted (cannot continue across sidecars)
//
// Note: 1 FfiModule = 1 sidecar = 1 snapshot scope. `ffiStore` must be an
// instance already bound to that scope (= constructed by the storage layer).

import {
  encodeCoreAgentDefId,
  stampAgentDefIdSnapshot,
  stripAgentDefIdSnapshot,
} from "../agent-def-id.js";
import type { Endpoint } from "../engine/endpoint.js";
import type { ExternalEvent } from "../engine/event.js";
import { createEscalationId, type DelegationId, type EscalationId } from "../engine/id.js";
import type { Logger } from "../engine/logger.js";
import { mkString, type Value } from "../engine/value.js";
import type { Module } from "../module.js";
import type { Sidecar } from "../sidecar/sidecar.js";
import type { FfiStore } from "../sidecar/store.js";
import type { ChildToParent } from "../sidecar/types.js";
import type { RawValue } from "../value-codec.js";
import { valueFromRaw, valueToRaw } from "../value-codec.js";
import { decryptValueRecord, encryptValueRecord } from "../value-secret-codec.js";
import { CORE_ENDPOINT, FFI_ENDPOINT } from "./endpoints.js";

export type FfiModuleOptions = {
  /**
   * Module's self endpoint. Default is {@link FFI_ENDPOINT} (`ext://ffi`).
   * If multiple FFI modules need to coexist (future), distinguish them by endpoint.
   */
  endpoint?: Endpoint;
  /**
   * The snapshot this FfiModule (= one sidecar) runs. Used to stamp the
   * snapshot onto a CORE child agent the ext spawns (`ipcChildDelegate`)
   * so CORE creates that child shard on the right IR version. Inbound
   * delegates arrive already stamped (CORE → FFI); we strip the stamp
   * before the sidecar sees the agent def id (its handler registry is
   * keyed by the bare qname — the sidecar already IS this snapshot's code).
   */
  snapshotId: string;
  /** Sidecar corresponding to one FfiModule (per-snapshot). `null` not allowed. */
  sidecar: Sidecar;
  /** Callback to push sidecar responses onto the bus. */
  onSidecarResponse: (event: ExternalEvent) => void;
  /** Persistence layer. Must be already bound to the snapshot scope. */
  store: FfiStore;
  logger: Logger;
};

interface EscalationRelayEntry {
  /** Original (= source) child delegationId that produced the escalate. */
  childDelegationId: DelegationId;
}

export class FfiModule implements Module {
  readonly endpoint: Endpoint;
  private readonly snapshotId: string;
  private readonly sidecar: Sidecar;
  private readonly store: FfiStore;
  private readonly logger: Logger;
  private readonly onSidecarResponse: (event: ExternalEvent) => void;
  /**
   * In-memory escalation relay state. Keyed by `escalationId` (= the
   * id the sender assigned). Rebuilt from the persistent store via
   * 'load()' so a server restart does not strand pending escalations:
   * the rows have always been written to FfiStore, the previous
   * comment claiming "lost on restart by design" was contradicted by
   * the (still-present) DB rows. After load the map matches the rows;
   * inbound escalateAck during the partial-restart window now finds
   * its entry rather than dropping as "unknown escalation".
   */
  private readonly escalations = new Map<EscalationId, EscalationRelayEntry>();

  constructor(opts: FfiModuleOptions) {
    this.endpoint = opts.endpoint ?? FFI_ENDPOINT;
    this.snapshotId = opts.snapshotId;
    this.sidecar = opts.sidecar;
    this.store = opts.store;
    this.logger = opts.logger;
    this.onSidecarResponse = opts.onSidecarResponse;
    // Note: we do NOT subscribe `sidecar.onMessage` here. The host
    // (orchestrator / api-server) owns the long-lived sidecar message
    // pump; it calls `dispatchSidecarMessage` from inside a tick so
    // every message is processed through the per-tick FfiModule (and
    // the transactional store it owns).
  }

  // ─── Module interface ───────────────────────────────────────────────────

  async feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }> {
    switch (event.payload.kind) {
      case "delegate":
        await this.handleInboundDelegate(event);
        return { outbound: [] };
      case "terminate":
        await this.handleInboundTerminate(event);
        return { outbound: [] };
      case "delegateAck":
        await this.handleInboundChildDelegateAck(event);
        return { outbound: [] };
      case "terminateAck":
        await this.handleInboundChildTerminateAck(event);
        return { outbound: [] };
      case "escalate":
        await this.handleInboundEscalate(event);
        return { outbound: [] };
      case "escalateAck":
        await this.handleInboundEscalateAck(event);
        return { outbound: [] };
    }
  }

  /** State is fully written through to the store, so persist is a no-op. */
  async persist(): Promise<void> {}

  /**
   * Rebuild the in-memory escalation relay map from the persistent
   * store. Called by the orchestrator at the start of every tick that
   * uses this FfiModule. Idempotent — repopulating an already-populated
   * map yields the same entries.
   */
  async load(): Promise<void> {
    const rows = await this.store.listEscalations();
    this.escalations.clear();
    for (const row of rows) {
      this.escalations.set(row.escalationId, {
        childDelegationId: row.delegationId,
      });
    }
  }

  // ─── Recovery ──────────────────────────────────────────────────────────

  /**
   * Call immediately after server startup. Reconciles in-flight rows in
   * the store as follows:
   *
   *   - parent (`parentExtDelegationId === null`): send `ipcDelegateRestarted`
   *   - child (`parentExtDelegationId != null`): fire terminate on the bus +
   *     delete from store (= ext-side Promise is gone, so force-kill the CORE side)
   *
   * Note: assumes the sidecar is already started (= `start()` has been called).
   */
  async recoverInflight(): Promise<void> {
    const delegations = await this.store.listDelegations();
    const orphanChildren: typeof delegations = [];
    const parents: typeof delegations = [];
    for (const row of delegations) {
      if (row.parentExtDelegationId === null) parents.push(row);
      else orphanChildren.push(row);
    }

    // Send the restart notification first — to avoid a race where the
    // sidecar re-spawns a child, run the handler before the orphan terminate.
    for (const row of parents) {
      try {
        await this.sidecar.send({
          type: "ipcDelegateRestarted",
          delegationId: row.delegationId,
          agentDefId: row.agentDefId,
          args: argsToRaw(decryptValueRecord(row.args)),
        });
      } catch (err) {
        this.logger.log("error", "ffi: ipcDelegateRestarted send failed", {
          delegationId: row.delegationId,
          err: err instanceof Error ? err.message : String(err),
        });
      }
    }

    for (const row of orphanChildren) {
      // Tell CORE to terminate the orphan child agent thread, then drop
      // the row. CORE will eventually emit `terminateAck` for it on the
      // bus; our terminateAck handler will see "child of an unknown
      // ext", treat it as already-cleaned, and drop again.
      this.onSidecarResponse({
        from: this.endpoint,
        to: CORE_ENDPOINT,
        payload: {
          kind: "terminate",
          delegationId: row.delegationId,
        },
      });
      await this.store.deleteDelegation(row.delegationId);
    }

    // Escalations are preserved across restarts: the persisted rows
    // are the source of truth, and 'load()' rebuilds the in-memory
    // relay map. An inbound escalateAck arriving after the restart but
    // before its corresponding ipcDelegateRestarted now finds its
    // entry rather than dropping as "unknown".
  }

  // ─── Inbound handlers (CORE → FFI) ────────────────────────────────────

  private async handleInboundDelegate(event: ExternalEvent): Promise<void> {
    if (event.payload.kind !== "delegate") return;
    const { delegationId, args } = event.payload;
    // CORE stamped the snapshot onto the target (`ext.qname@snapshot`) so the
    // bus could carry it; the sidecar's handler registry is keyed by the bare
    // qname, so we strip it here. The snapshot lives on the store row's
    // dedicated column, so recovery (`ipcDelegateRestarted`, which re-sends
    // `row.agentDefId`) keeps presenting the bare form to the sidecar.
    const agentDefId = stripAgentDefIdSnapshot(event.payload.agentDefId);
    await this.store.insertDelegation({
      delegationId,
      peerEndpoint: event.from,
      agentDefId,
      args: encryptValueRecord(args),
      state: "running",
      createdAt: new Date().toISOString(),
      parentExtDelegationId: null,
    });
    // The insert + send pair is not atomic across systems (the store is
    // a DB tx scoped to the outer tick, the sidecar is a separate
    // process). If the send throws, compensate by deleting the row we
    // just inserted so the recovery sweep doesn't ship a
    // `ipcDelegateRestarted` for a delegation the sidecar never heard
    // about. The CORE caller still gets the rejection so its
    // DelegateThread can transition to error.
    try {
      await this.sidecar.send({
        type: "ipcDelegate",
        delegationId,
        agentDefId,
        args: argsToRaw(args),
      });
    } catch (err) {
      try {
        await this.store.deleteDelegation(delegationId);
      } catch {
        /* swallow cleanup error — original send error is what matters */
      }
      throw err;
    }
  }

  private async handleInboundTerminate(event: ExternalEvent): Promise<void> {
    if (event.payload.kind !== "terminate") return;
    const { delegationId } = event.payload;
    const ok = await this.store.setDelegationState(delegationId, "cancelling");
    if (!ok) {
      // The delegation was already removed (e.g. ipcDelegateError consumed it
      // before CORE's cancel cascade reached us). Immediately ack so the
      // DelegateThread on the CORE side can finish its cancellation.
      this.logger.log(
        "debug",
        "ffi: terminate for unknown delegation — sending immediate terminateAck",
        {
          delegationId,
        },
      );
      this.onSidecarResponse({
        from: this.endpoint,
        to: event.from,
        payload: { kind: "terminateAck", delegationId },
      });
      return;
    }
    await this.sidecar.send({
      type: "ipcTerminate",
      delegationId,
    });
  }

  /**
   * `from: CORE, to: FFI, kind: delegateAck` — ext-spawned child agent
   * completed successfully. Look up the child row from the store and send
   * `ipcChildDelegateAck` to the sidecar of the parent ext call.
   */
  private async handleInboundChildDelegateAck(event: ExternalEvent): Promise<void> {
    if (event.payload.kind !== "delegateAck") return;
    const { delegationId, value } = event.payload;
    const row = await this.store.getDelegation(delegationId);
    if (row === null) {
      this.logger.log("debug", "ffi: delegateAck for unknown child", {
        delegationId,
      });
      return;
    }
    if (row.parentExtDelegationId === null) {
      this.logger.log(
        "warn",
        "ffi: delegateAck arrived for non-child delegation (= unexpected, dropping)",
        { delegationId },
      );
      return;
    }
    await this.store.deleteDelegation(delegationId);
    await this.sidecar.send({
      type: "ipcChildDelegateAck",
      delegationId,
      value: valueToRaw(value),
    });
  }

  /**
   * `from: CORE, to: FFI, kind: terminateAck` — cancel of ext-spawned
   * child agent completed.
   */
  private async handleInboundChildTerminateAck(event: ExternalEvent): Promise<void> {
    if (event.payload.kind !== "terminateAck") return;
    const { delegationId } = event.payload;
    const row = await this.store.getDelegation(delegationId);
    if (row === null) {
      // Could be the orphan-cleanup pass acking after recoverInflight
      // already deleted the row. Silent drop.
      this.logger.log("debug", "ffi: terminateAck for unknown child", {
        delegationId,
      });
      return;
    }
    if (row.parentExtDelegationId === null) {
      this.logger.log(
        "warn",
        "ffi: terminateAck arrived for non-child delegation (= unexpected, dropping)",
        { delegationId },
      );
      return;
    }
    await this.store.deleteDelegation(delegationId);
    await this.sidecar.send({
      type: "ipcChildTerminateAck",
      delegationId,
    });
  }

  /**
   * Escalate relay. A CORE-side child agent (= one the ext spawned via
   * `katari.delegate`) raised a req ask, its root AgentThread had no
   * handler, so `emitEscalateUpward` shipped the event to us. Look up
   * the owning ext delegation's caller and re-push the escalate on the
   * bus to that caller — the sidecar is bypassed.
   */
  private async handleInboundEscalate(event: ExternalEvent): Promise<void> {
    if (event.payload.kind !== "escalate") return;
    const { delegationId, escalationId, agentDefId, args } = event.payload;
    const childRow = await this.store.getDelegation(delegationId);
    if (childRow === null) {
      this.logger.log("debug", "ffi: escalate for unknown child delegation", {
        delegationId,
        escalationId,
      });
      return;
    }
    if (childRow.parentExtDelegationId === null) {
      this.logger.log("warn", "ffi: escalate from non-child delegation (dropping)", {
        delegationId,
      });
      return;
    }
    const parentRow = await this.store.getDelegation(childRow.parentExtDelegationId);
    if (parentRow === null) {
      this.logger.log("debug", "ffi: escalate parent already gone", {
        delegationId,
        parentExtDelegationId: childRow.parentExtDelegationId,
      });
      return;
    }
    this.escalations.set(escalationId, {
      childDelegationId: delegationId,
    });
    // Persist alongside the in-memory entry so a server restart that
    // happens before the matching escalateAck arrives can rebuild this
    // map via load(). Without the store write, the load() reconstruction
    // path is dead code.
    await this.store.insertEscalation({
      escalationId,
      delegationId,
      peerEndpoint: parentRow.peerEndpoint,
      agentDefId,
      args: encryptValueRecord(args),
      createdAt: new Date().toISOString(),
    });
    this.onSidecarResponse({
      from: this.endpoint,
      to: parentRow.peerEndpoint,
      payload: {
        kind: "escalate",
        delegationId: childRow.parentExtDelegationId,
        escalationId,
        agentDefId,
        args,
      },
    });
  }

  /**
   * Escalate ack relay. The handle scope handler returned; ship the ack
   * back toward the original child via CORE.
   */
  private async handleInboundEscalateAck(event: ExternalEvent): Promise<void> {
    if (event.payload.kind !== "escalateAck") return;
    const { escalationId, value } = event.payload;
    const entry = this.escalations.get(escalationId);
    if (entry === undefined) {
      this.logger.log(
        "debug",
        "ffi: escalateAck for unknown escalation (= probably restart-dropped)",
        { escalationId },
      );
      return;
    }
    this.escalations.delete(escalationId);
    // Mirror into the store so a restart doesn't resurrect an
    // already-acknowledged escalation.
    await this.store.deleteEscalation(escalationId);
    this.onSidecarResponse({
      from: this.endpoint,
      to: CORE_ENDPOINT,
      payload: {
        kind: "escalateAck",
        escalationId,
        value,
      },
    });
  }

  // ─── Outbound (Sidecar → FFI → bus) ────────────────────────────────────

  /**
   * Process one `ChildToParent` IPC message. The host (orchestrator)
   * calls this from inside a tick so the per-tick FfiModule + store
   * stay transactional. Errors are logged + swallowed (= a bad message
   * shouldn't crash the orchestrator's tick).
   */
  async dispatchSidecarMessage(msg: ChildToParent): Promise<void> {
    switch (msg.type) {
      case "ipcReady":
        // Handshake absorbed by start(). If we reach here, it's a spurious
        // re-emit (= sidecar-side bug), so drop.
        this.logger.log("debug", "ffi: spurious ready from sidecar");
        return;
      case "ipcDelegateAck": {
        const peer = await this.consumePendingDelegationPeer(msg.delegationId);
        if (peer === null) return;
        this.onSidecarResponse({
          from: this.endpoint,
          to: peer,
          payload: {
            kind: "delegateAck",
            delegationId: msg.delegationId,
            value: valueFromRaw(msg.value),
          },
        });
        return;
      }
      case "ipcDelegateError": {
        const peer = await this.consumePendingDelegationPeer(msg.delegationId);
        this.logger.log("warn", "sidecar reported delegate error", {
          delegationId: msg.delegationId,
          message: msg.message,
        });
        if (peer === null) return;
        // Route as a throw escalate so the caller can handle it via
        // `handle { req throw(msg) { ... } }` or the API Module's default
        // handler marks the snapshot as errored.
        this.onSidecarResponse({
          from: this.endpoint,
          to: peer,
          payload: {
            kind: "escalate",
            delegationId: msg.delegationId,
            escalationId: createEscalationId(),
            agentDefId: encodeCoreAgentDefId({ kind: "qname", value: "primitive.throw" }),
            args: { msg: mkString(msg.message) },
          },
        });
        return;
      }
      case "ipcTerminateAck": {
        const peer = await this.consumePendingDelegationPeer(msg.delegationId);
        if (peer === null) return;
        this.onSidecarResponse({
          from: this.endpoint,
          to: peer,
          payload: {
            kind: "terminateAck",
            delegationId: msg.delegationId,
          },
        });
        return;
      }
      case "ipcChildDelegate": {
        // Ext is starting a CORE-side child. The sidecar names it by bare
        // qname (the ext called `katari.delegate("some.agent", ...)` with no
        // notion of snapshots); stamp this sidecar's snapshot so CORE creates
        // the child shard on the matching IR version. Persist the child row
        // (parentExtDelegationId pointing at the ext call) and push a delegate
        // event on the bus toward CORE.
        const convertedArgs = argsFromRaw(msg.args);
        const agentDefId = stampAgentDefIdSnapshot(msg.agentDefId, this.snapshotId);
        await this.store.insertDelegation({
          delegationId: msg.delegationId,
          peerEndpoint: this.endpoint, // ack comes back to us
          agentDefId,
          args: encryptValueRecord(convertedArgs),
          state: "running",
          createdAt: new Date().toISOString(),
          parentExtDelegationId: msg.parentDelegationId,
        });
        this.onSidecarResponse({
          from: this.endpoint,
          to: CORE_ENDPOINT,
          payload: {
            kind: "delegate",
            delegationId: msg.delegationId,
            agentDefId,
            args: convertedArgs,
          },
        });
        return;
      }
      case "ipcChildTerminate": {
        const row = await this.store.getDelegation(msg.delegationId);
        if (row === null || row.parentExtDelegationId === null) {
          this.logger.log("debug", "ffi: child terminate for unknown child", {
            delegationId: msg.delegationId,
          });
          return;
        }
        await this.store.setDelegationState(msg.delegationId, "cancelling");
        this.onSidecarResponse({
          from: this.endpoint,
          to: CORE_ENDPOINT,
          payload: {
            kind: "terminate",
            delegationId: msg.delegationId,
          },
        });
        return;
      }
    }
  }

  /** Look up the pending delegation, return its peer, and delete the record. */
  private async consumePendingDelegationPeer(delegationId: DelegationId): Promise<Endpoint | null> {
    const row = await this.store.getDelegation(delegationId);
    if (row === null) {
      this.logger.log("debug", "ffi: response for unknown delegationId", {
        delegationId,
      });
      return null;
    }
    if (row.parentExtDelegationId !== null) {
      this.logger.log(
        "warn",
        "ffi: ext-handler ack arrived for a child delegation (= unexpected)",
        { delegationId },
      );
      return null;
    }
    await this.store.deleteDelegation(delegationId);
    return row.peerEndpoint;
  }
}

// type re-exports for convenience
export type { Value };

// ─── Value ↔ Raw helpers (sidecar wire boundary) ───────────────────────────
//
// The bus / CORE event types carry `Value` (tagged) everywhere. The sidecar
// IPC speaks raw JSON shapes (`RawValue`). Convert at the boundary so
// user-implemented sidecar handlers see plain `{x: 5}` instead of
// `{x: {kind: "number", value: 5}}`.

function argsToRaw(args: Record<string, Value>): Record<string, RawValue> {
  const out: Record<string, RawValue> = {};
  for (const [k, v] of Object.entries(args)) out[k] = valueToRaw(v);
  return out;
}

function argsFromRaw(args: Record<string, RawValue>): Record<string, Value> {
  const out: Record<string, Value> = {};
  for (const [k, v] of Object.entries(args)) out[k] = valueFromRaw(v);
  return out;
}
