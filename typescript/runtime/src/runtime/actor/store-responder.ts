// The store responder: how the runtime MACHINE-ANSWERS an unhandled `prelude.store.*` request. The store's
// four operations are `request`s (see `prelude/store.ktr`): a program performs one, an in-scope handler may
// catch it (like `prelude.throw`), and — unhandled — it escalates to the run root, where the api reactor
// answers it against the project's durable rows instead of surfacing an operator question. This module owns
// the durable-rows port and the pure answer construction; the api reactor owns only the escalation wiring
// (recognise the request, reply on the same downward path an operator answer takes).
//
// The answer is an engine `Value` delivered straight down the `escalateAck` — never a wire Json round-trip —
// so a stored `string of private` keeps its taint (a `reveal` round-trip strips it, a `redact` one erases
// the content) and a stored `file` keeps its ref.

import { createAgentName, type QualifiedName } from "@katari-lang/types";
import type { ProjectId } from "../ids.js";
import type { Value } from "../value/types.js";

/** The project-scoped durable KV rows the store responder reads and writes — the DB-backed `store_entries`
 *  port (the real one seals / unseals a `private` node at this seam, so a stored secret rests like a secret
 *  env entry). A consumer-defined port: the actor supplies the DB implementation, tests stub it. Row writes
 *  are last-write-wins, so a re-run during recovery converges; there is no reference probe / reclaim — a
 *  stored `file`'s blob joins the file library and is removed only there. */
export interface StoreRows {
  /** The stored value at the full key (unsealed — private marks intact), or `undefined`. */
  read(projectId: ProjectId, key: string): Promise<Value | undefined>;
  /** Create or replace the entry (last write wins). */
  upsert(projectId: ProjectId, key: string, value: Value): Promise<void>;
  /** Delete the entry; a missing key is a no-op. */
  remove(projectId: ProjectId, key: string): Promise<void>;
  /** Every full key strictly under `prefix` (all keys when `prefix` is ""), sorted. */
  listKeys(projectId: ProjectId, prefix: string): Promise<string[]>;
}

/** The compiled request names the store operations escalate under (`prelude/store.ktr`'s `request`s). */
const GET_REQUEST = "prelude.store.get";
const SET_REQUEST = "prelude.store.set";
const DELETE_REQUEST = "prelude.store.delete";
const LIST_REQUEST = "prelude.store.list";

/** The `prelude.store` result constructors (`prelude/store.ktr` declares them). */
const FOUND_CTOR = createAgentName("prelude.store.found");
const ABSENT_CTOR = createAgentName("prelude.store.absent");
const LEAF_CTOR = createAgentName("prelude.store.leaf");
const BRANCH_CTOR = createAgentName("prelude.store.branch");

const NULL_VALUE: Value = { kind: "null" };

/** Whether a request name is one the store responder machine-answers — the escalation the api reactor
 *  intercepts instead of opening an operator question. Named here so the api reactor and the user-facing
 *  filter (`escalation-filter`) read the same set. */
export function isStoreRequest(request: string): boolean {
  return (
    request === GET_REQUEST ||
    request === SET_REQUEST ||
    request === DELETE_REQUEST ||
    request === LIST_REQUEST
  );
}

/** Compute the answer to one store request against the durable rows: `get` reads (`found` / `absent`),
 *  `set` writes and answers `null`, `delete` removes and answers `null`, `list` is the FS-shaped listing.
 *  Async (the rows I/O is a DB round-trip); the api reactor replies with the returned Value on a fresh
 *  serial turn. An unknown request is engine/compiler drift (the api reactor gates on `isStoreRequest`
 *  first), surfaced as a defect. */
export async function answerStoreRequest(
  rows: StoreRows,
  projectId: ProjectId,
  request: QualifiedName,
  argument: Value | null,
): Promise<Value> {
  switch (request) {
    case GET_REQUEST: {
      const value = await rows.read(projectId, fullKeyOf(argument));
      return value === undefined ? absentValue(fullKeyOf(argument)) : foundValue(value);
    }
    case SET_REQUEST: {
      await rows.upsert(projectId, fullKeyOf(argument), fieldOf(argument, "value"));
      return NULL_VALUE;
    }
    case DELETE_REQUEST: {
      await rows.remove(projectId, fullKeyOf(argument));
      return NULL_VALUE;
    }
    case LIST_REQUEST: {
      const prefix = prefixOf(fieldOf(argument, "target"));
      return listing(prefix, await rows.listKeys(projectId, prefix));
    }
    default:
      throw new Error(`store: unknown request "${request}" (compiler/runtime drift — a bug)`);
  }
}

/** A `found` result carrying the stored value (an engine Value, private / refs intact). */
function foundValue(value: Value): Value {
  return { kind: "record", ctor: FOUND_CTOR, fields: { value } };
}

/** An `absent` result carrying the full key that had no entry. */
function absentValue(key: string): Value {
  return { kind: "record", ctor: ABSENT_CTOR, fields: { key: stringValue(key) } };
}

/** The FS-shaped listing of what sits DIRECTLY under `prefix`: a `leaf` per value-holding key and a
 *  deduplicated `branch` per segment with entries below it, sorted (a name that is both yields both), and
 *  "/"-bounded so the prefix `"memo"` never matches the key `"memos/a"`. */
function listing(prefix: string, keys: string[]): Value {
  const leaves = new Set<string>();
  const branches = new Set<string>();
  for (const key of keys) {
    const relative = prefix === "" ? key : keyBelowPrefix(key, prefix);
    if (relative === undefined || relative === "") continue;
    const separator = relative.indexOf("/");
    if (separator === -1) leaves.add(relative);
    else branches.add(relative.slice(0, separator));
  }
  const names = [...new Set([...leaves, ...branches])].sort();
  const elements: Value[] = [];
  for (const name of names) {
    if (leaves.has(name)) {
      elements.push({ kind: "record", ctor: LEAF_CTOR, fields: { key: stringValue(name) } });
    }
    if (branches.has(name)) {
      elements.push({ kind: "record", ctor: BRANCH_CTOR, fields: { name: stringValue(name) } });
    }
  }
  return { kind: "array", elements };
}

/** The key below `prefix` (after its "/"), or `undefined` when the key is not under it — the "/" boundary
 *  guard, so the prefix `"memo"` never matches the key `"memos/a"`. */
function keyBelowPrefix(key: string, prefix: string): string | undefined {
  return key.startsWith(`${prefix}/`) ? key.slice(prefix.length + 1) : undefined;
}

/** The full key of a store operation: the target view's prefix joined to the call's `key`. */
function fullKeyOf(argument: Value | null): string {
  const prefix = prefixOf(fieldOf(argument, "target"));
  const key = stringFieldOf(argument, "key");
  return prefix === "" ? key : `${prefix}/${key}`;
}

/** The `prefix` field of a `store` view value. */
function prefixOf(target: Value): string {
  if (target.kind !== "record") {
    throw new Error(
      `store: expected a store record, got ${target.kind} (compiler/runtime drift — a bug)`,
    );
  }
  const prefix = target.fields.prefix;
  if (prefix === undefined || prefix.kind !== "string") {
    throw new Error(
      "store: the store value is missing a string `prefix` (compiler/runtime drift — a bug)",
    );
  }
  return prefix.value;
}

/** A required field off a store request's record argument, any kind. A missing field is drift (the stdlib
 *  signatures type these), surfaced as a defect rather than resolved to junk. */
function fieldOf(argument: Value | null, name: string): Value {
  if (argument === null || argument.kind !== "record") {
    throw new Error("store: expected a record argument (compiler/runtime drift — a bug)");
  }
  const field = argument.fields[name];
  if (field === undefined) {
    throw new Error(`store: the argument "${name}" is missing (compiler/runtime drift — a bug)`);
  }
  return field;
}

/** A required string field off a store request's record argument. */
function stringFieldOf(argument: Value | null, name: string): string {
  const field = fieldOf(argument, name);
  if (field.kind !== "string") {
    throw new Error(
      `store: the argument "${name}" must be a string (compiler/runtime drift — a bug)`,
    );
  }
  return field.value;
}

function stringValue(value: string): Value {
  return { kind: "string", value };
}
