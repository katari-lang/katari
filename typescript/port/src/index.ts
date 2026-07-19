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
// `KatariFile` / `KatariString` (no raw `$katari_ref` handling), data values are `KatariData`, received callables
// are `KatariAgent`. The context is the way back into the runtime: `context.call(...)` runs another agent
// (core by default, or another reactor), `context.file(...)` produces a file value.

import { randomUUID } from "node:crypto";
import type { Json } from "@katari-lang/types";
import { downloadBlob, uploadBlob } from "./blob.js";
import {
  type DelegateCallee,
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

/** An inner agent call could not be DISPATCHED: the callee value is not callable, or its agent / reactor /
 *  argument could not be resolved (a LOCAL bad-dispatch failure, surfaced at the call site before any callee
 *  ran). A callee that DID run and then failed (panicked or raised a typed throw) does NOT reject with this —
 *  its failure unwinds up the delegation, caught by a katari-side handler above or failing the run. The
 *  message is the runtime's failure message. */
export class KatariCallError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "KatariCallError";
  }
}

/** A typed katari error (`prelude.throw`) a handler raises for ITS OWN call. Thrown out of a handler —
 *  `katari.throw(payload)` — it fails this call as `throw[T]` with `payload` as the error value, caught by a
 *  katari-side handler like any stdlib throw (declare it on the agent: `external agent ... with
 *  prelude.throw[my_error]`). Only used for the handler's OWN outward throw: an inner `context.call` whose
 *  callee throws no longer rejects with this — the callee's throw proxies UP the delegation to be caught in
 *  katari, so a handler never sees another agent's throw as a JS rejection. */
export class KatariThrowError extends Error {
  constructor(readonly error: unknown) {
    // The JS-facing message is a logging courtesy; the katari-facing content is the payload.
    super(`katari throw: ${describeThrowPayload(error)}`);
    this.name = "KatariThrowError";
  }
}

function describeThrowPayload(value: unknown): string {
  try {
    return JSON.stringify(encodeWireValue(value));
  } catch {
    return String(value);
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
  /** Call another agent and await its (decoded) result — `core` agents by qualified name (the default), or
   *  another reactor's callee by key (`options.reactor`). The declared `Result` is assumed, like the
   *  handler's own argument type. Rejects with `KatariCallError` (a LOCAL bad dispatch — the callee could not
   *  be resolved / is not callable) or `KatariCancelledError` (this call, or the whole handler call, was
   *  cancelled). A callee that runs and then FAILS (panics or raises a typed `prelude.throw`) does NOT reject
   *  this call — its failure unwinds UP the delegation, to be caught by a katari-side handler above or to
   *  fail the run. Catch a callee's error in katari, not here. */
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
 * `result` (a `throw` if it raised a `KatariThrowError`; an `error` if it threw anything else / no handler
 * is registered); an `abort` signals the in-flight handler and rejects its pending inner calls, and once
 * that handler settles the reply is a `cancelled` confirmation instead of its result/error. An inner
 * `context.call` goes out as a `delegate` message and suspends until its `delegateResult` comes back.
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
          // The inner channel settles only result / error / cancelled: a callee's OWN failure (a panic or a
          // typed `prelude.throw`) no longer settles this call — it proxies UP the delegation, to be caught
          // by a katari-side handler above or to fail the run. So `context.call` never rejects on a callee
          // failure; the only rejections are a LOCAL bad dispatch (`error`, see the runtime's
          // `resolveInnerCall`) and a cancellation. The wire's `throw` outcome is never produced here.
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
            default:
              // The inner channel never produces a `throw` (a callee's throw proxies up). A stray one is
              // protocol drift — reject loudly rather than leave `context.call` hanging forever on a
              // settlement that will never come.
              pending.reject(
                new KatariCallError(
                  `unexpected inner delegateResult outcome "${message.outcome.kind}"`,
                ),
              );
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
      // one settle delete the other's entry (breaking abort, double-replying). The runtime never sends one
      // (execution is at-most-once — nothing is ever re-dispatched), so treat it as protocol drift: keep
      // the original, report it, drop the duplicate.
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
          // A handler unwinding on cancellation rejects with `KatariCancelledError` (its inner call / file op
          // saw the abort) — the expected cancellation path, so confirm it quietly. Any OTHER rejection while
          // aborted is a real failure during cleanup: pass its natural reply through, so `settleDispatch`
          // still confirms the cancel but also logs the swallowed error (its whole reason for existing).
          if (dispatch.controller.signal.aborted && error instanceof KatariCancelledError) {
            this.settleDispatch(message.delegation, dispatch, send, {
              kind: "cancelled",
              delegation: message.delegation,
            });
            return;
          }
          this.settleDispatch(
            message.delegation,
            dispatch,
            send,
            error instanceof KatariThrowError
              ? throwReply(message.delegation, error.error)
              : {
                  kind: "error",
                  delegation: message.delegation,
                  message: errorMessage(error),
                },
          );
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
      if (reply.kind === "error" || reply.kind === "throw") {
        // The handler threw while it was being cancelled (e.g. a failing cleanup). The caller is already
        // unwinding and only needs the `cancelled` confirmation, but log the swallowed error so an
        // operator isn't left guessing why a cancelled call also failed.
        const detailText = reply.kind === "error" ? reply.message : JSON.stringify(reply.error);
        reportDiagnostic(`handler threw during cancellation: ${detailText}`);
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
      callee: DelegateCallee,
      wireArgument: Json | null,
    ): Promise<KatariValue> => {
      if (signal.aborted) return Promise.reject(new KatariCancelledError());
      // The token is unique ACROSS sidecar processes, not just within one: the runtime's bridge rows are
      // durable, so a stale bridge from a former process may still deliver under its old token — with a
      // per-process counter that delivery could collide with a fresh call's token and settle it with a
      // stray result. A UUID makes stale deliveries land nowhere, by construction.
      const token = randomUUID();
      return new Promise<KatariValue>((resolve, reject) => {
        dispatch.pendingCalls.add(token);
        this.pendingCalls.set(token, { delegation: message.delegation, binding, resolve, reject });
        send({
          kind: "delegate",
          delegation: message.delegation,
          call: token,
          callee,
          argument: wireArgument,
        });
      });
    };
    const binding: ValueBinding = {
      download: (ref) => downloadBlob(ref, signal),
      // A received callable dispatches itself: the raw reference rides verbatim as the `value` callee (it is
      // already wire JSON — re-encoding would escape its `$`-keys), and the runtime resolves it to a target.
      callCallable: (target, argument) =>
        sendDelegate({ kind: "value", callable: target }, encodeWireValue(argument)),
    };
    const context: HandlerContext = {
      signal,
      call: <Result>(agent: string, argument?: unknown, options?: CallOptions) =>
        // The declared Result is assumed (the typed-boundary assertion, like the argument type).
        sendDelegate(
          {
            kind: "named",
            agent,
            ...(options?.reactor !== undefined ? { reactor: options.reactor } : {}),
          },
          encodeWireValue(argument),
        ) as Promise<Result>,
      file: async (content, options) => {
        const bytes = typeof content === "string" ? new TextEncoder().encode(content) : content;
        const handle = await uploadBlob(message.delegation, bytes, options, signal);
        // Seed the download cache with what this call just uploaded — reading it back costs nothing.
        return new KatariFile(handle, binding, {
          bytes,
          size: bytes.byteLength,
          ...(options?.contentType !== undefined ? { contentType: options.contentType } : {}),
        });
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

/** A `throw` reply — the typed-error twin of `resultReply`, with the same encode guard: a payload that has
 *  no wire form fails the call as a plain `error` (a panic) instead of taking the process down. */
function throwReply(delegation: string, error: unknown): SidecarMessage {
  try {
    return { kind: "throw", delegation, error: encodeWireValue(error) };
  } catch (cause) {
    return {
      kind: "error",
      delegation,
      message: `the katari.throw payload has no wire form: ${errorMessage(cause)}`,
    };
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

  /** Raise a typed error from a handler: fail this call as `prelude.throw` with `error` as its payload,
   *  caught by a katari-side handler (declare the effect on the agent: `external agent ... with
   *  prelude.throw[my_error]`). The payload is encoded like a return value — plain data and the value
   *  wrappers all work. Never returns. */
  throw(error: unknown): never {
    throw new KatariThrowError(error);
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
export type {
  DelegateCallee,
  DelegateOutcome,
  RuntimeMessage,
  SidecarMessage,
} from "./protocol.js";
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
