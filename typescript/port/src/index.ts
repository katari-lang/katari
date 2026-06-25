// Katari FFI port — the sidecar runtime a user's external (FFI) handlers import. A handler file calls
// `katari.agent(name, handler)` to register an implementation; the bundler (`@katari-lang/bundle`) sets the
// ambient `globalThis.__katariModule` per package, so the registration lands under the flat key
// `<package>.<name>` — exactly the key the compiler lowers an `external agent` to. The bundle ends by
// calling `__startSidecar()`, which reads dispatch requests from stdin and writes replies to stdout over the
// newline-JSON `protocol`. Handlers deal in plain `Json` (the runtime converts its tagged value model at its
// own edge), so authoring an FFI handler is just `(argument) => result`.

import type { Json } from "@katari-lang/types";
import {
  decodeRequest,
  encodeReply,
  LineBuffer,
  type SidecarReply,
  type SidecarRequest,
} from "./protocol.js";

/** Context passed to every handler alongside its argument. Ignorable by a simple `(argument) => result`. */
export interface HandlerContext {
  /** Aborted when the runtime cancels this call — a long-running handler should observe it and stop, letting
   *  its promise settle (the port then confirms the cancellation). */
  signal: AbortSignal;
  /** True on a recovery re-dispatch (the runtime restarted with this call still in flight). A handler with a
   *  non-idempotent side effect can use it to dedupe. */
  redispatch: boolean;
}

/** A user's FFI handler: plain `Json` in, plain `Json` (or a promise of it) out. */
export type Handler = (argument: Json | null, context: HandlerContext) => Json | Promise<Json>;

/** How the sidecar talks to the runtime: a stream of inbound requests, and a `send` for outbound replies.
 *  Injectable so the dispatch logic is testable without real stdio. */
export interface SidecarChannel {
  onRequest(handler: (request: SidecarRequest) => void): void;
  send(reply: SidecarReply): void;
}

/**
 * The sidecar's handler registry and dispatch logic — independent of the stdio channel so it is unit
 * testable. A `dispatch` runs the keyed handler and replies with its `result` (or an `error` if it throws /
 * no handler is registered); an `abort` signals the in-flight handler, and once that handler settles the
 * reply is a `cancelled` confirmation instead of its result/error.
 */
export class Sidecar {
  private readonly handlers = new Map<string, Handler>();
  private readonly inFlight = new Map<string, AbortController>();

  register(key: string, handler: Handler): void {
    if (this.handlers.has(key)) {
      throw new Error(`katari: an FFI handler for "${key}" is already registered`);
    }
    this.handlers.set(key, handler);
  }

  /** React to one inbound request, emitting replies through `send`. */
  handle(request: SidecarRequest, send: (reply: SidecarReply) => void): void {
    if (request.kind === "abort") {
      // Signal the in-flight handler; the `cancelled` reply is sent when it settles. A handler that already
      // finished (or never existed) has no controller — the runtime treats a missing reply as a no-op.
      this.inFlight.get(request.delegation)?.abort();
      return;
    }
    const handler = this.handlers.get(request.key);
    if (handler === undefined) {
      send({
        kind: "error",
        delegation: request.delegation,
        message: `no FFI handler registered for "${request.key}"`,
      });
      return;
    }
    const controller = new AbortController();
    this.inFlight.set(request.delegation, controller);
    const context: HandlerContext = { signal: controller.signal, redispatch: request.redispatch };
    // Run off the current tick (and normalise a synchronous throw into a rejected promise).
    Promise.resolve()
      .then(() => handler(request.argument, context))
      .then(
        (value) => {
          this.inFlight.delete(request.delegation);
          send(
            controller.signal.aborted
              ? { kind: "cancelled", delegation: request.delegation }
              : { kind: "result", delegation: request.delegation, value },
          );
        },
        (error: unknown) => {
          this.inFlight.delete(request.delegation);
          send(
            controller.signal.aborted
              ? { kind: "cancelled", delegation: request.delegation }
              : { kind: "error", delegation: request.delegation, message: errorMessage(error) },
          );
        },
      );
  }

  /** Serve requests from a channel until it ends (the channel drives delivery). */
  serve(channel: SidecarChannel): void {
    channel.onRequest((request) => this.handle(request, (reply) => channel.send(reply)));
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

// ─── The ambient `katari` API the bundle and user code use ───────────────────────────────────────

/** The process-wide sidecar all `katari.agent(...)` registrations land in and `__startSidecar()` serves.
 *  Exported so an advanced host can serve it on a custom channel (and tests can drive it directly). */
export const defaultSidecar = new Sidecar();

declare global {
  // eslint-disable-next-line no-var
  var __katariModule: string | undefined;
}

/** The package name the bundler set as ambient for the file currently being evaluated. */
function ambientModule(): string {
  const moduleName = globalThis.__katariModule;
  if (typeof moduleName !== "string" || moduleName.length === 0) {
    throw new Error(
      "katari.agent(...) called outside a bundled sidecar (globalThis.__katariModule is unset)",
    );
  }
  return moduleName;
}

export const katari = {
  /** Register an FFI handler. `name` is the bare local name the user wrote (`external agent foo`); it is
   *  registered under `<package>.<name>`, the key the runtime dispatches by. */
  agent(name: string, handler: Handler): void {
    if (name.includes(".")) {
      throw new Error(`katari.agent: name "${name}" must be a bare identifier, not a dotted key`);
    }
    defaultSidecar.register(`${ambientModule()}.${name}`, handler);
  },
};

export default katari;

/** Hand stdio control to the sidecar: read newline-JSON dispatch/abort requests from stdin and write replies
 *  to stdout. The bundle calls this once, after every `katari.agent(...)` registration has run. */
export function __startSidecar(): void {
  const buffer = new LineBuffer();
  defaultSidecar.serve({
    onRequest: (handler) => {
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (chunk: string) => {
        for (const line of buffer.push(chunk)) {
          const request = decodeRequest(line);
          if (request !== null) handler(request);
        }
      });
      process.stdin.resume();
    },
    send: (reply) => void process.stdout.write(encodeReply(reply)),
  });
}

export type { SidecarReply, SidecarRequest } from "./protocol.js";
