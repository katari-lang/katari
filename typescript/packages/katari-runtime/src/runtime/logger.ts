// Logger interface for the runtime layer.
//
// All runtime components (MachineHandle, future helpers) accept a Logger via
// constructor injection so that the I/O-side (katari-api-server) can plug in
// a structured / unified logger later. The runtime package itself ships only
// console / noop adapters and never imports a logging library.

export type LogLevel = "debug" | "info" | "warn" | "error";

export interface Logger {
  log(level: LogLevel, message: string, context?: Record<string, unknown>): void;
}

const LEVEL_PRIORITY: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
};

/**
 * Build a console logger that drops everything below `minLevel`. The
 * default `info` cutoff matches "production sane" — `debug` is intended
 * for local development and CI failure reproduction.
 */
export function buildConsoleLogger(minLevel: LogLevel = "info"): Logger {
  const threshold = LEVEL_PRIORITY[minLevel];
  return {
    log(level, message, context) {
      if (LEVEL_PRIORITY[level] < threshold) return;
      const prefix = `[${level.toUpperCase()}]`;
      if (context !== undefined) {
        console.log(prefix, message, context);
      } else {
        console.log(prefix, message);
      }
    },
  };
}

/**
 * Default console logger at the `info` level. Kept as a module-level
 * singleton for backwards compatibility with existing imports; new
 * callers that need a different threshold should use
 * {@link buildConsoleLogger} directly.
 */
export const consoleLogger: Logger = buildConsoleLogger("info");

export const noopLogger: Logger = {
  log() {
    /* discard */
  },
};
