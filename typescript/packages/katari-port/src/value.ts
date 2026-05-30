// katari-port value client — the `katari.value` namespace.
//
// CONSUME. A handler receives args as `Record<string, RawValue>`. A
// byte-sequence arg (string / file) arrives either INLINE (a bare JSON string —
// short content) or as a `$ref` envelope (large content kept in the value
// store). This client hides that distinction: `await katari.value.text(
// args.history)` works the same whether `history` is a 3-word inline string or
// a 200 KB conversation fetched over the data plane. That uniformity is the
// point — the handler "builds a Promise from whatever ref flowed in".
//
// PRODUCE. `put` / `open`→`pushChunk`→`close` POST bytes to the owner module's
// produce endpoint and return a `$ref` to `return` from the handler; `persist`
// promotes an ephemeral ref to a project file. Produce is host-buffered and
// commits one complete blob (v0.1.0; observable streaming is v0.2).
//
// Both planes ride the Katari Protocol over HTTP
// (docs/2026-05-30-storage-schema-and-api.md §4):
//   GET  {KATARI_PROTOCOL_URL}/project/{KATARI_PROJECT_ID}/value/{module}/ref/{id}
//   POST {KATARI_PROTOCOL_URL}/project/{KATARI_PROJECT_ID}/value/{owner}/produce
// authenticated with the sidecar's bearer token. Inline consume needs no env;
// only refs / produce require the protocol configuration.

import type { RawValue } from "@katari-lang/types";

/**
 * Wire discriminator for a content-addressed reference. Mirrors
 * `REF_DISCRIMINATOR` in katari-runtime's value-codec — the `$ref` envelope is
 * `{ $ref: { module, id }, as, hash, size, contentType? }`.
 */
const REF_DISCRIMINATOR = "$ref";

/** A `$ref` envelope as it appears in a `RawValue`. */
type RefEnvelope = {
  [REF_DISCRIMINATOR]: { module: string; id: string };
  as: "string" | "file";
  hash: string;
  size: number;
  contentType?: string;
};

function asRefEnvelope(value: RawValue): RefEnvelope | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const ref = (value as Record<string, RawValue>)[REF_DISCRIMINATOR];
  if (typeof ref !== "object" || ref === null || Array.isArray(ref)) return null;
  const { module, id } = ref as Record<string, RawValue>;
  if (typeof module !== "string" || typeof id !== "string") return null;
  return value as unknown as RefEnvelope;
}

/** Produce-endpoint response = the new ref's identity + content addressing. */
type ProduceResponse = {
  module: string;
  id: string;
  hash: string;
  size: number;
  contentType?: string;
};

function parseProduceResponse(raw: unknown): ProduceResponse {
  if (typeof raw !== "object" || raw === null) {
    throw new Error("katari.value: malformed produce response (not an object)");
  }
  const { module, id, hash, size, contentType } = raw as Record<string, unknown>;
  if (
    typeof module !== "string" ||
    typeof id !== "string" ||
    typeof hash !== "string" ||
    typeof size !== "number"
  ) {
    throw new Error("katari.value: malformed produce response (missing module/id/hash/size)");
  }
  return {
    module,
    id,
    hash,
    size,
    contentType: typeof contentType === "string" ? contentType : undefined,
  };
}

/** Wrap a produce response into a `$ref` envelope RawValue. */
function wrapRef(response: ProduceResponse, as: ProduceAs): RawValue {
  const out: Record<string, RawValue> = {
    [REF_DISCRIMINATOR]: { module: response.module, id: response.id },
    as,
    hash: response.hash,
    size: response.size,
  };
  if (response.contentType !== undefined) out.contentType = response.contentType;
  return out;
}

function concatChunks(chunks: Uint8Array[], total: number): Uint8Array {
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

/** Minimal `fetch` shape so tests can inject a stub. */
export type FetchLike = (
  input: string,
  init?: { method?: string; headers?: Record<string, string>; body?: Uint8Array | string },
) => Promise<{
  ok: boolean;
  status: number;
  arrayBuffer(): Promise<ArrayBuffer>;
  text(): Promise<string>;
  json(): Promise<unknown>;
}>;

export type ValueClientConfig = {
  env?: Record<string, string | undefined>;
  fetchImpl?: FetchLike;
};

/** A produced byte sequence's kind on the wire (`secret` is inline-only). */
export type ProduceAs = "string" | "file";

export type ProduceOptions = {
  /** `string` (default) or `file`. Sets the ref's `as` + semantic kind. */
  as?: ProduceAs;
  /** Stored alongside the blob; surfaced on fetch / file download. */
  contentType?: string;
};

/**
 * Streaming producer handle (host-buffered → committed at `close`). v0.1.0
 * accumulates chunks in memory and produces one complete blob on `close`;
 * `abort` discards the buffer without contacting the store.
 */
export interface ProduceHandle {
  pushChunk(bytes: Uint8Array): void;
  close(): Promise<RawValue>;
  abort(): void;
}

/** The `katari.value` surface: consume (fetch/text/range) + produce (put/open/persist). */
export interface ValueApi {
  /** Raw bytes of a string / file value (inline or ref). */
  fetch(value: RawValue): Promise<Uint8Array>;
  /** UTF-8 text of a string / file value (inline or ref). */
  text(value: RawValue): Promise<string>;
  /** Bytes `[offset, offset+length)` — ranged data-plane fetch for refs. */
  fetchRange(value: RawValue, offset: number, length: number): Promise<Uint8Array>;
  /** Produce a complete blob; returns a `$ref` value to `return` from a handler. */
  put(bytes: Uint8Array, opts?: ProduceOptions): Promise<RawValue>;
  /** Open a streaming producer (host-buffered, committed on close). */
  open(opts?: ProduceOptions): ProduceHandle;
  /** Promote an ephemeral `$ref` to a persistent project file (`$ref` module=api). */
  persist(value: RawValue, opts?: { displayName?: string }): Promise<RawValue>;
}

type ProtocolConfig = {
  baseUrl: string;
  token: string;
  projectId: string;
  /** Owner module (`KATARI_SIDECAR_OWNER`) — required for produce, not consume. */
  owner: string | null;
};

function readConfig(env: Record<string, string | undefined>): ProtocolConfig {
  return {
    baseUrl: (env.KATARI_PROTOCOL_URL ?? "").replace(/\/$/, ""),
    token: env.KATARI_PROTOCOL_TOKEN ?? "",
    projectId: env.KATARI_PROJECT_ID ?? "",
    owner: env.KATARI_SIDECAR_OWNER ?? null,
  };
}

function requireConfig(env: Record<string, string | undefined>): ProtocolConfig {
  const cfg = readConfig(env);
  const missing = [
    cfg.baseUrl ? null : "KATARI_PROTOCOL_URL",
    cfg.token ? null : "KATARI_PROTOCOL_TOKEN",
    cfg.projectId ? null : "KATARI_PROJECT_ID",
  ].filter((name): name is string => name !== null);
  if (missing.length > 0) {
    throw new Error(
      `katari.value: cannot reach the data plane — missing sidecar env ${missing.join(", ")}. ` +
        `(Inline values need no protocol config; only refs require it.)`,
    );
  }
  return cfg;
}

function requireProduceConfig(env: Record<string, string | undefined>): ProtocolConfig & {
  owner: string;
} {
  const cfg = requireConfig(env);
  if (cfg.owner === null || cfg.owner === "") {
    throw new Error("katari.value: produce requires KATARI_SIDECAR_OWNER (the owner module)");
  }
  return { ...cfg, owner: cfg.owner };
}

export function createValueClient(config: ValueClientConfig = {}): ValueApi {
  const env = config.env ?? process.env;
  const fetchImpl = config.fetchImpl ?? (globalThis.fetch as unknown as FetchLike);

  function refUrl(cfg: ProtocolConfig, ref: RefEnvelope, range?: string): string {
    const { module, id } = ref[REF_DISCRIMINATOR];
    const base = `${cfg.baseUrl}/project/${encodeURIComponent(cfg.projectId)}/value/${encodeURIComponent(module)}/ref/${encodeURIComponent(id)}`;
    return range !== undefined ? `${base}?range=${range}` : base;
  }

  async function getBytes(url: string, cfg: ProtocolConfig): Promise<Uint8Array> {
    const response = await fetchImpl(url, {
      method: "GET",
      headers: { Authorization: `Bearer ${cfg.token}` },
    });
    if (!response.ok) {
      const detail = await response.text().catch(() => "");
      throw new Error(`katari.value: data plane GET ${url} failed (${response.status}) ${detail}`);
    }
    return new Uint8Array(await response.arrayBuffer());
  }

  async function postProduce(bytes: Uint8Array, opts?: ProduceOptions): Promise<RawValue> {
    const cfg = requireProduceConfig(env);
    const as: ProduceAs = opts?.as ?? "string";
    const url = `${cfg.baseUrl}/project/${encodeURIComponent(cfg.projectId)}/value/${encodeURIComponent(cfg.owner)}/produce`;
    const headers: Record<string, string> = {
      Authorization: `Bearer ${cfg.token}`,
      "X-Katari-Semantic-Kind": as,
    };
    if (opts?.contentType !== undefined) headers["Content-Type"] = opts.contentType;
    const response = await fetchImpl(url, { method: "POST", headers, body: bytes });
    if (!response.ok) {
      const detail = await response.text().catch(() => "");
      throw new Error(`katari.value: produce POST failed (${response.status}) ${detail}`);
    }
    return wrapRef(parseProduceResponse(await response.json()), as);
  }

  return {
    async fetch(value: RawValue): Promise<Uint8Array> {
      if (typeof value === "string") return new TextEncoder().encode(value);
      const ref = asRefEnvelope(value);
      if (ref === null) {
        throw new Error(
          "katari.value.fetch: value is not a string / file (no inline text or $ref)",
        );
      }
      const cfg = requireConfig(env);
      return getBytes(refUrl(cfg, ref), cfg);
    },

    async text(value: RawValue): Promise<string> {
      if (typeof value === "string") return value;
      const ref = asRefEnvelope(value);
      if (ref === null) {
        throw new Error("katari.value.text: value is not a string / file (no inline text or $ref)");
      }
      const cfg = requireConfig(env);
      return new TextDecoder().decode(await getBytes(refUrl(cfg, ref), cfg));
    },

    async fetchRange(value: RawValue, offset: number, length: number): Promise<Uint8Array> {
      if (offset < 0 || length < 0) {
        throw new Error("katari.value.fetchRange: offset / length must be non-negative");
      }
      if (typeof value === "string") {
        return new TextEncoder().encode(value).slice(offset, offset + length);
      }
      const ref = asRefEnvelope(value);
      if (ref === null) {
        throw new Error("katari.value.fetchRange: value is not a string / file");
      }
      const cfg = requireConfig(env);
      const endInclusive = offset + length - 1;
      return getBytes(refUrl(cfg, ref, `${offset}-${endInclusive}`), cfg);
    },

    put(bytes: Uint8Array, opts?: ProduceOptions): Promise<RawValue> {
      return postProduce(bytes, opts);
    },

    open(opts?: ProduceOptions): ProduceHandle {
      const chunks: Uint8Array[] = [];
      let total = 0;
      let settled = false;
      return {
        pushChunk(bytes: Uint8Array): void {
          if (settled) throw new Error("katari.value: pushChunk after close/abort");
          chunks.push(bytes.slice());
          total += bytes.length;
        },
        close(): Promise<RawValue> {
          if (settled) throw new Error("katari.value: close after close/abort");
          settled = true;
          return postProduce(concatChunks(chunks, total), opts);
        },
        abort(): void {
          settled = true;
          chunks.length = 0;
        },
      };
    },

    async persist(value: RawValue, opts?: { displayName?: string }): Promise<RawValue> {
      const ref = asRefEnvelope(value);
      if (ref === null) {
        throw new Error("katari.value.persist: value is not a $ref");
      }
      const { module, id } = ref[REF_DISCRIMINATOR];
      if (module !== "core" && module !== "ffi") {
        throw new Error(
          `katari.value.persist: only ephemeral (core/ffi) refs persist, got '${module}'`,
        );
      }
      const cfg = requireConfig(env);
      const url = `${cfg.baseUrl}/project/${encodeURIComponent(cfg.projectId)}/value/${encodeURIComponent(module)}/ref/${encodeURIComponent(id)}/persist`;
      const body = JSON.stringify(
        opts?.displayName !== undefined ? { displayName: opts.displayName } : {},
      );
      const response = await fetchImpl(url, {
        method: "POST",
        headers: { Authorization: `Bearer ${cfg.token}`, "Content-Type": "application/json" },
        body,
      });
      if (!response.ok) {
        const detail = await response.text().catch(() => "");
        throw new Error(`katari.value: persist POST failed (${response.status}) ${detail}`);
      }
      // A persisted ref is an api file (opaque bytes, identity equality).
      return wrapRef(parseProduceResponse(await response.json()), "file");
    },
  };
}
