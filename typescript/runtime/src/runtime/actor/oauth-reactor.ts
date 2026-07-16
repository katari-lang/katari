// OauthReactor: the `oauth` reactor — on-demand OAuth token resolution as a call reactor (see
// `ExternalCallReactor` for the shared callee-call lifecycle). It makes any workflow able to call an
// OAuth-protected API: `oauth.token(name)` reaches it as a `delegate` (an external leaf marked
// `reactor: "oauth"`) and resolves the named credential to a usable bearer token through the credentials
// core (`resolveToken` — docs/2026-07-14-credentials-core.md §2), the SAME resolution + refresh path the
// mcp transport injects its bearer through. The single operation dispatches on the resolution's outcome:
//   - `{ token }` — settle with the token as a `string of private` value (the stdlib return type). The
//     private marker is stamped at the wire-decode seam (`AckDecodingPayload`, like `env.get_secret`'s
//     prim), so the bearer redacts at every user-facing boundary (a run result, the trace) and reveals
//     only toward a submission sink (an http `Authorization` header) — the program never handles token
//     material, only the private string it composes into a header.
//   - `{ needsAuthorize }` — the credential is missing, unreadable, or refresh-dead: PARK the call through
//     the base's shared credential-park machinery (`parkCall` raises the base `prelude.oauth.authorize`
//     escalation, carrying only the credential `{ name }` — a configured credential has no server URL to
//     show). The run stops and asks; completing the authorization (the runtime-hosted browser flow) answers
//     the escalation, and the base re-runs the parked resolution FROM SCRATCH (`redispatchParked`), which
//     re-reads the store. Still-unusable material parks again with a fresh escalation — the one unbounded
//     authorize loop, owned by the base.
//   - a TRANSIENT resolution failure (a network error, a token-endpoint 5xx while refreshing) is a program-
//     anticipatable failure, so it escalates as `throw[oauth.server_error]` (the `error` completion +
//     `escalateError` override, exactly like the http reactor's `fetch_error`) — a caller handles it to
//     control retry; unhandled, it fails the run.
//
// Recovery is like `time.now`, NOT like http: token resolution is a read plus an idempotent refresh whose
// write-back persists IMMEDIATELY through the repository's compare-and-set (outside the actor's turn), so
// re-running it after a restart is at-most-once-safe — a reloaded running call simply re-resolves (a refresh
// that already landed is served by the stored clock, no second grant). The only durable state a call carries
// is its credential `name` (persisted so the re-resolve knows what to fetch) and, when parked, its open
// authorize escalation row — the SoT the reload reconstructs the park from (`reconstructPark`).

import type { Json, QualifiedName } from "@katari-lang/types";
import { errorData } from "../engine/throw-signal.js";
import type { ReactorName } from "../event/types.js";
import {
  type CredentialStore,
  OAUTH_AUTHORIZE_REQUEST,
  resolveToken,
  type TokenResolution,
} from "../external/credentials.js";
import type { DelegationId, InstanceId } from "../ids.js";
import { markPrivate } from "../value/privacy.js";
import type { GenericSubstitution, Value } from "../value/types.js";
import { documentOf, stringFieldOf } from "./extension-codec.js";
import {
  type CallRow,
  type DecodedCallExtension,
  ExternalCallReactor,
  type ExternalTarget,
} from "./external-call-reactor.js";
import { messageOf } from "./failure.js";
import type { ResourcePool } from "./resource-pool.js";

/** The compiled external key the `prelude.oauth.token` call arrives under — compared exactly here, at the
 *  payload boundary, then never again (the typechecker restricts `from "oauth"` to the stdlib module, so a
 *  key outside this one is compiler/runtime drift). */
const TOKEN_KEY = "prelude.oauth.token";

/** The domain error ctor a transient resolution failure throws (`prelude/oauth.ktr` declares it). */
const SERVER_ERROR = "prelude.oauth.server_error";

/** What an oauth call holds: the credential name to resolve (persisted, so a reloaded call re-resolves the
 *  same credential) plus the ack decoder that stamps the resolved token `private` — rebuilt identically by
 *  a fresh `openPayload` and a reload, so the private marker cannot drift between the two. */
interface OauthPayload {
  name: string;
  /** The ONE ack-shaping seam (`AckDecodingPayload`, applied by the base at the wire-decode boundary): the
   *  resolved bearer token is `string of private`, so it is marked private here. */
  decodeAck: (raw: Json) => Value;
}

export class OauthReactor extends ExternalCallReactor<OauthPayload> {
  readonly name: ReactorName = "oauth";

  constructor(
    /** The credential store token resolution refreshes through and the authorize-retry loop re-reads —
     *  the same per-project `credentials` store the mcp transport resolves its bearer through. */
    private readonly store: CredentialStore,
    /** Schedule a fresh reactor turn (the substrate's serial mailbox) — how an async resolution's outcome
     *  re-enters the transactional loop, like the time reactor's fired-timer work. */
    private readonly schedule: (work: () => void) => void,
    pool: ResourcePool,
  ) {
    super(pool);
  }

  // ─── the ExternalCallReactor hooks ───────────────────────────────────────────────────────────────

  protected openPayload(
    target: ExternalTarget,
    argument: Value | null,
    _generics: GenericSubstitution | undefined,
  ): OauthPayload {
    if (target.key !== TOKEN_KEY) {
      throw new Error(
        `oauth: unknown external key "${target.key}" (compiler/runtime drift — a bug)`,
      );
    }
    return oauthPayloadOf(nameOf(argument));
  }

  /** Post-commit: resolve the token. The resolution is async (a refresh POSTs to the token endpoint), so
   *  it re-enters the serial loop with its outcome — a settle, a park, or a transient-failure throw. */
  protected dispatch(delegation: DelegationId, payload: OauthPayload): void {
    void this.resolve(delegation, payload.name);
  }

  /** Reactivation: a parked call reconstructs from its open authorize escalation row (never re-resolves —
   *  it waits for the ack); every other reloaded running call re-resolves from scratch. Re-resolving is
   *  at-most-once-safe (a read + an idempotent, immediately-persisted refresh), so — unlike http / mcp
   *  transport calls — a time.now-style re-run is correct rather than a refused interruption. */
  protected recover(delegation: DelegationId): void {
    if (this.reconstructPark(delegation)) return;
    const payload = this.payloadOf(delegation);
    if (payload === undefined) return;
    void this.resolve(delegation, payload.name);
  }

  /** A cancel's transport half: there is no external transport to abort, so confirm on a fresh turn. */
  protected abort(delegation: DelegationId): void {
    this.schedule(() => this.complete({ delegation, outcome: { kind: "cancelled" } }));
  }

  /** The park request the oauth reactor raises and reconstructs from — turning on the base's
   *  credential-park machinery (`parkCall` / `reconstructPark` / `redispatchParked`). */
  protected override parkRequestName(): QualifiedName {
    return OAUTH_AUTHORIZE_REQUEST;
  }

  /** Re-run a parked resolution after its authorize escalation was answered — re-read the store from
   *  scratch. A still-unusable credential parks again with a fresh escalation (the base's one loop). */
  protected override redispatchParked(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined) return; // the call resolved while the retry was staged (a racing cancel)
    void this.resolve(delegation, payload.name);
  }

  /** A transient resolution failure is program-anticipatable: escalate `throw[oauth.server_error]` (not a
   *  panic), so a caller's throw handler controls retry. `raiser` (this oauth call's instance) owns the row. */
  protected override escalateError(
    delegation: DelegationId,
    message: string,
    caller: ReactorName,
    run: InstanceId,
    raiser: InstanceId,
  ): void {
    this.raiseThrow(delegation, errorData(SERVER_ERROR, message), caller, run, raiser);
  }

  /** Resolve the named credential to a bearer token and re-enter the serial loop with the outcome: a
   *  `{ token }` settles the call, a `{ needsAuthorize }` parks it, and a TRANSIENT failure (the throw out
   *  of `resolveToken`) completes as the `error` outcome the `escalateError` override turns into a typed
   *  `server_error` throw. The completion / park runs on a scheduled turn (the base mutates durable state
   *  and `send`s inside it); a call that vanished or moved to cancelling meanwhile is handled by the base. */
  private async resolve(delegation: DelegationId, name: string): Promise<void> {
    let resolution: TokenResolution;
    try {
      resolution = await resolveToken(this.store, name);
    } catch (error) {
      this.schedule(() =>
        this.complete({ delegation, outcome: { kind: "error", message: messageOf(error) } }),
      );
      return;
    }
    this.schedule(() => {
      if (resolution.kind === "needsAuthorize") {
        this.parkCall(delegation, authorizeArgument(name));
        return;
      }
      this.complete({ delegation, outcome: { kind: "result", value: resolution.token } });
    });
  }

  /** The extension document: the credential name (all a reload needs to re-resolve). No inner-delegation
   *  bridges — an oauth call opens none — so the fields are absent rather than empty-nullable. The park is
   *  marked by the open authorize escalation row alone (`reconstructPark`), not by an extension variant. */
  protected encodeCallExtension(row: CallRow<OauthPayload>): Json {
    return { name: row.payload.name };
  }

  protected decodeCallExtension(extension: Json): DecodedCallExtension<OauthPayload> {
    const document = documentOf(extension);
    return {
      payload: oauthPayloadOf(stringFieldOf(document, "name")),
      relays: [],
      innerCalls: [],
    };
  }
}

/** Build an oauth call's payload — the credential name plus the ack decoder that stamps the resolved token
 *  `private`. Shared by a fresh `openPayload` and a reloaded call, so the private marking cannot drift. */
function oauthPayloadOf(name: string): OauthPayload {
  return { name, decodeAck: (raw) => markPrivate(tokenValueOf(raw)) };
}

/** The resolved bearer token as a string `Value`. A non-string resolution is a runtime invariant break (a
 *  `{ token }` outcome always carries a string), surfaced loudly rather than marked private silently. */
function tokenValueOf(raw: Json): Value {
  if (typeof raw !== "string") {
    throw new Error(`oauth: token resolution produced a ${typeof raw}, not a string (a bug)`);
  }
  return { kind: "string", value: raw };
}

/** Read the `name` off an `oauth.token(name)` argument. A missing / wrong-kind field is compiler/runtime
 *  drift (the stdlib signature types `name: string`), surfaced as a defect rather than resolved to junk. */
function nameOf(argument: Value | null): string {
  if (argument !== null && argument.kind === "record") {
    const name = argument.fields.name;
    if (name !== undefined && name.kind === "string") return name.value;
  }
  throw new Error("oauth.token: the name argument is missing (compiler/runtime drift — a bug)");
}

/** The `{ name }` record an oauth-reactor `prelude.oauth.authorize` escalation carries — the credential
 *  name only, never token material. It carries NO url: a configured credential authenticates against an
 *  operator-registered endpoint, which is the acquisition flow's business, not something to show a human as
 *  a "server". The presentation renders its url as `null` (a genuine absence). */
function authorizeArgument(name: string): Value {
  return { kind: "record", fields: { name: { kind: "string", value: name } } };
}
