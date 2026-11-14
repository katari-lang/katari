# Katari Compiler — Generics 推論 設計 (v0.1.0, scrap-and-build)

> **状態: 全面実装済 (2026-06-20)。408 例 green。** **すべての generics 推論を一つの統一機構**
> （単一サイト `collectConstraints` → `solveConstraints` → 代入 → 信頼できる既存 `subtype` で dispose）に
> 載せた。`subtype` は一切変更していない (metavar-aware フラグなし)。propose は別関数 `collectConstraints`
> (新モジュール `Katari.Typechecker.Inference`)。健全性は触っていない既存 `subtype` が担保。
>
> 統一機構が扱う client（すべて単一サイト）:
> - **call / 演算子 / 一般 generic 呼び出し**（§6.1）— 引数 vs param。
> - **`use` provider の継続駆動推論**（§6.1b）— 継続引数の戻り型/効果から。
> - **constructor pattern**（§6.5）— scrutinee の data 引数から binder を型付け（旧 binder=never バグ修正）。
> - **request handler の generics**（§6.6）— param 注釈から導出（return-only は明示要求）。
> - **effect / attribute の generic**（§6.7）— `runWith[effect E]` 等。`collectConstraints` を type だけでなく
>   effect-tail / attribute にも拡張。continuation の overwrite `{...E, foo[..]}` は handled を落として E を推論。
> - **handler は generic 値**（§6.2）— `∀R E. agent({continuation: agent({value:null}) -> R with {...E,handled}})
>   -> (⋃break | then(R)) with (E | bodyEffect)`。**bare `handler{...}` は適用がないので推論不可＝K3015**、
>   `handler[R,E]{...}` は明示適用、`use handler{...}` = `(handler{...})(continuation)` の適用で R/E を継続から推論。
>   body は R/E rigid で検査。ad-hoc な accumulator は撤去。`then` は R→R' 変形、break/tail は then をバイパスし
>   break union に。
>
> Typechecker に **呼び出し位置での generic 引数推論** を入れる。フルスペック (HM) は入れず、
> 局所・引数駆動のローカル推論にとどめる。明示 `[...]` は escape hatch として常に残す。
>
> **動機は「演算子が今エンドツーエンドで壊れている」こと。** 演算子は Identifier パスで
> generic primitive 呼び出しに desugar 済み (`a + b` → `primitive.add[T extends number](left=a, right=b)`)
> なのに、呼び出し側に推論が無いため `1 + 1` が **K3015 (generic not applied)** で落ちる。
> handler[R,E] の明示必須・ユーザ generic agent 呼び出しも同じ穴。これら 3 つは全部
> 「call-site で型引数を推論する」一つの問題に帰着するので、一本の機構で解く。

---

## 0. 背景 — 確認した事実

実 pipeline (stdlib `primitive` を splice、`defaultImports = [primitive]`) で確認:

```
1 + 1                          → ["K3015","K3014"]   -- generic 未適用で落ちる
primitive.add[integer](...)    → []                  -- 明示適用なら通る
```

- 演算子は `Identifier/Expression.hs:resolveBinaryOperator` で `primitive.<name>(left=, right=)` に
  desugar される。Lowering は演算子ノードが残ると panic する (`Lowering.hs:642`)。つまり
  **実プログラムの演算子は Identified 以降「ただの generic 呼び出し」**。
- `Check.hs:synthBinaryExpression` / `synthUnaryExpression` の手書き型付け
  (`integer+integer→integer` 等) は、`ExpressionBinaryOperator` を直接構築する CheckSpec 単体テストでしか
  到達しない **デッドコード**。`primitive.ktr` の署名 (`add[T extends number](left:T,right:T)->T` 等) と
  二重管理になっている。
- `Check.hs:instantiateBare` が「generic 値を裸で使ったら K3015」を出すゲート。call-site での唯一の障害物。

→ この設計で `instantiateBare` の call-site 役割を「推論」に置き換える。`synthBinaryExpression` は削除し、
演算子の型付けの単一の真実を `primitive.ktr` の署名にする。

## 1. スコープ / 非ゴール

決定事項 (ユーザ確認済み):

- **方向**: 引数駆動のみ。実引数 / handler body から型変数を解く。return-only 型変数は明示 `[...]` を要求
  (push-down は v1 では入れない)。
- **対象**: 演算子 + handler[R,E] + 一般 generic 呼び出し (ユーザ定義 generic agent / combinator)。
- **成果物**: 本ドキュメント → 実装。

非ゴール (意図的な限界):

- `let` の generalization (局所変数は monomorphic のまま)。
- 期待型 push-down (Phase 3 候補)。
- higher-rank / impredicative / global unification。
- constructor pattern / data 適用の推論 (Phase 3 候補。注釈位置に出がちで明示でも実害が小さい)。

## 2. 全体構造 — propose / dispose 二相

推論は **候補を提案する相** と **正しさを確定する相** に明確に分ける ("inference proposes, checking disposes")。

```
(1) propose  : inference-mode subtype で制約 (lower/upper) を収集。寛容・近似・診断 OFF。
(2) solve    : 暫定候補を作る (lower 群の join 等)。canonical である必要はない。
(3) subst    : 候補を「元の generic scheme 本体」に既存 substitute* で代入し具体型にする。
(4) dispose  : flexible 集合=空・診断 ON の通常 subtype を具体型に対して回す。これが採否と
               本物の診断 (具体型での K3001 等) の唯一の権威。
```

### なぜ二相か — shadowing で metavar を一意表現できない

metavar の解は **暫定 (候補)** にすぎず、正しさは「解を代入してから通常 subtype」で初めて確定する。
収集した制約表現を直接突き合わせて採否を決めてはいけない。**shadowing が絡むと metavar を単独の
正規表現として一意に持てない**ため:

- **effect の tail / lacks** (`{...E, req}` のオーバーライド shadowing): 同じ effect metavar が位置ごとに
  `restrictEffect` で違う形に展開される (`Normalizer.hs:restrictEffect` / `boundedEffect`)。単独の
  「E の値」を作って比較すると lacks の扱いを誤る。`substituteEffect` → 通常 effect subtype に通せば
  文脈整合で正規化される。
- **generic の shadowing / ネスト**: 同一 `GenericId` が scope 違いで別物を指し得る。収集した制約表現の
  直接比較は危険。代入して再正規化すれば一意。
- **attribute generic**: 実効値が比較時の `world` join に依存する (`NormalizedAttribute` subtype は world を
  両辺に join する)。収集時の bound と代入後 check で形が変わり得る。

**帰結**: 収集相の subtype は厳密でなくてよい (ヒント収集に徹する)。健全性は **触らない既存の `subtype`** が
担保する。取りこぼしても最悪「推論不能」か dispose の失敗になるだけで、**不健全には絶対にならない**。
これは実装リスクを大きく下げる。

## 3. metavar の表現

- metavar = **fresh な `GenericId`**。型表現の `NormalizedType.generics :: Set GenericId`・
  `EffectRow.tails`・`NormalizedAttribute.generic` に rigid generic と同一表現で載る。
  `substituteType` / `substituteEffect` / `substituteAttribute` がそのまま置換できる。
- 採番: `GenericId inferenceModuleName n`。`inferenceModuleName` は予約合成モジュール名 (例 `<infer>`)、
  `n` は `CheckerState` に足すカウンタ。real module 名を持つ rigid id と決して交わらず、同一式で
  scheme を 2 回 instantiate しても衝突しない。metavar は 1 つの呼び出しに閉じ、dispose 前に必ず
  substitute されるので外へ漏れない。
- 区別は「flexible 集合に入っているか」だけ。`GenericParameterInformation` の bound・kind・variance は
  instantiate 時に登録簿へ写す。

## 4. 収集相 = 別関数 `collectConstraints` (subtype は不変)

**当初案の「`subtype` に `flexibleGenerics` フラグを足す」は採らなかった** (実装時に変更)。代わりに
`subtype` と構造が似た独立関数 `collectConstraints` を新モジュール `Katari.Typechecker.Inference` に
書いた。`subtype` (`Katari.Typechecker.Normalizer`) は 1 行も変えていない。これにより健全性リスクが
収集相に漏れず、推論ロジックを単体テストできる。

- 制約は値として返す (Normalizer の state は使わない):

  ```haskell
  collectConstraints :: Set GenericId -> NormalizedType -> NormalizedType -> Normalizer Constraints
  data Constraints = Constraints                 -- Monoid (Map.unionWith (<>))
    { typeBounds      :: Map GenericId (BoundSet NormalizedType)       -- (lowers, uppers)
    , effectBounds    :: Map GenericId (BoundSet NormalizedEffect)     -- v1 未使用
    , attributeBounds :: Map GenericId (BoundSet NormalizedAttribute)  -- v1 未使用
    }
  ```

- variance 方向の構造マッチ (function 引数は反変=左右入替、data 引数は宣言 variance、object/sequence は
  既存 `alignObjectFields`/`alignSequenceItems` を再利用)。leaf では「どちら側に bare metavar が出たか」だけ見る:
  - parameter (supertype) 側に bare metavar → **lower** bound (実引数側) を記録。
  - actual (subtype) 側に bare metavar → **upper** bound を記録。
  - 「bare」= instantiate が置いた `base=never, generics={M}, attr=⊥` の形 (`asTypeMetavar`)。
- 理解できない形は `mempty` (近似)。**診断は一切出さない** — 関数が `subtype` を呼ばないので、捨てるべき
  エラーがそもそも生じない (当初案の `captureErrors` は不要になった)。
- v1 は **type metavar のみ**。effect/attribute metavar (effect/attribute を量化する稀な scheme) は
  制約が付かず「推論不能」(K3016) → 明示 `[...]`。handler の E は metavar ではなく accumulator
  (§6.2、既存 `withEffectInference`) で解くので問題なし。

## 5. solver

`solveConstraints :: Registry -> Constraints -> Checker Substitution`。

- **type 変数**: 候補 = lower 群の `union` (join = 最小の共通上界 = 共変解)。lower が無ければ
  upper の `intersect` / 宣言 bound にフォールバック、それも無ければ **推論不能** (§7)。
  - 宣言 `extends` bound の検査・upper との整合は **solver 自身では確定しない** — dispose に委ねる。
- **effect 変数** (handler E): lower 群の `union`。tails の整合は dispose の effect subtype 任せ。
- metavar 同士の依存 (`M <: N` = N の lower に M が、M の upper に N が入る) は **worklist で lower を
  伝播**し fixpoint。単調 join なので停止。
- 解は暫定。canonical 化しない (§2 の理由)。
- 一意な解にならない位置 (lower も無く期待型 upper も無い純粋に phantom な変数) のみ推論不能。
  **演算子はオペランドで、handler は body で全変数が必ず拘束される**ので対象 2 ケースは曖昧化しない。

## 6. クライアント

### 6.1 一般 generic 呼び出し — `synthCallExpression`

現状 `synthExpression expression.callee` が generic callee で `instantiateBare` → K3015。これを:

1. callee が **generic 値参照** のとき `synthApplicationCallee` で `Scheme` を取得 (既存関数、`ExpressionTypeApplication` が使うのと同じ)。
2. scheme の generic を fresh metavar に instantiate (`substituteType` で開いた function 型に)。flexible 集合と登録簿を構築。
3. 引数を `synthCallArguments` で synth → `runInference` で `subtype argObject openParamObject` (propose、診断 OFF)。
4. `solveConstraints` → `substituteType` で開いた return/param を具体化 → **dispose**: 通常 `subtype argObject solvedParamObject` + 宣言 bound 検査 (`checkGenericBounds`)。
5. 効果は既存 `applyAgent` の規律 (pure-lift / `T<:W` / effect 再放出) を **dispose 後の具体型** に適用。
6. Typed AST には解いた引数を `instantiation`（既存 `instantiationOf` 経由）として記録 → lowering が消費。

非 generic callee は従来の高速路 (`extractFunction` → `applyAgent`) のまま。明示 `[...]` (`ExpressionTypeApplication`) は override として温存。call と `use` は共通の `applyCallee`（generic/mono を分岐）に通す。

### 6.1b use provider の継続駆動推論 — `handleUseStatement`

`use foo` は `foo(continuation = agent({value: A}) -> R_enclosing with E')` への適用に desugar される
（`R_enclosing` = 囲みの return target）。これを **6.1 と同じ `applyCallee` に通す**ことで、provider が
継続結果に generic な場合（例 `foo[R](continuation: agent(value: int) -> R) -> R`）、`collectConstraints`
が継続引数の **戻り型 (covariant)** から `R` の lower bound `R_enclosing` を拾い、`R = R_enclosing` を推論する。
これは push-down ではなく**引数駆動**（継続は引数）なので既存機構で解ける。handler に限らず任意の generic provider に効く。

### 6.2 handler[R, E] — `synthHandlerExpression`（accumulator 方式 + then 変換）

`R` / `E` は handler の **generics**（外から与えられる）。`R` は **handle 対象（継続）の計算結果**であり、
handler の body とは独立 — call/use 時に継続の戻り型から推論される（`⋃ body tail` と等しいとは限らない）。
handler の結果に流れ込むチャネルは `ResultChannels { normalChannel, escapeChannel }`（`for` と共有）で集める:

- **body tail（暗黙 break）** → `normalChannel`。handler が resume せず返す値なので、明示 break と同様に **`then` を
  飛ばして**結果へ直接 union する。`R` とは照合しない（`emitHandlerTailType` で集約するだけ）。
- **明示 `break e`** → `escapeChannel`。同じく `then` を**飛ばして**結果へ直接 union（`for` の break と一貫）。
  `break` は `R` と照合しない（`HandleContext` に `handlerResultType` は無い、`emitHandlerBreakType` のみ）。
- **`then(r){...}`** : binder `r : R`（継続結果）、body は自由に synth → **R'**。`then` body の `<: R` 強制は無く、
  `then` は継続結果 `R` のみを変形する（body tail / break は経由しない）。

戻り値の式:

```
handler 結果 = (⋃ break) | (⋃ body tail) | (then ? then body(R') : R)
continuation 戻り型 = R
handler 型 = agent({continuation: agent({value:null}) -> R with E∪handled}) -> 上記結果 with E
```

- 明示 `handler[R, E]`: `R` は継続結果として固定、`break` / body tail の union は別途集約、結果は
  `(⋃ break) | (⋃ body tail) | (then ? R' : R)`。`E` は明示（body 効果・then 効果を `<: E` で検査）。
- 省略 `handler { ... }`: `R` / `E` は rigid generic として body を検査し、call/use 時に継続から推論。
- 縁ケース: body が全て break/発散で tail 無し → `normalChannel = never`（健全・最も許容的）。

> NOTE（IR/lowering 整合）: `then` は **handle body の正常完了（= `k()` の戻り = R）のみ**を変形する。body tail /
> 明示 break は `OperationExit{target=handle}` で handle を脱出し、`then` を経由せず結果になる。runtime は handle への
> exit に `thenClause` を適用してはならない（適用すると Model A になり checker と矛盾）。`IR.hs` の「then は handle
> target の結果を受け取る」は「handle body の正常完了 R」の意であり、break 値ではない。

### 6.3 演算子

6.1 の自動的帰結。`a + b` は `primitive.add(...)` なので 6.1 がそのまま効く。

- `synthBinaryExpression` / `synthUnaryExpression` と Typed-AST の `ExpressionBinaryOperator`/`UnaryOperator`
  経路を **削除**。CheckSpec の演算子単体テストは call 経路 (program レベル) に書き換える。
- 署名から旧手書き表が再現されることを確認済み:

  | 式 | 署名 | 推論 | 結果 | 旧 bespoke |
  |---|---|---|---|---|
  | `1 + 1` | `add[T extends number]` | `T = join(int,int) = int`、`int<:number` OK | `int` | `int` ✓ |
  | `1 + 1.0` | 同上 | `T = join(int,number) = number` | `number` | `number` ✓ |
  | `1 + "x"` | 同上 | `T = int|string`、`<:number` **失敗** | K3001 | string⊄number で K3001 ✓ |
  | `4 / 2` | `divide(number,number)->number` (非 generic) | — | `number` | `number` ✓ |
  | `1 == "x"` | `equal[T]` (bound 無) | `T = int|string`、bound 無 | `boolean` | `boolean` ✓ |
  | `1 < "x"` | `less_than[T extends number]` | `T<:number` 失敗 | K3001 | K3001 ✓ |

### 6.4 ユーザ generic agent / combinator

6.1 と同一。`identity(value=1)` は `a = int` を解いて通る (現状 K3015)。`map(f, xs)` 等の combinator も
引数から型変数が決まる範囲で `[...]` 不要に。決まらない return-only 変数は明示要求 (§7)。

## 7. 診断

- **K3015 (`reportGenericNotApplied`)** は call-site では原則撤退 (推論が引き受ける)。真に裸の参照
  (call/handler でない位置に generic 値がそのまま出る) のみ残す。
- **新コード「型引数を推論できない」**: lower も upper も無く一意に決まらない変数。メッセージで明示
  `[...]` を促す。`Katari.Error` に追加。
- dispose で出る型不一致は従来の **K3001** (具体型) のまま。

## 8. 実装タッチポイント (実装済)

- `Katari/Data/Id.hs`: `inferenceModuleName` (予約名 `<infer>`) を定義。
- **`Katari/Typechecker/Inference.hs` (新規)**: `Constraints`/`BoundSet`/`Metavar`/`Registry`/
  `SolveResult`、`metavarKinded`、`collectConstraints` (propose)、`solveConstraints` (solve, fixpoint)、
  `deepGenerics`、`checkSolvedBounds` (dispose の bound 検査)。すべて `Normalizer` 上。**`subtype` は不変。**
- `Katari/Typechecker/Normalizer.hs`: **変更なし** (`alignObjectFields`/`alignSequenceItems` 等を再利用)。
- `Katari/Typechecker/Context.hs`:
  - `CheckerState` に metavar カウンタ + `freshGenericId`。
  - `HandlerAccumulator { tailResults, escapeResults }` + `withHandlerResultInference` /
    `emitHandlerTailType` / `emitHandlerBreakType`。
  - `HandleContext` から `handlerResultType` を撤去（break は R と照合しなくなった）→ `newtype`
    （`currentRequestReturnType` のみ）。
- `Katari/Typechecker/Check.hs`:
  - `applyCallee`（generic/mono 分岐）を `synthCallExpression` と `handleUseStatement` で共有。
    `applyGenericValue` (instantiate→propose→solve→subst→dispose) / `applyMonomorphicCallee` /
    `instantiateToMetavars`。
  - `handleUseStatement`: provider を `synthApplicationCallee` + `applyCallee` に変更（継続駆動推論、§6.1b）。
  - `synthHandlerExpression` / `walkRequestHandler` / `walkHandlerThenClause` / `elaborateHandlerGenerics`:
    明示 [R,E] / 省略=推論、tail/break を分離、then は R→R' 変形（body の `<: R` 撤廃）。
  - `synthBinaryExpression` / `synthUnaryExpression` を削除、dispatch は panic (desugar 済みのはず)。
  - `checkBreakStatement`: 常に `emitHandlerBreakType` に集約（R と照合しない）。
- `Katari/Error.hs`: K3016 `TypeErrorCannotInferGeneric`。K3015 のメッセージを「call site でのみ推論」に更新。
- `package.yaml`: `Katari.Typechecker.Inference` を exposed-modules に追加。

### lowering についての確認

`lowerCall` は callee 名で delegate するだけで instantiation を読まない。よって **generic call 推論は
lowering に何も足さなくてよい** (推論した型引数は IR に乗せない)。get_metadata の schema 特殊化が要る場合のみ
明示 `[...]` (= `OperationApplyGenerics`)。handler は従来どおり `typeOf` から schema を作る (R/E 推論を反映)。

## 9. フェーズ (実績)

- **Phase 1+2 を一括実装**: Inference モジュール + solver + 6.1 call 推論 (演算子含む) + 6.1b use provider の
  継続駆動推論 + 6.2 handler R/E（then 変形・break バイパス）。bespoke 演算子削除。394 例 green。
- **Phase 3 (未着手・任意)**: 期待型 push-down (`checkExpression` に本物の check 経路)、
  constructor/pattern 推論、effect/attribute metavar の収集。

## 10. テスト (実装済: `test/Katari/Typechecker/InferenceSpec.hs` ほか)

- 演算子エンドツーエンド (stdlib splice): `1+1=integer`、`1+1.0` の widen と `->integer` での K3001、
  `divide`/`concat` の非 generic、`==` の任意ペア、`<`/`+`/`negate` の number bound 違反 K3001、`!`/`-`。
- 一般 generic call: `identity(value=1)` 推論、明示 `[integer]`、array 要素からの推論、bounded の充足/違反、
  返り値ミスマッチ K3001。
- **use provider 継続駆動推論**: `use foo[R]` で継続戻り型から R 推論、binder 型不整合 → K3001。
- **should-fail**: phantom 変数 → K3016、裸の generic 参照 → K3015、bound 違反 → K3001、
  then binder の注釈が R を受けない → K3001。
- handler 省略形の R/E 推論 (break 値・implicit-break tail・effect)、明示 [R,E] 維持、then は変形（body が R と
  異なってよい）、break が then をバイパス、then binder 注釈 K3001、arity 1 → K3009。CheckSpec で
  then 変形の結果型（R'）を精密アサート。
- white-box: `collectConstraints` (object/array/2 占有/非該当)、`solveConstraints` (単一/join/未拘束/依存)、
  `deepGenerics`。

## 11. 代替案と却下理由

- **手書き演算子を残し handler だけ accumulator 推論**: 安いが、実 pipeline で演算子は generic call に
  desugar 済みで bespoke は **到達不能** (実プログラムは現状壊れている)。一般 generic call も未解決のまま。
  二重管理も残る。却下。
- **フル HM / 等式 unification 変数を全面導入**: `let` 越え推論まで効くが、subtype ベース (不等式) の本
  lattice と相性が悪く、規模も非ゴール「フルは入れない」に反する。却下。
- **演算子だけ checker で特別扱い (primitive 署名を引いて T=join(operands) をハードコード)**: bespoke の
  再実装に近く、handler / ユーザ generic を助けない。汎用機構の方が総コストが小さい。却下。
- **収集した制約だけで採否を確定 (dispose を省く)**: §2 の通り shadowing で metavar を一意表現できず
  不健全になり得る。却下 (propose/dispose 二相が前提)。
