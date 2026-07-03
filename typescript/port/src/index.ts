// Katari FFI port — the sidecar runtime a user's external (FFI) handlers import. A handler file calls
// `katari.agent<Argument>(name, handler)` to register an implementation; the bundler (`@katari-lang/bundle`)
// sets the ambient `globalThis.__katariModule` per file, so the registration lands under the flat key
// `<module>.<name>` — exactly the key the compiler lowers an `external agent` to. The bundle ends by calling
// `__startSidecar()`, which reads runtime messages from stdin and writes sidecar messages to stdout over the
// newline-JSON `protocol`.
//
// A handler is written against its *declared* types, PureScript-style: the katari compiler already checked
// the call site against the external agent's schema, so the argument is assumed to match `Argument` — no
// defensive re-validation. The argument arrives decoded (`values.ts`): blob-backed contents are
// `KatariFile` / `KatariString` (no raw `$ref` handling), data values are `KatariData`, received callables
// are `KatariAgent`. The context is the way back into the runtime: `context.call(...)` runs another agent
// (core by default, or another reactor), `context.file(...)` produces a file value.

import type { Json } from "@katari-lang/types";
import { downloadBlob, uploadBlob } from "./blob.js";
import {
  decodeRuntimeMessage,
  encodeSidecarMessage,
  LineBuffer,
  type RuntimeMessage,
  type SidecarMessage,
} from "./protocol.js";
import {
  decodeWireValue,
  encodeWireValue,
  KatariFile,
  type KatariValue,
  type ValueBinding,
} from "./values.js";

/** The wired-in dynamic-dispatch agent `KatariAgent.call` goes through: it re-materialises the callable
 *  value (with its own snapshot + generics) and runs it — see the runtime's `call_agent` unwrap. */
const CALL_AGENT = "prelude.ai.call_agent";

/** An inner agent call failed: the callee panicked, or the call could not be resolved (an unknown agent /
 *  reactor). The message is the runtime's failure message. */
export class KatariCallError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "KatariCallError";
  }
}

/** An inner agent call was cancelled — usually because the handler's own call is being cancelled. A handler
 *  awaiting the call unwinds here; it should finish quickly (the reply becomes the cancel confirmation). */
export class KatariCancelledError extends Error {
  constructor() {
    super("the call was cancelled");
    this.name = "KatariCancelledError";
  }
}

/** Options for `context.call`. */
export interface CallOptions {
  /** The reactor that runs the callee: `core` (the default) runs a katari agent by qualified name; `ffi`
   *  runs another FFI handler by key; `http` performs a built-in http request. */
  reactor?: "core" | "ffi" | "http";
}

/** Options for `context.file`. */
export interface FileOptions {
  /** The MIME type recorded with the blob (e.g. `"image/png"`), surfaced on download. */
  contentType?: string;
}

/** Context passed to every handler alongside its argument. */
export interface HandlerContext {
  /** Aborted when the runtime cancels this call — a long-running handler should observe it and stop, letting
   *  its promise settle (the port then confirms the cancellation). A pending `context.call` rejects with
   *  `KatariCancelledError` on cancellation, so an awaiting handler unwinds by itself. */
  signal: AbortSignal;
  /** True on a recovery re-dispatch (the runtime restarted with this call still in flight). A handler with a
   *  non-idempotent side effect can use it to dedupe. */
  redispatch: boolean;
  /** Call another agent and await its (decoded) result — `core` agents by qualified name (the default), or
   *  another reactor's callee by key (`options.reactor`). The declared `Result` is assumed, like the
   *  handler's own argument type. Rejects with `KatariCallError` (the callee failed) or
   *  `KatariCancelledError` (the callee — or this whole call — was cancelled). */
  call<Result = KatariValue>(
    agent: string,
    argument?: unknown,
    options?: CallOptions,
  ): Promise<Result>;
  /** Produce a new `file` value from bytes (or UTF-8 text): the bytes upload to the runtime over the blob
   *  side channel, and the returned `KatariFile` can be returned from the handler (or passed to
   *  `context.call`) to hand the file on. Owned by this call — reclaimed if the handler dies first. */
  file(content: Uint8Array | string, options?: FileOptions): Promise<KatariFile>;
}

/** A user's FFI handler over its declared argument type. The return value is encoded blindly
 *  (`values.ts`) — plain data, `KatariFile` / `KatariString` / `KatariData` / `KatariAgent` all encode. */
export type Handler<Argument = KatariValue> = (
  argument: Argument,
  context: HandlerContext,
) => unknown;

/** How the sidecar talks to the runtime: a stream of inbound messages, and a `send` for outbound ones.
 *  Injectable so the dispatch logic is testable without real stdio. */
export interface SidecarChannel {
  onMessage(handler: (message: RuntimeMessage) => void): void;
  send(message: SidecarMessage): void;
}

/** One in-flight dispatch: its abort controller, and the tokens of its pending inner calls (so an abort can
 *  unwind them, and a settled handler drops the leftovers). */
interface InFlightDispatch {
  controller: AbortController;
  pendingCalls: Set<string>;
}

/** One pending inner agent call awaiting its `delegateResult`. */
interface PendingCall {
  delegation: string;
  binding: ValueBinding;
  resolve: (value: KatariValue) => void;
  reject: (error: Error) => void;
}

/**
 * The sidecar's handler registry and dispatch logic — independent of the stdio channel so it is unit
 * testable. A `dispatch` decodes the argument, runs the keyed handler, and replies with its encoded
 * `result` (or an `error` if it throws / no handler is registered); an `abort` signals the in-flight
 * handler and rejects its pending inner calls, and once that handler settles the reply is a `cancelled`
 * confirmation instead of its result/error. An inner `context.call` goes out as a `delegate` message and
 * suspends until its `delegateResult` comes back.
 */
export class Sidecar {
  private readonly handlers = new Map<string, Handler>();
  private readonly inFlight = new Map<string, InFlightDispatch>();
  private readonly pendingCalls = new Map<string, PendingCall>();

  register<Argument>(key: string, handler: Handler<Argument>): void {
    if (this.handlers.has(key)) {
      throw new Error(`katari: an FFI handler for "${key}" is already registered`);
    }
    // The declared Argument is assumed to match what the (schema-checked) katari call site sends — the whole
    // point of the typed boundary — so widening the handler back to the registry's KatariValue is safe.
    this.handlers.set(key, handler as Handler);
  }

  /** React to one inbound message, emitting messages through `send`. */
  handle(message: RuntimeMessage, send: (message: SidecarMessage) => void): void {
    switch (message.kind) {
      case "dispatch":
        this.dispatch(message, send);
        return;
      case "abort": {
        // Signal the in-flight handler and unwind whatever it still awaits from inner calls; the `cancelled`
        // reply is sent when the handler settles. A handler that already finished has no entry — a no-op.
        const dispatch = this.inFlight.get(message.delegation);
        if (dispatch === undefined) return;
        dispatch.controller.abort();
        for (const token of dispatch.pendingCalls) {
          this.settlePendingCall(token, (pending) => pending.reject(new KatariCancelledError()));
        }
        dispatch.pendingCalls.clear();
        return;
      }
      case "delegateResult":
        this.settlePendingCall(message.call, (pending) => {
          switch (message.outcome.kind) {
            case "result":
              pending.resolve(decodeWireValue(message.outcome.value, pending.binding));
              return;
            case "error":
              pending.reject(new KatariCallError(message.outcome.message));
              return;
            case "cancelled":
              pending.reject(new KatariCancelledError());
              return;
          }
        });
        return;
    }
  }

  /** Serve messages from a channel until it ends (the channel drives delivery). */
  serve(channel: SidecarChannel): void {
    channel.onMessage((message) => this.handle(message, (reply) => channel.send(reply)));
  }

  private dispatch(
    message: Extract<RuntimeMessage, { kind: "dispatch" }>,
    send: (message: SidecarMessage) => void,
  ): void {
    if (this.inFlight.has(message.delegation)) {
      // A second dispatch for an already in-flight delegation would overwrite its abort controller and let
      // one settle delete the other's entry (breaking abort, double-replying). The runtime never does this
      // within a process — a `redispatch` only follows a crash, i.e. a fresh process with an empty map — so
      // treat it as protocol drift: keep the original, report it, drop the duplicate.
      reportDiagnostic(
        `duplicate dispatch for in-flight delegation ${message.delegation}; ignoring it`,
      );
      return;
    }
    const handler = this.handlers.get(message.key);
    if (handler === undefined) {
      send({
        kind: "error",
        delegation: message.delegation,
        message: `no FFI handler registered for "${message.key}"`,
      });
      return;
    }
    const controller = new AbortController();
    const dispatch: InFlightDispatch = { controller, pendingCalls: new Set() };
    this.inFlight.set(message.delegation, dispatch);
    const { context, binding } = this.makeContext(message, dispatch, send);
    // Run off the current tick (and normalise a synchronous throw into a rejected promise). The argument is
    // decoded inside the chain too, so a malformed argument fails THIS call rather than the process.
    Promise.resolve()
      .then(() => handler(decodeWireValue(message.argument, binding), context))
      .then(
        (value) =>
          this.settleDispatch(
            message.delegation,
            dispatch,
            send,
            resultReply(message.delegation, value),
          ),
        (error: unknown) => {
          if (dispatch.controller.signal.aborted) {
            this.settleDispatch(message.delegation, dispatch, send, {
              kind: "cancelled",
              delegation: message.delegation,
            });
            return;
          }
          this.settleDispatch(message.delegation, dispatch, send, {
            kind: "error",
            delegation: message.delegation,
            message: errorMessage(error),
          });
        },
      );
  }

  /** Send a settled dispatch's reply and drop its bookkeeping. Inner calls the handler left pending are
   *  abandoned (their late results are ignored) — the runtime cancels their delegations on its side once
   *  this reply lands, so nothing keeps running unobserved. */
  private settleDispatch(
    delegation: string,
    dispatch: InFlightDispatch,
    send: (message: SidecarMessage) => void,
    reply: SidecarMessage,
  ): void {
    this.inFlight.delete(delegation);
    for (const token of dispatch.pendingCalls) this.pendingCalls.delete(token);
    dispatch.pendingCalls.clear();
    if (dispatch.controller.signal.aborted && reply.kind !== "cancelled") {
      if (reply.kind === "error") {
        // The handler threw while it was being cancelled (e.g. a failing cleanup). The caller is already
        // unwinding and only needs the `cancelled` confirmation, but log the swallowed error so an
        // operator isn't left guessing why a cancelled call also failed.
        reportDiagnostic(`handler threw during cancellation: ${reply.message}`);
      }
      send({ kind: "cancelled", delegation });
      return;
    }
    send(reply);
  }

  private makeContext(
    message: Extract<RuntimeMessage, { kind: "dispatch" }>,
    dispatch: InFlightDispatch,
    send: (message: SidecarMessage) => void,
  ): { context: HandlerContext; binding: ValueBinding } {
    const signal = dispatch.controller.signal;
    const sendDelegate = (
      agent: string,
      wireArgument: Json | null,
      reactor?: string,
    ): Promise<KatariValue> => {
      if (signal.aborted) return Promise.reject(new KatariCancelledError());
      // The token must be unique ACROSS sidecar processes, not just within one: the runtime's bridge rows
      // are durable, so after a crash + re-dispatch a stale bridge still delivers under the old token — a
      // counter would collide with the fresh process's first calls and settle them with a stray result.
      const token = crypto.randomUUID();
      return new Promise<KatariValue>((resolve, reject) => {
        dispatch.pendingCalls.add(token);
        this.pendingCalls.set(token, { delegation: message.delegation, binding, resolve, reject });
        send({
          kind: "delegate",
          delegation: message.delegation,
          call: token,
          agent,
          ...(reactor !== undefined ? { reactor } : {}),
          argument: wireArgument,
        });
      });
    };
    const binding: ValueBinding = {
      download: (ref) => downloadBlob(ref, signal),
      // A received callable runs through the dynamic-dispatch agent: the raw reference rides verbatim as
      // `target` (it is already wire JSON — re-encoding would escape its `$`-keys), the argument is encoded.
      callCallable: (target, argument) =>
        sendDelegate(CALL_AGENT, { target, args: encodeWireValue(argument) }),
    };
    const context: HandlerContext = {
      signal,
      redispatch: message.redispatch,
      call: <Result>(agent: string, argument?: unknown, options?: CallOptions) =>
        // The declared Result is assumed (the typed-boundary assertion, like the argument type).
        sendDelegate(agent, encodeWireValue(argument), options?.reactor) as Promise<Result>,
      file: async (content, options) => {
        const bytes = typeof content === "string" ? new TextEncoder().encode(content) : content;
        const handle = await uploadBlob(message.delegation, bytes, options, signal);
        return new KatariFile(handle, binding, bytes);
      },
    };
    return { context, binding };
  }

  private settlePendingCall(token: string, settle: (pending: PendingCall) => void): void {
    const pending = this.pendingCalls.get(token);
    if (pending === undefined) return; // already settled (an abort), or a stale token from a former process
    this.pendingCalls.delete(token);
    this.inFlight.get(pending.delegation)?.pendingCalls.delete(token);
    settle(pending);
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** A `result` reply, guarding the user's return value on its way to the channel: the blind encoder turns
 *  wrappers into their wire form and rejects what has no wire form (a bigint, a cycle, raw bytes) — failing
 *  THIS one call as an `error` rather than throwing later inside an unawaited promise chain and taking the
 *  whole sidecar process, and every other in-flight call with it, down. */
function resultReply(delegation: string, value: unknown): SidecarMessage {
  try {
    return { kind: "result", delegation, value: encodeWireValue(value) };
  } catch (error) {
    return { kind: "error", delegation, message: errorMessage(error) };
  }
}

/** A diagnostic line for the operator. Always stderr — never stdout, which is the reply channel — so it
 *  surfaces in the runtime's inherited logs without corrupting protocol framing. */
function reportDiagnostic(message: string): void {
  process.stderr.write(`[katari-port] ${message}\n`);
}

function detail(value: unknown): string {
  return value instanceof Error ? (value.stack ?? value.message) : String(value);
}

// ─── The ambient `katari` API the bundle and user code use ───────────────────────────────────────

/** The process-wide sidecar all `katari.agent(...)` registrations land in and `__startSidecar()` serves.
 *  Exported so an advanced host can serve it on a custom channel (and tests can drive it directly). */
export const defaultSidecar = new Sidecar();

declare global {
  // eslint-disable-next-line no-var
  var __katariModule: string | undefined;
}

/** The module path the bundler set as ambient for the file currently being evaluated. */
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
   *  registered under `<module>.<name>`, the key the runtime dispatches by. The declared `Argument` is
   *  assumed to match the external agent's schema (the katari call site was checked against it). */
  agent<Argument = KatariValue>(name: string, handler: Handler<Argument>): void {
    if (name.includes(".")) {
      throw new Error(`katari.agent: name "${name}" must be a bare identifier, not a dotted key`);
    }
    defaultSidecar.register(`${ambientModule()}.${name}`, handler);
  },
};

export default katari;

let sidecarStarted = false;

/** Hand stdio control to the sidecar: read newline-JSON runtime messages from stdin and write sidecar
 *  messages to stdout. The bundle calls this once, after every `katari.agent(...)` registration has run. */
export function __startSidecar(): void {
  if (sidecarStarted) return; // The bundle calls this once; guard against a double take-over of stdio.
  sidecarStarted = true;

  installProcessGuards();
  redirectConsoleToStderr();

  const buffer = new LineBuffer();
  defaultSidecar.serve({
    onMessage: (handler) => {
      process.stdin.setEncoding("utf8");
      process.stdin.on("data", (chunk: string) => {
        for (const line of buffer.push(chunk)) {
          const message = decodeRuntimeMessage(line);
          if (message === null) {
            // A line we cannot read as a message is protocol drift or stray input on the request channel.
            // Surface it on stderr (never stdout) rather than dropping it silently, so a runtime/sidecar
            // mismatch is diagnosable instead of manifesting as a call that just hangs.
            reportDiagnostic(`ignoring unrecognised request line: ${line}`);
            continue;
          }
          handler(message);
        }
      });
      process.stdin.resume();
    },
    send: (message) => void process.stdout.write(encodeSidecarMessage(message)),
  });
}

/** Keep the sidecar alive and observable when async work fails outside a tracked handler call. A rejection
 *  from a timer / socket / emitter has no delegation to attribute, and on modern Node an unhandled rejection
 *  otherwise TERMINATES the process — failing every other in-flight call with it. Log to stderr and carry on
 *  instead. */
function installProcessGuards(): void {
  process.on("unhandledRejection", (reason) => {
    reportDiagnostic(`unhandled rejection (no delegation to attribute): ${detail(reason)}`);
  });
  process.on("uncaughtException", (error) => {
    reportDiagnostic(`uncaught exception: ${detail(error)}`);
  });
  // stdout is the reply channel; once the runtime is gone, a write surfaces EPIPE as an 'error' event, which
  // without a listener is itself an uncaught exception. The reply is moot on a dead channel — swallow it.
  process.stdout.on("error", () => {});
}

/** Route every `console` method to stderr. User handler code (and its dependencies) call `console.log`, which
 *  writes to stdout — the protocol's reply channel — where a stray line corrupts framing or is silently
 *  dropped. stderr is inherited by the runtime, so handler logging stays visible without touching the wire. */
function redirectConsoleToStderr(): void {
  const toStderr =
    (tag: string) =>
    (...args: unknown[]): void => {
      process.stderr.write(`[${tag}] ${formatConsoleArguments(args)}\n`);
    };
  console.log = toStderr("log");
  console.info = toStderr("info");
  console.warn = toStderr("warn");
  console.error = toStderr("error");
  console.debug = toStderr("debug");
}

function formatConsoleArguments(args: readonly unknown[]): string {
  return args
    .map((arg) => {
      if (typeof arg === "string") return arg;
      try {
        return JSON.stringify(arg);
      } catch {
        return String(arg);
      }
    })
    .join(" ");
}

export type { FileHandle } from "./blob.js";
export type { DelegateOutcome, RuntimeMessage, SidecarMessage } from "./protocol.js";
export {
  KatariAgent,
  KatariData,
  KatariFile,
  type KatariRecord,
  KatariString,
  type KatariText,
  type KatariValue,
  text,
} from "./values.js";
