// Internal data-plane client + value-shape guards for the sidecar.
//
// NOT the public surface — katari-port exposes friendly constructors / readers
// (`makeString` / `makeFile` / `makeAgent` / `readString` / `readBytes` /
// `persist`) on the `katari` singleton (see index.ts), built on top of this.
// This module hides the Katari Protocol HTTP (auth / URL / env):
//
//   CONSUME: a byte-sequence arg (string / file) arrives INLINE (a bare JSON
//   string) or as a `$ref` envelope (large content in the value store). A ref
//   is fetched over the data plane; inline needs no protocol config.
//   PRODUCE:  POST bytes to the owner module's produce endpoint → a `$ref`.
//   PERSIST:  promote an ephemeral (core/ffi) ref to a durable project file.
//
//   GET  {KATARI_PROTOCOL_URL}/project/{KATARI_PROJECT_ID}/value/{module}/ref/{id}
//   POST {KATARI_PROTOCOL_URL}/project/{KATARI_PROJECT_ID}/value/{owner}/produce
// authenticated with the sidecar's bearer token (KATARI_PROTOCOL_TOKEN).

import type { RawValue } from "@katari-lang/types";
import type { KatariAgent, KatariFile, KatariRef, KatariString, RefModule } from "./types.js";

const REF_DISCRIMINATOR = "$ref";
const CALLABLE_DISCRIMINATOR = "$agent";

// ─── value-shape guards (public) ────────────────────────────────────────────

/** The `$ref` envelope view of a value, or null if it isn't one. */
export function asRef(value: RawValue): KatariRef<"string" | "file"> | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const record = value as Record<string, RawValue>;
  const ref = record[REF_DISCRIMINATOR];
  if (typeof ref !== "object" || ref === null || Array.isArray(ref)) return null;
  const { module, id } = ref as Record<string, RawValue>;
  if (typeof module !== "string" || typeof id !== "string") return null;
  if (record.as !== "string" && record.as !== "file") return null;
  return value as unknown as KatariRef<"string" | "file">;
}

/** A `file` value (always a `$ref as:file`). */
export function isKatariFile(value: RawValue): value is KatariFile {
  return asRef(value)?.as === "file";
}

/** A `string` value — inline text or a `$ref as:string`. */
export function isKatariString(value: RawValue): value is KatariString {
  return typeof value === "string" || asRef(value)?.as === "string";
}

/** A callable value (agent `qname@snapshot` or `closureref:<id>`). */
export function isKatariAgent(value: RawValue): value is KatariAgent {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  return typeof (value as Record<string, RawValue>)[CALLABLE_DISCRIMINATOR] === "string";
}

// ─── data plane (internal) ──────────────────────────────────────────────────

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

/** A produced byte sequence's kind on the wire (`secret` is inline-only). */
export type ProduceAs = "string" | "file";

export type DataPlaneConfig = {
  env?: Record<string, string | undefined>;
  fetchImpl?: FetchLike;
};

export interface DataPlane {
  /** Bytes of a `$ref` value (fetched over the data plane). */
  fetchBytes(ref: KatariRef<"string" | "file">): Promise<Uint8Array>;
  /** Produce a complete blob → its `$ref`. `ownerDelegationId` is the producing
   *  handler's delegation id: the ref is stamped with it as its owning entity
   *  (GC ownership) — alive while that ext delegation runs, re-owned by the
   *  parent on ack. (Passed explicitly by the caller; no ambient context.) */
  produce(
    bytes: Uint8Array,
    opts: {
      as: ProduceAs;
      contentType?: string;
      displayName?: string;
      ownerDelegationId?: string | null;
    },
  ): Promise<KatariRef<"string" | "file">>;
  /** Promote an ephemeral (core/ffi) ref to a durable api file ref. */
  persist(ref: KatariRef<"string" | "file">, opts?: { displayName?: string }): Promise<KatariFile>;
}

type ProtocolConfig = { baseUrl: string; token: string; projectId: string; owner: string | null };

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
      `katari: cannot reach the data plane — missing sidecar env ${missing.join(", ")}. ` +
        `(Inline values need no protocol config; only refs require it.)`,
    );
  }
  return cfg;
}

function parseRefResponse(raw: unknown, as: ProduceAs): KatariRef<"string" | "file"> {
  if (typeof raw !== "object" || raw === null) {
    throw new Error("katari: malformed produce response (not an object)");
  }
  const { module, id, hash, size, contentType } = raw as Record<string, unknown>;
  if (
    typeof module !== "string" ||
    typeof id !== "string" ||
    typeof hash !== "string" ||
    typeof size !== "number"
  ) {
    throw new Error("katari: malformed produce response (missing module/id/hash/size)");
  }
  const out: KatariRef<"string" | "file"> = {
    $ref: { module: module as RefModule, id },
    as,
    hash,
    size,
  };
  if (typeof contentType === "string") out.contentType = contentType;
  return out;
}

export function createDataPlane(config: DataPlaneConfig = {}): DataPlane {
  const env = config.env ?? process.env;
  const fetchImpl = config.fetchImpl ?? (globalThis.fetch as unknown as FetchLike);

  return {
    async fetchBytes(ref): Promise<Uint8Array> {
      const cfg = requireConfig(env);
      const { module, id } = ref.$ref;
      const url = `${cfg.baseUrl}/project/${encodeURIComponent(cfg.projectId)}/value/${encodeURIComponent(module)}/ref/${encodeURIComponent(id)}`;
      const response = await fetchImpl(url, {
        method: "GET",
        headers: { Authorization: `Bearer ${cfg.token}` },
      });
      if (!response.ok) {
        const detail = await response.text().catch(() => "");
        throw new Error(`katari: data plane GET ${url} failed (${response.status}) ${detail}`);
      }
      return new Uint8Array(await response.arrayBuffer());
    },

    async produce(bytes, opts): Promise<KatariRef<"string" | "file">> {
      const cfg = requireConfig(env);
      if (cfg.owner === null || cfg.owner === "") {
        throw new Error("katari: produce requires KATARI_SIDECAR_OWNER (the owner module)");
      }
      const url = `${cfg.baseUrl}/project/${encodeURIComponent(cfg.projectId)}/value/${encodeURIComponent(cfg.owner)}/produce`;
      const headers: Record<string, string> = {
        Authorization: `Bearer ${cfg.token}`,
        "X-Katari-Semantic-Kind": opts.as,
      };
      if (opts.contentType !== undefined) headers["Content-Type"] = opts.contentType;
      if (opts.displayName !== undefined) headers["X-Katari-Display-Name"] = opts.displayName;
      const ownerDelegationId = opts.ownerDelegationId ?? null;
      if (ownerDelegationId !== null) headers["X-Katari-Owner-Delegation"] = ownerDelegationId;
      const response = await fetchImpl(url, { method: "POST", headers, body: bytes });
      if (!response.ok) {
        const detail = await response.text().catch(() => "");
        throw new Error(`katari: produce POST failed (${response.status}) ${detail}`);
      }
      return parseRefResponse(await response.json(), opts.as);
    },

    async persist(ref, opts): Promise<KatariFile> {
      const { module, id } = ref.$ref;
      if (module !== "core" && module !== "ffi") {
        throw new Error(`katari.persist: only ephemeral (core/ffi) refs persist, got '${module}'`);
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
        throw new Error(`katari.persist: POST failed (${response.status}) ${detail}`);
      }
      // A persisted ref is an api file (opaque bytes, identity equality).
      return parseRefResponse(await response.json(), "file") as KatariFile;
    },
  };
}
