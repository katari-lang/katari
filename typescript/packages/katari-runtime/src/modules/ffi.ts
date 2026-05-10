// FfiModule — runtime 側の FFI Runner。`Module` interface 実装。
//
// 役割:
//
//   1. CORE → FFI 方向の 6 event のうち、自分宛 inbound (= delegate /
//      terminate / escalateAck) を受け取り、対応する IPC message を
//      sidecar に送る。同時に自分の `FfiStore` に persistent 状態を書く。
//
//   2. Sidecar からの child→parent message (= delegateAck / terminateAck
//      / escalate / delegateError) を受け取って、bus に逆向き ExternalEvent
//      を push する (async)。
//
//   3. 起動直後の復旧 (`recoverInflight`): `FfiStore.listDelegations()` を
//      読み、各 delegation について sidecar に `restoredDelegate` を送る。
//      sidecar 側 (= user code) が per-delegation で「冪等じゃないので
//      delegateError 返す」「冪等なので走らせる」を選ぶ。escalation は
//      sidecar 跨ぎで継続不能なので drop + warn。
//
// 注意: 1 FfiModule = 1 sidecar = 1 snapshot scope。`ffiStore` は予め
// その scope に bind 済みのインスタンスを受け取る (= storage layer 側で
// 構築する)。

import type { AgentDefId } from "../agent-def-id.js";
import { CORE_ENDPOINT, FFI_ENDPOINT } from "./endpoints.js";
import type { ExternalEvent } from "../engine/event.js";
import type { DelegationId, EscalationId } from "../engine/id.js";
import type { Endpoint } from "../engine/endpoint.js";
import type { Logger } from "../engine/logger.js";
import type { Value } from "../engine/value.js";
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

export class FfiModule implements Module {
  readonly endpoint: Endpoint;
  private readonly sidecar: Sidecar;
  private readonly store: FfiStore;
  private readonly logger: Logger;
  private readonly onSidecarResponse: (event: ExternalEvent) => void;

  constructor(opts: FfiModuleOptions) {
    this.endpoint = opts.endpoint ?? FFI_ENDPOINT;
    this.sidecar = opts.sidecar;
    this.store = opts.store;
    this.logger = opts.logger;
    this.onSidecarResponse = opts.onSidecarResponse;

    this.sidecar.onMessage((msg) => this.handleSidecarMessage(msg));
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
      case "escalateAck":
        await this.handleInboundEscalateAck(event);
        return { outbound: [] };
      case "delegateAck":
      case "terminateAck":
      case "escalate":
        // FFI Module は受信側ではない方向の event。Bus が誤って
        // routing しない限り来ない。drop with debug log。
        this.logger.log("debug", "ffi: unexpected inbound event for FFI", {
          kind: event.payload.kind,
          from: event.from,
        });
        return { outbound: [] };
    }
  }

  /** State は store に書き通すので no-op。 */
  async persist(): Promise<void> {}
  async load(): Promise<void> {}

  // ─── Recovery ──────────────────────────────────────────────────────────

  /**
   * Server 起動直後に呼ぶ。store から in-flight delegation を読んで sidecar
   * に `restoredDelegate` を送り、escalation は drop + warn する。
   *
   * 注: sidecar が起動済み (= `start()` 済) であることを前提とする。
   */
  async recoverInflight(): Promise<void> {
    const delegations = await this.store.listDelegations();
    for (const row of delegations) {
      try {
        await this.sidecar.send({
          type: "restoredDelegate",
          delegationId: row.delegationId,
          agentDefId: row.agentDefId,
          args: row.args,
        });
      } catch (err) {
        this.logger.log("error", "ffi: restoredDelegate send failed", {
          delegationId: row.delegationId,
          err: err instanceof Error ? err.message : String(err),
        });
      }
    }

    const escalations = await this.store.listEscalations();
    for (const row of escalations) {
      this.logger.log("warn", "ffi: dropping cross-restart escalation", {
        escalationId: row.escalationId,
        delegationId: row.delegationId,
      });
      await this.store.deleteEscalation(row.escalationId);
      // CORE が以後 escalateAck を投げてくる場合に備えてレコードは消す。
      // 対応する delegation は restoredDelegate で別途 user に判断させる。
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
    });
    await this.sidecar.send({
      type: "delegate",
      delegationId,
      agentDefId,
      args,
    });
  }

  private async handleInboundTerminate(event: ExternalEvent): Promise<void> {
    if (event.payload.kind !== "terminate") return;
    const { delegationId } = event.payload;
    const ok = await this.store.setDelegationState(delegationId, "cancelling");
    if (!ok) {
      this.logger.log("debug", "ffi: terminate for unknown delegation", {
        delegationId,
      });
      return;
    }
    await this.sidecar.send({ type: "terminate", delegationId });
  }

  private async handleInboundEscalateAck(event: ExternalEvent): Promise<void> {
    if (event.payload.kind !== "escalateAck") return;
    const { escalationId, value } = event.payload;
    const pending = await this.store.getEscalation(escalationId);
    if (pending === null) {
      this.logger.log("debug", "ffi: escalateAck for unknown escalation", {
        escalationId,
      });
      return;
    }
    await this.store.deleteEscalation(escalationId);
    await this.sidecar.send({ type: "escalateAck", escalationId, value });
  }

  // ─── Outbound (Sidecar → FFI → bus) ────────────────────────────────────

  private handleSidecarMessage(msg: ChildToParent): void {
    void this.dispatchSidecarMessage(msg).catch((err) => {
      this.logger.log("error", "ffi: dispatch sidecar message threw", {
        type: msg.type,
        err: err instanceof Error ? err.message : String(err),
      });
    });
  }

  private async dispatchSidecarMessage(msg: ChildToParent): Promise<void> {
    switch (msg.type) {
      case "ready":
        return;
      case "log":
        this.logger.log(msg.level, `sidecar: ${msg.message}`, msg.context);
        return;
      case "delegateAck": {
        const peer = await this.consumePendingDelegationPeer(msg.delegationId);
        if (peer === null) return;
        this.onSidecarResponse({
          from: this.endpoint,
          to: peer,
          payload: {
            kind: "delegateAck",
            delegationId: msg.delegationId,
            value: msg.value,
          },
        });
        return;
      }
      case "delegateError": {
        const peer = await this.consumePendingDelegationPeer(msg.delegationId);
        this.logger.log("warn", "sidecar reported delegate error", {
          delegationId: msg.delegationId,
          message: msg.message,
        });
        if (peer === null) return;
        // v1: surface as terminateAck (= treat as "the call ended without
        // a value"). Future protocol revision should add a dedicated
        // `delegateError` external event.
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
      case "terminateAck": {
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
      case "escalate": {
        const peer = await this.peerForDelegation(msg.delegationId);
        if (peer === null) return;
        await this.store.insertEscalation({
          escalationId: msg.escalationId,
          delegationId: msg.delegationId,
          peerEndpoint: peer,
          agentDefId: msg.agentDefId,
          args: msg.args,
          createdAt: new Date().toISOString(),
        });
        this.onSidecarResponse({
          from: this.endpoint,
          to: peer,
          payload: {
            kind: "escalate",
            delegationId: msg.delegationId,
            escalationId: msg.escalationId,
            agentDefId: msg.agentDefId,
            args: msg.args,
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
    await this.store.deleteDelegation(delegationId);
    return row.peerEndpoint;
  }

  /** Pending delegation の peer (escalate 用) を引く (削除はしない)。 */
  private async peerForDelegation(
    delegationId: DelegationId,
  ): Promise<Endpoint | null> {
    const row = await this.store.getDelegation(delegationId);
    if (row === null) {
      this.logger.log("debug", "ffi: escalate for unknown delegationId", {
        delegationId,
      });
      return null;
    }
    return row.peerEndpoint;
  }
}

// type re-exports for convenience
export type { AgentDefId, EscalationId, Value };
void CORE_ENDPOINT;
