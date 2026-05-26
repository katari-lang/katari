// Cursor-based pagination utilities.
//
// The cursor encodes a `(createdAt, id)` pair as opaque base64 JSON so
// the client never parses or constructs it — it just passes the string
// back on the next request. Decoding is lenient: any malformed input
// returns `null` and the caller falls back to the first page.

export type CursorPayload = {
  /** ISO-8601 timestamp of the last item on the previous page. */
  createdAt: string;
  /** Primary-key id of the last item on the previous page. */
  id: string;
};

/**
 * Encode a `(createdAt, id)` pair into an opaque cursor string.
 */
export function encodeCursor(createdAt: string, id: string): string {
  const json = JSON.stringify({ t: createdAt, i: id });
  return Buffer.from(json, "utf-8").toString("base64");
}

/**
 * Decode an opaque cursor string back into a `(createdAt, id)` pair.
 * Returns `null` on any parse / shape error so callers can silently
 * treat invalid cursors as "start from the beginning".
 */
export function decodeCursor(cursor: string): CursorPayload | null {
  try {
    const json = Buffer.from(cursor, "base64").toString("utf-8");
    const parsed: unknown = JSON.parse(json);
    if (
      typeof parsed !== "object" ||
      parsed === null ||
      typeof (parsed as { t?: unknown }).t !== "string" ||
      typeof (parsed as { i?: unknown }).i !== "string"
    ) {
      return null;
    }
    return {
      createdAt: (parsed as { t: string }).t,
      id: (parsed as { i: string }).i,
    };
  } catch {
    return null;
  }
}
