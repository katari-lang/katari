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

export const consoleLogger: Logger = {
  log(level, message, context) {
    const prefix = `[${level.toUpperCase()}]`;
    if (context !== undefined) {
      console.log(prefix, message, context);
    } else {
      console.log(prefix, message);
    }
  },
};

export const noopLogger: Logger = {
  log() {
    /* discard */
  },
};
