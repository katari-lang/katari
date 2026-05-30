// katari-port value consume client — the `katari.value` namespace.
//
// A handler receives args as `Record<string, RawValue>`. A byte-sequence arg
// (string / file) arrives either INLINE (a bare JSON string — short content)
// or as a `$ref` envelope (large content kept in the value store). This client
// hides that distinction: `await katari.value.text(args.history)` works the
// same whether `history` is a 3-word inline string or a 200 KB conversation
// fetched over the data plane. That uniformity is the whole point — the
// handler "builds a Promise from whatever ref flowed in" without branching.
//
// Consume only (v0.1.0): full / ranged fetch of COMPLETE blobs. `$ref` values
// are pulled from the Katari Protocol data plane
// (docs/2026-05-30-storage-schema-and-api.md §4.2):
//   GET {KATARI_PROTOCOL_URL}/project/{KATARI_PROJECT_ID}/value/{module}/ref/{id}
// authenticated with the sidecar's bearer token. Inline values need no env, so
// handlers that only see small args run without the protocol configured.

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

/** Minimal `fetch` shape so tests can inject a stub. */
export type FetchLike = (
  input: string,
  init?: { method?: string; headers?: Record<string, string> },
) => Promise<{
  ok: boolean;
  status: number;
  arrayBuffer(): Promise<ArrayBuffer>;
  text(): Promise<string>;
}>;

export type ValueClientConfig = {
  env?: Record<string, string | undefined>;
  fetchImpl?: FetchLike;
};

/** The `katari.value` consume surface. */
export interface ValueApi {
  /** Raw bytes of a string / file value (inline or ref). */
  fetch(value: RawValue): Promise<Uint8Array>;
  /** UTF-8 text of a string / file value (inline or ref). */
  text(value: RawValue): Promise<string>;
  /** Bytes `[offset, offset+length)` — ranged data-plane fetch for refs. */
  fetchRange(value: RawValue, offset: number, length: number): Promise<Uint8Array>;
}

type ProtocolConfig = {
  baseUrl: string;
  token: string;
  projectId: string;
};

function requireConfig(env: Record<string, string | undefined>): ProtocolConfig {
  const baseUrl = env.KATARI_PROTOCOL_URL;
  const token = env.KATARI_PROTOCOL_TOKEN;
  const projectId = env.KATARI_PROJECT_ID;
  const missing = [
    baseUrl ? null : "KATARI_PROTOCOL_URL",
    token ? null : "KATARI_PROTOCOL_TOKEN",
    projectId ? null : "KATARI_PROJECT_ID",
  ].filter((name): name is string => name !== null);
  if (missing.length > 0) {
    throw new Error(
      `katari.value: cannot fetch a $ref — missing sidecar env ${missing.join(", ")}. ` +
        `(Inline values need no protocol config; only refs require the data plane.)`,
    );
  }
  return { baseUrl: baseUrl!.replace(/\/$/, ""), token: token!, projectId: projectId! };
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
  };
}
