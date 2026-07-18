# json / 値 / wire — 3ドメインの地図と全変換境界

2026-07-18。プロバイダの `json.json → stringify → decode[unknown] → http.json` round-trip 事故
(後述の落とし穴 §1)を除去した際に、JSON にまつわる**3つの別物のドメイン**と、その間の全変換境界を
実装から棚卸しした総まとめ。以後「この値はいまどのドメインにいるか」「この境界は予約キーをどう扱うか」
はここを参照する。実装の SoT: `typescript/types/src/wire.ts`(予約キーとエスケープ)、
`typescript/runtime/src/runtime/value/codec.ts`(値 ↔ wire)、
`typescript/runtime/src/runtime/engine/json-value.ts`(`json.json` ↔ 値/文書)、
`haskell/compiler/stdlib/prelude/json.ktr`(言語表面)、`haskell/compiler/src/Katari/Schema.hs`(スキーマ)。

## 3つのドメイン

| ドメイン | 実体 | `$` キーの意味 | file の姿 |
|---|---|---|---|
| **(i) `json.json`** | 純 JSON 文書の直和(`json_null` … `json_object(entries: record[json])`)。内部的には `prelude.json.json_*` を ctor に持つ data 値の木 | **ただのエントリ**。`parse` / `stringify` はキーを一切解釈しない(literal) | 存在できない(7形しかない)。`json.encode(file)` は `$ref` エントリを持つ **json_object**(handle の文書化)になる |
| **(ii) 生の Katari 値** | record / array / スカラー / `file`(= slim blob ref)/ agent / closure / tool / data(ctor 付き record)。engine のタグ付き `Value` モデル | キーは素のまま。file は record では**ない**(`kind: "ref"`)ので、literal `"$ref"` キーを持つ record と file 値は**内部表現で曖昧性なし** | `{ kind: "ref", semanticKind, blobId }` — identity のみ、バイト列は blob store |
| **(iii) wire JSON** | 値コーデック(`valueToJson` / `jsonToValue`)が作る bare Json。reactor 間・FFI・API・永続 envelope の形 | **予約単一 `$` 判別キー**: `$constructor` / `$ref` / `$agent` / `$closure` / `$tool` / `$redacted`。ユーザ record の `$` 始まりキーは先頭 `$` を倍加(`$$`)して退避 | `{ "$ref": blobId, "semanticKind": … }` handle オブジェクト |

wire の要点(`wire.ts` 冒頭に明文): data 値のフィールドは `value` の下にネストするので判別キーと衝突せず、
bare record は `$$` エスケープにより単一 `$` キーを**発行できない** — オブジェクト variant は本物の直和。
`$redacted` だけは片道(redact ポリシーの吸い込み口、decode は拒否)。

曖昧性が生じるのは **wire JSON 上だけ**であり、そこはコーデックのエスケープが守る。値平面では
literal `"$ref"` キーを持つ record と file 値は型が違うので混ざりようがない — だから「wire を経由せず
値を直接組み立てる」ことが常に安全側。

## 全変換境界の一覧

| 境界 | 方向 | 予約キーの扱い | file の扱い | 実装 |
|---|---|---|---|---|
| `json.parse` / `json.stringify` | text ↔ (i) | **literal** — キーは書かれたまま。`$constructor` もただのエントリ | stringify は blob 化 string leaf を本文化(文書の string は text) | `interop-prims.ts` + `json-value.ts` の `jsonValueFromJson` / `jsonValueToJson` |
| `json.encode[T]` | (ii) → (i) | **wire 規約を畳み込む**: data は `$constructor`+`value` ネスト、record の `$` キーは `$$` 化 | file → `$ref` エントリを持つ json_object(handle の文書) | `json-value.ts` `encodeValue` |
| `json.decode[T]` | (i) → (ii) | **wire 読み**: `$constructor` 再タグ、`$ref` → file 復元、`$agent`/`$closure`/`$tool` → callable 復元、`$$` → unescape。その後 T のスキーマで**別パス検証**(decode_error) | `$ref` → 本物の file 値 | `json-value.ts` `treeToValue` + `validation.ts` `conformValue` |
| `json.to_text` / `json.parse_as` | 融合対(encode∘stringify / parse∘decode) | 構成要素と同一(parse_as は `jsonToValue` 経由) | 同上 | `interop-prims.ts` |
| schema boundary 検証 | (ii) を JSONSchema に照合 | 検証のみ・**書き換えなし**(コーデックと分離が法則)。file ref は `$ref` 参照スキーマを満たす | 照合のみ | `value/validation.ts` |
| **http.json materializer** | wire(reveal 済) → HTTP 文書 | **`$$` を素の `$` に unescape して出力**(2026-07-18 修正)。単一 `$` の `$ref` handle は base64 化なので両者は衝突しない | `$ref` handle → その位置で base64。blob 化 string leaf → text | `external/http-body.ts` `materializeJsonTree`(reactor 側は `http-reactor.ts` が `valueToJson(…, "reveal")`) |
| FFI port | wire ↔ handler の JS 値 | decode で unescape / encode で再エスケープ。`$ref` → `KatariFile`/`KatariString`、`$constructor` → `KatariData`、`$agent`/`$closure`/`$tool` → `KatariAgent`。`$redacted` は throw | handle ラッパ(バイトはオンデマンド download) | `port/src/values.ts`(reactor 側 `ffi-reactor.ts` は reveal で送出) |
| run 引数 / 結果(API) | wire → (ii) / (ii) → wire | 引数は wire 読み(`{$ref}` を渡せば file になる)、不正 handle は 400。結果は **redact**(private subtree → `$redacted`) | 引数の `$ref` → file 復元 | `facade.ts` |
| `reflection.get_metadata` | JSONSchema → (i) | `schemaToJson` の文書を **literal lift**(`jsonValueFromJson`)。file 引数のスキーマは literal `"$ref"` **プロパティキー**を含む文書になる(Schema.hs `fileReferenceSchema`) | n/a | `interop-prims.ts` + `Schema.hs` |
| mcp tool 引数(minted tool / `mcp.call`) | (i) → MCP server 文書 | `jsonValueToJson` の **literal** 歩き — キー不変 | blob 化 string leaf は本文化 | `mcp-reactor.ts` |
| mcp direct reply | server 文書 → (ii) | まず literal tree で conform(`T = json.json` / `unknown` はそのまま)、外れたら wire 読み + conform(typed `T` の `$ref` は本物の file に) | typed T なら file 復元 | `mcp-reactor.ts` `decodeDirectReply` |
| mcp listing → toolbox | listing 文書 → tool 値 | `jsonToValue`(wire 読み)→ `valueToJson`(**再エスケープ**)→ `jsonToSchema`(**typed subset 化**: 未知キーワード `$defs` / `$schema` / JSON-pointer `$ref` は**落ちる**) | — | `mcp-reactor.ts` `mintToolbox` + `schema-json.ts` |
| model の `tool_call.args`(ai loop) | (i) → (ii) | `decode_args` = `json.decode[unknown]` — **意図的に wire 読み**。モデルが replay した `{$ref}` は本物の file になって tool に渡る | `$ref` → file 復元 | `katari-packages/ai` `ai.ktr` |
| プロバイダの request body(現行) | (i) の部分木 → (ii) | `ai.json_to_value` = **literal 平坦化**(キー再解釈なし)。file はツリーに**値として直接**置く | file 値のまま(base64 は送信境界) | `katari-packages/ai` `ai.ktr` / `anthropic.ktr` / `gemini.ktr` |

法則(2026-07-02 addendum の再確認): 値 ↔ wire は total・schema 非依存の bijection、検証は別パス。
ただし bijection の向きに注意 — `decode(encode(x)) == x` は全 x で成立するが、**外部産の文書**に対する
`encode(decode(d)) == d` は成立しない(単一 `$` キーは decode で素通りし、encode で `$$` 化される)。

## 落とし穴

1. **`decode[unknown]` round-trip 事故(今回の筆頭)。** 旧プロバイダは request body を
   `json.json` で組み立ててから `json.decode[unknown]` で値ツリーへ落としていた。decode は wire 読みなので、
   文書に**正当な literal `$` キー**があると壊れる: `properties: { "$ref": {…} }`(file 引数を取る tool の
   スキーマ — `view_image` がまさにこれ)は `wireKindOf` が file handle と誤認して "expected a string leaf"
   の decode_error に;`{"$ref": "#/$defs/x"}`(JSON-pointer)は文字列なので**無言で** blobId
   `"#/$defs/x"` の file 値に化ける;予約でない単一 `$` キー(`$schema` / `$defs`)は record キーとして
   素通りした後 `valueToJson` で `$$schema` / `$$defs` に化けて wire に出る。対策は「wire を経由しない」:
   値ツリーを**直接**組み立てる(record リテラル + キーワードキーは `record.set` + file はそのまま置く)、
   `json.json` の部分木(get_metadata のスキーマ、モデルの args の echo)は `ai.json_to_value` の
   literal 平坦化で継ぐ。`json.json` ラッパも `stringify`/`decode` も不要になり、`ai.step_error` から
   `json.decode_error` が消えた。
2. **`$$` エスケープの見え方。** `$` 始まりの record キーは reactor 間 wire では常に `$$…`。
   各**出口面が自分の unescape を持つ**のが規約: FFI port は decode で、http.json materializer は
   送信時に(2026-07-18 に追加 — それまでは `$$ref` のままサーバに届いていた)、`json.stringify` は
   そもそも literal なので関与しない。新しい出口面を作るときは unescape を忘れないこと。
   逆に `unescapeRecordKey` は単一 `$` キーを「外部産の literal キー」として温存する — これが上の
   bijection 非対称の源。
3. **`json.json` に file を置けない理由。** `json` は 7 形の閉じた直和で、file はその形を持たない。
   `json.encode(value = f)` は file を**handle の文書**(`$ref` エントリの json_object)へ落とすので、
   それを stringify しても送れるのは handle であってバイト列ではない。バイト列を送りたければ
   `http.json` の値ツリーに **file 値をそのまま**置く([[2026-07-18-http-file-body]] — 実体化は送信境界、
   値平面・DB・trace には handle しか乗らない)。
4. **handle を送りたいときは明示 stringify。** `http.json` ツリー内の file 値は必ず base64 化される
   (それが REST 慣行への約束)。`$ref` handle 自体を文書として送りたい稀なケースは
   `json.to_text(value = a_file)` を string として埋める(`http.ktr` の `json` variant docs に明文)。
5. **typed JSONSchema は外部スキーマに対して lossy。** `jsonToSchema`(`schema-json.ts`)は既知
   キーワードだけ拾う subset なので、外部 MCP server のスキーマの `$defs` / `$schema` / JSON-pointer
   `$ref` は toolbox mint(tool 値の `inputSchema`)の時点で落ちる。さらに listing の取り込みは
   `jsonToValue`(wire 読み)→ `valueToJson`(再エスケープ)を経るため、単一 `$` キーは `$$` 化して
   から subset 化される。コンパイラ由来のスキーマ(`Schema.hs`)は `$defs` を使わない(data は inline
   展開、再帰は open schema で切る)ので自家製スキーマは無傷 — 痛むのは外部産のみ。
6. **同じ `json.json` でも「意図」で変換が分かれる。** モデルの `tool_call.args` は **wire 読み**
   (`decode_args` — モデルが会話から replay した `{$ref}` は本物の file になって tool に渡るべき)、
   request body への echo は **literal 平坦化**(`ai.json_to_value` — サーバには書かれたままの文書を
   返すべき)。どちらか一方に統一しようとすると必ずどちらかの意図が壊れる。
7. **数値の縮退。** bare JSON には数が 1 種しかないので、text / wire 境界は `Number.isInteger` で
   `integer` / `number` に割る(`1.0` は `1` で round-trip)。`json.json` の木の中では
   `json_integer` / `json_number` が区別を保持する。
8. **`json_string` は blob 化 string を抱えうる。** `stringify` / `to_text` は本文化し、
   `treeToValue` はそのまま保つ(inline でも ref でも string は string)。
9. **`$redacted` は片道。** redact ポリシー(user-facing 境界のデフォルト)が private subtree を
   `{"$redacted": true}` に潰す。これはコーデックの外の吸い込み口で、decode / FFI port とも復元は
   throw — redact 済み文書を再投入したら大声で死ぬのが正しい。
