// McpReactor: the `mcp` reactor — the built-in MCP client as a call reactor (see `ExternalCallReactor`
// for the shared callee-call lifecycle). Two call shapes reach it, told apart ONCE at the `openPayload`
// boundary (the compiled `prelude.mcp.tools` external arrives as its qualified name on the wire; every
// other key is a minted tool's server-declared name):
//   - `listTools` (the `prelude.mcp.tools` external): list the server's tools and MINT one agent value
//     per tool — a `$tool` carrying the server-declared signature and, as its context, the server
//     DESCRIPTOR (`{url, auth}`; the auth sum — explicit headers or a named OAuth credential — rides
//     inside it and is dispatched at the TRANSPORT boundary, never here). The minting is the payload's
//     own `shapeResult`, built here from the call's ORIGINAL argument values — so a header value's
//     privacy markers survive into the minted tools (the wire to the transport reveals; the minted
//     values must not; an oauth credential NAME is not secret).
//   - `callTool` (a minted tool's call, an `external` target carrying that descriptor as `context`): the
//     caller's argument passes to the transport verbatim, the descriptor rides out-of-band.
//
// Like http it owns its in-flight calls durably (`mcp_instances` — just the status; no argument is
// persisted) and recovery never re-runs, so a reloaded call's payload is the explicit `recovered`
// variant — nothing dispatch-shaped survives a restart by type. Connections are the TRANSPORT's business
// (a lazy, descriptor-keyed cache), not a program-visible resource: a restart empties the cache and the
// next tool call reconnects — tools survive restarts. Every anticipated failure is a typed
// `throw[mcp.server_error]`.

import { errorData } from "../engine/throw-signal.js";
import type { ReactorName } from "../event/types.js";
import type { McpToolListing, McpTransport } from "../external/mcp-transport.js";
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

/** The reserved dispatch key the compiled `prelude.mcp.tools` external arrives under — compared exactly
 *  here, at the payload boundary (tool names are server-scoped and never dotted like this, so the two
 *  cannot collide). Past `openPayload` the two call shapes are distinct payload variants, not key sniffs. */
const MCP_TOOLS_KEY = "prelude.mcp.tools";

/** What an mcp call holds, decided once from the delegate target (see the module comment): a `listTools`
 *  listing (its descriptor from the call's original marker-bearing argument, and the toolbox minting as
 *  its own `shapeResult`), a `callTool` dispatch (the tool's name, the descriptor from the minted tool's
 *  context, the caller's argument verbatim), or `recovered` — a reloaded call, which by construction can
 *  never be re-dispatched (at-most-once; nothing dispatch-shaped is persisted). */
type McpPayload =
  | {
      kind: "listTools";
      /** The `{url, auth}` descriptor with privacy markers intact — the transport gets a revealed
       *  copy, the minted tools get this one. */
      descriptor: Value;
      /** Mints the toolbox from the transport's listing (the base applies it to the settled result). */
      shapeResult: (value: Value) => Value;
    }
  | {
      kind: "callTool";
      tool: string;
      /** The minted tool's descriptor context; `null` only for a malformed target (no minted tool lacks
       *  one), which the transport rejects as the typed descriptor error. */
      descriptor: Value | null;
      argument: Value | null;
    }
  | { kind: "recovered" };

export class McpReactor extends ExternalCallReactor<McpPayload> {
  readonly name: ReactorName = "mcp";

  constructor(
    private readonly transport: McpTransport,
    pool: ResourcePool,
  ) {
    super(pool);
  }

  protected openPayload(target: ExternalTarget, argument: Value | null): McpPayload {
    if (target.key === MCP_TOOLS_KEY) {
      const descriptor = descriptorOf(argument);
      const snapshot = target.snapshot;
      return {
        kind: "listTools",
        descriptor,
        shapeResult: (value) => mintToolbox(value, descriptor, snapshot),
      };
    }
    return { kind: "callTool", tool: target.key, descriptor: target.context ?? null, argument };
  }

  protected dispatch(delegation: DelegationId, payload: McpPayload): void {
    // Lowering to plain Json for the SDK reveals a secret header value (an MCP server is an allowed
    // sink, like an http auth header), unlike the user-facing API.
    switch (payload.kind) {
      case "listTools":
        this.transport.dispatch({
          kind: "listTools",
          delegation,
          descriptor: valueToJson(payload.descriptor, "reveal"),
        });
        return;
      case "callTool":
        this.transport.dispatch({
          kind: "callTool",
          delegation,
          tool: payload.tool,
          descriptor:
            payload.descriptor === null ? null : valueToJson(payload.descriptor, "reveal"),
          argument: payload.argument === null ? null : valueToJson(payload.argument, "reveal"),
        });
        return;
      case "recovered":
        // A reloaded call only ever goes through `recover` (at-most-once), so a recovered payload
        // reaching the dispatch seam is a runtime bug — fail loudly rather than fabricate a call.
        throw new Error(`mcp: refusing to dispatch recovered call ${delegation} (at-most-once)`);
    }
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
      // Nothing dispatch-shaped is persisted (at-most-once recovery never re-runs), so the payload says so.
      payload: { kind: "recovered" },
      relays: [],
      innerCalls: [],
    }));
  }
}

/** The domain error ctor every anticipated mcp failure throws (`prelude/mcp.ktr` declares it). */
const SERVER_ERROR = "prelude.mcp.server_error";

/** The `{url, auth}` descriptor of a `tools` call, from its original (marker-bearing) argument. */
function descriptorOf(argument: Value | null): Value {
  if (argument === null || argument.kind !== "record") {
    return { kind: "record", fields: {} };
  }
  const fields: Record<string, Value> = Object.create(null);
  if (argument.fields.url !== undefined) fields.url = argument.fields.url;
  if (argument.fields.auth !== undefined) fields.auth = argument.fields.auth;
  return { kind: "record", fields };
}

/** Mint the toolbox for a settled `tools` listing: one agent value per server tool, carrying the
 *  server-declared signature and — as its context — the DESCRIPTOR from the call's original argument
 *  (`{url, auth}` with privacy markers intact; the transport's revealed copy is never minted). */
function mintToolbox(listing: Value, descriptor: Value, snapshot: SnapshotId): Value {
  const fields: Record<string, Value> = Object.create(null);
  for (const tool of listingsOf(listing)) {
    fields[tool.name] = {
      kind: "tool",
      reactor: "mcp",
      name: tool.name,
      description: tool.description,
      context: descriptor,
      snapshot,
      inputSchema: jsonToSchema(tool.inputSchema),
      ...(tool.outputSchema !== undefined ? { outputSchema: jsonToSchema(tool.outputSchema) } : {}),
    };
  }
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
