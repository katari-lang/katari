// 3 つの module endpoint。bus が routing に使う識別子。
//
// 「endpoint = 名前」の関係はあえて固定しない。複数 API/FFI module を同居
// させたければ別の endpoint 文字列を割り当てれば良い。デフォルトはこの 3 つ。
//
// CORE_ENDPOINT is re-exported from engine/endpoint.ts (rather than
// redeclared) so the engine's `createState` default and the public
// host-facing constant can never drift apart.

import { CORE_ENDPOINT, endpoint, type Endpoint } from "../engine/endpoint.js";

export { CORE_ENDPOINT };
export const API_ENDPOINT: Endpoint = endpoint("api://main");
export const FFI_ENDPOINT: Endpoint = endpoint("ext://ffi");
