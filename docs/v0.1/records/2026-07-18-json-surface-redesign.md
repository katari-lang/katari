# JSON 表面の再設計 — 文書は生の値、wire は三つの動詞だけ(設計提案)

2026-07-18。[[2026-07-18-json-value-wire]] の棚卸し(3ドメイン・変換境界14件・落とし穴9件)を出発点に、
JSON まわりの API 表面をゼロベースで引き直した設計提案。owner の依頼は「ユースケースがまとまってきた
ので、直感的でない部分を仕様変更してユーザーフレンドリーに。全部の形式と変換を見直してベターな設計を」。
ユーザーフレンドリーさの物差しは実ユースサイト — `katari-packages/ai`(anthropic / gemini / openai)、
`google_calendar`、`tavily` / `web`、playground の tools / webhook、katari-web の tutorial。

結論を先に:

- **`json.json`(7 ctor の直和)を廃止し、JSON 文書の通貨を生の値(`unknown`)に一本化する。**
  文書は record / array / スカラーの木そのものであり、専用の木構造型を持たない。
- **無印の動詞は常に literal、wire 規約に触れるのは限られた動詞だけ**(当初案は `encode` / `decode` /
  `to_text` の3語 → 最終形では total 化した `stringify` 1語が wire form 描画も担う、2026-07-19)、
  という命名法則を仕様の中心に置く。`parse` / `stringify` / `parse_as` はキー verbatim
  (`parse_as` だけが今日の意味 — wire 読み — から変わる)。
- `ai.json_to_value` は**恒等写像になって消える**。落とし穴 §1(round-trip 事故)は構造的に消滅する。
- `http.post_json` の body は文字列でなく**値ツリー**を取る(JSON が HTTP に入る形は常に値ツリー)。
- キーワードキー問題は**すでに解けている**(`{ "type" = ... }` の quoted key は 2026-06-30 から
  パース可能 — パッケージの `record.set` タワーは全部不要)。bare 予約語キーのパーサ拡張は v0.1.x。

## 診断 — ユースサイトが既に答えを出している

実装を回った結果、ユースサイトは 2 つの世代に割れている:

| 世代 | 構築 | 読み | 例 |
|---|---|---|---|
| 旧 | `json.json_object(entries = { k = json.json_string(value = …) })` のラッパタワー + `record.set`(キーワードキー)+ `stringify` | `json.parse` → `json.field` / `json.text` の total reader + `match json_*` | openai.ktr、tavily.ktr、google_calendar の `create_event`、playground tools |
| 新 | **値ツリー直組み**(record リテラル + `record.set`)+ `http.json` | 同上 | anthropic.ktr、gemini.ktr(2026-07-18 の round-trip 事故除去で移行済み) |

つまり**構築側の答えは出ている**(値ツリー直組みが正しい形)のに、型 `json.json` が残っているせいで:

1. 読み(parse 結果)と部分木の splice(`get_metadata` のスキーマ、モデルの `tool_call.args`)だけが
   `json.json` の世界に残り、値ツリーの世界へ渡すために `ai.json_to_value`(literal 平坦化)という
   仮設の橋が要る。橋を踏み外して `json.decode[unknown]`(wire 読み)を使うと落とし穴 §1 が再発する
   — **事故の原因は誤用ではなく、二通貨制そのもの**。
2. 旧世代のコードは今もラッパタワーのまま(openai の request body は `json_string` の入れ子が 30 行)。
3. `json.json` が閉じた直和であることの対価(網羅 match)を実際に使っている場所は全ユースサイトで
   **`ai.json_to_value` の 7 分岐ただ一つ** — そしてその関数自身、直和を消せば不要になる。

もう一つの発見: record リテラルの quoted key(`{ "Content-Type" = v }`)は 2026-06-30 の
string-keyed literal(7049a7c)以来パース可能で、LoweringSpec にピンもある。anthropic / gemini /
openai の「`type` is a keyword, so … `record.set`」というコメントと、キーワードキー起因の
`record.set` 11 箇所(key = `"type"` / `"data"`)は**既に不要**である。摩擦 (2) の大半は仕様問題では
なくイディオムの未周知だった。

## 設計 — 各型の役割宣言

[[2026-07-16-katari-boundary]] の原則(一般機構+データ、直感の契約を仕様の中心に)に沿って、
3ドメインを次のように再宣言する:

| ドメイン | 役割 | ユーザーが触るか |
|---|---|---|
| **生の Katari 値** | **JSON 文書の唯一の通貨**。文書とは record / array / string / integer / number / boolean / null の木(文書形)。キーは書かれたまま、`$` に意味はない。`file` は文書形ではないが木に**置ける**(意味は境界ごとに 1 契約 — 後述) | 常に。構築は record リテラル、読みは shape filter(`case string(s)` / `case record(r)` / `case array(a)` — 型検査器に既にある)+ total reader |
| **wire JSON** | 値↔文書の**全単射規約**(`$constructor` / `$ref` / `$agent` / `$closure` / `$tool` / `$$` エスケープ)。reactor 間・FFI・API・永続 envelope の形。SoT は `wire.ts` のまま不変 | `stringify`(非文書値)を自分で呼んだときだけ(当初案の `encode` / `decode` / `to_text` は最終形で `stringify` に集約)。それ以外で `$` を意識したら設計のバグ |
| **`json.json`** | **廃止** | — |

`json.json` が担っていた仕事の行き先:

- parse 結果の読み → `unknown` + shape filter + total reader(readers は今より短くなる — 後述)
- `get_metadata` のスキーマ文書(`agent_metadata.input` 等)→ `unknown` の literal 値ツリー。
  provider body への splice は**代入そのもの**になり、変換関数が消える
- `ai.types.tool_call.args` → `unknown`(モデルの args は literal 文書として運ばれる)
- `mcp.call` の `arguments` / 出力 fallback の `T = json.json` → `unknown`
- 「純 JSON 文書である」という型保証 → **契約に降りる**(`stringify` の定義域)。閉じた直和の
  網羅 match は実ユースで使われていなかったので、失うものは理論上の安心だけ

これが成立する土台は 2026-07-18 の地図で確認済みの事実 — **値平面に曖昧性はない**。literal `"$ref"`
キーを持つ record と `file` 値は内部表現で型が違うので、wire を経由しない限り混ざりようがない。
だから文書を生の値で持つのは常に安全側であり、危険な操作(wire 解釈)だけを名前で隔離すればよい。

副次の利得: AI に見せる引数スキーマ。`json.json` 型のパラメータは 7 ctor 直和の wire スキーマという
異形を導出していたが、`unknown` は `{}`(任意の JSON)を導出する — モデルに対して正直な形になる。

## 新しい表面 — 全変換の名前・シグネチャ・意味

命名法則: **無印 = literal(文書をそのまま)。wire 規約に触れる動詞を限局する。**(当初案は
`encode` / `decode` / `to_text` の3語 → 最終形は total 化した `stringify` 1語がその役割を吸収、
2026-07-19。)「decode」の 2 義(wire 解釈 vs literal 解釈)は、literal 側から decode という語を
追放することで解消する。

| 名前 | シグネチャ | 意味 | エラー |
|---|---|---|---|
| `json.parse` | `(text: string) -> unknown` | **literal** 読み: キーは書かれたまま record のキーに、小数部のない数は `integer` に(`Number.isInteger` 分割 — 今日と同じ)。`$` は解釈しない | `parse_error` |
| `json.parse_as[T]` | `(text: string) -> T` | **literal** 読み + T のスキーマ検証(型付きテキスト境界)。**今日の wire 読みから意味が変わる唯一の動詞** | `parse_error` / `decode_error` |
| `json.stringify[T]` | `(value: T) -> string` | **TOTAL** 書き: 文書形(record / array / スカラー、blob 化 string 含む)は key-for-key で往復、非文書(data / file / agent / closure / tool)は正準 wire form(`$constructor`+`value` / `$ref` handle)に描く。キーは常に書かれたまま(escape なし)。旧 `to_text` を吸収(2026-07-19) | — (total) |
| `json.encode[T]` | `(value: T) -> unknown` | **wire** 文書化: 任意の値をその wire form の literal 文書として返す(data → `$constructor`+`value` ネスト、file → `$ref` handle オブジェクト、record の `$` キー → `$$`)。全値 total。実装は literal-lift ∘ `valueToJson` | — |
| `json.decode[T]` | `(value: unknown) -> T` | **wire** 読み: literal 文書を wire form として解釈し(`$constructor` 再タグ、`$ref` → file 復元、`$$` → unescape)、T のスキーマで別パス検証。実装は `jsonToValue` ∘ literal-flatten + conform | `decode_error` |
| ~~`json.to_text[T]`~~ | — | **`stringify` に統合(2026-07-19)**: `stringify` が total 化して非文書を wire form で描くようになり、別動詞は不要になった(`stringify(encode(x))` の融合はそのまま `stringify` の実装に) | — |

> 最終形(2026-07-19)の注記: 上表の wire 3語(`encode` / `decode` / `to_text`)は、実装では total 化した
> `stringify` 1語に集約された(「the surface collapses to literal — one word touches the wire」)。`stringify`
> は文書を key-for-key で往復させつつ、非文書値を正準 wire form のテキストに描く単一の total 動詞である。

法則(2026-07-02 addendum の継承):

- `stringify(parse(t)) == t`(文書テキスト、数値表記の正規化を除く)/ `parse(stringify(d)) == d`(文書形 d)
- `decode[T](encode(x)) == x` が**全 x で成立**(値 ↔ wire 文書は total・schema 非依存の全単射、検証は別パス)
- テキストレベルの wire 読みは合成で書ける: `decode[T](parse(text))` は `stringify`(非文書描画)の逆
  (literal-lift してから wire 解釈するのは、wire テキストを直接読むのと同値)
- 非対称は残る: 外部産文書 d に対する `encode(decode(d)) == d` は不成立(単一 `$` キーは decode で
  素通りし encode で `$$` 化)。この非対称は wire 動詞の中に閉じ、literal 面には現れない

エラー型は `parse_error` / `decode_error` の 2 つを維持する(`decode_error` は「文書が T に合わない」
の総称で、`parse_as` と `decode` が投げる)。`shape_error` への改名も検討したが、投げ手が明確になった
今、改名の利得は薄い(採らない)。

### total reader — `unknown` の上の探り読み

reader は `json.json` 時代と同じ思想(TOTAL: 欠落・形違いは既定値、不在チェックは最後に一度)のまま
`unknown` に移る。`or_null` は不要になる(欠落はそのまま `null` 値 — 今日も `or_null` が欠落を
`json_null` に畳んでいたので情報量は同じ)。全て plain Katari:

```katari
json.entries(target: unknown) -> record[unknown]   // record でなければ record.empty()
json.items(target: unknown) -> array[unknown]      // array でなければ []
json.field(target: unknown, key: string) -> unknown    // 欠落・形違いは null
json.element(target: unknown, index: integer) -> unknown
json.text(target: unknown) -> string               // string でなければ ""
```

`items` / `entries` は新設。`match (json.field(...)) { case json.json_array(items => items) -> items
case _ -> [] }` という 3 行の踊りが anthropic / gemini / calendar / tavily の全てに出てくる —
これを 1 呼び出しに畳む(reader が既に張っている「total な探り読み」の同じ線上であり、おせっかい
ではない)。形の分岐が要る場所は shape filter がそのまま使える:

```katari
// 今日                                      // 新設計
match (node) {                               match (node) {
  case json.json_object(entries => e) -> …     case record(e) -> …
  case json.json_array(items => i) -> …        case array(i) -> …
  case _ -> node                               case _ -> node
}                                            }
```

### 廃止する変換・型のリスト

| 廃止 | 行き先 |
|---|---|
| `data json_null / json_boolean / json_integer / json_number / json_string / json_array / json_object`、`type json` | 生の値(`null` / `boolean` / `integer` / `number` / `string` / `array[unknown]` / `record[unknown]`) |
| `json.or_null` | 不要(欠落は `null` 値そのもの) |
| `ai.json_to_value`(literal 平坦化の仮設橋) | **恒等写像になって消える** — splice は代入 |
| `json.parse_as[T]` の wire 読み意味 | literal + 検証に変更。wire テキスト読みが要るなら `decode[T](parse(text))` と綴る(現ユースサイトに該当なし — run 引数 / FFI は機構側) |
| `http.post_json(body: string)` | `http.post_json(body: unknown of private)` — 後述 |
| `mcp.call(arguments: json.json)` / 出力 fallback `T = json.json` | `arguments: unknown` / `T = unknown` |
| `agent_metadata` の `input / output / requests : json.json` | `: unknown`(literal 値ツリー) |
| `ai.types.tool_call.args : json.json` | `: unknown` |
| runtime `json-value.ts` の tagged-tree コーデック 4 本 | literal lift / literal write の 2 本(小さい)+ 既存 `codec.ts` の合成 |

## 境界の再定義

各境界は「literal か wire か」を 1 契約で宣言する。[[2026-07-18-json-value-wire]] の境界一覧は
この表に置き換わる:

| 境界 | 規約 | 変更点 |
|---|---|---|
| `json.parse` / `stringify` / `parse_as` | literal | `parse_as` が literal 化。他は型が変わるだけ |
| `json.encode` / `decode` / `to_text` | wire | 値ツリー ↔ literal 文書に着地(木構造型が消える) |
| `http.json` materializer | literal + **file スロット契約**(file を置いたらそこだけ base64、blob 化 string は本文化、`$$` unescape) | 不変 — この契約が手本であり、新設計はこれを全境界の型に広げる |
| `http.post_json` | body は値ツリー(`http.json` 経由)。Content-Type 既定 + 非 2xx `status_error` の opinionated スタンス維持。**返りは parse 済み `unknown`**(空 body は `null`)| 変更 — 後述 |
| `mcp.call` / minted tool の引数 | literal walk(キー不変)。**reactor は `$$` unescape を持つ**(新しい出口面の規約 — 今日は `json.json` 木が literal walk されるので escape が現れなかったが、生 record が wire で届く以上必須)。file スロット契約も `http-body.ts` の materializer を共有して同じにする | 変更 |
| mcp direct reply / listing 取り込み | literal lift(`T = unknown` はそのまま、typed `T` は今日どおり conform-else-wire)。listing → toolbox の `jsonToValue → valueToJson` 往復(単一 `$` キーを `$$` 化してしまう)は literal lift に直す | 簡素化 |
| `reflection.get_metadata` | スキーマ文書の literal lift(plain record 化)| 型が変わるだけ |
| `reflection.call_agent` | args は**値**(literal 文書ではない)。境界は検証のみ・書き換えなし — 今日の法則のまま | 不変 |
| ai loop の `tool_call.args` | 運搬は literal(`unknown`)。dispatch 直前の `json.decode[unknown]` が唯一の wire 読み(モデルが replay した `{$ref}` は本物の file になって tool に渡る)。request body への echo は**代入** | `json_to_value` 消滅 |
| run 引数 / FFI / redact | 機構側 — 不変 | — |

検討して**却下**した対案 C′: `call_agent` が literal 文書を直接受けて境界で blind revive する
(loop から `decode` も消える)。却下理由は、値と文書の曖昧性を境界に持ち込むから — literal `"$ref"`
キーの引数を取る tool が永久に書けなくなり、落とし穴 §1 を境界に移植するだけになる。wire 読みの
意図は呼び出しとして可視のまま残すのが正しい。

### `http.post_json` — JSON が HTTP に入る形は常に値ツリー

摩擦 (4) の二重性(`post_json(body: string)` vs `http.json(unknown)`)は、**文字列側を消して**解く:

```katari
agent post_json(
  url: string,
  body: unknown of private,      // 値ツリー。file を置いたらそこだけ base64(http.json と同一契約)
  headers: record[string of private],
) -> unknown                     // parse 済みの返り。空 body は null
```

- 実装は `fetch` + `http.json(value = body)` の合成のまま(組み込みは書ける合成の効率化版)。
- tavily は `post_json(url = …, body = { query = query, max_results = 5 }, headers = …)` の 1 呼び出しに
  なり、構築タワーと `stringify` と `json.parse` が全部消える — JSON API 統合の正準形。
- 返りを `unknown` にするのは `post_json` が既に宣言している opinionated JSON-API スタンスの一貫
  (非 2xx は `status_error` に body テキストが乗るので情報は失われない)。2xx で JSON でない body は
  `parse_error` — JSON API を名乗る相手が約束を破った、が正しい読み。生テキストが欲しい呼び手は
  `fetch` が常に脱出口(providers は現に `fetch` 直呼びに移行済み)。
- すでに直列化済みのテキストを送る稀なケースは `fetch` + `http.text`。

### `$` エスケープの見え方(摩擦 5)

原則「ユーザーに意識させない」はこう達成される: literal 面(parse / stringify / readers / http.json /
mcp 引数 / splice)には `$` の規約が**存在しない** — キーは常に書かれたまま。`$$` がユーザーの目に
入るのは `encode` の出力(とその stringify)だけで、それは「wire form を見せてくれ」と自分で頼んだ
場面である。機構側の規約「値 ↔ wire は escape で守る。新しい出口面は自分の unescape を持つ」は不変
(今回 mcp 引数面に unescape を追加するのがその適用第 1 号)。

## キーワードキー(摩擦 2)

- **v0.1.0(コスト 0)**: quoted key `{ "type" = "tool_use", id = call.opaque, … }` を公式イディオムに
  昇格し、パッケージのキーワードキー起因 `record.set` 11 箇所を一掃、tutorial / reference に明記する
  (ヘッダ等の動的キー構築は `record.set` のままが正しい)。
- **v0.1.x(パーサ拡張)**: bare 予約語キーの文脈受理。`recordEntry` は今 `identifier <|> stringLiteral`
  — ここに「予約語 + `=` 先読み」を足す(`{ type = … }`)。同様に `fieldAccessPostfix`(`.` の後は
  予約語で曖昧性なし — `x.type`)、record 型のフィールド(`{ type: string }`)、pattern のフィールド名
  (`type => t`)。ブロックとの曖昧性はない(`try recordLiteral` が先行し、文中に `type` 宣言は
  来ない。`{ for = 1 }` も `for` の直後が `(` でないので record 側で確定)。見積り: Lexer に
  reserved-word-as-name ヘルパ + 4 パースサイト + テストで 0.5–1 日。宣言側(`data foo(type: …)`)
  まで広げるかは需要を見てから — record キーと field access だけで実ユースの摩擦は消える。

## 落とし穴 9 件の対応表

[[2026-07-18-json-value-wire]] の §1–9 が新設計でどうなるか:

| # | 落とし穴 | 新設計での帰結 |
|---|---|---|
| 1 | `decode[unknown]` round-trip 事故 | **構造的に消滅**。二通貨が消え、splice は代入(`json_to_value` 恒等化)。wire 読みは `decode` 1 語に限局され、呼ばない限り起きない |
| 2 | `$$` エスケープの見え方 | ユーザー面から消える(literal 面に `$` 規約なし)。機構規約「新しい出口面は unescape を持つ」は**残る**(値↔wire 全単射に escape は不可欠)— mcp 引数面に unescape を追加するのが本提案の適用例 |
| 3 | `json.json` に file を置けない | **溶ける**: 文書=値ツリーなので file が置ける。意味は境界ごとに 1 契約 — `http.json` / mcp 引数は send 境界で base64、`stringify` は file を `$ref` handle 文書に描く(total、2026-07-19 以降) |
| 4 | handle を送りたいときは明示 stringify | `json.stringify(value = a_file)` を文書に埋める — 「wire form をくれ」という意図がそのまま動詞になる(旧 `to_text` を `stringify` が吸収) |
| 5 | typed JSONSchema が外部スキーマに lossy | **半分残る**: tool 値の `inputSchema` が typed subset である限り `$defs` / JSON-pointer `$ref` は落ちる(why: 境界検証は typed schema で走る)。ただし listing 取り込みの wire 読み→再 escape 往復は literal lift に直すので、単一 `$` キーの `$$` 化は消える。raw 文書の並走保持は v0.1.x の改善候補 |
| 6 | 同じ文書でも「意図」で変換が分かれる | **残るが可視化される**: デフォルトが literal(echo は代入)、wire の意図は `decode` の呼び出しとして 1 箇所に現れる。「どちらかに統一すると壊れる」緊張は、統一しない+明示する、で解消 |
| 7 | 数値の縮退(bare JSON の数は 1 種)| **残る**(テキスト境界の本質)。`parse` が `Number.isInteger` で割るのは今日と同じ、値平面は `integer` / `number` を保持、`1.0` は `1` で round-trip |
| 8 | `json_string` が blob 化 string を抱える | **残る・簡素化**: ラッパが消えて string 値そのもの。`stringify`(total)は本文化 — 規約は同じで層が一つ減る |
| 9 | `$redacted` は片道 | **残る**(機構)。`decode` / FFI とも復元は throw — redact 済み文書の再投入は大声で死ぬのが正しい、のまま |

## 検討した代替案

- **A. 現状維持 + 命名整理**(`json.json` 温存、`json_to_value` を stdlib に昇格): 二通貨制が残る
  以上、橋(literal 平坦化)と橋の踏み外し(落とし穴 §1)が仕様に残る。却下。
- **B. `json.json` を parse 結果の read 専用 view に純化**(構築側から ctor を消す): 読み語彙が
  二重のまま(`match json_*` と shape filter)、splice の橋も残る。「読み専用の木」は shape filter +
  total reader で表現できるので、型を残す理由が網羅 match だけになる — その網羅 match の実ユースは
  ゼロ件だった。却下。
- **C. `unknown` 一本化**(採用): 上記。危険な操作を型で分けるのではなく、**安全な表現(値ツリー)を
  唯一の通貨にし、危険な解釈(wire)を動詞で隔離する**。if は sum の上にだけ、分岐は大元で —
  という既存の法則とも整合する(literal / wire の分岐は呼び出しの選択であり、データの中を流れない)。

## 移行影響(ユースサイトごと)

| ユースサイト | 変更 | 規模 |
|---|---|---|
| `ai/src/ai.ktr` | `json_to_value` 削除(27 行)。`decode_args` は綴りそのまま(`decode[unknown](value = args)` — args の型が `unknown` に)。`dispatch_one` の `encode` + `stringify` は綴りそのまま。`collect_result_files` / `is_file_handle` は shape filter 化 | 小 |
| `ai/src/ai/types.ktr` | `tool_call.args : json.json` → `unknown` | 極小 |
| `anthropic.ktr` / `gemini.ktr` | `ai.json_to_value(node = …)` → 直接代入。`record.set` タワー → quoted key リテラル(`{ "type" = "tool_use", … }`)。response 読みの `match json_*` → shape filter / `json.items`。`gemini_sanitize` は `record(entries)` の上の同型書き換え | 中(機械的) |
| `openai.ktr` | ラッパタワー全廃 → record リテラル + `post_json(body = tree)`(返り `unknown` で `json.parse` も消える)。`arguments = json.stringify(value = call.args)` は綴りそのまま | 中(行数は大きく減る) |
| `tavily.ktr` | `search` の body 構築 5 行 → リテラル 1 行 + `post_json`。`render_results` は reader 移行 | 小 |
| `google_calendar.ktr` | `create_event` payload → `{ summary = summary, start = { dateTime = start }, … }`。`calendar_get` / `read_moment` / pager は reader 移行 | 小–中 |
| playground `tools.ktr` | `tool_list` → record リテラル(`input_schema = m.input` は代入のまま)。`parse_as` は綴り不変(意味は literal 化 — この文書に `$` キーはないので挙動同値)。`dispatch` の描画は `to_text` → `stringify`(total 統合、2026-07-19) | 小 |
| playground `webhook.ktr` / `mcp_demo` / `basics` / discord-bot / katari-verify | 描画は `to_text` → `stringify`(total 統合、2026-07-19) | 小 |
| stdlib `reflection.ktr` / `mcp.ktr` | metadata / `mcp.call` の型を `unknown` に、doc 書き換え | 小 |
| `McpCodegen.hs`(`katari mcp pull`)| 最小: `json.json` → `unknown`、`json.json_object(entries = …)` → record 直渡し。**本質的簡素化**(v0.1.x): 「typed param は `json.encode` で埋めるため部分マッピングが unsound → all-or-nothing fallback」という制約が、literal 引数では**消える**(plain 型の値はそれ自身が文書; `encode` が要るのは file だけ)。部分マッピング解禁は別 wave | 小(+1–2d で簡素化) |
| katari-web docs(tutorial `giving-the-model-tools`、concepts `types-and-schemas`、guides)| `inspect` の例 → record リテラル、`parse_as` の説明 literal 化、`json` tree の節を書き換え | 小–中 |
| runtime tests / e2e | codec・prim・mcp reactor のピン更新。e2e smoke は providers / tools を現に踏むので回帰検出はここ | 中 |

## 実装コスト見積

| 領域 | 作業 | 見積 |
|---|---|---|
| compiler | **変更なし**(`json.json` は通常の stdlib data で、パーサ・型検査器に特別扱いが元々ない。shape filter・quoted key・`unknown` は既存)。stdlib `.ktr` の書き換えのみ | 0.5d |
| runtime | literal lift / literal write の新設(`jsonValueFromJson` の plain 版 ~30 行、文書形チェック付き write ~50 行)。`encode` / `decode` は既存 `valueToJson` / `jsonToValue` との合成。prim 配線(`interop-prims.ts`)、`get_metadata`、tagged-tree コーデック削除 | 1–1.5d |
| runtime(reactor)| mcp 引数の literal walk + `$$` unescape + file 契約(`http-body.ts` の materializer 共有)、direct reply / listing の literal lift 化 | 1d |
| runtime tests | codec / prim / reactor のピン更新、境界の新ピン(mcp unescape / file) | 1–1.5d |
| `http.post_json` | stdlib 書き換えのみ(合成は既存)| 0.2d |
| packages + examples + docs | 上表の一掃(機械的)| 1.5–2d |
| cli(`McpCodegen.hs` 最小)| 型名・埋め込みの置換 | 0.5d |
| **v0.1.0 合計** | | **6–7d** |
| parser(bare 予約語キー)| record entry / field access / 型 field / pattern field の文脈受理 | 0.5–1d(v0.1.x)|
| codegen 部分マッピング解禁・schema raw 並走保持・その他 | | v0.1.x |

## 段階案

**v0.1.0 に入れる(推奨)**: `json.json` 廃止一式(parse / stringify / parse_as の literal 統一、
encode / decode / to_text の `unknown` 化、readers、廃止リスト、境界の再定義、mcp 引数 unescape +
file 契約共有)、`post_json(body: unknown) -> unknown`、quoted key のイディオム昇格とユースサイト
一掃、docs 更新。理由: これは**型を消す破壊**であり、互換を無視できる v0.1.0 が唯一の窓。中途
(型を残して命名だけ直す)は二通貨制のコストを恒久化する。動詞の名前と役割は `parse_as` 以外
全て保存されるので、移行は機械的で、行数は全ユースサイトで減る。

**v0.1.x に送る**: bare 予約語キーのパーサ拡張(quoted key で当座は足りる)、`McpCodegen` の
部分マッピング解禁、tool 値への raw スキーマ並走保持(落とし穴 §5 の残り半分)、宣言側パラメータ名
への予約語開放(需要が出たら)。

実装したら [[2026-07-18-json-value-wire]] の境界一覧と落とし穴をこの文書の表で置き換え、あちらは
歴史(なぜ二通貨制を捨てたかの記録)として残す。
