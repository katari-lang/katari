// AgentDefId: opaque, module-local agent identifier.
//
// 6 event のうち `delegate` / `escalate` は対象 agent を `agentDefId` で指す。
// この id は **受信側 module 局所** の意味だけ持つ。送信側は受信側が知る形に
// pre-encode して渡し、受信側が自分で decode する。bus / 中間層は中身を見ない。
//
// 各 module の encoding (現状):
//
//   - CORE encoding:
//       { kind: "qname",   value: { module_, name } }   — top-level agent
//     | { kind: "closure", value: ClosureId }            — closure dispatch
//
//   - FFI encoding:
//       { kind: "qname",   value: { module_, name } }   — sidecar handler
//                                                         (CORE と同じ shape だが
//                                                          名前空間は別)
//
//   - API encoding (現状空、将来 user 提供 def 用):
//       (currently no agent definitions; receiving a delegate yields
//        delegateError)
//
// **重要**: CORE と FFI の `qname` は同じ JSON 形でも *別 namespace*。
// CORE の IR 内の `BlockExternal` が指す QualifiedName と、FFI sidecar が
// 公開する QualifiedName は同名でも違う関数を指す。decoder 関数経由で
// 必ず module を意識して narrow すること。

import type { ClosureId } from "./engine/id.js";
import type { QualifiedName } from "./ir/types.js";

/**
 * Bus / 中間層で扱う opaque な agent identifier。受信側 module だけが decode する。
 *
 * Wire 形式は JSON-serializable (= structuredClone-safe)。
 */
export type AgentDefId = unknown & { readonly __brand: "AgentDefId" };

// ─── CORE encoding / decoding ──────────────────────────────────────────────

export type CoreAgentDefId =
  | { kind: "qname"; value: QualifiedName }
  | { kind: "closure"; value: ClosureId };

export function encodeCoreAgentDefId(value: CoreAgentDefId): AgentDefId {
  return value as unknown as AgentDefId;
}

export function decodeCoreAgentDefId(id: AgentDefId): CoreAgentDefId {
  const v = id as unknown as Partial<CoreAgentDefId>;
  if (v && typeof v === "object" && "kind" in v) {
    if (v.kind === "qname" || v.kind === "closure") {
      return v as CoreAgentDefId;
    }
  }
  throw new Error(`agent-def-id: invalid CORE encoding: ${JSON.stringify(id)}`);
}

// ─── FFI encoding / decoding ───────────────────────────────────────────────
//
// FFI side currently only handles qualified-name dispatch. The shape is
// identical to CORE's `qname` variant but conceptually distinct — the
// wire format happens to overlap because both modules want "module.name"
// strings. Dedicated encoders prevent accidental cross-namespace use.

export type FfiAgentDefId = { kind: "qname"; value: QualifiedName };

export function encodeFfiAgentDefId(value: FfiAgentDefId): AgentDefId {
  return value as unknown as AgentDefId;
}

export function decodeFfiAgentDefId(id: AgentDefId): FfiAgentDefId {
  const v = id as unknown as Partial<FfiAgentDefId>;
  if (v && typeof v === "object" && v.kind === "qname" && "value" in v) {
    return v as FfiAgentDefId;
  }
  throw new Error(`agent-def-id: invalid FFI encoding: ${JSON.stringify(id)}`);
}
