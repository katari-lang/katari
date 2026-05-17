// FfiStore — FFI Module の永続化レイヤ interface。
//
// FFI Module は「sidecar に投げて未完了の delegation / escalation」を
// 自分の DB に保持する (CORE 側の状態とは独立)。host (api-server / cli /
// テスト) が具体実装を提供する。
//
// 各 instance は **特定の "key" (= 通常 snapshotId) に bind 済み** とする。
// メソッド引数に key を取らないことで、misuse (= 別 snapshot のレコードを
// 触る) を構造的に防ぐ。

import type { AgentDefId } from "../agent-def-id.js";
import type { DelegationId, EscalationId } from "../engine/id.js";
import type { Endpoint } from "../engine/endpoint.js";
import type { Value } from "../engine/value.js";

/**
 * FFI Module が「自分が sidecar に投げて返答待ち」のレコード。
 *
 *   - `peerEndpoint`: ack を返す相手 (= ext call の caller、 通常 CORE)
 *   - `agentDefId`:   wire 上で受け取った encoding (= FFI 側の名前空間)
 *   - `parentExtDelegationId`: ext-delegated child agent のみ非 null。
 *     ext handler が `katari.delegate(...)` で起こした子 agent の場合、
 *     ここに「ext call 自体の delegationId」 が入る。 これにより
 *     escalate 中継時に親 ext delegation の peer を引ける + restart 時に
 *     orphan 子を terminate できる。
 */
export type FfiPendingDelegation = {
  delegationId: DelegationId;
  peerEndpoint: Endpoint;
  agentDefId: AgentDefId;
  args: Record<string, Value>;
  state: "running" | "cancelling";
  createdAt: string;
  parentExtDelegationId: DelegationId | null;
};

/**
 * FFI Module が「sidecar が emit して CORE に転送中の escalate」のレコード。
 * sidecar process が再起動で失われた場合は、起動時に整理対象 (= drop)。
 */
export type FfiPendingEscalation = {
  escalationId: EscalationId;
  delegationId: DelegationId;
  peerEndpoint: Endpoint;
  agentDefId: AgentDefId;
  args: Record<string, Value>;
  createdAt: string;
};

export interface FfiStore {
  // ─── Pending delegations ──────────────────────────────────────────────
  insertDelegation(row: FfiPendingDelegation): Promise<void>;
  getDelegation(id: DelegationId): Promise<FfiPendingDelegation | null>;
  setDelegationState(
    id: DelegationId,
    state: "running" | "cancelling",
  ): Promise<boolean>;
  deleteDelegation(id: DelegationId): Promise<boolean>;
  /** 起動時 `ipcDelegateRestarted` 送信 + child terminate 発火用に scope 内全件返す。 */
  listDelegations(): Promise<FfiPendingDelegation[]>;
  /** 指定の親 ext delegation を `parentExtDelegationId` に持つ子 delegations を返す。 */
  listChildrenOf(parentId: DelegationId): Promise<FfiPendingDelegation[]>;

  // ─── Pending escalations ──────────────────────────────────────────────
  insertEscalation(row: FfiPendingEscalation): Promise<void>;
  getEscalation(id: EscalationId): Promise<FfiPendingEscalation | null>;
  deleteEscalation(id: EscalationId): Promise<boolean>;
  /** 起動時 cleanup 用に scope 内全件返す。 */
  listEscalations(): Promise<FfiPendingEscalation[]>;
}
