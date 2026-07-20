# MCP OAuth を escalation に乗せる — 認証は「止まって、聞いて、続く」(v0.1.0, scrap-and-build)

ゴール: **OAuth の認証不能を typed エラーではなく user-facing escalation にする**。credential が無い・
refresh が死んだ・サーバーが 401 を返した — どの場合も mcp の provide / call インスタンスが
`prelude.mcp.authorize` を escalate して**止まり**、ユーザーが認証を完了すると **ack で再開**する。
env secret `mcp.oauth.<name>` の予約 namespace と `katari mcp login` は**削除**する。

旧設計([docs/2026-07-10-mcp-oauth.md](2026-07-10-mcp-oauth.md))の §2(credential store = env secret)と
§3(`katari mcp login`)は本ドキュメントが置き換える。§1(`auth` 直和)と型表面は不変。

## 0. なぜ escalation か

- 旧契約は「`auth_error` は retry では直らない。人間が `katari mcp login` を再実行する」だった。つまり
  **本質的に人間への問い合わせ**なのに、それをエラー + out-of-band な CLI + env secret という 3 つの
  ad-hoc な部品で表現していた。
- ランタイムには既に「実行を止めて人間に聞き、答えで再開する」仕組み — escalation — がある。認証要求は
  その一事例にすぎない: **escalate としては「認証情報を供給してください」という request であり、
  admin / CLI の rendering がそれを OAuth 認証要求として描く**。
- 利点: (1) 実行途中で refresh token が切れても run は失敗せず**一時停止 → 認証 → 再開**する。
  escalation 行は durable なので**ランタイム再起動も跨ぐ**。(2) env の ad-hoc な予約 namespace が消え、
  既存の escalation 系(永続化・一覧・answer・audit)にそのまま乗る。

## 1. authorize escalation — 表面と流れ

- **request 名は `prelude.mcp.authorize`**(`prelude.panic` / `prelude.throw` と同じ正準命名)。IR には
  宣言されない runtime-synthesized request で、`escalation-filter` の分類ではふつうの user-facing request
  である(panic でも throw でも control でもない)。argument は `{ url: string, name: string }`。
- **raiser は mcp の call / provide インスタンス**。エンジン経由ではなく reactor が自分の ask として
  raise する(`raiseThrow` / `raisePanic` の genuine-request 版)。既存の relay 機構で caller の core
  インスタンスを bubble し、api root の open escalation になる — 経路・永続化・answer・audit は全て
  既存のまま。
- `prelude.mcp.authorize` はどの row にも現れないので、ユーザーコードの `handle` に捕まることはなく、
  必ず api root まで届く(型システムには一切見えない変更である)。
- **escalate するのは oauth auth の認証不能すべて、かつそれだけ**: credential 不在、保存 blob の読解
  不能、refresh 不能な期限切れ / 失効、認証後もサーバーが 401 を返す場合。分類は従来どおりクラスで
  行う(transport の catch で `UnauthorizedError` 等)が、**descriptor の auth 変種で二分**する:
  - `oauth(name)` → `McpAuthorizationRequired { url, name }`(park 信号。typed エラーにならない)
  - `headers(values)` → 従来どおり typed `auth_error`(「同じ素材で retry しても直らない。鍵を直す」)
- **park と retry のループ**: mcp インスタンスは authorize を escalate したら操作(connect / listing /
  tool call)を park する。ack が来たら credential store を**読み直して操作を最初から再実行**する。まだ
  使えなければ再度 escalate する — 初回認証・refresh 死・ユーザーの空 answer・レースの全てがこの
  **一つのループ**で処理される。分岐は auth 直和の 2 変種だけである。
- **再実行の安全性**: 401 は HTTP 層の拒否であり、拒否された試行はサーバー側で実行されていない。
  よって authorize 後の再実行は at-most-once 契約を破らない。
- **再起動**: open な authorize escalation 行そのものが park 状態の SoT である。reload はそれを parked
  として再構築し(transport との reconcile で refuse **しない**)、reload 後の ack が再実行する。
- run の cancel は従来どおり teardown する(escalation は run と共に消える)。escalation が止めるのは
  その ask の leaf だけで、run の他 thread は走り続ける。

## 2. credential store — 専用テーブルが SoT、秘密は answer を通らない

- **`mcp_credentials` テーブルが token 素材の唯一の SoT**:
  `(project_id FK cascade, name) PK, value(AES-GCM sealed JSON), generation(integer), updated_at`。
  value は従来の triple `{ tokens, clientInformation, resourceUrl }` のまま。env entries の予約キー
  `mcp.oauth.<name>` は廃止(env は本来の用途に戻る)。
- 書き手は 2 つ、意味が違う:
  - **flow 完了(§3)**: 無条件 upsert(generation をインクリメント)— 新しい認証は常に勝つ。
  - **refresh 回転(provider)**: generation compare-and-set — stale な書き戻しは負ける(従来の
    content-hash CAS を実カラムにしただけ)。
- **token 素材は escalation answer を通らない**。answer 値が秘密を運ぶと、平文の
  `run_escalations_audit` 行と admin API wire に漏れる。escalate の契約は「認証情報を供給せよ」だが、
  その実現は「store への deposit + ack(= resume 信号、値は無視)」である。raiser は resume 時に store
  を読む。audit には question `{url, name}` / answer `null` が残る — 「ここで認証が要求され、許可された」
  という履歴としてちょうどよい。
- ランタイム側 read / rotate の seam は従来の port のまま:

  ```ts
  // runtime/external/mcp-oauth.ts が輸出する(実装ファイルの所有は engine 側)
  export const MCP_AUTHORIZE_REQUEST = "prelude.mcp.authorize";
  interface McpCredentialStore {
    load(name: string): Promise<LoadedMcpOAuthCredential | null>; // { credential, generation: number }
    save(name: string, credential: McpOAuthCredential, expectedGeneration: number): Promise<boolean>;
  }
  ```

  facade はこの port を `mcp_credentials` repository に束ねる(env service への束縛を置き換え)。
  flow 完了の無条件 upsert は port ではなく repository を直接使う(port は engine 側の seam だけに保つ)。
- 管理面: `GET /api/v1/projects/:projectId/mcp-credentials` → `{ credentials: [{ name, updatedAt }] }`、
  `DELETE .../mcp-credentials/:name`。CLI は `katari mcp credentials`(一覧)と
  `katari mcp forget NAME`(削除 — 別アカウントでやり直すときの強制再認証)。admin-web の管理 UI は
  作らない(endpoints で足りる。スコープ外として記録)。

## 3. OAuth フローの実行はランタイムに一本化

旧設計はフローを node helper(loopback listener + ブラウザ)が実行し、保存を CLI がしていた。新設計は
**ランタイムがフロー全体をホストする** — ランタイムは常駐サーバーであり、redirect callback の受け口として
自然である。フロー実装の SoT が 1 箇所になり、CLI と admin-web は「開始して URL を開く」だけの同型な
rendering になる。

- **開始**: `POST /api/v1/projects/:projectId/escalations/:escalationId/oauth-flow` →
  `{ authorizationUrl }`。対象 escalation が open でなければ 404、presentation が oauth 種でなければ 409。
  ランタイムは SDK の `auth(...)` orchestrator を in-memory provider で回し、discovery + dynamic client
  registration + PKCE + authorization URL 生成まで進める(旧 helper の `LoginProvider` と同じ 2 round
  構造。public client、`token_endpoint_auth_method: "none"`)。
- **flow 状態は in-memory** — `state` パラメータ(mint した UUID)をキーに
  `{ projectId, name, url, verifier, clientInformation, escalationId }` を TTL 付き Map で持つ。durable に
  しない: durable なのは escalation であり、フローは何度でも開始し直せる(再起動中にフローが飛んでも、
  escalation が残っているのでボタンをもう一度押すだけ)。寿命の所有者は flow service ただ一つ。
- **callback**: `GET /oauth/callback?code&state`(**public** — `/inbound` / `/mcp` と同じ capability-URL
  パターン。state が capability)。redirect_uri は `config.publicUrl`(webhook / serve の minted URL と
  同じ「one address, one knob」)起点の `<publicUrl>/oauth/callback`。code を交換し、triple を
  `mcp_credentials` に upsert し、**その (project, name) に対する open な authorize escalation を全て
  answer する**(値 null) — 「credential が使えるようになったら、それを待つ全ての ask が答えられる」
  という一つの規則。成功 / 失敗を小さな HTML で返す(「認証しました。アプリ / ターミナルに戻って
  ください」)。
- scope パラメータは渡さない(SDK + dynamic registration の既定に任せる)。必要になったら flow 開始
  endpoint に足す — スコープ外として記録。

## 4. rendering — wire は直和、表面はそれに従うだけ

escalation の wire 形は request 名 sniff を各表面に散らさず、**service 境界で一度だけ直和に畳む**:

```ts
type EscalationPresentation =
  | { kind: "form"; answerSchema: Json | null } // 従来の schema-driven form(answerSchema はここへ移動)
  | { kind: "oauth"; url: string; name: string };
// response = { id, request, argument, runId, createdAt, presentation }
```

- **admin-web**: `EscalationCard` は presentation で分岐。`form` は従来の `SchemaForm`。`oauth` は
  サーバー情報(url / name)と「Authorize」ボタン — 押すと flow 開始 endpoint を叩き
  `window.open(authorizationUrl)`。answer は callback 側で起きるので、カードは既存の polling /
  invalidation で消える。
- **CLI**: `katari answer` は oauth 種に対して schema interview ではなくフローを駆動する — flow 開始 →
  URL を印字 + best-effort でブラウザ起動(`xdg-open` / `open`) → escalation が消えるまで poll →
  「authorized; run resumes」。`--value` は oauth 種では意味を持たない(種ごとに挙動は一つ)。
  `katari status` は oauth 種を「OAuth authorization required for <url> (credential "<name>")」と描く。
- 生の answer API はどの escalation にも従来どおり使える(oauth 種の answer schema は無いので値は検証
  されない)。変な値で answer しても raiser のループが store を読み直して再 escalate するだけ — ガードは
  要らない。

## 5. 削除されるもの

- `katari mcp login`(`Mcp.hs` の `runLogin` / `CredentialBlob` / helper 起動)。`katari mcp pull` と
  list-tools helper は不変。
- node helper の `login` verb と `parseLoginArguments`。`@katari-lang/mcp` は list-tools 専用になる。
  **留意**: `performLogin` / `LoginProvider` / loopback listener は削除**しない** — `katari mcp pull
  --oauth` が codegen 時の listing 認証に使う ephemeral な(保存されない)フローで、ランタイムの
  credential ストーリーとは直交する dev-time の道具である。
- `mcpOAuthEnvKey` と env 予約 namespace `mcp.oauth.*`(facade の env 束縛ごと)。
- vscode 拡張の login / env 文言。
- `StoredMcpOAuthProvider` の対話 step は「`McpAuthError`(= login して来い)」から
  「`McpAuthorizationRequired`(= park して聞け)」へ。

## 6. 型表面 / エラー契約の変化

- `prelude/mcp.ktr` は**構文上不変**(auth 直和、provide / call / tool の row とも)。変わるのは doc
  comment の契約だけ:
  - `auth_error` = 「headers の鍵素材をサーバーが拒否した。同じ素材で retry しても直らない」。
    **oauth では決して投げられない**(投げる代わりに止まって聞く)。
  - provide / call の oauth 経路のエラー欄から「katari mcp login を再実行」の文言が消える。
- row から `auth_error` を外すことはしない — headers 経路が現に投げるし、外すのは型変更でありこの変更の
  スコープ外。
- wire drift(auth が未知 constructor 等)は従来どおり typed `server_error`。

## 7. テスト

- store: repository の CAS / upsert 意味論(unit)。
- flow: fake IdP(loopback の authorization + token endpoint)で 2 round を通し、callback →
  `mcp_credentials` 書き込み → open escalation の一括 answer まで(既存の mcp live loopback テスト基盤に
  fake authorization server を足す)。
- reactor: oauth credential 不在 → authorize escalation が open になる / ack → store 読み直し → 成功、
  空 store のままの ack → 再 escalate、headers 401 → 従来 `auth_error`。
- recovery: open authorize escalation を残して reload → parked が再構築され、ack で再実行(refuse
  しない)。
- wire: presentation 直和の service 変換(form / oauth)。
- CLI / admin は表面の分岐のみ(フロー本体はランタイム側でテスト済み)。
- 対話部分(実 IdP + 実ブラウザ)は従来どおり自動テスト対象外。
