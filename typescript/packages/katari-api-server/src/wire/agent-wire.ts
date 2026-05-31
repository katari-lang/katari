// Wire-format conversion for run / delegation / escalation rows.
//
// Storage carries the **encrypted** form ('EncryptedValue' = the
// runtime 'Value' shape with each `secret` variant replaced by a
// `$envelope` ciphertext blob). HTTP clients must see neither the
// plaintext (= bypasses the type system's leak prevention) nor the
// raw ciphertext (= metadata leak with no upside). 'redactSecretsInEncrypted'
// replaces every `$envelope` with a deterministic `<redacted:...>`
// placeholder before 'valueToRaw' produces the flat wire shape.

import { type EncryptedValue, redactSecretsInEncrypted, valueToRaw } from "@katari-lang/runtime";
import type { RawValue } from "@katari-lang/types";
import type {
  DelegationRow,
  EscalationRow,
  RunEscalationAuditRow,
  RunRow,
} from "../storage/types.js";

// ─── Live delegation (request edge) ─────────────────────────────────────────

export type DelegationRowWire = Omit<DelegationRow, "args"> & {
  args: Record<string, RawValue>;
};

export function delegationRowToWire(row: DelegationRow): DelegationRowWire {
  return {
    ...row,
    args: redactArgs(row.args),
  };
}

// ─── Run (the API's per-run management record) ─────────────────────────────

export type RunRowWire = Omit<RunRow, "args" | "result"> & {
  args: Record<string, RawValue>;
  result?: RawValue;
};

export function runRowToWire(row: RunRow): RunRowWire {
  return {
    ...row,
    args: redactArgs(row.args),
    result: row.result === undefined ? undefined : valueToRaw(redactSecretsInEncrypted(row.result)),
  };
}

// ─── Escalation (raiser-owned, live) ───────────────────────────────────────

export type EscalationRowWire = Omit<EscalationRow, "args"> & {
  args: Record<string, RawValue>;
};

export function escalationRowToWire(row: EscalationRow): EscalationRowWire {
  return {
    ...row,
    args: redactArgs(row.args),
  };
}

// ─── Operator-facing escalation (the run's view; pending or answered) ──────

export type RunEscalationWire = {
  runId: string;
  escalationId: string;
  agentDefId: string;
  args: Record<string, RawValue>;
  /** `open` while awaiting an operator answer; `answered` once replied. */
  state: "open" | "answered";
  value?: RawValue;
  createdAt: string;
  answeredAt?: string;
};

export function runEscalationToWire(row: RunEscalationAuditRow): RunEscalationWire {
  return {
    runId: row.runId,
    escalationId: row.escalationId,
    agentDefId:
      typeof row.agentDefId === "string" ? row.agentDefId : JSON.stringify(row.agentDefId),
    args: redactArgs(row.args),
    state: row.answer === undefined ? "open" : "answered",
    value: row.answer === undefined ? undefined : valueToRaw(redactSecretsInEncrypted(row.answer)),
    createdAt: row.createdAt,
    answeredAt: row.answeredAt,
  };
}

// ─── Internal ──────────────────────────────────────────────────────────────

function redactArgs(args: Record<string, EncryptedValue>): Record<string, RawValue> {
  const out: Record<string, RawValue> = {};
  for (const [k, v] of Object.entries(args)) {
    out[k] = valueToRaw(redactSecretsInEncrypted(v));
  }
  return out;
}
