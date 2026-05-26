// Project-wide JSON type. Anything we serialize to / from JSON
// (snapshot payloads, schema bundles, IR module bodies) is shaped to
// fit this recursive structural type so downstream JSON persistence
// helpers can type-check their input without resorting to `unknown` /
// `any`.
//
// Why duplicate the obvious shape: the bare `unknown` lets callers
// pass functions, symbols, BigInts, Date instances, etc. — all of which
// serialise to surprising values (or throw). `Json` constrains values
// to what `JSON.stringify` actually round-trips losslessly.

export type Json =
  | null
  | string
  | number
  | boolean
  | Json[]
  | { readonly [key: string]: Json | undefined };
