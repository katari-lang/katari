// Wire-format conversion for run / delegation / escalation rows.
//
// Storage carries the **encrypted** form ('EncryptedValue' = the
// runtime 'Value' shape with each `secret` variant replaced by a
// `$envelope` ciphertext blob). HTTP clients must see neither the
// plaintext (= bypasses the type system's leak prevention) nor the
// raw ciphertext (= metadata leak with no upside). 'redactSecretsInEncrypted'
// replaces every `$envelope` with a deterministic `<redacted:...>`
// placeholder before 'valueToRaw' produces the flat wire shape.

import {
  redactSecretsInEncrypted,
  valueToRaw,
  type EncryptedValue,
} from "@katari-lang/runtime";
import type { RawValue } from "@katari-lang/runtime";
import type {
  DelegationRow,
  EscalationRow,
  RunsAuditRow,
} from "../storage/types.js";

// ─── Live delegation ───────────────────────────────────────────────────────

export type DelegationRowWire = Omit<DelegationRow, "args"> & {
  args: Record<string, RawValue>;
};

export function delegationRowToWire(row: DelegationRow): DelegationRowWire {
  return {
    ...row,
    args: redactArgs(row.args),
  };
}

// ─── Run (= operator-launched root delegation, audit log) ──────────────────

export type RunAuditRowWire = Omit<RunsAuditRow, "args" | "result"> & {
  args: Record<string, RawValue>;
  result?: RawValue;
};

export function runAuditRowToWire(row: RunsAuditRow): RunAuditRowWire {
  return {
    ...row,
    args: redactArgs(row.args),
    result:
      row.result === undefined
        ? undefined
        : valueToRaw(redactSecretsInEncrypted(row.result)),
  };
}

// ─── Escalation ────────────────────────────────────────────────────────────

export type EscalationRowWire = Omit<EscalationRow, "args" | "value"> & {
  args: Record<string, RawValue>;
  value?: RawValue;
};

export function escalationRowToWire(row: EscalationRow): EscalationRowWire {
  return {
    ...row,
    args: redactArgs(row.args),
    value:
      row.value === undefined
        ? undefined
        : valueToRaw(redactSecretsInEncrypted(row.value)),
  };
}

// ─── Internal ──────────────────────────────────────────────────────────────

function redactArgs(
  args: Record<string, EncryptedValue>,
): Record<string, RawValue> {
  const out: Record<string, RawValue> = {};
  for (const [k, v] of Object.entries(args)) {
    out[k] = valueToRaw(redactSecretsInEncrypted(v));
  }
  return out;
}
