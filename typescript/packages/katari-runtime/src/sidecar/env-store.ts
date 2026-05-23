// EnvStore — persistence layer interface for the EnvModule.
//
// Env entries are a flat key/value store shared across snapshots (the
// `katari apply` flow doesn't reset env). Secret entries carry their
// value as AES-GCM ciphertext per the runtime-side encryption
// convention; non-secret entries carry plaintext. EnvModule encrypts
// on the way in (when set_env names a secret) and decrypts on the
// way out (when get_secret_env returns one), so the store
// implementation (= api-server side) never sees plaintext secrets.

export type EnvEntry = {
  key: string;
  /**
   * Wire-form value.
   *
   *   - When `isSecret === false`: the actual plaintext non-secret string.
   *   - When `isSecret === true`: the AES-GCM ciphertext envelope produced
   *     by 'secret-crypto.encryptSecret'. The runtime decrypts at the
   *     EnvModule boundary before the value enters runtime memory as
   *     a 'secret' Value variant.
   */
  value: string;
  isSecret: boolean;
};

export interface EnvStore {
  /** Look up one entry by key. Returns null when absent. */
  get(key: string): Promise<EnvEntry | null>;
  /** Insert or overwrite an entry. Keys are case-sensitive. */
  upsert(entry: EnvEntry): Promise<void>;
  /** Remove an entry. Returns true iff one was deleted. */
  delete(key: string): Promise<boolean>;
  /** List every entry. Secret entries still carry their ciphertext. */
  list(): Promise<EnvEntry[]>;
}
