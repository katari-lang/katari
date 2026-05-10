// 3 つの module endpoint。bus が routing に使う識別子。
//
// 「endpoint = 名前」の関係はあえて固定しない。複数 API/FFI module を同居
// させたければ別の endpoint 文字列を割り当てれば良い。デフォルトはこの 3 つ。

import { endpoint, type Endpoint } from "../engine/endpoint.js";

export const API_ENDPOINT: Endpoint = endpoint("api://main");
export const CORE_ENDPOINT: Endpoint = endpoint("core://main");
export const FFI_ENDPOINT: Endpoint = endpoint("ext://ffi");
