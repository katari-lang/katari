// Obsolete: the JSON-anywhere walker has been replaced by typed
// per-Module persistors. Encryption now happens at typed boundaries
// via 'value-secret-codec.ts' (Value ↔ EncryptedValue) and at the
// EngineCheckpoint structural boundary via private helpers inside
// 'engine/snapshot.ts'. No public API is exported from this file —
// it remains as a placeholder so the file path doesn't reappear via
// stale imports; deletion lands with a follow-up filesystem cleanup.
export {};
