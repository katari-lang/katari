export function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString();
}

/** Compact relative form for tables ("12s", "3m", "2h", "5d"); absolute belongs in a title tooltip. */
export function relativeTime(iso: string): string {
  const deltaSeconds = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (deltaSeconds < 60) return `${Math.floor(deltaSeconds)}s ago`;
  if (deltaSeconds < 3600) return `${Math.floor(deltaSeconds / 60)}m ago`;
  if (deltaSeconds < 86400) return `${Math.floor(deltaSeconds / 3600)}h ago`;
  return `${Math.floor(deltaSeconds / 86400)}d ago`;
}

export function formatBytes(size: number): string {
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  if (size < 1024 * 1024 * 1024) return `${(size / (1024 * 1024)).toFixed(1)} MB`;
  return `${(size / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

export function shortId(id: string): string {
  return id.slice(0, 8);
}
