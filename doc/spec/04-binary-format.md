# KTRI v0.2 バイナリフォーマット仕様

本仕様書は KTRI (Katari IR) バイナリフォーマット version 0.2 を定義する。
正準エンコーダは `Katari.Emit.emitModule` (Haskell) であり、本文書はそのバイト列出力と 1:1 で対応する。

---

## 1. ヘッダ

ファイル先頭の固定 6 バイト。

| Offset | Byte(s)              | 意味                     |
|--------|----------------------|--------------------------|
| 0      | `4b 54 52 49`        | マジックナンバー "KTRI"  |
| 4      | `00 02`              | バージョン 0.2           |

ランタイムはこの 6 バイトを検証し、一致しなければファイルを拒否すること。

---

## 2. エンコーディングプリミティブ

以降の全セクションで使用する基本エンコーディング。

### 2.1 LEB128 Unsigned

符号なし可変長整数エンコーディング。値域は `Word32` (0 -- 2^32-1)。

```
while value > 0:
    byte = value & 0x7f
    value >>= 7
    if value != 0:
        byte |= 0x80
    emit(byte)
```

値が `0` の場合は `0x00` の 1 バイトを出力する。最大 5 バイト。

本文書で `LEB128` と記す場合は全て符号なし LEB128 を指す。

### 2.2 Signed LEB128

符号付き可変長整数エンコーディング。任意精度整数 (`Integer`) に使用する。

```
loop:
    byte = value & 0x7f
    value >>= 7  (算術シフト)
    done = (value == 0  AND bit6 of byte == 0)
        OR (value == -1 AND bit6 of byte == 1)
    if not done:
        byte |= 0x80
    emit(byte)
    if done: break
```

bit6 (`0x40`) は符号ビットの役割を果たす。負の値は 2 の補数表現で拡張される。

### 2.3 Text

UTF-8 文字列。

```
Text = LEB128(byte_length) + UTF-8_bytes
```

`byte_length` は UTF-8 エンコード後のバイト数 (文字数ではない)。

### 2.4 Vec\<T\>

可変長配列。

```
Vec<T> = LEB128(count) + T[0] + T[1] + ... + T[count-1]
```

`count` は要素数。`count == 0` の場合は `0x00` の 1 バイトのみ。

### 2.5 Maybe\<T\>

省略可能な値。

| Tag (u8) | 意味    | 後続データ |
|----------|---------|-----------|
| `0x00`   | Nothing | なし      |
| `0x01`   | Just    | T の値    |

### 2.6 f64

IEEE 754 倍精度浮動小数点数。リトルエンディアン。固定 8 バイト。

---

## 3. トップレベルレイアウト

`emitModule` が出力するバイト列の全体構成。順序は厳密に以下の通り。

```
+----------------------------+
| Header        (6 bytes)    |
+----------------------------+
| module_name   (Text)       |
+----------------------------+
| constants     (Vec<Const>) |
+----------------------------+
| requests      (Vec<ReqDef>)|
+----------------------------+
| threads       (Vec<Thread>)|
+----------------------------+
| handle_defs   (Vec<HDef>)  |
+----------------------------+
| for_defs      (Vec<FDef>)  |
+----------------------------+
| agent_defs    (Vec<ADef>)  |
+----------------------------+
```

各セクションは隙間なく連続する。セクション間にパディングやアライメントは存在しない。

---

## 4. 定数プールエントリ (Constant Pool Entry)

各エントリは 1 バイトのタグで始まり、タグに応じたペイロードが続く。

| Tag  | 型      | ペイロード                              | 備考                           |
|------|---------|-----------------------------------------|-------------------------------|
| `0x00` | Null    | なし (0 バイト)                         |                               |
| `0x01` | Bool    | `u8` (1 バイト): `0x00`=false, `0x01`=true |                               |
| `0x02` | Integer | Signed LEB128                           | 任意精度整数                   |
| `0x03` | Number  | f64 リトルエンディアン (8 バイト)       | IEEE 754 倍精度               |
| `0x04` | String  | Text エンコーディング                   | LEB128(byte_length) + UTF-8  |

### 例

- `null` : `00`
- `true` : `01 01`
- `false` : `01 00`
- 整数 `42` : `02 2a`
- 整数 `-1` : `02 7f`
- 整数 `0` : `02 00`
- 浮動小数点 `3.14` : `03 1f 85 eb 51 b8 1e 09 40`
- 文字列 `"hi"` : `04 02 68 69`

---

## 5. Request Definition

各リクエスト定義のエンコーディング。

```
RequestDef =
    request_id  : LEB128       -- RequestId
    name        : Text         -- リクエスト名
    from        : Maybe<Text>  -- external の場合 "server:name" 等
```

`from` フィールドは `Maybe<Text>` エンコーディング (Section 2.5) に従う。

---

## 6. Thread

各 Thread のエンコーディング。

```
Thread =
    thread_id   : LEB128           -- ThreadId
    kind        : u8               -- ThreadKind (下表参照)
    params      : Vec<LEB128>      -- パラメータの VarId 列
    body        : Vec<Instruction>  -- 命令列
```

### 6.1 ThreadKind

| 値   | 名前              | 説明                                   |
|------|-------------------|----------------------------------------|
| `0`  | FN_BODY           | Agent エントリポイント                  |
| `1`  | BLOCK             | par branch / block 式                  |
| `2`  | HANDLER_TARGET    | handle body (対象コード)                |
| `3`  | REQUEST_HANDLER   | request case handler                    |
| `4`  | HANDLE_THEN       | handle then 節                          |
| `5`  | FOR_BODY          | for loop body                           |
| `6`  | FOR_THEN          | for then 節                             |

---

## 7. Handle Definition

各 Handle 定義のエンコーディング。

```
HandleDef =
    handler_id   : LEB128                          -- HandlerId
    state_vars   : Vec<LEB128>                     -- state variable の VarId 列
    state_inits  : Vec<LEB128>                     -- 初期値を保持する VarId 列
    body         : LEB128                          -- HANDLER_TARGET の ThreadId
    req_cases    : Vec<(LEB128, LEB128)>           -- (RequestId, REQUEST_HANDLER の ThreadId) の列
    then         : Maybe<LEB128>                   -- HANDLE_THEN の ThreadId (省略可)
```

`req_cases` の各要素は RequestId と ThreadId の 2 つの LEB128 値を連続して並べる。

`then` フィールドは `Maybe<LEB128>` エンコーディング (Section 2.5) に従う。

---

## 8. For Definition

各 For 定義のエンコーディング。

```
ForDef =
    for_id       : LEB128                          -- ForId
    iter_vars    : Vec<LEB128>                     -- イテレーション変数の VarId 列
    arrays       : Vec<LEB128>                     -- 配列の VarId 列
    state_vars   : Vec<LEB128>                     -- state variable の VarId 列
    state_inits  : Vec<LEB128>                     -- 初期値を保持する VarId 列
    body         : LEB128                          -- FOR_BODY の ThreadId
    then         : Maybe<LEB128>                   -- FOR_THEN の ThreadId (省略可)
```

`then` フィールドは `Maybe<LEB128>` エンコーディング (Section 2.5) に従う。

---

## 9. Agent Definition

各 Agent 定義のエンコーディング。

```
AgentDef =
    agent_id    : LEB128       -- AgentId
    name        : Text         -- Agent 名
    entry       : LEB128       -- FN_BODY の ThreadId
```

---

## 10. 命令セット (Opcode Table)

全命令の一覧。各命令は 1 バイトの opcode で始まり、命令固有の引数が続く。
引数の型注釈がない LEB128 値は全て `Word32` (符号なし 32 ビット) である。

### 10.1 定数・移動

| Opcode | 命令       | 引数                            | 説明                      |
|--------|------------|---------------------------------|---------------------------|
| `0x01` | ILoadConst | dst:`LEB128`, constId:`LEB128`  | 定数プール[constId] を dst にロード |
| `0x02` | ILoadNull  | dst:`LEB128`                    | null を dst にロード       |
| `0x03` | IMove      | dst:`LEB128`, src:`LEB128`      | src の値を dst にコピー    |

### 10.2 オブジェクト操作

| Opcode | 命令       | 引数                                                  | 説明                                          |
|--------|------------|-------------------------------------------------------|-----------------------------------------------|
| `0x10` | INewObject | dst:`LEB128`, fields:`Vec<(constId:LEB128, val:LEB128)>` | フィールド列からオブジェクトを生成し dst に格納 |
| `0x11` | IGetField  | dst:`LEB128`, obj:`LEB128`, constId:`LEB128`          | obj のフィールド[constId] を dst に取得        |
| `0x12` | ISetField  | obj:`LEB128`, newObj:`LEB128`, constId:`LEB128`, val:`LEB128` | obj のフィールド[constId] を val に更新した新オブジェクトを newObj に格納 |
| `0x13` | IHasField  | dst:`LEB128`, obj:`LEB128`, constId:`LEB128`          | obj にフィールド[constId] が存在するか判定し dst に bool を格納 |

**INewObject** の `fields` は `Vec` エンコーディングに従う: `LEB128(count)` + 各要素 `(constId:LEB128, val:LEB128)`。

**ISetField** の引数順序に注意: `obj`, `newObj`, `constId`, `val` の順。

### 10.3 配列操作

| Opcode | 命令       | 引数                                                    | 説明                                    |
|--------|------------|--------------------------------------------------------|----------------------------------------|
| `0x20` | INewArray  | dst:`LEB128`, elems:`Vec<LEB128>`                      | 要素列から配列を生成し dst に格納       |
| `0x21` | IArrGet    | dst:`LEB128`, arr:`LEB128`, idx:`LEB128`               | arr[idx] を dst に取得                  |
| `0x22` | IArrLen    | dst:`LEB128`, arr:`LEB128`                             | arr の長さを dst に格納                 |
| `0x23` | IArrPush   | dst:`LEB128`, arr:`LEB128`, elem:`LEB128`              | arr に elem を追加した新配列を dst に格納 |
| `0x25` | IArrSlice  | dst:`LEB128`, arr:`LEB128`, from:`LEB128`, to:`LEB128` | arr[from..to] のスライスを dst に格納   |

**INewArray** の `elems` は `Vec` エンコーディングに従う: `LEB128(count)` + 各要素 `LEB128`。

> **Note**: opcode `0x24` は未使用 (欠番)。

### 10.4 算術演算

| Opcode | 命令  | 引数                                        | 説明         |
|--------|-------|---------------------------------------------|-------------|
| `0x30` | IAdd  | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs + rhs |
| `0x31` | ISub  | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs - rhs |
| `0x32` | IMul  | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs * rhs |
| `0x33` | IDiv  | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs / rhs |
| `0x34` | IMod  | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs % rhs |
| `0x35` | INeg  | dst:`LEB128`, src:`LEB128`                  | dst = -src      |

算術演算はランタイムが動的に integer/number を判定して実行する。

### 10.5 比較演算

| Opcode | 命令    | 引数                                        | 説明           |
|--------|---------|---------------------------------------------|---------------|
| `0x50` | ICmpEq  | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs == rhs |
| `0x51` | ICmpNe  | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs != rhs |
| `0x52` | ICmpLt  | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs < rhs  |
| `0x53` | ICmpLe  | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs <= rhs |
| `0x54` | ICmpGt  | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs > rhs  |
| `0x55` | ICmpGe  | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs >= rhs |

### 10.6 論理演算

| Opcode | 命令  | 引数                                        | 説明           |
|--------|-------|---------------------------------------------|---------------|
| `0x60` | IAnd  | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs AND rhs |
| `0x61` | IOr   | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs OR rhs  |
| `0x62` | INot  | dst:`LEB128`, src:`LEB128`                  | dst = NOT src      |

### 10.7 文字列・型変換

| Opcode | 命令      | 引数                                        | 説明                                    |
|--------|-----------|---------------------------------------------|-----------------------------------------|
| `0x70` | IConcat   | dst:`LEB128`, lhs:`LEB128`, rhs:`LEB128`   | dst = lhs ++ rhs (文字列または配列結合) |
| `0x71` | IToString | dst:`LEB128`, src:`LEB128`                  | dst = toString(src)                     |
| `0x73` | ITypeOf   | dst:`LEB128`, src:`LEB128`                  | dst = typeof(src) (型名文字列)          |

> **Note**: opcode `0x72` は未使用 (欠番)。

### 10.8 制御フロー

| Opcode | 命令      | 引数                                                              | 説明                                             |
|--------|-----------|-------------------------------------------------------------------|--------------------------------------------------|
| `0x80` | IJump     | target:`LEB128`                                                   | 命令インデックス target へ無条件ジャンプ          |
| `0x81` | IBranch   | cond:`LEB128`, trueTarget:`LEB128`, falseTarget:`LEB128`         | cond が true なら trueTarget、false なら falseTarget へジャンプ |
| `0x82` | ISwitch   | val:`LEB128`, cases:`Vec<(constId:LEB128, target:LEB128)>`, default:`LEB128` | val を定数プールの値と照合し、一致する case の target へジャンプ。一致なしなら default へジャンプ |
| `0x83` | IReturn   | val:`LEB128`                                                      | FnReturn signal を発生させ、val を返り値として FN_BODY まで巻き上げる |
| `0x84` | IComplete | val:`LEB128`                                                      | Thread の正常完了 (Normal signal)。val を結果として返す |

**ISwitch** の `cases` は `Vec` エンコーディングに従う: `LEB128(count)` + 各要素 `(constId:LEB128, target:LEB128)`。`default` はその直後に続く。

### 10.9 Agent 操作

| Opcode | 命令     | 引数                                                   | 説明                                          |
|--------|----------|--------------------------------------------------------|-----------------------------------------------|
| `0x90` | ICall    | dst:`LEB128`, agentId:`LEB128`, args:`Vec<LEB128>`    | Agent を呼び出し、結果を dst に格納           |
| `0x91` | IPar     | dst:`LEB128`, threadIds:`Vec<LEB128>`                  | 複数 Thread を並列実行し、結果配列を dst に格納 |
| `0x92` | IRequest | dst:`LEB128`, requestId:`LEB128`, args:`Vec<LEB128>`  | リクエストを発行し、結果を dst に格納          |

### 10.10 Handle 操作

| Opcode | 命令         | 引数                                                        | 説明                                               |
|--------|--------------|-------------------------------------------------------------|----------------------------------------------------|
| `0xa0` | IHandle      | dst:`LEB128`, handlerId:`LEB128`                            | Handle 定義を実行開始。結果を dst に格納            |
| `0xa2` | IContinue    | val:`LEB128`, updates:`Vec<(stateVar:LEB128, newVal:LEB128)>` | request handler から継続。state 変数を更新し val で reply |
| `0xa3` | IHandleBreak | val:`LEB128`                                                | HandleBreak signal を発生。handle スコープを val で脱出 |

**IContinue** の `updates` は `Vec` エンコーディングに従う: `LEB128(count)` + 各要素 `(stateVar:LEB128, newVal:LEB128)`。

> **Note**: opcode `0xa1` は未使用 (欠番)。

### 10.11 For 操作

| Opcode | 命令         | 引数                                                        | 説明                                               |
|--------|--------------|-------------------------------------------------------------|----------------------------------------------------|
| `0xb0` | IForContinue | updates:`Vec<(stateVar:LEB128, newVal:LEB128)>`            | for loop の次イテレーションへ継続。state 変数を更新  |
| `0xb1` | IForBreak    | val:`LEB128`                                                | ForBreak signal を発生。for ループを val で脱出      |
| `0xb2` | IFor         | dst:`LEB128`, forId:`LEB128`                                | For 定義を実行開始。結果を dst に格納               |

**IForContinue** の `updates` は `Vec` エンコーディングに従う: `LEB128(count)` + 各要素 `(stateVar:LEB128, newVal:LEB128)`。

---

## 11. Opcode 一覧 (クイックリファレンス)

全 opcode の数値順一覧。

| Opcode | ニーモニック  | 引数バイト数 (最小) |
|--------|--------------|---------------------|
| `0x01` | ILoadConst   | 2+                  |
| `0x02` | ILoadNull    | 1+                  |
| `0x03` | IMove        | 2+                  |
| `0x10` | INewObject   | 2+                  |
| `0x11` | IGetField    | 3+                  |
| `0x12` | ISetField    | 4+                  |
| `0x13` | IHasField    | 3+                  |
| `0x20` | INewArray    | 2+                  |
| `0x21` | IArrGet      | 3+                  |
| `0x22` | IArrLen      | 2+                  |
| `0x23` | IArrPush     | 3+                  |
| `0x25` | IArrSlice    | 4+                  |
| `0x30` | IAdd         | 3+                  |
| `0x31` | ISub         | 3+                  |
| `0x32` | IMul         | 3+                  |
| `0x33` | IDiv         | 3+                  |
| `0x34` | IMod         | 3+                  |
| `0x35` | INeg         | 2+                  |
| `0x50` | ICmpEq       | 3+                  |
| `0x51` | ICmpNe       | 3+                  |
| `0x52` | ICmpLt       | 3+                  |
| `0x53` | ICmpLe       | 3+                  |
| `0x54` | ICmpGt       | 3+                  |
| `0x55` | ICmpGe       | 3+                  |
| `0x60` | IAnd         | 3+                  |
| `0x61` | IOr          | 3+                  |
| `0x62` | INot         | 2+                  |
| `0x70` | IConcat      | 3+                  |
| `0x71` | IToString    | 2+                  |
| `0x73` | ITypeOf      | 2+                  |
| `0x80` | IJump        | 1+                  |
| `0x81` | IBranch      | 3+                  |
| `0x82` | ISwitch      | 3+                  |
| `0x83` | IReturn      | 1+                  |
| `0x84` | IComplete    | 1+                  |
| `0x90` | ICall        | 3+                  |
| `0x91` | IPar         | 2+                  |
| `0x92` | IRequest     | 3+                  |
| `0xa0` | IHandle      | 2+                  |
| `0xa2` | IContinue    | 2+                  |
| `0xa3` | IHandleBreak | 1+                  |
| `0xb0` | IForContinue | 1+                  |
| `0xb1` | IForBreak    | 1+                  |
| `0xb2` | IFor         | 2+                  |

合計: 40 命令。

---

## 12. 注意事項

- **NameTable はバイナリに含まれない。** `IRModule` の `irmNameTable` フィールドは `emitModule` によって出力されない。ランタイムは変数名・Agent 名・リクエスト名のテーブルなしで動作する (Agent 名は `AgentDef.name`、リクエスト名は `RequestDef.name` から取得可能)。
- **全ての ID は LEB128 (符号なし `Word32`) でエンコードされる。** VarId, AgentId, RequestId, ConstId, HandlerId, ForId, ThreadId は全て同一のエンコーディング。
- **Signed LEB128 が使用されるのは CVInt (整数定数) のみ。** それ以外の全ての LEB128 値は符号なし。
- **バイト列にパディング・アライメントは一切存在しない。** 全てのフィールドは直前のフィールドの直後から始まる。
- **欠番 opcode**: `0x24`, `0x72`, `0xa1` は現在未使用。ランタイムはこれらの opcode を検出した場合エラーとすること。
- **IJump / IBranch / ISwitch の target 値** は、同一 Thread 内の命令インデックス (0-based) を指す。
