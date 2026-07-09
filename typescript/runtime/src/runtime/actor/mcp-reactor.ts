// McpReactor: the `mcp` reactor — the built-in MCP client as a call reactor (see `ExternalCallReactor`
// for the shared callee-call lifecycle). Two call shapes reach it:
//   - `prelude.mcp.tools` (a compiled external): list the server's tools and MINT one agent value per
//     tool — a `$tool` carrying the server-declared signature and, as its context, the server
//     DESCRIPTOR (`{url, headers}`). The minting happens HERE, reactor-side, from the transport's
//     listing plus the call's ORIGINAL argument values — so the headers' privacy markers survive into
//     the minted tools (the wire to the transport reveals; the minted values must not).
//   - a minted tool's call (an `external` target carrying that descriptor as `context`): the caller's
//     argument passes to the transport verbatim, the descriptor rides out-of-band.
//
// Like http it owns its in-flight calls durably (`mcp_instances` — just the status; no argument is
// persisted) and recovery never re-runs. Connections are the TRANSPORT's business (a lazy,
// descriptor-keyed cache), not a program-visible resource: a restart empties the cache and the next
// tool call reconnects — tools survive restarts. Every anticipated failure is a typed
// `throw[mcp.server_error]`.

import { errorData } from "../engine/throw-signal.js";
import type { ReactorName } from "../event/types.js";
import {
  MCP_TOOLS_KEY,
  type McpToolListing,
  type McpTransport,
} from "../external/mcp-transport.js";
import type { DelegationId, InstanceId, SnapshotId } from "../ids.js";
import { valueToJson } from "../value/codec.js";
import { jsonToSchema } from "../value/schema-json.js";
import type { Value } from "../value/types.js";
import {
  type CallRow,
  ExternalCallReactor,
  type ExternalTarget,
  type LoadedCall,
} from "./external-call-reactor.js";
import type { Loader, PersistenceTx } from "./persistence.js";
import type { ResourcePool } from "./resource-pool.js";

/** The transport data an mcp call holds: the dispatch key, the argument, a minted tool's descriptor
 *  context, and the calling snapshot (stamped on minted tools). Kept only to dispatch and to mint;
 *  recovery never re-runs (at-most-once), so none of it is persisted. */
interface McpPayload {
  key: string;
  argument: Value | null;
  context: Value | null;
  snapshot: SnapshotId;
}

export class McpReactor extends ExternalCallReactor<McpPayload> {
  readonly name: ReactorName = "mcp";

  constructor(
    private readonly transport: McpTransport,
    pool: ResourcePool,
  ) {
    super(pool);
  }

  protected openPayload(target: ExternalTarget, argument: Value | null): McpPayload {
    return {
      key: target.key,
      argument,
      context: target.context ?? null,
      snapshot: target.snapshot,
    };
  }

  protected dispatch(delegation: DelegationId, payload: McpPayload): void {
    this.transport.dispatch({
      delegation,
      key: payload.key,
      // Lower the engine's Values to plain Json for the SDK; a secret header value is revealed here
      // (an MCP server is an allowed sink, like an http auth header), unlike the user-facing API.
      argument: payload.argument === null ? null : valueToJson(payload.argument, "reveal"),
      context: payload.context === null ? null : valueToJson(payload.context, "reveal"),
    });
  }

  protected recover(delegation: DelegationId): void {
    this.transport.recover(delegation);
  }

  /** An mcp infrastructure error is still program-anticipatable (the server is an external party):
   *  escalate `throw[mcp.server_error]` (not a panic), so a caller's handler controls retry — and a
   *  retried call reconnects through the transport's descriptor cache. */
  protected override escalateError(
    delegation: DelegationId,
    message: string,
    caller: ReactorName,
    run: InstanceId,
  ): void {
    this.raiseThrow(delegation, errorData(SERVER_ERROR, message), caller, run);
  }

  protected abort(delegation: DelegationId): void {
    this.transport.abort(delegation);
  }

  /** Mint the toolbox for a settled `tools` listing: one agent value per server tool, carrying the
   *  server-declared signature and — as its context — the DESCRIPTOR from the call's original argument
   *  (`{url, headers}` with privacy markers intact; the transport's revealed copy is never minted). */
  protected override transformResult(delegation: DelegationId, value: Value): Value {
    const payload = this.payloadOf(delegation);
    if (payload === undefined || payload.key !== MCP_TOOLS_KEY) return value;
    const context = descriptorOf(payload.argument);
    const fields: Record<string, Value> = Object.create(null);
    for (const listing of listingsOf(value)) {
      fields[listing.name] = {
        kind: "tool",
        reactor: "mcp",
        name: listing.name,
        description: listing.description,
        context,
        snapshot: payload.snapshot,
        inputSchema: jsonToSchema(listing.inputSchema),
        ...(listing.outputSchema !== undefined
          ? { outputSchema: jsonToSchema(listing.outputSchema) }
          : {}),
      };
    }
    return { kind: "record", fields };
  }

  protected async persistCallRow(tx: PersistenceTx, row: CallRow<McpPayload>): Promise<void> {
    // The inner-delegation bridges are not persisted: an mcp transport surfaces no inner agent calls,
    // so both are empty by construction (mirroring http).
    await tx.mcp.putMcpInstance({
      instanceId: row.instance,
      status: row.status,
    });
  }

  protected async loadCallRows(loader: Loader): Promise<Array<LoadedCall<McpPayload>>> {
    return (await loader.mcp.instances()).map((row) => ({
      delegation: row.delegation,
      instance: row.instance,
      caller: row.caller,
      run: row.run,
      status: row.status,
      // Nothing dispatch-shaped is persisted (at-most-once recovery never re-runs).
      payload: { key: "", argument: null, context: null, snapshot: "" as SnapshotId },
      relays: [],
      innerCalls: [],
    }));
  }
}

/** The domain error ctor every anticipated mcp failure throws (`prelude/mcp.ktr` declares it). */
const SERVER_ERROR = "prelude.mcp.server_error";

/** The `{url, headers}` descriptor of a `tools` call, from its original (marker-bearing) argument. */
function descriptorOf(argument: Value | null): Value {
  if (argument === null || argument.kind !== "record") {
    return { kind: "record", fields: {} };
  }
  const fields: Record<string, Value> = Object.create(null);
  if (argument.fields.url !== undefined) fields.url = argument.fields.url;
  if (argument.fields.headers !== undefined) fields.headers = argument.fields.headers;
  return { kind: "record", fields };
}

/** The transport's `{ tools: [...] }` listing, decoded back out of the completion value. A malformed
 *  shape is transport drift, not a program error — fail loudly (the substrate surfaces it). */
function listingsOf(value: Value): McpToolListing[] {
  if (value.kind !== "record" || value.fields.tools?.kind !== "array") {
    throw new Error("mcp: the tools completion did not carry a { tools: [...] } listing");
  }
  const listings: McpToolListing[] = [];
  for (const entry of value.fields.tools.elements) {
    if (entry.kind !== "record") continue;
    const name = entry.fields.name;
    const description = entry.fields.description;
    if (name?.kind !== "string") continue;
    listings.push({
      name: name.value,
      description: description?.kind === "string" ? description.value : "",
      inputSchema:
        entry.fields.inputSchema === undefined
          ? {}
          : valueToJson(entry.fields.inputSchema, "reveal"),
      ...(entry.fields.outputSchema !== undefined
        ? { outputSchema: valueToJson(entry.fields.outputSchema, "reveal") }
        : {}),
    });
  }
  return listings;
}
