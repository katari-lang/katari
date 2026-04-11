# KATARI Language Specification - Type System

本仕様書は KATARI 言語の型システムを定義する。型の分類・正規化・部分型関係・判別可能 union・パターンマッチと網羅性チェック・JSON Schema 生成・ランタイム型タグ・エフェクト型の全領域を対象とする。

コンパイラ実装における ground truth は `Katari.Types` モジュール (`NormalizedType`, `subtypeNT`, `normalize` 等) および `Katari.Typechecker` モジュールである。

---

## 1. 型の分類

KATARI の型は以下のカテゴリに分類される。

### 1.1 プリミティブ型

| 型 | 説明 | 対応する AST |
|----|------|-------------|
| `null` | null 値の唯一の型 | `TNull` |
| `boolean` | 真偽値 (`true` または `false`) | `TBoolean` |
| `integer` | 整数 | `TInteger` |
| `number` | 数値 (integer を包含) | `TNumber` |
| `string` | 文字列 | `TString` |

**重要**: `integer` と `number` は同じ "Numeric" kind に属する。`integer` は `number` のサブタイプである。

### 1.2 特殊型

| 型 | 説明 | 対応する AST |
|----|------|-------------|
| `never` | ボトム型。全ての型のサブタイプ。値が存在しない。 | `TNever` |
| `unknown` | トップ型。全ての型のスーパータイプ。任意の値を受け入れる。 | `TUnknown` |

### 1.3 リテラル型

プリミティブ値を単一の値に限定する型。

| リテラル型 | 例 | 対応する AST |
|-----------|-----|-------------|
| Boolean リテラル | `true`, `false` | `TLitBool Bool` |
| Integer リテラル | `0`, `1`, `42` | `TLitInt Integer` |
| Number リテラル | `3.14`, `2.718` | `TLitNum Double` |
| String リテラル | `"hello"`, `"world"` | `TLitStr Text` |

リテラル型はそれぞれの基底型のサブタイプである:

```
true   <: boolean
false  <: boolean
42     <: integer <: number
3.14   <: number
"hello" <: string
```

### 1.4 配列型

```
array[T]
```

要素型 `T` を持つ配列。AST では `TArray Type` で表現される。

### 1.5 Object 型

```katari
{
  name: string,
  age?: integer,
  uniq kind: "circle",
  @"ユーザーのメールアドレス" email: string
}
```

Object 型は以下の種類のフィールドを持つ:

| フィールド種別 | 構文 | 説明 |
|--------------|------|------|
| 通常フィールド | `name: T` | 必須フィールド |
| Optional フィールド | `name?: T` | 省略可能なフィールド。アクセス時の型は `T \| null` |
| Uniq フィールド | `uniq name: T` | 判別フィールド。判別可能 union に使用 |
| アノテーション付き | `@"説明" name: T` | JSON Schema の `description` に変換される |

AST では `TObj [ObjField]` で表現される:

```haskell
data ObjField = ObjField
  { ofName :: Text,
    ofOptional :: Bool,
    ofUniq :: Bool,
    ofType :: Type,
    ofAnnot :: Maybe Text
  }
```

### 1.6 Union 型

```katari
T | U
```

`T` または `U` のいずれかの値を持つ型。AST では `TUnion [Type]` で表現される。

### 1.7 Intersection 型

```katari
T & U
```

`T` かつ `U` の両方を満たす値の型。AST では `TInter [Type]` で表現される。

### 1.8 型エイリアス

```katari
type UserId = integer
type Response = {status: integer, body: string}
```

ユーザー定義の名前付き型。AST では `TAlias Text` で表現される。型エイリアスは正規化時に展開される。

**制約**: 直接再帰・相互再帰ともに禁止される (コンパイルエラー)。

```katari
// NG: 直接再帰
type A = {child: A}

// NG: 相互再帰
type A = {b: B}
type B = {a: A}
```

---

## 2. 型の正規化 (Normalization)

全ての型は比較・部分型チェックの前に**正規化された形式 (NormalizedType)** に変換される。

### 2.1 NormalizedType の構造

```haskell
data NormalizedType
  = NTUnknown                  -- トップ型
  | NTDISC Discriminator       -- 判別可能 union
  | NTFields NormalFields      -- 通常の型 (kind ごとに保持)
```

### 2.2 NormalFields

各 kind を独立したフィールドとして保持する構造:

```haskell
data NormalFields = NormalFields
  { nfNull    :: Bool,               -- null kind の有無
    nfBoolean :: Maybe BoolKind,     -- boolean kind
    nfNumeric :: Maybe NumericKind,  -- numeric kind (integer + number)
    nfString  :: Maybe StringKind,   -- string kind
    nfArray   :: Maybe NormalizedType, -- 配列の要素型
    nfObject  :: Maybe ObjectFields  -- object kind
  }
```

全てのフィールドが absent (`False` / `Nothing`) の NormalFields は `never` を表す。

### 2.3 各 Kind の内部構造

#### BoolKind

```haskell
newtype BoolKind = BoolLits (Set Bool)
```

- `BoolLits {True, False}` = `boolean` (full)
- `BoolLits {True}` = `true`
- `BoolLits {False}` = `false`

#### NumericKind

```haskell
data NumericKind = NumericKind
  { nkInt :: IntPart,   -- integer 部分
    nkNum :: NumPart    -- number 部分 (非整数)
  }

data IntPart = IntAbsent | IntFull | IntLits (Set Integer)
data NumPart = NumAbsent | NumFull | NumLits (Set Double)
```

`integer` と `number` は同一の NumericKind 内で管理される:

| KATARI 型 | IntPart | NumPart |
|-----------|---------|---------|
| `integer` | `IntFull` | `NumAbsent` |
| `number` | `IntFull` | `NumFull` |
| `42` (integer リテラル) | `IntLits {42}` | `NumAbsent` |
| `3.14` (number リテラル) | `IntAbsent` | `NumLits {3.14}` |

NumericKind の意味は **IntPart と NumPart の和集合**である。値が NumericKind にマッチするとは、IntPart にマッチする **OR** NumPart にマッチすることである。

`integer <: number` の関係は以下のように表現される:
- `ntInteger` = `NumericKind IntFull NumAbsent`
- `ntNumber` = `NumericKind IntFull NumFull`

IntPart と NumPart の両方が absent の場合、numericKind 自体が absent (Nothing) となる。

#### StringKind

```haskell
data StringKind = StringFull | StringLits (Set Text)
```

- `StringFull` = `string`
- `StringLits {"hello", "world"}` = `"hello" | "world"`

#### ObjectFields

```haskell
newtype ObjectFields = ObjectFields
  { ofFields :: Map Text FieldInfo }

data FieldInfo = FieldInfo
  { fiType     :: NormalizedType,
    fiOptional :: Bool,
    fiAnnot    :: Maybe Text
  }
```

#### Discriminator (判別可能 union)

```haskell
data Discriminator = Discriminator
  { discField   :: Text,                    -- 判別フィールド名
    discMapping :: Map LitVal NormalFields   -- リテラル値 -> バリアント
  }

data LitVal
  = LVBool Bool
  | LVInt Integer
  | LVNum Double
  | LVStr Text
```

### 2.4 正規化のルール

`normalize :: Type -> Map Text NormalizedType -> NormalizedType` 関数が型を正規化する。第二引数は型エイリアスの環境 (完全修飾名 -> NormalizedType)。

| ソース型 | 正規化結果 |
|---------|-----------|
| `null` | `NTFields {nfNull = True, ...}` |
| `boolean` | `NTFields {nfBoolean = Just (BoolLits {True, False}), ...}` |
| `integer` | `NTFields {nfNumeric = Just (NumericKind IntFull NumAbsent), ...}` |
| `number` | `NTFields {nfNumeric = Just (NumericKind IntFull NumFull), ...}` |
| `string` | `NTFields {nfString = Just StringFull, ...}` |
| `never` | `NTFields {全て absent}` |
| `unknown` | `NTUnknown` |
| `true` | `NTFields {nfBoolean = Just (BoolLits {True}), ...}` |
| `42` | `NTFields {nfNumeric = Just (NumericKind (IntLits {42}) NumAbsent), ...}` |
| `3.14` | `NTFields {nfNumeric = Just (NumericKind IntAbsent (NumLits {3.14})), ...}` |
| `"foo"` | `NTFields {nfString = Just (StringLits {"foo"}), ...}` |
| `array[T]` | `NTFields {nfArray = Just (normalize T), ...}` |
| `S \| T` | `unionNT (normalize S) (normalize T)` |
| `S & T` | `intersectNT (normalize S) (normalize T)` |
| `TAlias name` | 環境から引いた NormalizedType (未定義なら `never`) |

#### Object 型の正規化

Object 型の正規化は以下の手順で行う:

1. 各フィールドの型を再帰的に正規化する
2. **Never 伝播**: 必須フィールド (optional でない) の型が `never` の場合、object 型全体を `never` に潰す
3. **DISC 構築**: `uniq` フィールドがちょうど 1 つあり、そのフィールドの型がリテラル型の場合、`NTDISC` バリアントを生成する
4. 上記条件を満たさない場合、`NTFields` の `nfObject` に格納する

```haskell
-- tryMakeDISC の条件:
-- 1. uniq フィールドがちょうど 1 つ
-- 2. そのフィールドの型が TLitBool, TLitInt, または TLitStr
```

---

## 3. 判別可能 union (Discriminated Union)

### 3.1 概要

判別可能 union は `uniq` キーワードを用いて判別可能な object の union である。通常の object union では共通でないフィールドの情報が失われるが、判別可能 union ではそれぞれのバリアントの完全な型情報が保持される。

```katari
type Shape = {uniq kind: "circle", radius: number}
           | {uniq kind: "rect", width: number, height: number}
```

内部表現:

```
NTDISC {
  discriminator: "kind",
  mapping: {
    "circle" -> NormalFields {
      objectKind: ObjectFields {
        fields: { kind: "circle", radius: number }
      }
    },
    "rect" -> NormalFields {
      objectKind: ObjectFields {
        fields: { kind: "rect", width: number, height: number }
      }
    }
  }
}
```

### 3.2 DISC 型の成立条件

object の union が DISC 型として扱われるには、以下の**全て**を満たす必要がある:

1. union の全要素が object 型である
2. 全要素が `uniq` プロパティを持つ
3. 全要素の `uniq` プロパティが同一のフィールド名を指す
4. `uniq` プロパティの値が全てリテラル型である
5. `uniq` プロパティは optional でない
6. 全要素のリテラル値が互いに異なる

各 object 型に付けられる `uniq` は**高々 1 つ**である:

```katari
// OK: 各バリアントに uniq が 1 つ
type A = {uniq type: 0, x: integer} | {uniq type: 1, y: string}

// NG: 1 つの object に uniq が 2 つ
type B = {uniq type: 0, uniq tag: "a"}
```

条件を満たさない場合、`uniq` は無視され、通常の NormalFields (object union) として正規化される。

### 3.3 object リテラル式からの DISC 生成

object リテラル式 `EObj` の型推論時にも DISC が生成される。`uniq` フラグが付いたフィールドがちょうど 1 つあり、その推論型がシングルトンリテラル型の場合、`NTDISC` を返す。これにより match 式の被マッチ式として使う場合に判別が有効になる。

---

## 4. Union の正規化

Union 型 `S | T` は、S と T をそれぞれ正規化した後、`unionNT` でマージする。

### 4.1 NormalizedType バリアント間の Union 規則

```
Unknown | T           = Unknown         (任意の T)
T | Unknown           = Unknown

DISC(d1) | DISC(d2)  (d1.field == d2.field):
  -> mapping をマージ。重複キーは NormalFields 同士を union。
  -> 結果は DISC。

DISC(d1) | DISC(d2)  (d1.field != d2.field):
  -> 両方の DISC の全バリアントを NormalFields に集約し、
     NormalFields 同士の union として正規化。
  -> 結果は NormalFields。

DISC | NormalFields(nf):
  -> nf が never なら DISC をそのまま返す (DISC 構造を保持)。
  -> それ以外は DISC を NormalFields に集約し、nf と union。
  -> 結果は NormalFields (DISC 情報は失われる)。

NormalFields(nf) | DISC:
  -> nf が never なら DISC をそのまま返す。
  -> それ以外は上記と同様。

NormalFields | NormalFields:
  -> kind ごとにマージ。
```

### 4.2 NormalFields 同一 kind の Union マージ

各 kind について、absent (Nothing) は never として扱う。never は union の単位元である。

#### Null

```
True | True   = True
True | False  = True
False | True  = True
False | False = False
```

(Bool 値の論理和)

#### Boolean

```
BoolLits(s1) | BoolLits(s2) = BoolLits(s1 ∪ s2)
```

`{True, False}` になった場合も BoolLits のまま保持する (BoolFull バリアントは存在しない)。

#### Numeric

```
NumericKind の union:
  integerPart: unionIntPart
  numberPart:  unionNumPart

IntFull | _           = IntFull
_ | IntFull           = IntFull
IntAbsent | x         = x
x | IntAbsent         = x
IntLits(s1) | IntLits(s2) = IntLits(s1 ∪ s2)

NumFull | _           = NumFull
_ | NumFull           = NumFull
NumAbsent | x         = x
x | NumAbsent         = x
NumLits(s1) | NumLits(s2) = NumLits(s1 ∪ s2)
```

結果の NumericKind が IntAbsent かつ NumAbsent の場合、nfNumeric を Nothing にする。

#### String

```
StringFull | _           = StringFull
_ | StringFull           = StringFull
StringLits(s1) | StringLits(s2) = StringLits(s1 ∪ s2)
```

#### Array

```
array[S] | array[T] = array[S | T]
```

absent (配列なし) は union の単位元。

#### Object

```
ObjectFields(f1) | ObjectFields(f2) = ObjectFields(共通フィールドのみ)
```

- 共通フィールドの型は union を取る
- 片方にのみ存在するフィールドは消える
- どちらかが optional なら結果も optional

例:

```
{type: 0, x: integer} | {type: 1, y: string}
-> {type: 0 | 1}
// x, y は共通でないため消える

{a: integer, b: string} | {a: string, b: integer}
-> {a: integer | string, b: string | integer}
```

---

## 5. Intersection の正規化

Intersection 型 `S & T` は、S と T をそれぞれ正規化した後、`intersectNT` でマージする。

### 5.1 NormalizedType バリアント間の Intersection 規則

```
Unknown & T           = T              (任意の T)
T & Unknown           = T

DISC(d1) & DISC(d2)  (d1.field == d2.field):
  -> mapping の各キーについて intersection を取る。
     両方に存在するキーのみ残し、NormalFields 同士を intersect。
  -> never になったバリアントは除去。
  -> 全バリアントが除去されたら never。

DISC(d1) & DISC(d2)  (d1.field != d2.field):
  -> 両方を NormalFields に集約し、NormalFields 同士の intersect。

DISC & NormalFields(nf):
  -> DISC の各バリアントの NormalFields と nf を intersect。
  -> never でないバリアントのみ残す。
  -> 結果は DISC。

NormalFields & DISC:
  -> 上記と同様 (交換可能)。

NormalFields & NormalFields:
  -> kind ごとにマージ。
```

### 5.2 NormalFields 同一 kind の Intersection マージ

各 kind について、absent (Nothing) は never として扱う。never は intersection の零元 (absorbing element) である。

#### Null

```
True & True   = True
True & False  = False
False & True  = False
False & False = False
```

(Bool 値の論理積)

#### Boolean

```
Nothing & _             = Nothing
_ & Nothing             = Nothing
BoolLits(s1) & BoolLits(s2) = BoolLits(s1 ∩ s2)
  -- 空の場合は Nothing
```

#### Numeric

```
NumericKind の intersection:
  integerPart: intersectIntPart
  numberPart:  intersectNumPart

IntFull & x           = x
x & IntFull           = x
IntAbsent & _         = IntAbsent
_ & IntAbsent         = IntAbsent
IntLits(s1) & IntLits(s2) = IntLits(s1 ∩ s2)
  -- 空の場合は IntAbsent

NumFull & x           = x
x & NumFull           = x
NumAbsent & _         = NumAbsent
_ & NumAbsent         = NumAbsent
NumLits(s1) & NumLits(s2) = NumLits(s1 ∩ s2)
  -- 空の場合は NumAbsent
```

IntPart と NumPart は独立に intersection を計算する。例:

```
NumericKind{IntFull, NumLits({3.14})}
  & NumericKind{IntLits({1,2}), NumFull}
  = NumericKind{IntLits({1,2}), NumLits({3.14})}
```

#### String

```
Nothing & _             = Nothing
_ & Nothing             = Nothing
StringFull & x          = x
x & StringFull          = x
StringLits(s1) & StringLits(s2) = StringLits(s1 ∩ s2)
  -- 空の場合は Nothing
```

#### Array

```
Nothing & _             = Nothing
_ & Nothing             = Nothing
array[S] & array[T]     = array[S & T]
```

#### Object

```
Nothing & _             = Nothing
_ & Nothing             = Nothing
ObjectFields(f1) & ObjectFields(f2) = ObjectFields(全フィールドを残す)
```

- 共通フィールドの型は intersection を取る
- 片方にのみ存在するフィールドはそのまま追加
- 両方 optional の場合のみ結果が optional。片方でも必須なら結果は必須
- **Never 伝播**: 必須フィールドの型が never の場合、object 全体を Nothing (never) にする

### 5.3 異なる kind 間の intersection

異なる kind 間の intersection は暗黙的に `never` となる。NormalFields の各 kind は独立に intersection を計算するため、例えば `integer & string` は全ての kind が absent になり、結果は `never` となる:

```
integer & string = never
boolean & null   = never
array[integer] & {x: integer} = never
```

---

## 6. 部分型チェック (Subtyping)

部分型チェック `S <: T` は、両辺を正規化した後、`subtypeNT` で比較する。

### 6.1 基本規則

```
T <: unknown      = true  (任意の T)
unknown <: T      = false (T が unknown の場合のみ true)
never <: T        = true  (任意の T; NormalFields の全 kind が absent)
T <: never        = T が never の場合のみ true
```

### 6.2 NormalizedType バリアント間の部分型規則

```
DISC(d1) <: DISC(d2)  (d1.field == d2.field):
  -> d1 の全キーが d2 に存在し、対応するバリアントについて
     NormalFields <: NormalFields。

DISC(d1) <: DISC(d2)  (d1.field != d2.field):
  -> 両方を NormalFields に集約してから比較。

DISC <: NormalFields:
  -> DISC の全バリアントが NormalFields のサブタイプであること。

NormalFields <: DISC:
  -> NormalFields がいずれかのバリアントのサブタイプであること。

NormalFields <: NormalFields:
  -> kind ごとに比較。
```

### 6.3 NormalFields の kind ごとの部分型チェック

```
NormalFields(S) <: NormalFields(T)
  iff
  S.nfNull    <: T.nfNull    &&
  S.nfBoolean <: T.nfBoolean &&
  S.nfNumeric <: T.nfNumeric &&
  S.nfString  <: T.nfString  &&
  S.nfArray   <: T.nfArray   &&
  S.nfObject  <: T.nfObject
```

absent (Nothing) は never として扱い、`never <: T` は常に true。

#### Null

```
True <: False  = false
_    <: _      = true   (他の全ケース)
```

#### Boolean

```
Nothing <: _             = true
_ <: Nothing             = false
BoolLits(s1) <: BoolLits(s2) = s1 ⊆ s2
```

#### Numeric

NumericKind の部分型チェックは 2 つの条件を両方満たす必要がある:

**条件 1: IntPart の全値が対象の NumericKind に含まれること**

`integer <: number` であるため、IntPart の値は対象の IntPart **または** NumPart に含まれればよい。

```
IntAbsent <: _ = true
IntFull <: NumericKind(ip2, np2) = (ip2 == IntFull) || (np2 == NumFull)
IntLits(s) <: NumericKind(ip2, np2):
  ip2 == IntFull -> true
  ip2 == IntLits(s2) -> s ⊆ s2
  ip2 == IntAbsent -> np2 == NumFull
```

**条件 2: NumPart の全値が対象の NumPart に含まれること**

number の値は NumPart にのみ属するため、NumPart 同士で比較する。

```
NumAbsent <: _ = true
_ <: NumAbsent = false
NumFull <: NumFull = true
NumFull <: _ = false
_ <: NumFull = true
NumLits(s1) <: NumLits(s2) = s1 ⊆ s2
```

#### String

```
Nothing <: _                = true
_ <: Nothing                = false
StringFull <: StringFull    = true
StringFull <: _             = false
StringLits(_) <: StringFull = true
StringLits(s1) <: StringLits(s2) = s1 ⊆ s2
```

#### Array

```
Nothing <: _      = true
_ <: Nothing      = false
array[S] <: array[T]  iff  S <: T
```

配列は共変 (covariant) である。

#### Object

```
Nothing <: _      = true
_ <: Nothing      = false
ObjectFields(o1) <: ObjectFields(o2):
  o2 の全フィールド f について:
    - f が o1 に存在しない場合: f が optional なら OK, 必須なら false
    - f が o1 に存在する場合:
      o1.f.type <: o2.f.type
      かつ (o2.f が optional、または o1.f が必須)
```

Object は**幅方向に共変**である。S にフィールドが多い (= より具体的) 方がサブタイプ。

### 6.4 Optional フィールドの部分型

Optional フィールドは部分型チェックにおいて以下のように扱われる:

- `{x?: T}` を持つ側がスーパータイプの場合: サブタイプ側に `x` がなくても OK
- `{x: T}` を持つ側がスーパータイプの場合: サブタイプ側に `x` が存在し、optional でないことが必要

---

## 7. 型引き算とパターンマッチの網羅性チェック

### 7.1 パターンから型を生成する

`patternTypeNT :: Pat -> NormalizedType` がパターンの受理型を生成する。生成される型の意味は「この型であればこのパターンに必ずマッチする」である (逆は必ずしも真でない)。

| パターン | 生成される型 |
|---------|------------|
| `x` (変数) | `NTUnknown` |
| `x: T` (型アノテーション付き) | `normalize T` |
| `null` | `null` |
| `42` | `42` (integer リテラル) |
| `3.14` | `3.14` (number リテラル) |
| `"foo"` | `"foo"` (string リテラル) |
| `true` | `true` |
| `false` | `false` |
| `boolean(x)` | `boolean` |
| `integer(x)` | `integer` |
| `number(x)` | `number` |
| `string(x)` | `string` |
| `[p1, p2, ...]` | `NTFields {nfArray = Just NTUnknown}` |
| `{foo = p1, bar = p2}` | `NTFields {nfObject = Just {foo: type(p1), bar: type(p2)}}` |
| `{uniq kind = "circle", r = x}` | `NTDISC {"kind", {"circle" -> NF{obj: {kind: "circle", r: unknown}}}}` |

**DISC パターン**: object パターン内にちょうど 1 つの `uniq` フィールドが存在し、そのフィールドがリテラルパターンの場合、DISC パターンとして型を生成する。

### 7.2 型引き算アルゴリズム

型引き算 `L - R` は `subtractNT` で実行される。L から R が受理する型を引く操作。

#### NormalizedType バリアント間の引き算

```
L - Unknown           = never             (全て引かれる)
Unknown - R           = Unknown           (安全に倒す)

DISC(d1) - DISC(d2)  (d1.field == d2.field):
  -> d1 の各バリアント (k, nf) について:
     k が d2 にある場合: nf - d2[k] を計算。never なら除去。
     k が d2 にない場合: そのまま残す。
  -> 全バリアントが除去されたら never。

DISC(d1) - DISC(d2)  (d1.field != d2.field):
  -> 両方を NormalFields に集約してから引き算。

DISC - NormalFields:
  -> DISC を NormalFields に集約してから引き算。

NormalFields - DISC:
  -> DISC を NormalFields に集約してから引き算。

NormalFields - NormalFields:
  -> kind ごとに引き算。
```

#### NormalFields の kind ごとの引き算

各 kind について独立に引き算する:

**Null**:

```
True - True   = False (引かれる)
True - False  = True  (残る)
False - _     = False
```

**Boolean**:

```
Nothing - _             = Nothing
x - Nothing             = x
BoolLits(s1) - BoolLits(s2) = BoolLits(s1 \ s2)
  -- 空の場合は Nothing
```

**Numeric**:

```
IntPart の引き算 (subtractIntPart ip tgtI tgtN):
  IntAbsent - _, _     = IntAbsent
  _ - IntFull, _       = IntAbsent
  _ - _, NumFull       = IntAbsent    (number は integer を含むため)
  IntFull - IntLits(_), _ = IntFull   (保守的: 有限集合を引いても Full)
  IntLits(s1) - IntLits(s2), _ = IntLits(s1 \ s2)
                                       -- 空の場合は IntAbsent

NumPart の引き算:
  NumAbsent - _        = NumAbsent
  n - NumAbsent        = n
  NumFull - NumFull    = NumAbsent
  NumFull - NumLits(_) = NumFull      (保守的)
  NumLits(_) - NumFull = NumAbsent
  NumLits(s1) - NumLits(s2) = NumLits(s1 \ s2)
```

**String**:

```
Nothing - _                    = Nothing
x - Nothing                    = x
StringFull - StringFull        = Nothing
StringFull - StringLits(_)     = StringFull  (保守的)
StringLits(_) - StringFull     = Nothing
StringLits(s1) - StringLits(s2) = StringLits(s1 \ s2)
```

**Array**:

```
Nothing - _             = Nothing
x - Nothing             = x
array[S] - array[T]:
  S - T が never なら Nothing (全て引く)
  それ以外は array[S] を保持 (保守的: 要素型での区別は困難)
```

**Object**:

```
Nothing - _             = Nothing
o - Nothing             = o
ObjectFields(o1) - ObjectFields(o2):
  o2 の各フィールド (name, fi2) について:
    name が o1 にない場合: 無視 (引き算に影響しない)
    name が o1 にある場合: o1[name].type - fi2.type を計算
  共通フィールドの引き算結果が全て never なら:
    object 全体を Nothing (引かれた)
  それ以外:
    o1 を保持 (保守的)
  共通フィールドがない場合:
    o1 を保持
```

### 7.3 網羅性チェック

match 式の網羅性チェックは以下の手順で行う:

1. 被マッチ式の型 `T` を正規化する
2. 各 case arm のパターンについて:
   a. パターンの受理型 `P` を `patternTypeNT` で生成する
   b. パターンに合致する入力型を `narrowed = intersectNT T P` で計算し、case body の型チェックに使用する
   c. 残り型を `T' = subtractNT T P` で計算する
   d. `T'` が never なら網羅完了。残りの case は到達不能。
   e. `T'` が never でなければ、`T = T'` として次の case へ
3. 全 case 処理後、`T` が never でなければコンパイルエラー (`NonExhaustive`)

### 7.4 例: DISC パターンの網羅性

```katari
type Result = {uniq ok: true, value: integer}
            | {uniq ok: false, error: string}

agent process(r: Result) -> string {
  match r {
    case {uniq ok = true, value = v} => {
      // 残り: DISC { d: "ok", mapping: {
      //   false: NF{obj: {ok: false, error: string}}
      // } }
      to_string(v)
    }
    case {uniq ok = false, error = e} => {
      // 残り: never (網羅完了)
      e
    }
  }
}
```

### 7.5 例: ネストした引き算

```katari
type X = {uniq type: 0, x: integer | string} | {uniq type: 1, y: string}

agent f(v: X) -> string {
  match v {
    case {uniq type = 0, x = integer(n)} => {
      // 残り: DISC { d: "type", mapping: {
      //   0: NF{obj: {type: 0, x: string}},
      //   1: NF{obj: {type: 1, y: string}}
      // } }
      to_string(n)
    }
    case {uniq type = 0, x = string(s)} => {
      // 残り: DISC { d: "type", mapping: {
      //   1: NF{obj: {type: 1, y: string}}
      // } }
      s
    }
    case {uniq type = 1, y = y} => {
      // 残り: never (網羅完了)
      y
    }
  }
}
```

### 7.6 保守的な引き算について

型引き算は一部のケースで**保守的** (conservative) に動作する。つまり、引ききれない場合に元の型を残す。これにより、型引き算は always sound (安全に倒す) だが、一部のケースで false positive (非網羅的と判定されるが実際には網羅的) が発生し得る。

保守的なケース:
- `StringFull - StringLits(s)` -> `StringFull` (有限集合を引いても無限集合は残る)
- `IntFull - IntLits(s)` -> `IntFull` (同上)
- `NumFull - NumLits(s)` -> `NumFull` (同上)
- 配列の引き算: 要素型で区別が困難なため保守的に保持
- Object: 共通フィールドの一部のみが never になった場合は保守的に保持

---

## 8. パターン変数の型推論

### 8.1 bindPat によるパターン変数の型バインド

`bindPat :: Pat -> NormalizedType -> TypeEnv -> TypeEnv` がパターン変数に型を割り当てる。第二引数は `intersectNT remaining patternType` で絞り込まれた型。

| パターン | 変数の型 |
|---------|---------|
| `PVar n` | 絞り込まれた型がそのまま変数 `n` の型 |
| `PTyped n T` | `normalize T` が変数 `n` の型 (アノテーション通り) |
| `PTag _ n` | 絞り込まれた型がそのまま変数 `n` の型 |
| `PLit _` | 変数なし |
| `PArr pats` | 配列要素型を各パターンにバインド |
| `PObj fields` | 各フィールドの型を `fieldType` で取得してバインド |

### 8.2 DISC パターンの変数型推論

object パターン内に `uniq` フィールドがある場合 (DISC パターン)、被マッチ式の型が DISC であれば discriminator の値からバリアントを特定し、そのバリアントのフィールド型を変数に割り当てる。

```katari
type Shape = {uniq kind: "circle", radius: number}
           | {uniq kind: "rect", width: number, height: number}

agent area(s: Shape) -> number {
  match s {
    case {uniq kind = "circle", radius = r} => {
      // r: number (DISC "circle" バリアントの radius の型)
      3.14 * r * r
    }
    case {uniq kind = "rect", width = w, height = h} => {
      // w: number, h: number
      w * h
    }
  }
}
```

### 8.3 fieldType の解決

`fieldType :: NormalizedType -> Text -> NormalizedType` はフィールド名から型を取得する:

- `NTFields`: `nfObject` から `ofFields` を引く。なければ `NTUnknown`
- `NTDISC`: 全バリアントの NormalFields から同名フィールドの型を union で集約
- `NTUnknown`: `NTUnknown`

### 8.4 型アノテーション付きパターンの検証

`PTyped n T` パターンでは、推論された型がアノテーション型 `T` のサブタイプかを検証する (`checkPatAnnot`)。サブタイプでない場合は `TypeMismatch` エラー。

```katari
let x: integer = some_expr  // some_expr の推論型が integer <: integer なら OK
```

---

## 9. 演算子の型推論

### 9.1 二項演算子

| 演算子 | オペランド型 | 結果型 |
|--------|-------------|--------|
| `+`, `-`, `*` | `integer, integer` | `integer` |
| `+`, `-`, `*` | その他の数値組み合わせ | `number` |
| `/` | 任意の数値 | `number` |
| `++` | `string, string` | `string` |
| `++` | `array[S], array[T]` | `array[S \| T]` |
| `<`, `>`, `<=`, `>=` | 数値 | `boolean` |
| `==`, `!=` | 任意 | `boolean` |
| `&&`, `\|\|` | 任意 | `boolean` |

**注意**:
- `integer / integer` は `number` を返す (整数除算ではない)。整数商は `prim.div(a, b)` を使用。
- `&&` と `||` は**非短絡評価**である (両辺を常に評価する)。
- `++` はオペランドの型で動作が決まる: 両方 string なら文字列結合、そうでなければ配列結合。

### 9.2 単項演算子

| 演算子 | オペランド型 | 結果型 |
|--------|-------------|--------|
| `-` (否定) | `T` | `T` (型を保持) |
| `!` (論理否定) | 任意 | `boolean` |

### 9.3 数値型の判定

`numericResult` は二項演算の結果型を決定する:
- 両オペランドが integer 型 (NumericKind の IntPart のみが present、NumPart が absent) なら `integer`
- それ以外は `number`

---

## 10. ランタイム型タグ

### 10.1 動的型タグ

ランタイムでは全ての値が動的型タグを持つ。`ITypeOf dst src` 命令は `src` の型タグを文字列として `dst` に格納する。

| 値の種類 | 型タグ文字列 |
|---------|------------|
| Null | `"null"` |
| Boolean | `"boolean"` |
| Integer | `"integer"` |
| Number (非整数) | `"number"` |
| String | `"string"` |
| Array | `"array"` |
| Object | `"object"` |

### 10.2 PTag パターンとランタイムマッチング

`PTag` パターン (例: `integer(x)`, `string(s)`) はランタイムで以下の命令列にコンパイルされる:

```
ITypeOf typeVar scrutVar        // 型タグを取得
ILoadConst tagStr tagConstId    // タグ文字列定数をロード
ICmpEq cmpVar typeVar tagStr   // タグを比較
IBranch cmpVar matchLabel nextLabel  // 分岐
```

タグ文字列の対応:

| PrimTag | タグ文字列 |
|---------|-----------|
| `TagBoolean` | `"boolean"` |
| `TagInteger` | `"integer"` |
| `TagNumber` | `"number"` |
| `TagString` | `"string"` |

### 10.3 数値演算の動的ディスパッチ

算術命令 (`IAdd`, `ISub`, `IMul`, `IDiv` 等) はランタイムで integer/number を動的に判定して処理する。両オペランドが integer の場合は整数演算、それ以外は浮動小数点演算を行う。`IDiv` は常に浮動小数点の結果を返す。

---

## 11. JSON Schema 生成

### 11.1 概要

`Katari.Schema` モジュールが KATARI の型から JSON Schema (draft-07 互換) を生成する。主に AI サーバーの構造化出力のスキーマ定義に使用される。

### 11.2 型から JSON Schema への変換

`normalizedToSchema :: NormalizedType -> Value` が NormalizedType を JSON Schema に変換する。

| NormalizedType | JSON Schema |
|---------------|-------------|
| `NTUnknown` | `{}` (任意の値を許容) |
| `NTDISC d` | `{"oneOf": [...], "discriminator": {"propertyName": "..."}}` |
| `NTFields` (never) | `{"not": {}}` (何も許容しない) |
| `NTFields` (単一 kind) | 対応する kind の schema |
| `NTFields` (複数 kind) | `{"oneOf": [...]}` |

#### Kind ごとの Schema

| Kind | JSON Schema |
|------|-------------|
| null | `{"type": "null"}` |
| boolean (full) | `{"type": "boolean"}` |
| boolean (literal) | `{"const": true}` / `{"const": false}` |
| integer (full) | `{"type": "integer"}` |
| number (IntFull + NumFull) | `{"type": "number"}` |
| integer リテラル | `{"const": 42}` |
| number リテラル | `{"const": 3.14}` |
| string (full) | `{"type": "string"}` |
| string リテラル | `{"const": "hello"}` |
| 複数リテラル | `{"oneOf": [{"const": ...}, ...]}` |
| array | `{"type": "array", "items": <elemSchema>}` |
| object | `{"type": "object", "properties": {...}, "required": [...]}` |

### 11.3 アノテーションと description

`@"..."` アノテーションは JSON Schema の `"description"` フィールドに変換される。

```katari
agent greet(
  @"ユーザーの名前" name: string,
  @"挨拶の言語" lang: "ja" | "en"
) -> string { ... }
```

生成される input schema:

```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string",
      "description": "ユーザーの名前"
    },
    "lang": {
      "oneOf": [{"const": "ja"}, {"const": "en"}],
      "description": "挨拶の言語"
    }
  },
  "required": ["name", "lang"]
}
```

agent 宣言・request 宣言自体にも `@"..."` アノテーションを付与でき、最上位の schema に `"description"` が追加される。

### 11.4 Agent / Request の Schema 構造

Agent と Request の schema は以下の構造を持つ:

```json
{
  "type": "object",
  "properties": {
    "input": <paramsSchema>,
    "output": <returnTypeSchema>
  },
  "required": ["input", "output"]
}
```

`input` はパラメータ一覧を object schema として表現し、`output` は戻り値型の schema である。

---

## 12. エフェクト型 (RequestEffect)

### 12.1 概要

KATARI では agent が使用する request を**エフェクト**として宣言できる。エフェクトは `with` 節で明示するか、コンパイラが推論する。

### 12.2 構文

```haskell
data RequestEffect
  = RENames [Text]   -- with req1 | req2 | ...
  | REAgent           -- with agent
```

#### `with req1 | req2 | ...`

agent が使用する request を明示的に列挙する。宣言された request 以外を使用するとコンパイルエラー (`EffectMismatch`)。

```katari
agent my_agent(x: integer) -> string with get_data | send_msg {
  // get_data と send_msg のみ使用可能
  let data = get_data(x)
  send_msg(data)
}
```

#### `with agent`

agent 自身がリクエストハンドラとして動作することを示す。agent body 内で直接 request を呼び出すことはできない (handle 経由のみ)。

```katari
agent handler(x: integer) -> string with agent {
  // request を直接呼び出すことはできない
  // handle 経由で受け取るのみ
  ...
}
```

`with agent` が宣言された場合、body 内に `prim.throw` 以外の request 呼び出しがあるとエラーになる。

#### `with` 省略 (推論)

`with` 節を省略した場合、コンパイラがエフェクトを推論する。推論モードでは型チェック時にエフェクト検証をスキップする。

### 12.3 エフェクト収集

`collectRequestsBlock` / `collectRequestsExpr` がブロック・式内で使用される request の集合を収集する。

収集ルール:
- `IRequest` (request 呼び出し): 直接 request として収集
- `ICall` (agent 呼び出し): 呼び出し先 agent の `with` 宣言に基づくエフェクトを推移的に収集
- `handle` ブロック: handle で処理される request は scope body の収集結果から除外される
- `prim.throw` は暗黙的に全ての agent で使用可能 (収集結果から除外して比較)

### 12.4 val 宣言のエフェクト制約

`val` 宣言はエフェクトフリーでなければならない。`prim.throw` 以外の request を使用する式は `val` の右辺に置くことができない (`ValWithEffect` エラー)。

```katari
// OK: エフェクトフリー
val x: integer = 42

// NG: request を使用
val y: string = get_data(0)  // エラー: ValWithEffect
```

### 12.5 handle によるエフェクトのスコープ

handle 文は特定の request をスコープ内で処理する。handle 内で処理される request は、外部から見たエフェクトに含まれない。

```katari
agent my_agent() -> string with send_msg {
  // get_data は handle で処理されるため with に含めなくてよい
  handle (var acc: string = "") {
    case get_data(id) => {
      continue "data_" ++ to_string(id)
    }
  }
  // send_msg は handle 外で直接使用
  send_msg("done")
}
```

---

## 13. 型チェックの全体フロー

### 13.1 エントリポイント

```haskell
typecheck :: GlobalEnv -> [Module] -> Either TypeError ()
```

全モジュールの全宣言を順に型チェックする。

### 13.2 Agent の型チェック

1. パラメータの型を正規化して環境に追加
2. 戻り値型を正規化 (省略時は `null`)
3. Body の型を推論
4. Body の型が戻り値型のサブタイプかを検証
5. `with` 節が明示されている場合、エフェクト検証を実行

### 13.3 Val の型チェック

1. 式の型を推論
2. エフェクトフリーかを検証
3. 推論型が宣言型のサブタイプかを検証

### 13.4 ブロックの型推論

- 空ブロックの型は `null`
- 最後の文の型がブロックの型
- `SReturn`, `SBreak`, `SForBreak`, `SContinue`, `SForContinue` は `never` を返す (制御が戻らない)
- `never` を返す文の後のコードは到達不能 (unreachable) として扱われ、ブロックの型は `never`

### 13.5 Handle 文の型推論

1. state 変数の初期値式の型を検証
2. 各 request case の body を型チェック (teContinue に request の戻り値型を設定)
3. 残り文 (handle スコープ) を推論
4. then 節がある場合: scope body の型を then 変数にバインドして then body を推論
5. then 節がない場合: scope body の型がそのまま結果型

### 13.6 For 式の型推論

1. let バインドの配列要素型を推論
2. var バインドの型を正規化
3. Body を推論
4. `collectForBreakNT` で body 内の `SForBreak` 式の型を union で収集 (内側の for には降りない)
5. then 節の型を推論 (省略時は `null`)
6. 結果型 = `then型 | break型`

### 13.7 If / Match 式

- `if cond then_block else_block`: 結果型 = `then型 | else型`
- `match expr { case ... }`: 結果型 = 全 arm の body 型の union。網羅性チェックあり。

### 13.8 呼び出しの型チェック

Agent / Request の呼び出しでは以下を検証する:
- 引数の数が合っているか (`ArityMismatch`)
- 各引数の型がパラメータ型のサブタイプか (`TypeMismatch`)
- 結果型は呼び出し先の戻り値型を正規化したもの

---

## 14. 型エラー

コンパイラが報告する型エラーの一覧:

| エラー | 説明 |
|--------|------|
| `TypeMismatch sp actual expected` | 型の不一致。actual が expected のサブタイプでない |
| `UndefinedName sp name` | 未定義の名前 |
| `EffectMismatch sp actual declared` | エフェクト宣言と実際の使用が不一致 |
| `NonExhaustive sp` | match 式が網羅的でない |
| `ValWithEffect sp name` | val 宣言でエフェクトのある式を使用 |
| `InvalidOp sp msg` | 不正な操作 (例: agent 外での return) |
| `ArityMismatch sp name expected actual` | 引数の数が合わない |
