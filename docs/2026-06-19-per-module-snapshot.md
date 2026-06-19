# Katari Runtime — module 単位アップロードと snapshot 再定義 (v0.1.0, scrap-and-build)

> 2026-06-19 の設計議論のまとめ。runtime の「snapshot = 全 module を 1 枚岩で同梱した
> 不変バンドル」を、**content-addressed な module store + その上の manifest** に再定義し、
> CLI が **module 単位で差分アップロード**できるようにする。
>
> [runtime-domain-model](2026-06-15-runtime-domain-model.md) を土台にした増補。本 doc が
> snapshot / module / upload まわりの SSoT で、domain-model 側の §3 (Snapshot) と §6
> (schema) はこの再定義に合わせて改訂済み。

---

## 0. 動機 — 既に半分は per-module に倒れている

Haskell 側 (`katari-project`) は既に **per-module / content-addressed アップロード**を前提に
作られているのに、TS runtime 側だけが旧来の「全 module 同梱の 1 枚岩 snapshot」のまま残って
いた。本設計はこの食い違いを橋渡しする。

- `Katari.Project.Upload`: `ModuleHash = SHA-256(canonical IR)`、
  `planUpload :: Map ModuleName IRModule -> Map ModuleName ModuleHash -> UploadPlan` —
  CLI が module 単位で hash 比較し差分だけ上げる設計。
- `Katari.Compile`: 「runtime は module を個別にアップロードするので lowering は per-module の
  `IRModule` を出し、whole-program link step は無い」。

旧 runtime 側:

- `snapshots` テーブル = `{ id, projectId, modules: Record<ModuleName, IRModule>, ... }` —
  **IR を丸ごと 1 つの JSONB に inline**。1 回のアップロードで全 module を置き換え新 id。

---

## 1. 3 層モデル

「module にバージョンを付け、snapshot をその集合とする」方向性を、混ざりがちな 3 つの関心に
分けて整理する。旧 runtime は (1) と (2) を癒着させていた (snapshot id が「不変バンドルの
identity」と「IR 本体」を兼ねていた)。これを割る。

| 層 | 中身 | 性質 |
|----|------|------|
| **1. module store** | `(project, moduleHash) → IRModule` | content-addressed・不変・自動 dedup |
| **2. snapshot (= manifest に再定義)** | `snapshotId → Map ModuleName moduleHash` | 不変・「一貫した世界の 1 版」 |
| **3. head pointer** | `project → 現在の snapshotId` | 可変・「今ライブな版」。rollback = 付け替え |

旧 `snapshots.modules`（`name → IRModule` の inline）が、`name → moduleHash`（store への参照）
に変わるだけ。これで dedup と per-module 差分アップロードが自然に落ちてくる。

### identity = content hash

module の「バージョン」は **content hash そのもの**とする（連番カウンタは採らない）。

- 連番は runtime が「次の番号」の真実源になり可変状態が増える。hash なら同一内容が自動同一に
  なり、dedup と再アップロードの冪等性がタダで手に入る。
- 人間向けの連番が欲しければ、それは identity ではなく**表示レイヤ**に後付けできる
  (「module foo: 3 版 deploy 済み、現在 = abc1234」のような lineage 表示)。

`ModuleHash` = `IRModule` の **canonical serialization の hex SHA-256**。canonical 化は
`Katari.Project.Upload.hashModule` が担う（§5）。

---

## 2. snapshot の再定義と pin セマンティクス

domain-model の glossary では Snapshot = 「不変・実行可能・rollback 可能な code version」。
この語義はそのまま保ち、中身だけ「全 IR の同梱」から「per-module hash の manifest」に変える。
rollback のストーリはむしろ綺麗になる（head を古い snapshot に向けるだけ）。

### instance は snapshot を pin する（snapshot-pinned）

走行中 instance は起動時の snapshot を pin し、**生存中ずっとその版の一貫した世界を見る**。
依存 module を上げても既存 instance は影響を受けず、recovery / replay は決定的になる。これは
Katari の価値（永続・長寿命・復旧可能な実行）に必須の保証で、module 単位の floating-latest は
採らない。

### pin は delegate event のスタンプで自動的に伝播する

重要なのは、この保証に**特別な機構が要らない**こと。

1. instance は起動 target `(qualifiedName, snapshot)` を持ち、`snapshot_id` を denormalize
   している（domain-model §6、既存のまま）。
2. その instance 内で `OperationDelegate` が発火 → 外部 `delegate` event に変換される際、
   **実行中 instance 自身の snapshot がスタンプされる**（`DelegateTarget.snapshot`）。
3. delegate event は既に snapshot を運ぶので、相手 module の版は「event の snapshot で引く」
   だけ。新規 instance はその snapshot を pin して生まれ、以降も同じ snapshot を伝播する。

→ cross-module delegation が常に同じ snapshot 内で閉じ、「一貫した世界」が event 伝播から
自動的に出てくる。**head pointer を見るのは instance 誕生時（外部トリガ / API から run 起動）
だけ**で、内部 delegate は自分の snapshot を継承し head を見ない。

### 層ごとの変更まとめ

| 層 | 変更 |
|----|------|
| event / addressing（`DelegateTarget = {name, snapshot}`、closure の snapshot 付与） | **変更なし** |
| 解決経路 | `snapshot → IRModule`（直接）から **`snapshot → moduleHash → IRModule`（一段間接）** へ |
| storage | `snapshots.modules` を `name → IRModule` から **`name → moduleHash`** に。新規 `modules` テーブル `(project, hash) → IRModule`。`projects.head_snapshot_id` 追加 |

`DelegateTarget` の `snapshot: SnapshotId`、closure 値の `{ blockId, scopeId, snapshot }`、
instance の pin はそのまま。**実際の作業は storage の分割と解決の一段間接化に集約される。**

---

## 3. CLI の責務と upload API

### 差分は転送の最適化、manifest コミットは完成形を送る

最重要の原則: **差分（hash 比較）は「無変更 module のバイトを再送しない」ための最適化に
すぎず、snapshot のコミットは差分ではなく desired world 全体（完成した manifest）を送る。**

「M を足して N を消す」差分コミットは結果が server の事前状態に依存しレースに弱い。新 snapshot
は世界の完全な記述であるべき。`removed` は「新 manifest がその module に言及しない」だけで
自然に表現される（IR blob 自体は旧 snapshot や走行中 instance が参照していれば保持、GC は §6）。

### CLI の手順

1. project 全体を build → `Map ModuleName IRModule`。
2. 各 module を `hashModule` で hash。
3. **`GET head`** で runtime が今持つ `Map ModuleName ModuleHash` を取得。
4. `planUpload` で diff（`changed` / `unchanged` / `removed`）を計算しユーザに表示。
5. **完全な module 集合**を `POST snapshots`（`changed` は `ir` 込み、`unchanged` は hash のみ、
   `removed` は省く）。

`Katari.Project.Upload` の `planUpload` / `hashModule` / `UploadPlan` がこの 2〜4 を担う
（純粋・テスト可能）。CLI に残るのは HTTP エンベロープだけ。

### API 契約（v0.1）

Docker registry push（blob upload by digest → manifest PUT）を 1 リクエストに畳んだ hybrid。
帯域節約・原子性・部分状態なしを 1 往復で両立する。

```
GET /api/v1/projects/{projectId}/snapshots/head
  200 → { snapshotId: string | null,        // 未 deploy なら null
          message: string | null,
          modules: { [moduleName]: hash },   // 現 head が参照する per-module hash
          createdAt: string | null }

POST /api/v1/projects/{projectId}/snapshots
  body {
    message: string,
    sidecarBundle?: Json,
    modules: {
      [moduleName]: { hash: string, ir?: IRModule }   // ir は runtime が未保有の hash だけ inline
    }
  }
  runtime:
    1. 参照される全 hash が解決する（store 済み or inline）ことを検証。1 つでも欠ければ 422。
    2. 新規 IR を hash で store に upsert（content-addressed・冪等）。
    3. 不変 snapshot を作成（modules = name→hash）。
    4. project head を atomic に前進。
  201 → { snapshotId: string }
```

- **冪等性**: module の store は hash がキーなので、同じ内容の再 PUT は no-op。CLI が事前に
  diff するので、そもそも未保有分しか `ir` を送らない（二重の最適化：CLI 側で送らない・
  runtime 側で重複保存しない）。
- **hash は trust（opaque key）/ verify（runtime 再 hash）の選択**: v0.1 は単一信頼 CLI
  なので、CLI 提供 hash を opaque key として trust で十分。store 健全性を厳密化するなら
  canonical 化を TS 側にも実装し受信バイトを再 hash して検証するが、これは v0.1 では過剰（§5）。
- **rollback**: head を古い snapshot に向ける別 API（`PUT snapshots/head { snapshotId }`）で
  実現できる。本設計の storage はこれを許すが、エンドポイント自体は後続作業。

> NOTE: 上記 HTTP リソースの実装は runtime の snapshot リソース scaffold（domain-model §5
> の stateless HTTP リソース、実装計画 Phase 1 / 8）に属する。本 doc 時点では storage モデルと
> Haskell 側 plan を先に固める（§4 が実装済みの範囲）。

---

## 4. 実装範囲（本 doc 時点）

| 対象 | 内容 | 状態 |
|------|------|------|
| `Katari.Project.Upload` | `hashModule`（canonical SHA-256）・`planUpload`（純粋 diff） | 実装 |
| runtime `db/tables/projects.ts` | `modules` テーブル新設・`snapshots.modules` を hash 参照に・`projects.head_snapshot_id` 追加 | 実装 |
| runtime `runtime/ids.ts` | `ModuleHash` ブランド型 | 実装 |
| drizzle migration | 再生成 | 実装 |
| HTTP リソース（`GET head` / `POST snapshots`） | §3 の契約 | 後続（snapshot リソース scaffold） |
| 解決経路 `snapshot → hash → IR` | engine の IR ロード | 後続（engine 未実装） |

---

## 5. `hashModule` の canonical 化

`ModuleHash` は `IRModule` の **canonical serialization の hex SHA-256**。canonical 化が
必要なのは、`Data.Map` / aeson の `KeyMap` の内部反復順に依存せず「同一 IRModule → 同一バイト」
を保証するため。

v0.1 では **hash を計算するのは Haskell CLI だけ**（runtime は受領 hash を opaque key として
trust）。よって cross-language な JSON 正準化（RFC 8785 等）は不要で、**Haskell 内での
自己一貫性**だけ満たせばよい。実装は aeson の `Value` を再帰的に走査し、object のキーを
ソートして決定的なバイト列に落とす（scalar の表現は aeson の `encode` をそのまま使う）。

注意点:

- **lowering の決定性が前提**。同一 source（+ 同一依存インターフェース）→ 同一 `IRModule`
  バイト → 同一 hash。`BlockId` 採番が module-local かつ決定的でないと「無変更なのに hash が
  変わる」で dedup が無意味になる。
- 理想は **module M の IR が N の本体ではなく N のインターフェース / schema にのみ依存**する
  こと（N の body 編集で M の hash がチャーンしない）。
- 現状は `IRModule` の wire 形全体（`names` のデバッグ名を含む）を hash する。デバッグ名変更で
  hash が動くのが気になれば、将来 semantically-significant な部分集合に絞れる。

---

## 6. retention / GC（v0.1 は保留可）

content-addressed store を割ったことで GC が新たな関心になる。

- module IR blob は「いずれかの live snapshot（head）/ 走行中 instance が pin する snapshot が
  参照」する限り保持。これは domain-model の RESTRICT FK（走っている版は消せない）の一般化。
- `snapshots.modules` は JSONB の `name → hash` map なので DB レベルの FK ではなく**アプリ層 GC**。
- **v0.1 は「GC しない」で十分**（module は安いし、まず正しさを優先）。mark（live snapshot の
  参照集合）& sweep は後続。

---

## 7. domain-model doc への反映

[runtime-domain-model](2026-06-15-runtime-domain-model.md) の以下を本設計に合わせ改訂済み:

- §3 Snapshot: 「全 IR 同梱」→「per-module hash の manifest」。Module（store）概念を追加。
- §6 schema: `snapshots(modules)` を `name → hash` に、`modules` テーブル新設、
  `projects.head_snapshot_id` 追加。
- §7 v0.2+: snapshot migration は head 付け替えとして本設計の延長線上に整理。
