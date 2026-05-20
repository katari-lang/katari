// Wire-format conversion for agent / escalation rows. Storage carries
// `Value`-tagged fields (canonical runtime form); HTTP clients see the
// flat raw form produced by `valueToRaw`.

import { valueToRaw } from "@katari-lang/runtime";
import type { RawValue } from "@katari-lang/runtime";
import type { AgentRow, ApiPendingEscalation } from "../storage/types.js";

export type AgentRowWire = Omit<AgentRow, "args" | "result"> & {
  args: Record<string, RawValue>;
  result?: RawValue;
};

export function agentRowToWire(row: AgentRow): AgentRowWire {
  const args: Record<string, RawValue> = {};
  for (const [k, v] of Object.entries(row.args)) {
    args[k] = valueToRaw(v);
  }
  return {
    ...row,
    args,
    result: row.result === undefined ? undefined : valueToRaw(row.result),
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
    args[k] = valueToRaw(v);
  }
  return {
    ...row,
    args,
    value: row.value === undefined ? undefined : valueToRaw(row.value),
  };
}
