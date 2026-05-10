// Sidecar abstraction: the parent-side handle to a single child sidecar
// (subprocess, in-process function, future remote process, etc).
//
// runtime はこの interface だけを知る。具体実装:
//   - InProcessSidecar: テスト・組込み用途。ハンドラを直接呼ぶ。
//   - (future) SubprocessSidecar: katari-port library 経由で実装される予定。
//
// Sidecar 本体は **stateless**: 飛んできた IPC event を処理するだけ。
// 再起動時の state restore は親側 (FFI Module) の責務。

import type { ChildToParent, ParentToChild } from "./types.js";

export interface Sidecar {
  /** Parent → Child message を送信。 */
  send(msg: ParentToChild): Promise<void>;

  /** Child → Parent message を受信するコールバックを登録。1 個だけ。 */
  onMessage(cb: (msg: ChildToParent) => void): void;

  /** Lifecycle 開始 (subprocess spawn / connection 確立など)。 */
  start(): Promise<void>;

  /** Lifecycle 終了。リソース解放。 */
  shutdown(): Promise<void>;
}

// ─── InProcessSidecar ──────────────────────────────────────────────────────

import type { Logger } from "../engine/logger.js";

/**
 * テスト用 in-process sidecar。subprocess を起動せず、user の `invoke`
 * 関数を直接呼ぶ。Subprocess 版と同じ `Sidecar` interface を提供するので、
 * テストと本番で FFI Module 側のコードが共通化できる。
 */
export type InProcessHandler = (input: {
  agentDefId: unknown;
  args: Record<string, unknown>;
  delegationId: string;
  /** "delegate" の場合 false、"restoredDelegate" の場合 true */
  isRestored: boolean;
  signal: AbortSignal;
  escalate: (
    agentDefId: unknown,
    args: Record<string, unknown>,
  ) => Promise<unknown>;
}) => Promise<unknown>;

export class InProcessSidecar implements Sidecar {
  private handler: ((msg: ChildToParent) => void) | null = null;
  private readonly inflight = new Map<string, AbortController>();
  private readonly pendingEscalations = new Map<
    string,
    { resolve: (v: unknown) => void; reject: (e: Error) => void }
  >();

  constructor(
    private readonly userInvoke: InProcessHandler,
    private readonly logger: Logger,
  ) {}

  async start(): Promise<void> {
    queueMicrotask(() => this.handler?.({ type: "ready" }));
  }

  async send(msg: ParentToChild): Promise<void> {
    switch (msg.type) {
      case "delegate":
        this.handleDelegate(msg, false).catch((err) => {
          this.logger.log("error", "inproc sidecar delegate threw", {
            err: String(err),
          });
        });
        return;
      case "restoredDelegate":
        this.handleDelegate(msg, true).catch((err) => {
          this.logger.log("error", "inproc sidecar restoredDelegate threw", {
            err: String(err),
          });
        });
        return;
      case "terminate": {
        const ctrl = this.inflight.get(msg.delegationId);
        ctrl?.abort();
        this.inflight.delete(msg.delegationId);
        this.handler?.({
          type: "terminateAck",
          delegationId: msg.delegationId,
        });
        return;
      }
      case "escalateAck": {
        const pending = this.pendingEscalations.get(msg.escalationId);
        pending?.resolve(msg.value);
        this.pendingEscalations.delete(msg.escalationId);
        return;
      }
      case "escalateError": {
        const pending = this.pendingEscalations.get(msg.escalationId);
        pending?.reject(new Error(msg.message));
        this.pendingEscalations.delete(msg.escalationId);
        return;
      }
      case "shutdown":
        return;
    }
  }

  private async handleDelegate(
    msg: Extract<ParentToChild, { type: "delegate" | "restoredDelegate" }>,
    isRestored: boolean,
  ): Promise<void> {
    const ctrl = new AbortController();
    this.inflight.set(msg.delegationId, ctrl);
    let currentDelegationId = msg.delegationId;
    const escalate = (agentDefId: unknown, args: Record<string, unknown>) => {
      const escalationId = generateId();
      return new Promise<unknown>((resolve, reject) => {
        this.pendingEscalations.set(escalationId, { resolve, reject });
        this.handler?.({
          type: "escalate",
          delegationId: currentDelegationId as never,
          escalationId: escalationId as never,
          agentDefId: agentDefId as never,
          args: args as never,
        });
      });
    };
    try {
      const value = await this.userInvoke({
        agentDefId: msg.agentDefId,
        args: msg.args,
        delegationId: msg.delegationId,
        isRestored,
        signal: ctrl.signal,
        escalate,
      });
      this.handler?.({
        type: "delegateAck",
        delegationId: msg.delegationId,
        value: value as never,
      });
    } catch (err) {
      this.handler?.({
        type: "delegateError",
        delegationId: msg.delegationId,
        message: err instanceof Error ? err.message : String(err),
      });
    } finally {
      this.inflight.delete(msg.delegationId);
    }
  }

  onMessage(cb: (msg: ChildToParent) => void): void {
    this.handler = cb;
  }

  async shutdown(): Promise<void> {
    for (const ctrl of this.inflight.values()) ctrl.abort();
    this.inflight.clear();
    for (const pending of this.pendingEscalations.values()) {
      pending.reject(new Error("sidecar shutdown"));
    }
    this.pendingEscalations.clear();
  }
}

function generateId(): string {
  return `${Math.random().toString(16).slice(2)}-${Date.now().toString(16)}`;
}
