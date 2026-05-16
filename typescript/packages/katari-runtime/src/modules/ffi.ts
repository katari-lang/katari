// FfiModule — runtime 側の FFI Runner。`Module` interface 実装。
//
// 役割 (protocol v1, 7 message variants):
//
//   1. CORE → FFI 方向の inbound event (= delegate / terminate) を受け取り、
//      対応する `ParentToChild` IPC message を sidecar に送る。同時に自分の
//      `FfiStore` に persistent 状態を書く。
//
//   2. Sidecar からの `ChildToParent` (= ready / delegateAck / delegateError
//      / terminateAck) を受け取って、bus に逆向き ExternalEvent を push
//      する (async)。`ready` は handshake で `SubprocessSidecar.start()` 内
//      で吸い取られるので、ここに届くのは spurious 再 emit のみ。
//
//   3. 起動直後の復旧 (`recoverInflight`): `FfiStore.listDelegations()` を
//      読み、各 delegation について sidecar に `delegateRestored` を送る。
//      sidecar 側 (= user code) が `isRestored: true` を見て per-delegation
//      で「冪等じゃないので throw」「冪等なので走らせる」を選ぶ。
//
// Escalation (= ext → core / ext → ext call) と log IPC は本リビジョンの
// protocol には含まれない (= 別 RFC で v2 として追加予定)。
//
// 注意: 1 FfiModule = 1 sidecar = 1 snapshot scope。`ffiStore` は予め
// その scope に bind 済みのインスタンスを受け取る (= storage layer 側で
// 構築する)。

import { CORE_ENDPOINT, FFI_ENDPOINT } from "./endpoints.js";
import type { ExternalEvent } from "../engine/event.js";
import type { DelegationId } from "../engine/id.js";
import type { Endpoint } from "../engine/endpoint.js";
import type { Logger } from "../engine/logger.js";
import type { Value } from "../engine/value.js";
import { valueFromRaw, valueToRaw } from "../value-codec.js";
import type { RawValue } from "../value-codec.js";
import type { Module } from "../module.js";
import type { Sidecar } from "../sidecar/sidecar.js";
import type { FfiStore } from "../sidecar/store.js";
import { PROTOCOL_VERSION, type ChildToParent } from "../sidecar/types.js";

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
        // protocol v1 では escalate 経路を扱わない。 escalation 自体が
        // sidecar 側から発火しないので escalateAck もここには来ない
        // (= 来たら CORE / bus 側のバグ)。
        this.logger.log("warn", "ffi: escalateAck in v1 protocol (dropped)", {
          from: event.from,
        });
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
   * に `delegateRestored` を送る。
   *
   * 注: sidecar が起動済み (= `start()` 済) であることを前提とする。
   */
  async recoverInflight(): Promise<void> {
    const delegations = await this.store.listDelegations();
    for (const row of delegations) {
      try {
        await this.sidecar.send({
          type: "delegateRestored",
          protocolVersion: PROTOCOL_VERSION,
          delegationId: row.delegationId,
          agentDefId: row.agentDefId,
          args: argsToRaw(row.args),
        });
      } catch (err) {
        this.logger.log("error", "ffi: delegateRestored send failed", {
          delegationId: row.delegationId,
          err: err instanceof Error ? err.message : String(err),
        });
      }
    }

    // protocol v1 では escalate 経路が無いので、 store 上に残っている
    // escalation row は (古い data か CORE 側の予期せぬ書き込みの) いずれ
    // にせよ clean up しておく。
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
    });
    await this.sidecar.send({
      type: "delegate",
      protocolVersion: PROTOCOL_VERSION,
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
      this.logger.log("debug", "ffi: terminate for unknown delegation", {
        delegationId,
      });
      return;
    }
    await this.sidecar.send({
      type: "terminate",
      protocolVersion: PROTOCOL_VERSION,
      delegationId,
    });
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
        // start() で吸い取られる handshake。 ここに来たら spurious 再 emit
        // (= sidecar 側の bug) なので drop。
        this.logger.log("debug", "ffi: spurious ready from sidecar");
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
            value: valueFromRaw(msg.value),
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
        // protocol v1: surface as terminateAck (= "the call ended without
        // producing a value"). A dedicated cross-module `delegateError`
        // event is a future RFC.
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
}

// type re-exports for convenience
export type { Value };
void CORE_ENDPOINT;

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
