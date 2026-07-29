# stdlib の合成穴を埋める — shared×exclusive / http 語彙 v2 / segment 防衛(2026-07-29)

常駐アプリ(tsukasa)と katari-packages のレビューで、**stdlib にあるはずの合成が無いために各所が同じ
定型を手書きしている**箇所が洗い出された。本稿はその穴を塞いだ 7 つの追加の設計判断を記録する。追加は
すべて純 Katari(新 primitive ゼロ)なので、既存ランタイムイメージのまま snapshot に載る。

| # | 追加 | 潰した定型 |
|---|---|---|
| 1 | `http.classify_status` + `auth_error` / `api_error` に `status`・`context` | パッケージごとの分類器コピー 3 本 |
| 2 | `store.shared_exclusive_as[T]` | 「なぜ helper が使えないか」の弁明コメント 4 本 |
| 3 | `store.safe_segment` / `scope` の断片検査 | charset ループ手書き ×2 |
| 4 | `json.text_at` | `text(field(...))` の 2 段ネスト 17 箇所 |
| 5 | `reflection.constructor_of` | `"$katari_constructor"` 魔法文字列 |
| 6 | `record.set_if` | optional フィールド構築の 4 行 `match` |
| 7 | `time.weekday_label` / `offset_label` / `date_label` / `stamp` / `add_days` | アプリ側 civil 整形一式 |

## 1. shared × exclusive の穴 — `_as` が入れ子に合成しない

`shared_as[T]` は「task 自身が T を返す」ことを要求するが、内側を `store.exclusive` で包んだ task は
必ず `unknown` を返す — `exclusive` は request であり、応答型が handler 境界で消えるためだ(K3016 の
一形態)。結果として「共有セルの read-modify-write」という最も普通の操作だけが両ラッパーから漏れ、
3 箇所が「素の `shared` × 素の `exclusive` + 手書き `json.validate`」を書き、そのたびに理由を
コメントで再導出していた。`shared_exclusive_as[T]` はその合成を 1 箇所に固定する(内側 `unknown`、
外側で 1 回だけ narrowing)。言語側の本修正(request 応答型の generic 化)は別工事なので、これが正しい
中間解である。

## 2. http エラー語彙 v2 — status を捨てたのが間違いだった(破壊的)

`auth_error` / `api_error` は「誰が動くべきか」の線引きとしては正しかったが、**status を捨てて
message に畳んでいた**ため、下流の retry ポリシーが「408/429/5xx か」を判定する手段を失い、英文の
部分一致か、パッケージ独自の分類器コピーに逆戻りしていた。v2 では両変種が `status` と、呼び出し側が
書く `context` を持ち、分類は `classify_status` 1 本に集約する。判断(401/403 = 認証、他 = API)は
変えていない — 変えたのは**その判断結果が数値を運ぶ**ことだけで、これで「Google の 401 と Anthropic
の 401 が別の型を着る」二方言が消える。`status_error` は raw fetch 層の事実として不変。

## 3. `store.scope` の不正断片は panic — outcome ではなく defect

worker 名や series 名は**そのまま store のパス断片になる**ので、`/` や `..` を含む名前は workspace
幾何(「そこに dispatch された agent はその directory に居る」)をただの文字列 1 本で破る。そこで
charset を stdlib に 1 箇所置き、**2 つの形**に分けた: `safe_segment` は total で `null` を返し
(モデルが選んだ名前が不正なのは日常の出来事で、文言はアプリの物)、`scope` は不正 path で **panic**
する(検証していない入力で workspace を開いたプログラムには欠陥がある。代替ディレクトリなど無いので、
値で返せば bad prefix のまま書き込みが続く)。これは「seam = outcome / defect = panic」の素直な適用。

**実装上の注意**: Katari は panic を *raise* できない(`prelude` ヘッダの通り、`panic` はランタイム
自身の失敗チャネルで、プログラムが perform できる宣言は無い)。よって唯一の扉である部分適用 prim —
零除算 — を `store.panic_on_unsafe_path` の中で 1 回だけ使っている。panic メッセージはランタイムの
物("division by zero")なので、**診断はエージェント名がトレースに出ることに依存する**。message を
運べる `panic` の第一級化は言語側の宿題として残る(新 prim はランタイム再ビルドを要求するため、
今回の「純 Katari のみ」制約では採れない)。

## 4〜7. 残りの 4 つ

- `json.text_at(target, key, fallback ?= "")` — `text(field(...))` の 1 段化。`text` 単体は非文字列を
  `""` に畳むので fallback を飲んでしまう、というのが「2 つ重ねるだけでは足りない」理由。パス式 DSL
  (`json.at(target, "a.b.c")`)には**行かない** — 1 段アクセサで実測 17 箇所すべてを賄える。
- `reflection.constructor_of(value)` — `data` のコンストラクタ名は値の**帯域外**タグであり、field
  ではないので `record.get` も `match` も届かない。唯一観測できるのは `json.stringify` が描く wire 形
  なので、そのテキストの先頭タグを読む。魔法文字列の家をここ 1 箇所にするのが目的。将来 prim 化する
  価値はある(runtime 側 `interop-prims.test.ts` にテキスト形の契約テストを追加済み)。
- `record.set_if[T](target, key, value)` — 「値が `null` なら**キーごと書かない**」の正準形。省略と
  明示 JSON null は境界で別物なので、`null` を書き込むのでは表現できない。T は `target` から読むので、
  `record.empty()` から始める鎖(= mcp codegen)だけ `set_if[unknown]` と明示instantiate が要る
  (T が union の下にしか現れず、下限として解けないため)。
- `time` の civil ラベル 5 本 — `to_rfc3339` は wire の render であって、人やモデルに見せる物ではない。
  `add_days` は**正午アンカー**が肝で、真夜中起点だと DST の 1 時間で日付が前後に落ち、週次タスクが
  曜日から静かにずれていく。`strftime` 相当のパターン言語は**作らない**(第二の文字列文法とその
  エスケープ規則を抱えることになる)。

## 追随が必要な下流

語彙 v2 のみが破壊的:

- katari-packages: `gmail` / `google_calendar` / `google_common` / `tavily` / `imagegen` / `web` の
  ローカル分類器を `http.classify_status` に委譲し、構築箇所に `status` / `context` を渡す。
  `ai` の `step_error` は `http.status_error` → `http.api_failure` へ。
- tsukasa: converter / ceiling 型 / `classify_crash` の union を新語彙へ。
- tsukasa(語彙 v2 とは別件・**現に壊れている**): `crash_kind` は
  `json.field(target = error, key = "$katari_constructor")` でコンストラクタ名を掘っているが、上記の
  通りタグは field ではないので**常に `null` → 常に "crash"** を返している(= `ai.supervise` の
  repeat 判定が実質無効)。`reflection.constructor_of` への置換は名前の整理ではなくバグ修正である。
- `katari mcp pull` の再生成: optional 引数が `record.set_if[unknown]` の 1 行になるので、生成済み
  バインディング(`notion.ktr` 等)は次の regen で差分が出る(意味は不変)。
