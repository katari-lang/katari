// FfiModule — runtime 側の FFI Runner。`Module` interface 実装。
//
// 役割 (protocol v2, 11 message variants):
//
//   1. CORE → FFI 方向の inbound event を受け取って sidecar や bus に
//      取り次ぐ:
//
//        - `delegate` (CORE が ext を呼んだ): store insert + `ipcDelegate`
//        - `terminate` (CORE が ext を cancel): store setState + `ipcTerminate`
//        - `delegateAck` / `terminateAck` (= ext が起こした child agent の終了):
//          store から「親 ext delegation」 を引いて sidecar に
//          `ipcChildDelegateAck` / `ipcChildTerminateAck` を返す
//        - `escalate` (= ext-spawned child agent が発火した escalate):
//          そのまま「親 ext delegation の caller」 に向けて bus に再 push
//          (sidecar には届けない、 ExternalThread の handle scope chain に届く)
//        - `escalateAck` (上の escalate に対する逆方向 ack): in-memory
//          escalation map から original child の endpoint を引き、 同じく
//          bus に再 push
//
//   2. Sidecar からの `ChildToParent` を受けて bus / store を更新:
//
//        - `ipcReady`: handshake で start() に吸われるので spurious のみ
//        - `ipcDelegateAck` / `ipcDelegateError` / `ipcTerminateAck`:
//          ext invocation の終了。 store から peer を引いて逆向き bus event
//        - `ipcChildDelegate`: ext が CORE 側に child agent を起動。
//          parentExtDelegationId 付きで store insert + bus に
//          `{from: FFI, to: CORE, kind: delegate}` を発火
//        - `ipcChildTerminate`: ext が child を cancel。 bus に terminate を発火
//
//   3. 起動直後の復旧 (`recoverInflight`):
//
//        - parent ext delegation (= `parentExtDelegationId === null`) には
//          `ipcDelegateRestarted` を投げて handler に「restart 後」 と知らせる
//        - 子 delegation (= ext が katari.delegate で起こしたもの) は ext
//          側 Promise が失われているので CORE 側で terminate を発火 + store
//          から削除 (orphan cleanup)
//        - 残ってる escalation row は全削除 (sidecar 跨ぎで継続不能)
//
// 注意: 1 FfiModule = 1 sidecar = 1 snapshot scope。`ffiStore` は予め
// その scope に bind 済みのインスタンスを受け取る (= storage layer 側で
// 構築する)。

import { CORE_ENDPOINT, FFI_ENDPOINT } from "./endpoints.js";
import type { ExternalEvent } from "../engine/event.js";
import { createEscalationId, type DelegationId, type EscalationId } from "../engine/id.js";
import { encodeCoreAgentDefId } from "../agent-def-id.js";
import type { Endpoint } from "../engine/endpoint.js";
import type { Logger } from "../engine/logger.js";
import type { Value } from "../engine/value.js";
import { valueFromRaw, valueToRaw } from "../value-codec.js";
import type { RawValue } from "../value-codec.js";
import type { Module } from "../module.js";
import type { Sidecar } from "../sidecar/sidecar.js";
import type { FfiStore } from "../sidecar/store.js";
import type { ChildToParent } from "../sidecar/types.js";

export type FfiModuleOptions = {
  /**
   * Module の self endpoint。デフォルトは {@link FFI_ENDPOINT} (`ext://ffi`)。
   * 複数 FFI module を併存させたい場合 (将来) は別 endpoint で区別する。
   */
  endpoint?: Endpoint;
  /** 1 FfiModule に対応する sidecar (per-snapshot)。`null` 不可。 */
  sidecar: Sidecar;
  /** Sidecar からの応答を bus に投げる callback。 */
  onSidecarResponse: (event: ExternalEvent) => void;
  /** 永続化レイヤ。snapshot scope に bind 済みであること。 */
  store: FfiStore;
  logger: Logger;
};

interface EscalationRelayEntry {
  /** Original (= source) child delegationId that produced the escalate. */
  childDelegationId: DelegationId;
}

export class FfiModule implements Module {
  readonly endpoint: Endpoint;
  private readonly sidecar: Sidecar;
  private readonly store: FfiStore;
  private readonly logger: Logger;
  private readonly onSidecarResponse: (event: ExternalEvent) => void;
  /**
   * In-memory escalation relay state. Keyed by `escalationId` (= the
   * id the sender assigned). Lost on restart by design — that matches
   * the user-approved policy: pending escalations across restarts get
   * dropped, and the eventual ack is treated as unknown.
   */
  private readonly escalations = new Map<EscalationId, EscalationRelayEntry>();

  constructor(opts: FfiModuleOptions) {
    this.endpoint = opts.endpoint ?? FFI_ENDPOINT;
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

  /** State は store に書き通すので no-op。 */
  async persist(): Promise<void> {}
  async load(): Promise<void> {}

  // ─── Recovery ──────────────────────────────────────────────────────────

  /**
   * Server 起動直後に呼ぶ。 store の in-flight rows を以下のように整理する:
   *
   *   - parent (`parentExtDelegationId === null`): `ipcDelegateRestarted` 送信
   *   - child (`parentExtDelegationId != null`): bus に terminate を発火 +
   *     store から削除 (= ext 側 Promise が消えてるので CORE 側を強制 kill)
   *
   * 注: sidecar が起動済み (= `start()` 済) であることを前提とする。
   */
  async recoverInflight(): Promise<void> {
    const delegations = await this.store.listDelegations();
    const orphanChildren: typeof delegations = [];
    const parents: typeof delegations = [];
    for (const row of delegations) {
      if (row.parentExtDelegationId === null) parents.push(row);
      else orphanChildren.push(row);
    }

    // Restart 通知を先に送る — sidecar が child を再 spawn する race を
    // 避けるため、 orphan terminate より先に handler に走らせる。
    for (const row of parents) {
      try {
        await this.sidecar.send({
          type: "ipcDelegateRestarted",
          delegationId: row.delegationId,
          agentDefId: row.agentDefId,
          args: argsToRaw(row.args),
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

    // Escalations across restarts are unsalvageable: the sidecar's
    // in-memory pendingEscalations map is gone too. Wipe whatever's in
    // the store.
    const escalations = await this.store.listEscalations();
    for (const row of escalations) {
      this.logger.log("warn", "ffi: dropping stale escalation row", {
        escalationId: row.escalationId,
        delegationId: row.delegationId,
      });
      await this.store.deleteEscalation(row.escalationId);
    }
  }

  // ─── Inbound handlers (CORE → FFI) ────────────────────────────────────

  private async handleInboundDelegate(event: ExternalEvent): Promise<void> {
    if (event.payload.kind !== "delegate") return;
    const { delegationId, agentDefId, args } = event.payload;
    await this.store.insertDelegation({
      delegationId,
      peerEndpoint: event.from,
      agentDefId,
      args,
      state: "running",
      createdAt: new Date().toISOString(),
      parentExtDelegationId: null,
    });
    await this.sidecar.send({
      type: "ipcDelegate",
      delegationId,
      agentDefId,
      args: argsToRaw(args),
    });
  }

  private async handleInboundTerminate(event: ExternalEvent): Promise<void> {
    if (event.payload.kind !== "terminate") return;
    const { delegationId } = event.payload;
    const ok = await this.store.setDelegationState(delegationId, "cancelling");
    if (!ok) {
      // The delegation was already removed (e.g. ipcDelegateError consumed it
      // before CORE's cancel cascade reached us). Immediately ack so the
      // ExternalThread on the CORE side can finish its cancellation.
      this.logger.log("debug", "ffi: terminate for unknown delegation — sending immediate terminateAck", {
        delegationId,
      });
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
   * が成功裏に完了した。 child row を store から引いて、 親 ext call の
   * sidecar に `ipcChildDelegateAck` を投げる。
   */
  private async handleInboundChildDelegateAck(
    event: ExternalEvent,
  ): Promise<void> {
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
   * `from: CORE, to: FFI, kind: terminateAck` — ext-spawned child agent
   * の cancel が完了した。
   */
  private async handleInboundChildTerminateAck(
    event: ExternalEvent,
  ): Promise<void> {
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
      this.logger.log(
        "warn",
        "ffi: escalate from non-child delegation (dropping)",
        { delegationId },
      );
      return;
    }
    const parentRow = await this.store.getDelegation(
      childRow.parentExtDelegationId,
    );
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
    this.onSidecarResponse({
      from: this.endpoint,
      to: CORE_ENDPOINT,
      payload: {
        kind: "escalateAck",
        escalationId,
        value,
      },
    });
    // Avoid lint for unused variable in case of future refactor
    void entry;
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
        // start() で吸い取られる handshake。 ここに来たら spurious 再 emit
        // (= sidecar 側の bug) なので drop。
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
            agentDefId: encodeCoreAgentDefId({ kind: "qname", value: "prim.throw" }),
            args: { msg: { kind: "string", value: msg.message } },
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
        // Ext is starting a CORE-side child. Persist the child row
        // (parentExtDelegationId pointing at the ext call) and push a
        // delegate event on the bus toward CORE.
        await this.store.insertDelegation({
          delegationId: msg.delegationId,
          peerEndpoint: this.endpoint, // ack comes back to us
          agentDefId: msg.agentDefId,
          args: argsFromRaw(msg.args),
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
            agentDefId: msg.agentDefId,
            args: argsFromRaw(msg.args),
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

  /** Pending delegation を引いて peer を返し、レコード削除。 */
  private async consumePendingDelegationPeer(
    delegationId: DelegationId,
  ): Promise<Endpoint | null> {
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
