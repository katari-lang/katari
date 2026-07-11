# MCP `provide`: スコープ付き tool と `scope` phantom effect(v0.1.0, scrap-and-build)

ゴール: **MCP の tool を「接続より長生きする値」ではなく「スコープの区間だけ生きる能力」として
型で縛ること**。tool の寿命を `runST` 型で区切り、スコープの外へ持ち出したら**型エラー**にする。
旧 `mcp.tools(url, auth) -> toolbox`(動的 mint した tool 値がそのまま `let` で外へ漏れる形)は
**削除**した(開発期につき後方互換なし)。

```katari
// tool は `use` ブロックの区間だけ生きる。ブロックを抜けたら scope が閉じる。
// mint された tool は動的シグネチャの agent 値なので、呼び出しは reflection 経由
// (型付きの dot アクセスが欲しければ codegen の `with_tools` — §5)。
let tools : mcp.toolbox["https://mcp.example.com/mcp"] =
  use mcp.provide(url = "https://mcp.example.com/mcp", auth = mcp.oauth(name = "github"))
let issue = match (record.get(target = tools, key = "get_issue")) {
  case null -> bad_server(message = "no get_issue tool")
  case tool -> reflection.call_agent(target = tool, args = { owner = "katari-lang", repo = "katari", number = 1 })
}
json.to_text(value = issue)
```

このドキュメントは、tool を provide の外へ逃がせないようにするスコープ設計(phantom marker +
covariance)、literal / dynamic の分岐、covariance が残す唯一の穴とそれを塞ぐランタイム backstop
規則、永続化 / リカバリの形、codegen(`katari mcp pull`)の `with_tools` 化、そして `serve` の
型の微調整を記録する。表面は `prelude/mcp.ktr` の 1 モジュールにまとまっている。

## 1. スコープ設計: tool は provide の外へ逃げられない

- tool は**値ではなく生きた能力**であり、接続より長生きしてはならない。`tool[URL]` はエフェクト行に
  `scope[URL]` を持つ:

  ```katari
  type tool[URL] = agent never -> unknown with io | scope[URL] | prelude.throw[server_error | auth_error]
  type toolbox[URL] = record[tool[URL]]
  ```

  tool の呼び出しは、その `scope[URL]` を**まだ運んでいる行の中でだけ**型が付く。
- `effect scope[URL]` は **phantom marker**: オペレーションを一切持たず、perform されず、handle も
  されず、lowering で消える(実行時には残らない)。行の中では `mcp.scope["https://..."]` と読む。
- `provide` は**スコープ付き provider**([docs/2026-07-07-composability-reflection-webhook.md](2026-07-07-composability-reflection-webhook.md)
  §1 の `use` provider で確立した `runST` 形)である:
  継続の行に `scope[URL]` を mint し、**自身の結果行からはそれを discharge する**(`-> R with E`、
  scope なし)。

  ```katari
  external agent provide[literal URL, R, effect E](
    url: URL,
    auth: auth,
    continuation: agent (value: toolbox[URL]) -> R with {...E, scope[URL]},
  ) -> R with E from "mcp"
  ```

  継続の行は overwrite 綴り `{...E, scope[URL]}` で書く — provider 形の行の正準表記
  ([docs/2026-07-07-composability-reflection-webhook.md](2026-07-07-composability-reflection-webhook.md)
  §1 の provider 例と同じ)。

  したがって tool を provide の外へ返すと、tool が引きずる `scope[URL]` を discharge する場所が
  どこにもなくなり、**型エラー**になる。tool は provide のブロックから逃げられない。
- エルゴノミックな形は `use`: `let tools : mcp.toolbox["https://..."] = use mcp.provide(url = "https://...", auth = ...)` と書き、
  以降の `use` ブロックの残りがそのスコープになる(`use` の binder には**明示の型注釈**が要る)。

## 2. literal / dynamic の分岐(なぜ `[literal URL]` か)

- `[literal URL]` は **literal-binding generic**(const 型パラメータの類例、commit a39318f)。
  構文上リテラルな文字列引数 `url = "https://x"` は `URL` をその文字列の**シングルトン型**
  `"https://x"` に束縛するので、スコープは `scope["https://x"]` になる — **URL ごとのスコープ**。
  `scope["https://x"]` タグの tool は、その正確なスコープを運ぶ文脈にしか適合しない。
- **dynamic**(非リテラル、たとえば `string` 変数)の `url` は `URL` を素の `string` に格下げし、
  スコープは `scope[string]` — **最も広いスコープ**になる。これは許容され、ドキュメント済みの挙動。
- `scope[URL]` の URL パラメータは **phantom** なので、行の中では **covariant**(phantom-covariance
  規則、a39318f): `scope["x"]` は `scope[string]` に適合するが、`scope["y"]` には決して適合しない。

## 3. covariance の帰結とランタイム backstop 規則

URL ごとの literal スコープは型システム上は airtight である。しかし covariance により、`scope[string]`
の文脈(dynamic url)は**任意の具体 URL の tool を走らせられる** — `scope[string]` でスコープされた
継続が、別 URL の tool を密輸できてしまう。これは型システムが**排除しきれない唯一の穴**である。

ランタイムがこれを backstop する。二つの規則で、静的経路(`call`)と動的経路(minted tool)を
一様に「生きた `provide` スコープの中でだけ呼べる」に揃える。

- **minted tool(close-on-exit 拒否)**: `provide` の各 activation は**ランタイムのスコープ同一性**を
  mint する。mint された tool は(サーバー記述子と並べて)それを context に持つ。`provide` が生きている
  間、tool 呼び出しは従来どおりの transport 経路を通る。`provide` が settle または cancel されると
  スコープは**閉じる**: reactor は記述子のクライアントを transport の接続キャッシュから evict し、
  以降その(閉じた)スコープを運ぶ tool 呼び出しを、**閉じたスコープ名を含む typed `mcp.server_error`**
  で拒否する。つまり covariance の穴を通ってスコープの外へ逃げた tool は、実行時に catch 可能・typed な
  エラーで失敗する — 黙って成功することも、panic することもない。型システムは他の全てを防ぎ、これが
  拾うのは dynamic-URL の covariance ケースだけである。
- **`call`(directCall / static 経路)**: `mcp.call`(生成された `katari mcp pull` バインディングが
  使う経路)のスコープ gating は**純粋に型レベル**(行の中の `scope[URL]`、literal URL generic 経由)。
  directCall のランタイム規則は「記述子(url + auth)について**生きた `provide` スコープを要求する**」:
  その記述子の生きた provide が無い呼び出しは、**欠けている provide を名指しする typed
  `mcp.server_error`** で拒否する。これで静的経路と動的経路が一様になる — どちらも `provide` スコープの
  中で暮らす。

## 4. 永続化 / リカバリ(serve 型の拡張)

`provide` の呼び出しは **serve-like** である。リカバリに必要なもの — 継続 + 記述子 + スコープ id、
加えてその snapshot と inner-delegation の bridge — を **serve 形の拡張テーブル**に永続化する。

- 再起動時に生きたスコープを**再登録**する。in-flight の tool 呼び出しは従来どおり **at-most-once**:
  再起動に割り込まれた tool 呼び出しは typed に失敗し、retry が再接続する。
- mint された tool 値は(永続化された安定な)**スコープ id** を運ぶので、保存された tool は再起動後も
  再登録されたスコープに解決する。

## 5. codegen: `katari mcp pull` の `connect` → `with_tools`

生成モジュールの旧 `connect` agent は、provide をラップする provider に置き換わった:

```katari
agent with_tools[R, effect E](
  auth: mcp.auth,
  continuation: agent (value: { /* …型付きラッパー… */ }) -> R with {...E, mcp.scope["<url>"]},
) -> R with io | E
```

- `with_tools` は `mcp.provide(url = "<pulled literal>", auth = auth, ...)` を呼び、スコープの
  **中で**型付きラッパー record を組み立て、それを呼び出し側の継続に渡す。Katari に無名 agent 式は
  無いので、body は `use` 形になる: `let tools : mcp.toolbox["<url>"] = use mcp.provide(url = "<url>", auth = auth)`
  に続けてローカルの型付きラッパー agent 群、最後に `continuation(value = { … })`。
- 各ラッパーは従来どおり `mcp.call(url = "<literal>", auth = auth, tool = "...", arguments = ...)` +
  decode を呼ぶが、その行に `mcp.scope["<literal>"]` が乗るようになった。
- したがって型付きラッパーの行と、呼び出し側の継続の行に `scope["<literal>"]` が入る
  (継続は `-> R with {...E, mcp.scope["<literal>"]}`)。`with_tools` 自身の結果はスコープを
  discharge する — ただし結果行は `io | E` であって素の `E` ではない(external agent は暗黙に `io` を
  perform するので、`provide` を呼ぶ通常 agent の `with_tools` は `io` を自分の行に宣言する)。

留意: 継続の行は **overwrite 綴り `{...E, mcp.scope["<url>"]}` でなければならない**。union 綴り
`E | mcp.scope["<url>"]` は現行 checker の normalizer が持つ保守的な tail-lacks 部分集合検査で拒否
される(「Effect generic overrides are incompatible」— solver は provider 側の `E` を
tail-minus-scope に解くため、呼び出し側の union 綴りが `rightLacks ⊆ leftLacks` を満たさない)。

```katari
import github   // `--out src/github.ktr` の生成モジュール

agent main() -> string {
  let tools : {
    get_issue: agent (owner: string, repo: string, number: integer) -> get_issue_output with ...,
    // ...
  } = use github.with_tools(auth = mcp.oauth(name = "github"))
  let issue = tools.get_issue(owner = "katari-lang", repo = "katari", number = 1)
  issue.title
}
```

## 6. `serve` は `toolbox` → `toolbox[string]` だけ

`serve` の意味論は不変。型 synonym が URL パラメータ化されたのに伴い、`tools: toolbox` が
`tools: toolbox[string]` になっただけである。完全に handle された(自前の行にスコープを持たない)
ユーザー agent は依然 `tool[string]` へ coerce される — 「行にスコープなし」は
`io | scope[string] | throw[...]` の部分集合だからである。

```katari
external agent serve[R, effect E](
  tools: toolbox[string],
  subscriber: agent (url: string) -> R with E,
) -> R with E from "mcp"
```

## 留意(スコープ外として記録)

- 型システムが排除するのは literal スコープの全ケースと、`scope["x"]` を `scope["y"]` へ渡す誤りである。
  **唯一** backstop に委ねるのは dynamic-URL(`scope[string]`)の covariance ケース — そこだけは
  ランタイムの close-on-exit / requires-live-provide 規則(§3)が typed に拾う。型の穴を実行時 panic では
  なく catch 可能な `mcp.server_error` で塞ぐ、という位置づけ。
- `auth` 直和(headers / oauth)と credential 保存契約は
  [docs/2026-07-10-mcp-oauth.md](2026-07-10-mcp-oauth.md)、`mcp.call` + `katari mcp pull` の 3 層構成と
  型マッピングは [docs/2026-07-10-mcp-pull.md](2026-07-10-mcp-pull.md) を参照。本ドキュメントはその
  表面にスコープを被せる変更だけを扱う。
