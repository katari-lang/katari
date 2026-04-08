# KATARI Language Specification - Syntax

## 字句規則

### コメント

```
// 行コメント
/* ブロックコメント (ネスト可能) */
```

### キーワード

```
val let task if else match case return reply next break
request type import as with from for finally of var handle
external null true false par throw
```

### 識別子

```
identifier  ::= letter (letter | digit | '_')*
letter      ::= 'a'..'z' | 'A'..'Z' | '_'
digit       ::= '0'..'9'
```

識別子はキーワードと同名であってはならない。

### リテラル

```
integer_literal  ::= digit+
number_literal   ::= digit+ '.' digit+
string_literal   ::= '"' string_char* '"'
string_char      ::= (任意の文字 except '"' and '\') | escape_seq
escape_seq       ::= '\\' ('n' | 't' | 'r' | '\\' | '"' | '$')
bool_literal     ::= 'true' | 'false'
null_literal     ::= 'null'
```

### 複数行文字列

```
multiline_string  ::= '"""' newline multiline_char* newline '"""'
```

最初と最後の改行はコンテンツに含まれない。`"""` の直後は必ず改行でなければならない。

### テンプレートリテラル

```
template_literal  ::= 'f"' template_char* '"'
                     | 'f"""' newline template_char* newline '"""'
template_char     ::= string_char | '${' expr '}'
```

`${expr}` 内の式は `to_string` で文字列に変換される。

### 演算子と区切り文字

```
+  -  *  /  %  ==  !=  <  >  <=  >=  &&  ||  ++  !
=  ->  :  .  ,  ;  @  ?
(  )  {  }  [  ]
```

## セミコロン自動挿入

改行がセミコロンとして扱われる条件:

1. 行末のトークンが以下の**いずれでもない**場合、改行はセミコロンとして扱われる:
   - `{`, `(`, `[`
   - `,`
   - 二項演算子: `+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `&&`, `||`, `++`
   - `=`, `->`, `:`, `with`, `of`, `@`, `.`

2. 次の行の先頭トークンが以下の場合、先行する改行はセミコロンとして扱われ**ない**:
   - `.`, `)`, `]`, `}`
   - `case`

### カンマ

カンマは関数引数、オブジェクトフィールド、配列要素の区切りに使用する。改行もカンマの代わりに使用可能。末尾カンマ (trailing comma) は許容される。

## 演算子の優先順位

優先度の高い順:

| 優先度 | 演算子 | 結合性 | 説明 |
|--------|--------|--------|------|
| 7 | `-` (単項), `!` | 右 | 単項マイナス、論理否定 |
| 6 | `*`, `/`, `%` | 左 | 乗算、除算、剰余 |
| 5 | `+`, `-` | 左 | 加算、減算 |
| 4 | `++` | 左 | 文字列結合 / 配列結合 |
| 3 | `<`, `>`, `<=`, `>=` | なし | 比較 (チェイン不可) |
| 2 | `==`, `!=` | なし | 等値比較 (チェイン不可) |
| 1 | `&&` | 左 | 論理積 |
| 0 | `\|\|` | 左 | 論理和 |

## 文法 (EBNF)

### モジュール

```ebnf
module      ::= decl*
```

各ソースファイルが 1 つのモジュールに対応する。モジュール名はファイルパスから導出される (-> [05-module-system.md](05-module-system.md))。

### 宣言 (Declaration)

```ebnf
decl        ::= import_decl
              | val_decl
              | task_decl
              | request_decl
              | external_task_decl
              | external_request_decl
              | type_decl

import_decl ::= 'import' module_path ('as' identifier)?
                  ('{' identifier (',' identifier)* '}')?

val_decl    ::= annotation? 'val' identifier (':' type)? '=' expr

task_decl   ::= annotation? 'task' identifier '(' params? ')' ('->' type)?
                  ('with' request_effect)? block

request_decl
            ::= annotation? 'request' identifier '(' params? ')' '->' type

external_task_decl
            ::= annotation? 'external' 'task' identifier '(' params? ')' '->' type
                  ('with' request_effect)? 'from' string_literal

external_request_decl
            ::= annotation? 'external' 'request' identifier '(' params? ')' '->' type
                  'from' string_literal

type_decl   ::= 'type' identifier '=' type
```

### 注釈 (Annotation)

```ebnf
annotation  ::= '@' string_literal
```

Semantic annotation は文字列リテラルのみ。動的な変数は挿入不可。

### パラメータ

```ebnf
params      ::= param (',' param)*
param       ::= identifier ':' type annotation?
```

### ブロック

```ebnf
block       ::= '{' stmt* expr '}'
              | '{' stmt* '}'       -- 暗黙の null を返す
```

### 文 (Statement)

```ebnf
stmt        ::= let_stmt
              | handle_stmt
              | expr_stmt

let_stmt    ::= 'let' pattern '=' expr

handle_stmt ::= 'handle' handle_params? '{' handle_item* '}'
handle_params ::= '(' handle_param (',' handle_param)* ')'
handle_param ::= annotation? identifier ':' type annotation? '=' expr
handle_item ::= handler_request | handler_return
handler_request
            ::= 'request' identifier '(' params? ')' '=>' block
handler_return
            ::= 'return' pattern '=>' block

expr_stmt   ::= expr
```

`handle` 文は task のブロック内にインラインで記述する (Koka スタイル)。子エージェントからの `request` を捕捉し処理するハンドラを定義する。`handle_params` はハンドラの状態を定義し、`reply with` で更新できる。ハンドラはブロック内の `let` 束縛を参照できる (`let` は不変なので安全)。`handle` はそれ以降のコードに対して有効である。

### 式 (Expression)

```ebnf
expr        ::= if_expr
              | match_expr
              | for_expr
              | par_expr
              | block_expr
              | binary_expr

if_expr     ::= 'if' expr block ('else' (block | if_expr))

match_expr  ::= 'match' expr '{' match_case+ '}'
match_case  ::= 'case' pattern '=>' block

for_expr    ::= 'for' '(' for_bindings ')' block ('finally' block)?

for_bindings
            ::= for_let (',' for_let)* (',' for_var)*
              | for_var (',' for_var)*

for_let     ::= 'let' pattern 'of' expr
for_var     ::= 'var' identifier (':' type)? annotation? '=' expr

par_expr    ::= 'par' '[' par_block (',' par_block)* ','? ']'
              | 'par' '[' ']'

par_block   ::= '{' stmt* expr '}'
              | '{' stmt* '}'

block_expr  ::= block

binary_expr ::= unary_expr (binary_op unary_expr)*
binary_op   ::= '+' | '-' | '*' | '/' | '%'
              | '==' | '!=' | '<' | '>' | '<=' | '>='
              | '&&' | '||' | '++'

unary_expr  ::= ('-' | '!') unary_expr
              | postfix_expr

postfix_expr
            ::= primary_expr postfix*
postfix     ::= '(' args? ')'          -- 関数呼び出し (同期呼び出し: task を spawn し完了を待機する)
              | '.' identifier          -- フィールドアクセス
              | '[' expr ']'            -- 配列インデックス

args        ::= expr (',' expr)*

primary_expr
            ::= integer_literal
              | number_literal
              | string_literal
              | multiline_string
              | template_literal
              | bool_literal
              | null_literal
              | qualified_name
              | object_literal
              | array_literal
              | '(' expr ')'

qualified_name
            ::= identifier ('.' identifier)*

object_literal
            ::= '{' object_field (',' object_field)* '}'
              | '{' '}'

object_field
            ::= identifier '=' expr

array_literal
            ::= '[' (expr (',' expr)*)? ']'
```

### 制御文 (ブロック内)

```ebnf
-- handle 内で使用可能:
reply_stmt      ::= 'reply' expr
                   | 'reply' expr 'with' '{' state_update (',' state_update)* '}'

-- for body 内で使用可能:
next_stmt       ::= 'next'
                   | 'next' 'with' '{' state_update (',' state_update)* '}'

-- handle 内 / for body 内で使用可能:
break_stmt      ::= 'break' expr

-- task body / block 内:
return_stmt     ::= 'return' expr

state_update    ::= identifier '=' expr
```

`reply`、`next`、`break`、`return` は式ではなく文として扱う。これらは never 型を返すため、式の最後に位置する必要がある。

### パターン (Pattern)

```ebnf
pattern     ::= variable_pattern
              | typed_variable_pattern
              | literal_pattern
              | object_pattern
              | array_pattern

variable_pattern
            ::= identifier (':' type)? annotation?

typed_variable_pattern
            ::= primitive_tag '(' identifier (':' type)? annotation? ')'

primitive_tag
            ::= 'boolean' | 'integer' | 'number' | 'string'

literal_pattern
            ::= integer_literal
              | number_literal
              | string_literal
              | bool_literal
              | null_literal

object_pattern
            ::= '{' object_field_pattern (',' object_field_pattern)* '}'

object_field_pattern
            ::= ('uniq')? identifier '=' pattern

array_pattern
            ::= '[' (pattern (',' pattern)*)? ']'
```

**typed_variable_pattern** の動作:

- `boolean(x)` -- ランタイムで値が boolean かチェック
- `integer(x)` -- ランタイムで値が integer かチェック (number にもマッチしない)
- `number(x)` -- ランタイムで値が number かチェック (integer も number にマッチする)
- `string(x)` -- ランタイムで値が string かチェック

型注釈 (`: T`) はランタイムの判定には影響しない。静的型チェックのみに使用。

### 型 (Type)

```ebnf
type        ::= union_type
union_type  ::= intersect_type ('|' intersect_type)*
intersect_type
            ::= primary_type ('&' primary_type)*

primary_type
            ::= 'null'
              | 'unknown'
              | 'never'
              | 'integer' | 'number' | 'boolean' | 'string'
              | integer_literal | number_literal | string_literal | bool_literal
              | 'array' '[' type ']'
              | object_type
              | identifier                -- type alias の参照
              | '(' type ')'

object_type ::= '{' object_type_field (',' object_type_field)* '}'
              | '{' '}'

object_type_field
            ::= ('uniq')? identifier ('?')? ':' type annotation?
```

### Request Effect

```ebnf
request_effect
            ::= request_effect_union
request_effect_union
            ::= request_effect_single ('|' request_effect_single)*
request_effect_single
            ::= identifier                -- request 名の参照 (module path 含む)
```

### モジュールパス

```ebnf
module_path ::= identifier ('.' identifier)*
```

## ブロック式 vs オブジェクトリテラルの曖昧性解消

`{` が出現した際の曖昧性は以下のルールで解消する:

1. `{` の直後が `identifier =` で、かつ `identifier` が `let`, `request`, `return` でない場合は **オブジェクトリテラル**
2. `{` の直後が `}` の場合は **空のオブジェクトリテラル**
3. それ以外は **ブロック式**

## ネストした for/handle の曖昧性解消

`handle` の `handler_request` ブロック内に `for` ループがネストした場合、`reply` / `break` / `next` のスコープは以下のルールで決定する:

- `reply` は常に最も内側の `handle` の `handler_request` に対応する
- `next` は常に最も内側の `for` ループに対応する
- `break` は最も内側の `for` または `handle` の `handler_request` に対応する

```katari
task example() -> null {
  handle {
    request some_request() => {
      // ここの reply / break は handler 用
      for (let x of xs) {
        // ここの next / break は for 用
        next
      }
      // ここの reply / break は handler 用
      reply null
    }
  }
  some_task_with_loop()
}
```

## 例

### 基本的な task

```katari
task add(a: integer, b: integer) -> integer {
  a + b
}
```

### Request と handle

```katari
request throw(message: string) -> never

task safe_divide(a: number, b: number) -> number with throw {
  if b == 0 {
    throw("division by zero")
  } else {
    a / b
  }
}

task main() -> number {
  handle {
    request throw(message) => {
      break 0
    }
  }
  safe_divide(10, 0)
}
```

`safe_divide` が `throw` request を発行すると、`main` の `handle` ブロックが捕捉し、`break 0` により `main` の結果を `0` として返す。

### handle の状態パラメータと reply

```katari
request get_count() -> integer

task counting_task() -> null with get_count {
  let c1 = get_count()
  let c2 = get_count()
  let c3 = get_count()
  // c1 = 1, c2 = 2, c3 = 3
  null
}

task main() -> null {
  handle(counter: integer = 0) {
    request get_count() => {
      reply counter + 1 with {
        counter = counter + 1
      }
    }
  }
  counting_task()
}
```

### Par (並行実行)

```katari
@"AIに質問する"
external task ask_ai(prompt: string) -> string from "ai_server:ai"

task main() -> array[string] {
  par [
    { ask_ai("What is KATARI?") },
    { ask_ai("What is Qatali?") }
  ]
}
```

`par` は複数のブロックを並行実行する式。各ブロックは独立したエージェントとして起動され、全ブロックが完了した時点で結果の配列 (`array[T1 | T2 | ...]`) を返す。各ブロックは周囲の `let` 変数を参照できる (capture by value)。

### For ループ (next / break)

```katari
task sum(xs: array[integer]) -> integer {
  for (let x of xs, var acc: integer = 0) {
    next with {
      acc = acc + x
    }
  } finally {
    acc
  }
}
```

```katari
task find_first_negative(xs: array[integer]) -> integer | null {
  for (let x of xs) {
    if x < 0 {
      break x
    } else {
      next
    }
  } finally {
    null
  }
}
```

`next` は for ループの次のイテレーションに進む。`next with { ... }` で状態変数を更新できる。`break expr` はループを中断し、`expr` をループ式の結果として返す。

### Match 式

```katari
type Shape = {uniq kind: "circle", radius: number}
           | {uniq kind: "rect", width: number, height: number}

task area(s: Shape) -> number {
  match s {
    case {uniq kind = "circle", radius = r} => {
      3.14159 * r * r
    }
    case {uniq kind = "rect", width = w, height = h} => {
      w * h
    }
  }
}
```

### External task / request

```katari
@"AIに質問する"
external task ask_ai(prompt: string) -> string from "ai_server:ask"

@"cron ジョブを登録する"
external task register_cron(
  schedule: string @"cron 式"
  callback: string @"コールバック task 名"
) -> null from "cron_server:register"

external request get_user_input(prompt: string) -> string from "discord_server:input"
```

### throw (組み込み request)

```katari
// throw は組み込み request として定義済み:
// request throw(message: string) -> never

task risky_operation() -> string with throw {
  throw("something went wrong")
}

task main() -> string {
  handle {
    request throw(message) => {
      break f"Error caught: ${message}"
    }
  }
  risky_operation()
}
```

`throw` は組み込みの request であり、ランタイムがトップレベルのハンドラを提供する。ユーザーが `handle` ブロックで捕捉しない場合、ランタイムのデフォルトハンドラがエラーを報告してエージェントを終了する。
