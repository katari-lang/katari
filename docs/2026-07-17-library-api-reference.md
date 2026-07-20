# library API reference — `katari docs` の JSON 契約と生成パイプライン

owner の決定(2026-07-17): registry 全パッケージ + prelude の API Reference を katari-web の一部として
生成する(独立サイトにしない)。API Reference は各宣言の**動作を端的に**述べる(ソースの `@"..."`
docstring が SoT)。機能の**組み合わせ方はガイド**に書く。katari-web 内でも language doc(`/docs`)と
library reference(`/reference`)はページを分ける。

## 型と schema は別レイヤ

- **型(surface)が一次データ**。generics、effect row、`of private`、union、synonym — schema に
  写らない情報はここにしかない。reference は宣言時の表層型に忠実に出す(synonym は展開しない。
  解決済み qualified name を添えてリンクにする)。
- **schema は導出ビュー**。`Katari.Schema` が型から導出する wire-facing の姿 — runtime /
  `reflection.get_metadata` が AI に見せるものと同一。admin-web は runtime 側なので schema しか
  持てないが、reference は compiler 側なので両方持てる。schema は「wire view」として monomorphic
  な agent にだけ添える(generic は型パラメータが開いているので出さない。placeholder で埋めない)。

## `katari docs` (CLI)

```
katari docs [--out PATH]     # プロジェクトの root package の docs JSON。既定は stdout
katari docs --stdlib         # prelude(stdlib 全モジュール)の docs JSON
```

- ロードは `loadProjectOffline`(build/check と同じ、決定論・オフライン)。
- `Compile.compile` を直接呼ぶ(`compileSourcesOrExit` は loweredModules しか返さない。docs は
  `typedModules` + `loweredModules` の両方を使う)。
- 対象は **root package の自モジュールのみ**(依存パッケージのモジュールは含めない)。
- **private agent も出す**(owner 判断 2026-07-17)。`private` はカプセル化ではなく privacy 属性系
  — handle が private world からのみ呼べるという意味で、private な呼び出し側にとっては API
  サーフェスの一部。JSON に `"private": true|false` を載せ、web はバッジで示す。
  なお現状 Lowering は private を見ずに全 agent を entry 登録しており(Lowering.hs:456)、runtime
  トップレベルからも起動できてしまう。private escalation が operator へ流れうるので、IR entry に
  privacy を載せて run-start 境界で拒否するのが筋(entries は first-class agent 解決にも使われる
  ため entry から外す方式は不可)。**別件のフォローアップ**。
- schema は再導出しない: Lowering 済み IR の `SchemaInformation`(agent の input/output/requests)
  を宣言名で引く。generic fallback(`SchemaAny`/`SchemaAny`)は「schema なし」として null。
- `--stdlib` は `Compile.stdlibParsed`(Parsed 相)から抽出する。Parsed には resolution が無いので
  TypeNode の `resolved` は null になる(stdlib 型は surface qualifier で足りる)。

## JSON 契約(katariDocsVersion = 1)

```jsonc
{
  "katariDocsVersion": 1,
  "compiler": "0.1.0",                          // cliVersion
  "package": { "name": "ai", "version": "0.1.0" },   // --stdlib では { name: "prelude", version: compiler }
  "modules": [{
    "name": "ai.types",
    "declarations": [{
      "kind": "agent",       // agent | external_agent | primitive_agent | request | marker_effect | data | type_synonym
      "name": "infer_with_tools",
      "private": false,                          // agent のみ(handle privacy)。他 kind では省略
      "documentation": "…",                      // @"..." 本文。無ければ null
      "signature": "agent infer_with_tools[E](…) -> string with E",   // 表層構文、コピー用
      "generics": [{ "name": "E", "kind": "effect", "bindsLiteral": false, "upperBound": null }],
      "parameters": [{ "label": "history", "documentation": null, "type": TypeNode, "default": null }],
      "returnType": TypeNode,                    // agent で省略(推論)なら null
      "effects": TypeNode,                       // effect row。無ければ null
      "checkedType": "agent(…) -> …",            // agent のみ: renderSemanticType(推論込みの真)
      "reactor": "http",                          // external_agent のみ
      "definition": TypeNode,                    // type_synonym のみ
      "schema": { "input": {…}, "output": {…}, "requests": [{…}] }   // monomorphic agent のみ、IR 由来
    }]
  }]
}
```

### TypeNode(表層型の構造化ツリー)

`SyntacticTypeExpression` の忠実な写し。**全ノードが `rendered`(自身のソース表記)を持つ** —
レンダラは Haskell に一つだけ置き、web 側は文字列合成をしない(どの深さのノードもコピー可能)。

| node | 追加フィールド |
|---|---|
| `primitive` | `name`(integer/number/string/boolean/null/file) |
| `string_literal` | `value` |
| `never` / `unknown` / `all` / `io` / `pure` / `array` / `record` | —(裸のヘッド) |
| `name` | `qualifier`(surface)、`name`、`resolved`: `"prelude.json.json"` \| `{"generic":"T"}` \| null |
| `agent` | `parameter`、`return`、`effects`(null 可) |
| `application` | `head`、`arguments[]`(`array[string]` 等) |
| `tuple` | `elements[]` |
| `union` | `branches[]` |
| `object` | `fields[]`: `{name, optional, type}` |
| `attributed` | `base`、`attribute`(`T of private`) |
| `attribute_literal` | `kind`(public/private) |
| `override` | `base`、`overrides[]` |

表層プリンタ(`rendered` / `signature`)は新規実装(既存資産なし — McpCodegen は JSONSchema→型
テキストで別物、renderSemanticType は意味型用)。agent のパラメータ型は `BindVariable` の注釈
から(注釈無し = null、`checkedType` が真を補う)。default はリテラルのみ(`?=` の仕様どおり)。

## 実装配置

- `compiler/src/Katari/Docs.hs` — 抽出と JSON 化。phase 多相(resolution アクセサを渡す)で
  Typed(ユーザ)/ Parsed(stdlib)を一本化。
- `cli/src/Katari/Cli/Command/Docs.hs` + `Main.hs` 配線。
- テスト: ソース文字列 → `Compile.compile` → docs JSON を inline golden で(McpCodegenSpec の流儀)。

## katari-web `/reference`(フル UX)

- `/reference` — snapshot のパッケージ(prelude + 6 パッケージ)カード一覧。クリックで遷移。
- `/reference/<package>` — サイドバーに module 一覧、本文は宣言リスト。
- 宣言表示: TypeNode をグラフィカルに描く(admin-web の SchemaViewer と同じ視覚文法 — type badge、
  `border-l` インデント、Copy ボタン)。`signature` はコード表示 + コピー。monomorphic agent には
  schema(wire view)タブ。
- 生成: katari-web ビルド時に registry の pin から tarball を取得 → リリース済み katari バイナリで
  `katari docs` → 静的ページ。prelude は `katari docs --stdlib`。

## 積み残し(このイテレーションではやらない)

- **module docstring**: `Module` に annotation が無い(パーサは宣言単位のみ)。module 概要を
  出したくなったら `Module.annotation` + パーサ拡張を入れる。それまで module ページの前書きは
  宣言の docstring だけで構成する。
- effect row 内の request リンク(effects TypeNode の name 解決で既に取れる — web 側の表現だけ)。
- 検索(katari-web の既存 search-index に reference エントリを足す)。
