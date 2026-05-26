// Raw value type: a JSON-shaped subset used at the FFI / REST / sidecar
// boundary. This is the "schema-less" form that flows on the wire; the
// runtime converts to / from its internal `Value` tagged union at the
// boundary.

/** Raw value: a JSON-shaped subset (numbers, strings, booleans, null,
 * arrays, objects). Object shapes carrying a `$constructor` / `$agent`
 * discriminator are decoded into the corresponding 'Value' variant. */
export type RawValue =
  | number
  | string
  | boolean
  | null
  | RawValue[]
  | { [key: string]: RawValue };
