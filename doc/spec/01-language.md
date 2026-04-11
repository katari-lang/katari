# KATARI 言語仕様 -- 構文と意味論

本ドキュメントは KATARI 言語の字句規則、構文、および意味論を包括的に定義する。
型システムについては [02-type-system.md](02-type-system.md)、
IR 命令セットについては [03-ir.md](03-ir.md) を参照のこと。

---

## 1. 字句規則

### 1.1 文字セット

ソースファイルは UTF-8 エンコーディングのテキストファイルである。

### 1.2 空白とコメント

空白文字 (` `, `\t`) はトークン間の区切りとして機能する。
改行 (`\n`, `\r\n`, `\r`) はセミコロン自動挿入の対象となる (1.7 節参照)。

```
// 行コメント: // から行末まで
/* ブロックコメント: ネスト可能 /* このように */ */
```

ブロックコメントは入れ子にでき、内側の `/*` に対応する `*/` が必要である。

### 1.3 識別子

```
identifier  ::= (letter | '_') (letter | digit | '_')*
letter      ::= 'a'..'z' | 'A'..'Z'
digit       ::= '0'..'9'
```

識別子はキーワードと同名であってはならない。`uniq` は文脈キーワード (contextual keyword) であり、オブジェクトリテラルやオブジェクト型の中でのみキーワードとして扱われ、それ以外の文脈では通常の識別子として使用できる。

### 1.4 キーワード

以下の語はキーワードとして予約されている。

```
val       let       agent     if        else      match     case
return    continue  break     request   type      import    as
with      from      for       then      of        var       handle
external  par       null      true      false
```

### 1.5 リテラル

#### 1.5.1 整数リテラル

```
integer_literal  ::= digit+
```

符号なし十進整数。負の整数は単項マイナス演算子 (`-`) で表現する。

#### 1.5.2 数値リテラル (浮動小数点)

```
number_literal   ::= digit+ '.' digit+
```

小数点の前後にそれぞれ 1 桁以上の数字が必要である。`.5` や `3.` は不正。

#### 1.5.3 文字列リテラル

```
string_literal   ::= '"' string_char* '"'
string_char      ::= <'"' と '\' 以外の任意の文字> | escape_seq
escape_seq       ::= '\' ('n' | 't' | 'r' | '\' | '"' | '$')
```

エスケープシーケンスの対応:

| 表記   | 文字             |
|--------|------------------|
| `\n`   | 改行 (LF)        |
| `\t`   | タブ             |
| `\r`   | 復帰 (CR)        |
| `\\`   | バックスラッシュ |
| `\"`   | ダブルクオート   |
| `\$`   | ドル記号         |

#### 1.5.4 複数行文字列リテラル

```
multiline_string  ::= '"""' newline content newline? '"""'
```

`"""` の直後は必ず改行でなければならない。開始直後の改行と、閉じ `"""` 直前の改行はコンテンツに含まれない。

#### 1.5.5 真偽値リテラル

```
bool_literal  ::= 'true' | 'false'
```

#### 1.5.6 null リテラル

```
null_literal  ::= 'null'
```

### 1.6 テンプレートリテラル (f-string)

```
template_literal       ::= 'f"' template_char* '"'
                          | 'f"""' newline template_char* newline? '"""'
template_char          ::= string_char | template_interpolation
template_interpolation ::= '${' expr '}'
```

テンプレートリテラルは `f` 接頭辞付きの文字列で、`${expr}` 形式の式埋め込みを含むことができる。複数行テンプレートリテラル (`f"""..."""`) も使用可能で、通常の複数行文字列と同様に先頭・末尾の改行規則に従う。

`${...}` 内では中括弧 `{` `}` のネストが追跡され、正しく対応する `}` が閉じ括弧として認識される。

```katari
let name = "world"
let msg = f"Hello, ${name}!"          // "Hello, world!"
let calc = f"1 + 2 = ${1 + 2}"       // "1 + 2 = 3"
```

### 1.7 演算子と区切り文字

#### 複数文字トークン (優先的にマッチ)

```
=>  ==  !=  <=  >=  &&  ||  ++  ->
```

#### 単一文字トークン

```
+  -  *  /  <  >  !  =  :  .  ,  ;  @  ?  |  &
(  )  {  }  [  ]
```

**注意**: KATARI には `%` (剰余) 演算子が存在しない。剰余演算には組み込み関数を使用する。

### 1.8 セミコロン自動挿入

KATARI は改行位置に基づいてセミコロンを自動挿入する。以下の条件をすべて満たすとき、2 つのトークン間にセミコロンが挿入される。

1. 2 つのトークンが異なる行に存在する (後のトークンの行番号が前のトークンの行番号より大きい)
2. 前のトークンが **noSemiAfter** 集合に属さない
3. 後のトークンが **noSemiBefore** 集合に属さない

#### noSemiAfter (行末にあるとき、その後の改行にセミコロンを挿入しないトークン)

| カテゴリ       | トークン                                                         |
|---------------|------------------------------------------------------------------|
| 開き括弧      | `{`, `(`, `[`                                                    |
| 区切り        | `,`                                                               |
| 二項演算子    | `+`, `-`, `*`, `/`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `&&`, `\|\|`, `++` |
| 代入・矢印    | `=`, `->`, `=>`                                                  |
| その他         | `:`, `with`, `of`, `@`, `.`                                     |

#### noSemiBefore (行頭にあるとき、その前の改行にセミコロンを挿入しないトークン)

| カテゴリ       | トークン                          |
|---------------|-----------------------------------|
| 閉じ括弧      | `)`, `]`, `}`                     |
| キーワード     | `case`, `else`, `then`, `of`     |
| 型演算子       | `\|`, `&`                        |

これにより、式を複数行にまたがって記述する場合でも自然に解析される。

```katari
// セミコロンは自動挿入される
let x = 42        // ← ここにセミコロン挿入
let y = 10        // ← ここにセミコロン挿入

// 演算子で行をまたぐ場合、セミコロンは挿入されない
let sum = x +
  y                // + が noSemiAfter のため挿入されない

// メソッドチェーン: . は noSemiAfter かつ noSemiBefore
let result = obj
  .field           // . が noSemiBefore のため挿入されない
  .method()

// 型の union/intersection: |, & は noSemiBefore
type T = integer
  | string         // | が noSemiBefore のため挿入されない
  | null

// else は noSemiBefore
if cond {
  a
} else {           // else が noSemiBefore のため挿入されない
  b
}
```

---

## 2. 演算子の優先順位

優先順位の高い順 (上が高い)。同一行内の演算子は同じ優先順位を持つ。

| 優先度 | 演算子             | 結合性   | 説明                   |
|--------|--------------------|----------|------------------------|
| 8      | `expr(args)`       | 左       | 関数/agent 呼び出し    |
| 8      | `expr.field`       | 左       | フィールドアクセス     |
| 8      | `expr[idx]`        | 左       | 配列インデックス       |
| 7      | `-` (単項), `!`    | 前置     | 単項マイナス、論理否定 |
| 6      | `*`, `/`           | 左       | 乗算、除算             |
| 5      | `+`, `-`           | 左       | 加算、減算             |
| 4      | `++`               | 左       | 文字列結合 / 配列結合  |
| 3      | `<`, `>`, `<=`, `>=` | 非結合 | 比較 (チェイン不可)    |
| 2      | `==`, `!=`         | 非結合   | 等値比較 (チェイン不可)|
| 1      | `&&`               | 左       | 論理積                 |
| 0      | `\|\|`             | 左       | 論理和                 |

比較演算子 (`<`, `>`, `<=`, `>=`) と等値演算子 (`==`, `!=`) は非結合 (non-associative) である。`a < b < c` のような連鎖は構文エラーとなる。

後置演算子 (関数呼び出し、フィールドアクセス、配列インデックス) は最も高い優先順位を持ち、左から右へ結合する。

```katari
// 配列インデックスはフィールドアクセスの特殊形式に脱糖される
arr[0]   // → arr.__index__(0)
```

---

## 3. 文法 (EBNF)

以下の EBNF で KATARI の完全な文法を定義する。`?` は省略可能、`*` は 0 回以上の繰り返し、`+` は 1 回以上の繰り返しを示す。

### 3.1 モジュール

```ebnf
module  ::= decl*
```

各ソースファイル (`.ktr`) が 1 つのモジュールに対応する。モジュール名はファイルパスから導出される。

### 3.2 宣言 (Declaration)

```ebnf
decl  ::= import_decl
        | type_decl
        | annotated_decl

annotated_decl  ::= annotation? (val_decl | agent_decl | request_decl | external_decl)
```

アノテーション (`@"..."`) と宣言キーワードの間に改行があってもよい (自動挿入されたセミコロンは読み飛ばされる)。

#### 3.2.1 import 宣言

```ebnf
import_decl  ::= 'import' module_path ('as' identifier)? ('{' ident_list '}')?
module_path  ::= identifier ('.' identifier)*
ident_list   ::= identifier (',' identifier)* ','?
```

```katari
import lib.math                   // モジュール全体をインポート
import lib.http as http           // エイリアス付きインポート
import lib.utils { max, min }    // 選択的インポート
```

#### 3.2.2 val 宣言

```ebnf
val_decl  ::= 'val' identifier (':' type)? '=' expr
```

モジュールレベルの不変値束縛。型注釈は省略可能 (省略時は `unknown` として扱われる)。

```katari
val pi: number = 3.14159
val greeting = "hello"
```

#### 3.2.3 agent 宣言

```ebnf
agent_decl  ::= 'agent' identifier '(' params? ')' ('->' type)?
                  ('with' request_effect)? block
params      ::= param (',' param)* ','?
param       ::= identifier ':' type annotation?
```

agent は KATARI の基本的な計算単位である。パラメータ、戻り値型、使用する request エフェクト、および本体ブロックを持つ。

- 戻り値型 (`-> type`) を省略した場合、本体の型から推論される。
- `with` 節を省略した場合、本体から使用される request が推論される。

```katari
agent add(a: integer, b: integer) -> integer {
  a + b
}

agent greet(name: string @"挨拶する相手の名前") -> string {
  f"Hello, ${name}!"
}
```

#### 3.2.4 request 宣言

```ebnf
request_decl  ::= 'request' identifier '(' params? ')' '->' type
```

request は agent が外部に対して発行する効果 (エフェクト) の宣言である。request 自体は実装を持たず、handle ブロックまたは外部ランタイムによって処理される。

```katari
request get_input(prompt: string) -> string
request throw_error(message: string) -> never
```

#### 3.2.5 external 宣言

```ebnf
external_decl  ::= 'external' (ext_agent_decl | ext_request_decl)

ext_agent_decl    ::= 'agent' identifier '(' params? ')' '->' type
                        ('with' request_effect)? 'from' string_literal

ext_request_decl  ::= 'request' identifier '(' params? ')' '->' type
                        'from' string_literal
```

外部サーバーが提供する agent や request を宣言する。`from` 節の文字列は `"サーバー名:エンティティ名"` の形式を取る。

```katari
@"AI に質問する"
external agent ask_ai(prompt: string) -> string from "ai_server:ask"

external request fetch_data(url: string) -> string from "http:get"
```

#### 3.2.6 type 宣言

```ebnf
type_decl  ::= 'type' identifier '=' type
```

型エイリアスを定義する。アノテーションは付けられない。

```katari
type UserId = integer
type Shape = { uniq kind: "circle", radius: number }
           | { uniq kind: "rect", width: number, height: number }
```

### 3.3 アノテーション

```ebnf
annotation  ::= '@' string_literal
```

セマンティックアノテーションは文字列リテラルのみを受け付ける。agent 宣言、request 宣言、パラメータ、および external 宣言に付与できる。動的な式は使用できない。

```katari
@"ユーザーの入力を取得する"
agent get_user_name(prompt: string @"表示するプロンプト") -> string {
  // ...
}
```

### 3.4 Request Effect

```ebnf
request_effect  ::= 'agent'
                   | identifier ('|' identifier)*
```

`with` 節で agent が発行しうる request を宣言する。

- `with agent` -- すべての request を発行しうることを示す (完全エフェクト転送)
- `with req1 | req2 | ...` -- 列挙された request のみを発行する

```katari
agent pure_fn(x: integer) -> integer with agent {
  x * 2
}

agent uses_io() -> string with get_input | notify {
  let s = get_input("name?")
  notify(s)
  s
}
```

### 3.5 ブロック

```ebnf
block  ::= '{' block_body '}'
block_body  ::= stmt* expr?
```

ブロックは文の列と、省略可能な末尾式から構成される。末尾式がある場合、その値がブロック全体の値となる。末尾式がない場合、ブロックの値は暗黙的に `null` となる。

```katari
{
  let x = 10     // 文
  let y = 20     // 文
  x + y          // 末尾式 → ブロックの値は 30
}

{
  let x = 10     // 文 → ブロックの値は暗黙的に null
}
```

### 3.6 文 (Statement)

```ebnf
stmt  ::= let_stmt
        | handle_stmt
        | return_stmt
        | continue_stmt
        | break_stmt
        | expr_stmt

expr_stmt  ::= expr ';'?
```

#### 3.6.1 let 文

```ebnf
let_stmt  ::= 'let' pattern '=' expr
```

不変変数束縛。パターンによる分配束縛が可能。

```katari
let x = 42
let name: string = "Alice"
let { name = n, age = a } = user
let [first, second] = pair
```

#### 3.6.2 handle 文

```ebnf
handle_stmt    ::= 'handle' handle_params? '{' req_case* '}' then_clause?
handle_params  ::= '(' handle_param (',' handle_param)* ','? ')'
handle_param   ::= identifier ':' type annotation? '=' expr
req_case       ::= 'request' identifier '(' pattern_list? ')' '=>' block
then_clause    ::= 'then' '(' identifier ')' block
pattern_list   ::= pattern (',' pattern)* ','?
```

handle 文の詳細な意味論については 4 節を参照。

#### 3.6.3 return 文

```ebnf
return_stmt  ::= 'return' expr
```

`return` は囲む agent の本体から脱出し、式の値を agent の戻り値とする。`return` はどの文脈 (handle, for, if, match 等の内部) から使用しても、常に最も近い agent の本体まで制御を戻す。

```katari
agent early_return(x: integer) -> string {
  if x < 0 {
    return "negative"
  }
  "non-negative"
}
```

#### 3.6.4 continue 文

`continue` 文はそれが記述された制御文脈によって意味が異なる。

```ebnf
// handle の request handler 内:
continue_handle  ::= 'continue' expr ('with' state_update)?

// for ループの本体内:
continue_for     ::= 'continue' ('with' state_update)?

state_update     ::= '{' update_field (',' update_field)* ','? '}'
update_field     ::= identifier '=' expr
```

- **handle 文脈**: `continue val` は request への応答値を返し、request 発行元での実行を再開する。`with { ... }` で handle の状態変数を更新できる。
- **for 文脈**: `continue` は次のイテレーションに進む。`with { ... }` で状態変数を更新できる。値は取らない。

```katari
// handle 文脈
handle (counter: integer = 0) {
  request get_count() => {
    continue counter with { counter = counter + 1 }
  }
}

// for 文脈
for (let x of xs, var sum: integer = 0) {
  continue with { sum = sum + x }
}
```

#### 3.6.5 break 文

```ebnf
break_stmt  ::= 'break' expr
```

`break` の意味も制御文脈によって異なる。

- **handle 文脈** (handle のスコープ本体内または request handler 内): handle スコープから脱出し、式の値を handle 全体の結果とする。
- **for 文脈** (for ループの本体内): for ループから脱出し、式の値を for 式の結果とする。

```katari
// handle 文脈: request handler 内から break
handle {
  request get_value() => {
    break 42   // handle スコープ全体を終了し、結果を 42 にする
  }
}

// for 文脈: ループ内から break
for (let x of [1, 2, 3]) {
  if x == 2 {
    break x    // for ループを終了し、結果を 2 にする
  }
}
```

### 3.7 式 (Expression)

```ebnf
expr  ::= if_expr
        | match_expr
        | for_expr
        | par_expr
        | bin_expr
```

すべての式は値を持つ (式指向言語)。

#### 3.7.1 if 式

```ebnf
if_expr      ::= 'if' bin_expr block else_branch?
else_branch  ::= 'else' (block | if_expr)
```

`else` 節がない場合、条件不成立時の値は `null` であり、式の型は `then_type | null` となる。

```katari
let x = if cond { 10 } else { 20 }

// else なし → integer | null
let y = if cond { 10 }

// else if チェーン
let z = if a > 10 {
  "big"
} else if a > 5 {
  "medium"
} else {
  "small"
}
```

#### 3.7.2 match 式

```ebnf
match_expr  ::= 'match' bin_expr '{' case_arm+ '}'
case_arm    ::= 'case' pattern '=>' block
```

match 式は値に対してパターンマッチを行い、最初にマッチした case のブロックを実行する。

```katari
match value {
  case 1 => { "one" }
  case 2 => { "two" }
  case integer(n) => { f"other int: ${n}" }
  case string(s) => { s }
  case _other => { "unknown" }
}
```

#### 3.7.3 for 式

```ebnf
for_expr      ::= 'for' '(' for_bindings ')' block then_block?
for_bindings  ::= for_let* for_var*
for_let       ::= 'let' identifier 'of' expr ','?
for_var       ::= 'var' identifier (':' type)? annotation? '=' expr ','?
then_block    ::= 'then' block
```

for 式の詳細な意味論については 5 節を参照。

#### 3.7.4 par 式

```ebnf
par_expr   ::= 'par' '[' par_block_list? ']'
par_block_list  ::= block (',' block)* ','?
```

par 式の詳細な意味論については 6 節を参照。

#### 3.7.5 二項式・単項式

```ebnf
bin_expr     ::= unary_expr (bin_op unary_expr)*
bin_op       ::= '||' | '&&' | '==' | '!=' | '<' | '<=' | '>' | '>=' | '++' | '+' | '-' | '*' | '/'
unary_expr   ::= ('-' | '!') unary_expr
               | postfix_expr
```

演算子の優先順位と結合性は 2 節の表に従う。

#### 3.7.6 後置式

```ebnf
postfix_expr  ::= primary_expr postfix*
postfix       ::= '(' arg_list? ')'          -- 関数/agent 呼び出し
                 | '.' identifier             -- フィールドアクセス
                 | '[' expr ']'               -- 配列インデックス

arg_list      ::= expr (',' expr)* ','?
```

配列インデックス `expr[idx]` は内部的に `expr.__index__(idx)` へ脱糖される。

#### 3.7.7 一次式

```ebnf
primary_expr  ::= integer_literal
                 | number_literal
                 | string_literal
                 | multiline_string
                 | template_literal
                 | bool_literal
                 | null_literal
                 | qualified_name
                 | object_literal
                 | array_literal
                 | block
                 | '(' expr ')'

qualified_name  ::= identifier ('.' identifier)*
```

##### オブジェクトリテラル

```ebnf
object_literal  ::= '{' '}'
                   | '{' obj_field ((',' | ';') obj_field)* (',' | ';')? '}'
obj_field       ::= 'uniq'? identifier '=' expr
```

`uniq` キーワード付きフィールドは判別共用体 (discriminated union) のタグフィールドを示す。

```katari
let point = { x = 10, y = 20 }
let circle = { uniq kind = "circle", radius = 5.0 }
{}  // 空オブジェクト
```

##### 配列リテラル

```ebnf
array_literal  ::= '[' (expr (',' expr)* ','?)? ']'
```

```katari
let xs = [1, 2, 3, 4, 5]
let empty: array[integer] = []
```

#### 3.7.8 ブロック式 vs オブジェクトリテラルの曖昧性解消

`{` が式の位置に出現した際、以下のルールで曖昧性を解消する。

1. `{ }` → **空オブジェクトリテラル**
2. `{ identifier = ...` → **オブジェクトリテラル**
3. `{ uniq identifier = ...` → **オブジェクトリテラル**
4. それ以外 → **ブロック式**

### 3.8 パターン (Pattern)

```ebnf
pattern  ::= prim_tag_pat
           | obj_pat
           | arr_pat
           | lit_pat
           | var_pat

var_pat       ::= identifier (':' type)? annotation?
prim_tag_pat  ::= prim_tag '(' identifier (':' type)? annotation? ')'
prim_tag      ::= 'boolean' | 'integer' | 'number' | 'string'
lit_pat       ::= integer_literal | number_literal | string_literal
                 | bool_literal | null_literal
obj_pat       ::= '{' obj_field_pat ((',' | ';') obj_field_pat)* (',' | ';')? '}'
                 | '{' '}'
obj_field_pat ::= 'uniq'? identifier '=' pattern
arr_pat       ::= '[' (pattern (',' pattern)* ','?)? ']'
```

#### 3.8.1 変数パターン (`PVar`)

識別子に値を束縛する。`_` で始まる名前は慣例として「未使用」を示す。

```katari
case x => { ... }        // x に束縛
case _unused => { ... }  // 値を捨てる
```

#### 3.8.2 型付き変数パターン (`PTyped`)

識別子に値を束縛し、同時に型注釈を付ける。型チェッカが推論型と注釈型の整合性を検証する。

```katari
let x: integer = 42
let name: string = "Alice"
```

#### 3.8.3 リテラルパターン (`PLit`)

値がリテラルと等しいときにマッチする。

```katari
case null => { ... }
case true => { ... }
case 42 => { ... }
case "hello" => { ... }
```

#### 3.8.4 プリミティブタグパターン (`PTag`)

ランタイムで値の型を検査し、マッチした場合に変数に束縛する。

```katari
case boolean(b) => { ... }   // 値が boolean のとき b に束縛
case integer(n) => { ... }   // 値が integer のとき n に束縛
case number(n) => { ... }    // 値が number のとき n に束縛
case string(s) => { ... }    // 値が string のとき s に束縛
```

**注意**: `integer` と `number` の判定は排他的である。整数値は `integer(n)` にのみマッチし、`number(n)` にはマッチしない (言語の型システムでは integer は number のサブタイプではない)。

#### 3.8.5 オブジェクトパターン (`PObj`)

オブジェクトの指定フィールドに対して再帰的にパターンマッチする。

```katari
case { name = n, age = a } => { ... }
case { uniq kind = "circle", radius = r } => { ... }
```

`uniq` フィールドパターンは判別共用体の識別に使用される。

#### 3.8.6 配列パターン (`PArr`)

配列の各要素に対して位置ベースでパターンマッチする。

```katari
case [first, second] => { ... }
case [] => { ... }
```

### 3.9 型 (Type)

```ebnf
type          ::= union_type
union_type    ::= intersect_type ('|' intersect_type)*
intersect_type ::= primary_type ('&' primary_type)*

primary_type  ::= 'null'
                | 'boolean'
                | 'integer'
                | 'number'
                | 'string'
                | 'never'
                | 'unknown'
                | bool_literal
                | integer_literal
                | number_literal
                | string_literal
                | array_type
                | object_type
                | '(' type ')'
                | qualified_alias

array_type      ::= 'array' '[' type ']'
object_type     ::= '{' '}'
                   | '{' obj_type_field ((',' | ';') obj_type_field)* (',' | ';')? '}'
obj_type_field  ::= 'uniq'? identifier '?'? ':' type annotation?
qualified_alias ::= identifier ('.' identifier)*
```

#### 3.9.1 プリミティブ型

| 型        | 説明                       |
|-----------|----------------------------|
| `null`    | null 値のみを含む型        |
| `boolean` | `true` と `false` を含む型 |
| `integer` | 整数を含む型               |
| `number`  | 浮動小数点数を含む型       |
| `string`  | 文字列を含む型             |
| `never`   | 値を持たない型 (ボトム型)  |
| `unknown` | すべての値を含む型 (トップ型) |

#### 3.9.2 リテラル型

具体的なリテラル値をそのまま型として使用できる。

```katari
type Yes = true
type AnswerToLife = 42
type Greeting = "hello"
```

#### 3.9.3 配列型

```katari
type IntList = array[integer]
type Matrix = array[array[number]]
```

#### 3.9.4 オブジェクト型

フィールド名、型、オプショナルフラグ、`uniq` フラグを持つ。

```katari
type User = {
  name: string,
  age: integer,
  email?: string         // オプショナルフィールド
}

type Shape = {
  uniq kind: "circle",   // uniq フィールド (判別タグ)
  radius: number
}
```

- `?` 付きフィールドはオプショナルで、値が存在しない場合がある。
- `uniq` フィールドは判別共用体のタグとして使用される。

#### 3.9.5 共用体型 (Union Type)

```katari
type StringOrInt = string | integer
type Nullable = integer | null
```

#### 3.9.6 交差型 (Intersection Type)

```katari
type Named = { name: string }
type Aged = { age: integer }
type Person = Named & Aged   // { name: string, age: integer }
```

#### 3.9.7 型エイリアス

`type` 宣言で定義された名前を使用する。修飾名 (`module.TypeName`) でモジュール越しに参照可能。

```katari
type UserId = integer
let id: UserId = 42   // UserId は integer のエイリアス
```

---

## 4. handle の意味論

### 4.1 概要

`handle` は **文** (statement) であり、agent の本体ブロック内に記述する。handle 文はそれが記述された位置から囲むブロックの末尾までの**スコープ**を形成し、そのスコープ内で発行された request を捕捉・処理する。

```katari
agent example() -> integer {
  // ── handle 文 ──
  handle (state_var: integer = 0) {
    request some_request(arg) => {
      continue response_value with { state_var = state_var + 1 }
    }
  } then (result) {
    result + state_var
  }
  // ── handle のスコープ本体: ここから下がスコープ ──
  let v = some_request(42)
  v
  // ── スコープ終了 (ブロック末尾) ──
}
```

### 4.2 状態パラメータ

```katari
handle (counter: integer = 0, total: number = 0.0) {
  ...
}
```

handle は 0 個以上の状態パラメータを持つ。各パラメータは名前、型、および初期値を持つ。request handler 内で `continue ... with { ... }` を使用して更新できる。状態パラメータは `then` 節でも参照可能。

### 4.3 request case

```katari
handle {
  request get_count() => {
    continue counter with { counter = counter + 1 }
  }
  request set_value(v) => {
    continue null with { total = total + v }
  }
}
```

各 request case は `request name(params) => block` の形式で記述する。スコープ内でその名前の request が発行されると、対応する case のブロックが実行される。

request case 内では以下の制御文が使用可能:

- **`continue val`** / **`continue val with { updates }`** -- request への応答値 `val` を返し、request 発行元の実行を再開する。`with` 節で状態変数を更新できる。
- **`break val`** -- handle スコープ全体から脱出し、`val` を結果とする。

### 4.4 then 節

```katari
handle {
  request get_value() => { break 42 }
} then (result) {
  f"Result: ${result}"
}
```

`then` 節は省略可能で、`then (変数名) { body }` の形式で記述する。handle のスコープ本体が正常に完了 (break せずに末尾に到達) した場合、本体の結果値が変数に束縛され、`then` 節のブロックが実行される。`then` 節内では handle の状態パラメータも参照可能。

### 4.5 スコープ内での break

handle のスコープ本体内 (request handler の外) でも `break` を使用でき、handle スコープから脱出する。

```katari
agent example() -> integer {
  handle {
    request get_value() => { continue 0 }
  }
  let v = get_value()
  if v == 0 {
    break 999   // handle スコープから脱出
  }
  v
}
```

### 4.6 ネストした handle

handle はネストできる。内側の handle の break は内側のスコープのみに影響し、外側のスコープには伝播しない。

```katari
agent nested_example() -> string {
  handle {
    request outer_req() => { break "outer" }
  }
  let x = outer_req()
  handle {
    request inner_req() => { break f"inner with ${x}" }
  }
  inner_req()
}
```

---

## 5. for ループの意味論

### 5.1 構造

```katari
for (let x of array_expr, var acc: Type = init_expr) {
  // body
} then {
  // then block
}
```

for 式は以下の要素から構成される:

- **let 束縛** (`let x of expr`): 配列の各要素を順にイテレートする不変変数。複数指定可能。
- **var 束縛** (`var name: Type = init`): ループを通じて引き回される状態変数。初期値を持ち、`continue with { ... }` で更新される。複数指定可能。
- **本体ブロック**: 各イテレーションで実行される。
- **then 節** (省略可能): ループが break されずにすべてのイテレーションを完了した後に実行される。状態変数を参照可能。

### 5.2 制御フロー

for の本体内では以下の制御文が使用可能:

- **`continue`** / **`continue with { updates }`** -- 状態変数を更新し、次のイテレーションに進む。値は取らない。
- **`break val`** -- for ループから即座に脱出し、`val` を for 式の結果とする。

### 5.3 型規則

- `then` 節なし: for 式の型は `null | break_type`。すべてのイテレーションが完了した場合 `null`。
- `then` 節あり: for 式の型は `then_type | break_type`。すべてのイテレーションが完了した場合は `then` 節の結果型。

ここで `break_type` は本体内のすべての `break` 式の型の共用体である。

### 5.4 let 束縛と var 束縛の順序

文法上、let 束縛はすべて var 束縛の前に記述しなければならない。

```katari
// 正しい
for (let x of xs, let y of ys, var sum: integer = 0) { ... }

// 不正 (let の後に var、さらに let)
for (let x of xs, var sum: integer = 0, let y of ys) { ... }
```

### 5.5 例

```katari
// 配列の合計
agent sum(xs: array[integer]) -> integer {
  for (let x of xs, var acc: integer = 0) {
    continue with { acc = acc + x }
  } then {
    acc
  }
}

// 最初の負の数を探す
agent find_negative(xs: array[integer]) -> integer | null {
  for (let x of xs) {
    if x < 0 {
      break x
    }
  }
}

// 複数の状態変数
agent stats(xs: array[integer]) -> { sum: integer, count: integer } {
  for (let x of xs,
       var sum: integer = 0,
       var count: integer = 0) {
    continue with { sum = sum + x, count = count + 1 }
  } then {
    { sum = sum, count = count }
  }
}
```

---

## 6. par の意味論

### 6.1 構造

```katari
par [
  { block1 },
  { block2 },
  ...
]
```

`par` 式は複数のブロックを並行に実行する。各ブロックは独立したスレッド (子エージェント) として起動される。

### 6.2 実行モデル

- すべてのブロックが並行に実行を開始する。
- すべてのブロックが完了した時点で `par` 式が完了する。
- 結果は各ブロックの結果値を要素とする配列であり、ブロックの記述順序に対応する。
- 各ブロックは親スコープの変数 (`let` で束縛された不変変数) を参照できる。

### 6.3 型

`par` 式の型は `array[T1 | T2 | ...]` で、`Ti` は各ブロックの結果型。空の `par []` は `array[null]` 型を返す (空配列)。

### 6.4 例

```katari
agent parallel_fetch() -> array[string] {
  let prefix = "data"
  par [
    {
      let x = fetch("url1")
      f"${prefix}: ${x}"
    },
    {
      let y = fetch("url2")
      f"${prefix}: ${y}"
    }
  ]
}

agent empty() -> array[null] {
  par []
}
```

---

## 7. 制御フロースコーピング規則

KATARI では `return`, `break`, `continue` の 3 種の制御フロー文があり、それぞれ異なるスコープ規則に従う。

### 7.1 return

`return expr` は常に最も近い **agent の本体**まで制御を戻す。agent が `return` を実行すると、即座に本体の実行を終了し、`expr` の値を agent の戻り値とする。

`return` は agent 本体内のどの深さからでも使用できる (if, match, for, handle の内部を含む)。for ループ内で `return` を使用した場合、ループを脱出するのではなく、agent 自体から脱出する。

```katari
agent example() -> integer {
  for (let x of [1, 2, 3]) {
    if x == 2 {
      return 999   // agent から脱出 (for ループの break ではない)
    }
  }
  0
}
```

### 7.2 break

`break` の対象スコープはパーサーによって静的に決定される。

| 制御文脈                     | `break val` の効果                   |
|-----------------------------|--------------------------------------|
| handle のスコープ本体内      | handle スコープから脱出              |
| handle の request handler 内 | handle スコープから脱出              |
| for ループの本体内           | for ループから脱出                   |

ネストした for/handle がある場合、`break` は最も近い for または handle のスコープに対応する。

```katari
agent nested_break() -> integer {
  handle {
    request r() => { continue 0 }
  }
  // ここの break は外側の handle に対応
  for (let x of [1, 2, 3]) {
    // ここの break は for ループに対応
    if x == 2 { break x }
  }
  0
}
```

### 7.3 continue

`continue` の対象スコープもパーサーによって静的に決定される。

| 制御文脈                     | `continue` の効果                    |
|-----------------------------|--------------------------------------|
| handle の request handler 内 | `continue val` で request に応答     |
| for ループの本体内           | `continue` で次のイテレーションへ    |

handle 文脈の `continue` は応答値を必須引数に取る。for 文脈の `continue` は値を取らない。いずれも `with { ... }` による状態変数の更新が可能。

### 7.4 制御フロー信号の伝播

ランタイムレベルでは、制御フロー文は以下の信号を生成する:

| 制御文        | 信号            | 捕捉される場所        |
|--------------|-----------------|----------------------|
| `return`     | FnReturn        | agent 本体の境界     |
| `break` (handle) | HandleBreak | handle スコープの境界 |
| `break` (for)    | ForBreak    | for ループの境界     |
| `continue` (handle) | Normal (応答付き) | request handler の境界 |
| `continue` (for)    | ForContinue | for ループの境界     |

FnReturn 信号は for ループや handle スコープを貫通して agent の本体まで伝播する。ForBreak および HandleBreak 信号はそれぞれ対応する for/handle の境界で捕捉される。

---

## 8. サンプルコード

### 8.1 基本的な agent と関数呼び出し

```katari
agent add(a: integer, b: integer) -> integer {
  a + b
}

agent main() -> integer {
  let result = add(10, 20)
  result * 2
}
```

### 8.2 判別共用体とパターンマッチ

```katari
type Shape = { uniq kind: "circle", radius: number }
           | { uniq kind: "rect", width: number, height: number }

agent area(s: Shape) -> number {
  match s {
    case { uniq kind = "circle", radius = r } => {
      3.14159 * r * r
    }
    case { uniq kind = "rect", width = w, height = h } => {
      w * h
    }
  }
}
```

### 8.3 request と handle による例外処理

```katari
request throw(message: string) -> never

agent safe_divide(a: number, b: number) -> number with throw {
  if b == 0.0 {
    throw("division by zero")
  }
  a / b
}

agent main() -> number {
  handle {
    request throw(message) => {
      break 0.0
    }
  }
  safe_divide(10.0, 0.0)
}
```

### 8.4 handle の状態パラメータ

```katari
request get_count() -> integer

agent counter_user() -> integer with get_count {
  let c1 = get_count()
  let c2 = get_count()
  let c3 = get_count()
  c3
}

agent main() -> integer {
  handle (counter: integer = 0) {
    request get_count() => {
      continue counter with { counter = counter + 1 }
    }
  }
  counter_user()  // c1=0, c2=1, c3=2 → 結果は 2
}
```

### 8.5 for ループによるアキュムレータ

```katari
agent sum(xs: array[integer]) -> integer {
  for (let x of xs, var acc: integer = 0) {
    continue with { acc = acc + x }
  } then {
    acc
  }
}

agent find_first_even(xs: array[integer]) -> integer | null {
  for (let x of xs) {
    if x == x / 1 * 2 {  // 偶数チェック (% 演算子なし)
      break x
    }
  }
}
```

### 8.6 par による並行処理

```katari
@"AI に質問する"
external agent ask_ai(prompt: string) -> string from "ai_server:ask"

agent main() -> array[string] {
  let questions = ["What is KATARI?", "How does it work?"]
  par [
    { ask_ai(questions[0]) },
    { ask_ai(questions[1]) }
  ]
}
```

### 8.7 テンプレートリテラルとオブジェクト

```katari
type User = { name: string, age: integer }

agent describe(user: User) -> string {
  f"${user.name} is ${user.age} years old"
}

agent main() -> string {
  let user = { name = "Alice", age = 30 }
  describe(user)
}
```

### 8.8 ネストした制御構造

```katari
request get_seed() -> integer
request notify(v: integer) -> null

agent complex_example() -> integer {
  handle {
    request get_seed() => { continue 10 }
  }
  let seed = get_seed()
  for (let x of [1, 2, 3], var total: integer = seed) {
    handle (count: integer = 0) {
      request notify(v) => {
        continue null with { count = count + 1 }
      }
    }
    notify(x)
    continue with { total = total + x }
  } then {
    total  // 10 + 1 + 2 + 3 = 16
  }
}
```

### 8.9 外部 agent と request

```katari
@"cron ジョブを登録する"
external agent register_cron(
  schedule: string @"cron 式",
  callback: string @"コールバック agent 名"
) -> null from "cron_server:register"

external request get_user_input(
  prompt: string @"表示するプロンプト"
) -> string from "discord_server:input"

agent setup() -> null with get_user_input {
  let schedule = get_user_input("Enter cron schedule:")
  register_cron(schedule, "my_job")
}
```

### 8.10 型エイリアスとオプショナルフィールド

```katari
type Config = {
  host: string
  port?: integer
  debug?: boolean
}

type Result = { uniq status: "ok", data: string }
            | { uniq status: "error", message: string }

agent process_config(cfg: Config) -> Result {
  match cfg {
    case { host = h } => {
      { uniq status = "ok", data = f"Connected to ${h}" }
    }
  }
}
```
