# Katari v0.2 ロードマップ

## 前提

- v0.2 は v0.1 から構造を大きく変えるため、Compiler も Runtime も含めてゼロから作り直す。
- Katari Protocol（仕様は `spec/katari-protocol.md`、設計の過程は `records/2026-10-23-katari-protocol-design-record.md`）を中心に据え、Runtime を含むすべてのエンドポイントは、プロトコルのライブラリを使って実装する。
- 実装の言語は **TypeScript に統一**する（Protocol ライブラリ、IR、Compiler、Runtime）。Haskell は、型付け規則・IR の検証規則・ライフサイクルの層の**参照実装（実行可能な仕様）**に用い、TS の実装との差分テストで正しさを確かめる。
- 主要な用途の一つは、**AI が実行中に Katari のコードを書き、それをその場でコンパイルして安全に動かすこと**である。そのため、コンパイルは実行中に何度も呼ばれる処理として扱う。
- もう一つの用途は、**Runtime 同士で component を渡し合うこと**である。これは MCP では表せない（権限を第三者に渡すこと、サーバーをまたいだ構造化された寿命）ので、Katari Protocol の capability 層とライフサイクル層が担う。
- **外部のサービスとの境界は、できるだけ MCP に寄せる。** AI の呼び出しや外部のツールは MCP の tool、長い処理は MCP の tasks として扱い、Katari 専用のプロキシは必要な場合だけ書く。Katari Protocol は、Katari のエンドポイント同士の間で使う。
- **MCP events（Triggers and Events WG）の状況を定期的に確認する。** サーバーからイベントを押し出す仕組み（購読のライフサイクル、webhook、順序の保証）が MCP で確定したら、外部からのイベントの受け取りを MCP events に寄せる。そのうえで、Katari Protocol の 1 層・2 層（認証と配送）を MCP の輸送路に載せ替えられるかを検討する（3 層・4 層は輸送路から独立に作ってある）。

## 全体の流れ

| # | フェーズ | 主な成果物 | 完了の条件 |
|---|---|---|---|
| 1 | Protocol の下書きを固める | 仕様の下書き | 仕様の未決事項のうち、ライブラリの実装に必要なものが決まっている |
| 2 | Protocol ライブラリ | TS のライブラリ、シミュレータ、ライフサイクルのモデル検査 | シミュレータ上で、再起動・重複・欠落があっても L1〜L5 の性質が保たれる |
| 3 | 端から端までの最小構成 | 最小の Runtime、Timer サーバー | 実際のネットワーク越しに component の init・revise・dispose が動く |
| 4 | Protocol の凍結 | Protocol v0.2 | 2〜3 で見つかった問題を仕様に反映し終えている |
| 5 | Ecosystem の決定 | Ecosystem の設計文書 | 下の「決めること」がすべて決まっている |
| 6 | IR の仕様 | IR の仕様書、`ir` パッケージ | Runtime と Compiler が、IR だけを介して独立に作れる状態になっている |
| 7 | Runtime | Katari Runtime | Ecosystem の設計どおりに、コードのデプロイから実行まで動く |
| 8 | Compiler | Katari Compiler（Katari のリソースとして提供） | ソースから IR を出力し、Runtime の中で動く。AI からの呼び出しに耐える |
| 9 | その他のエコシステム | 標準ライブラリ、パッケージマネージャ、LSP、標準の Katari Server、Docker イメージ | 利用者が手元で開発し、デプロイできる |
| 10 | 例 | サンプル集 | 主要な使い方（Timer、チャット連携、AI 連携、AI によるコード生成など）を一通り示している |
| 11 | ホームページ・ドキュメント | 公開用のサイトとドキュメント | 仕様・チュートリアル・API リファレンスがそろっている |
| 12 | 公開 | v0.2 のリリース | — |

Runtime（7）と Compiler（8）は、IR の仕様（6）が決まれば並行して進められる。

## パッケージ構成

Protocol の層構成に合わせ、層ごとに独立したパッケージにする。依存は上から下への一方向で、各層は下の層だけを使う。

```
packages/
  envelope    1. 認証層：DID とその解決（最初は did:key）、JWT のエンベロープ、署名と検証、HTTP binding
  rpc         2. RPC 層：JSON-RPC、冪等性、outbox と再送、エラーオブジェクト
  capability  3. capability 層：URI、grant と Ref、derive・revoke、値と型の形式、種別の枠
  kinds          標準の種別：sink、blob（capability だけを使う）
  lifecycle   4. ライフサイクル層：component 種別、activation、revision、panic、寿命の規則
  ir          5. IR の型定義、検証器、シリアライズ（Compiler と Runtime で共有）
  compiler    5. ソース → 型付き IR。Katari のリソースとしても提供する
  runtime     5. IR の検証と実行。lifecycle のフックとして動く
reference/    Haskell による参照実装（型付け規則、IR の検証、ライフサイクルのモデル）
```

- Katari 以外のサーバーは、必要な層までを使う（自分のリソースを提供するだけなら `capability` と、提供する種別のパッケージまで、他人の Ref を受け取って持ち続けるサーバー（イベントを届けるプロキシ、Timer など）は component を提供するので `lifecycle` まで）。
- 各層は永続ストアを直接持たず、下の層から渡されるトランザクションの単位（Unit of Work）を通じて自分の表を読み書きする。一つの処理で複数の層の表を同じトランザクションで確定させる必要があるためである。この抽象はフェーズ 2 の最初に決める。
- `ir` を Compiler と Runtime で共有することで、Compiler が出力する IR と Runtime が受け付ける IR の食い違いを防ぐ。

## 各フェーズの詳細

### 1. Protocol の下書きを固める

- 残っている未決事項のうち、ライブラリの実装に影響するものを決める（再送の上限の既定値、`seen_rpc` の保持期間など）。
- 後から拡張できるように、次の二点を仕様の構成に反映しておく。
  - エンベロープの規則と HTTP binding を分けて書く（WebSocket などの binding を後から足せるように）。
  - ストリーミングは、sink とは別の種別（`stream`）として後から追加する。sink は単発のイベントのための種別のままにする。
- この時点では凍結しない。実装で見つかった問題を戻す余地を残す。

### 2. Protocol ライブラリ

ライブラリ利用者が書くのは、次のものだけにする。

- activation のフック（`onInit`、`onRevise`、`onDispose`）と、反映の完了の通知（`commitRevision`、`commitDispose`）。いつ・どの順で反映し、どんな解放処理を挟むかは利用者が決める
- 子の activation の起動と、子への revise・dispose
- エラーの扱い（失敗の報告、`onFault`・`onStuck` を受けたときの振る舞いなど）

それ以外（署名と検証、outbox と再送、冪等性、grant 表、derive、寿命の規則の条件の検査（L3 の条件 I3 など）と最後の後片付け（残った子孫の dispose、sub-grant の revoke））は、ライブラリがすべて受け持つ。

実装は層の順（`envelope` → `rpc` → `capability` → `lifecycle`）に進め、各層を単独でテストできるようにする。

ライブラリは、次の部分を差し替え可能にする。

| 差し替え可能な部分 | 例 |
|---|---|
| DID の方式（解決器） | did:key（最初の実装）、did:web、did:webvh など。**did:key を前提にしない**：DID は不透明な文字列として扱い、鍵は常に解決器から得る |
| 永続ストア | SQLite、Postgres、D1、Durable Objects、DynamoDB、メモリ（テスト用） |
| 輸送路 | HTTP のクライアントとサーバー（将来は WebSocket） |
| 鍵の保管 | ファイル、OS のキーチェーン、KMS |
| 時計とスケジューラ | 実時間、サーバーレスのスケジューラ（Durable Objects の alarm、Cron Triggers、EventBridge など）、シミュレータ用の仮想時計 |

あわせて、次の二つを作る。

- **シミュレータ**：ネットワークの遅延・重複・欠落・順序の入れ替わりと、エンドポイントの再起動を任意に起こせる環境。ライブラリ自身のテストに使い、利用者が自分の component をテストするのにも使えるようにする。
- **ライフサイクルの層の形式的な検証**：TLA+ や Quint によるモデル検査、または Haskell の参照実装に対するプロパティベーステストで、「通常の経路では解放済みのリソースに触れない」「完了通知の待ちが有限で終わる」を確かめる。修論の形式化と素材を共有できる。

### 3. 端から端までの最小構成

- ライブラリを使って、最小の Runtime（決め打ちの component を一つ動かせる程度）と Timer サーバーを作る。
- 実際のネットワーク越しに、init・revise・dispose、再起動からの復旧、grant の derive と失効が動くことを確かめる。
- ここで見つかった問題を Protocol に戻す。

### 4. Protocol の凍結

- 2〜3 の結果を反映し、Protocol v0.2 として凍結する。
- 以後の変更は、拡張（新しい種別、新しい binding）として行う。

### 5. Ecosystem の決定

決めること：

| 項目 | 内容 |
|---|---|
| コードのデプロイ | Katari Runtime にコードを上げる方法（ソースを上げて Runtime の中の Compiler でコンパイルする、IR を CID で指定する、パッケージ） |
| AI によるコード生成 | AI に compiler の Ref と使ってよいリソースを渡し、書かせたコードを動かすまでの流れ（下の「Compiler の置き方」） |
| ダッシュボード | 実行中の activation の木、grant、ログ、エラー、コンパイルの結果の見え方 |
| 秘密情報 | Discord の Bot トークンなどの保管場所と、Katari の権限（grant）との関係。秘密情報そのものは Katari の値として流さない |
| メディアの保存 | 画像・動画などの大きなデータの置き場所（`blob` の実体、CID による参照、外部ストレージとの連携） |
| OAuth | 外部サービスへの接続の認可の流れと、得たトークンの保管 |
| MCP の接続 | MCP サーバーを Katari のリソースとして取り込むプロキシの導入方法 |
| ブートストラップ | root grant の配り方（設定ファイル、招待トークン） |
| 実行環境 | サーバーレス（Cloudflare Workers、AWS Lambda など）と常駐サーバーのそれぞれでの構成 |

### 6. IR の仕様

- Runtime と Compiler は IR だけを介してつながるので、両方に先立って決める。
- **IR は明示的に型が付いた形にする**（総称型を保持し、型引数も明示する）。Runtime は受け取った IR を自分で型検査する（WebAssembly の検証や JVM のバイトコード検証と同じ考え方）。これにより、Runtime は Compiler の出力を信用せずに、受け取ったコードの型安全性を確かめられる。明示的に型の付いた IR の検査は単純なので、TS で小さく実装できる。
- IR の内容は CID で識別し、activation が使うコードのバージョンを固定できるようにする。検証の結果も CID でキャッシュする。
- 型付け規則と検証規則は、Haskell の参照実装でも書き、TS の実装との差分テストに用いる。

### 7. Runtime

- Protocol ライブラリの上に、IR の検証器とインタプリタを載せる。
- Compiler を Runtime の中で提供する（下の「Compiler の置き方」）。
- Ecosystem の設計に沿って、デプロイ、ダッシュボード、秘密情報、メディア、OAuth、MCP の各機能を実装する。
- activation ごとに CPU 時間・メモリの上限を課す。AI が書いたコードを動かすうえで必須である。
- サーバーレスでも動くことを目標にする。

### 8. Compiler

- TS でゼロから書く。ソースの型検査を行い、明示的に型の付いた IR を出力する。
- 型引数を明示する方針なので、双方向型検査を中心にし、型推論の手間を小さく保つ。IFC や coeffect の制約解消は単純に保ち、一般的な制約ソルバーには頼らない。
- モジュールと IR を CID でキャッシュし、同じコードを二度検査しない。
- 型エラーなどの診断は、人間向けの文章に加えて、位置・期待した型・実際の型などを構造化した形で返す。AI が読んで修正しやすくするためである。
- Haskell の参照実装との差分テストで、型付け規則の実装の誤りを見つける。

### 9. その他のエコシステム

- 標準ライブラリ
- パッケージマネージャ
- LSP（Compiler を TS で書くので、そのまま利用できる）
- 標準の Katari Server（Timer、チャット連携、AI 連携、MCP プロキシなど）
- Docker イメージ

### 10〜12. 例、ドキュメント、公開

- 主要な使い方を示す例を用意する。AI によるコード生成の例を含める。
- ホームページとドキュメント（仕様、チュートリアル、API リファレンス）を更新する。
- v0.2 として公開する。

## Compiler の置き方

### Compiler は Katari のリソースとして提供する

Compiler を Katari の component として提供する。結果を返す処理は component として起動し、結果は sink で受け取る。また、Ref は activation の引数でしか流れないので、`compile` は component の Ref を返さず、IR をプールに置いて CID を返す。

```
compile : 引数 { source, result: Sink }。result に次のどちらかを emit する
          { cid }                 成功した場合。IR はプール（または Runtime の中の IR の置き場）に置かれる
          { diagnostics: [...] }  型エラーなどの場合
run : CID を引数に取って、その IR を起動する component
```

これにより、「Katari のコードを作って動かす権限」が grant として扱えるようになる。AI によるコード生成は次の流れになる。

1. AI エージェントの activation に、compiler の Ref、`run` の component の Ref、使ってよいリソースの Ref を引数として渡す。
2. AI はソースを書いて `compile` を起動する。型エラーがあれば `diagnostics` を見て直す。
3. 成功したら、得た CID と、自分が持っている Ref だけを引数にして、`run` を `init` する。

AI が書いたコードは、AI が渡した Ref 以外には触れない（object-capability の性質と、暗黙の権限の排除による）。Runtime は IR を自分で検証し、CPU とメモリの上限も課すので、AI が何を書いても、渡した権限の範囲を超えて被害が広がらない。

compiler が提供する op や component の詳しい中身は、後で決める。

### 既定は Runtime の中に置く

| | Runtime の中に置く（既定） | Katari Server として外に置く |
|---|---|---|
| 呼び出しの速さ | 自己発行の Ref の短絡により、関数呼び出しと同じ | ネットワークと署名の分だけ遅い |
| IR のバージョン | 同じ `ir` パッケージを使うので、ずれない | Compiler と Runtime のバージョンがずれうる |
| 運用 | デプロイするものが一つ | Compiler も別に動かす必要がある |
| 負荷の分離 | コンパイルが他の activation の CPU を奪いうる | 独立に分けられ、別々に増やせる |
| サーバーレス | 関数のサイズとコールドスタートが少し増える | Runtime の関数を軽くできる |

呼ぶ側から見ると、どちらも「`compile` の component を起動する」だけなので、置き場所は後から変えられる。まず Runtime の中に置き、次のような状況になったら外に出す。

- コンパイルの負荷が、他の activation の処理を遅らせるようになった
- サーバーレスで、関数のサイズやコールドスタートが問題になった
- 複数の Runtime でコンパイル結果を共有したくなった

### Runtime の中に置く場合も、隔離する

AI が書くソースは信用できない入力である。悪意がなくても、型検査に極端に時間がかかるコードや、パーサーを深く再帰させるコードが来ることはありうる。そのため、

- コンパイルは別のスレッドや隔離された実行環境（Node の worker threads など）で行う
- 時間・メモリ・入力の大きさに上限を設け、超えた場合は `diagnostics` として返す

ようにする。こうしておけば、後で外に出すときも、隔離の単位がプロセスの境界に変わるだけで済む。

### compiler の API（設計判断は保留）

言語の上では、次のような形を想定している。

```
use env = compiler.env([...使ってよい component...])
use mod = env.compile("...")
env.mount(mod, [...args...])
```

compiler を Runtime に内蔵する場合は、`env` と `mod` を Runtime 側のリソースとし、`mod` の寿命を `env` に連動させれば（`env` が終われば `mod` も連鎖して無効になる）、すでに unmount された component を使うことは起きない。この形が最も単純である。

compiler を外に出す場合は、`env` と `mod` が compiler 側のリソースになり、`mount` すると component が compiler 側で動く。その結果、component が使う Ref をすべて compiler 側に derive することになり、権限が compiler に集まる。これを避けるには、WebAssembly のモジュールとインスタンスの分け方にならい、env を二つに分ける必要がある。

| | 中身 | 使う場面 |
|---|---|---|
| 型の env | 使ってよい component のシグネチャ | コンパイル時（compiler に渡す） |
| 実物の env | 使ってよい component の Ref | mount 時（Runtime で渡す） |

```
compiler : compile(source, 型の env)       → module（IR の CID。型付きの import の一覧を持つ）
runtime  : mount(module, 実物の env, args)  → activation
```

- compiler には型だけを渡し、Ref は渡さない。module は純粋なデータなので、どこでコンパイルしても、どこで動かしてもよく、同じソースと型なら同じ CID になって使い回せる。
- 実物の env の Ref は、mount のときに activation の引数として渡す。これにより、それらの Ref にはライフサイクルの規則がそのまま適用され、親が env の component を unmount すれば子が先にそれを手放し、親が dispose されれば子も連鎖して dispose される。
- コンパイル済みのモジュールは import を引数に取る functor であり、mount はそれに実物の capability を適用することにあたる（ML の分割コンパイルと同じ構造）。

**判断**：compiler を外に出すならこの分割は必須である。Runtime に内蔵する場合は、より単純な形（`mod` を `env` に連動するリソースとする）で足りる可能性がある。どちらにするかは、compiler が提供する op の詳細を決めるときに判断する。
