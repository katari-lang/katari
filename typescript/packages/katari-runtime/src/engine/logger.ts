// Logger: a small interface the engine writes diagnostic events to.
//
// Earlier shapes of this module exposed an Effect `Context.Tag` so
// callers could `yield* Logger`. The engine never actually ran in an
// Effect context (the runner uses plain async/await), so the tag was
// dead. It was removed (and the `effect` dependency along with it).
//
// The on-the-wire log shape is captured as `LogEntry` so the engine can
// also accumulate logs into the Result for callers that prefer to drain
// them on the way out.

export type LogLevel = "debug" | "info" | "warn" | "error";

export type LogEntry = {
  level: LogLevel;
  message: string;
  context?: Record<string, unknown>;
  /** Optional epoch millis. The engine does not compute this; the host can fill it on the way out. */
  timestamp?: number;
};

export interface Logger {
  log(level: LogLevel, message: string, context?: Record<string, unknown>): void;
}

// ─── Built-in adapters ─────────────────────────────────────────────────────

const LEVEL_PRIORITY: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
};

export function buildConsoleLogger(minLevel: LogLevel = "info"): Logger {
  const threshold = LEVEL_PRIORITY[minLevel];
  return {
    log(level, message, context) {
      if (LEVEL_PRIORITY[level] < threshold) return;
      const prefix = `[${level.toUpperCase()}]`;
      if (context !== undefined) {
        // eslint-disable-next-line no-console -- the console adapter is allowed to use console.
        console.log(prefix, message, context);
      } else {
        // eslint-disable-next-line no-console
        console.log(prefix, message);
      }
    },
  };
}

export const consoleLogger: Logger = buildConsoleLogger("info");

export const noopLogger: Logger = {
  log() {
    /* discard */
  },
};
