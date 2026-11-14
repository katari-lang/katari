# Katari Protocol

ver 1.0 策定中

## 概要

### 目的

Katari Protocol は、Katari のエンドポイント間のプロトコルであり、次を達成するものである:

- リソースの権限 (Grant) の配布、再配布、失効。
- Component の起動 (Activate)、引数の差し替え、及び停止。

### レイヤ

Katari Protocol はいくつかのレイヤからなる。

| レイヤ |  |
|---|---|
| [認証](#認証) | エンドポイント間の認証 |
| [RPC](#RPC) | 通信されるオペレーションの仕様 |
| [リソース](#リソース) | リソースの管理と配布、再配布、失効 |
| [Component](#Component) | Component の Activation、引数の差し替え、及び停止 |
| Katari Language | 言語仕様を参照 |


## 認証

### エンドポイントの識別子

エンドポイントの識別子は DID であり、did:key か did:web とする。

```
did:key:z<base58btc(0xed 0x01 ‖ Ed25519 公開鍵 32 バイト)>
did:web:<Host>:<Path>:<to>:<Document>
```

- エンドポイントは、自身の識別子が示す場所に DID 文書を置く必要がある。
  - did:key なら、did 自体が文書となる。
  - did:web なら指定された web サーバー上の、Path (指定なしの場合 /.well-known/) 以下に、did.json を配置する。

did:web の場合、DID 文書は次のような形をとる。

例:

```jsonc
{
  "@context": ["https://www.w3.org/ns/did/v1.1"],
  "id": "did:web:example.com",
  "verificationMethod": [{
    "id": "did:web:example.com#key-1", // key 名は任意に付けられる
    "type": "Multikey", // type は Multikey か JsonWebKey である
    "controller": "did:web:example.com",
    "publicKeyMultibase": "z6Mk…" // 公開鍵
  },
  {
    "id": "did:web:example.com#key-2",
    "type": "JsonWebKey",
    "controller": "did:web:example.com",
    "publicKeyJwk": {
      "kty": "OKP", // 固定
      "crv": "Ed25519", // Ed25519 固定
      "x": "Lm_…"
    }
  }],
  "authentication": ["did:web:example.com#key-1", "did:web:example.com#key-2"], // Katari では自身の文書を指すものしか使えないとする。
  // service は基本的に id を DID#katari、type を KatariEndpoint とする。
  "service": [{
    "id": "did:web:example.com#katari",
    "type": "KatariEndpoint",
    "serviceEndpoint": "https://example.com/katari" // DID 文書と同オリジンで無ければいけない
  }]
}
```

### 設定

運用者は次の二つを設定する。

- Peers（DID → URL）：送り先の URL。did:key の DID 文書は送り先を持たないので、did:key のエンドポイントにはここで URL を与える。
- Policy（DID の集合）：通信を許可する DID。

### エンドポイントの所在の特定

各エンドポイントは他のエンドポイントに通信したいとき、どこにアクセスすればいいかを判断したい。次の手順に従う。

1. 前提: まず、Policy に DID が無ければ Policy 違反でありエラー
2. Peers にあればその URL。専ら `did:key` に使うが、`did:web` にも使える
3. `did:web` の場合、DID 文書を入手し、その `serviceEndpoint`
4. どちらでもなければエラー。

### トークン

リクエストの送信者は、自身の鍵で署名した JWT を JWS Compact Serialization で表してトークンを作成する。


#### 保護ヘッダ

```jsonc
{
  "alg": "Ed25519", // 固定
  "typ": "katari+jwt", // 固定
  "kid": "<送信者の DID 文書の authentication に載っている鍵の id（DID URL）>"
}
```

`alg`, `typ`, `kid` 以外のプロパティは載せてはならない。


kid は次のように指定される。

- `did:key` の場合、Multibase 自身の繰り返しとなる。

```
did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK#z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK
```

- `did:web` の場合、authentication 内の key を指定する。

```
did:web:example.com#key-1
```

#### クレーム

| クレーム | 内容 |
|---|---|
| `iss` | 送信者の DID |
| `aud` | 受信者の DID |
| `iat` | 署名した時刻（Unix 秒） |
| `exp` | 有効期限（Unix 秒）。`exp - iat` は有効期間の上限（参考: [既定値](#既定値)）以下とする |
| `kv` | 整数であらわされるプロトコルバージョン。このドキュメント冒頭の ver のメジャーバージョンを用いる |

### 検証

受信者は次を順に検証する

1. JWS Compact として解釈可能か、`alg` が `Ed25519`、`typ` が `katari+jwt` で、`kid` が絶対形の DID URL である。`alg`, `typ`, `kid` 以外のプロパティが載っていない
2. `kid` の `#` より前を DID の Sender とする。Sender が DID として受け付ける形式か、Policy に載っているかを確かめる。適当なら文書を解決する。
3. その文書の `authentication` に載っている鍵から `id` が `kid` と等しいものを探し、なければ拒否。文書の中の相対的な `id` (`#key-1` など) は絶対的にしてから探す
4. その鍵で署名を検証。
5. `iss` が Sender である。
6. `aud` が自分の DID である。
7. `kv` が自身のプロトコルバージョンのメジャーと一致している。
8. 現在時刻が `iat` から `exp` までの間にあり、`exp - iat` が有効期間の上限以下である。（時刻のずれを考慮）参照：[既定値](#既定値)
9. Sender とリクエストを上の層に渡す。

応答するエラーは次の種類がある。（Problem Details の `type` は `tag:katari-lang.dev,2026:error:<理由>`とする。）

| 理由 | 状況 | 性質 |
|---|---|---|
| `malformed` | トークンがない、JWT として解釈できない、`kid` が絶対形の DID URL でない、`iss` が Sender と一致しない、必要なクレームがない、他のヘッダがある | 再送しても変わらない |
| `unsupported` | `alg`・`typ` が異なる、受け付けない DID（受け付けない方式、Policy にない）、`kv` が受け付けないバージョンである | 再送しても変わらない |
| `bad-signature` | 署名が検証できない、`kid` の鍵が DID 文書の `authentication` にない | 再送しても変わらない |
| `misdirected` | `aud` が受信者でない | 再送しても変わらない |
| `stale` | 現在時刻が有効期間の外、または `exp` - `iat` が上限を超える | トークンを新しくすれば再送で変わりうる |
| `unavailable` | 受信者の側で今は検証や処理ができない（一時的な障害、DID 文書を解決できない） | 待ってからの再送で変わりうる |

### HTTP binding

```
POST <解決した URL>
Authorization: Bearer <トークン>
Content-Type: application/json

<JSON-RPC のリクエスト>
```

| 状況 | HTTP | リザルト |
|---|---|---|
| `malformed`・`unsupported`・`bad-signature`・`misdirected`・`stale` | 401 | `application/problem+json` |
| `unavailable` | 503（`Retry-After` を付けてよい） | 同上 |
| ヘッダの Content-Type が `application/json` でない | 415 | 同上 |
| 検証に通った | 200 | JSON-RPC の応答（`application/json`）。JSON-RPC のエラーも 200 で返す |

- 401 には `WWW-Authenticate: Bearer` を付けなければならない。トークンが付いていた場合は、`error="invalid_token"` を加える（RFC 6750 §3）。
- すべての応答に `Cache-Control: no-store` を付けなければならない。

通信経路は次に従う。


| 所在 | 要件 |
|---|---|
| 同じホストの中 | 平文の `http` を用いてよい |
| ホストをまたぐ閉じたネットワーク | TLS か、それに準じる暗号化を用いなければならない |
| インターネット | `https` を用いなければならない |

### 実装への要件

次の規則は通信プロトコルではないが、実装において守るべきである

- 接続先は、[所在の特定](#エンドポイントの所在の特定)で得た URL に限る。すなわち、Peers の URL か、Policy に載せた did:web の `serviceEndpoint` 以外には接続しない。第三者から受け取った値（Ref など）から接続先を得てはならない。
- `serviceEndpoint` が DID 文書の所在と同じオリジンでなければ、それを用いない。
- HTTP クライアントはリダイレクトに従わない。
- Policy にない DID の DID 文書を取得しない。
- Authorization ヘッダは記録に残さない

## RPC

### メッセージ

HTTP リクエスト本文は JSON-RPC 2.0 のリクエスト、レスポンスは　JSON-RPC の応答とする。

- `id` は必須の文字列（UUIDv7）とし、送信者が必ず付ける。(id なしの通知は使わない)
- `id` はリクエストごとに新しく作り、別のリクエストに用いない。
- メソッドの名前空間は`<kind>/` といったように分ける。

### エラー

リクエストの失敗は JSON-RPC の `error` で返す。

```json
{ "code": 1001, "message": "Request is in progress",
  "data": { "type": "tag:katari-lang.dev,2026:error:in-progress" } }
```

- `type` は `tag:katari-lang.dev,2026:error:<名前>` とする。

| `code` の範囲 | 定めるレイヤ |
|---|---|
| -32600〜-32603, -32700 | JSON-RPC 標準 |
| 1000 番台 | [RPC](#RPC) |
| 1100 番台 | [リソース](#リソース) |
| 1200 番台 | [Component](#Component) |
| 2000・2001 | 拡張 |

- `code` を拡張するときは 2000 か 2001 を用いる。知らない `code` は 2000 として扱う。

| `code` | `type` の名前 | 意味 |
|---|---|---|
| -32700 | `parse-error` | リクエストが JSON としてパースできない |
| -32600 | `invalid` | リクエストの形式が不正 |
| -32601 | `no-method` | メソッドが存在しない |
| -32602 | `invalid-params` | 引数が不正 |
| -32603 | `internal` | 内部エラー |
| 1001 | `in-progress` | 同じ `id` のリクエストを処理している |
| 1002 | `id-reused` | 同じ `id` で内容の異なるリクエストを処理済み |
| 2000 | （拡張が定める） | 拡張のエラー |
| 2001 | （拡張が定める） | 拡張のエラーのうち一時的なもの |

### 受信

受信者は、同じ (Sender, `id`) のリクエストを一度だけ処理する。[検証](#検証)に通ったリクエストを次の順に判定し、最初に該当した行の応答を返す。

| 状況 | 応答 |
|---|---|
| リクエストが JSON としてパースできない| -32700 |
| JSON-RPC のリクエストとして不正 (id なしも含む) | -32600 |
| 同じ (Sender, `id`) を処理している | 1001 |
| 同じ (Sender, `id`) を処理済みで、内容が異なる (任意。照合する場合はリクエストのバイト列の SHA-256 で比較) | 1002 |
| 同じ (Sender, `id`) を処理済み | そのときの応答 |
| 上のレイヤの処理がエラーになった | 上のレイヤは一時的なもの、つまり再送して直りうるものを 2001、それ以外は 2001 以外のコードを用いる。 |
| 予期しない内部エラーが起きた | -32603 |
| 上のレイヤの処理が成功した | `result` |

- 応答する側は応答を記録しておく。この記録は処理の確定と atomic に記録されるべき。
  - なお、2001 と -32603 は除く。これらは同じ内容の再送で結果が変わりうるからである。処理も確定させてはいけない。
- 処理の途中で受信者が再起動したらリクエストは処理していないものとして扱う。
- 参考: 保持期間（[既定値](#既定値)）
- 参考: 応答時間の上限（[既定値](#既定値)）

### 送信

- リクエストを送る時は、リクエストを送ると書き込む -> 送る -> 完了した（または再送をやめた）と書き込む、として再起動耐性を付けるべき。リクエストを送ると書き込むのはそれによる状態変化と atomic にするべきである。
- 送信者は同じ `id` で再送する。有効期間内のトークンを付ける
- 再送の間隔はジッター付きの指数バックオフとする。ただし 503 で Retry-After があれば従う。
- 同じ `id` のリクエストを同時に二本以上送るべきでない。
- リクエストが届く順序は保証しない。

受け取ったものは、上から順に判定して扱う。

| 受け取ったもの | 扱い |
|---|---|
| `id` が一致しない応答、JSON-RPCの応答として解釈できないもの | 破棄して再送する |
| 1001・-32603・2001 | 再送する |
| RPCレイヤのそれ以外のエラー | 再送をやめて失敗とみなす |
| それ以外の応答 | このオペレーションが成功したとみなす |
| malformed, unsupported, bad-signature, misdirected, 415 | 失敗とみなす |
| stale | 新しいトークンで再送 |
| それ以外の　HTTP エラー | 再送する |

送信者は、再送の期限（既定値）に達するまで再送する。その後、冪等でないメソッドは再送をやめなければならない。冪等なメソッドに関してはその限りではなく、上のレイヤが期限を過ぎても再送を続けることを求める場合がある。

送信者は、上の層に結果を渡す (成功したらその結果、再送しても失敗したらその旨)

## リソース

### リソースの識別

各エンドポイントはリソースを保持する。リソースは次のような URI で一意に定まる。

```
katari:<issuer の DID>/<Kind>/<Local ID>
```

Kind はリソースの種別を定めるものである。この文書では `component` が定義されている。`standard-kinds.md` に他の標準的なKindを定め、それらは小文字始まりの識別子である。将来の拡張: 各サーバーが逆ドメイン形式の提供をできるようにする。

なるべくあらゆる状態をリソースとして扱う事が望ましい。

一部のリソースは貸し出すことが出来る。リソースの貸し出しは Grant というものを受け渡すことで行われる。Grant は次の URI で一意に定まる。

```
<Resource URI>/grant/<Grant の ID>
```

- KindやIDは `/` を含まない。DID も含まないので、分解は一意にできる
- URI は公開情報と考え、秘密の値は入れてはいけない。

### メソッドと貸し出し

## Component

## 既定値

| 項目 | 既定値 | 制約 |
|---|---|---|
| トークンの有効期間 | 60 秒（上限 5 分、時計のずれ 30 秒） | |
| HTTP リクエストの大きさの上限 | 4 MiB | |
| 一回の送信のタイムアウト | 60 秒 | 応答時間の上限より長い |
| 応答時間の上限（受け取る側） | 30 秒 | メッセージを受理するまでの時間 |
| バックオフ | 初回 1 秒、2 倍ずつ、full jitter | |
| 再送の間隔の上限 | 1 分 | |
| 再送の期限 | 24 時間 | |
| 処理済みの応答の保持期間 | 7 日 | 再送の期限 ＋ トークンの有効期間の上限より長い |
| 招待トークン | 128 ビット、有効期限 7 日 | |
| `onStuck` までの時間 | 10 分 | |
