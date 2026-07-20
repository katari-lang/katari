# http の file スロット — body の実体化は wire 境界で(値平面には handle だけ)

owner 決定(2026-07-18): AI プロバイダの画像 inline(`files.read_base64` を純 Katari で呼ぶ)は
base64 文字列を **durable な値平面に乗せてしまう** — メモリコピー、external call envelope としての
DB 永続化、trace の汚染。gemini プロバイダは今日この重さを抱えており、anthropic の画像対応も
同じ穴に落ちる。欠けている能力は「**file の中身を、値として実体化せずに HTTP リクエストへ運ぶ**」。
AI 専用最適化ではなく、HTTP の body モデルに沿った一般 primitive として分解する
([[2026-07-16-katari-boundary]] の判定原則)。

## 直感の契約(これが判断基準)

**body に `file` 値を置いたら、その場所だけが送信時に中身へ変換される。** handle(`$ref`)を
そのまま送りたいケースはほぼ無く、欲しければ明示的に stringify する — これが Katari ユーザーの
自然な期待であり、docs で明文化する。値平面・DB・trace に乗るのは常に handle のみで、バイト列は
http reactor が送信の瞬間に blob store から読む(slim-blob-ref と同じ思想)。

## 三態 — HTTP が標準を持つ所は標準に、無い所は慣行と明記

| 形 | 意味 | 根拠 |
|---|---|---|
| **raw** | body = file 1つの生バイト列(Content-Type は file から) | HTTP 標準(S3 PUT 等の upload API) |
| **multipart** | RFC 7578 multipart/form-data、パートに file | **HTTP 標準** |
| **base64 スロット** | json ツリー内の `file` 値が、その位置で base64 文字列になる | 標準ではなく **REST 慣行**(GitHub content API、AI プロバイダ群)。docs にそう書く |

## 表面のスケッチ(実装時に確定)

- `http.fetch` の body を直和へ: `text(string of private)` / `binary(content: file)` /
  `multipart(parts: ...)` / `json(value: ...)`(json 態のツリー内 `file` が base64 スロット)。
  `post_json` は json 態の糖衣として維持。
- runtime: external call envelope には handle を格納し、http transport が送信時に blob を読んで
  raw / multipart / base64 に実体化。レスポンス側は現状不変(受信の file 化は将来)。
- 消費側の書き換え: `ai.gemini` / `ai.anthropic` の画像 inline がスロットに置き換わり
  read_base64 呼び出しが消える(プロバイダは純 Katari のまま)。将来: slack の files.uploadV2 を
  multipart 態で純 Katari 化する余地、raw 態で blob の外部 PUT。
- `files.read_base64` は残す(小さいデータの明示変換は正当)が、docs は http には
  スロットを使えと誘導する。

## 非目標

ストリーミング送信(boundary 台帳の SSE/streaming と同じく defer)。受信側の file 化。
