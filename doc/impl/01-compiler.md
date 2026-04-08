# コンパイラ実装

spec 参照: `01-syntax.md`, `02-type-system.md`, `03-discriminated-unions.md`, `04-request-system.md`, `05-module-system.md`, `08-ir.md`

---

## モジュール構成と依存関係

```
Lib               公開 API
  ├── Lexer       字句解析
  ├── Parser      構文解析
  ├── Resolver    名前解決
  ├── Typechecker 型検査
  ├── Lowering    IR 変換
  └── Emit        バイナリ出力
```

---

## 1. Lexer

**役割**: ソーステキスト → トークン列 (セミコロン自動挿入込み)

**主要データ型**:
```
Token
  = TIdent(string)
  | TInt(integer) | TFloat(float) | TString(string) | TBool(bool) | TNull
  | TKeyword(Keyword)          -- task, let, handle, request, reply, break, next,
                               --   for, par, match, if, else, return, with,
                               --   import, type, external, from, null, true, false
  | TPunct(Punct)              -- ( ) [ ] { } , ; : = => -> | & ++ @ ? .
  | TOp(Op)                    -- + - * / % == != < <= > >= && || !
  | TEOF
```

**セミコロン自動挿入**: 行末のトークンが `identifier`, `integer`, `float`, `string`, `true`, `false`, `null`, `)`, `]`, `}` のいずれかなら次の改行前に `;` を挿入。

---

## 2. Parser

**役割**: トークン列 → AST

**主要データ型**:

```
Module = { name: ModuleName, decls: [Decl] }

Decl
  = DImport(ModuleName, alias?, [name]?)
  | DVal(name, type_params, type_ann?, expr)
  | DTask(name, type_params, params, return_type, with_clause, body)
  | DRequest(annotation?, name, params, return_type)
  | DExternalTask(annotation?, name, params, return_type, with_clause, from)
  | DExternalRequest(annotation?, name, params, return_type, from)
  | DType(name, type_params, type_expr)

Expr
  = ELit(Literal)
  | EVar(QualifiedName)
  | ECall(expr, type_args, args)
  | EBinOp(op, lhs, rhs)
  | EUnaryOp(op, expr)
  | EIf(cond, then, else?)
  | EMatch(expr, [MatchArm])
  | EFor(var, iter_expr, body_stmts, for_vars)   -- for v in expr { ... }
  | EPar([BlockExpr])                              -- par [{ ... }, { ... }]
  | EBlock([Stmt])
  | EObject([(string, expr)])
  | EArray([expr])
  | EIndex(expr, expr)
  | EFieldAccess(expr, string)
  | ETemplateLit([TemplateSegment])               -- f"text ${expr} text"
  | EReturn(expr?)
  | EReply(expr, state_updates?)                  -- reply val with { k = v }
  | EBreak(expr)                                  -- break expr (handle / for)
  | ENext(state_updates?)                         -- next with { k = v } (for)

Stmt
  = SExpr(expr)
  | SLet(name, type_ann?, expr)
  | SHandle(handle_params, [HandleCase])          -- handle(...) { ... }

HandleCase
  = HCRequest(request_name, params, body)         -- request name(p) => { ... }
  | HCReturn(pattern, body)                       -- return x => { ... }

HandleParam = { name: string, type: TypeExpr, init: Expr }

Pat
  = PVar(name)
  | PLit(Literal)
  | PWild
  | PObject([(string, Pat)])                      -- { key: pat, ... }
  | PArray(SpreadPat)                             -- [p1, ...rest, p2]
  | PTyped(tag, name)                             -- integer(x), string(x) etc.

TypeExpr
  = TName(QualifiedName)
  | TApp(TypeExpr, [TypeExpr])
  | TFun(params, return_type)                     -- (x: A) -> B
  | TUnion(TypeExpr, TypeExpr)                    -- A | B
  | TIntersect(TypeExpr, TypeExpr)                -- A & B
  | TObject([(string, optional, TypeExpr)])       -- { key: T, key?: T }
  | TArray(TypeExpr)                              -- array[T]
  | TLit(Literal)                                 -- "ok", 42, true
```

**演算子優先順位** (高→低):
1. 単項 (`!`, `-`)
2. `*`, `/`, `%`
3. `+`, `-`
4. `++` (文字列/配列結合)
5. `<`, `>`, `<=`, `>=`
6. `==`, `!=`
7. `&&`
8. `||`

---

## 3. Resolver

**役割**: 名前解決・import 展開・モジュール依存順決定

**主要処理**:
- `import` 宣言を解析し、モジュールグラフを構築
- トポロジカルソートで循環依存を検出
- 各スコープで名前を解決: ローカル → モジュール/import/prim (衝突はエラー)
- `external task/request` の `from "server:name"` を `katari_config.yaml` と照合

**スコープ規則**:
```
ローカルスコープ (let, params) > モジュールスコープ / selective import / prim
  ※ モジュールスコープ・selective import・prim の間での衝突 = エラー
修飾名 (module.name) は常に使用可能
```

---

## 4. Typechecker

**役割**: 型推論・部分型チェック・match 消尽性チェック

### 4.1 正規化型 (NormalizedType)

```
NormalizedType
  = Unknown                                   -- top 型
  | DISC { discriminator: string,
           mapping: Map<LiteralValue, NormalFields> }
  | NormalFields { nullKind:    null | absent,
                   booleanKind: BooleanKind | absent,
                   numericKind: NumericKind | absent,
                   stringKind:  StringKind | absent,
                   arrayKind:   NormalizedType | absent,
                   objectKind:  ObjectFields | absent }

BooleanKind = Full | Literals(Set<bool>)
NumericKind = { integerPart: Full | Literals(Set<int>) | absent,
                numberPart:  Full | Literals(Set<float>) | absent }
StringKind  = Full | Literals(Set<string>)
ObjectFields = { fields: Map<string, FieldInfo> }
FieldInfo   = { type: NormalizedType, optional: bool }
```

### 4.2 Union/Intersection 正規化

**Union** (型の和):
- `Unknown | T = Unknown`
- `DISC | DISC` (同一 discriminator): mapping をマージ
- `DISC | DISC` (異なる discriminator): NormalFields に崩壊
- `NormalFields | NormalFields`: kind ごとにマージ
  - nullKind: どちらかが null なら null
  - booleanKind: Full が支配; Literals は union
  - numericKind: integerPart / numberPart それぞれ Full が支配; Literals は union
  - arrayKind: covariant union (array[S] | array[T] = array[S | T])
  - objectKind: 共通フィールドのみ残す (幅 covariant); 型は union

**Intersection** (型の積):
- objectKind: 全フィールドを保持; 型は intersection
- 他: 種別ごとに積を計算 (片方が absent なら absent)

### 4.3 部分型チェック (`S <: T`)

```
never <: T            (S = Never → always true)
T <: unknown          (T = Unknown → always true)
Literals(S) <: Full   (e.g. LitIntegerType(1) <: integer)
integer <: number     (integerPart present → numberPart subsumes)
DISC <: T             全 variant が T の subtype であれば ok
NormalFields <: NF    各 kind ごとに subtype チェック
object S <: object T  T の各フィールドが S にあり、型が subtype
```

### 4.4 型推論

制約ベース推論:
1. 各式に型変数 `?α` を割り当てる
2. 式の構造から制約を生成: `?α <: T`, `T <: ?α`, `?α <: ?β`
3. 制約をソルバで解消 (上下限の伝播)
4. 解消できない制約 = 型エラー

**主要な型規則**:
```
task_call(args)  → return_type (引数型チェック + with 節チェック)
reply val        → val: handler の return_type
break val        → val: handle expression の型
request perform  → request の return_type (親に処理委譲)
par [b1, b2]     → array[T1 | T2] (Ti は各ブロック型)
for v in iter    → 最後の next with の型 / break の型
match expr { cases } → 消尽性チェック (型引き算アルゴリズム) + 全 arm の union
```

### 4.5 Match 消尽性チェック (型引き算)

```
subtract(L: NormalizedType, pattern: Pat) → NormalizedType (残余型)

PTyped("integer", _): subtract integerPart from numericKind
PTyped("string", _):  subtract Full from stringKind
PObject({k: p}):      subtract via field patterns
PLit(v):              subtract literal from Literals(S)
PWild / PVar:         → Never (全て消費)
```

残余型が Never でない場合 = 未網羅の case が存在 → エラー

### 4.6 Request/Effect チェック

- 各タスクの `with` 節に宣言された request のみ perform 可能
- `handle` ブロック内で宣言された request は子タスクに対して公開
- `with` 節の整合性: body と handle case body 内の perform を収集し、handle で処理された分を除いた残りが `with` 節と一致するか検証
- `throw` は全タスクに暗黙的に含まれる

---

## 5. Lowering (AST → IR)

**役割**: 型検査済み AST を IR のフラット命令列に変換

### 5.1 識別子割り当て

```
VarId    u32  task ローカル (let 変数・パラメータ・一時変数)
TaskId   u32  グローバル (task 定義)
RequestId u32 グローバル (request 定義)
ConstId  u32  モジュールローカル (定数プール)
HandlerId u32 task ローカル (handle ブロック)
```

### 5.2 命令列生成

各 task の body をフラット命令列として生成。制御フローは絶対オフセットジャンプで表現:

```
if cond { a } else { b }
  →  IBranch(cond, offset_a, offset_b)
     ... a instructions ...
     IJump(after_b)
     ... b instructions ...
     // after_b:

match expr { case p1 => e1; case p2 => e2 }
  →  type check instructions (ITypeOf / field checks)
     ISwitch / IBranch chains
     ... each arm instructions ...

for v in iter { body }
  →  IRequest(iter_next_request, ...)  -- suspension point
     IBranch(has_next, body_start, after_loop)
     // body_start:
     ... body instructions ...
     INext(var_updates)               -- → iter_next_request
     IJump(body_start) / IForBreak(val)

par [b1, b2]
  →  各ブロックを合成 task として lower (free variables を引数化)
     #par_block_0(captured_vars...) { b1 instructions; IReturn r1 }
     #par_block_1(captured_vars...) { b2 instructions; IReturn r2 }
     IPar(dst, [(par_block_0, [v_captured...]), (par_block_1, [v_captured...])])
     -- 結果は array として dst に
     -- IR にクロージャはないため free variable は明示的に引数として渡す

handle(p: T = init) { request R(x) => body; return r => ret_body }
  →  [init instructions]
     IHandleBegin(handler_id)          -- handle 文到達
     ... (handle スコープの後続コード) ...
     IHandleEnd(handler_id)            -- スコープ離脱
```

### 5.3 Handle Block コンパイル

各 HandleBlock は以下を持つ:
- `StateParams`: `(VarId, Type, InitExpr)` のリスト
- `RequestHandlers`: `(RequestId, [Instruction])` のリスト
  引数は `(request_args..., state_params...)`
- `ReturnHandler?`: `[Instruction]`
  引数は `(body_result, state_params...)`

Handler 関数内:
- `IReply(val, handler_id, [(var_id, new_val)])` — 状態更新して reply
- `IBreak(val, handler_id)` — handle スコープを中断

### 5.4 NameTable 生成

```
NameTable {
  vars:     Map<VarId, string>
  tasks:    Map<TaskId, QualifiedName>
  requests: Map<RequestId, QualifiedName>
}
```

デバッグ・永続化・JSON Schema 生成に使用。

---

## 6. Emit

**役割**: IR Program → バイナリ出力

**バイナリフォーマット**:
```
Header:
  magic:   4 bytes = "KTRI"
  version: 2 bytes = (major, minor)

エンコーディング:
  整数:   LEB128 可変長
  文字列: LEB128 長さ + UTF-8 バイト列
  配列:   LEB128 長さ + 要素列
```

---

## 7. JSON Schema 生成

**役割**: request/task の型情報から JSON Schema を生成 (Katari Protocol の GET /request, GET /task レスポンス用)

```
NormalizedType → JSON Schema (object)

Unknown         → {}
Never           → {"not": {}}
null            → {"type": "null"}
boolean Full    → {"type": "boolean"}
boolean Literal → {"const": true/false}
integer Full    → {"type": "integer"}
number Full     → {"type": "number"}
string Full     → {"type": "string"}
DISC            → {"oneOf": [...], "discriminator": {"propertyName": "..."}}
NormalFields    → {"oneOf": [...]}  (各 kind の schema)
array[T]        → {"type": "array", "items": schema(T)}
object          → {"type": "object", "properties": {...}, "required": [...]}
optional field  → フィールドを required から除外
Literal string  → {"const": "value"}
annotation      → "description" フィールドを追加
```
