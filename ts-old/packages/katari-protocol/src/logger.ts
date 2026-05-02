// ===========================================================================
// KatariLogger — structured logging for protocol tracing
// ===========================================================================

export type LogLevel = "debug" | "info" | "warn" | "error";

export interface KatariLogger {
  /** General log */
  log(level: LogLevel, message: string, data?: Record<string, unknown>): void;

  /** Protocol message sent (outgoing) */
  protocolSend(type: string, toEndpoint: string, data?: Record<string, unknown>): void;

  /** Protocol message received (incoming) */
  protocolRecv(type: string, fromEndpoint: string | null, data?: Record<string, unknown>): void;
}

// ===========================================================================
// ConsoleKatariLogger — default implementation with color-coded output
// ===========================================================================

const LEVEL_LABEL: Record<LogLevel, string> = {
  debug: "\x1b[90mDEBUG\x1b[0m",
  info:  "\x1b[36mINFO\x1b[0m ",
  warn:  "\x1b[33mWARN\x1b[0m ",
  error: "\x1b[31mERROR\x1b[0m",
};

function ts(): string {
  return new Date().toISOString().slice(11, 23); // HH:mm:ss.SSS
}

export function fmtData(data?: Record<string, unknown>): string {
  if (!data) return "";
  const parts: string[] = [];
  for (const [k, v] of Object.entries(data)) {
    if (v === undefined || v === null) continue;
    const s = typeof v === "object" ? JSON.stringify(v) : String(v);
    parts.push(`${k}=${s}`);
  }
  return parts.length > 0 ? " " + parts.join(" ") : "";
}

export function shortenEndpoint(ep: string): string {
  try {
    const u = new URL(ep);
    return u.hostname + (u.port ? `:${u.port}` : "") + u.pathname;
  } catch {
    return ep;
  }
}

export class ConsoleKatariLogger implements KatariLogger {
  private minLevel: LogLevel;
  private prefix: string;

  private static readonly ORDER: Record<LogLevel, number> = {
    debug: 0, info: 1, warn: 2, error: 3,
  };

  constructor(opts?: { level?: LogLevel; prefix?: string }) {
    this.minLevel = opts?.level ?? "info";
    this.prefix = opts?.prefix ? `[${opts.prefix}] ` : "";
  }

  shouldLog(level: LogLevel): boolean {
    return ConsoleKatariLogger.ORDER[level] >= ConsoleKatariLogger.ORDER[this.minLevel];
  }

  getPrefix(): string {
    return this.prefix;
  }

  log(level: LogLevel, message: string, data?: Record<string, unknown>): void {
    if (!this.shouldLog(level)) return;
    console.log(`${ts()} ${LEVEL_LABEL[level]} ${this.prefix}${message}${fmtData(data)}`);
  }

  protocolSend(type: string, toEndpoint: string, data?: Record<string, unknown>): void {
    const short = shortenEndpoint(toEndpoint);
    console.log(`${ts()} \x1b[35mPROTO\x1b[0m ${this.prefix}\x1b[32m→ ${type}\x1b[0m  to=${short}${fmtData(data)}`);
  }

  protocolRecv(type: string, fromEndpoint: string | null, data?: Record<string, unknown>): void {
    const short = fromEndpoint ? shortenEndpoint(fromEndpoint) : "?";
    console.log(`${ts()} \x1b[35mPROTO\x1b[0m ${this.prefix}\x1b[34m← ${type}\x1b[0m  from=${short}${fmtData(data)}`);
  }
}

// ===========================================================================
// NullKatariLogger — for tests / silence
// ===========================================================================

export class NullKatariLogger implements KatariLogger {
  log(): void {}
  protocolSend(): void {}
  protocolRecv(): void {}
}
