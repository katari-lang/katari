// A tiny bridge from the API layer (outside React) to the auth gate (inside React). The query/mutation
// caches call `reportUnauthorized()` when a request comes back 401; the gate registers a handler to show
// its login screen. Kept as a module-level slot rather than context so the non-React fetch layer can
// reach it without threading providers through.

let handler: (() => void) | null = null;

/** Register the gate's "a request was unauthorized" handler (null on unmount). */
export function setUnauthorizedHandler(next: (() => void) | null): void {
  handler = next;
}

/** Signal that a request was rejected with 401 — the gate shows its login screen. */
export function reportUnauthorized(): void {
  handler?.();
}
