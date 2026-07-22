# credentials 統一 — パッケージ横断の capability 規約(設計、要レビュー)

現状、katari-packages の 8 パッケージにクレデンシャルの扱いが **5 パターン並存**している:

| パターン | パッケージ | 形 |
|---|---|---|
| 名前を受けて内部で `oauth.token` 解決 | google_calendar | `request get_access_token()` → handler が `oauth.token(name)` |
| 値を配る専用 request | tavily, imagegen | `request get_tavily_key() -> string of private`(~15 行の同型定型 ×2) |
| session データに同梱 | e2b | `data session_data(session_id, api_key)` |
| sidecar 接続ハンドル | discord, slack | 接続時に渡して以後は不透明 |
| handler var に閉じ込め | ai の 3 プロバイダ | `use handler (var client = connection(...))` |

SoT 違反(同じ関心事が 5 通りの形)であり、`get_*_key` という命名ドリフトの源でもある。

## 設計の核にある緊張

**値渡し**(`api_key: string of private` を provider 引数に)は合成が明快だが、**OAuth は使用時点の鮮度が要る**
(`oauth.token` は呼ぶたびに refresh 済みトークンを返す)。値を一度キャプチャすると refresh に追随できない —
google_calendar が内部解決を選んだ理由はこれ。逆に名前渡しに全振りすると、単純な API キーまで runtime の
credential store 経由を強制され、`env.get_secret` との二重管理になる。

## 提案: nominal request 1 本 + 共有の source 直和

**各パッケージは自分の capability request を 1 本、標準名 `credential` で宣言し続ける**(effect 行に
「どのパッケージのクレデンシャルが要るか」が出るのは意味であり、共通化しない)。**解決だけを** stdlib の
直和 + 1 関数に集約する:

```katari
// prelude.credentials(新設)
@"..."
data api_key(@"..." value: string of private)
@"..."
data oauth(@"runtime の credential store 上の名前。" name: string)
type source = api_key | oauth

@"source を使用時点の実クレデンシャルに解決する。api_key はその値、oauth は oauth.token(name) —
呼ぶたびに refresh 済みの現在値。"
agent resolve(source: source) -> string of private with io | prelude.throw[oauth.server_error] {
  match (source) {
    case api_key(value => value) -> value
    case oauth(name => name) -> oauth.token(name = name)
  }
}
```

各パッケージ側の標準形(tavily の例、全文):

```katari
@"tavily の呼び出しが要求する capability。provider が discharge する。"
request credential() -> string of private

@"credential を source の解決で提供する。"
agent provider[R, effect E](
  source: credentials.source,
  continuation: agent (value: null) -> R with {...E, credential},
) -> R with E | io | prelude.throw[oauth.server_error] {
  use handler { request credential() -> string of private { next credentials.resolve(source = source) } }
  continuation(value = null)
}
```

- **per-call 解決**なので OAuth の refresh 鮮度は自動で正しい。api_key の match 1 回は無視できるコスト。
- 呼び出し側: `use tavily.provider(source = credentials.api_key(value = env.get_secret(key = "TAVILY_API_KEY")))`
  または `source = credentials.oauth(name = "google-calendar")`。**パッケージは自分がどちらで認証されるかを
  知らない** — 認証方式の選択がアプリ(データ)側に移る。
- tavily / imagegen / ai(3 プロバイダ)/ google_calendar / e2b は機械的に移行できる。
- discord / slack は WebSocket 接続時に一度だけ resolve して sidecar へ渡す(接続クレデンシャルは接続の
  性質上その時点で固定 — 正直にそう文書化する)。provider 引数の形だけ `source` に揃える。

## 併走する統一(同じ波で)

- 命名: capability request は全パッケージ `credential`、provider 引数は `source`。`get_*_key` は廃止。
- 欠損表現: 空文字センチネルをやめ `T | null` 直和に統一(google_calendar の `description ?= ""` など)。
- モデルのデフォルト: ai の 3 プロバイダとも `model ?=` を持つ(現状 anthropic のみ)。
- imagegen: 純 Katari 化(`http.post_json` + `file.from_base64`)とセットで移行し、生 JS throw = panic
  規約違反も同時に消す。
- `auth_error | api_error` の 3 重定義: **data 宣言は各パッケージ nominal のまま**(行の出所を保つ)。統一
  するのは形 — フィールド名(`message`)と分類規約(401/403 → auth_error、他 → api_error)のみ。

## やらないこと

- 名前をリテラル型で行に載せる案(`credentials.get[literal Name]` の単一 request)は、同名 request の
  異なるインスタンス化が行の Map で合流し精度を失うため見送り。nominal request の方が行が語る。
- runtime credential store への API キー profile 追加は要らない(`env.get_secret` が既に名前付きシーク
  レットの SoT)。store を触らないので移行が薄い。
