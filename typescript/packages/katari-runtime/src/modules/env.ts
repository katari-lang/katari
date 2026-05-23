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
// (qualified name `prim.env_not_found`) via `escalate`, which the
// caller's surrounding handle scope can catch.
//
// **Persistence**: a single store instance shared across snapshots
// — env entries do not belong to a snapshot's lifecycle (they
// outlive deploys). Storage is responsible for durability; the
// module is stateless between events.
//
// **Secret handling**: when 'set_env' names a secret, the plaintext
// is encrypted via 'secret-crypto.encryptSecret' before the value
// reaches 'EnvStore.upsert'. 'get_secret_env' performs the reverse
// decrypt inside the module so the storage layer never sees
// plaintext credentials.

import { ENV_ENDPOINT } from "./endpoints.js";
import { encodeCoreAgentDefId, decodeFfiAgentDefId } from "../agent-def-id.js";
import type { Endpoint } from "../engine/endpoint.js";
import type { ExternalEvent } from "../engine/event.js";
import { createEscalationId } from "../engine/id.js";
import type { Logger } from "../engine/logger.js";
import type { Value } from "../engine/value.js";
import { decryptSecret, encryptSecret } from "../secret-crypto.js";
import type { Module } from "../module.js";
import type { EnvStore } from "../sidecar/env-store.js";

/** Reserved env dispatch names that EnvModule recognises on inbound
 * delegates. Anything else is logged and dropped. */
const ENV_DISPATCH_GET = "get_env";
const ENV_DISPATCH_GET_SECRET = "get_secret_env";
const ENV_DISPATCH_SET = "set_env";

/** Qualified name of the stdlib request raised on missing-key lookup. */
const ENV_NOT_FOUND_QNAME = "prim.env_not_found";

export type EnvModuleOptions = {
  /** Self-endpoint. Defaults to {@link ENV_ENDPOINT}. */
  endpoint?: Endpoint;
  /** Persistence backend (host-provided). */
  store: EnvStore;
  /** Callback that hands an event back to the bus. */
  onBusResponse: (event: ExternalEvent) => void;
  logger: Logger;
};

export class EnvModule implements Module {
  readonly endpoint: Endpoint;
  private readonly store: EnvStore;
  private readonly onBusResponse: (event: ExternalEvent) => void;
  private readonly logger: Logger;

  constructor(opts: EnvModuleOptions) {
    this.endpoint = opts.endpoint ?? ENV_ENDPOINT;
    this.store = opts.store;
    this.onBusResponse = opts.onBusResponse;
    this.logger = opts.logger;
  }

  // ─── Module interface ───────────────────────────────────────────────────

  async feed(event: ExternalEvent): Promise<{ outbound: ExternalEvent[] }> {
    if (event.payload.kind !== "delegate") {
      // EnvModule only responds to delegate. Other events (terminate /
      // escalate / etc.) are not expected from CoreModule against the
      // env endpoint; log and drop so a misconfigured caller surfaces.
      this.logger.log("debug", "env: unexpected event kind dropped", {
        kind: event.payload.kind,
      });
      return { outbound: [] };
    }
    const { delegationId, agentDefId, args } = event.payload;
    const dispatchName = decodeFfiAgentDefId(agentDefId).value;
    switch (dispatchName) {
      case ENV_DISPATCH_GET:
        await this.handleGet(event.from, delegationId, args, /*secret=*/ false);
        return { outbound: [] };
      case ENV_DISPATCH_GET_SECRET:
        await this.handleGet(event.from, delegationId, args, /*secret=*/ true);
        return { outbound: [] };
      case ENV_DISPATCH_SET:
        await this.handleSet(event.from, delegationId, args);
        return { outbound: [] };
      default:
        this.logger.log("warn", "env: unknown dispatch name", { dispatchName });
        return { outbound: [] };
    }
  }

  /** Nothing to flush — every state update writes through to the store. */
  async persist(): Promise<void> {}
  /** Stateless module — load is a no-op. */
  async load(): Promise<void> {}

  // ─── Dispatch handlers ──────────────────────────────────────────────────

  private async handleGet(
    caller: Endpoint,
    delegationId: import("../engine/id.js").DelegationId,
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
    const value: Value = secret
      ? { kind: "secret", value: decryptSecret(entry.value) }
      : { kind: "string", value: entry.value };
    this.respondDelegateAck(caller, delegationId, value);
  }

  private async handleSet(
    caller: Endpoint,
    delegationId: import("../engine/id.js").DelegationId,
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

  private respondDelegateAck(
    to: Endpoint,
    delegationId: import("../engine/id.js").DelegationId,
    value: Value,
  ): void {
    this.onBusResponse({
      from: this.endpoint,
      to,
      payload: { kind: "delegateAck", delegationId, value },
    });
  }

  private escalateEnvNotFound(
    to: Endpoint,
    delegationId: import("../engine/id.js").DelegationId,
    key: string,
  ): void {
    this.onBusResponse({
      from: this.endpoint,
      to,
      payload: {
        kind: "escalate",
        delegationId,
        escalationId: createEscalationId(),
        agentDefId: encodeCoreAgentDefId({
          kind: "qname",
          value: ENV_NOT_FOUND_QNAME,
        }),
        args: { key: { kind: "string", value: key } },
      },
    });
  }

  private escalateInvalidArgs(
    to: Endpoint,
    delegationId: import("../engine/id.js").DelegationId,
    message: string,
  ): void {
    // Argument-shape problems are programmer errors at the boundary;
    // surface them via `prim.throw` so they reach the snapshot's
    // top-level error state (= the same fate as any other engine bug).
    this.onBusResponse({
      from: this.endpoint,
      to,
      payload: {
        kind: "escalate",
        delegationId,
        escalationId: createEscalationId(),
        agentDefId: encodeCoreAgentDefId({
          kind: "qname",
          value: "prim.throw",
        }),
        args: { msg: { kind: "string", value: message } },
      },
    });
  }
}

function requireString(
  args: Record<string, Value>,
  name: string,
): string | null {
  const v = args[name];
  return v !== undefined && v.kind === "string" ? v.value : null;
}

function requireBoolean(
  args: Record<string, Value>,
  name: string,
): boolean | null {
  const v = args[name];
  return v !== undefined && v.kind === "boolean" ? v.value : null;
}
