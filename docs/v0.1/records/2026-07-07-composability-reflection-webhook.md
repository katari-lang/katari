# 合成可能性: use provider / reflection / MCP / webhook.inbound (v0.1.0, scrap-and-build)

ゴール: **MCP・カレンダー・検索などの外部統合を、最小限の努力で、拡張性とモジュラリティを保って合成できる体験**。
具体的には、アプリのルートがこう書けること:

```katari
use gemini.provider(model = "gemini-3.5-flash", api_key = env.get_secret(key = "GEMINI_API_KEY"))
use e2b.provider(api_key = env.get_secret(key = "E2B_API_KEY"))
use tavily.provider(api_key = env.get_secret(key = "TAVILY_API_KEY"))
use discord.provider(token = env.get_secret(key = "DISCORD_TOKEN"))
let tools: mcp.toolbox = use mcp.provider(url = url, headers = record.empty())
```

このドキュメントは、それを成立させた 4 つの変更(言語 1、prelude 2、ランタイム 2)と、
併せて行った 2 つの設計判断(MCP の配置、memory の外部化)を記録する。

## 1. `use f(args)` — call-provider は「引数マージの一回適用」

### 問題

従来の `use e` は `e` を評価してから `(結果)(continuation = k)` と二段適用する意味論だった。
このため「provider を返すファクトリ」`use mcp_provider(url)` は、返り値の agent が継続の結果型 R と
エフェクト行 E について多相でなければならず(rank-2)、単相化する現在の推論
(`synthApplicationCallee` がスキームを返すのは変数参照・qualified 参照・handler 式のみ)では成立しない。
内側の呼び出し時点では `url` しか制約がなく、R/E は推論不能 (K3016) になる。

### 決定

provider が構文上の呼び出し式であるとき、`use f(args…)` を **`f(args…, continuation = k)` の
一回適用**として型付け・lower する。継続が同一呼び出しサイトの引数になるので、R/E は
`use handler` と同じ機構(継続引数からの推論)で決まる。

さらにレビュー(「呼び出しだけ特別扱いは ad-hoc」)を受けて、**`use` を適用形式として定義し直した**:
provider に許される形は「handler リテラル | (qualified) 名前 | 明示インスタンス化 `p[T]` |
適用 `<callee>(args…)`」のみで、意味は常に一つ — **「provider を `{書いた引数 ∪ continuation}` に
一回適用する」**(bare 形は零引数の場合)。フィールド読みや match などそれ以外の式は K3011 で拒否し、
`let p = …; use p` か `use expr(args…)` に書き直させる。形によって意味が変わる余地はない。

- checker: `handleUseStatement` が `ExpressionCall` は `synthCallArgumentsWith`(書かれた引数 +
  合成 `continuation` フィールド)で一回適用、handler / 名前 / TypeApplication は零引数適用、
  他は K3011。`continuation` は use 適用内の予約ラベル(明示すると K3011)。
- lowering: `lowerUse` が `delegateCall`(`lowerCall` と共有)で引数レコードに継続クロージャを
  合流させた **単一の delegate** を emit(generics スタンプ込み)。
- 直接呼び出し形 `p(url = …, continuation = f)` とも一貫する(provider はただの agent)。
- 発見・修正した潜在バグ: `lowerUse` の binder が継続プロトコルレコード `{value: A}` **全体**を
  束縛していた(`value` フィールドの射影が抜けており、`let x = use p(...)` の x が
  `{value: …}` になる)。binder 付き use の実行は本変更の MCP e2e が初出で顕在化。
  LoweringSpec に射影の回帰テストを追加。

provider の書き方(rank-2 不要、ただの generic agent):

```katari
agent provider[R, effect E](
  api_key: string of private,
  continuation: agent (value: null) -> R with {...E, get_e2b_key},
) -> R with E {
  use handler (var key = api_key) { request get_e2b_key() { next key } }
  continuation(value = null)
}
```

破壊的変更: 旧「二段適用」を期待する `use <call>` は意味が変わる(開発期につき許容)。
ファクトリを使いたければ `let p = make_provider(...)` して `use p`。

## 2. `prelude.ai` → `prelude.reflection`、`as_tool` と `$tool` 値

### リネーム

`get_metadata` / `call_agent` は AI 固有ではなくリフレクションそのもの。`prelude/ai.ktr` を
`prelude/reflection.ktr` に改名(`reflection.get_metadata` / `reflection.call_agent` /
`reflection.agent_metadata` / `reflection.call_error`)。ランタイムのレジストリキー
(`prelude.reflection.*`、core-reactor の `CALL_AGENT_NAME`)も同時に更新。
副次効果として、ユーザーモジュール `ai`(discord example の AI 層)と prelude qualifier `ai` の
衝突が消えた。

なお FFI port はもはや `call_agent` の名前をハードコードしない(§2.1)。`call_agent` は
**katari 言語側の動的ディスパッチプリミティブ**として、そして webhook reactor の配信経路として残る。

### `$tool` — reactor-backed agent(ランタイムが mint する第 3 の callable)

設計は 2 段階で収束した。当初は `reflection.as_tool` primitive をユーザー向けに公開 → レビュー
(「as_tool をユーザーが呼べるのは微妙」「tool = agent の同一視がしたい」)で **as_tool 削除・
ランタイム mint 化**(tool = call_tool の部分適用、`bind` + `argumentField` を値に持つ)→ 再レビュー
(「argumentField は結局 call_tool の一要素で、call_tool がハードコードされている」「全体に ad-hoc」)
で **最終形: tool の実行体を Katari agent ではなくリアクタそのものにする**。

callable 値は 3 種で閉じる:

```
named agent  = コンパイル済みコードへの参照
closure      = block + captured scope
tool         = reactor + context + 実行時シグネチャ   ← external agent 宣言の「値版」
```

`{ "$tool": name, "reactor", "context": <value>, "snapshot", "description", "inputSchema",
"outputSchema"? }`。`context` はリアクタ所有の不透明な実行コンテキスト(MCP なら `{url, headers}`
のサーバー記述子。secret は privacy marker のまま乗り、封印/redact が自動で効く)。closure が
(block, scope, args) を別枠で運ぶのと同型に、tool は (reactor+name, context, args) を運ぶ —
引数の組み立て・`bind`・`argumentField`・中継用の compiled agent(旧 `call_tool`)は全て消えた。

- **動的ディスパッチは emit サイトで解決**: エンジンの delegate 操作(callee 値と、名前
  `call_agent` の呼び出し — 引数から `{target, args}` を剥がす)・FFI(§2.1)・webhook が、共有の
  `engine/dynamic-dispatch.ts` `dispatchCallable` で callable 値 → `DelegateTarget` + 行き先
  reactor に解決する。tool は inputSchema 検証(違反は catch 可能な `reflection.call_error` —
  エンジンが `raiseThrow` する)ののち **`external` target + context として直接 mcp reactor へ**
  1 委譲で届く。core の acceptance unwrap(「同一委譲の re-target」)は廃止 — cancel の
  ルーティング(terminate の peer)も正しくなり、ラッパーホップも消えた。core の acceptance は
  compiled agent の入力適合検証(callee 側検証、常に `call_error`)に専念する。
- `get_metadata` は mint された name / description / inputSchema と、サーバーが宣言していれば
  outputSchema(なければ `{}` = unknown)を返す。
- codec / json.encode / validation / privacy(context の taint)/ ascent(context 内リソースの
  到達性)/ port(FFI 側は `KatariAgent` として受ける)を新 `$tool` 形に対応。

これで **動的に発見されるツール(MCP の tools/list)** が、コンパイル済み agent と見分けの
つかない形で既存の AI ツールループ(get_metadata / call_agent だけを使う)に流れ、
MCP 固有の接着剤は言語にもエンジンにも残らない。

### 2.1 FFI の値ディスパッチは `call_agent` を経由しない

問題: FFI port の `KatariAgent.call`(handler が受け取った callable 値の呼び出し)は当初、sidecar
プロトコルの `delegate` が **agent 名 (string) しか運べない**ため、`prelude.reflection.call_agent`
という stdlib agent 名を port にハードコードし、`{ target, args }` を引数に密輸して core の
unwrap に再具体化させていた。この暗黙の ABI(port が prelude の agent 名を知っている)が原因で、
`prelude.ai.call_agent` → `prelude.reflection.call_agent` のリネーム時に、古い port で bundle された
FFI blob が実行時に未知 agent へ delegate し panic する、という検知しづらい壊れ方をした。

決定: `delegate` メッセージの宛先を discriminated な `callee` にする。

```ts
type DelegateCallee =
  | { kind: "named"; agent: string; reactor?: string }   // context.call(name)
  | { kind: "value"; callable: Json };                    // KatariAgent.call — 生の $agent/$closure/$tool
```

- port は callable の wire JSON をそのまま `value` callee に載せて送る(名前は一切持たない)。
  `context.call(name)` は従来どおり `named` callee。port の `CALL_AGENT` 定数は削除。
- ffi reactor(`resolveInnerCall`)が `value` callee を受けたら `jsonToValue` で復号し、上記
  `dispatchCallable` で `DelegateTarget` に解決、`openInnerDelegation`(generics 引数を追加)で
  **core への通常の inner delegation** を開く。既存の proxy / escalation 中継 / cancel カスケードが
  そのまま面倒を見る — **中間に立っていた `call_agent` インスタンスが 1 つ消える**。
- 失敗の扱いは katari 側と分ける: `call_agent` は catch 可能な `reflection.call_error` を投げるが、
  FFI 経路の失敗(不正な callable 値・tool schema 違反)は **panic**。境界を越えて流れてくる callable
  値が不正なのは通常ありえないバグなので、動的ディスパッチの想定内エラーとしては扱わない。

結果として port は prelude の agent 名に依存しなくなり、この種のバージョンずれは原理的に起こらない。

## 3. prelude の再編

- `prelude/json.ktr` に読み取りヘルパ `or_null` / `field` / `element` / `text` を追加
  (discord example の `jsonx` を昇格・全て素の Katari agent)。形が既知の文書には従来どおり
  typed boundary (`parse_as[T]` / `decode[T]`) を推奨、というスタンスはヘッダに明記。
- `prelude/http.ktr` に `post_json`(+ `status_error`)を追加。JSON API 統合の標準形
  「body を json で組み、POST し、応答を json で読む」の一撃呼び出し。example の `api.ktr` は削除。
- `http.fetch` の返り値に **`headers: record[string]`** を追加(名前は小文字化、重複ヘッダは
  ", " join)。セッショントークン・rate limit・Location 等をプログラムから読めるようにする
  (MCP の純 Katari 実装可否の検討から独立して有用、と確認済み)。

## 4. `webhook.inbound` — 動的 inbound エンドポイント

### 宣言 (prelude/webhook.ktr)

```katari
external agent inbound[R, effect E](
  callback: agent never -> unknown with E,
  subscriber: agent (url: string) -> R with E,
) -> R with E from "webhook"
```

`http.fetch` の逆向き: ランタイムが推測不能な公開 URL(`POST /inbound/<token>`、bearer 認証の
外側 — URL 自体が capability)を発行し、subscriber が生きている間、そこへの POST を callback の
呼び出しに変換する(JSON body → 引数、callback の結果 → JSON 応答)。subscriber が URL の
生存期間を所有する: 外部サービスへの登録(カレンダー push、リポジトリ webhook — 通常は
ライブラリの FFI)を行って購読が続く限り生き、return / cancel で URL は無効化される。

### ランタイム (webhook reactor)

`ExternalCallReactor` の第 5 のリアクタ(`ReactorName` / `InstanceKind` / kind check /
`webhook_instances` テーブル / migration 0001)。ffi / http と方向が逆なので、リカバリも逆:

- **payload(token + callback)を永続化**し、reload で token を再登録 — エンドポイントは
  再起動を完全に生き延びる(照合すべき外部プロセスがないため at-most-once の失敗化が不要)。
  subscriber は durable な core 委譲として自力で再開する。
- 配信は inner delegation。callback / subscriber は **直接委譲**する(call_agent を経由しない)。
  検証は委譲境界(callee のスキーマを、callee が召喚される時点で照合 = 「検証はコールされた側が
  する」)。失敗チャネル: スキーマ違反 = `reflection.call_error` → HTTP 400、panic → 500。
  例外は callback が `as_tool` 製の `tool` 値のとき — コンパイル済みブロックがないので call_agent の
  unwrap 経由で実行時スキーマ検証する。
  - これに伴い **委譲境界の引数不適合は常に `reflection.call_error`**(回復可能な throw)に統一した。
    静的呼び出しは checker が適合を保証するので発火せず、発火するのは動的入力(call_agent の args、
    run 引数、webhook body)のみ — どれも「予期される外部入力エラー」なので panic より call_error が
    適切。run 引数違反の誤り種別が panic → call_error に変わる(いずれも run を失敗させる)。
- subscriber の settle がコール全体の settle(結果は `inbound` の返り値)。cancel は
  base の cascade(subscriber の FFI cleanup が走る)→ token 解放 → terminateAck。
- 再起動を跨ぐ配信中の HTTP waiter は失われる(プロバイダの再送が再配達)— ドキュメント済み。

HTTP surface: `POST /inbound/:token` は `/api` の外(auth バイパス)。200 は callback の結果を
**素のボディ**で返す(URL 検証ハンドシェイク等をプログラム側で制御できる)。
`KATARI_PUBLIC_URL` が mint される URL のベース(未設定はローカルポート)。

## 5. 判断: MCP はランタイム組み込み(`prelude.mcp` + `mcp` reactor)

当初は FFI sidecar ライブラリ(example 内 `mcp.ktr` + `mcp.ts`)で実装したが、レビューで
「tool 機構(reflection)がランタイムにあるのに MCP だけユーザーが SDK を install するのは非対称」
との指摘を受け、**ランタイム組み込みに変更**(ユーザー確認済み):

- `prelude/mcp.ktr` は実質 **1 宣言**: `external agent tools(url, headers: record[string of
  private]) -> toolbox from "mcp"` + 型(`server_error` / `tool` / `toolbox`)+ `tools_of`
  (素の Katari)。**connect / call_tool / close / provider は存在しない** — 接続はユーザー可視の
  リソースではないので、スコープすべきものがなく `use` も不要。
  `let tools = mcp.tools(url = ..., headers = record.empty())` という素の呼び出しが全て
  (「`use` は capability の導入、値は `let`」の区別が立つ)。
- **mint はリアクタ側**: transport は listing(name/description/schemas)だけを返し、
  `McpReactor.transformResult`(base の seam)が呼び出しの**元の引数 Value**から記述子を組み立てて
  tool 値を鋳造する — secret ヘッダの privacy marker が mint 後も生きる(transport への reveal 済み
  コピーは値にならない)。
- **接続 = 記述子 + lazy キャッシュ**: tool は `{url, headers}` 記述子を context に持ち、transport が
  記述子キーのクライアントキャッシュで初回接続・再利用・失敗時 evict → 次回再接続を行う。
  **再起動は透過的に治る**(キャッシュが空になるだけ。scope に生き残った tool 値は次の呼び出しで
  再接続)。close-on-escape 問題は概念ごと消滅 — MCP に finalizer は不要になった。
- ランタイム: 第 6 のリアクタ `mcp`(http のミラー: `mcp_instances` は status のみ、引数は
  非永続、at-most-once。restart で中断された in-flight 呼び出しは typed `server_error` で失敗し、
  katari 側の retry が再接続経由で成功する)。transport は公式 SDK(streamable HTTP → SSE
  フォールバック)を**ランタイムイメージに同梱** — ユーザーは何も install しない。
- あらゆる予期される失敗(接続拒否・tool の isError・transport 断・restart 中断)は
  **typed `throw[mcp.server_error]`** に統一(http の fetch_error と同じ位置づけ)。

純 Katari 実装(SDK なし)は `http.fetch` のヘッダ返却だけでは足りない(SSE ストリーミング、
サーバー起点通知)ため見送り。ヘッダ返却自体は独立して追加した(§3)。

### tool 呼び出しの経路(「tool 専用 reactor にすべきか」への答え)

分けない — そして最終形では中間層そのものが消えた。経路は
`tool 値の呼び出し →(emit サイトで inputSchema 検証)→ mcp reactor(I/O)` の **1 委譲・
2 インスタンス(caller の proxy + mcp コール)**。検証はディスパッチの emit サイトに
(全 callable と同じ `dispatchCallable`)、I/O は mcp reactor に。旧設計の
「core の call_tool ラッパー 1 ホップ」も「transport が call_tool のシグネチャを知る結合」も
存在しない。tool は値であって実行資源ではない、が結論。

留意(スコープ外として記録): 接続キャッシュは使い回しなので、stateful な MCP セッション機能
(sampling / subscriptions / セッション固定)は対象外。tools/list + tools/call の利用が対象。

## 6. 判断: memory(KV 永続化)はランタイムに入れない

結論: **v0.1.0 ではランタイム組み込みの KV primitive を追加しない(外部化)**。理由:

1. run 内の永続状態は handler state が既にカバーしている(会話履歴などは durable)。
2. run を跨ぐアプリデータは実行ストアとは責務が別(容量管理・GC・スキーマ移行・バックアップを
   実行エンジンの Postgres に背負わせない)。
3. 本変更で接続コストが十分に下がった: memory は「MCP の memory server に
   `mcp.tools(...)` 一行」「Upstash 等の HTTP KV に `http.post_json`」「FFI ライブラリ」の
   三経路で最小努力になる — まさに今回の合成モデルの適用例であり、組み込みにする動機が消えた。

将来、実行トレースと結合した first-class な記憶(run 横断の検索など)が要件になったら、
その時に専用設計として再検討する(env store と同じ host-prim 形が候補)。**この方針は確認済み。**

## 7. レビューで挙がった検討事項(解決済み)と残タスク

### 残タスク(v0.1.0 候補、未着手)

- **finalizer(cancel 窓の解放処理)**: terminate → terminateAck の窓は callee のもので、ランタイム側の
  受け皿は既にある(webhook の token 解放、FFI の `context.signal` cleanup が実例)。欠けているのは
  言語表面 — スコープに「cancel の cascade 中 / throw の unwind 中に走る finalizer」を書く構文
  (`defer` / bracket 相当)。MCP は接続レス化(§5)で不要になったが、provider パターン一般
  (e2b 等のリソースを掴む provider)には依然必要な言語機能。

### 再設計で解決(「tool = reactor-backed agent」、§2 / §5 に反映)

当初「v0.2 の種」としていた 3 件は、tool 値の再設計そのもので v0.1.0 内に解決した:

- **MCP 接続の永続化(lazy reconnect)** → 接続 handle を廃止し、tool が `{url, headers}` 記述子を
  context に持つ形へ。transport の記述子キーキャッシュが lazy (re)connect。再起動は透過回復。
- **external 直参照の callable 値** → `$tool` 自体を「reactor + context + 実行時シグネチャ」に
  再定義。パススルーの core ラッパーホップと call_tool シグネチャ結合は消滅(call_tool 自体が
  存在しない)。
- **MCP `outputSchema`** → mint 時に載せ、`get_metadata` の output で返す(なければ `{}`)。
  結果の実行時検証は行わない(metadata のみ)。

### 解決済み

- **MCP の first-class 化** → **(B) ランタイム組み込みを採用**(§5 に反映)。純 Katari 化(C)は
  SSE ストリーミング / サーバー起点通知が `http.fetch` の拡張では届かないため見送り。ただしヘッダ
  返却自体は独立して有用なので追加した(§3)。
- **`as_tool` の位置づけ** → 再レビュー(「tool = agent の同一視」)を受けて **削除**。さらに
  「argumentField は call_tool の一要素で call_tool がハードコード」「全体に ad-hoc」の指摘で
  中間形(`bind` + `argumentField` の部分適用)も廃止し、reactor-backed agent に最終化(§2)。
  OpenAPI 等の自作コネクタが将来必要になったら、その時に mint 用 API を再設計する。
- **tool 呼び出しの専用 reactor 化** → 分けない(§5 末尾)。検証は emit サイトの
  `dispatchCallable`、I/O は tool の backing reactor、という責務分離で、tool は値であって
  実行資源ではない。

## 検証

- compiler: 551 examples / 0 failures(use の適用形式制限・binder 射影の回帰、
  `prelude.mcp` / `http.fetch` ヘッダの stdlib 変更を含む)。
- runtime: 235 tests(tool ディスパッチ両経路 — call_agent 経由と値の直接委譲 — が emit サイト
  検証+mcp reactor 直行であることと secret reveal の境界、get_metadata(outputSchema 込み)、
  webhook の配信 / スキーマ違反 / トークン失効 / **再起動生存**、§2.1 の FFI 値ディスパッチ、
  mcp reactor の listing mint / typed throw / **at-most-once リカバリ**、そして **実 MCP サーバを
  立てた actor 統合テスト**(list → mint → call_agent、lazy connect)を追加)。port: 42 tests。
- playground: `webhook.ktr`(自己 POST で外部依存ゼロ)+ `mcp_demo.ktr`。**e2e 11/11** — e2e が
  実 MCP サーバ(SDK の streamable HTTP、stateless)を立て、コンパイル済み prelude + 実 Postgres
  越しに「`mcp.tools` → mint → get_metadata → call_agent(19+23=42)」を検証する。
- discord example: 全面リライト(20 modules, no errors — MCP は prelude 化で example から消え、
  `mcp.` qualifier はそのまま prelude.mcp に解決される)。
