// The value layer a handler sees: the ergonomic decoding of Katari's wire JSON, and its exact inverse for
// handler results. A handler's argument is decoded ONCE at dispatch — blob-backed contents become
// `KatariFile` / `KatariString` (downloadable handles, so no user code ever touches a raw `$ref`), data
// values become `KatariData`, callable references become `KatariAgent` (callable back through the runtime),
// record keys are unescaped — and the handler's declared TypeScript type is *assumed* to match, exactly like
// the katari-side call site was checked to. No runtime validation happens here.
//
// The wire conventions — the reserved `$` discriminator keys, each variant's exact shape, and `$`-key
// escaping — are defined once in `@katari-lang/types` (`wire.ts`, imported below) and shared with the
// runtime codec, so this layer cannot drift from what the runtime emits. The port-specific notes on top:
// a bare record's own `$`-keys travel escaped (leading `$` doubled) — this layer unescapes on decode and
// re-escapes on encode, so handler code sees natural keys — and a file handle is identity only, so
// `KatariFile`'s metadata accessors download on demand instead of reading wire fields.

import {
  AGENT_KEY,
  CLOSURE_KEY,
  CONSTRUCTOR_KEY,
  escapeRecordKey,
  FILE_KEY,
  type Json,
  REDACTED_KEY,
  SEMANTIC_KIND_KEY,
  TOOL_KEY,
  unescapeRecordKey,
  VALUE_KEY,
} from "@katari-lang/types";
import type { BlobDownload, FileHandle } from "./blob.js";

/** What the decoded argument (and an inner call's decoded result) is made of. A handler's own argument type
 *  is a refinement of this — declared by the user and assumed, not validated. */
export type KatariValue =
  | null
  | boolean
  | number
  | string
  | KatariValue[]
  | KatariRecord
  | KatariFile
  | KatariString
  | KatariData<unknown>
  | KatariAgent;

/** A decoded bare record (keys already unescaped). */
export interface KatariRecord {
  [key: string]: KatariValue;
}

/** A Katari `string` parameter as it may arrive over the wire: inline (a plain JS string) or blob-backed
 *  (a `KatariString` to download). `text(…)` reads either uniformly. */
export type KatariText = string | KatariString;

/** Read a Katari text value uniformly, whether it arrived inline or blob-backed. */
export function text(value: KatariText): Promise<string> {
  return typeof value === "string" ? Promise.resolve(value) : value.text();
}

/** What the wrappers need from their dispatch context: the blob side channel (bound to the call's abort
 *  signal) and the inner agent-call channel (for `KatariAgent.call`). */
export interface ValueBinding {
  download(ref: string): Promise<BlobDownload>;
  /** Call a callable wire value (`$agent` / `$closure`, passed through verbatim) with an argument. */
  callCallable(target: Json, argument: unknown): Promise<KatariValue>;
}

/** A Katari `file` value: a slim handle (identity only) whose bytes AND metadata live behind the
 *  runtime's blob side channel — `size()` / `contentType()` are async because the handle deliberately
 *  carries nothing that could go stale. One download serves all of them (cached for the call's
 *  lifetime). Returned from a handler (directly or inside a record), it becomes a `file` value for the
 *  calling agent — receive one from the argument, or produce one with `context.file(...)`. */
export class KatariFile {
  constructor(
    private readonly fileHandle: FileHandle,
    private readonly binding: ValueBinding,
    /** A just-produced file (`context.file`) already knows its content, so its producer seeds the
     *  download cache — reading back a file this handler created costs no round trip. */
    private downloaded?: BlobDownload,
  ) {}

  /** The file's bytes, downloaded from the runtime on first use (cached for the call's lifetime). */
  async bytes(): Promise<Uint8Array> {
    return (await this.download()).bytes;
  }

  /** The file's size in bytes (downloads the content on first use — the slim handle carries none). */
  async size(): Promise<number> {
    return (await this.download()).size;
  }

  /** The file's recorded MIME type (from the runtime's blob row, served as the download's
   *  Content-Type), or `undefined` when none was recorded at upload. */
  async contentType(): Promise<string | undefined> {
    return (await this.download()).contentType;
  }

  /** The file's bytes decoded as UTF-8 text. */
  async text(): Promise<string> {
    return new TextDecoder().decode(await this.bytes());
  }

  /** The raw wire handle (for the encoder, and for advanced interop). */
  handle(): FileHandle {
    return this.fileHandle;
  }

  private async download(): Promise<BlobDownload> {
    this.downloaded ??= await this.binding.download(this.fileHandle.$ref);
    return this.downloaded;
  }
}

/** A blob-backed Katari `string` (a large string promoted out of line): downloadable like a file, but its
 *  semantic type on the katari side is `string`. An inline string arrives as a plain JS string instead —
 *  type a string parameter as `KatariText` and read it with `text(…)`. */
export class KatariString {
  constructor(
    private readonly fileHandle: FileHandle,
    private readonly binding: ValueBinding,
    private cached?: string,
  ) {}

  /** The string's content, downloaded from the runtime on first use (cached for the call's lifetime). */
  async text(): Promise<string> {
    this.cached ??= new TextDecoder().decode(
      (await this.binding.download(this.fileHandle.$ref)).bytes,
    );
    return this.cached;
  }

  /** The raw wire handle (for the encoder, and for advanced interop). */
  handle(): FileHandle {
    return this.fileHandle;
  }
}

/** A Katari `data` value: its constructor name and its (decoded) fields. Construct one to return a data
 *  value from a handler: `return new KatariData("Ok", { value: 1 })`. */
export class KatariData<Value = unknown> {
  constructor(
    readonly name: string,
    readonly value: Value,
  ) {}
}

/** A callable Katari value (a top-level agent reference, a closure, or an `as_tool` tool) received
 *  across the FFI boundary. `call` runs it back inside the runtime — the generic dynamic dispatch,
 *  carrying the reference's own snapshot and generics (a tool validates the argument against its
 *  attached schema at the runtime's delegation boundary) — and resolves with the decoded result. */
export class KatariAgent {
  constructor(
    private readonly raw: Json,
    private readonly binding: ValueBinding,
  ) {}

  /** The callable's name: an agent reference's qualified name, or a tool's attached name
   *  (`undefined` for a closure). */
  get name(): string | undefined {
    const wire = this.wire();
    const name = wire === undefined ? undefined : (wire[AGENT_KEY] ?? wire[TOOL_KEY]);
    return typeof name === "string" ? name : undefined;
  }

  /** Call the referenced agent / closure with `argument` and decode its result. */
  call<Result = KatariValue>(argument?: unknown): Promise<Result> {
    // The declared Result is assumed (the same trust as a handler's argument type), so the one cast here is
    // the typed-boundary assertion, not a runtime conversion.
    return this.binding.callCallable(this.raw, argument ?? null) as Promise<Result>;
  }

  /** The raw wire reference (for the encoder, and for advanced interop). */
  handle(): Json {
    return this.raw;
  }

  private wire(): { [key: string]: Json } | undefined {
    return typeof this.raw === "object" && this.raw !== null && !Array.isArray(this.raw)
      ? this.raw
      : undefined;
  }
}

// ─── decode: wire Json → the handler's value model ────────────────────────────────────────────────

/** Decode one wire JSON value into the handler value model, binding the downloadable / callable wrappers to
 *  the dispatch's context. Total over well-formed runtime output. */
export function decodeWireValue(json: Json, binding: ValueBinding): KatariValue {
  if (json === null || typeof json !== "object") return json;
  if (Array.isArray(json)) return json.map((element) => decodeWireValue(element, binding));
  if (Object.hasOwn(json, CONSTRUCTOR_KEY)) {
    const name = json[CONSTRUCTOR_KEY];
    const fields = json[VALUE_KEY];
    return new KatariData(
      typeof name === "string" ? name : String(name),
      typeof fields === "object" && fields !== null && !Array.isArray(fields)
        ? decodeRecord(fields, binding)
        : {},
    );
  }
  if (Object.hasOwn(json, FILE_KEY)) {
    const handle = json as FileHandle;
    return json[SEMANTIC_KIND_KEY] === "string"
      ? new KatariString(handle, binding)
      : new KatariFile(handle, binding);
  }
  if (
    Object.hasOwn(json, AGENT_KEY) ||
    Object.hasOwn(json, CLOSURE_KEY) ||
    Object.hasOwn(json, TOOL_KEY)
  ) {
    return new KatariAgent(json, binding);
  }
  if (Object.hasOwn(json, REDACTED_KEY)) {
    // The FFI boundary reveals secrets, so a redaction marker cannot appear in well-formed input; reaching
    // one means a redacted document was fed back around — fail loudly rather than hand out a husk.
    throw new Error("katari: a redacted value cannot be decoded (its content was withheld)");
  }
  return decodeRecord(json, binding);
}

function decodeRecord(json: { [key: string]: Json }, binding: ValueBinding): KatariRecord {
  const record: KatariRecord = {};
  for (const [key, child] of Object.entries(json)) {
    record[unescapeRecordKey(key)] = decodeWireValue(child, binding);
  }
  return record;
}

// ─── encode: a handler's return value → wire Json ─────────────────────────────────────────────────

/** Encode a handler's return value (or an inner call's argument) to wire JSON: wrappers collapse to their
 *  handles, `KatariData` to its tagged form, record keys are escaped, `undefined` becomes `null` (a field
 *  set to `undefined` is dropped, like `JSON.stringify`). Throws a clear error on a value that has no wire
 *  form (a function, a bigint, a cycle, raw bytes — upload those with `context.file`). */
export function encodeWireValue(value: unknown): Json {
  return encode(value, new Set());
}

function encode(value: unknown, seen: Set<object>): Json {
  if (value === null || value === undefined) return null;
  switch (typeof value) {
    case "boolean":
    case "string":
      return value;
    case "number":
      if (!Number.isFinite(value)) {
        throw new Error("katari: a non-finite number (NaN / Infinity) has no wire representation");
      }
      return value;
    case "object":
      break;
    default:
      throw new Error(`katari: a ${typeof value} value has no wire representation`);
  }
  if (value instanceof KatariFile || value instanceof KatariString) {
    // The handle is spread into a fresh object so the encoder's output is always plain data.
    return { ...value.handle() };
  }
  if (value instanceof KatariAgent) return value.handle();
  if (value instanceof Uint8Array) {
    throw new Error(
      "katari: raw bytes cannot be returned directly — upload them with context.file(bytes) and return the file",
    );
  }
  if (seen.has(value)) throw new Error("katari: a cyclic value has no wire representation");
  seen.add(value);
  try {
    if (value instanceof KatariData) {
      const fields = encode(value.value, seen);
      if (fields === null || typeof fields !== "object" || Array.isArray(fields)) {
        throw new Error(`katari: the fields of data value "${value.name}" must be a record`);
      }
      return { [CONSTRUCTOR_KEY]: value.name, [VALUE_KEY]: fields };
    }
    if (Array.isArray(value)) return value.map((element) => encode(element, seen));
    const out: { [key: string]: Json } = {};
    for (const [key, child] of Object.entries(value)) {
      if (child === undefined) continue; // dropped, like JSON.stringify
      out[escapeRecordKey(key)] = encode(child, seen);
    }
    return out;
  } finally {
    seen.delete(value);
  }
}
