// The shared vocabulary of the per-reactor extension codecs. Each call reactor owns a pure
// `encode…Extension` / `decode…Extension` pair mapping its warm call state to/from the ONE
// `external_call_instances.extension` Json document; these helpers keep the two directions honest about
// the boundary:
//
//   - Routing-shaped fields (tags, tokens, ids, the inner-delegation bridges) decode CHECKED — a wrong
//     shape throws a drift error, surfaced loudly like a corrupt envelope, because outside readers (the
//     run-tree repository) render these fields and must never render garbage.
//   - Engine-value subtrees (a callback, a descriptor, a time operation) decode TRUSTED — the document
//     was written only by the paired encode, so the embedded value is trusted exactly as the old
//     per-kind jsonb columns' `$type` was; re-validating a recursive `Value` here would duplicate the
//     codec that owns it.

import type { Json } from "@katari-lang/types";
import type { DelegationId, EscalationId } from "../ids.js";
import type { EscalationRelayRow, InnerCallRow } from "./external-call-reactor.js";

/** Widen an at-rest-shaped payload (an engine `Value`, a `TimeOperation`, an `McpDispatchCall`) to the
 *  extension document's `Json`. The runtime value model IS plain JSON by construction (see
 *  `value/types.ts`); only nominal typing (branded ids, optional fields) keeps TypeScript from proving
 *  it, so this is the one deliberate widening the encode direction uses. */
export function asJson(payload: object | null): Json {
  return payload as unknown as Json;
}

/** Narrow an extension document to its object form. Every codec's decode starts here; a non-object
 *  document is drift (the paired encode always writes an object). */
export function documentOf(extension: Json): Record<string, Json> {
  if (typeof extension !== "object" || extension === null || Array.isArray(extension)) {
    throw new Error("the extension document is not an object (corrupt row)");
  }
  return extension;
}

/** Read a checked string field (a tag / token / id the codec or an outside reader dispatches on). */
export function stringFieldOf(document: Record<string, Json>, field: string): string {
  const value = document[field];
  if (typeof value !== "string") {
    throw new Error(`the extension document has no string "${field}" (corrupt row)`);
  }
  return value;
}

/** Read a trusted engine-value field back at its warm type. `null` in the document round-trips a
 *  nullable warm field (the paired encode writes it explicitly), so absence — never written — is drift. */
export function warmFieldOf<Warm>(document: Record<string, Json>, field: string): Warm {
  if (!(field in document)) {
    throw new Error(`the extension document has no "${field}" (corrupt row)`);
  }
  return document[field] as unknown as Warm;
}

/** Encode the escalation-relay bridge rows (plain routing ids — never sealed). */
export function encodeRelays(relays: EscalationRelayRow[]): Json {
  return relays.map((relay) => ({
    escalation: relay.escalation,
    child: relay.child,
    childEscalation: relay.childEscalation,
  }));
}

/** Decode (and re-brand) the escalation-relay bridge rows. */
export function relaysOf(document: Record<string, Json>): EscalationRelayRow[] {
  return bridgeEntriesOf(document, "relays").map((entry) => ({
    escalation: stringFieldOf(entry, "escalation") as EscalationId,
    child: stringFieldOf(entry, "child") as DelegationId,
    childEscalation: stringFieldOf(entry, "childEscalation") as EscalationId,
  }));
}

/** Encode the inner-call bridge rows (delegation ↔ the transport's own call token). */
export function encodeInnerCalls(innerCalls: InnerCallRow[]): Json {
  return innerCalls.map((inner) => ({ delegation: inner.delegation, call: inner.call }));
}

/** Decode (and re-brand) the inner-call bridge rows. */
export function innerCallsOf(document: Record<string, Json>): InnerCallRow[] {
  return bridgeEntriesOf(document, "innerCalls").map((entry) => ({
    delegation: stringFieldOf(entry, "delegation") as DelegationId,
    call: stringFieldOf(entry, "call"),
  }));
}

/** A bridge field's entries as objects — both bridges are arrays of small routing records. */
function bridgeEntriesOf(
  document: Record<string, Json>,
  field: string,
): Array<Record<string, Json>> {
  const value = document[field];
  if (!Array.isArray(value)) {
    throw new Error(`the extension document has no array "${field}" (corrupt row)`);
  }
  return value.map((entry) => documentOf(entry));
}
