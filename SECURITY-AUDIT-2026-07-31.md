# Katari v0.1.1 セキュリティ監査

> **状態: v0.1.2 (コミット `77ed26b6`) で対応済み。** 本書は 0.1.1 に対する監査結果であり、公開済みの
> 0.1.1 に有効な攻撃手順を含むため、リポジトリにはコミットしていない（ローカル作業ドキュメント）。
> 各項目の対応状況は末尾の「v0.1.2 での対応状況」を参照。

対象: `katari` compiler / CLI (Haskell) と runtime (TypeScript)、コミット `34fcea41 (release: 0.1.1)`
公開状況: `@katari-lang/{runtime,cli,types,port,bundle,mcp}` すべて 0.1.1 が npm 公開済み（SLSA provenance 付き）
観点: ローカル (`docker compose`) では妥当な設計が、ECS などの実運用環境に移したときに何が壊れるか

---

## 総評

**基礎の作りは良い。** SQL インジェクション、prototype pollution、tar 展開の traversal、シェル注入、エラー応答の情報漏洩、`.env` の混入 —— よくやらかす箇所はいずれも意図的に塞がれており、コメントで理由まで書かれている。CLI の API キー取り扱い（`show request` を避けて Authorization ヘッダーの漏洩を防ぐなど）は特に丁寧。

**問題は「信頼境界の想定」に集中している。** 具体的には次の 3 つが、localhost では成立していたのに ECS では成立しなくなる。

1. **ネットワークが信頼できる** という前提 — SSRF 防御が皆無で、VPC 内部と AWS メタデータサービスに到達できる
2. **プロセス内は同一信頼レベル** という前提 — FFI サイドカーにマスター API キーが渡り、`/proc` 経由で親の環境変数も読める
3. **インスタンスは 1 つだけ** という前提 — リーダー選出も分散ロックもなく、ECS のローリングデプロイだけで破れる

---

## Critical

### C-1. `[sidecar].sourceRoots` が未検証 — 第三者パッケージが開発マシンの任意ディレクトリを読み出す

`[package].src` は絶対パスと `..` を弾く検証があるのに、`[sidecar].sourceRoots` には検証が一切ない。

- `haskell/project/src/Katari/Project/Config.hs:252-265` — `validateConfig` は `package.src` / 依存名 / overrides を検証するが、`sidecar = rawConfig.sidecar` を素通しする
- `haskell/cli/src/Katari/Cli/Command/Apply.hs:204-215` — `sourceRoot = package.root </> sidecarSourceRoot config`

Haskell の `</>` は右辺が絶対パスなら**左辺を捨てる**。実測で確認済み:

```
"/home/u/.katari/packages/evil-abc" </> "/home/victim/.ssh"  ==  "/home/victim/.ssh"
"/home/u/.katari/packages/evil-abc" </> "../../../.."        ==  ".../evil-abc/../../../.."
```

受け側の `typescript/bundle/src/index.ts:98-118` (`collectSourceFiles`) はシンボリックリンクを追いながら再帰的に走査し、**ルート外への脱出チェックがない**。コンパイラの `.ktr` 走査 (`Discovery.hs:175-209`) は `realpath` + `isUnder` で正しく封じ込めているので、バンドラだけが漏れている。

**攻撃:** レジストリに公開されたパッケージ（推移的依存でも可）が

```toml
[sidecar]
sourceRoots = ["/home/dev"]
```

を宣言すると、`katari apply` が開発者のホームを走査し、見つけた `.ts`/`.js` をすべてサイドカーバンドルに取り込み、ランタイムへアップロードして**実行**する。CI ランナーならワークスペース全体が対象になる。`runKatariBundle` は `katari apply` で無条件に走る (`Apply.hs:134`)。

**修正:** `validateConfig` で `sourceRoots` の各要素に `validateSourceDir` を適用し、`collectSourceFiles` に `isUnder(root, realpath(file))` の封じ込めを追加する。

---

## High

### H-1. SSRF 防御が皆無 — ECS のメタデータサービスと VPC 内部に到達できる

`typescript/runtime/src/runtime/external/http-transport.ts:203`:

```ts
const response = await fetch(request.url, init);
```

URL の検証が**一切ない**。スキーム、ホスト、プライベート IP / リンクローカルアドレスのいずれもチェックしていない。メソッドとヘッダーはプログラムが自由に指定でき (`parseRequest:271-291`)、リダイレクトは既定で追従し、タイムアウトもレスポンスサイズ上限もない（コメントで "neither caps the body size" と明記）。`mcp-transport.ts` の接続先 URL も同様。

実コード (`FetchHttpTransport`) をモックのメタデータサーバーに向けて検証したところ、**IMDSv2 のフロー全体が通る**ことを確認した:

- `PUT /latest/api/token` + `x-aws-ec2-metadata-token-ttl-seconds` ヘッダー → 200、トークン取得
- そのトークンを付けた `GET .../iam/security-credentials/<role>` → 200、認証情報を取得

つまり EC2 起動タイプの ECS では**インスタンスプロファイルの認証情報が窃取可能**。Fargate では IMDS 自体が無いが、`169.254.170.2` のタスクメタデータと、**VPC 内部の全リソース**（RDS、内部 ALB、ElastiCache、他サービス）には到達できる。

**この問題を増幅する設計上の論点:** `url` は `prelude/http.ktr` で public な `string` 型であり、実行時に計算される。型システムは private/public という**機密性**の格子を持つが、**完全性**（この値は信頼できる入力由来か）は追跡しない。Katari は AI エージェントのオーケストレーション言語なので、LLM の出力や webhook のペイロードがそのまま `url` に流れうる。間接プロンプトインジェクション → SSRF → クラウド認証情報窃取という連鎖が現実的な脅威になる。

**修正:** 送信前に URL を検証する層を入れる（スキームを http/https に限定、名前解決後の IP がプライベート / リンクローカル / ループバックなら拒否、リダイレクト先も毎回再検証）。加えて、宛先の許可リストをプロジェクト単位で設定できると望ましい。インフラ側では、タスクロールを最小権限にし、`HttpPutResponseHopLimit=1` と IMDSv2 必須化を設定する。

### H-2. FFI サイドカーにマスター API キーが渡っている

`typescript/runtime/src/runtime/external/snapshot-transport.ts:164-173`:

```ts
return subprocessSidecar(process.execPath, [path], {
  KATARI_RUNTIME_URL: runtimeBaseUrl,
  KATARI_PROJECT_ID: projectId,
  KATARI_API_KEY: apiKey,        // ← グローバルなマスターキー
});
```

`KATARI_API_KEY` はプロジェクト単位のスコープを持たない単一キーで、`/api/v1` の全ルートを開ける (`middleware/auth.ts:43-58`)。サイドカーの中身は**利用者が書いた任意の JavaScript** なので、`process.env.KATARI_API_KEY` を読むだけで全プロジェクトに対する管理権限が手に入る（`@katari-lang/port` の `src/blob.ts:32` が実際にこの経路で読んでいる）。

`katari-packages/` には slack、discord、gmail、e2b など FFI を含む第三者パッケージが並んでいる。**パッケージを 1 つ入れることが、ランタイムのマスターキーをそのパッケージに渡すことと同義**になっている。

**修正:** サイドカーには blob ルートだけに限定した、プロジェクトスコープの短命トークンを発行する。

### H-3. サイドカーの環境変数隔離は境界として機能していない

`subprocess-runner.ts:150-158` のコメントは「サイドカーはランタイムの環境（DB / オブジェクトストアの認証情報）を継承しないので、利用者の FFI コードはそれらを読めない」と述べており、`spawn` の `env` 指定自体は正しい。

しかし親子が**同一 UID** で動くため（Dockerfile の `USER node`）、子プロセスは `/proc/<ppid>/environ` を読める。同じ構成で実測した結果:

```
own env keys: KATARI_RUNTIME_URL,KATARI_PROJECT_ID,KATARI_API_KEY
PARENT ENV READABLE: YES -> FAKE_SECRET_KEY=... | FAKE_DATABASE_URL=postgres://user:pw@rds/db
```

つまり FFI コードは `KATARI_SECRET_KEY`（保存時暗号化キー = 全シークレットの復号が可能）、`DATABASE_URL`、そして ECS ならタスクロール由来の AWS 認証情報の在処まで到達できる。C-1 と組み合わせると、第三者パッケージ 1 つでランタイム全体が陥落する。

**修正:** サイドカーを別 UID で起動する（`spawn` の `uid` オプション、または専用ユーザー）。根本的にはコンテナを分離する。少なくとも、現在のコメントが主張する保証は成立していないので記述を改める。

### H-4. 複数インスタンスでの協調機構が存在しない — ECS のローリングデプロイで破れる

`typescript/runtime/src/bin.ts:33` は起動のたびに `activateInFlightProjects` を呼び、進行中の run を持つ**全プロジェクトのアクターをそのプロセス内で起動する** (`facade.ts:419-435`)。

そして advisory lock、リース、リーダー選出、`FOR UPDATE SKIP LOCKED` のいずれも**コードベース全体に存在しない**（grep で確認）。トランザクションは分離レベル未指定 = Postgres 既定の READ COMMITTED (`db-persistence.ts:44-48`)、instances テーブルに version 列もない。`MAX_COMMIT_RETRIES` はトランザクション失敗時の再試行であって、二重駆動を検出する仕組みではない。

**ECS では既定設定でこれを踏む。** ローリングデプロイは `minimumHealthyPercent: 100` が既定なので、`desiredCount: 1` であってもデプロイ中は新旧 2 タスクが同時に動く。その間、両方が同じプロジェクトの同じ run を駆動し、FFI / HTTP の at-most-once 保証（`http-transport.ts:143-153` の `recover` が前提にしているもの）が崩れて外部副作用が二重に発生しうる。

**修正:** 起動時に Postgres の advisory lock を取る（取れなければ待機 or 縮退）か、プロジェクト単位のリースを導入する。当面はドキュメントで「単一インスタンス必須、デプロイは `minimumHealthyPercent: 0` で」と明記する。

### H-5. DB 接続が既定で暗号化されない

`typescript/runtime/src/db/client.ts:11` — `postgres(config.databaseUrl, { max: 10 })`。`ssl` 指定がなく、postgres.js の既定は `ssl: false`（`postgres@3.4.9` の `src/index.js:450` で確認）。

ローカルの compose では同一ブリッジネットワーク上の隣のコンテナなので実害はない。ECS + RDS では、保存済みシークレットの暗号文・全 run のペイロード・DB パスワード自体が VPC 内を平文で流れる。README / docs / テンプレートのいずれにも `sslmode` の記述がない。

注意すべき罠: postgres.js は URL の `?sslmode=` を尊重する (`index.js:443`) が、**`sslmode=require` は `rejectUnauthorized = false` になる**（`connection.js:283-284` で確認）。暗号化はされるが検証されず MITM 可能。安全なのは `verify-full`（+ RDS の CA バンドル）だけなので、`require` を案内すると罠になる。

### H-6. `/api/*` にボディサイズ上限がない

`typescript/runtime/src/app.ts:45-50` の 1 MiB `bodyLimit` は `/inbound/*` と `/mcp/*` にしか適用されていない。`/api/*` は無制限で、`@hono/node-server` にも既定値はない。

- `modules/file/file.routes.ts:14,26` — `new Uint8Array(await c.req.arrayBuffer())` が全体をメモリに載せる
- スナップショットのデプロイは `c.req.text()` → `JSON.parse` → zValidator が再度パースするので、ピーク時にボディの約 3 倍が常駐する (`snapshot.middleware.ts:37`, `snapshot.routes.ts:23`)

1 リクエストでプロセスが OOM で落ち、**同居する全プロジェクト**のエンジンが巻き添えになる。

### H-7. `KATARI_SECRET_KEY` はローテーション不能、紛失時は復旧不能（しかも未文書）

`typescript/runtime/src/lib/crypto.ts:17-33`。封筒の形式は `base64(iv[12] || authTag[16] || ciphertext)` で、**キー ID もバージョンバイトもアルゴリズム識別子もない**。`decryptSecret` は無条件に現在の `config.secretKey` で復号する。

結果として、鍵の交換にはオフラインでの一括再暗号化が必要だが、そのツールは存在しない（`scripts/` にも CLI にもない）。鍵を変えると全シークレットと全 OAuth 認可が GCM 検証で落ち、起動時ではなく**読み出し時に散発的な run エラーとして**現れる。ECS のタスク定義を作り直す際に `openssl rand` を再実行してしまえば、保存済みシークレットは永久に失われる。

`.env.example` とテンプレートは「保存時暗号化に使う」ことは説明しているが、「**未来永劫そのまま保持する必要がある**」とは書いていない。導入直後の今なら、封筒にバージョンバイトを足すコストはほぼゼロ。

---

## Medium

### M-1. プロジェクト横断でスナップショットが実行できる

`facade.ts:233-244` の `resolveSnapshot` は、呼び出し側が `snapshotId` を指定した場合、**そのスナップショットがそのプロジェクトのものか確認せずに**返す。続く `db-ir-source.ts:26-46` の `preload` はスナップショットを id だけで検索し（プロジェクト述語なし）、モジュールを**スナップショット側のプロジェクト**でスコープして読み込む。

```
POST /api/v1/projects/<A>/runs  {"qualifiedName":"...","snapshotId":"<Bのスナップショット>"}
```

でプロジェクト B の IR がプロジェクト A のアクター内で、A の env シークレット・A の store・A の認証情報を使って実行される。

隣接するコードはすべて正しくスコープしている（`facade.ts:83` の `loadSidecarBundle`、`snapshot.repository.ts:85` の `findSnapshot`）ので、これは設計判断ではなく漏れ。現在の単一キーモデルでは権限境界を越えないが、プロジェクト単位の認証を入れた日にテナント分離の致命傷になる。**修正は 1 行**（`preload` の select に `eq(snapshots.projectId, projectId)` を追加）。

### M-2. レート制限が存在しない

コードベース全体に rate limit / throttle が無い。`/inbound/:token` と `/mcp/:token` は無認証で到達でき、トークンの正否に関わらず**毎回 DB 往復**する (`facade.ts:220-230`)。接続プールは `max: 10` なので、無認証の攻撃者が並列にゴミトークンを投げるだけで全接続を占有でき、アクターのコミット (`Substrate.commitBatch`) まで止まる。

加えて `KATARI_API_KEY` は `z.string().min(1)` (`config/env.ts:58-60`) で、1 文字のキーでも起動する。レート制限が無い状態でインターネット向け ALB に置けば総当たりが成立しうる。

### M-3. エンジンに fuel / ステップ上限がない

`typescript/runtime/src/runtime/engine/drive.ts:23-30` の drive ループにはステップカウンタもデッドラインもマクロタスクへの譲渡もない。`MAX_BATCH_TURNS = 256` (`substrate.ts:41`) はコミットバッチあたりの**外部**ターン数を縛るだけで、1 ターン内のドレインの長さは無制限。

`forever { ... }` は文書化された第一級の言語機能なので、委譲を挟まない純計算ループを誤って書くことは容易。ファンアウト（fiber / thread / scope / 委譲の深さ）にも上限が無く (`region-reactor.ts`, `resource-pool.ts`)、`run_events` の保持期限も無い (`db/tables/execution.ts:357-376`)。いずれも 1 プログラムが全プロジェクトを巻き添えにする経路。

### M-4. tarball がハッシュ検証**前**にディスク展開される + サイズ上限なし

sha256 のピン検証自体は実装されている (`Resolve.hs:193-198`) が、順序が逆。`Fetch.hs:89-114` は取得したバイト列をまず `Tar.unpack` で展開し、検証は呼び出し側の `Resolve.hs:186-188` で**その後**に行われる。`Http.hs:34-45` の `httpLbs` にはタイムアウトもサイズ上限もない。

正しいハッシュをピンしていても、悪意あるレジストリ / リダイレクトが数百 GB に展開される gzip を返せば、ハッシュ不一致に気づく前に CI ランナーのディスクを食い潰せる。

### M-5. コンテンツアドレスのキャッシュが再検証されない

`Fetch.hs:81-87` と `Resolve.hs:375-382` は `.katari/packages/<name>-<sha>/` を**ディレクトリの存在だけ**で信頼する。`.katari/` は雛形の `.gitignore` に入っているが強制ではないので、悪意あるリポジトリが正規の sha 名で中身の異なるディレクトリをコミットしておけば、`check` / `build` / `apply` が無検証でそれを使う。

### M-6. CLI の Bearer トークンがホスト跨ぎのリダイレクトで送出される

`cli/src/Katari/Cli/Api.hs:958-969`。マネージャは既定の `newTlsManager` で `redirectCount = 10`、`http-client` はリダイレクト時に `Authorization` ヘッダーをそのまま引き継ぐ。侵害されたランタイム（または M-7 の平文経路上の MITM）が `302 Location: https://attacker/` を返せば `KATARI_API_KEY` を受け取れる。

### M-7. 平文 `http://` のランタイム URL が無警告で通る

`--url` → `KATARI_API_URL` → `[runtime].url` のどの段階にもスキーム検査がない (`Common.hs:122-129, 201-212`)。平文で流れるのは Bearer トークン、`env set --secret` の値、コンパイル済み IR、サイドカーバンドル、アップロードするファイル。依存取得側は `https://` 限定で正しく実装されている (`Snapshot.hs:213-218`, `Fetch.hs:70-71`) ので、対比として惜しい。

### M-8. capability トークンが URL パスに載る — ALB アクセスログに平文で残る

`/inbound/<token>` と `/mcp/<token>` (`app.ts:49-58`) はトークンをパスセグメントとして持つ。ランタイム自身のログには漏れないよう `request-context.ts:13-27` が専用の伏字処理をしているが、その保護はアプリ境界で終わる。ECS では ALB アクセスログ、CloudFront、WAF ログがフルパスを記録するため、全 webhook / MCP の capability トークンが（多くの場合より緩い権限の）S3 ログバケットに平文で蓄積される。

### M-9. `z.url()` が `javascript:` / `file:` を通す — コンソールへの stored XSS と、クライアントシークレット付き SSRF

`modules/oauth-client/oauth-client.schema.ts:20-21` の `authorizeEndpoint` / `tokenEndpoint`、および `credential.schema.ts:12` のログイン `url` は素の `z.url()` で、スキームを制約していない。`javascript:` / `file:` / `data:` が通る。

**経路 1 — コンソールでのコード実行。** `javascript:` な `authorizeEndpoint` は `authorization-flow.ts:354` を通って `authorizationUrl` として返され、コンソールが `popup.location.href = authorizationUrl` で遷移させる (`admin-web/src/pages/CredentialsPage.tsx:182`, `components/escalations/EscalationCard.tsx:194`)。`window.open()` で開いた about:blank のポップアップはオープナーと同一オリジンなので、そこで実行される JS は `localStorage` の Bearer トークンを読める。

**経路 2 — シークレットを載せた SSRF。** `exchangeConfiguredCode` (`authorization-flow.ts:409`) は `entry.tokenEndpoint` を **Basic 認証ヘッダーにクライアントシークレットを載せて** fetch する。任意ホスト（`169.254.169.254` を含む）を指定できる。

登録には Bearer トークンが必要なので単独では権限昇格にならないが、(a) キーを共有する複数人運用では別の運用者が踏む、(b) 永続的なバックドアとして機能する、(c) H-1 の SSRF と同じ宛先に**シークレット付きで**到達できる、という点で無視できない。`{protocol: /^https?$/}` で制約すべき。

### M-10. capability トークンに TTL / 失効 API / 署名検証・リプレイ防御がない

トークン自体の品質は高い（`randomBytes(24)` = 192 bit、`webhook-reactor.ts:196`, `mcp-reactor.ts:593`。コードベース全体に `Math.random` は 0 件）。問題はライフサイクル。

- `db/tables/execution.ts:176` はトークンを**平文の主キー**として保存する。読み取り専用の DB 侵害やバックアップ流出で、全 webhook / MCP の生きた URL が手に入る。各 URL は追加の認証情報なしでプログラムを起動できる。
- TTL もローテーションも無く、稼働中エンドポイントを一覧・失効させる API も無い。失効は所有インスタンスの消滅による FK カスケードのみ (`webhook-reactor.ts:301-304`)。URL 漏洩を疑った運用者には、run のキャンセル以外に打つ手が無い。
- `webhook.routes.ts:20-50` には**署名検証・リプレイ防御・nonce・タイムスタンプ検査・トークン単位のクォータのいずれも無い**。URL を持つ者は同じ配信を無制限に再送でき、そのたびに実エンジン処理が走る。コールバックが LLM や従量課金 API を叩くなら直接的なコスト増幅になる。

「URL を知る者が起動できる」こと自体は capability URL モデルとして正しい。欠けているのはトークン単位のクォータと失効手段。

### M-11. esbuild の解決範囲に制限がない — ビルドマシンの任意ファイル読み出し

`typescript/bundle/src/index.ts:136-163` は `bundle: true` で、解決パスを制限する `onResolve` プラグインが無い（`portSingletonPlugin` と `moduleNamePlugin` はどちらも制限しない）。esbuild は絶対パスの import をそのまま解決し、既定ローダーは `.json` / `.txt` を含む。

悪意ある依存のサイドカーソースが `import creds from "/home/dev/.aws/credentials.json"` と書けば、その内容がビルド時にバンドルへインライン化され、同じバンドル内の攻撃者のハンドラが起動時に外部送信できる。

明確にしておくと、**ビルド時の任意コード実行は無い** — build script / postinstall フック / JS を読む設定 / パッケージからのプラグイン読み込みのいずれも存在せず、esbuild はバンドル対象を実行しない。あくまで任意**読み出し**が、デプロイされる成果物経由で現金化される。

---

## Low / hardening

- **CSP が無い。** Hono の `secureHeaders()` は既定で CSP を設定しない（`DEFAULT_OPTIONS` に無いことを確認）。HSTS・nosniff・X-Frame-Options・`Referrer-Policy: no-referrer`（OAuth の `code`/`state` が Referer で漏れるのを防ぐ、有用）は既定で入る。管理コンソールは Bearer トークンを `localStorage` に置く (`admin-web/src/api/client.ts:34`) ので、注入があればトークンが盗まれる。**実際に注入経路は 1 つ存在する（M-9）**ため、CSP の欠如は多層防御の欠落として実害に直結する。`admin-web/index.html:9-14` が `fonts.googleapis.com` を読んでおり CSP の例外になるので、フォントは自ホストして `default-src 'self'` を素直に入れられるようにするのが良い。
- **ファイルダウンロードがアップロード時の `Content-Type` をそのまま反射する** (`file.routes.ts:15,50-55`)。`Content-Disposition: attachment` が無い。ただしこの経路は現状悪用できない — ファイル取得は `/api` 配下でヘッダー認証なのでブラウザの直接遷移は 401 になり、コンソール側も `<a download>` で強制保存する (`FilesPage.tsx:50-55`, `ValueViewer.tsx:260-265`)。将来コンソールがインライン表示を始めた瞬間に stored XSS になるので、先に `Content-Disposition: attachment` と型の許可リストを入れておくべき。
- **公開 OAuth コールバックページが内部エラー文言を反射する** (`authorization-flow.ts:463-468, 546`)。到達には有効な `state` が必要で、`oauth.routes.ts:21-28` の `escapeHtml` は危険文字 5 種を正しく処理している（**XSS は無い**）が、トークンエンドポイントの失敗理由や DB エラーが信頼境界の外のブラウザに出る。
- **`limit` 省略時のページングが無制限** (`lib/paging.ts:34-41,60-72`)。上限値自体は 500 / 1000 で妥当だが、省略すると全件返す。CLI の都合による意図的な設計。
- **リクエストタイムアウトが無い** (`bin.ts:25`)。
- **サイドカーの一時ファイル**が `/tmp/katari-sidecar-<snapshot>.mjs` という予測可能なパスに `O_EXCL` 無しで書かれる (`snapshot-transport.ts:166-167`)。ECS で `readonlyRootFilesystem: true` を使うなら `/tmp` に tmpfs ボリュームが必要（他にディスク書き込みは無いので、それだけで有効化できる）。
- **`qualifiedName` でプロトタイプチェーンを踏む** (`runtime/ir.ts:62,76`)。`entries["constructor"]` が `Object` に解決され private エージェントのゲートを素通りするが、直後に別のエラーで死ぬので実害は無い。`Object.hasOwn` を挟めば閉じる。
- **`/api/v1/health` が無認証でバージョンを返す** (`health.routes.ts:19`)。
- **`xdg-open` にサーバー由来 URL を渡している** (`cli/.../Answer.hs:150-155`)。argv 渡しなのでシェル注入は無いが、スキーム検証が無いので侵害されたランタイムが `file://` 等のハンドラを起動させられる。
- **ランタイム由来の文字列を端末にそのまま出力** (`cli/.../Output.hs`)。ANSI/OSC エスケープが素通しになる。
- **`ovsx` が `npx --yes` で未固定取得**され、publish トークンを渡される (`release.yml:432`)。他はすべてロックファイル管理下なのでここだけ浮いている。
- **GitHub Actions がすべて可変メジャータグ**。特に `softprops/action-gh-release@v2` は `contents: write` を持つ唯一のジョブで動く。
- **ベースイメージがタグ指定**（`node:22-slim`、digest 未固定）。
- **雛形の compose が `chrislusf/seaweedfs:latest`** を使う。
- **マイグレーションが起動時に無条件実行**され (`bin.ts:16`)、drizzle の migrator は advisory lock を取らない（`pg-core/dialect.js:44-70` で確認）。H-4 と同じ理由で同時起動時に競合する。
- **`KATARI_PUBLIC_URL` の既定が `http://localhost:3000`** (`config/index.ts:38`)。ALB 配下で未設定だと `webhook.inbound` が外部から到達不能な URL を発行する。本番では未設定なら起動拒否が親切。
- **雛形 compose の `AWS_ACCESS_KEY_ID`/`SECRET` がハードコード**（ローカルモック用）。ECS に持ち込むとタスクロールを上書きして 403 になる。「AWS ではこの 2 行を消す」旨のコメントが欲しい。
- **`@katari-lang/language` が publish ループに入っていない** (`release.yml:268`)。
- **`cli-linux-arm64` / `cli-darwin-x64` が未公開。** Graviton / arm64 Linux と Intel Mac で CLI が入らない。
- **runtime パッケージの README が古い** — 存在しない `/api/v1/users` のダミー API を記載したまま npm に公開されている。

---

## 良好だった箇所（確認済み）

作り込みが効いている部分は明記しておく。

- **Bearer 認証の実装:** 正しい。`tokensMatch` (`middleware/auth.ts:30-40`) は本物の定数時間比較で、長さ不一致時にも `timingSafeEqual(keyBytes, keyBytes)` を空打ちして**長さ自体がオラクルにならない**ようにしている。ここまでやっている実装は少ない。
- **認証パスの正規化バイパス:** 存在しない。`isPublicPath` の文字列前置判定と Hono のルーターマッチが食い違えば完全な認証バイパスになるが、両者とも同じ `getPath` 結果に由来する。`app.ts` の結線を再現して 15 種のエンコーディング / 正規化プローブ（`/%61pi/...`、`/./api/...`、`/api/../api/...`、`//api/...`、`/API/...`、`/api%2Fv1%2F...` 等）を実測したところ、**認証を免除されるパスはいずれも API ハンドラに到達しない**ことが確認された。`decodeURI` は `%2F` を復号しないため、エンコード traversal はリテラルのファイル名に退化する。
- **OAuth フロー:** 4 つの論点すべて問題なし。`state` は `randomUUID()` (CSPRNG) で、検証後に交換前に削除される単回使用 (`authorization-flow.ts:527`)。PKCE S256 を両プロファイルで使用 (`randomBytes(32)` + SHA-256、:352-360)。`redirect_uri` は**呼び出し側から受け取らず**サーバーが `${publicUrl}/oauth/callback` として生成する (:293) ので open redirect も code interception も無い。レジストリ由来の追加パラメータは `has()` ガード付きで追記されるため (:370-372)、`redirect_uri` / `state` / PKCE を上書きできない —— このガードは効いている。取得したトークンは AES-256-GCM で封印して保存 (`oauth.service.ts:50`)。
- **シークレットの読み戻し:** 経路無し。`credential` にはそもそも読み出しエンドポイントが無く、`env.get` は secret ならメタデータのみ、`oauth-client` はメタデータのみ、`store` は `valueToJson(value, "redact")`。`src/modules/` と `facade.ts` の `valueToJson(` 呼び出し 11 箇所は**すべて `"redact"`**。`"reveal"` は transport 向け（許可されたシンク）のみ。
- **capability トークンの品質:** `randomBytes(24)` = 192 bit の URL-safe 文字列。コードベース全体で `Math.random` の使用が **0 件**、乱数はすべて `node:crypto`。列挙は非現実的。
- **MCP セッションのスコープ:** `mcp-serve.ts` は `initialize`/`ping`/`tools/list`/`tools/call` のみを実装し、`resources/*` も `prompts/*` も任意エージェント起動も無い。`mcp-reactor.ts:452` は `Object.hasOwn` を使うので `toString` 等の継承キーをツールとして起動できない。トークン 1 つが開けるのは 1 プロジェクト内の 1 回の `mcp.serve` が渡したツール集合だけ。
- **ログ:** `Authorization` ヘッダー・シークレット値・認証情報のいずれも出力されない。`request-context.ts:13-27` は capability トークンをパスから積極的に伏字化し (`/mcp/<redacted>`)、クエリ文字列も記録しないので OAuth の `code`/`state` もログに残らない。
- **静的配信の traversal:** 無し。`admin-web.ts:31-33` が先に `isApiPath` で分岐し、`serveStatic` は `decodeURI` 後の `.`/`..`/`//` セグメントを拒否する。
- **SQL インジェクション:** 無し。`sql.raw` / 文字列連結 / 動的 ORDER BY のいずれも存在せず、`escapeLike` が全 `ilike` 呼び出しに適用されている。ソート方向は zod enum → Drizzle ヘルパーのホワイトリスト。
- **prototype pollution:** 徹底的に防御済み。JSON→オブジェクトの復号経路がすべて `Object.create(null)` を使い、`record.set/merge` は `Object.assign(Object.create(null), …)` + `Object.hasOwn`。`snapshot.middleware.ts:21-52` は**生のリクエスト文字列**に対して `__proto__` 等を検査している（パース後では消えているため）—— 相当細かい所まで見ている。
- **tar 展開:** `tar-0.5.1.1` の `checkEntrySecurity` が絶対パス・`..`・**ハードリンク/シンボリックリンクのターゲット**まで拒否し、リンクはコピーで模倣される。zip-slip は成立しない。
- **`.ktr` 探索:** `Discovery.hs:175-209` が canonicalize + visited セット + `isUnder` で封じ込め済み。
- **シェル注入:** 皆無。`shell` / `system` / `callCommand` / `rawSystem` の使用が 0 件。3 箇所の spawn はすべて argv リスト。
- **パス/URL セグメントになる値の検証:** パッケージ名 `[A-Za-z_][A-Za-z0-9_]*`、スナップショット名 `[A-Za-z0-9._-]`、sha256 は 64 桁 hex 固定。
- **CLI のシークレット取り扱い:** `KATARI_API_KEY` は環境変数からのみ読み、ディスクにも成果物にもログにも出ない。`formatHttpException` が `show request` を避けているのは特に良い。`env get` はシークレットの表示を拒否する。
- **TLS 検証の無効化:** 無し。全マネージャが `newTlsManager`。
- **エラー応答:** スタックトレース / SQL 断片 / パス / 環境値のいずれも漏れない (`error-handler.ts:107-115`)。OAuth コールバックの HTML は両方の補間箇所を `escapeHtml` している。
- **store のプロジェクト分離:** 4 つの行操作すべてに project 述語があり、プレフィックス列挙は `escapeLike` + `/` 境界。プログラム側の `projectId` はアクターが渡すのでプログラムからは詐称不能。
- **Docker イメージ:** マルチステージ、`USER node`、`--ignore-scripts`、`NODE_ENV=production`、healthcheck あり、シークレットの焼き込み無し。
- **S3 クライアント:** 静的認証情報を渡さず既定のプロバイダチェーンを使うので、ECS のタスクロールがそのまま効く。
- **CI / リリース:** `pull_request_target` を使っておらず、fork PR には secrets が渡らない。npm は OIDC Trusted Publishing で `NPM_TOKEN` が存在しない。**公開済み 6 パッケージすべてに SLSA provenance が付いていることを確認済み**（`predicateType: https://slsa.dev/provenance/v1`）。
- **`typescript/cli/bin/katari.mjs`:** プラットフォームキーはハードコードされた集合で検証され、解決失敗時に **PATH フォールバックへ落ちない**（このシムでよくある致命的な footgun が無い）。
- **依存の健全性:** `pnpm audit --prod` は moderate 1 件のみ（`@hono/node-server` の Windows 限定 path traversal で、直接依存は既にパッチ済み）。`pnpm-workspace.yaml` に理由付きの `overrides` がある。
- **`.env`:** 両リポジトリで gitignore 済み、履歴にも混入なし。
- **雛形テンプレート:** 弱いデフォルト鍵は無く、両キーとも `:?` で必須化され `openssl rand` の生成手順が書かれている。プロジェクト名は補間前に検証される。
- **コンパイラの堅牢性:** `compiler/src` に `error`/`undefined`/`fromJust`/`!!` が無く、`head` は `NonEmpty.head` のみ。推論のフィックスポイントは fuel 制限付き、型シノニム循環と依存循環の双方を検出。

---

## 推奨する対応順序

**ECS に載せる前に必ず:**

1. C-1 — `sourceRoots` の検証とバンドラの封じ込め（第三者パッケージを 1 つ入れるだけで成立する）
2. H-1 — SSRF フィルタ。並行して、タスクロールの最小権限化と IMDSv2 の hop limit 1 を設定
3. H-4 — 単一インスタンス制約の明文化（できれば advisory lock）。少なくともデプロイ設定を `minimumHealthyPercent: 0` にする
4. H-5 — `DATABASE_URL` に `sslmode=verify-full`（`require` ではない）
5. H-7 — 「`KATARI_SECRET_KEY` は永久に保持せよ」の一文を追記し、封筒にバージョンバイトを追加（今なら移行コスト 0）
6. ECS のシークレットは `environment:` ではなく `secrets:` + `valueFrom` を使うようドキュメント化

**近いうちに:**

7. H-2 / H-3 — サイドカーの権限を絞る（スコープ付き短命トークン + 別 UID）
8. M-9 — `authorizeEndpoint` / `tokenEndpoint` / ログイン `url` を `{protocol: /^https?$/}` に制約し、あわせて CSP を入れる（この 2 つはセットで意味を持つ）
9. H-6 / M-2 — `/api/*` のボディ上限、無認証ルートのレート制限、`KATARI_API_KEY` の下限長（`min(32)`）
10. M-1 — スナップショット解決のプロジェクトスコープ（1 行）
11. M-4 / M-5 / M-6 / M-7 — 検証順序の是正、キャッシュ検証、`redirectCount = 0`、平文 URL の警告
12. M-3 — エンジンの fuel 上限とファンアウト上限
13. M-10 — capability トークンのクォータと失効 API
14. M-11 — esbuild の `onResolve` 許可リスト

**公開プロジェクトとしての整備:**

15. `SECURITY.md` が無く、脆弱性報告の窓口が存在しない。docs/ は 49 本の設計文書があるが、運用・セキュリティの文書は 0 本。公開したばかりの今、報告先を明示しておく価値は高い。

---

## v0.1.2 での対応状況

コミット `77ed26b6`（タグ `v0.1.2`）。

### 根治した

| # | 対応 |
|---|---|
| C-1 | `validateConfig` が `sourceRoots` の全要素を検証。バンドラ側も `realpath` + `isUnder` で封じ込め（コンパイラの `.ktr` 走査と同じ規律に揃えた） |
| H-1 | `egress-guard.ts` を新設。接続直前のアドレスを検査するので DNS リバインディングとリダイレクト各ホップも対象。IP リテラル宛は `lookup` を通らないため別途前段でも検査。加えてタイムアウトとレスポンス上限を追加 |
| H-2 | サイドカーにはプロジェクトと blob 2 経路に限定した短命トークンを発行（`sidecar-tokens.ts`）。マスターキーは渡さない |
| H-4 | Postgres advisory lock で単一インスタンスを強制。マイグレーションの競合も同時に解決 |
| H-5 | 非ループバックのホストなら既定で `verify-full`（`require` は検証しないので既定にしない） |
| H-6 | `/api` に上限、アップロードは別枠。無認証経路は従来どおり 1 MiB |
| H-7 | 封筒にバージョンバイト。復号は設定済み全鍵を試すので `KATARI_SECRET_KEY_PREVIOUS` でローテーション可能。旧形式も読める |
| M-1 | `resolveSnapshot` がプロジェクト所有を確認 |
| M-2 | 固定窓のレート制限（無認証経路 + 認証失敗）と API キーの下限長 32 |
| M-4 | ハッシュ検証を展開前に移動。転送にサイズ上限とヘッダタイムアウト |
| M-5 | 抽出時に sentinel を書き、無い/不一致ならキャッシュミス扱い |
| M-6 | `redirectCount = 0` |
| M-7 | 非ループバックの `http://` に警告 |
| M-9 | `authorizeEndpoint` / `tokenEndpoint` / ログイン `url` を http(s) に限定。あわせて CSP を追加（コンソールのインライン script は外部ファイル化して `unsafe-inline` を回避） |
| M-11 | esbuild に `onResolve` 許可リスト。pnpm のシンボリックリンク配置を壊さない規則を採用し、実パッケージでバイト単位同一を確認 |
| Low | `Content-Disposition: attachment`、`Object.hasOwn`、サイドカー一時ファイルは `wx` + 0600、ベースイメージを digest 固定、`KATARI_PUBLIC_URL` を本番必須、`xdg-open` のスキーム制約 |

### 緩和にとどめた（設計上の制約）

- **H-3（同一 UID の `/proc` 読み取り）** — サイドカーは依然として親と同じ UID で動くため、`/proc/<ppid>/environ` は読める。`KATARI_API_KEY_FILE` などの `*_FILE` 系を追加し、シークレットをプロセス環境に置かない経路を用意した。別 UID / 別コンテナ化が本来の解で、未実装。`SECURITY.md` の Known limitations に明記。
- **M-8（capability トークンが URL パスに載る）** — capability URL モデルの根幹なので変更せず。ロードバランサのアクセスログに残る点を `SECURITY.md` と `docs/deploying.md` に明記。
- **M-3（エンジンの fuel 上限）** — 未対応。`forever` の純計算ループでプロセスを占有できる問題は残る。エンジン中枢の変更になるため、単独で設計・検証したい。
- **M-10（capability トークンの TTL / 失効 API）** — 未対応。トークン自体は 192bit で推測不能、失効は所有インスタンス消滅時のカスケードのみ。

### 残タスク

1. M-3（fuel 上限）と M-10（トークンのクォータ・失効）
2. フォントの自ホスト化（CSP から `fonts.googleapis.com` / `fonts.gstatic.com` の例外を消せる）
3. `ovsx` の固定と GitHub Actions の SHA 固定
4. `@katari-lang/language` を publish ループに追加、`cli-linux-arm64`（Graviton / arm64 Linux）の追加
5. runtime パッケージの README が古い（存在しない `/api/v1/users` を記載）
