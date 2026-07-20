// The durable shape of an mcp transport call's DISPATCH — a leaf module (it imports only value / type
// leaves), shared by the `McpReactor` and its extension codec (the `parked` variant of `McpExtension`
// embeds it), exactly like `time-schedule.ts`.
//
// A transport call normally persists NO dispatch data (recovery is at-most-once: an interrupted in-flight
// call is refused, never re-run, because the server may have executed it). A PARKED call is the one
// exception with a proof: its attempt was REJECTED with an authorization failure (an HTTP 401 rejection
// guarantees the server never executed it), so re-running after the authorize escalation is answered is
// safe — across restarts too. This union is exactly the state that re-run needs, written while the call
// is parked and reverted in the same commit that retires the answered escalation, so a crash mid-retry
// reloads a plain in-flight call and the at-most-once refusal applies again.

import type { JSONSchema } from "@katari-lang/types";
import type { Value } from "./value/types.js";

/** One dispatch-shaped mcp transport call — the `callTool | directCall` half of the reactor's transport
 *  sum (its third variant, `recovered`, is by definition NOT dispatch-shaped and never persists). Values
 *  ride whole (privacy markers intact — a persisted row seals like any stored value). */
export type McpDispatchCall =
  | {
      kind: "callTool";
      /** The minted tool's server-declared name (the reactor-scoped dispatch key). */
      tool: string;
      /** The minted tool's server descriptor; `null` only for a malformed target (no minted tool lacks
       *  one), which the transport rejects as the typed descriptor error. */
      descriptor: Value | null;
      /** The provide scope this tool was minted under — re-checked live before every dispatch attempt,
       *  so a tool outliving its `provide` is rejected as a typed `server_error` (the requires-a-live-provide
       *  boundary; scope identity is a compiler marker, never seen here). `null` for a tool with no scope
       *  in its context (a legacy / hand-built target), which skips the check. */
      scope: string | null;
      argument: Value | null;
    }
  | {
      kind: "directCall";
      /** The `{url, auth}` descriptor assembled from the call's own argument (privacy markers intact —
       *  the transport gets a revealed copy at dispatch, like the other transport shapes). */
      descriptor: Value;
      /** The `tool` name value (a string leaf, possibly blob-backed) — read at dispatch, where the
       *  string reader is allowed to touch the store. */
      tool: Value | null;
      /** The `arguments` json tree, lowered to the literal Json document at dispatch. */
      argumentsTree: Value | null;
      /** The result generic `T`'s schema, from the external's own instantiation — what the reply is
       *  decoded against (see the reactor's `decodeDirectReply`). Absent decodes to the raw `json`
       *  tree. */
      outputSchema: JSONSchema | undefined;
    };
