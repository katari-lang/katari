// Public types for user code that imports katari-port.

import type { RawValue } from "@katari-lang/types";

/** Wire module owning a value reference. */
export type RefModule = "core" | "ffi" | "api";

/**
 * A content-addressed value reference, parameterized by how its bytes are
 * read. `as: "string"` → a Katari `string`; `as: "file"` → a Katari `file`.
 * Mirrors the `$ref` envelope in the runtime's value codec.
 */
export type KatariRef<As extends "string" | "file"> = {
  $ref: { module: RefModule; id: string };
  as: As;
  hash: string;
  size: number;
  contentType?: string;
};

/** A Katari `file` value — always a content ref. */
export type KatariFile = KatariRef<"file">;

/** A Katari `string` value — inline text (short) or a content ref (large). */
export type KatariString = string | KatariRef<"string">;

/** A Katari callable value: an agent (`{$agent:"qname@snapshot"}`) or a closure
 *  (`{$agent:"closureref:<id>"}`). Closures arrive from CORE; user code can only
 *  construct agents (see `katari.makeAgent`). */
export type KatariAgent = { $agent: string };

/** Context handed to a user-provided agent handler at delegate time. `A` is the
 *  handler's argument shape (default: an untyped record). */
export interface AgentContext<A = Record<string, RawValue>> {
  /** Argument map sent by the Katari runtime. Keys match the `ext agent`
   *  parameter labels. Type it via `katari.agent<{ ... }>(...)`. */
  args: A;
  /**
   * Stable delegation id assigned by the runtime. Useful as a logger
   * context or an idempotency key. Different deliveries of the same call
   * (e.g. after a parent restart) reuse the same id.
   */
  delegationId: string;
  /**
   * Aborts when the runtime sends an `ipcTerminate` for this delegation.
   * Forward to `fetch`, `setTimeout`, etc. for cooperative cancellation.
   */
  signal: AbortSignal;
  /** `true` when the runtime re-issued this delegation after a parent restart
   *  (= `ipcDelegateRestarted`). Non-idempotent handlers should throw. */
  isRestored: boolean;
  /** The snapshot this sidecar runs (from `KATARI_SNAPSHOT_ID`). */
  readonly snapshotId: string;

  // ── operations bound to THIS delegation ────────────────────────────────
  // These live on the context (not the global `katari`) precisely because
  // they are tied to this specific delegation — `delegate` parents its child
  // here, `make*` stamps produced refs as owned here. The context is a plain
  // object, so a handler can close over it and use these from a callback that
  // fires LATER, off its own async chain (a socket / emitter / timer) — the
  // `watch_*` / subscription pattern. (There is no ambient context to lose.)

  /**
   * Start a CORE-side child agent and await its result. `callable` is a
   * `KatariAgent` — typically one received in args, or built with
   * `ctx.makeAgent(...)`. (A bare agent-id string is also accepted.)
   */
  delegate(
    callable: KatariAgent | string,
    args: Record<string, RawValue>,
    opts?: DelegateOptions,
  ): Promise<RawValue>;

  /** A `string` value. Small text stays inline; large text is produced as a
   *  content ref over the data plane (hence async), owned by this delegation. */
  makeString(text: string): Promise<KatariString>;
  /** A `file` value: produce a content ref from bytes (ephemeral — owned by
   *  this delegation, GC'd with the run unless `persist`ed). */
  makeFile(bytes: Uint8Array, opts?: MakeFileOptions): Promise<KatariFile>;
  /** An agent value referencing a CORE agent by qualified name, in THIS
   *  sidecar's snapshot (`{$agent:"qname@snapshot"}`). */
  makeAgent(qualifiedName: string): KatariAgent;

  /** UTF-8 text of a `string` / `file` value (inline → as-is; ref → fetched). */
  readString(value: KatariString | KatariFile): Promise<string>;
  /** Raw bytes of a `string` / `file` value (inline → encoded; ref → fetched). */
  readBytes(value: KatariString | KatariFile): Promise<Uint8Array>;

  /** Promote an ephemeral (core/ffi) ref to a durable project file. */
  persist(value: KatariRef<"string" | "file">, opts?: { name?: string }): Promise<KatariFile>;
}

/** Async function that implements an `ext agent`. */
export type AgentHandler<A = Record<string, RawValue>> = (
  ctx: AgentContext<A>,
) => Promise<RawValue>;

/** Options for `katari.delegate`. The signal cancels the child. */
export interface DelegateOptions {
  signal?: AbortSignal;
}

/** Options for `katari.makeFile`. */
export interface MakeFileOptions {
  /** Human file name (shown in the file browser / used as the download name). */
  name?: string;
  /** Media type stored alongside the blob; served on fetch / download. */
  contentType?: string;
}

/** Public surface of the singleton imported as `import katari from "@katari-lang/port"`. */
export interface KatariPort {
  /**
   * Register a handler for an `ext agent <name>` declared in the sibling
   * `.ktr` file. The module qname prefix is injected by the bundler; pass
   * only the local agent name. Type the args via the type parameter:
   * `katari.agent<{ doc: KatariFile }>("summarize", async (ctx) => ...)`.
   */
  agent<A = Record<string, RawValue>>(name: string, handler: AgentHandler<A>): void;
}

export type { RawValue };
