# KATARI Language Specification - Type System

## 型の分類

KATARI の型は以下の階層 (kind) に分類される。

| Kind | 型 | リテラル型 |
|------|----|-----------|
| Null | `null` | `null` |
| Boolean | `boolean` | `true`, `false` |
| Numeric | `integer`, `number` | `0`, `1`, ..., `3.14`, ... |
| String | `string` | `"hello"`, `"world"`, ... |
| Array | `array[T]` | なし |
| Object | `{x: T, y: U, ...}` | なし |

**注意**: Integer と Number は同じ "Numeric" kind に属する。Integer は Number のサブタイプである。Integer リテラル (`0`, `1`, ...) と Number リテラル (`3.14`, ...) は Numeric kind 内で区別して管理される。

特殊な型:
- `never` -- ボトム型。全ての型のサブタイプ。
- `unknown` -- トップ型。全ての型のスーパータイプ。

## 型階層 (Subtyping)

### 基本的な部分型関係

```
never <: T        (任意の T)
T <: unknown      (任意の T)
```

### プリミティブ型の部分型関係

```
null    <: null
true    <: boolean
false   <: boolean
0       <: integer
1       <: integer
...
integer <: number
3.14    <: number
"hello" <: string
...
```

**重要**: `integer <: number` である。正規化後の表現では integer と number は同一の NumericKind 内で integerPart と numberPart として管理される。integer リテラル型は integerPart に属し、number リテラル型 (小数) は numberPart に属する。

### 配列の部分型関係

```
array[S] <: array[T]  iff  S <: T
```

配列は共変 (covariant) である。

### Object の部分型関係

```
{x: S, y: T, ...} <: {x: S', ...}  iff  S <: S' (共通フィールドについて)
```

Object は**幅方向に共変**である。左辺にフィールドが多い (= より具体的) 方がサブタイプ。

Optional フィールドの部分型チェック時:
- `x?: T` は `x: T | null` として扱う。
- つまり `{x?: integer}` は `{x: integer | null}` と同等。

## 型の正規化 (Normalization)

全ての型は **正規化された形式 (NormalizedType)** に変換される。NormalizedType は以下の直和型 (sum type) である:

```
NormalizedType = Unknown
              | DISC { discriminator: string, mapping: Map<LiteralValue, NormalFields> }
              | NormalFields { ... }
```

### Unknown

トップ型。全ての型のスーパータイプ。

### DISC

判別可能 union を表す。詳細は 03-discriminated-unions.md を参照。DISC は NormalizedType のトップレベルのバリアントである。

### NormalFields

通常の型を kind ごとに保持する構造:

```
NormalFields = {
  nullKind:    null | absent,
  booleanKind: BooleanKind | absent,
  numericKind: NumericKind | absent,
  stringKind:  StringKind | absent,
  arrayKind:   NormalizedType | absent,   // array の要素型
  objectKind:  ObjectFields | absent,
}
```

全ての kind が absent の NormalFields は `never` を表す。

### 各 Kind の定義

```
BooleanKind = Full                -- boolean
            | Literals(Set<bool>) -- true, false, or both

NumericKind = {
  integerPart: Full | Literals(Set<int>) | absent,
  numberPart:  Full | Literals(Set<float>) | absent,
}
-- integerPart と numberPart の両方が absent の場合、numericKind 自体が absent となる。
-- NumericKind の意味: integerPart と numberPart の和集合を表す。
-- 値が NumericKind にマッチするとは、integerPart にマッチする OR numberPart にマッチすることである。

StringKind  = Full                -- string
            | Literals(Set<string>) -- "hello", "world", ...

ObjectFields = {
  fields: Map<string, FieldInfo>
}

FieldInfo   = {
  type: NormalizedType,
  optional: boolean,
  annotation: string | absent,
}
```

### integer <: number の表現

`integer <: number` の関係は NumericKind 内で以下のように成り立つ:
- `IntegerPart.Full <: NumberPart.Full` = true
- `IntegerPart.Literals(s) <: NumberPart.Full` = true
- `IntegerPart._ <: NumberPart.Literals(_)` = false (integer リテラルは number リテラルではない)

### 正規化のルール

- `unknown` は `Unknown` バリアントになる。
- `never` は全ての kind が absent の `NormalFields` になる。
- 判別可能 union の条件を満たす場合は `DISC` バリアントになる (03-discriminated-unions.md 参照)。
- それ以外は `NormalFields` の対応する kind に格納される。

## Union の正規化

Union 型 `S | T` は、S と T をそれぞれ正規化した後、バリアントの組み合わせに応じてマージする。

### NormalizedType バリアント間の Union 規則

```
Unknown | T           = Unknown         (任意の T)
T | Unknown           = Unknown

DISC | DISC (同一 discriminator):
  → mapping をマージする。
    重複するキーについては、対応する NormalFields 同士を union する。
    重複しないキーはそのまま含める。
  → 結果は DISC。

DISC | DISC (異なる discriminator):
  → 両方の DISC の全バリアントを NormalFields に集約し、NormalFields 同士の union として正規化する。

DISC | NormalFields:
  → DISC の全バリアントの NormalFields を NormalFields に集約し、
    その結果と右辺の NormalFields を union する。
  → 結果は NormalFields (DISC 情報は失われる)。

NormalFields | NormalFields:
  → kind ごとにマージする (後述)。
```

### NormalFields 同一 kind のマージ規則

```
-- Boolean
Full | Literals(_)       = Full
Literals(s1) | Literals(s2) = Literals(s1 ∪ s2)
  -- {true, false} の場合は Full に昇格

-- Numeric (NumericKind)
NumericKind union:
  integerPart: union of integer parts
  numberPart:  union of number parts

  IntegerPart union rules:
    Full | Literals(_)       = Full
    Literals(s1) | Literals(s2) = Literals(s1 ∪ s2)

  NumberPart union rules:
    Full | Literals(_)       = Full
    Literals(s1) | Literals(s2) = Literals(s1 ∪ s2)

-- String
Full | Literals(_)       = Full
Literals(s1) | Literals(s2) = Literals(s1 ∪ s2)

-- Array
array[S] | array[T]      = array[S | T]

-- Object (ObjectFields)
{fields1} | {fields2}    = {共通フィールドのみ残す}
  -- 共通フィールドの型は union を取る
  -- 片方にのみ存在するフィールドは消える
  -- どちらかが optional なら optional

-- DISC → 03-discriminated-unions.md 参照
```

**Object union の詳細**:

```
{type: 0, x: integer} | {type: 1, y: string}
→ {type: 0 | 1}
// x, y は共通でないため消える
```

```
{a: integer, b: string} | {a: string, b: integer}
→ {a: integer | string, b: string | integer}
```

## Intersection の正規化

Intersection 型 `S & T` は、S と T をそれぞれ正規化した後、バリアントの組み合わせに応じてマージする。

### NormalizedType バリアント間の Intersection 規則

```
Unknown & T           = T              (任意の T)
T & Unknown           = T

DISC & DISC (同一 discriminator):
  → mapping の各キーについて intersection を取る。
    両方に存在するキーについては、対応する NormalFields 同士を intersect する。
    片方にのみ存在するキーは削除する。
  → 結果のバリアントが 0 個なら never。
  → 結果は DISC。

DISC & DISC (異なる discriminator):
  → 左辺の各バリアントと右辺の各バリアントの全ペアについて intersection を計算し、
    有効な (never でない) ものを保持する。

DISC & NormalFields:
  → DISC の各バリアントの NormalFields と右辺の NormalFields を intersect する。
  → 結果が never でないバリアントのみ残す。
  → 結果は DISC。

NormalFields & NormalFields:
  → kind ごとにマージする (後述)。
```

### NormalFields 同一 kind のマージ規則

```
-- Boolean
Full & Literals(s)       = Literals(s)
Literals(s1) & Literals(s2) = Literals(s1 ∩ s2)
  -- 空の場合、boolean kind は absent

-- Numeric (NumericKind)
NumericKind intersection:
  integerPart: intersection of integer parts
  numberPart:  intersection of number parts

  IntegerPart intersection rules:
    Full & Literals(s)       = Literals(s)
    Literals(s1) & Literals(s2) = Literals(s1 ∩ s2)
    -- 空の場合は absent

  NumberPart intersection rules:
    Full & Literals(s)       = Literals(s)
    Literals(s1) & Literals(s2) = Literals(s1 ∩ s2)
    -- 空の場合は absent

  Cross-interaction:
    integerPart と numberPart は共存可能。
    NumericKind の意味は integerPart と numberPart の和集合であるため、
    intersection 時にはそれぞれ独立に intersection を計算する。
    例: NumericKind{integerPart: Full, numberPart: Literals({3.14})}
        & NumericKind{integerPart: Literals({1,2}), numberPart: Full}
        = NumericKind{integerPart: Literals({1,2}), numberPart: Literals({3.14})}

-- String
Full & Literals(s)       = Literals(s)
Literals(s1) & Literals(s2) = Literals(s1 ∩ s2)

-- Array
array[S] & array[T]      = array[S & T]

-- Object (ObjectFields)
{fields1} & {fields2}    = {全フィールドを残す}
  -- 共通フィールドの型は intersection を取る
  -- 片方にのみ存在するフィールドはそのまま追加
  -- 両方 optional の場合のみ optional。片方でも必須なら必須
```

### 異なる kind 間の intersection

異なる kind 間の intersection は `never` となる (空集合)。例:

```
integer & string = never
boolean & null   = never
array[integer] & {x: integer} = never
```

## 部分型チェック (Subtyping Check)

部分型チェック `S <: T` は、両辺を正規化した後、NormalizedType のバリアントに応じて比較する。

### NormalizedType バリアント間の部分型規則

```
Unknown <: T       = T が Unknown の場合のみ true
T <: Unknown       = true (任意の T)

DISC <: DISC:
  → discriminator が同一であること。
  → 左辺の全キーが右辺に存在し、対応するバリアントについて NormalFields <: NormalFields。
  → discriminator が異なる場合は、左辺を NormalFields に集約してから比較。

DISC <: NormalFields:
  → DISC の全バリアントが NormalFields のサブタイプであること。

NormalFields <: DISC:
  → NormalFields がいずれかのバリアントのサブタイプであること。

NormalFields <: NormalFields:
  → kind ごとに比較する (後述)。
```

### NormalFields の kind ごとの部分型チェック

```
NormalFields(S) <: NormalFields(T)
  iff
  S.nullKind    <: T.nullKind    &&
  S.numericKind <: T.numericKind &&
  S.booleanKind <: T.booleanKind &&
  S.stringKind  <: T.stringKind  &&
  S.arrayKind   <: T.arrayKind   &&
  S.objectKind  <: T.objectKind
```

ここで absent は never として扱い、`never <: T` は常に真。

### Kind 内の部分型

```
-- Boolean
Literals(s) <: Full       = true
Literals(s1) <: Literals(s2) = s1 ⊆ s2
Full <: Literals(_)       = false

-- Numeric (NumericKind)
NumericKind(S) <: NumericKind(T):
  以下の 2 条件を両方満たすこと:

  1. S.integerPart の全ての値が T に含まれること:
     S.integerPart <: (T.integerPart ∪ T.numberPart)
     -- integer <: number なので、T.integerPart だけでなく T.numberPart も受け入れ先になる。
     具体的には:
       S.integerPart absent → true
       S.integerPart Full → T.integerPart が Full、または T.numberPart が Full
       S.integerPart Literals(s) → s ⊆ T.integerPart の集合 (T.integerPart が Full なら true)、
                                    または T.numberPart が Full

  2. S.numberPart の全ての値が T.numberPart に含まれること:
     S.numberPart <: T.numberPart
     -- number は integer のスーパータイプなので、number の値は numberPart にのみ属する。
     具体的には:
       S.numberPart absent → true
       S.numberPart Full → T.numberPart が Full
       S.numberPart Literals(s) → s ⊆ T.numberPart の集合 (T.numberPart が Full なら true)

-- String (Boolean と同様)
Literals(s) <: Full       = true
Literals(s1) <: Literals(s2) = s1 ⊆ s2
Full <: Literals(_)       = false

-- Array
array[S] <: array[T]  iff  S <: T

-- Object → 後述のフィールド比較ルール
```

### Object の部分型チェック

```
ObjectFields(fields_s) <: ObjectFields(fields_t)
  iff
  T の全フィールド f について:
    f が S にも存在し、S.f.type <: T.f.type
    かつ T.f が必須なら S.f も必須 (optional でない)
```

S に T にないフィールドがあっても問題ない (幅方向の共変性)。

### unknown / never の扱い

```
T <: Unknown           = true  (任意の T)
never <: T             = true  (任意の T)
Unknown <: T           = T が Unknown の場合のみ true
T <: never             = T が never の場合のみ true
```

Unknown は NormalizedType の独立したバリアントである:
- `Unknown <: T` は T が Unknown の場合のみ true
- `T <: Unknown` は常に true

## 数値型の演算子と戻り値型

| 演算 | オペランド型 | 結果型 |
|------|-------------|--------|
| `+`, `-`, `*`, `%` | `integer, integer` | `integer` |
| `+`, `-`, `*`, `%` | `number, number` (integer 含む) | `number` |
| `/` | `integer, integer` | `number` |
| `/` | `number, number` | `number` |
| `<`, `>`, `<=`, `>=` | `number, number` | `boolean` |
| `==`, `!=` | `T, T` | `boolean` |
| `&&`, `\|\|` | `boolean, boolean` | `boolean` |
| `!` | `boolean` | `boolean` |
| `-` (単項) | `integer` | `integer` |
| `-` (単項) | `number` | `number` |
| `++` | `string, string` | `string` |
| `++` | `array[S], array[T]` | `array[S \| T]` |

**注意**: `integer / integer` は `number` を返す (整数除算ではない)。

## Optional フィールド

Object 型のフィールドには `?` を付けて optional にできる。

```katari
type User = {
  name: string,
  email?: string
}
```

### Optional フィールドのアクセス

Optional フィールド `x?: T` にアクセスすると、結果の型は `T | null` となる。フィールドが存在しない場合、ランタイムでは `null` が返る。

### Union / Intersection での Optional

Union 時:
- 片方にのみフィールドがある → そのフィールドは消える (共通フィールドのみ残る)
- 両方にフィールドがあり、片方が optional → 結果は optional、型は union

Intersection 時:
- 片方にのみフィールドがある → そのまま追加
- 両方にフィールドがあり、両方 optional → 結果は optional、型は intersection
- 片方が必須 → 結果は必須、型は intersection

## 型エイリアス

```katari
type UserId = integer
type Response = {status: integer, body: string}
```

型エイリアスは展開されて使用される。再帰的な型エイリアスは禁止。
