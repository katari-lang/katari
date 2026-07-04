// SubprocessFfiTransport: an `FfiTransport` backed by a long-lived external (FFI) sidecar process. It speaks
// the newline-JSON `sidecar-protocol` over the child's stdio: a `dispatch` / `abort` / `delegateResult` goes
// out on the child's stdin, the sidecar's messages (`result` / `throw` / `error` / `cancelled` /
// `delegate`) come back on its stdout, and stderr is left for the sidecar's own logs. The sidecar is spawned lazily on the first
// dispatch and respawned after a crash; a crash fails every call still in flight as an `error` completion (a
// panic), so the ffi reactor never waits forever on a dead process. Calls are correlated by their
// `delegation` id — the id the ffi reactor's pending-call and core's external proxy thread share — so the
// transport needs no request-id table of its own; inner agent calls ride the sidecar's own `call` token.
//
// The transport is split from the channel: this class implements the protocol logic over an injected
// `SidecarSpawner`, so the routing / crash / cancel behaviour is unit-testable with a fake channel, while
// `subprocessSidecar` is the thin real channel that spawns the process and frames its stdio.

import { spawn } from "node:child_process";
import type { DelegationId } from "../ids.js";
import {
  type FfiCall,
  type FfiCompletion,
  type FfiInnerDelegate,
  type FfiInnerResult,
  type FfiTransport,
  INTERRUPTED_MESSAGE,
} from "./runner.js";
import {
  decodeSidecarMessage,
  encodeRuntimeMessage,
  LineBuffer,
  type RuntimeMessage,
  type SidecarMessage,
} from "./sidecar-protocol.js";

/** The runtime's end of one running sidecar: send it a message, or kill it. */
export interface SidecarHandle {
  send(message: RuntimeMessage): void;
  kill(): void;
}

/** How the transport is notified by a sidecar: one message per protocol line, and one close (exit / spawn
 *  failure) with a human reason. */
export interface SidecarHandlers {
  onMessage(message: SidecarMessage): void;
  onClose(reason: string): void;
}

/** Spawn a sidecar wired to the given handlers, returning the handle to drive it. Injectable so the protocol
 *  logic can be tested without a real process. */
export type SidecarSpawner = (handlers: SidecarHandlers) => SidecarHandle;

export class SubprocessFfiTransport implements FfiTransport {
  private sink: ((completion: FfiCompletion) => void) | null = null;
  private delegateSink: ((request: FfiInnerDelegate) => void) | null = null;
  private handle: SidecarHandle | null = null;
  /** Calls dispatched but not yet replied — keyed by `delegation`, so a sidecar crash can fail them all as
   *  panics rather than leave their proxy threads suspended forever. */
  private readonly inFlight = new Set<DelegationId>();

  constructor(private readonly spawner: SidecarSpawner) {}

  onComplete(sink: (completion: FfiCompletion) => void): void {
    this.sink = sink;
  }

  onDelegate(sink: (request: FfiInnerDelegate) => void): void {
    this.delegateSink = sink;
  }

  dispatch(call: FfiCall): void {
    this.inFlight.add(call.delegation);
    this.ensureSpawned().send({
      kind: "dispatch",
      delegation: call.delegation,
      key: call.key,
      argument: call.argument,
    });
  }

  recover(delegation: DelegationId): void {
    // At-most-once: never re-run a handler. Still in flight ⇒ this transport (and so its process) survived
    // a warm reset — leave the handler alone, its reply will come. Not in flight ⇒ the process that ran it
    // is gone (this transport is fresh, or the sidecar crashed) — fail the call rather than re-execute.
    if (!this.inFlight.has(delegation)) {
      this.sink?.({ delegation, outcome: { kind: "error", message: INTERRUPTED_MESSAGE } });
    }
  }

  abort(delegation: DelegationId): void {
    // Nothing to abort if no sidecar is running (the call cannot be in flight); otherwise ask it to stop, and
    // wait for its `cancelled` (or any other completion, which the reactor treats as the abort).
    this.handle?.send({ kind: "abort", delegation });
  }

  deliverDelegateResult(result: FfiInnerResult): void {
    // A result for a process that already died is moot: the crash failed the parent call, and the respawned
    // process's tokens never collide (the sidecar mints process-unique tokens), so dropping it is safe.
    this.handle?.send({
      kind: "delegateResult",
      delegation: result.delegation,
      call: result.call,
      outcome: result.outcome,
    });
  }

  /** Kill the sidecar (host cleanup on actor disposal). In-flight calls fail through the close handler. */
  close(): void {
    this.handle?.kill();
    this.handle = null;
  }

  private ensureSpawned(): SidecarHandle {
    if (this.handle !== null) return this.handle;
    const handle = this.spawner({
      onMessage: (message) => this.onMessage(message),
      onClose: (reason) => this.onClose(reason),
    });
    this.handle = handle;
    return handle;
  }

  private onMessage(message: SidecarMessage): void {
    if (message.kind === "delegate") {
      this.delegateSink?.(message);
      return;
    }
    this.inFlight.delete(message.delegation);
    this.sink?.(toCompletion(message));
  }

  private onClose(reason: string): void {
    // The sidecar died: fail every call still in flight as a panic, and drop the handle so the next dispatch
    // respawns. (A failure of a call whose proxy is already cancelling is treated by the reactor as its abort
    // confirmation, so an abort that races the crash still completes gracefully.) The calls' pending inner
    // delegations die as orphans — their results are undeliverable and are dropped by `deliverDelegateResult`.
    const failed = [...this.inFlight];
    this.inFlight.clear();
    this.handle = null;
    for (const delegation of failed) {
      this.sink?.({ delegation, outcome: { kind: "error", message: reason } });
    }
  }
}

/** The real channel: spawn the sidecar command and frame the protocol over its stdio — runtime messages out
 *  on stdin, sidecar messages in on stdout (one JSON per line), stderr inherited for the sidecar's logs. */
export function subprocessSidecar(
  command: string,
  args: string[] = [],
  env?: Record<string, string>,
): SidecarSpawner {
  return (handlers) => {
    // When `env` is given, the sidecar gets EXACTLY those vars — it does NOT inherit the runtime's environment
    // (which holds DB / object-store credentials), so user FFI handler code cannot read them. The injected vars
    // carry only the runtime's own URL + the project id, letting a handler reach the blob side channel over
    // HTTP. The production materialize spawns `node` by its absolute path (`process.execPath`), so no inherited
    // `PATH` is needed to resolve it. (`env` omitted — the integration test's own sidecar — keeps the default
    // inheritance, which is fine for first-party code.)
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "inherit"],
      ...(env !== undefined ? { env } : {}),
    });
    const buffer = new LineBuffer();
    let closed = false;
    const close = (reason: string): void => {
      if (closed) return;
      closed = true;
      handlers.onClose(reason);
    };
    // Decode stdout as UTF-8 at the stream level: Node's StringDecoder then retains a partial multibyte
    // codepoint across chunk boundaries, so a non-ASCII reply value isn't corrupted before LineBuffer rejoins
    // its line. (Decoding each raw Buffer chunk independently would mangle a split codepoint into U+FFFD.)
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      for (const line of buffer.push(chunk)) {
        const message = decodeSidecarMessage(line);
        if (message !== null) handlers.onMessage(message);
      }
    });
    // A write to a dying child's stdin surfaces EPIPE on the stream; the close handler already fails its
    // calls, so swallow it rather than let it become an unhandled error.
    child.stdin?.on("error", () => {});
    child.on("exit", (code, signal) => close(exitReason(code, signal)));
    child.on("error", (error) => close(`FFI sidecar failed to start: ${error.message}`));
    return {
      send: (message) => void child.stdin?.write(encodeRuntimeMessage(message)),
      kill: () => void child.kill(),
    };
  };
}

function exitReason(code: number | null, signal: NodeJS.Signals | null): string {
  if (signal !== null) return `FFI sidecar terminated by signal ${signal}`;
  return `FFI sidecar exited (code ${code ?? "unknown"})`;
}

function toCompletion(message: Exclude<SidecarMessage, { kind: "delegate" }>): FfiCompletion {
  switch (message.kind) {
    case "result":
      return { delegation: message.delegation, outcome: { kind: "result", value: message.value } };
    case "throw":
      return { delegation: message.delegation, outcome: { kind: "throw", error: message.error } };
    case "error":
      return {
        delegation: message.delegation,
        outcome: { kind: "error", message: message.message },
      };
    case "cancelled":
      return { delegation: message.delegation, outcome: { kind: "cancelled" } };
  }
}
