// EnvModule — host-provided key/value store for environment entries.
//
// Receives `delegate` events from CoreModule whenever a Katari program
// calls one of the stdlib env builtins:
//
//   * `get_env(key) -> string with env_not_found`
//   * `get_secret_env(key) -> secret with env_not_found`
//   * `set_env(key, value, is_secret) -> null`
//
// The 'dispatchName' on the event's agentDefId selects which handler
// runs. Missing-key lookups raise the stdlib `req env_not_found`
// (qualified name `prim.env_not_found`) via `escalate`. The caller's
// surrounding handle scope catches it and the resulting `escalateAck`
// is converted back into a `delegateAck` so the round-trip closes.
//
// **Persistence**: env entries themselves outlive snapshots (the
// store is the source of truth). The escalation map below tracks
// in-flight env_not_found round-trips and is intentionally
// in-memory: a server restart while one is pending will drop it
// (the caller's snapshot will fail to complete and be retried).
//
// **Secret handling**: when 'set_env' names a secret, the plaintext
// is encrypted via 'secret-crypto.encryptSecret' before the value
// reaches 'EnvStore.upsert'. 'get_secret_env' performs the reverse
// decrypt inside the module so the storage layer never sees
// plaintext credentials.

import { decodeFfiAgentDefId, encodeCoreAgentDefId, THROW_REQUEST_QNAME } from "../agent-def-id.js";
import type { Endpoint } from "../engine/endpoint.js";
import type { ExternalEvent } from "../engine/event.js";
import { createEscalationId, type DelegationId, type EscalationId } from "../engine/id.js";
import type { Logger } from "../engine/logger.js";
import { mkSecret, mkString, tryInlineString, type Value } from "../engine/value.js";
import type { Module } from "../module.js";
import { decryptSecret, encryptSecret } from "../secret-crypto.js";
import type { EnvStore } from "../sidecar/env-store.js";
import { ENV_ENDPOINT } from "./endpoints.js";

/** Reserved env dispatch names that EnvModule recognises on inbound
 * delegates. Anything else is logged and dropped. */
const ENV_DISPATCH_GET = "get_env";
const ENV_DISPATCH_GET_SECRET = "get_secret_env";
const ENV_DISPATCH_SET = "set_env";

/** Qualified name of the stdlib request raised on missing-key lookup. */
const ENV_NOT_FOUND_QNAME = "primitive.env_not_found";

export type EnvModuleOptions = {
  /** Self-endpoint. Defaults to {@link ENV_ENDPOINT}. */
  endpoint?: Endpoint;
  /** Persistence backend (host-provided). */
  store: EnvStore;
  /** Callback that hands an event back to the bus. */
  onBusResponse: (event: ExternalEvent) => void;
  logger: Logger;
};

/**
 * In-flight env_not_found round-trip. Created when 'handleGet' escalates
 * because the key is missing; consumed when the matching 'escalateAck'
 * arrives (= the handler resumed via 'next') or the caller cancels
 * (= 'terminate').
 */
interface PendingEscalation {
  delegationId: DelegationId;
  caller: Endpoint;
}

export class EnvModule implements Module {
  readonly endpoint: Endpoint;
  private readonly store: EnvStore;
  private readonly onBusResponse: (event: ExternalEvent) => void;
  private readonly logger: Logger;
  /**
   * Active env_not_found escalations. Keyed by 'escalationId' so an
   * inbound 'escalateAck' can locate its caller in O(1). The
   * 'delegationId' field lets a 'terminate' event drop the entry
   * via a linear scan (rare path; one delegation never has more than
   * one in-flight escalation, so the scan is at most as long as the
   * count of concurrently-stuck env lookups).
   */
  private readonly pendingEscalations = new Map<EscalationId, PendingEscalation>();

  constructor(opts: EnvModuleOptions) {
    this.endpoint = opts.endpoint ?? ENV_ENDPOINT;
    this.store = opts.store;
    this.onBusResponse = opts.onBusResponse;
    this.logger = opts.logger;
  }

  // ─── Module interface ───────────────────────────────────────────────────

  async feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }> {
    const p = event.payload;
    switch (p.kind) {
      case "delegate": {
        const dispatchName = decodeFfiAgentDefId(p.agentDefId).value;
        switch (dispatchName) {
          case ENV_DISPATCH_GET:
            await this.handleGet(event.from, p.delegationId, p.args, /*secret=*/ false);
            return { outbound: [] };
          case ENV_DISPATCH_GET_SECRET:
            await this.handleGet(event.from, p.delegationId, p.args, /*secret=*/ true);
            return { outbound: [] };
          case ENV_DISPATCH_SET:
            await this.handleSet(event.from, p.delegationId, p.args);
            return { outbound: [] };
          default:
            this.logger.log("warn", "env: unknown dispatch name", { dispatchName });
            return { outbound: [] };
        }
      }
      case "escalateAck":
        this.handleEscalateAck(p.escalationId, p.value);
        return { outbound: [] };
      case "terminate":
        this.handleTerminate(event.from, p.delegationId);
        return { outbound: [] };
      default:
        // 'delegateAck' / 'terminateAck' / 'escalate' have no reverse
        // meaning at this endpoint — drop with a debug log.
        this.logger.log("debug", "env: unexpected event kind dropped", {
          kind: p.kind,
        });
        return { outbound: [] };
    }
  }

  // ─── Dispatch handlers ──────────────────────────────────────────────────

  private async handleGet(
    caller: Endpoint,
    delegationId: DelegationId,
    args: Record<string, Value>,
    secret: boolean,
  ): Promise<void> {
    const key = requireString(args, "key");
    if (key === null) {
      this.escalateInvalidArgs(caller, delegationId, "key must be a string");
      return;
    }
    const entry = await this.store.get(key);
    if (entry === null) {
      this.escalateEnvNotFound(caller, delegationId, key);
      return;
    }
    // 'get_env' rejects secret entries: a non-secret read of a
    // secret-tagged entry would either launder taint (= read secret
    // value as plain string) or break the type system invariant. Treat
    // it as "no plaintext entry with this key" and escalate.
    if (!secret && entry.isSecret) {
      this.escalateEnvNotFound(caller, delegationId, key);
      return;
    }
    // 'get_secret_env' likewise refuses non-secret entries: the
    // return type is `secret`, and synthesising a `secret` value
    // from a non-secret entry would defeat the whole type-level
    // leak prevention. Treat as "no secret with this key".
    if (secret && !entry.isSecret) {
      this.escalateEnvNotFound(caller, delegationId, key);
      return;
    }
    const value: Value = secret ? mkSecret(decryptSecret(entry.value)) : mkString(entry.value);
    this.respondDelegateAck(caller, delegationId, value);
  }

  private async handleSet(
    caller: Endpoint,
    delegationId: DelegationId,
    args: Record<string, Value>,
  ): Promise<void> {
    const key = requireString(args, "key");
    const valueStr = requireString(args, "value");
    const isSecret = requireBoolean(args, "is_secret");
    if (key === null || valueStr === null || isSecret === null) {
      this.escalateInvalidArgs(
        caller,
        delegationId,
        "set_env: args must be { key: string, value: string, is_secret: boolean }",
      );
      return;
    }
    const stored = isSecret ? encryptSecret(valueStr) : valueStr;
    await this.store.upsert({ key, value: stored, isSecret });
    this.respondDelegateAck(caller, delegationId, { kind: "null" });
  }

  // ─── Response emitters ──────────────────────────────────────────────────

  private respondDelegateAck(to: Endpoint, delegationId: DelegationId, value: Value): void {
    this.onBusResponse({
      from: this.endpoint,
      to,
      payload: { kind: "delegateAck", delegationId, value },
    });
  }

  private escalateEnvNotFound(to: Endpoint, delegationId: DelegationId, key: string): void {
    const escalationId = createEscalationId();
    // Register the pending round-trip so the matching escalateAck can
    // be converted into a delegateAck, and a terminate can drop it.
    this.pendingEscalations.set(escalationId, {
      delegationId,
      caller: to,
    });
    this.onBusResponse({
      from: this.endpoint,
      to,
      payload: {
        kind: "escalate",
        delegationId,
        escalationId,
        agentDefId: encodeCoreAgentDefId({
          kind: "qname",
          value: ENV_NOT_FOUND_QNAME,
        }),
        args: { env_key: mkString(key) },
      },
    });
  }

  private escalateInvalidArgs(to: Endpoint, delegationId: DelegationId, message: string): void {
    // Argument-shape problems are programmer errors at the boundary;
    // surface them via `prim.throw` so they reach the snapshot's
    // top-level error state (= the same fate as any other engine bug).
    // No pending entry is recorded: 'throw' has no resume value, the
    // handler chain transitions the snapshot to error and never asks
    // us back.
    this.onBusResponse({
      from: this.endpoint,
      to,
      payload: {
        kind: "escalate",
        delegationId,
        escalationId: createEscalationId(),
        agentDefId: encodeCoreAgentDefId({
          kind: "qname",
          value: THROW_REQUEST_QNAME,
        }),
        args: { msg: mkString(message) },
      },
    });
  }

  // ─── Reverse-direction handlers ─────────────────────────────────────────

  /**
   * The handle scope above us caught 'env_not_found' and resumed with
   * 'next <value>'. Convert the inbound escalateAck into the deferred
   * delegateAck for the original 'get_env' / 'get_secret_env' call so
   * the caller sees the resume value as the delegate's result.
   */
  private handleEscalateAck(escalationId: EscalationId, value: Value): void {
    const entry = this.pendingEscalations.get(escalationId);
    if (entry === undefined) {
      this.logger.log("debug", "env: escalateAck for unknown escalation", {
        escalationId,
      });
      return;
    }
    this.pendingEscalations.delete(escalationId);
    this.respondDelegateAck(entry.caller, entry.delegationId, value);
  }

  /**
   * Caller cancelled mid-escalation. Drop the pending entry (so a
   * later escalateAck arrives at no recipient and gets logged) and
   * ack the terminate immediately — EnvModule never has real
   * concurrent work to wind down.
   */
  private handleTerminate(caller: Endpoint, delegationId: DelegationId): void {
    for (const [escalationId, entry] of this.pendingEscalations) {
      if (entry.delegationId === delegationId) {
        this.pendingEscalations.delete(escalationId);
      }
    }
    this.onBusResponse({
      from: this.endpoint,
      to: caller,
      payload: { kind: "terminateAck", delegationId },
    });
  }
}

function requireString(args: Record<string, Value>, name: string): string | null {
  const v = args[name];
  return v !== undefined ? tryInlineString(v) : null;
}

function requireBoolean(args: Record<string, Value>, name: string): boolean | null {
  const v = args[name];
  return v !== undefined && v.kind === "boolean" ? v.value : null;
}
