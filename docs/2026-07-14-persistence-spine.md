# 永続化の背骨 — external call は「封筒 + 状態 + Ext 文書」ただ一つ(v0.1.0 rebuild Wave 1)

ゴール: **external reactor の永続化を kind ごとの複製から一つのパラメトリックな形に畳む**。
ffi / http / webhook / mcp / time の 5 kind が現状それぞれ、Row 型・Instance 型・Tx interface・
Loader interface・NO_OP / EMPTY 実装・DbPersistence の serialize/join 腕・StoringPersistence の
手鏡写し・専用テーブル、という 8 点セットを複製している(persistence.ts 615 行、db-persistence.ts
841 行、storing-persistence.ts 562 行、execution.ts のテーブル群)。「対象は違うけど同じように動く」
に畳む。

## 1. 中心の形

external call の永続化単位は全 kind で同型である:

```
external call = PersistedCallEnvelope(封筒: delegation / instance / caller / run — 既存)
              + status ("running" | "cancelling" | "awaitingAnswer")
              + extension(kind 固有の再構成材料 — ひとつの JSON 文書)
```

- **port は Ext の中身を知らない**。書き込みは
  `ExternalTx.putCall({ instanceId, status, extension: Json })`、読み出しは
  `ExternalLoader.instances(reactor)` → `PersistedExternalCall[]`(封筒 ⋈ status ⋈ extension、
  extension は raw Json)。kind の型は **reactor 側の codec** が与える: 各 concrete reactor が
  `encodeExtension / decodeExtension`(純関数)を持ち、warm 状態 ↔ Ext 文書を往復する。
- 5 つの Tx interface、5 つの Loader interface、10 個の Persisted\*(Row/Instance 対)、NO_OP / EMPTY
  の kind 別エントリは全て消える。`PersistenceTx.{ffi,http,webhook,mcp,time}` → `tx.external` 一つ。
  core / api / pool / outbox / journal は形が本当に異なるので不変。
- inner-delegation の bridge(relays / innerCalls)は「それを開ける kind の Ext 文書の中」に入る
  (ffi / webhook / mcp-serve / mcp-provide)。http のように持たない kind の Ext から欄そのものが
  消える — nullable でぶら下げない。

## 2. mcp の 3 つの nullable は直和になる

`PersistedMcpInstanceRow` の `serve / provide / parked`(高々 1 つ非 null)は if-discipline 違反の
典型で、Ext 文書では本来の姿に戻る:

```ts
type McpExtension =
  | { kind: "transport" }                                   // callTool / directCall(再送しない)
  | { kind: "serve"; snapshotId; token; tools; relays; innerCalls }
  | { kind: "provide"; snapshotId; scopeId; descriptor; continuation; relays; innerCalls }
  | { kind: "parked"; call: McpDispatchCall };              // authorize 待ち(行 = park 証明)
```

mcp_serve / mcp_provide / mcp_parked のサブタイプテーブル 3 枚と「高々 1 つ」不変量の散文は消え、
判別は tag ひとつになる。recovery の分岐(§ mcp-reactor)は既にこの直和で書かれているので、
デコード後そのまま合流する。

## 3. DB は 1 テーブル

`ffi_instances / http_instances / webhook_instances / mcp_instances / mcp_serve_instances /
mcp_provide_instances / mcp_parked_instances / time_instances` →
**`external_call_instances(instance_id PK FK→instances CASCADE, status, extension jsonb)`** 1 枚。

- reactor の自己選択は封筒(`instances.kind`)との join で行う — ext 側に reactor 列は持たない
  (SoT は封筒)。
- **seal が一様になる**: extension 文書を既存の `sealForStorage` / `unsealFromStorage` に通す
  (今日と同じく private ノードだけが `$sealed` になる node-level 封印 — 文書全体の暗号化ではない)。
  「webhook の callback は seal、mcp の descriptor は seal、…」という kind 別の列挙が
  「Ext は seal される」という 1 規則になる。
- migration: 新テーブルを作り、既存 5+3 テーブルの生存行を kind ごとに `json_build_object` で
  写してから drop する(開発期だが、rc8 利用中のデータを黙って捨てない)。

### 3a. capability routing は独自の概念 — pre-flight が暴いた複製

pre-flight で判明: 裸 token での DB 検索は**存在する**(facade の `deliverWebhook` が
`webhook_instances.token`、`deliverMcp` が `mcp_serve_instances.serve_token` を unique index で
引く)。cold な project へ inbound POST を routing する load-bearing な経路であり、しかも
**webhook と mcp-serve が同じ機構を別々に複製している**。これ自体を畳む:

- 新テーブル **`capability_routes(token text PK, project_id FK CASCADE, instance_id FK→instances
  CASCADE)`**。「公開 capability token → (project, instance)」という routing の**索引**である。
  SoT は ext 行(token は Ext 文書の中に居続け、reload 時の warm 再登録もそこから行う)— routes は
  cold-start の inbound 配送のためだけに、ext と**同一コミット**で維持される射影。teardown は
  instance drop の FK cascade に委ねる(明示 delete なし)。
- 書き手は token を mint する reactor(webhook / mcp-serve)の persist、`tx.routes.putRoute` 経由。
- facade の 2 つの bespoke query は **1 つ**の `capability_routes ⋈ instances.kind` 検索になる
  (kind 不一致は 404 — deliverWebhook は webhook 行しか受けない)。将来の inbound reactor は
  行を書くだけで同じ配送に乗る。
- token は今日も plaintext 索引列なので、routes を plaintext に保つことは後退ではない。

### 3b. run-tree は codec を import して読む

`run-tree.repository.ts` は ffi/http の型付き列(key / status / snapshotId)を直接 SELECT していた。
改訂後: `status` は `external_call_instances` の実列のまま読み、kind 固有の表示欄(ffi の key /
snapshotId)は **reactor が輸出する純関数 `decodeExtension`** で Ext 文書から取る(1 run 分の木で
行数は小さく、対象 field は private でないので unseal 不要 — `$sealed` ノードは触らない)。SQL で
`extension->>'key'` を掘るのは codec の schema を暗黙複製するので**やらない** — 型は codec が守る。

## 4. Db / Storing の二重実装は「行 CRUD の差」だけに縮む

turn-commit の意味論(書き込み順序・sticky terminal・cascade・エンベロープ先行)を **1 実装**に
畳み、差分は行ストアの port に閉じる:

```ts
interface RowStore { /* 論理テーブルごとの get / put / delete / 範囲読み */ }
```

- drizzle 実装(SQL、cascade は FK に委譲)と Map 実装(cascade を同じ 1 箇所のロジックで模倣)の
  2 つが RowStore を与え、`DbPersistence` / `StoringPersistence` は薄い合成になる。
  562 行のテスト専用 twin は「Map の RowStore + 共有ロジック」に置き換わる。
- InMemoryPersistence(no-op)は不変 — warm が真実、という既定はこの設計の外側。

## 5. reactor 側の変化

- `ExternalCallReactor` の persist / recover 契約が「status + Ext codec」で一様になる。各 concrete
  (ffi / http / webhook / time / mcp)は Ext 型と codec と recover の分岐だけを持つ。
- 命名ゆれ(`snapshot` vs `snapshotId` が Row / Instance で食い違う)は codec 内で正準化して解消。
- 挙動は不変: at-most-once(http / mcp-transport)、re-register(webhook / serve)、re-arm(time)、
  park 再構成(mcp-parked)、FFI の warm-reset / process-death 判別 — 全て既存テストが pin 済み。

## 6. 測定と受け入れ基準

- 対象 4 ファイル + execution.ts で **−900〜1100 行**(codec 新設 ~150 行込みの純減)を見込む。
- 全 runtime テスト green(366+)。挙動変更ゼロ(このウェーブは純粋な再基礎化)。
- migration は fresh DB(0000→末尾)と rc8 データ入り DB の両方で検証。
- 触った file のコメントは why-文へ整理(stale な kind 別散文の削除もこのウェーブの成果物)。
