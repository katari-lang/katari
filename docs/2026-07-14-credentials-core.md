# credentials core — OAuth を汎用機構に、mcp はその1消費者(v0.1.0 rebuild)

ゴール: MCP 結合の OAuth を **汎用 credentials core** に昇格し、任意の workflow が OAuth 保護 API を
叩けるようにする。同時に mcp を薄い consumer に落とし、mcp-reactor の横断的な `parked` 変種と
`StoredMcpOAuthProvider` を消す。owner の [[stdlib-oauth-direction]] / triage rule 2(中心抽象へ畳む)。

Scout 確認: 認証 escalation・store・flow 土台は**既にほぼ汎用**。mcp 固有は acquisition の
discovery+DCR+resource-binding だけ。token は**注入時には opaque bearer**(resource-binding は取得時の
制約)。よって mcp の oauth は「core から token 解決 → bearer header」に畳める。**唯一の実作業 = refresh
を SDK provider から core へ移す**(token endpoint を保存すれば再 discovery 不要)。

## 0. SoT と全体像

- **認証状態の SoT = project-scoped な `credentials` テーブル**(run 非依存、Admin で一括管理、run して
  なくても管理可能)。instance を owner にしない — 認証は run より長生きするので project レベルの durable
  テーブルが正しい。「ログイン済み/要ログイン」は credential の存在 + refresh 可否から**派生**。
- **profile は acquisition の直和** `mcp | configured`。取得後(store / expiry 判定 / refresh grant /
  bearer 注入 / park / escalation / Admin 管理)は **profile 非依存の共通機構**。
- **内部構造**: `configured` が基底の OAuth 2.1 code+PKCE フロー。`mcp` はその前段に discovery+DCR を足して
  client 設定 + resource を**自動導出**しただけ(owner の「mcp はサブプロトコル」の直感を構造で表現)。

## 1. credentials テーブル(mcp_credentials を汎用化)

`mcp_credentials` → **`credentials`**: `(project_id FK cascade, name) PK, value(AES-GCM sealed jsonb),
generation bigint, updated_at`。generation の単調規則(`greatest(current+1, epoch_ms)`)は不変。
`value` を **profile タグ付き**に:

```ts
type StoredCredential = {
  profile: "mcp" | "configured";
  accessToken: string;
  refreshToken: string | null;
  expiresAt: number | null;      // epoch ms — expiry 判定の SoT
  tokenEndpoint: string;         // ★refresh 用に保存(再 discovery を避ける — Scout B の crux)
  scopes: string[];
} & (
  | { profile: "mcp"; clientInformation: McpClientInfo; resourceUrl: string }  // DCR + RFC 9728
  | { profile: "configured"; clientName: string }                             // operator client 参照
);
```

repo の CAS `saveWithGeneration` / 無条件 `upsert` / `load` / `list` / `delete` は不変(既に汎用)。
module `mcp-credential/` → `credential/`。管理 route(list/forget)も汎用名に。migration で既存
`mcp_credentials` 行を `credentials` に写す(profile="mcp" を付与、token_endpoint は次回 refresh 時に
埋まる or 移行時に resource から再 discovery — 移行の実挙動は実装で決定)。

## 2. refresh 機構(lazy・on-demand・core 内)— owner の Q への答え

背景ジョブは作らない。token 解決時に core が:

```ts
// credentials core の共有サービス。mcp-transport と oauth reactor の両方が呼ぶ。
resolveToken(project, name): { token: string } | { needsAuthorize: { name, url? } }
  cred = load(project, name)
  if cred is null:                         return needsAuthorize        // 未認証 → park→login
  if now < cred.expiresAt - MARGIN:        return { token: cred.accessToken }  // 有効(先回り)
  // 期限切れ(時計基準)→ refresh
  if cred.refreshToken:
    try: fresh = refreshGrant(cred.tokenEndpoint, cred.refreshToken, clientCredsOf(cred))
         saveWithGeneration(fresh, cred.generation)   // 既存の CAS
         return { token: fresh.accessToken }
    catch refreshDead:                     return needsAuthorize        // refresh 死 → 再login
  else:                                    return needsAuthorize
```

- **expiry 認識** = 保存した `expiresAt`(MARGIN 付き proactive、既定 60s 程度)。呼び出し前に更新するので
  殆どの 401 を回避。
- **refresh grant** = plain OAuth 2.1 `refresh_token` grant を `tokenEndpoint` に対して。client 資格は
  profile 別(mcp = 動的登録 client、configured = 登録 client)だが grant 自体は共通。
- **refresh 死 → authorize escalation**(park→再login)。
- **時計有効なのに 401(失効・skew、稀)**: consumer が「拒否された」を信号 → core が強制 refresh か
  needsAuthorize。mcp は park/retry がこれを担う。workflow は 401 を catch して `oauth.token` を再呼び。

## 3. credential-park を base へ lift(mcp の parked 変種を消す)

mcp-reactor の `parked` 変種(横断 concern)を、汎用の「**credential 待ちで call を park、authorize で
re-run**」機構として **base `ExternalCallReactor`(or 共有 helper)へ lift**:

- 汎用化する部分(Scout A):park↔open-escalation-row の等価、status-guard + escalate + markCallDirty、
  `onEscalateAck`/`afterCommit`/`retryParked`/`reconstructPark` の制御、`McpDispatchCall`-in-extension を
  一般化した「re-runnable dispatch」の永続化。
- profile/reactor 固有 = **authorize escalation を raise する trigger**(`resolveToken` が needsAuthorize を
  返したとき)と **re-dispatch target**(mcp の startListing/dispatchToolCall、oauth の token 解決の再実行)。
- 結果: mcp-reactor の payload 直和が **3変種(provide|serve|transport)に減り**、parked が消える。
  per-variant object split は Scout A の通り不要(共有機構が重いので lateral move になる)ため**やらない**。

## 4. authorize escalation の汎用化

`prelude.mcp.authorize` → **`prelude.oauth.authorize`**(汎用「この credential を認可せよ」)。argument は
`{ name, url? }`(mcp は url あり、configured は url なし or issuer)。presentation sum の `oauth` 変種、
CLI(`katari answer` の oauth 駆動)、admin card は request 名 sniff を新名に更新。**契約は既に汎用**なので
名前と argument の一般化のみ。escalation-filter の分類・uniform-row 化(前 wave)とは無関係(user-facing)。

## 5. mcp を bearer-header 化(StoredMcpOAuthProvider を消す)

`mcp-transport.ts` の `oauth` auth path:
- 今: `authProvider: new StoredMcpOAuthProvider(...)`(SDK が refresh + 401→re-auth)。
- 後: **`resolveToken(project, name)` → 成功なら `Authorization: Bearer <token>` を `requestInit.headers` に
  注入(`headers` path に統一)/ needsAuthorize なら park 信号**。`StoredMcpOAuthProvider` と SDK
  authProvider 分岐を削除。descriptor auth 直和 `headers|oauth` は残る(注入の仕方が両者同じ header に収束)。
- **mcp acquisition フロー(discovery+DCR)は残す**が、flow 完了時に **token_endpoint を保存**(core の
  refresh 用)。`mcp-authorization-flow.ts` は `credential` module の acquisition(profile=mcp)として整理。

## 6. Phase 分け

- **Phase 1(refactor、この doc の主眼)**: §1–§5。credentials 汎用化 + token_endpoint 保存 + refresh を core
  へ + park を base へ lift + mcp を bearer-header 化 + escalation 名の一般化。**mcp が唯一の consumer の
  まま、ユーザー可視の挙動は不変**(OAuth escalation の見え方・login・refresh・再login は今と同じ)。出荷済み
  OAuth 機能に触れるので **e2e + review を重点**。
- **Phase 2(feature)**: 新 `oauth` reactor + stdlib `prelude.oauth`(`token(name) -> string of private with io
  from "oauth"`、`prelude.time.now` 同型)+ **`configured` profile**(operator client 登録テーブル
  `configured_oauth_clients`: project, name, issuer, authorize/token endpoint, client_id, sealed secret,
  scopes)+ Admin の proactive login(escalation 無しで (project,name) の flow 開始 = 「run 前にログイン」)。
  additive で低リスク。reactor 追加は `Check.hs` の reactor-name 2 リストに `"oauth"` を足す。

## 7. 受け入れ基準(各 Phase)

- 全 runtime + port + compiler テスト green。**e2e の mcp OAuth 経路が不変**(Phase 1: login/refresh/再login/
  park recovery が今と同じ観測挙動)。migration は fresh + 既存データで検証。
- Phase 1: mcp-reactor から `parked` 変種が消え、payload 3変種に。`StoredMcpOAuthProvider` 削除。refresh が
  core で走る(SDK provider に依存しない)。token_endpoint が保存され refresh が再 discovery 不要。
- Phase 2: `oauth.token(name)` が動的に token 解決 + 未認証 park。configured client で任意 API 認証。
  Admin proactive login。K3022 の reactor-name 整合。
- typecheck / lint clean。コメントは why-文、mcp 固有散文の一般化。
- adversarial review: refresh の CAS/並行、park 汎用化で mcp 挙動不変、bearer 注入で secret が sealed/redact
  境界を破らない、resource-binding が acquisition に閉じ注入に漏れない、escalation 名変更の全 surface 追随。
