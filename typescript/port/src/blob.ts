// The blob side channel: how an FFI handler moves a blob's BYTES to / from the runtime. A blob crosses the FFI
// boundary as a small handle (`{ $ref, size, hash, ... }`) — never its bytes — so reading a received file (or,
// in a later step, producing a new one) goes over HTTP to the runtime, out of band from the one-shot stdio
// reply channel that carries only the handler's JSON result. The runtime hands the sidecar its own URL, the
// project id, and the API bearer token as env (`KATARI_RUNTIME_URL` / `KATARI_PROJECT_ID` / `KATARI_API_KEY`);
// these helpers read them. The blob routes are under the runtime's authenticated `/api`, so every call carries
// the bearer. Outside a runtime-hosted sidecar (e.g. a bare unit test) the env is unset and they throw a clear
// error rather than guessing an endpoint.

/** The handle an FFI handler receives for a `File` argument (and returns to produce one): a content reference,
 *  not the bytes. `$ref` is the blob id; `size` / `hash` describe it. Declared as a type (not an interface) so
 *  it is structurally a `Json` object — a handler can `return context.uploadBlob(...)` (or a record containing
 *  the handle) directly, and the runtime lifts it into a `File` value. */
export type FileHandle = {
  $ref: string;
  size: number;
  hash: string;
  semanticKind?: string;
  contentType?: string;
};

/** The runtime endpoint a runtime-hosted sidecar was given, or a thrown error when run outside one. */
function runtimeEndpoint(): { baseUrl: string; projectId: string; apiKey: string } {
  const baseUrl = process.env.KATARI_RUNTIME_URL;
  const projectId = process.env.KATARI_PROJECT_ID;
  const apiKey = process.env.KATARI_API_KEY;
  if (
    baseUrl === undefined ||
    baseUrl === "" ||
    projectId === undefined ||
    projectId === "" ||
    apiKey === undefined ||
    apiKey === ""
  ) {
    throw new Error(
      "katari: a blob operation needs a runtime-hosted sidecar (KATARI_RUNTIME_URL / KATARI_PROJECT_ID / KATARI_API_KEY are unset)",
    );
  }
  return { baseUrl, projectId, apiKey };
}

/** The bearer header every blob-channel request carries (the routes are under the runtime's `/api`). */
function authHeader(apiKey: string): Record<string, string> {
  return { authorization: `Bearer ${apiKey}` };
}

/** The blob id a handle (or a bare id string) names. */
function blobIdOf(handle: FileHandle | string): string {
  return typeof handle === "string" ? handle : handle.$ref;
}

/** Download a blob's bytes from the runtime by its handle (or bare blob id). The bytes stream over HTTP, not
 *  the stdio reply channel. Honors the handler's abort signal so a cancelled call stops waiting. */
export async function downloadBlob(
  handle: FileHandle | string,
  signal?: AbortSignal,
): Promise<Uint8Array> {
  const { baseUrl, projectId, apiKey } = runtimeEndpoint();
  const response = await fetch(`${baseUrl}/projects/${projectId}/files/${blobIdOf(handle)}`, {
    headers: authHeader(apiKey),
    ...(signal !== undefined ? { signal } : {}),
  });
  if (!response.ok) {
    throw new Error(`katari: blob download failed (${response.status} ${response.statusText})`);
  }
  return new Uint8Array(await response.arrayBuffer());
}

/** Options for producing a blob from a handler. */
export interface UploadOptions {
  /** The MIME type recorded with the blob (e.g. `"image/png"`), surfaced on download. */
  contentType?: string;
}

/** Narrow an unknown JSON value to a record, or `undefined` if it is not an object. */
function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null
    ? (value as Record<string, unknown>)
    : undefined;
}

/** Read a response body as JSON, turning a non-JSON body (an off-contract 2xx — e.g. a proxy that stripped it)
 *  into the same clear shape error a malformed envelope gives, rather than a raw `SyntaxError`. */
async function readJsonBody(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    throw new Error("katari: blob upload returned an unexpected response shape");
  }
}

/** Pull the produced blob's `{ id, hash, size }` out of the runtime's `{ ok, data }` envelope, validating each
 *  field's type — a missing `size` must fail here rather than silently become `NaN` in the handle. */
function parseProducedBlob(body: unknown): { id: string; hash: string; size: number } {
  const data = asRecord(asRecord(body)?.data);
  if (
    data === undefined ||
    typeof data.id !== "string" ||
    typeof data.hash !== "string" ||
    typeof data.size !== "number"
  ) {
    throw new Error("katari: blob upload returned an unexpected response shape");
  }
  return { id: data.id, hash: data.hash, size: data.size };
}

/** Produce a new blob from `bytes` and return its handle (a `File` value when returned from the handler). The
 *  bytes are POSTed to the runtime over HTTP, where the blob is registered as owned by this call — so it
 *  ascends to the calling agent on return, and is reclaimed if the handler dies first. Honors the handler's
 *  abort signal. The `delegation` ties the blob to this in-flight call; the handler API curries it in. */
export async function uploadBlob(
  delegation: string,
  bytes: Uint8Array,
  options?: UploadOptions,
  signal?: AbortSignal,
): Promise<FileHandle> {
  const { baseUrl, projectId, apiKey } = runtimeEndpoint();
  const headers: Record<string, string> = authHeader(apiKey);
  if (options?.contentType !== undefined) headers["content-type"] = options.contentType;
  const response = await fetch(`${baseUrl}/projects/${projectId}/ffi/${delegation}/blobs`, {
    method: "POST",
    headers,
    body: bytes,
    ...(signal !== undefined ? { signal } : {}),
  });
  if (!response.ok) {
    throw new Error(`katari: blob upload failed (${response.status} ${response.statusText})`);
  }
  const produced = parseProducedBlob(await readJsonBody(response));
  return {
    $ref: produced.id,
    size: produced.size,
    hash: produced.hash,
    semanticKind: "file",
    ...(options?.contentType !== undefined ? { contentType: options.contentType } : {}),
  };
}
