// Capability tokens for FFI sidecar processes: what a sidecar authenticates its blob side channel with.
//
// A sidecar runs the user's own FFI handler code — arbitrary JavaScript, and on a project that pulled in a
// third-party katari package, arbitrary JavaScript someone else wrote. It needs to reach the runtime for
// exactly two things: downloading a blob it was handed, and uploading one it produced mid-call. It used to
// be given `KATARI_API_KEY` for that, which is the runtime's MASTER bearer — the credential that opens every
// route of every project. Any handler could read it out of its own environment and deploy code into an
// unrelated project, or rewrite that project's env. The blast radius of "a package I depend on" was "the
// whole runtime".
//
// So a sidecar now gets a token minted for it alone: random, held only in this process's memory, scoped to
// ONE project and to the two blob paths, and revoked when its process is torn down. It is a capability, not
// an identity — there is nothing to look up and no privilege to escalate to, because the token names its own
// authority completely.
//
// Deliberately in-memory rather than in the database: the token's lifetime is exactly the sidecar process's,
// both die with the runtime, and persisting it would only create a way for one to outlive the other.

import { randomBytes } from "node:crypto";
import type { ProjectId } from "../runtime/ids.js";

/** What a minted token authorises: the one project whose blobs its sidecar may read and write. */
interface Grant {
  projectId: ProjectId;
}

const grants = new Map<string, Grant>();

/** Mint a token for one sidecar process. 192 bits from the CSPRNG, so the token is unguessable and needs no
 *  rate limiting of its own to be safe. */
export function mintSidecarToken(projectId: ProjectId): string {
  const token = randomBytes(24).toString("base64url");
  grants.set(token, { projectId });
  return token;
}

/** Drop a token — its sidecar is gone, so the capability should be too. Idempotent. */
export function revokeSidecarToken(token: string): void {
  grants.delete(token);
}

/** The two request shapes a sidecar token may be used for, both under `/api/v1` and both scoped to the
 *  granted project:
 *    - `GET  /projects/<project>/files/<blobId>`         — read a blob it was handed
 *    - `POST /projects/<project>/ffi/<delegation>/blobs` — register a blob it produced
 *  Written as explicit patterns rather than a prefix test, so widening the sidecar's reach is a deliberate
 *  edit here rather than something a new route under `/projects/<id>/` inherits by accident. */
const DOWNLOAD_PATH = /^\/api\/v1\/projects\/([^/]+)\/files\/[^/]+$/;
const UPLOAD_PATH = /^\/api\/v1\/projects\/([^/]+)\/ffi\/[^/]+\/blobs$/;

/** Whether a presented token authorises this exact request. Returns false for an unknown token, for a
 *  project other than the one it was minted for, and for any path outside the blob side channel — including
 *  a method mismatch, so the read grant cannot be used to write. */
export function sidecarTokenAuthorizes(token: string, method: string, path: string): boolean {
  const grant = grants.get(token);
  if (grant === undefined) return false;
  const matched =
    (method === "GET" && DOWNLOAD_PATH.exec(path)) || (method === "POST" && UPLOAD_PATH.exec(path));
  if (matched === null || matched === false) return false;
  return matched[1] === grant.projectId;
}

/** How many tokens are live. Only for the tests — a leak here is a slow one, so it is worth being able to
 *  assert that teardown actually revokes. */
export function liveSidecarTokenCount(): number {
  return grants.size;
}
