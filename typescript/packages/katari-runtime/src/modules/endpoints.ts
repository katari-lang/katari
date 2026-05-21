// The three module endpoints. Identifiers the bus uses for routing.
//
// The "endpoint = name" relationship is intentionally not fixed. If you
// want multiple API/FFI modules to coexist, just assign different endpoint
// strings. These three are the defaults.
//
// CORE_ENDPOINT is re-exported from engine/endpoint.ts (rather than
// redeclared) so the engine's `createState` default and the public
// host-facing constant can never drift apart.

import { CORE_ENDPOINT, endpoint, type Endpoint } from "../engine/endpoint.js";

export { CORE_ENDPOINT };
export const API_ENDPOINT: Endpoint = endpoint("api://main");
export const FFI_ENDPOINT: Endpoint = endpoint("ext://ffi");
