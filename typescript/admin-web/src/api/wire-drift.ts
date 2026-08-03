// Drift trip-wire: the handwritten wire types in `./types` are a hand-maintained VIEW of the runtime's
// HTTP API, so they can silently fall out of step with it (as `ReactorKind` did when the runtime grew a
// `region` reactor — a drift this file now catches). It re-derives each endpoint's real response shape
// from the runtime's own `AppType` — the same route type the typed RPC client (`hc`) binds to — and
// asserts, at the type level, that the runtime's actual response is usable as the view `./types` declares.
// A mismatch is a compile error, so `pnpm run typecheck` (which runs this file under `tsconfig.drift.json`)
// fails on drift.
//
// It is a Node-flavoured, source-level reference into the runtime package, so it lives OUTSIDE the app's
// own (browser) `tsconfig.json` — it is `import type`-only and is never bundled by Vite. See
// `tsconfig.drift.json` for how `@katari-lang/runtime` and `hono/client` are resolved from the runtime's
// own install without adding either to the app's dependencies.
//
// SCOPE — the endpoints whose payload carries a free-form `Json` / `JsonSchema` value are deliberately
// NOT asserted here: `hono` bakes a `JSONParsed<…>` transform into every response type, and resolving
// that transform over the runtime's recursive `Json` type overflows the compiler's type-instantiation
// limit (`TS2589`) the instant the wire type is referenced — there is no way to reach a single field
// around it. That excludes `runs` (`Run`), `runs/:id/escalations` (`RunEscalationAudit`), `escalations`
// (`Escalation`), `runs/:id/events` (`RunEventsPage`), `agents` / `agents/:name` (`AgentList` /
// `AgentDetail`), and `store/:key` (`StoreEntryDetail`). Their drift-prone reactor / run-state ENUMS are
// still guarded transitively: `RunTree` (asserted below) embeds `ReactorKind` (as its `reactor` / node
// `kind`) and `RunState` (as its `state`), so a change to either fails `_runTree`.

import type { AppType } from "@katari-lang/runtime";
import type { InferRequestType, InferResponseType } from "hono/client";
import { hc } from "hono/client";
import type {
  Credential,
  EnvEntry,
  EnvEntryDetail,
  FileEntry,
  HeadSnapshot,
  Health,
  OauthClient,
  OauthClientInput,
  Project,
  RunTree,
  SnapshotSummary,
  StoreEntrySummary,
} from "./types";

// The typed RPC client, purely as the carrier of `AppType`'s per-route types (no request is ever made).
const client = hc<AppType>("");
type Client = typeof client;

// Peel the `{ ok: true, data }` success envelope off an endpoint's inferred response to get the payload.
type Unwrap<T> = Extract<T, { ok: true }> extends { data: infer D } ? D : never;
type Data<Endpoint> = Unwrap<InferResponseType<Endpoint>>;

// The drift assertions. `Resp` (responses): the runtime's actual body must be assignable to the view
// `./types` reads — this catches a field the view expects that the runtime dropped or retyped, and a
// widened enum (e.g. a new reactor). It intentionally allows the runtime to carry EXTRA fields the view
// ignores, since the view is a deliberate subset (e.g. `HeadSnapshot` omits the snapshot row's
// `projectId` / `sidecarBundle`). `Req` (request bodies): the body the app SENDS must be accepted by the
// route's input schema — the reverse direction. `Expect<T>` forces the boolean to be `true`.
type Resp<Endpoint, View> = [Data<Endpoint>] extends [View] ? true : false;
type Req<Body, Endpoint> =
  InferRequestType<Endpoint> extends { json: infer J }
    ? [Body] extends [J]
      ? true
      : false
    : false;
type Expect<T extends true> = T;

type V = Client["api"]["v1"];
type P = V["projects"][":projectId"];

type _health = Expect<Resp<V["health"]["$get"], Health>>;
type _projectList = Expect<Resp<V["projects"]["$get"], Project[]>>;
type _project = Expect<Resp<P["$get"], Project>>;
type _projectCreate = Expect<Resp<V["projects"]["$post"], Project>>;
type _snapshotList = Expect<Resp<P["snapshots"]["$get"], SnapshotSummary[]>>;
type _headSnapshot = Expect<Resp<P["snapshots"]["head"]["$get"], HeadSnapshot>>;
type _runTree = Expect<Resp<P["runs"][":runId"]["tree"]["$get"], RunTree>>;
type _fileList = Expect<Resp<P["files"]["$get"], FileEntry[]>>;
type _envList = Expect<Resp<P["env"]["$get"], EnvEntry[]>>;
type _envEntry = Expect<Resp<P["env"][":key"]["$get"], EnvEntryDetail>>;
type _storeList = Expect<Resp<P["store"]["$get"], StoreEntrySummary[]>>;
type _credentials = Expect<Resp<P["credentials"]["$get"], { credentials: Credential[] }>>;
type _oauthClients = Expect<Resp<P["oauth-clients"]["$get"], { clients: OauthClient[] }>>;
type _oauthClientPut = Expect<Req<OauthClientInput, P["oauth-clients"][":name"]["$put"]>>;
// The trace SWEEP is asserted even though the trace READ is not: its payload is the swept count beside
// the run's identity, with no `Json` in it, so the transform that defeats the read resolves here.
type _runEventsClear = Expect<
  Resp<P["runs"][":runId"]["events"]["$delete"], { id: string; deleted: number }>
>;

// Every assertion is referenced here so an unused-type prune can never quietly drop a check.
export type WireDriftChecks = [
  _health,
  _projectList,
  _project,
  _projectCreate,
  _snapshotList,
  _headSnapshot,
  _runTree,
  _fileList,
  _envList,
  _envEntry,
  _storeList,
  _credentials,
  _oauthClients,
  _oauthClientPut,
  _runEventsClear,
];
