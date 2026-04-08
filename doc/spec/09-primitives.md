# KATARI Language Specification - Primitives

## 組み込み型

| 型 | 説明 | ランタイム表現 |
|----|------|---------------|
| `null` | null 値。unit 型としても使用。 | JSON `null` |
| `boolean` | 真偽値。 | JSON `true` / `false` |
| `integer` | 任意精度整数。 | JSON number (整数) |
| `number` | IEEE 754 倍精度浮動小数点数。 | JSON number |
| `string` | UTF-8 文字列。 | JSON string |
| `never` | ボトム型。値を持たない。 | (存在しない) |
| `unknown` | トップ型。全ての値を含む。 | 任意の JSON 値 |
| `array[T]` | T 型の要素の配列。 | JSON array |
| `{...}` | Object 型。 | JSON object |

## 組み込みタスク (prim モジュール)

### to_string

```katari
task to_string(x: integer | number | boolean | string | null) -> string
```

値を文字列に変換する。純粋関数 (request なし)。

| 入力 | 出力 |
|------|------|
| `null` | `"null"` |
| `true` | `"true"` |
| `false` | `"false"` |
| `42` (integer) | `"42"` |
| `3.14` (number) | `"3.14"` |
| `"hello"` (string) | `"hello"` (identity) |

### parse_error request

```katari
request parse_error(message: string) -> never
```

パース関数が失敗した際に発生する request。`-> never` のため、handler は `break` のみ可能。

### parse_integer

```katari
task parse_integer(s: string) -> integer with parse_error
```

文字列を整数にパースする。失敗時は `parse_error` を perform する。

### parse_number

```katari
task parse_number(s: string) -> number with parse_error
```

文字列を浮動小数点数にパースする。失敗時は `parse_error` を perform する。

### parse_boolean

```katari
task parse_boolean(s: string) -> boolean with parse_error
```

文字列を boolean にパースする。`"true"` → `true`、`"false"` → `false`。その他は `parse_error`。

### throw request

```katari
request throw(message: string) -> never
```

エラーをスローする組み込み request。`-> never` のため、handler は `break` のみ可能。`throw` 自身は `with task` である（他の request を発生させない）。

**暗黙的な包含**: 全ての task は暗黙的に `with throw` を含む。`with` 節に明示しなくても `throw` は常に perform 可能。

**effect 型への影響なし**: `handle` ブロック内に `throw` case を書いた場合も、effect 型には一切影響を与えない（throw は常に暗黙であるため）。

ランタイムはトップレベルに暗黙的な throw handler を提供する。ユーザーコードで handle block により throw を処理した場合、ランタイムのデフォルトハンドラは上書きされる。ユーザーコードで throw が処理されなかった場合、ランタイムがエラーメッセージとスタックトレースと共にエージェントを終了させる。

### div / mod (整数商・剰余)

```katari
task div(a: integer | number, b: integer | number) -> integer
task mod(a: integer | number, b: integer | number) -> number
```

**floor division** (負の方向への切り捨て) を行う組み込み関数。

| 関数 | 説明 |
|------|------|
| `div(a, b)` | `a ÷ b` の商（floor）。常に `integer` を返す |
| `mod(a, b)` | `a ÷ b` の余り。常に `number` を返す |

```
div(7, 2)    = 3       mod(7, 2)    = 1.0
div(4, 1.5)  = 2       mod(4, 1.5)  = 1.0
div(-7, 2)   = -4      mod(-7, 2)   = 1.0
div(-4, 1.5) = -3      mod(-4, 1.5) = 0.5
```

不変条件: `div(a, b) * b + mod(a, b) == a`

**注意**: `/` 演算子は通常の浮動小数点除算（常に `number` を返す）であり、`div` とは異なる。`%` 演算子は存在しない。

### par

`par` は構文 (式) であり、prim モジュールの関数ではない。詳細は [01-syntax.md](01-syntax.md) を参照。

## ログ関数 (prim.log モジュール)

```katari
task info(message: string) -> null
task warn(message: string) -> null
task error(message: string) -> null
```

ログ関数は request を発生させない。ランタイムが直接処理する。

## 演算子の型規則

### 算術演算子

| 演算子 | 左辺 | 右辺 | 結果 |
|--------|------|------|------|
| `+` | `integer` | `integer` | `integer` |
| `+` | `number` | `number` | `number` |
| `+` | `integer` | `number` | `number` |
| `+` | `number` | `integer` | `number` |
| `-` | (同上) | (同上) | (同上) |
| `*` | (同上) | (同上) | (同上) |
| `/` | `integer` | `integer` | `number` |
| `/` | `number` | `number` | `number` |
| `/` | `integer` | `number` | `number` |
| `/` | `number` | `integer` | `number` |

**注意**: `/` は常に `number` を返す (整数除算ではない)。整数商・余りは `prim.div` / `prim.mod` 関数を使用。

`integer` と `number` が混在する場合、`integer` 側が暗黙的に `number` に昇格する。

### 単項演算子

| 演算子 | オペランド | 結果 |
|--------|-----------|------|
| `-` | `integer` | `integer` |
| `-` | `number` | `number` |
| `!` | `boolean` | `boolean` |

### 比較演算子

| 演算子 | 左辺 | 右辺 | 結果 |
|--------|------|------|------|
| `<`, `>`, `<=`, `>=` | `integer \| number` | `integer \| number` | `boolean` |
| `==`, `!=` | `T` | `T` | `boolean` |

`==` / `!=` は同一型間でのみ使用可能。異なる kind 間の比較はコンパイルエラー。
ただし `integer` と `number` は `number` に昇格して比較可能。

### 文字列・配列結合

| 演算子 | 左辺 | 右辺 | 結果 |
|--------|------|------|------|
| `++` | `string` | `string` | `string` |
| `++` | `array[S]` | `array[T]` | `array[S \| T]` |

### 論理演算子

| 演算子 | 左辺 | 右辺 | 結果 |
|--------|------|------|------|
| `&&` | `boolean` | `boolean` | `boolean` |
| `\|\|` | `boolean` | `boolean` | `boolean` |

`&&` と `||` は**非短絡評価**である。左辺の値に関わらず右辺も常に評価される。

## テンプレートリテラル

```katari
f"hello ${name}, you are ${to_string(age)} years old"
```

テンプレートリテラルは以下のように展開される:

```katari
"hello " ++ to_string(name) ++ ", you are " ++ to_string(age) ++ " years old"
```

`${expr}` 内の式に対して暗黙的に `to_string` が呼ばれる。ただし、式の型が `string` の場合は `to_string` の呼び出しは省略される。

`to_string` の引数型 (`integer | number | boolean | string | null`) 以外の式をテンプレートリテラルに埋め込む場合はコンパイルエラー。

## JSON Schema 生成

Semantic annotation を含む型情報から JSON Schema を生成する。以下の場面で生成される:

- task の引数、返り値
- request の引数、返り値
- GET /task, GET /request のレスポンスに含まれる

### 生成規則

正規化後の型に対して再帰的に生成される。

| KATARI 型 | JSON Schema |
|-----------|-------------|
| `null` | `{ "type": "null" }` |
| `boolean` | `{ "type": "boolean" }` |
| `true` | `{ "const": true }` |
| `false` | `{ "const": false }` |
| `integer` | `{ "type": "integer" }` |
| `0`, `1`, ... | `{ "const": 0 }`, `{ "const": 1 }`, ... |
| `number` | `{ "type": "number" }` |
| `3.14`, ... | `{ "const": 3.14 }`, ... |
| `string` | `{ "type": "string" }` |
| `"foo"`, ... | `{ "const": "foo" }`, ... |
| `array[T]` | `{ "type": "array", "items": schema(T) }` |
| `never` | `{ "not": {} }` |
| `unknown` | `{}` |

### Object 型の JSON Schema

```katari
type User = {
  name: string @ "ユーザー名",
  age: integer @ "年齢",
  email?: string @ "メールアドレス"
}
```

```json
{
  "type": "object",
  "properties": {
    "name": { "type": "string", "description": "ユーザー名" },
    "age": { "type": "integer", "description": "年齢" },
    "email": { "type": "string", "description": "メールアドレス" }
  },
  "required": ["name", "age"]
}
```

- 必須フィールドは `required` に含まれる。
- optional フィールドは `required` に含まれない。
- semantic annotation は `description` として出力。

### Union 型の JSON Schema

```katari
type Response = integer | string
```

```json
{
  "oneOf": [
    { "type": "integer" },
    { "type": "string" }
  ]
}
```

### 判別可能 Union (DISC) の JSON Schema

```katari
type Shape = {uniq kind: "circle", radius: number}
           | {uniq kind: "rect", width: number, height: number}
```

```json
{
  "oneOf": [
    {
      "type": "object",
      "properties": {
        "kind": { "const": "circle" },
        "radius": { "type": "number" }
      },
      "required": ["kind", "radius"]
    },
    {
      "type": "object",
      "properties": {
        "kind": { "const": "rect" },
        "width": { "type": "number" },
        "height": { "type": "number" }
      },
      "required": ["kind", "width", "height"]
    }
  ],
  "discriminator": {
    "propertyName": "kind"
  }
}
```

DISC 型の場合、`discriminator` フィールドが追加され、各バリアントの discriminator フィールドには `const` が設定される。

## Semantic Annotation

```katari
@"この関数はメールを送信する"
task send_mail(
  to: string @ "送信先メールアドレス",
  subject: string @ "件名",
  body: string @ "本文"
) -> null {
  // ...
}
```

- task・val・request・external task/request の定義に `@"..."` を付けられる。
- タスクパラメータ、object フィールドの型に `@ "..."` を付けられる。
- handle パラメータにも `@ "..."` を付けられる。
- annotation は JSON Schema の `description` として出力される。
- annotation は静的な文字列リテラルのみ (動的な変数は挿入不可)。
