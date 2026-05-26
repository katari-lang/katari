// Zod schema for the `ChildToParent` IPC discriminated union.
//
// `parseChildLine` in `subprocess-sidecar.ts` uses this to validate
// incoming JSON from the sidecar child process instead of a bare
// `as ChildToParent` type assertion.

import { z } from "zod";
import type { ChildToParent } from "./types.js";

// ── Shared leaf schemas ─────────────────────────────────────────────

/** RawValue: recursive JSON-like type (number | string | boolean | null | array | object). */
const rawValueSchema: z.ZodType<unknown> = z.lazy(() =>
  z.union([
    z.number(),
    z.string(),
    z.boolean(),
    z.null(),
    z.array(rawValueSchema),
    z.record(z.string(), rawValueSchema),
  ]),
);

/** DelegationId is a branded string on the wire. */
const delegationIdSchema = z.string();

/** AgentDefId is a branded string on the wire. */
const agentDefIdSchema = z.string();

// ── Per-variant schemas ─────────────────────────────────────────────

const ipcReadySchema = z.object({
  type: z.literal("ipcReady"),
});

const ipcDelegateAckSchema = z.object({
  type: z.literal("ipcDelegateAck"),
  delegationId: delegationIdSchema,
  value: rawValueSchema,
});

const ipcDelegateErrorSchema = z.object({
  type: z.literal("ipcDelegateError"),
  delegationId: delegationIdSchema,
  message: z.string(),
});

const ipcTerminateAckSchema = z.object({
  type: z.literal("ipcTerminateAck"),
  delegationId: delegationIdSchema,
});

const ipcChildDelegateSchema = z.object({
  type: z.literal("ipcChildDelegate"),
  parentDelegationId: delegationIdSchema,
  delegationId: delegationIdSchema,
  agentDefId: agentDefIdSchema,
  args: z.record(z.string(), rawValueSchema),
});

const ipcChildTerminateSchema = z.object({
  type: z.literal("ipcChildTerminate"),
  delegationId: delegationIdSchema,
});

// ── Discriminated union ─────────────────────────────────────────────

export const childToParentSchema = z.discriminatedUnion("type", [
  ipcReadySchema,
  ipcDelegateAckSchema,
  ipcDelegateErrorSchema,
  ipcTerminateAckSchema,
  ipcChildDelegateSchema,
  ipcChildTerminateSchema,
]) as z.ZodType<ChildToParent>;
