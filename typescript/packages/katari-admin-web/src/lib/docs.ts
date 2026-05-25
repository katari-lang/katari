// Docs URL helpers.
//
// Single point of edit when the docs site moves, the version bumps, or
// the path structure changes. Pages reference docs by slug only.

const DOCS_BASE = "https://katari-lang.dev/docs";

/** Docs version this build of admin-web is paired with. Bumped alongside
 *  the katari toolchain. Kept here (not env-injected) because admin-web is
 *  shipped statically by the api-server — it has no build-time version
 *  awareness of its own. */
export const DOCS_VERSION = "v0.1";

/** Resolve a docs slug to a full URL.
 *
 *  Accepts slugs with or without a leading slash. Empty / `"/"` slug
 *  returns the docs landing page.
 *
 *  Examples:
 *    docsUrl("agents") → "https://katari-lang.dev/docs/v0.1/agents"
 *    docsUrl("/concepts/runs") → "https://katari-lang.dev/docs/v0.1/concepts/runs"
 *    docsUrl("") → "https://katari-lang.dev/docs/v0.1"
 */
export function docsUrl(slug: string): string {
  const trimmed = slug.replace(/^\/+/, "");
  if (trimmed === "") return `${DOCS_BASE}/${DOCS_VERSION}`;
  return `${DOCS_BASE}/${DOCS_VERSION}/${trimmed}`;
}
