// ===========================================================================
// RuntimeLogger — extends KatariLogger with runtime event tracing
// ===========================================================================

import type { KatariLogger, LogLevel } from "katari-protocol";
import { ConsoleKatariLogger, fmtData, shortenEndpoint } from "katari-protocol";

export interface RuntimeLogger extends KatariLogger {
  /** Runtime event fired on a thread */
  runtimeEvent(agentId: string, threadId: number, event: string, data?: Record<string, unknown>): void;
}

// ===========================================================================
// ConsoleRuntimeLogger — colored console output
// ===========================================================================

function ts(): string {
  return new Date().toISOString().slice(11, 23);
}

export class ConsoleRuntimeLogger extends ConsoleKatariLogger implements RuntimeLogger {
  constructor(opts?: { level?: LogLevel; prefix?: string }) {
    super(opts);
  }

  runtimeEvent(agentId: string, threadId: number, event: string, data?: Record<string, unknown>): void {
    const aid = agentId.slice(0, 8);
    console.log(`${ts()} \x1b[33mEVENT\x1b[0m ${this.getPrefix()}agent=${aid} thread=${threadId} \x1b[1m${event}\x1b[0m${fmtData(data)}`);
  }
}

// ===========================================================================
// NullRuntimeLogger — for tests
// ===========================================================================

export class NullRuntimeLogger extends ConsoleKatariLogger implements RuntimeLogger {
  constructor() { super({ level: "error" }); }
  override log(): void {}
  override protocolSend(): void {}
  override protocolRecv(): void {}
  runtimeEvent(): void {}
}
