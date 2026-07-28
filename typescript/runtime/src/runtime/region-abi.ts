// The region handle ABI: the namespaced marker fields a `nursery[Scope, E]` / `fiber[Scope]` handle
// carries its identities under. A handle is minted by the region reactor (`actor/region-reactor.ts`) and
// read back by BOTH sides of the layering — the reactor routes a `fork` / `watch` / `cancel` by them, and
// the `fiber_id` prim (`engine/interop-prims.ts`) reads a fiber's public id straight off the handle with
// no reactor round-trip. The engine must not import actor code, so the layout cannot live in the reactor;
// it does not belong in the generic engine either (nothing in the engine's own machinery knows what a
// nursery is). It lives here instead: a region-owned module both layers import, so the one wire shape has
// one home.
//
// The keys live in the reserved `$katari_` namespace, disjoint from any user-authored record key, so a
// handle reads as a runtime value rather than user data. A handle carries plain string leaves and no
// reserved wire DISCRIMINATOR, so it crosses the wire as a bare record — `jsonToValue` reconstructs it
// with no decoding seam of its own.

/** The field a region nursery handle carries its scope identity under. */
export const NURSERY_SCOPE_FIELD = "$katari_region_scope";

/** The field a region fiber handle carries its runtime-minted fiber id under (alongside the scope). */
export const NURSERY_FIBER_FIELD = "$katari_region_fiber";
