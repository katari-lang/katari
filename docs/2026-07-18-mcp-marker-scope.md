# MCP スコープの identity を「URL literal」から「marker effect」へ(設計分析, v0.1.0)

owner 提案(2026-07-18): `katari mcp pull` の接続識別は今 URL の const string(literal 型)でやっているが、
言語には marker effect がある。**pull 生成モジュールが自前の marker effect を宣言**(名前は各ファイルで
`connection` 等と同じでよい — モジュールが違えば `github.connection` / `slack.connection` と qualified 名が
別になる)し、tools がそれを effect row に載せ、`connect` がその discharge 境界になれば、**URL const string
による mcp スコープ制御は要らなくなるのではないか**。credential との関係も整理したい。

本ノートは現行機構を正確に記述し、marker 案の設計空間(特に「型レベル capability を誰が閉じるか」)を詰め、
credential との軸の分離を確認し、owner 原則に照らした推奨案と実装範囲を出す。**実装はしない**。

結論を先に: 提案は正しい方向で、**採用を推奨**する。核心は「URL literal が *型レベルの scope identity* と
*ランタイムの routing descriptor* の**二役を兼ねている**のを分離すること」。scope identity を module-local
marker に移し、URL は**素の runtime 値(routing 専用)に降格**する。これで covariance の穴が丸ごと消え、
codegen の row 綴りが単純化し、そして **runtime はほぼ無改修**(routing は元々 descriptor 値で行っており、
型レベル scope を使っていないため)。唯一の実作業は compiler 側の「marker をどう discharge するか」1 点に集中する。

---

## 1. 現行機構の正確な記述

### 1.1 URL literal が兼ねる二役

`prelude/mcp.ktr` では 1 本の URL literal が**二つの独立した役割**を同時に担っている。

- **型レベルの scope identity**: `effect scope[URL]`(phantom marker)の `URL` パラメータ。literal な
  `url = "https://a"` は `[literal URL]` generic(literal-binding generic)経由で `URL` を**シングルトン型
  `"https://a"`** に束縛し、tool の row は `mcp.scope["https://a"]` になる。これが runST 型の逃亡不能性を担う。
- **ランタイムの routing descriptor**: 同じ URL literal が `mcp.call` / `mcp.provide` の `url` **引数値**にも
  乗り、runtime はそれ(+ auth)を接続の cache key に使う。

この兼任が現行設計の複雑さの根源である(§2 で分離する)。

### 1.2 型による逃亡不能性(mcp.ktr / scoped.ktr)

```katari
effect scope[URL]                                        // phantom marker: 操作なし・perform 不能・handle 不能
type tool[URL]    = agent never -> unknown with io | scope[URL] | prelude.throw[server_error | auth_error]
type toolbox[URL] = record[tool[URL]]

external agent provide[literal URL, R, effect E](
  url: URL, auth: auth,
  continuation: agent (value: toolbox[URL]) -> R with E | scope[URL],   // 継続の row に scope を mint
) -> R with E from "mcp"                                                 // 自身の row から discharge
```

- tool の呼び出しは `scope[URL]` を**まだ運んでいる行の中でだけ**型が付く。`provide` は継続に `scope[URL]` を
  敷き、**自身の結果行からはそれを引く**(runST の `runST` 形)。tool を `provide` の外へ返すと `scope[URL]` を
  discharge する場所が無く**型エラー**。逃亡不能性は「signature による subtraction」でのみ成立する。
- **同じ形が汎用 primitive として `examples/playground/src/scoped.ktr` に既に demo されている**:
  `primitive agent with_resource[literal res, R, effect E](resource: res, continuation: agent (value: null)
  -> R with E | scoped[res]) -> R with E`。コメント曰く「**A primitive, because only a signature can
  discharge a marker**」。つまり *marker は handler で閉じられない*(後述の enforcement 参照)、閉じられるのは
  signature の subtraction だけ、という設計判断が現行の前提である。

### 1.3 covariance の穴と runtime backstop

- `scope[URL]` の `URL` は phantom なので row 中で **covariant**(`Normalizer.hs` の `requestRowVariance` が
  phantom を covariant に pin、`Inference.hs` の `subtractConcreteRequests` / covariant-arg-remainder が
  merged arg を扱う)。literal url は per-URL scope、**dynamic(非 literal)url は `scope[string]` に格下げ**され、
  covariance により `scope[string]` の継続は**任意の URL の tool を密輸できる** — 型が塞げない唯一の穴。
- runtime がこれを backstop する。routing は**型レベル scope ではなく descriptor 値**で行われている点が重要:
  - `mcp-transport.ts` の `descriptorKey(url + auth identity)` が接続 cache key(`clientFor` / `evict`)。
  - `mcp-dispatch.ts` の `directCall`(= `mcp.call`)は descriptor を引数から組み、`mcp-reactor.ts` は
    「その descriptor について**生きた `provide` scope を要求**」する(無ければ
    `mcp.call: no live mcp.provide scope for ${url}` の typed `server_error`, mcp-reactor.ts:750)。
  - minted tool は `provide` activation ごとの runtime scope-id を持ち、`provide` 退出で descriptor client を
    evict、以降その閉じた scope の呼び出しを typed `server_error` で拒否(close-on-exit)。

  → **runtime は URL/auth の descriptor 値だけで routing・接続・backstop を行い、型レベルの `scope[URL]` は
  一切参照しない**。型レベル scope は純粋に compiler の逃亡不能検査のための飾りである。

### 1.4 codegen(McpCodegen.hs)の生成形

pull は URL literal を全所に焼き込む: `connect` の `provide` url、`mcp.scope["<url>"]`、`toolbox["<url>"]`、
各 tool の `mcp.call["<url>", T]`(§1.1 の二役がここで衝突している — literal は scope 型 generic と url 引数の
**両方**に同じ文字列で出る)。

```katari
request credentials() -> mcp.auth                                   // 接続 auth を ambient 供給する request

agent connect[R, effect E](
  auth: mcp.auth,
  continuation: agent (value: null) -> R with {...(E | mcp.scope["<url>"]), credentials},   // ★混在綴り
) -> R with io | E {
  let _ : mcp.toolbox["<url>"] = use mcp.provide(url = "<url>", auth = auth)
  use handler { request credentials() { next auth } }
  continuation(value = null)
}

agent get_issue(...) -> get_issue_output
  with io | mcp.scope["<url>"] | credentials | prelude.throw[mcp.server_error | mcp.auth_error | json.decode_error] {
  mcp.call["<url>", get_issue_output](url = "<url>", auth = credentials(), tool = "get-issue", arguments = ...)
}
```

- 継続 row の**混在綴り** `{...(E | mcp.scope["<url>"]), credentials}` が load-bearing:
  - `scope` は **union 側**でなければならない。理由は URL-keyed だから — 2 モジュールを nest すると per-URL
    scope が arg-union で `scope["a" | "b"]` に**マージ**し、内側 `provide` は自分の arg 差分だけ引いて残りを外へ流す。
    overwrite 綴りは entry 全体を pin し 2 つ目で K3001。**この面倒さは URL-keyed marker が引き起こしている**(§2.4)。
  - `credentials` は **overwrite 側**(handler が discharge するには共有 `E` から pin して外す必要、純 union だと K3001)。
- codegen テスト(`McpCodegenSpec` golden + round-trip + composition)がこの形を byte 単位で固定している。

---

## 2. marker effect 案の設計

### 2.1 核心: identity を name に移し、URL を routing 値へ降格

marker effect の宣言は**言語の汎用機構として既に存在**する(`Parser.hs:171` `effect name[generics]`,
`Environment.hs` marker collect, `scoped.ktr` の `effect scoped[resource]`)。提案はこの汎用機構を使う:

```katari
// github.ktr(pull 生成)
effect connection                          // module-local な nullary marker。qualified 名 = github.connection

agent connect[R, effect E](auth: mcp.auth, continuation: agent (value: null) -> R with E | connection) -> R with E {
  ... 接続を開く(mcp.provide/open, runtime)...
  ... connection を discharge(§2.2)...
  continuation(value = null)
}

agent get_issue(...) -> get_issue_output
  with io | connection | credentials | prelude.throw[mcp.server_error | mcp.auth_error | json.decode_error] {
  mcp.call(url = "<url>", auth = credentials(), tool = "get-issue", arguments = ...)   // URL は素の string 引数
}
```

変わるのはただ一点: **scope identity を `mcp.scope["<url>"]`(URL literal singleton, covariant)から
`github.connection`(module-qualified name, nullary)へ移す**。URL は `mcp.call` の**素の `string` 引数値**として
残り、runtime routing はそれ(§1.3 の descriptor)で従来どおり。identity が name に宿るので:

- **module namespace が identity を保証**する。手で選ぶ token の衝突可能性(`scoped["github"]` を 2 モジュールが
  偶然選ぶと同一 scope に潰れる)が消える。`github.connection` ≠ `slack.connection` は module system が保証。
- **covariance が消える**。nullary marker には arg が無い → 広がる先(`string`)が無い → §1.3 の穴が
  **構造的に存在しない**。distinct な name 同士は subtyping 関係を持たない(`scope["x"] <: scope["y"]` の
  誤適合も、`scope["x"] <: scope[string]` の widening も起きない)。

### 2.2 型レベル capability を誰が「閉じる」か(検討必須の中心論点)

現行では marker を閉じられるのは signature の subtraction だけで、**handler では閉じられない**
(`Check.hs:2292-2297`: marker を handle しようとすると `TypeErrorWrongReferenceKind` —「markers are
introduced and discharged by signatures alone」)。`mcp.provide` は `mcp.scope[URL]` を固定で subtract するが、
生成される `connect` は**普通の Katari agent**(external ではない)なので自前で subtraction を主張できない。
よって `github.connection` を誰が閉じるかが実装の核心。三つの候補:

- **(a) marker を handler で discharge 可能にする(推奨)**。`Check.hs:2295` の拒否を緩め、marker を名指す
  **operation ゼロの handler**(`use handler for connection { }`)が marker を discharge できるようにする。
  意味論的に自然: **marker = 操作ゼロの request** であり、discharge = 操作ゼロの handler。marker は phantom で
  lowering 時に消えるので、空 handler も lowering で消える — 純粋に型検査上の discharge。`connect` は
  「接続を開く(runtime)」+「`use handler for connection {}`(型)」の 2 手。**新 primitive 不要**、handler という
  既存の汎用 discharge 機構に marker を合流させるだけ。
- **(b) 汎用 scope primitive を stdlib に昇格**。`scoped.ktr` の `with_resource` を literal-keyed から
  **marker-name-keyed** に一般化: `primitive agent enter[effect M, R, effect E](continuation: agent (value: null)
  -> R with E | M) -> R with E`(io を足さない純機構)。`connect` = `enter[connection]` ∘ open。marker は
  非 handle のまま。boundary 原則の「一般 scope 機構を言語に置き、mcp はその 1 消費者」に最も忠実。
- **(c) `mcp.provide` を marker-generic にする(最小差分)**。`provide[effect Scope, R, effect E]` が
  呼び手選択の `Scope` を subtract。`connect` = `mcp.provide[connection]` の 1 手。scope が mcp に残る(分解度は低い)。

**(a)(b)(c) の逃亡不能性・runtime 保証は等価**である(いずれも「型 scope は空機構、実接続は provide+descriptor が
別途担保、runtime requires-live-provide が実境界」— これは現行 §1.3 と同じ保証水準で退行なし)。差は discharge の
書き味と新機構の量:
- (a): `Check.hs` の marker-handle 拒否を緩めるだけ。新 primitive 0。marker を「操作 0 の request」に統合(最も economical)。
- (b): 新 stdlib primitive 1 + name-generic subtraction(§2.3)。boundary 原則に最も整合。
- (c): stdlib 改修のみ + name-generic subtraction(§2.3)。scope が mcp 内に残る。

推奨は **(a)**。owner 原則「一般機構」に最も適う(marker に特別扱いを増やすのでなく、request との差を減らす)。
ただし marker を意図的に「signature でしか閉じない」とした現行判断(scoped.ktr のコメント)を緩めることになる
点は明示的な設計決定であり、owner 確認が要る。marker を非 handle のまま保ちたいなら **(b)**(boundary-doc の
gap-ledger「scope 型付け ✓ phantom effect は通常宣言」の *discharge 側* を埋める昇格として自然)。

> **name-generic subtraction について**(b/c が要る場合): `with_resource` は `scoped[res]`(name は固定 `scoped`、
> arg `res` だけ generic)を subtract する。(b)(c) は name 自体が generic(`M`/`Scope := github.connection`)。
> generic は**呼び出し時点で instantiate** され、その後 row-solve が走るので、instantiate 後は具体 name
> `github.connection` の subtraction = `subtractConcreteRequests` の既存 name-keyed 経路そのもの。`effect M` を
> 単一 marker entry(closed single-entry row)に束ねられれば modest な一般化で足りる見込み。要検証点だが、
> 既存機構の自然な延長。

### 2.3 動的 URL(pull せず inline `mcp.provide`)のスコープ

pull は compile-time なので **dynamic url は pull できない**。dynamic url は常に inline
`use mcp.provide(url = 実行時 string)`(minted toolbox + reflection 経路, `mcp_demo.ktr`)を通る。ここでは
ユーザーが per-URL の module marker を宣言できないので、**stdlib `mcp.provide` が組み込みの nullary marker
`mcp.scope` を保持**する。minted tool 値はそれを row に持ち、`provide` が discharge、runtime は
descriptor + close-on-exit(§1.3)で境界を張る。

現行の `scope[string]` 格下げと違い、**nullary marker には arg が無いので covariance の穴が最初から存在しない**。
dynamic 経路は今より**厳密に単純**になる(格下げも backstop の「型穴を塞ぐ」位置付けも不要、requires-live-provide が
素直な実境界)。

結果、経路は literal-vs-dynamic で綺麗に二分される(現行の二分と同じだが covariance 機構ゼロ):

| 経路 | scope identity | 逃亡不能 | runtime 境界 |
|---|---|---|---|
| pull(literal, 静的 `mcp.call`) | module-local `github.connection` | (a)空 handler / (b)(c) subtraction | requires-live-provide(descriptor) |
| inline(dynamic, minted + reflection) | 組み込み nullary `mcp.scope` | `mcp.provide` の subtraction | close-on-exit + requires-live(descriptor) |

### 2.4 2 モジュールの tools を混ぜて AI ループへ(effect union の合流)

`describe_tools[effect E](tools: array[agent never -> unknown with E])` に 2 モジュールの tool を混ぜる場合:

- **現行**: github tool `... | mcp.scope["gh"] | credentials_gh | ...`、slack tool `... | mcp.scope["sl"] | ...`。
  E は `... | mcp.scope["gh" | "sl"] | credentials_gh | credentials_sl | ...` に — **同名 `scope` entry の arg-union
  マージ**(§1.4 の面倒さの本体; covariant-arg-remainder 機構が要る)。
- **marker 案**: `... | github.connection | credentials_gh | ...` と `... | slack.connection | credentials_sl | ...`。
  E は `... | github.connection | slack.connection | credentials_gh | credentials_sl | ...`。**distinct な name の
  素な union**。arg マージ無し、covariant-remainder 無し。両 connect scope が開いている中でのみ配列が使える(正しい)。

→ marker 案は multi-module 合流を**単純化**する。§1.4 の「scope は union 側でなければ nest が壊れる」という
綴り注意は URL-keyed marker 固有の症状であり、**nullary distinct marker なら消える**(scope は素の name の集合として
共存、pin/merge の論点が発生しない)。`credentials` の overwrite 側要求(handler discharge のための pin)は marker とは
独立に残る。

### 2.5 stdlib `mcp.provide` は残るか(二層 API)

残る。二層になる:

- **stdlib `mcp.provide`**(汎用・dynamic・minted toolbox via reflection): 組み込み `mcp.scope`(nullary)を持つ
  汎用 API。§2.3 の dynamic 経路と、AI が実行時にサーバーを選ぶ「型付けできない」用途を担う。
- **pull 生成 `connect`**(静的・typed tools via `mcp.call`): module-local marker を宣言し、それを discharge。
  型付き tool の物語を担う。

`serve` は不変(`toolbox[string]` → `toolbox`。marker 案では tool の row に scope marker を持たない
「完全 handle 済み」agent が coerce される点は同じ — 素の name marker が無いだけ)。

### 2.6 表現力の得失(URL literal 型で得ていたもの)

- **保つ**: (i) 逃亡不能性(marker + discharge, 等価)。(ii) compile-time routing(URL literal は `mcp.call` の
  引数値として残る)。(iii) per-server の型レベル区別(per-URL → per-module。pull は 1 server = 1 module なので一致)。
- **失う(軽微)**: 型が `mcp.call` の **url 引数 == scope の url** を強制する不変式。marker 案では scope
  (`github.connection`)と url 引数(`"<url>"`)が**脱結合**する。生成コードは両者を同一 literal から焼くので
  実害なし、runtime の descriptor 一致検査が誤配線を typed に拾う。手書きコードでの型不変式 1 本の喪失だが、
  これは**むしろ狙い**(routing と lifetime の分離)であり、保証水準は現行 dynamic 経路と同じ。

---

## 3. credential との関係(別軸である)

pull binding には**三つの別概念**が混在しており、marker 案が触るのは 1 番だけである。

1. **scope marker**(`mcp.scope[URL]` → 提案 `github.connection`): **型レベルの lifetime / 逃亡 token**。
   identity は name。discharge は signature(または §2.2(a) の空 handler)。
2. **`credentials` request**(生成・module-local): 接続 auth を tool へ配る **ambient 供給チャネル**。`connect` が
   `use handler` で serve、tool は `credentials()` で読む。discharge は handler。
3. **`mcp.auth` 値**(`headers | oauth`)+ credentials core: 実際の**認証材料**。`oauth(name)` は
   project-scoped credential store(SoT, `docs/2026-07-14-credentials-core.md`)が解決する名前、
   `headers(values)` はヘッダ材料。

**marker と auth/credential は直交軸**である:
- marker = 「これらの tool は**どの scope の間**生きるか」(lifetime / escape)。**name identity**、型レベル、phantom。
- auth/credential = 「接続を**何で認証**するか」(header 材料 or 名前付き oauth credential)。**value identity**
  (name 文字列 or header 値)、runtime 値。

両者が交わるのは runtime の **descriptor = {url, auth}**(接続 cache/routing key, `descriptorKey`)だけ。しかし
descriptor は**両者の下流にある runtime 概念**で、marker(型)でも credential-name(値)でもない。

owner の問い「credential はまた別の概念か?」の答え: **YES、別概念**。統合すべきでない — 統合は lifetime と
authentication の再結合であり、それは marker 案が**解こうとしている conflation そのもの**(URL が routing と
scope を兼ねた §1.1)を別の形で復活させる。credentials core(認証状態の SoT)と scope marker(block 単位の
型レベル lifetime SoT)は別々の SoT として保つ。生成 `credentials` request(第 3 の ambient 供給チャネル)も別物で、
marker 案では**一切変更されない**。

---

## 4. 判定(owner 原則に照らして)

### 4.1 原則との整合

- **SoT**: 現行は URL literal を「型 scope」と「routing」の**共有 SoT**にしている(§1.1) — SoT 臭。marker 案は
  型 lifetime = marker(name)/ runtime routing = descriptor(値)に**分離**し、SoT が綺麗になる。**強く整合**。
- **一般機構 + データ / 抽象化(共通化ではない)**: marker effect は**既存の汎用機構**。提案はそれを再利用する。
  literal-generic + singleton + phantom-covariance + covariance-hole-backstop という**特化機構**は、grep 上
  stdlib では **mcp と scoped.ktr demo のみが消費者**(`[literal ...]` は他に無い)。mcp を marker へ移せば、この
  特化機構の一部(`Inference.hs` の covariant-arg-remainder、marker arg の covariant pin、literal-scope 経路)を
  **削除候補**にできる(要 consumer 確認、scoped.ktr は書き換え/退役)。**臨界的抽象を減らす**方向。整合。
- **if は直和 dispatch / control-flow**: covariance の穴(「型が塞げない唯一の穴」)と backstop の特殊 case 論法を
  **除去**。§1.4 の scope-on-union の綴り注意も消える。特殊 case が純減。整合。
- **書ける合成の効率化版(boundary 原則)**: scoped.ktr が示すとおり、runST scope は**ユーザーが書ける汎用機構**。
  boundary-doc の gap-ledger も「scope 型付け(runST) ✓」と済判定済み。mcp 組み込みはその scope 機構の
  **効率化/堅牢化版**(実接続 + descriptor backstop)に落ちる。URL-literal 結合より boundary 原則に忠実。整合。

### 4.2 推奨案

**採用を推奨**。具体形:

1. **scope identity を URL literal → module-local marker に移す**。pull 生成モジュールが `effect connection` を
   宣言、tools が row に `connection` を載せ、`connect` が discharge 境界。
2. **URL を素の `string` 引数に降格**。`mcp.call(url: string, auth, tool, arguments)`(scope 型を持たない)。
   runtime routing は descriptor(url + auth)で従来どおり。
3. **discharge は §2.2(a)**(marker を空 handler で discharge 可能にする)を第一候補、marker を非 handle に
   保ちたいなら **(b)**(汎用 `scope.enter[effect M]` primitive の昇格 = scoped.ktr の `with_resource` の
   marker-name 一般化)。
4. **dynamic 経路は stdlib `mcp.provide` + nullary `mcp.scope`** を残す(§2.3)。二層 API。

### 4.3 実装範囲

| 層 | 変更 | 規模感 |
|---|---|---|
| **compiler** | (a) `Check.hs:2295` の marker-handle 拒否を緩め、operation-ゼロ handler の discharge を実装(+ lowering で空 handler を消す)。もしくは (b)(c) の name-generic subtraction。**削除候補**: covariant-arg-remainder / marker-arg covariant pin / literal-scope 経路(要 consumer 確認)。 | 中(核心はここ 1 点) |
| **stdlib** | `mcp.ktr` 改修: `scope[URL]` → nullary `mcp.scope`(dynamic 用)、`provide`/`call`/`toolbox`/`tool` から `[URL]`/`[literal URL]` を除去、`call` は scope を row から落とす(or (b)(c) なら `[effect M]` 化)。 | 小〜中 |
| **codegen** | `McpCodegen.hs`: module ごとに `effect connection` を emit、`connect` は open + discharge、tools は `connection` を宣言し `mcp.call`(url 引数)を呼ぶ。**row 綴りが単純化**(scope の union-side 綴り理由が消える; credentials の overwrite は残す)。golden fixture 全書き換え、composition/round-trip test 更新。 | 中 |
| **runtime** | **ほぼゼロ**。routing(`descriptorKey`)・requires-live-provide・close-on-exit は descriptor 値ベースで型レベル scope を参照していないため不変。covariance-backstop の**コメント/位置付け**のみ更新(型穴の backstop → dynamic 経路の素直な実境界)。 | 極小 |

### 4.4 主要トレードオフ

- **得**: SoT 分離(lifetime ⊥ routing)、covariance の穴の**構造的消滅**、multi-module 合流の単純化、codegen row
  綴りの単純化、runtime 無改修、特化型機構の削除余地。
- **払う**: (i) compiler に「marker discharge」の一般化 1 点(marker を handle 可能にする、または name-generic
  subtraction)。(ii) 「url 引数 == scope url」の型不変式 1 本の喪失(生成コードでは無害、runtime が拾う。むしろ
  分離の狙いどおり)。(iii) marker を非 handle とした現行判断を緩める設計決定(owner 確認要)。
- **要検証**: (b)(c) を採るなら name-generic marker subtraction の型システム上の成立(§2.2 脚注)。(a) を採るなら
  空 handler discharge の lowering(phantom なので消えるはず)と、既存 marker 利用箇所(scoped.ktr)への影響。

### 4.5 関連

- 現行スコープ設計の詳細: `docs/2026-07-11-mcp-provide.md`(phantom marker + covariance + backstop)、
  `docs/2026-07-10-mcp-pull.md`(3 層 + 型マッピング)。
- 汎用 scope 機構の既存 demo: `examples/playground/src/scoped.ktr`(`with_resource` = 本案 (b) の原型)。
- boundary 原則と gap-ledger: `docs/2026-07-16-katari-boundary.md`(「組み込み = 書ける合成の効率化版」)。
- credentials core(auth 軸の SoT): `docs/2026-07-14-credentials-core.md`。
