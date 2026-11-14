# outbound HTTP の private sink: body を submission surface に加える (v0.1.0)

ゴール: **`string of private` の値が「宛先サーバーへの意図的な提出面」からのみ外に出る**という
一様な規則を、ヘッダに加えて **リクエスト body** にも広げること。

```katari
// ヘッダの秘密(従来どおり)に加え、body も秘密を運べるようになった
let response = http.fetch(
  url = "https://oauth2.googleapis.com/token",  // url は public のまま
  method = "POST",
  headers = record.empty(),
  body = f"grant_type=refresh_token&refresh_token=${refresh_token}",  // refresh_token は private でよい
)
```

このドキュメントは、`prelude.http.fetch` / `post_json` の `body` を `string of private` に変えた表面の
変更と、その根拠(宛先サーバーの信頼境界、URL を除外する理由)を記録する。

## 1. 動機: header では届かない秘密がある

Google の OAuth 2.0 token endpoint は `refresh_token` を **form body** で要求する — ヘッダ版の
代替が存在しない。従来の規則(`url` / `method` / `body` はすべて public `string`、秘密はヘッダ値のみ)
では、この `refresh_token` を private のまま提出できず、非 secret の保管を強いていた。owner の判断で
**body を private-capable な sink に格上げする**。

## 2. 一様な規則: 「宛先サーバーへの提出面」だけが private を通す

private な値がランタイムを出てよいのは、**リクエストの宛先サーバーへ向かうときだけ**。その意図的な
提出面 — **ヘッダ値 AND body** — が private を通す。両者は **transport 境界のただ 1 箇所**
(`HttpReactor.dispatch` の `valueToJson(argument, "reveal")`)で剥がされ、そこでリクエストは
プログラムが名指した唯一のサーバーへ発つ。

**`url`(と `method`)は public のまま** — private を渡すと型エラー。URL はログ・キャッシュ・
プロキシ・`Referer` ヘッダに漏れる、つまり宛先サーバー以外の場所に流れるからだ。「提出面(header/body)」
と「漏出面(URL)」を分けるのがこの規則の核心で、body を格上げしても URL の禁止は動かさない。

レスポンスは public(declassify 済み)— サーバーの返答であって秘密の関数ではない。private な body を
持つリクエストのレスポンスも汚染されない(reactor は `jsonToValue` で応答を鋳造し、それは値に private
マーカを一切付けない — 新しい taint 規則は導入していない)。

## 3. 表面の変更(`prelude/http.ktr`)

- `external agent fetch(..., body: string of private)` — `body: string` から変更。
- `agent post_json(..., body: string of private, ...)` — 同上。`body` は下層の `fetch` の
  private-capable な `body` にそのまま渡る。
- 型の向き: `public <: private`。ゆえに **public な body はそのまま受かる**
  (`webhook.ktr` の `body = json.to_text(...)` は無変更で通る)。private な body は
  private-capable な sink に吸収され、観測されない — 呼び出し元の world は public のままでよい。

## 4. ランタイム: 変更は 1 箇所の意味づけだけ

`HttpReactor.dispatch` は元から **引数全体**を `valueToJson(payload.argument, "reveal")` で剥がして
いた。つまり body はすでに同じ単一の reveal 点を通っており、機能的な追加コードは不要 — コメントを
「header AND body を提出面として reveal する / URL は型で public」に更新しただけ。`FetchHttpTransport`
はプレーン Json をそのまま送るだけで、秘密の概念を持たない。

## 5. ログ衛生(調査結果)

http パス(`http-reactor.ts` / `http-transport.ts`)には **ログ出力が一切ない** ため、body(や
dispatch する payload)がログに現れる箇所はない。近傍の構造化ログを確認した:

- `middleware/request-context.ts` は **inbound** リクエストの path をログするが、capability トークンを
  `/mcp/<redacted>` の形で既に伏せる。outbound の body には無関係。
- `substrate.ts` の post-commit 失敗ログは `{ kind: event.kind, error }` のみ — 引数や body は出さない。

したがって capability-URL と同じ伏せ字規律を新たに適用する必要はなかった。

## 6. テスト

- コンパイラ(型層に規則が住むことの証明、`ProgramSpec`): `fetch` の情報流形状を写した
  ローカル external で、public-world の呼び出し元が private header AND private body を提出できること
  (accepted)、private 値が public な `url` sink に届くと **K3001** で拒否されること(規則を honest に
  保つ negative)。
- ランタイム(`http-reactor.test.ts`): 実 `FetchHttpTransport` を loopback サーバーへ駆動し、
  private body が **実ワイヤ**に revealed で届くこと・そのレスポンスが untainted であること、public
  body が無変更で届くことを検証。
