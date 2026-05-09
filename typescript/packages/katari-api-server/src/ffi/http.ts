// HTTP FFI executor: posts to an external sidecar over HTTP/JSON.
//
// Routes:
//   POST <baseUrl>/<module>/<name>?delegationId=...
//     body: { args: <Record<string, Value>> }
//     response: 200 with body { value: <Value> } on success
//                non-2xx → reject
//
//   POST <baseUrl>/__terminate?delegationId=...
//     body: empty
//     response: any (best-effort; ignored)
//
// AbortController is used so timeouts and explicit `terminate` calls can
// abort the in-flight fetch. The sidecar protocol intentionally stays
// minimal — production deployments may want to swap this for gRPC /
// Cap'n Proto / etc, but the FFIExecutor interface keeps that contained.

import type { DelegationId, QualifiedName, Value } from "katari-runtime";
import type { FFIExecutor, InvokeArgs } from "./executor.js";
import { withTimeout } from "./executor.js";

export type HttpFFIOptions = {
  baseUrl: string;
  /** Optional Authorization header value. */
  authHeader?: string;
  /** Default timeout when InvokeArgs.timeoutMs is unset. */
  defaultTimeoutMs?: number;
};

export class HttpFFIExecutor implements FFIExecutor {
  private readonly inFlight = new Map<DelegationId, AbortController>();

  constructor(private readonly options: HttpFFIOptions) {}

  async invoke(args: InvokeArgs): Promise<Value> {
    const url = `${this.options.baseUrl.replace(/\/$/, "")}/${qnPath(args.qualifiedName)}?delegationId=${encodeURIComponent(args.delegationId)}`;
    const controller = new AbortController();
    this.inFlight.set(args.delegationId, controller);

    const headers: Record<string, string> = {
      "content-type": "application/json",
    };
    if (this.options.authHeader !== undefined) {
      headers["authorization"] = this.options.authHeader;
    }

    const fetchPromise = fetch(url, {
      method: "POST",
      headers,
      body: JSON.stringify({ args: args.args }),
      signal: controller.signal,
    }).then(async (resp) => {
      if (!resp.ok) {
        throw new Error(
          `HttpFFI: ${qnPath(args.qualifiedName)} responded ${resp.status} ${resp.statusText}`,
        );
      }
      const body = (await resp.json()) as { value: Value };
      return body.value;
    });

    const timeoutMs = args.timeoutMs ?? this.options.defaultTimeoutMs ?? 0;
    try {
      return await withTimeout(fetchPromise, timeoutMs);
    } catch (err) {
      controller.abort();
      throw err;
    } finally {
      this.inFlight.delete(args.delegationId);
    }
  }

  async terminate(delegationId: DelegationId): Promise<void> {
    const controller = this.inFlight.get(delegationId);
    if (controller !== undefined) {
      controller.abort();
      this.inFlight.delete(delegationId);
    }
    // Best-effort terminate signal to the sidecar — fire-and-forget.
    try {
      await fetch(
        `${this.options.baseUrl.replace(/\/$/, "")}/__terminate?delegationId=${encodeURIComponent(delegationId)}`,
        { method: "POST" },
      );
    } catch {
      /* ignore */
    }
  }
}

function qnPath(qn: QualifiedName): string {
  if (qn.module_ === "") return encodeURIComponent(qn.name);
  return `${encodeURIComponent(qn.module_)}/${encodeURIComponent(qn.name)}`;
}
