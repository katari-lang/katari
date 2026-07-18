// The http request-body materialiser: the ONE place a `file` value's bytes enter an http request, and it
// runs at the SEND boundary (inside the transport's `perform`), never on the value plane. `http.fetch`'s
// `body` is a four-way sum (`stdlib/prelude/http.ktr`): `text` (a string, sent verbatim), `binary` (one
// file's raw bytes), `multipart` (RFC 7578 form-data), and `json` (a value tree whose `file` leaves become
// base64 strings — the REST convention). A file rides the whole way here as its slim `$ref` HANDLE (the
// value codec's wire form); only at this point does the transport read the bytes from the blob store and
// splice them in. So nothing durable — the external-call envelope, the DB, the trace — ever carries the
// bytes, only the handle (docs/2026-07-18-http-file-body.md).
//
// The `text` variant is HTTP-shape-neutral, so a bare string body (what a hand-built request, or a caller
// predating the sum, supplies) is treated as a `text` body too — the degenerate case of the same sum.

import { randomBytes } from "node:crypto";
import {
  CONSTRUCTOR_KEY,
  FILE_KEY,
  type Json,
  SEMANTIC_KIND_KEY,
  unescapeRecordKey,
  VALUE_KEY,
} from "@katari-lang/types";
import type { BlobId } from "../ids.js";

/** Reads a blob's bytes plus its recorded content type (the `blobs` row / warm catalog datum a slim `$ref`
 *  deliberately does not carry), for materialising a `file` into a request body. The content type is `""`
 *  when none was recorded — the caller then falls back to a generic type. */
export type HttpBlobResolver = (
  blobId: BlobId,
) => Promise<{ bytes: Uint8Array; contentType: string }>;

/** A materialised body ready for `fetch`: the payload (bytes / string / none) and the Content-Type the body
 *  IMPLIES. `authoritative` distinguishes multipart — whose Content-Type carries the generated boundary and
 *  so must override any caller header — from the defaults (`binary` / `json`), which apply only when the
 *  caller set no Content-Type of its own. */
export interface MaterializedBody {
  body: Uint8Array | string | undefined;
  contentType?: { value: string; authoritative: boolean };
}

// The body sum's constructor names (their `valueToJson` wire tags — `stdlib/prelude/http.ktr`).
const BODY_TEXT = "prelude.http.text";
const BODY_BINARY = "prelude.http.binary";
const BODY_MULTIPART = "prelude.http.multipart";
const BODY_JSON = "prelude.http.json";
// The multipart part sum's constructor names.
const PART_TEXT = "prelude.http.multipart_text";
const PART_FILE = "prelude.http.multipart_file";

/** The Content-Type a binary body with no recorded file type falls back to (RFC 2046's catch-all). */
const OCTET_STREAM = "application/octet-stream";

/** Materialise `http.fetch`'s `body` argument (its `valueToJson` wire form) into the bytes to send. A file
 *  is read from the blob store HERE, at send time, through `resolve`; a body with no file needs no resolver.
 *  `undefined` / `null` means no body (a GET, or an omitted body). */
export async function materializeBody(
  body: Json | undefined,
  resolve: HttpBlobResolver | null,
): Promise<MaterializedBody> {
  if (body === undefined || body === null) return { body: undefined };
  // A bare string is a `text` body — the degenerate case of the sum (a hand-built request's plain body).
  if (typeof body === "string") return { body };
  const data = dataValueOf(body);
  if (data === null) {
    throw new Error("http.fetch: body is not a text / binary / multipart / json request body");
  }
  switch (data.ctor) {
    case BODY_TEXT:
      return { body: await readWireString(data.fields.content, resolve) };
    case BODY_BINARY:
      return materializeBinary(data.fields.content, resolve);
    case BODY_MULTIPART:
      return materializeMultipart(data.fields.parts, resolve);
    case BODY_JSON:
      return {
        body: JSON.stringify(await materializeJsonTree(data.fields.value, resolve)),
        contentType: { value: "application/json", authoritative: false },
      };
    default:
      throw new Error(`http.fetch: unknown request body kind "${data.ctor}"`);
  }
}

/** The raw-bytes `binary` body: one file, sent as-is, its recorded content type the default Content-Type. */
async function materializeBinary(
  content: Json | undefined,
  resolve: HttpBlobResolver | null,
): Promise<MaterializedBody> {
  const handle = fileHandleOf(content);
  if (handle === null) throw new Error("http.fetch: a binary body's content must be a file");
  const blob = await requireResolver(resolve)(handle.blobId);
  return {
    body: blob.bytes,
    contentType: {
      value: blob.contentType === "" ? OCTET_STREAM : blob.contentType,
      authoritative: false,
    },
  };
}

/** The `multipart/form-data` body (RFC 7578): each part a form field, text or file, delimited by a
 *  generated boundary. The boundary rides the Content-Type, which therefore overrides any caller header. */
async function materializeMultipart(
  parts: Json | undefined,
  resolve: HttpBlobResolver | null,
): Promise<MaterializedBody> {
  if (!Array.isArray(parts))
    throw new Error("http.fetch: a multipart body's parts must be an array");
  const boundary = `----katari${randomBytes(16).toString("hex")}`;
  const chunks: Uint8Array[] = [];
  const encoder = new TextEncoder();
  for (const part of parts) {
    const data = dataValueOf(part);
    if (data === null) throw new Error("http.fetch: a multipart part must be a text / file part");
    if (data.ctor === PART_TEXT) {
      const name = fieldName(data.fields.name, "a multipart part");
      const content = await readWireString(data.fields.content, resolve);
      chunks.push(
        encoder.encode(
          `--${boundary}\r\nContent-Disposition: form-data; name="${headerQuote(name)}"\r\n\r\n${content}\r\n`,
        ),
      );
    } else if (data.ctor === PART_FILE) {
      const name = fieldName(data.fields.name, "a multipart file part");
      const filename = fieldName(data.fields.filename, "a multipart file part");
      const handle = fileHandleOf(data.fields.content);
      if (handle === null)
        throw new Error("http.fetch: a multipart file part's content must be a file");
      const blob = await requireResolver(resolve)(handle.blobId);
      const contentType = blob.contentType === "" ? OCTET_STREAM : blob.contentType;
      chunks.push(
        encoder.encode(
          `--${boundary}\r\nContent-Disposition: form-data; name="${headerQuote(name)}"; filename="${headerQuote(filename)}"\r\nContent-Type: ${contentType}\r\n\r\n`,
        ),
      );
      chunks.push(blob.bytes);
      chunks.push(encoder.encode("\r\n"));
    } else {
      throw new Error(`http.fetch: unknown multipart part kind "${data.ctor}"`);
    }
  }
  chunks.push(encoder.encode(`--${boundary}--\r\n`));
  return {
    body: concatBytes(chunks),
    contentType: { value: `multipart/form-data; boundary=${boundary}`, authoritative: true },
  };
}

/** Walk the `json` body's value tree (its `valueToJson` wire form), replacing every `file` leaf with the
 *  base64 of its bytes — the ONE place the tree's shape changes. A blob-backed STRING leaf materialises to
 *  its text (a JSON document's string is text); every other node passes through unchanged, so the tree the
 *  caller built is the tree that goes on the wire, files aside.
 *
 *  Object keys are UN-escaped back to what the program wrote (`unescapeRecordKey`): the value codec doubles
 *  a record key's leading `$` on the way out (`valueToJson`), so a program that put a literal `$ref` / `$defs`
 *  / `$schema` key in the tree — a JSON-Schema keyword an AI provider's tool schema carries — arrives here as
 *  `$$ref` / …, and must go on the wire as the ORIGINAL `$ref`. A single-`$` object (a real `$ref` file
 *  handle) is caught by `fileHandleOf` above before this branch, so the two never collide. */
export async function materializeJsonTree(
  node: Json | undefined,
  resolve: HttpBlobResolver | null,
): Promise<Json> {
  if (node === undefined || node === null) return null;
  if (Array.isArray(node)) {
    const out: Json[] = [];
    for (const element of node) out.push(await materializeJsonTree(element, resolve));
    return out;
  }
  if (typeof node === "object") {
    const handle = fileHandleOf(node);
    if (handle !== null) {
      const blob = await requireResolver(resolve)(handle.blobId);
      // A `file` leaf becomes base64; a promoted-string leaf becomes its decoded text (it IS a string).
      return handle.semanticKind === "string"
        ? new TextDecoder().decode(blob.bytes)
        : Buffer.from(blob.bytes).toString("base64");
    }
    const out: { [key: string]: Json } = {};
    for (const [key, value] of Object.entries(node)) {
      out[unescapeRecordKey(key)] = await materializeJsonTree(value, resolve);
    }
    return out;
  }
  return node;
}

/** Read a wire node that must be a string: an inline string directly, a promoted-string blob (`$ref`,
 *  `semanticKind: "string"`) through the store. A file (`semanticKind: "file"`) is a type error here — a
 *  text surface (a `text` body, a text part) takes a string, not a file. */
async function readWireString(
  node: Json | undefined,
  resolve: HttpBlobResolver | null,
): Promise<string> {
  if (typeof node === "string") return node;
  const handle = fileHandleOf(node);
  if (handle !== null && handle.semanticKind === "string") {
    const blob = await requireResolver(resolve)(handle.blobId);
    return new TextDecoder().decode(blob.bytes);
  }
  throw new Error("http.fetch: expected a string body / part content");
}

/** A `{ $constructor, value }` data value's tag + its fields, or `null` for any other Json. */
function dataValueOf(
  node: Json,
): { ctor: string; fields: { [key: string]: Json | undefined } } | null {
  if (node === null || typeof node !== "object" || Array.isArray(node)) return null;
  const ctor = node[CONSTRUCTOR_KEY];
  if (typeof ctor !== "string") return null;
  const value = node[VALUE_KEY];
  const fields = value !== null && typeof value === "object" && !Array.isArray(value) ? value : {};
  return { ctor, fields };
}

/** A `{ $ref, semanticKind }` file / blob handle's parts, or `null` for any other Json. */
function fileHandleOf(
  node: Json | undefined,
): { blobId: BlobId; semanticKind: "string" | "file" } | null {
  if (node === undefined || node === null || typeof node !== "object" || Array.isArray(node)) {
    return null;
  }
  const blobId = node[FILE_KEY];
  if (typeof blobId !== "string") return null;
  const semanticKind = node[SEMANTIC_KIND_KEY] === "string" ? "string" : "file";
  return { blobId: blobId as BlobId, semanticKind };
}

/** A multipart part's `name` / `filename` field as a plain string (a wire string, never a blob — these are
 *  small labels the program wrote inline). */
function fieldName(node: Json | undefined, where: string): string {
  if (typeof node !== "string") throw new Error(`http.fetch: ${where} needs a string name`);
  return node;
}

/** Neutralise a value going into a quoted header parameter (a part name / filename): drop CR / LF (header
 *  injection) and percent-escape the closing quote, per RFC 7578's guidance for form-data parameters. */
function headerQuote(value: string): string {
  return value.replace(/[\r\n]/g, "").replace(/"/g, "%22");
}

/** A body that references a file needs a resolver; a caller that wired none (a bare `FetchHttpTransport`)
 *  gets a loud error rather than a silent empty body. */
function requireResolver(resolve: HttpBlobResolver | null): HttpBlobResolver {
  if (resolve === null) {
    throw new Error("http.fetch: a file body needs a blob resolver, but none was wired");
  }
  return resolve;
}

/** Concatenate byte chunks into one buffer (the multipart body is text headers around raw file bytes). */
function concatBytes(chunks: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const chunk of chunks) total += chunk.byteLength;
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}
