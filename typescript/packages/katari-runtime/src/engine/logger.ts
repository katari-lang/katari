// Logger: an Effect Service the engine writes diagnostic events to.
//
// Modeled as a Context.Tag so any code path inside `applyEvent` can `yield*
// Logger` and emit log entries without threading a Logger argument
// through every helper. The host attaches its own Logger via
// `Effect.provideService(LoggerTag, hostLogger)`.
//
// The on-the-wire log shape is captured as `LogEntry` so the engine can
// also accumulate logs into the Result (without an attached service) when
// running outside an Effect context — useful for tests / future synchronous
// callers.

import { Context } from "effect";

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

/** Effect Service tag — `yield* Logger` to obtain the active Logger. */
export class LoggerTag extends Context.Tag("katari/Logger")<
  LoggerTag,
  Logger
>() {}

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
