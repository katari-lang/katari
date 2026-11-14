# 零引数 agent — 糖衣は要らなかった(2026-07-29)

tsukasa レビューの提言 4 は「零引数エージェントが書けない」とし、`agent f() -> T { ... }` / `f()` を
`(value: null)` / `value = null` へ機械的に脱糖するパーサ糖衣を求めていた(儀式 76 箇所)。**着手前の
確認で前提が崩れた**: `()` は現に文法として通り、現に意味を持っている。本稿はその現物の意味を記録し、
糖衣を**入れない**と決めた理由と、儀式を消すための実際の手順を残す。

## 何が既に成立しているか

`agent f() -> T { ... }` は「パラメータを 1 つも取らない agent」であり、`f()` はその零引数呼び出しで
ある。新しい話ではない — `agent main() -> string` は `katari init` の雛形そのもので、`record.empty()`
`array.empty()` `env.get_all()` `time.now()` はすべて零引数の stdlib 呼び出しだ。ここに脱糖を入れる
ことは、これら全部の意味を `(value: null)` 付きに書き換えることを意味する。`record.empty()` は
`record.empty(value = null)` になり、`main` は `{"value": null}` を要求するようになる。純糖衣どころか、
言語で最も使われている宣言形の破壊的変更である。よって**糖衣は入れない**。

## 儀式が消える理由 — object 型は「要求する」フィールドだけを名指す

では stdlib と tsukasa の `(value: null)` は何だったのか。`prelude.catch` / `store.shared` /
`region.post` / `replay.*` の task 引数は `agent (value: null) -> T` と宣言されている。ここに零引数
agent を渡せるかどうかが儀式の全てだったが、**渡せる**。katari の object 型は必要なフィールドだけを
名指す(余分なキーは許す)ので `{value: null} <: {}` が成り立ち、agent のパラメータレコードは反変
だから `agent () -> T <: agent (value: null) -> T` になる。つまり `(value: null)` という宣言は
**呼び手への要求ではなく、受け入れ幅の広い上界**だった。

同じ理由で、引数名も渡す側には伝わらない。`task: agent (input: null) -> null` の枠にも零引数 agent は
そのまま入る — `value` と `input` の綴り分けは、零引数側に寄せた瞬間に問題ごと消える。

逆向きは通らないし、通らないままでよい。`agent unit(value: null) -> T` と宣言した agent を `unit()` で
呼ぶのは K3001(必須フィールド `value` が無い)。宣言された引数は必須である、という素直な読みであり、
**バラで呼びたい agent はバラで宣言する**というのがそのまま移行規則になる。

wire 側も同様に安全だ。零引数 agent の input schema は「プロパティ無し・required 無し・開いた
object」なので、`catch` が内部で書いている `task(value = null)` は零引数の task に着地しても
ランタイムの delegate 受理検査(閉じた object のときだけ余剰キーを弾く)を通る。型と実行の両方で、
移行は片側ずつ進められる。

## 移行規則(採用側)

1. 宣言を `()` に寄せる: `agent decide(input: null) -> null with E { ... }` → `agent decide() -> null with E { ... }`。
   インラインの `agent (value: null) -> null { ... }` も `agent () -> null { ... }` へ。
2. 直接呼び出しから引数を落とす: `preflight_secrets(value = null)` → `preflight_secrets()`。
3. **callback の型注釈は触らなくてよい**。`agent (value: null) -> T` のままで零引数 agent を受け取れる。
   自前の型注釈を `agent () -> T` に狭めることもできるが、それは受け入れ幅を狭める破壊的変更になる
   (`(value: null)` 版の agent が入らなくなる)ので、アプリ内で両側を握っているときだけにする。
4. `region.fork(argument = null)` は別物 — `argument` は generic `A` の実引数なので落とせない。零引数
   の一発仕事には既に `region.post` がある。

## 残る宿題

stdlib の doc string(特に `region.post`)は `agent (value: null) -> null` を**書くべき形として教えて
いる**。儀式の出所はここなので、語彙の更新は stdlib 側の別作業として残す。コンパイラの文法・AST・
型検査・schema・直列化はいずれも変更していない。

回帰の固定として、`ParserSpec` に「`()` は引数ゼロ、`f()` は実引数ゼロ(パーサは何も挿入しない)」を、
`LoweringSpec` に零引数 agent の 4 象限(宣言 + 素の呼び出し / 無名値 / `(value: null)`・`(input: null)`
枠への受け入れ + 実 stdlib の `prelude.catch` / 開いた input schema / 必須 `value: null` を素で呼べば
K3001)を追加した。
