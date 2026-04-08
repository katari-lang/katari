# KATARI Language Specification - Discriminated Unions

## 概要

判別可能 union (Discriminated Union) は、`uniq` キーワードを用いて判別可能な object の union である。通常の object union では共通でないフィールドの情報が失われるが、判別可能 union ではそれぞれのバリアントの完全な型情報が保持される。

## DISC 型の構造

DISC は NormalizedType のトップレベルのバリアントである。内部的には以下の構造で保持される:

```
NormalizedType = Unknown
              | DISC { discriminator: string, mapping: Map<LiteralValue, NormalFields> }
              | NormalFields { ... }
```

DISC のバリアント:

```
DISC {
  discriminator: string,                        // 判別フィールド名
  mapping: Map<LiteralValue, NormalFields>,     // リテラル値 → NormalFields
}
```

各 mapping のバリアントは NormalFields であり、通常は objectKind が設定されている。

例:

```katari
type Shape = {uniq kind: "circle", radius: number}
           | {uniq kind: "rect", width: number, height: number}
```

内部表現:

```
DISC {
  discriminator: "kind",
  mapping: {
    "circle" → NormalFields {
      objectKind: ObjectFields {
        fields: { kind: "circle", radius: number }
      }
    },
    "rect" → NormalFields {
      objectKind: ObjectFields {
        fields: { kind: "rect", width: number, height: number }
      }
    }
  }
}
```

## DISC 型の成立条件

object の union が DISC 型として扱われるには、以下の**全て**を満たす必要がある:

1. union の全要素が object 型である
2. 全要素が `uniq` プロパティを持つ
3. 全要素の `uniq` プロパティが同一のフィールド名を指す
4. `uniq` プロパティの値が全てリテラル型である
5. `uniq` プロパティは optional でない
6. 全要素のリテラル値が互いに異なる

条件を満たす場合、結果は NormalizedType の `DISC` バリアントとなる。
条件を満たさない場合、`uniq` は無視され、NormalizedType の `NormalFields` バリアントとして正規化される (情報が落ちる)。

### uniq の制約

各 object 型に付けられる `uniq` は**高々 1 つ**である。

```katari
// OK: 各バリアントに uniq が 1 つ
type A = {uniq type: 0, x: integer} | {uniq type: 1, y: string}

// NG: 1 つの object に uniq が 2 つ (コンパイルエラー)
type B = {uniq type: 0, uniq tag: "a"}
```

## DISC 型の部分型チェック

### DISC <: NormalFields

```
DISC { mapping: { l1: nf1, l2: nf2, ... } } <: NormalFields(T)
  iff
  nf1 <: T && nf2 <: T && ...
```

全バリアントの NormalFields が T のサブタイプであれば、DISC 全体も T のサブタイプ。

### NormalFields <: DISC

```
NormalFields(T) <: DISC { mapping: { l1: nf1, l2: nf2, ... } }
  iff
  T <: nf1 || T <: nf2 || ...
```

T がいずれかのバリアントの NormalFields のサブタイプであれば、T は DISC のサブタイプ。

### DISC <: DISC

```
DISC { discriminator: d1, mapping: { l1: s1, l2: s2, ... } }
  <:
DISC { discriminator: d2, mapping: { l1': t1', l2': t2', ... } }
```

1. `d1 == d2` でなければならない (discriminator が同一)
2. 左辺の全キー `l1, l2, ...` が右辺に存在する
3. 対応するバリアントについて `s_i <: t_i` (NormalFields 同士の部分型チェック)

条件 1 または 2 が満たされない場合: 左辺を NormalFields に集約 (全バリアントの union) してから、右辺と比較する。

## Union と DISC

### DISC 同士の union (同一 discriminator)

```
DISC { d: "kind", mapping: { "a": nf_a } } | DISC { d: "kind", mapping: { "b": nf_b } }
→ DISC { d: "kind", mapping: { "a": nf_a, "b": nf_b } }
```

同じ discriminator で、キーが衝突しなければマージ可能。

キーが衝突する場合 (同じ discriminator 値を持つバリアントが両方にある場合):

- 衝突するバリアントの NormalFields を union で合成する。

```
DISC { d: "kind", mapping: { "a": nf_a1, "b": nf_b } }
  | DISC { d: "kind", mapping: { "a": nf_a2, "c": nf_c } }
→ DISC { d: "kind", mapping: {
    "a": nf_a1 | nf_a2,    // NormalFields 同士の union
    "b": nf_b,
    "c": nf_c
  } }
```

### DISC 同士の union (異なる discriminator)

discriminator が異なる場合、DISC として維持できない。両方の DISC の全バリアントを NormalFields に集約し、NormalFields 同士の union として正規化する。

```
DISC { d: "kind", mapping: { "a": nf_a, "b": nf_b } }
  | DISC { d: "type", mapping: { 0: nf_0, 1: nf_1 } }
→ NormalFields(nf_a | nf_b | nf_0 | nf_1)
```

### DISC と NormalFields の union

DISC の全バリアントを NormalFields に集約してから、NormalFields 同士の union として正規化する (DISC 情報は失われる)。

```
DISC { d: "kind", mapping: { "a": nf_a, "b": nf_b } } | NormalFields(nf_c)
→ NormalFields(nf_a | nf_b | nf_c)
```

## Intersection と DISC

### DISC 同士の intersection (同一 discriminator)

mapping の各キーについて intersection を取る。両方に存在するキーについては、対応する NormalFields 同士を intersect する。片方にのみ存在するキーは削除する。

```
DISC { d: "kind", mapping: { "a": nf_a1, "b": nf_b } }
  & DISC { d: "kind", mapping: { "a": nf_a2, "c": nf_c } }
→ DISC { d: "kind", mapping: {
    "a": nf_a1 & nf_a2     // NormalFields 同士の intersection
  } }
// "b" と "c" は片方にのみ存在するため削除
```

結果のバリアントが 0 個、または全てのバリアントの NormalFields が never の場合、結果は never となる。

### DISC 同士の intersection (異なる discriminator)

左辺の各バリアントと右辺の各バリアントの全ペアについて intersection を計算し、有効な (never でない) ものを保持する。

```
DISC { d: "kind", mapping: { "a": nf_a, "b": nf_b } }
  & DISC { d: "type", mapping: { 0: nf_0, 1: nf_1 } }
→ 有効な intersection が存在するペアのみ保持。
  結果の構造はペア数と条件による。
```

### DISC と NormalFields の intersection

DISC の各バリアントの NormalFields と右辺の NormalFields を intersect する。結果が never でないバリアントのみ残す。

```
DISC { d: "kind", mapping: { "a": nf_a, "b": nf_b } } & NormalFields(nf_c)
→ DISC { d: "kind", mapping: {
    "a": nf_a & nf_c,      // never でなければ残す
    "b": nf_b & nf_c       // never でなければ残す
  } }
```

## Match 式と型引き算

match 式は、DISC 型のパターンマッチングにおいて、各 case で型を「引いていく」ことで網羅性チェックを行う。

### パターンから型を生成する

各パターンに対して、そのパターンが受理する正規化された型を生成する:
生成される型の意味は "この型であればこのパターンに必ずマッチする。" である (逆は必ずしも真でない)。

| パターン                        | 生成される型                                                              |
| ------------------------------- | ------------------------------------------------------------------------- |
| `x` (変数)                      | `Unknown`                                                                 |
| `x : T`                         | `T`                                                                       |
| `null`                          | `null`                                                                    |
| `0`                             | `0`                                                                       |
| `"foo"`                         | `"foo"`                                                                   |
| `true`                          | `true`                                                                    |
| `boolean(x)`                    | `boolean`                                                                 |
| `integer(x)`                    | `integer`                                                                 |
| `number(x)`                     | `number`                                                                  |
| `string(x)`                     | `string`                                                                  |
| `{foo = p1, bar = p2}`          | `NormalFields { objectKind: {foo: type(p1), bar: type(p2)} }`             |
| `{uniq kind = "circle", r = x}` | `DISC { d: "kind", mapping: { "circle": NormalFields{objectKind: {kind: "circle", r: unknown}} } }` |
| `[p1, p2, p3]`                  | `NormalFields { arrayKind: type(p1) & type(p2) & type(p3) }`             |

**DISC パターンの生成条件**: object パターン内にちょうど 1 つの `uniq` フィールドが存在し、そのフィールドがリテラルパターンである場合、DISC パターンとして型を生成する。

### 型引き算アルゴリズム

型引き算 `L - R` は、正規化された型 L から、パターンが受理する型 R を引く操作。

#### NormalizedType バリアント間の引き算

```
-- R が Unknown の場合、全て引く
L - Unknown = never

-- Unknown - R (R が Unknown でない場合)
Unknown - R = Unknown    (安全に倒す: unknown は引ききれない)

-- DISC - DISC (同一 discriminator)
DISC { d: d, mapping: M_L } - DISC { d: d, mapping: M_R }
  → 左辺の各マッピング (l, nf_l) について:
    l が M_R にもある場合: nf_l - M_R[l] を計算。結果が never なら、そのマッピングを削除。
    l が M_R にない場合: そのまま残す。
  → 全マッピングが削除されたら never。

-- DISC - DISC (異なる discriminator)
  → 両辺を NormalFields に集約してから引き算。

-- DISC - NormalFields
  → DISC を NormalFields に集約してから引き算。

-- NormalFields - DISC
  → DISC を NormalFields に集約してから引き算。

-- NormalFields - NormalFields
  → kind ごとに引き算 (後述)。
```

#### NormalFields の kind ごとの引き算

各 kind について独立に引き算する:

```
-- Boolean
BooleanKind(Full) - BooleanKind(Full) = absent
BooleanKind(Full) - BooleanKind(Literals(s)) = BooleanKind(Literals(全体 \ s))
  -- 引いた結果が空 → absent
BooleanKind(Literals(s1)) - BooleanKind(Literals(s2)) = BooleanKind(Literals(s1 \ s2))
  -- 引いた結果が空 → absent

-- Numeric (NumericKind)
NumericKind の引き算:
  integerPart: integerPart 同士の引き算
  numberPart:  numberPart 同士の引き算

  IntegerPart - NumberPart(Full) = absent    (安全に倒す: number は integer を含む)
  NumberPart - IntegerPart = NumberPart      (安全に倒す: number - integer = number)

  IntegerPart 引き算:
    Full - Full = absent
    Full - Literals(s) = Full              (安全に倒す: 有限集合を引いても Full のまま)
    Literals(s1) - Full = absent
    Literals(s1) - Literals(s2) = Literals(s1 \ s2)
      -- 空の場合は absent

  NumberPart 引き算:
    同上

-- String (Boolean と同様)
StringKind(Full) - StringKind(Full) = absent
StringKind(Full) - StringKind(Literals(s)) = StringKind(Full)   (安全に倒す)
StringKind(Literals(s1)) - StringKind(Literals(s2)) = StringKind(Literals(s1 \ s2))

-- Array
ArrayKind(S) - ArrayKind(T) = absent         (配列は中身で区別できないため全て引く)
  -- ※ 配列の要素型での区別はランタイムでは困難なため、保守的に全て引く

-- Object (ObjectFields)
ObjectFields(fields_L) - ObjectFields(fields_R):
  -- R にのみあるフィールドは無視
  -- L にのみあるフィールドはそのまま
  -- 共通フィールドについて、型を再帰的に引き算
  -- 全ての共通フィールドの型が never になったら、ObjectFields は absent
```

#### Optional フィールドの引き算

パターンから生成される型には optional フィールドは存在しない (パターンにはフィールドの有無を「任意」にする構文がないため)。

- 左辺 optional, 右辺にフィールドなし → optional のまま残る
- 左辺 optional, 右辺にフィールドあり → フィールド自体が消える (引かれる)

### 網羅性チェック

match 式の網羅性チェックは以下の手順で行う:

1. 被マッチ式の型 `T` を正規化する。
2. 各 case のパターンについて:
   a. パターンの受理型 `P` を生成する。
   b. 残り型を `T' = T - P` で計算する。
   c. T' が never なら網羅完了。残りの case は unreachable 警告。
   d. T' が never でなければ、T = T' として次の case へ。
3. 全 case 処理後、T が never でなければコンパイルエラー (非網羅的)。

### 例

```katari
type Result = {uniq ok: true, value: integer}
            | {uniq ok: false, error: string}

task process(r: Result) -> string {
  match r {
    case {uniq ok = true, value = v} => {
      // ここで残りは: DISC { d: "ok", mapping: {
      //   false: NormalFields{objectKind: {ok: false, error: string}}
      // } }
      to_string(v)
    }
    case {uniq ok = false, error = e} => {
      // ここで残りは: never (網羅完了)
      e
    }
  }
}
```

ネストした引き算の例:

```katari
type X = {uniq type: 0, x: integer | string} | {uniq type: 1, y: string}

task f(v: X) -> string {
  match v {
    case {uniq type = 0, x = integer(n)} => {
      // 残り: DISC { d: "type", mapping: {
      //   0: NormalFields{objectKind: {type: 0, x: string}},
      //   1: NormalFields{objectKind: {type: 1, y: string}}
      // } }
      to_string(n)
    }
    case {uniq type = 0, x = string(s)} => {
      // 残り: DISC { d: "type", mapping: {
      //   1: NormalFields{objectKind: {type: 1, y: string}}
      // } }
      s
    }
    case {uniq type = 1, y = y} => {
      // 残り: never
      y
    }
  }
}
```
