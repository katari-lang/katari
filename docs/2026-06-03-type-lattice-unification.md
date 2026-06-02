# Type-lattice unification (object / data / record · tuple / array)

Status: design agreed 2026-06-03. Precedes the generics phase.

## Principle

One refinement rule organizes the whole lattice: **a precise / structural /
nominal type is a subtype of its more-general counterpart**, covariantly.

| precise            | <: | general            | axis        |
| ------------------ | -- | ------------------ | ----------- |
| `1` / `"s"`        |    | `integer`/`string` | scalar (existing) |
| `data foo(x: A)`   |    | `{x: A}` (object)  | nominal → structural |
| `{a: A, b: B}`     |    | `record[A ∪ B]`    | object → record |
| `[A, B]` (tuple)   |    | `array[A ∪ B]`     | tuple → array |

So `data <: object <: record` and `tuple <: array` become **subtype edges
inside one layer** (just like `integer <: number` already are), instead of
the current independent layers.

`$constructor` stays hidden from users: the compiler types a value as its
`data` type; the object view is reached only via the subtype edge. A `data`
value is a tagged object; constructor patterns check the tag, object
patterns (`{x = x}`) match structurally (and so match any compatible data).

## Normalized representation

### Map layer (object / record / data)

No per-field optional on objects: a bare object is a plain `Map Text NT`.
Omittable *callable arguments* are already handled by the default-argument
feature on the function-type side (param optionality), so objects don't need
their own optional fields. Field access `x.label` generates `t1 <: {label:
t2}` with `label` required (no `null` leakage); reading a maybe-absent field
is done by narrowing, not direct access.

```
MapSlot = MapSlot { dataFields :: Map QualifiedName (Map Text NT)   -- data names → their (concrete) fields, inline
                  , bare       :: BareObj }
BareObj = NoObj | ClosedObj (Map Text NT) | RecordObj NT             -- object (closed) | record[V]
```

- Data names are kept **separate** from `bare` (not absorbed into the record).
  This keeps `union` / `intersect` env-free; the slight loss of canonicality
  (`foo | record[V]` is not collapsed to a single `record`) is harmless.
- Data field types are **concrete** (declared, no vars), stored **inline** in
  `dataFields` so subtyping (`data <: object`, rule ii) and absorption read
  them directly. They are filled once when a `SemanticTypeData` is normalized:
  `normaliseSemantic` is the only function threaded a read-only
  `Map QualifiedName (Map Text NT)` env (built from the data defs).

Subtype `L <: R`:

| L \ R          | `Closed(oR, dR)`                                   | `Homogeneous vR`                          |
| -------------- | ------------------------------------------------- | ----------------------------------------- |
| `Closed(oL,dL)`| (∀q∈dL: `q∈dR` ∨ `obj(q) <: oR`) ∧ `oL <: oR`     | every field of `oL` and of each `q∈dL` `<: vR` |
| `Homogeneous vL` | ⊥ (a record is not a specific object/data)      | `vL <: vR`                                |

`oL <: oR` is object width subtyping (for each label of `oR`: present in `oL`
with a subtype).

Union (join):
- `Closed(o1,d1) ∪ Closed(o2,d2) = Closed(o1 ⊔ o2, d1 ∪ d2)` where object ⊔ =
  common labels, types unioned.
- `Closed(o,d) ∪ Homogeneous V = Homogeneous (V ∪ ⋃values(o) ∪ ⋃fields(d))`.
- `Homogeneous V1 ∪ Homogeneous V2 = Homogeneous (V1 ∪ V2)`.

Intersection (meet):
- `Closed(o1,d1) ∩ Closed(o2,d2) = Closed(o1 ⊓ o2, d1 ∩ d2)` where object ⊓ =
  union of labels, common intersected, single-side inherited.
- `Closed(o,d) ∩ Homogeneous V = Closed(eachField ⊓ V, …)` (impose the record
  bound on each field).
- `Homogeneous V1 ∩ Homogeneous V2 = Homogeneous (V1 ∩ V2)`.

### Sequence layer (tuple / array)

Tuples are purely structural — treat them like objects with positions as
labels, collapsed to a single canonical tuple (no per-arity map):

```
BareSeq = NoSeq
        | Tuple [NT]    -- positional; collapses on union/intersect (positions = labels)
        | Array NT      -- homogeneous; the layer top — absorbs all tuples
```

- `tuple[A,B] | array[C] = array[A ∪ B ∪ C]` (tuple absorbed).
- **Union** collapses to the common prefix (shorter length, positions
  unioned): `tuple[A,B] | tuple[C,D,E] = tuple[A∪C, B∪D]`. **Intersection**
  extends to all positions (longer length, common intersected, trailing
  kept): `tuple[A,B] ∩ tuple[C,D,E] = tuple[A∩C, B∩D, E]`. (Dual of object
  width, exactly as for `{l: T}`.)
- Subtype: a longer tuple refines a shorter prefix (`tuple[A,B,C] <:
  tuple[A,B]`); `tuple <: array` = each element `<: a`; `array </: tuple`;
  `array a <: array a'` = `a <: a'`.

## Decompose (constraints with variables)

Unions split via the existing left-union→all / right-union→branch machinery.
Per single-shape pair (`fields(q)` = data q's declared field object):

- `Data q <: Data q'` → settle if `q=q'`, else ⊥.
- `Data q <: Object m'` → `Object(fields q) <: Object m'` (expand to object view).
- `Object m <: Data q'` → ⊥. `Record _ <: Data q'` → ⊥.
- `Object m <: Object m'` → width (existing `decomposeObject`).
- `Object m <: Record v'` / `Data q <: Record v'` → each field `<: v'`.
- `Record v <: Record v'` → `v <: v'`. `Record _ <: Object _` → ⊥.
- `Tuple ts <: Tuple ts'` → per-position + width (existing).
- `Tuple ts <: Array a'` → each `t <: a'`. `Array a <: Array a'` → `a <: a'`.
- `Array _ <: Tuple _` → ⊥.

## Surface syntax

- **Object type**: `{x: T, y: U}` is now writable as a type (new
  `TypeObject`). `record[V]` stays for homogeneous.
- **Object literal**: `{x = 0, y = "a"}` infers `object{x: 0, y: "a"}` (precise),
  widening to `record[…]` on demand — not `record[V]` by default.
- **Tuple literal**: moves from `(0, 1)` to `[0, 1]`. Every value written with
  the array `[...]` syntax infers as a **tuple** by default; it is assignable
  to an `array` via the `tuple <: array` edge. `(...)` becomes grouping-only.

## Schema

`additionalProperties` is always `true` (permit). Even a `data` value may
carry extra properties, so the AI-tool-calling schema should not forbid them.

## IR / runtime

object / data / record share a layer and tuple / array share a layer, so the
runtime `Value` model and `match` need review: tuple and array values are both
ordered sequences (likely one `Value` kind); object / data / record are
string-keyed maps (data carries `$constructor`). Match patterns must treat the
unified views (an object pattern matching a data value, a tuple pattern over an
array-shaped value).

## Ordering

1. NormalizedType representation (map + seq slots) + typechecker
   (subtype / decompose / union / intersect).
2. Surface: object type syntax; tuple `[]` migration; object-default literal
   inference.
3. Schema (`additionalProperties: true`).
4. IR / runtime (Value + match) adjustments.
5. Migration (samples, tests, goldens). Then generics.
