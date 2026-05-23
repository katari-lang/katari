// Wire-format conversion for agent / escalation rows.
//
// Storage carries the **encrypted** form ('EncryptedValue' = the
// runtime 'Value' shape with each `secret` variant replaced by a
// `$envelope` ciphertext blob). HTTP clients must see neither the
// plaintext (= bypasses the type system's leak prevention) nor the
// raw ciphertext (= metadata leak with no upside). 'redactSecretsInEncrypted'
// replaces every `$envelope` with a deterministic `<redacted:...>`
// placeholder before 'valueToRaw' produces the flat wire shape.

import { redactSecretsInEncrypted, valueToRaw } from "@katari-lang/runtime";
import type { RawValue } from "@katari-lang/runtime";
import type { AgentRow, ApiPendingEscalation } from "../storage/types.js";

export type AgentRowWire = Omit<AgentRow, "args" | "result"> & {
  args: Record<string, RawValue>;
  result?: RawValue;
};

export function agentRowToWire(row: AgentRow): AgentRowWire {
  const args: Record<string, RawValue> = {};
  for (const [k, v] of Object.entries(row.args)) {
    args[k] = valueToRaw(redactSecretsInEncrypted(v));
  }
  return {
    ...row,
    args,
    result:
      row.result === undefined
        ? undefined
        : valueToRaw(redactSecretsInEncrypted(row.result)),
  };
}

export type ApiPendingEscalationWire = Omit<ApiPendingEscalation, "args" | "value"> & {
  args: Record<string, RawValue>;
  value?: RawValue;
};

export function apiEscalationToWire(
  row: ApiPendingEscalation,
): ApiPendingEscalationWire {
  const args: Record<string, RawValue> = {};
  for (const [k, v] of Object.entries(row.args)) {
    args[k] = valueToRaw(redactSecretsInEncrypted(v));
  }
  return {
    ...row,
    args,
    value:
      row.value === undefined
        ? undefined
        : valueToRaw(redactSecretsInEncrypted(row.value)),
  };
}
