// Storage-backed `EnvStore` adapter.
//
// One instance per orchestrator tick (= per HTTP request). Routes
// each EnvModule call through to the underlying `envEntries` repo
// on the transactional `Storage` handle.
//
// The store does not perform any crypto: the EnvModule encrypts
// secret values upstream so the rows that reach this layer carry
// either plaintext (for non-secret entries) or AES-GCM ciphertext
// (for secret entries) — both opaque strings as far as the DB is
// concerned.

import type { EnvEntry, EnvStore } from "@katari-lang/runtime";
import type { Storage } from "../storage/types.js";

export class StorageEnvStore implements EnvStore {
  constructor(private readonly storage: Storage) {}

  async get(key: string): Promise<EnvEntry | null> {
    const row = await this.storage.envEntries.get(key);
    if (row === null) return null;
    return { key: row.key, value: row.value, isSecret: row.isSecret };
  }

  async upsert(entry: EnvEntry): Promise<void> {
    await this.storage.envEntries.upsert({
      key: entry.key,
      value: entry.value,
      isSecret: entry.isSecret,
    });
  }

  async delete(key: string): Promise<boolean> {
    return this.storage.envEntries.delete(key);
  }

  async list(): Promise<EnvEntry[]> {
    const rows = await this.storage.envEntries.list();
    return rows.map((r) => ({
      key: r.key,
      value: r.value,
      isSecret: r.isSecret,
    }));
  }
}
