// SubprocessFfiTransport: an `FfiTransport` backed by a long-lived external (FFI) sidecar process. It speaks
// the newline-JSON `sidecar-protocol` over the child's stdio: a `dispatch` goes out on the child's stdin, the
// reply (`result` / `error` / `cancelled`) comes back on its stdout, and stderr is left for the sidecar's own
// logs. The sidecar is spawned lazily on the first dispatch and respawned after a crash; a crash fails every
// call still in flight as an `error` completion (a panic), so the ffi reactor never waits forever on a dead
// process. Calls are correlated by their `delegation` id — the id the ffi reactor's pending-call and core's
// external proxy thread share — so the transport needs no request-id table of its own.
//
// The transport is split from the channel: this class implements the protocol logic over an injected
// `SidecarSpawner`, so the routing / crash / cancel behaviour is unit-testable with a fake channel, while
// `subprocessSidecar` is the thin real channel that spawns the process and frames its stdio.

import { spawn } from "node:child_process";
import type { DelegationId } from "../ids.js";
import type { FfiCall, FfiCompletion, FfiTransport } from "./runner.js";
import {
  decodeReply,
  encodeRequest,
  LineBuffer,
  type SidecarReply,
  type SidecarRequest,
} from "./sidecar-protocol.js";

/** The runtime's end of one running sidecar: send it a request, or kill it. */
export interface SidecarHandle {
  send(request: SidecarRequest): void;
  kill(): void;
}

/** How the transport is notified by a sidecar: one reply per completed message, and one close (exit / spawn
 *  failure) with a human reason. */
export interface SidecarHandlers {
  onReply(reply: SidecarReply): void;
  onClose(reason: string): void;
}

/** Spawn a sidecar wired to the given handlers, returning the handle to drive it. Injectable so the protocol
 *  logic can be tested without a real process. */
export type SidecarSpawner = (handlers: SidecarHandlers) => SidecarHandle;

export class SubprocessFfiTransport implements FfiTransport {
  private sink: ((completion: FfiCompletion) => void) | null = null;
  private handle: SidecarHandle | null = null;
  /** Calls dispatched but not yet replied — keyed by `delegation`, so a sidecar crash can fail them all as
   *  panics rather than leave their proxy threads suspended forever. */
  private readonly inFlight = new Set<DelegationId>();

  constructor(private readonly spawner: SidecarSpawner) {}

  onComplete(sink: (completion: FfiCompletion) => void): void {
    this.sink = sink;
  }

  dispatch(call: FfiCall): void {
    this.inFlight.add(call.delegation);
    this.ensureSpawned().send({
      kind: "dispatch",
      delegation: call.delegation,
      key: call.key,
      argument: call.argument,
      redispatch: call.redispatch ?? false,
    });
  }

  abort(delegation: DelegationId): void {
    // Nothing to abort if no sidecar is running (the call cannot be in flight); otherwise ask it to stop, and
    // wait for its `cancelled` (or any other completion, which the reactor treats as the abort).
    this.handle?.send({ kind: "abort", delegation });
  }

  /** Kill the sidecar (host cleanup on actor disposal). In-flight calls fail through the close handler. */
  close(): void {
    this.handle?.kill();
    this.handle = null;
  }

  private ensureSpawned(): SidecarHandle {
    if (this.handle !== null) return this.handle;
    const handle = this.spawner({
      onReply: (reply) => this.onReply(reply),
      onClose: (reason) => this.onClose(reason),
    });
    this.handle = handle;
    return handle;
  }

  private onReply(reply: SidecarReply): void {
    this.inFlight.delete(reply.delegation);
    this.sink?.(toCompletion(reply));
  }

  private onClose(reason: string): void {
    // The sidecar died: fail every call still in flight as a panic, and drop the handle so the next dispatch
    // respawns. (A failure of a call whose proxy is already cancelling is treated by the reactor as its abort
    // confirmation, so an abort that races the crash still completes gracefully.)
    const failed = [...this.inFlight];
    this.inFlight.clear();
    this.handle = null;
    for (const delegation of failed) {
      this.sink?.({ delegation, outcome: { kind: "error", message: reason } });
    }
  }
}

/** The real channel: spawn the sidecar command and frame the protocol over its stdio — `dispatch` / `abort`
 *  out on stdin, replies in on stdout (one JSON per line), stderr inherited for the sidecar's logs. */
export function subprocessSidecar(command: string, args: string[] = []): SidecarSpawner {
  return (handlers) => {
    const child = spawn(command, args, { stdio: ["pipe", "pipe", "inherit"] });
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
        const reply = decodeReply(line);
        if (reply !== null) handlers.onReply(reply);
      }
    });
    // A write to a dying child's stdin surfaces EPIPE on the stream; the close handler already fails its
    // calls, so swallow it rather than let it become an unhandled error.
    child.stdin?.on("error", () => {});
    child.on("exit", (code, signal) => close(exitReason(code, signal)));
    child.on("error", (error) => close(`FFI sidecar failed to start: ${error.message}`));
    return {
      send: (request) => void child.stdin?.write(encodeRequest(request)),
      kill: () => void child.kill(),
    };
  };
}

function exitReason(code: number | null, signal: NodeJS.Signals | null): string {
  if (signal !== null) return `FFI sidecar terminated by signal ${signal}`;
  return `FFI sidecar exited (code ${code ?? "unknown"})`;
}

function toCompletion(reply: SidecarReply): FfiCompletion {
  switch (reply.kind) {
    case "result":
      return { delegation: reply.delegation, outcome: { kind: "result", value: reply.value } };
    case "error":
      return { delegation: reply.delegation, outcome: { kind: "error", message: reply.message } };
    case "cancelled":
      return { delegation: reply.delegation, outcome: { kind: "cancelled" } };
  }
}
