# Thread ベース IR 仕様書 (v0.2)

## 1. 概要

Katari IR v0.2 は **Thread** を基本実行単位とする中間表現。
handle / for / par / block 式をすべて Thread 分解で統一的に扱う。

旧 IR (v0.1) の問題点:
- handle body が暗黙的 (begin/end マーカー間) で Lowering に先読みが必要
- par が擬似 agent + captured vars リストでアドホック
- block/handle/for/par で異なるメカニズム

## 2. Thread モデル

Thread は独立した命令列。`ThreadKind` で境界の意味を持つ。

| Kind | 用途 | params |
|------|------|--------|
| `FN_BODY` | agent エントリポイント | agent の仮引数 |
| `BLOCK` | par branch / block 式 | なし |
| `HANDLER_TARGET` | handle body (残り文) | なし |
| `REQUEST_HANDLER` | request case handler | request 引数 |
| `HANDLE_THEN` | handle then 節 | 入力値 1 つ |
| `FOR_BODY` | for loop body | element 変数 |
| `FOR_THEN` | for then 節 | なし |

### データ構造

```
IRThread:
  id: ThreadId
  kind: ThreadKind
  params: [VarId]
  body: [Instruction]
```

## 3. 変数コンテキスト (scope chain)

- `VarId` はモジュール全体でユニーク
- 子 thread は親の ctx を scope chain で参照 (読み取り)
- mutation は thread の signal を通じて `[(VarId, VarId)]` を親に返す
- agent 呼び出し = ctx 境界 (callee は fresh ctx で開始)

## 4. Signal (制御フロー伝搬)

| Signal | 発行命令 | 伝搬先 |
|--------|----------|--------|
| Normal(value) | `IComplete` | 直接の親 |
| FnReturn(value) | `IReturn` | FN_BODY まで巻き上げ |
| HandleBreak(value) | `IHandleBreak` | handle scope を脱出 |
| Continue(value, mutations) | `IContinue` | request handler → handle |
| ForBreak(value) | `IForBreak` | for loop を脱出 |
| ForContinue(mutations) | `IForContinue` | for body → for loop |

## 5. Handle 分解

### ソース

```katari
let a = 0
handle (var s: T = init) {
  request foo(y) => { B }
} then (r) { C }
let b = 1
```

### IR

```
thread_0: FN_BODY
  a = 0
  s_init = [eval init]
  dst = IHandle hnd0
  IComplete dst

thread_1: HANDLER_TARGET     // 残り文
  b = 1
  IComplete b

thread_2(y): REQUEST_HANDLER
  [B]
  IComplete result

thread_3(r): HANDLE_THEN
  [C]
  IComplete result

handle_def[0]:
  states=[s], inits=[s_init]
  body=thread_1
  req=[(foo, thread_2)]
  then=thread_3
```

### セマンティクス

1. ランタイムが `IHandle` を実行:
   - state 変数を inits で初期化
   - HANDLER_TARGET thread を実行
   - request 発生時は対応する REQUEST_HANDLER thread を実行
   - `IContinue` で state を更新し HANDLER_TARGET を再開
   - `IHandleBreak` で handle を脱出
   - target が Normal 完了 → then 節を実行 (あれば)
2. 結果が `dst` に格納される

## 6. For 分解

### ソース

```katari
for (let x of arr, var acc = 0) {
  continue with { acc = acc + x }
} then { acc }
```

### IR

```
thread_0: FN_BODY
  v_arr = [eval arr]
  v_acc_init = 0
  dst = IFor for0
  IComplete dst

thread_1(x): FOR_BODY
  v_new = acc + x
  IForContinue [(acc, v_new)]

thread_2: FOR_THEN
  IComplete acc

for_def[0]:
  iters=[x], arrays=[v_arr]
  states=[acc], inits=[v_acc_init]
  body=thread_1, then=thread_2
```

### セマンティクス

ループ制御 (index 管理, 長さ比較, element 取得) は **ランタイムが担当**。
IR にはループ制御命令は出現しない。

1. ランタイムが `IFor` を実行:
   - state 変数を inits で初期化
   - arrays の各要素について FOR_BODY thread を実行
   - `IForContinue` で state を更新し次のイテレーションへ
   - `IForBreak` でループ脱出
   - 全要素処理後 → then 節を実行 (あれば)
2. 結果が `dst` に格納される

## 7. Par 分解

### ソース

```katari
par [{ A }, { B }]
```

### IR

```
dst = IPar [thread_1, thread_2]

thread_1: BLOCK
  [A]
  IComplete result

thread_2: BLOCK
  [B]
  IComplete result
```

captured vars リスト不要 (scope chain で参照)。

## 8. Match (パターンマッチ)

Thread 分解なし。現在の thread 内でインライン:

```
v = [eval expr]
// case 1: literal
v1 = v == "reply"
branch v1 ? @body1 : @next1
@body1: [A]; jump @end
@next1:
// case 2: object pattern
v2 = v."kind"; v3 = v2 == "circle"
branch v3 ? @bind2 : @next2
@bind2: v_r = v."radius"; [B]; jump @end
@next2:
// default
v_other = v; [C]; jump @end
@end:
```

## 9. データ構造一覧

```
IRModule:
  name: Text
  nameTable: NameTable (debug 用)
  consts: [ConstVal]
  requests: [IRRequestDef]
  threads: [IRThread]
  handles: [IRHandleDef]
  fors: [IRForDef]
  agents: [IRAgentDef]

IRThread:
  id: ThreadId
  kind: ThreadKind
  params: [VarId]
  body: [Instruction]

IRHandleDef:
  id: HandlerId
  stateVars: [VarId]
  stateInits: [VarId]
  body: ThreadId
  reqCases: [(RequestId, ThreadId)]
  then: Maybe ThreadId

IRForDef:
  id: ForId
  iterVars: [VarId]
  arrays: [VarId]
  stateVars: [VarId]
  stateInits: [VarId]
  body: ThreadId
  then: Maybe ThreadId

IRAgentDef:
  id: AgentId
  name: Text
  entry: ThreadId

IRRequestDef:
  id: RequestId
  name: Text
  from: Maybe Text
```

## 10. 命令セット (40 命令)

### 定数・移動
| 命令 | 引数 | 説明 |
|------|------|------|
| `ILoadConst` | dst, constId | 定数プールから読み込み |
| `ILoadNull` | dst | null を読み込み |
| `IMove` | dst, src | 値のコピー |

### Object
| 命令 | 引数 | 説明 |
|------|------|------|
| `INewObject` | dst, [(constId, varId)] | オブジェクト生成 |
| `IGetField` | dst, obj, constId | フィールド取得 |
| `ISetField` | obj, _, constId, val | フィールド設定 |
| `IHasField` | dst, obj, constId | フィールド存在判定 |

### Array
| 命令 | 引数 | 説明 |
|------|------|------|
| `INewArray` | dst, [varId] | 配列生成 |
| `IArrGet` | dst, arr, idx | 要素取得 |
| `IArrLen` | dst, arr | 長さ取得 |
| `IArrPush` | dst, arr, elem | 要素追加 |
| `IArrSlice` | dst, arr, start, end | スライス |

### 算術 (ランタイムが integer/number を動的判定)
| 命令 | 引数 | 説明 |
|------|------|------|
| `IAdd` | dst, l, r | 加算 |
| `ISub` | dst, l, r | 減算 |
| `IMul` | dst, l, r | 乗算 |
| `IDiv` | dst, l, r | 除算 |
| `IMod` | dst, l, r | 剰余 |
| `INeg` | dst, src | 符号反転 |

### 比較
| 命令 | 引数 | 説明 |
|------|------|------|
| `ICmpEq` | dst, l, r | == |
| `ICmpNe` | dst, l, r | != |
| `ICmpLt` | dst, l, r | < |
| `ICmpLe` | dst, l, r | <= |
| `ICmpGt` | dst, l, r | > |
| `ICmpGe` | dst, l, r | >= |

### 論理
| 命令 | 引数 | 説明 |
|------|------|------|
| `IAnd` | dst, l, r | && |
| `IOr` | dst, l, r | \|\| |
| `INot` | dst, src | ! |

### 文字列・型変換
| 命令 | 引数 | 説明 |
|------|------|------|
| `IConcat` | dst, l, r | 文字列/配列結合 |
| `IToString` | dst, src | 文字列変換 |
| `ITypeOf` | dst, src | 型名取得 |

### 制御フロー
| 命令 | 引数 | 説明 |
|------|------|------|
| `IJump` | target | 無条件ジャンプ |
| `IBranch` | cond, trueTarget, falseTarget | 条件分岐 |
| `ISwitch` | val, [(constId, target)], default | 多分岐 |
| `IComplete` | val | thread 正常完了 (Normal signal) |
| `IReturn` | val | ソースの `return` 文 (FN_BODY まで巻き上げ) |

### Agent 操作
| 命令 | 引数 | 説明 |
|------|------|------|
| `ICall` | dst, agentId, [args] | agent 呼び出し |
| `IPar` | dst, [threadId] | 並列実行 |
| `IRequest` | dst, requestId, [args] | request 発行 |

### Handle
| 命令 | 引数 | 説明 |
|------|------|------|
| `IHandle` | dst, handlerId | handle 実行 |
| `IContinue` | val, [(stateVar, newVal)] | request handler から continue |
| `IHandleBreak` | val | handle scope 脱出 |

### For
| 命令 | 引数 | 説明 |
|------|------|------|
| `IFor` | dst, forId | for loop 実行 |
| `IForContinue` | [(stateVar, newVal)] | 次のイテレーションへ |
| `IForBreak` | val | for loop 脱出 |

## 11. バイナリフォーマット (KTRI v0.2)

### ヘッダ

```
4b 54 52 49 00 02   "KTRI" + version 0x0002
```

### セクション構成

```
Header
→ module_name: Text
→ Constants: Vec<ConstVal>
→ Requests: Vec<RequestDef>
→ Threads: Vec<Thread>
→ HandleDefs: Vec<HandleDef>
→ ForDefs: Vec<ForDef>
→ AgentDefs: Vec<AgentDef>
```

### エンコーディング

- 整数: LEB128 unsigned
- 符号付き整数: signed LEB128
- 文字列: LEB128(byte_length) + UTF-8
- ベクタ: LEB128(count) + items
- Maybe: 0 = Nothing, 1 + value = Just

### Thread エンコーディング

```
ThreadId: LEB128
ThreadKind: u8 (0=FN_BODY, 1=BLOCK, 2=HANDLER_TARGET,
                3=REQUEST_HANDLER, 4=HANDLE_THEN,
                5=FOR_BODY, 6=FOR_THEN)
Params: Vec<VarId>
Body: Vec<Instruction>
```

### HandleDef エンコーディング

```
HandlerId: LEB128
StateVars: Vec<VarId>
StateInits: Vec<VarId>
Body: ThreadId
ReqCases: Vec<(RequestId, ThreadId)>
Then: Maybe<ThreadId>
```

### ForDef エンコーディング

```
ForId: LEB128
IterVars: Vec<VarId>
Arrays: Vec<VarId>
StateVars: Vec<VarId>
StateInits: Vec<VarId>
Body: ThreadId
Then: Maybe<ThreadId>
```

### AgentDef エンコーディング

```
AgentId: LEB128
Name: Text
Entry: ThreadId
```

### Opcode 一覧

| Opcode | 命令 | 引数 |
|--------|------|------|
| 0x01 | ILoadConst | var, constId |
| 0x02 | ILoadNull | var |
| 0x03 | IMove | dst, src |
| 0x10 | INewObject | dst, Vec<(constId, var)> |
| 0x11 | IGetField | dst, obj, constId |
| 0x12 | ISetField | obj, var, constId, val |
| 0x13 | IHasField | dst, obj, constId |
| 0x20 | INewArray | dst, Vec<var> |
| 0x21 | IArrGet | dst, arr, idx |
| 0x22 | IArrLen | dst, arr |
| 0x23 | IArrPush | dst, arr, elem |
| 0x25 | IArrSlice | dst, arr, start, end |
| 0x30 | IAdd | dst, l, r |
| 0x31 | ISub | dst, l, r |
| 0x32 | IMul | dst, l, r |
| 0x33 | IDiv | dst, l, r |
| 0x34 | IMod | dst, l, r |
| 0x35 | INeg | dst, src |
| 0x50 | ICmpEq | dst, l, r |
| 0x51 | ICmpNe | dst, l, r |
| 0x52 | ICmpLt | dst, l, r |
| 0x53 | ICmpLe | dst, l, r |
| 0x54 | ICmpGt | dst, l, r |
| 0x55 | ICmpGe | dst, l, r |
| 0x60 | IAnd | dst, l, r |
| 0x61 | IOr | dst, l, r |
| 0x62 | INot | dst, src |
| 0x70 | IConcat | dst, l, r |
| 0x71 | IToString | dst, src |
| 0x73 | ITypeOf | dst, src |
| 0x80 | IJump | target |
| 0x81 | IBranch | cond, trueTarget, falseTarget |
| 0x82 | ISwitch | val, Vec<(constId, target)>, default |
| 0x83 | IReturn | val |
| 0x84 | IComplete | val |
| 0x90 | ICall | dst, agentId, Vec<args> |
| 0x91 | IPar | dst, Vec<threadId> |
| 0x92 | IRequest | dst, requestId, Vec<args> |
| 0xa0 | IHandle | dst, handlerId |
| 0xa2 | IContinue | val, Vec<(stateVar, newVal)> |
| 0xa3 | IHandleBreak | val |
| 0xb0 | IForContinue | Vec<(stateVar, newVal)> |
| 0xb1 | IForBreak | val |
| 0xb2 | IFor | dst, forId |

### v0.1 からの変更

**削除:**
- IHandleBegin (0xa0) / IHandleEnd (0xa1) → IHandle に統合
- IForBegin (0xb2) / IForEnd (0xb3) → IFor に統合
- Agent セクション → Threads + AgentDefs に分離

**追加:**
- IComplete (0x84) — thread 正常完了
- IHandle (0xa0) — handle 実行 (opcode 再利用)
- IFor (0xb2) — for 実行 (opcode 再利用)
- Thread セクション, HandleDef セクション, ForDef セクション, AgentDef セクション

**変更:**
- IPar: `(agentId, [capturedVars])[]` → `[ThreadId]`
- IContinue: `val, handlerId, [(slotIdx, val)]` → `val, [(stateVar, newVal)]`
- IHandleBreak: `val, handlerId` → `val`
- IForContinue: `forId, [(slotIdx, val)]` → `[(stateVar, newVal)]`
- IForBreak: `val, forId` → `val`
- IReturn: 意味変更 — ソースの `return` 文 (FN_BODY まで巻き上げ)
