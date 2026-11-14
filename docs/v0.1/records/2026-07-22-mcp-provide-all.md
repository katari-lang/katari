# `mcp.provide_all` — 接続の配列化で条件分岐爆発を消す(設計、要レビュー)

## 動機

discord-bot-example の `run_session` は、Notion / GitHub 接続の on/off で **2×2 = 4 分岐**になり、ほぼ同一の
`ai.infer_with_region` 呼び出しを 4 回書いている。原因は scoped `use mcp.provide[marker]` の形そのもの:
marker は provide を呼んだ分岐でしか mint されず、呼ばない分岐の行に marker を union すると discharge
する者がいないまま root へ届いて型エラーになる。つまり **接続の有無という「データ」が、行の形を変える
「制御フロー」に化けている**。接続が 3 つになれば 8 分岐。

lacks 制約(別件)はこれを解かない — これは marker の mint 位置の問題であって、行の多相性の問題ではない。

## 提案

接続の集合を**データ(配列)**にし、marker の mint を **1 回・無条件**にする:

```katari
@"1 本の MCP 接続の記述: 接続先とその認証。"
data connection(@"サーバの URL。" url: string, @"認証。" auth: auth)

@"接続の配列をまとめて 1 つの scope で開く。marker は配列が空でも mint されるので、接続の有無は
行の形を変えない — 条件付き接続は if でなく配列の内容で表現する。結果は接続ごとの toolbox、
入力と同順。"
external agent provide_all[effect Scope, R, effect E](
  connections: array[connection],
  continuation: agent (toolboxes: array[toolbox[Scope]]) -> R with E | Scope,
) -> R with E | io from "mcp"
```

呼び出し側(run_session の 4 分岐が 1 呼び出しに畳まれる):

```katari
let wanted = array.concat(
  left = if (connect_notion) { [mcp.connection(url = "https://mcp.notion.com/mcp", auth = mcp.oauth(name = "notion"))] } else { [] },
  right = if (connect_github) { [mcp.connection(url = "https://api.githubcopilot.com/mcp/", auth = mcp.oauth(name = "github"))] } else { [] },
)
let toolboxes = use mcp.provide_all[mcp.scope](connections = wanted)
let tools = array.concat(left = base_tools, right = array.flatten(target = array.map(target = toolboxes, transform = record.values(target = _))))
ai.infer_with_region(... tools = tools ...)   // 1 回だけ書く
```

## 意味論

- **1 scope = 1 provide_all**: 配列の全接続が同じ marker を共有する。既存 `provide` の「ネストする
  nursery は marker を別に」の規約はそのまま(provide_all はネストの代替ではなく、同一寿命の接続集合の
  表現)。
- 接続のライフサイクルは既存 `provide` と同一(lazy 接続、continuation 脱出で全接続 teardown、
  接続失敗は typed `mcp.server_error`)。teardown は配列の逆順。
- `provide` は残す(1 本のときの素直な形)。provide_all は「複数・条件付き」の一般形。

## 同名 tool(レビューで追記)

衝突は provide_all 固有ではない(2 本の `provide` でも起きる)が、ここで固める。3 点セット:

1. provide_all 自体はマージしない(接続ごとの `array[toolbox]`)— primitive は構造的に衝突フリー。
2. 治療は mint 時の `prefix`(**実装済み**: `provide(prefix = "notion")` → モデル/toolbox キーは
   `notion_search`、wire は minted tool の context の `server_tool` で常にサーバ宣言名)。`connection`
   にも同フィールドを載せる。暗黙の自動リネームはしない — tool 名はモデルへの API。
3. 検出は消費者側で **typed throw**(panic は runtime 不整合専用): AI loop は step 前に tool_metas を
   一度検査して `ai.duplicate_tool(name)` を throw、`mcp.serve` は公開時の重複名を typed で拒否。

## 実装(着手後の知見で更新)

- **provide_all は external でなければならない**(当初案どおり)。stdlib の再帰合成(`provide` の
  ネスト)で書けるかを試したが、型が正しく拒否する: plain agent は marker を discharge できず
  (discharge は接続を実際に開く external の特権)、空配列のケースは「mint していない marker の
  discharge」そのもの — 以前 2×2 の議論で退けた vacuous discharge に他ならない。scope が本物である
  ためには、runtime が(空集合でも)scope を実際に開く必要がある。
- reactor 実装案: 新 payload variant `provideAll { scope, servers: [{descriptor, prefix, landed}],
  continuation }`。同一 scope id を N descriptor に登録(openScope × N)、`startListing` を server
  ごとに張り(listings map の値を `{delegation, slot}` に拡張)、全 slot 着地で N toolbox を mint して
  continuation を `{ value: array }` で dispatch。どれかの listing 失敗は全体を typed `server_error`
  で settle(scope close が全 descriptor を evict)。authorize park は listing 単位で既存の park
  機構に乗る。extension codec に同 variant を追加。
- ローカル再帰 agent(`agent f` の中の `agent g` が `f` を呼ぶ形)はチェッカーが
  「lookupScheme: resolved local variable is not in scope」で panic する **コンパイラバグを発見**
  (Check.hs:3088)。トップレベル再帰は問題ない。要修正(別件)。
- K3022(ユーザーモジュールの `from "mcp"` 禁止)はそのまま効く。
