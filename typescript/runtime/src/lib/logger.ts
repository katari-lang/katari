export type LogLevel = "debug" | "info" | "warn" | "error";

const LEVEL_ORDER: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
};

/** The record fields the logger owns; a colliding meta/binding key is relocated, never dropped. */
const RESERVED_FIELDS = ["level", "time", "message"] as const;

export interface Logger {
  debug(message: string, meta?: Record<string, unknown>): void;
  info(message: string, meta?: Record<string, unknown>): void;
  warn(message: string, meta?: Record<string, unknown>): void;
  error(message: string, meta?: Record<string, unknown>): void;
  /** Returns a new logger that always attaches the given bindings. */
  child(bindings: Record<string, unknown>): Logger;
}

interface LoggerOptions {
  level: LogLevel;
  bindings?: Record<string, unknown>;
}

/**
 * Minimal dependency-free structured logger that emits one JSON line per
 * record. Swap the sink for pino/winston later without touching call sites.
 */
export function createLogger({ level, bindings = {} }: LoggerOptions): Logger {
  const threshold = LEVEL_ORDER[level];

  const emit = (logLevel: LogLevel, message: string, meta?: Record<string, unknown>): void => {
    if (LEVEL_ORDER[logLevel] < threshold) return;
    const record: Record<string, unknown> = { ...bindings, ...meta };
    // A caller-supplied binding/meta key must never clobber the event's own level/time/message — but it
    // must not be silently dropped either (a `{ message: err.message }` would vanish, hiding the real
    // error). Relocate any collision under a `meta.`-prefixed key, then stamp the reserved fields.
    for (const key of RESERVED_FIELDS) {
      if (key in record) record[`meta.${key}`] = record[key];
    }
    record.level = logLevel;
    record.time = new Date().toISOString();
    record.message = message;
    const sink = logLevel === "error" || logLevel === "warn" ? console.error : console.log;
    sink(JSON.stringify(record));
  };

  return {
    debug: (message, meta) => emit("debug", message, meta),
    info: (message, meta) => emit("info", message, meta),
    warn: (message, meta) => emit("warn", message, meta),
    error: (message, meta) => emit("error", message, meta),
    child: (childBindings) => createLogger({ level, bindings: { ...bindings, ...childBindings } }),
  };
}
