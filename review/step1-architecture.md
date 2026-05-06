# Step 1: 全体アーキテクチャとデータ構造の把握

調査対象:
- [Katari.Compile](../haskell/katari-compiler/src/Katari/Compile.hs) (179 行)
- [Katari.AST](../haskell/katari-compiler/src/Katari/AST.hs) (1436 行)
- [Katari.Diagnostic](../haskell/katari-compiler/src/Katari/Diagnostic.hs) (183 行)
- [Katari.Id](../haskell/katari-compiler/src/Katari/Id.hs) (68 行)
- [Katari.SemanticType](../haskell/katari-compiler/src/Katari/SemanticType.hs) (211 行)
- [Katari.IR](../haskell/katari-compiler/src/Katari/IR.hs) (738 行)
- [Katari.SourceSpan](../haskell/katari-compiler/src/Katari/SourceSpan.hs) (30 行)
- [Katari.Internal](../haskell/katari-compiler/src/Katari/Internal.hs) (30 行)

## 美しい設計点

### 1. 完全 pure な単一エントリ ([Compile.hs:123-160](../haskell/katari-compiler/src/Katari/Compile.hs#L123-L160))

`compile :: CompileInput -> CompileResult` は理想形。`Map ModuleName SourceEntry` を入力に受け取り、IO ゼロで全 phase を実行する。LSP / CLI / playground / test が同じエントリを共有できる。phase ごとに独自エラー型を持ちつつ最終的に統一 `Diagnostic` に集約する設計も、デバッグ性と外部 UX の両立としてクリーン。

### 2. Trees-that-Grow の Haskell 流実装 ([AST.hs:77-103](../haskell/katari-compiler/src/Katari/AST.hs#L77-L103))

- `NameRefResolution :: Phase -> NameRefKind -> Type` を**閉じた type family** にすることで全 phase + kind の組合せを 1 ヶ所で網羅。
- `NameRefKind` で「変数 / 型 / モジュール / ラベル / req / data ctor」の 6 名前空間を**型レベルで分離**。これにより `RequestRef` slot に variable id を入れるコードはそもそもコンパイルが通らない (K0108 / K0109 の type-level reject)。
- `Identified` / `Constrained` / `Zonked` の 3 phase が同じ `Maybe Identifier` shape を返すおかげで `retagNameRef` で素通しが書ける ([AST.hs:1020-1029](../haskell/katari-compiler/src/Katari/AST.hs#L1020-L1029))。

これは Trees-that-Grow の通例 (12 type families) より圧倒的に boilerplate が少ない。

### 3. 二層 ID 体系 (AST 5 種 + IR 4 種 + `QualifiedName`)

- AST 側 `VariableId` / `TypeId` / `ModuleId` / `RequestId` / `ConstructorId` ([Id.hs](../haskell/katari-compiler/src/Katari/Id.hs))
- IR 側 `BlockId` / `VarId` / `ReqId` / `CtorId` を **Lowering で再発行** ([IR.hs:107-123](../haskell/katari-compiler/src/Katari/IR.hs#L107-L123))
- `IRModule.entries :: Map QualifiedName BlockId` のみが FFI 名前解決の SSoT、逆引きは runtime が load 時に 1 周走査して構築。

「IR の内部 dispatch」と「FFI 公開境界」を意図的に分離することで、IR の id 割り当てを変えても外向き API が壊れない。これは Production Ready の観点で非常に良い分離。

### 4. Diagnostic の API 設計 ([Diagnostic.hs](../haskell/katari-compiler/src/Katari/Diagnostic.hs))

- `Severity` の `Ord` を活用した `filterAtLeast` / `hasErrors`
- 安定 4 桁 code (`K####`) を phase レンジで分割
- `notes` (関連スパン) と `hints` (アクション提案) の分離は LSP の `relatedInformation` / `codeAction` に直接マップする
- `Render` を別モジュールに切ってあるので、LSP は snippet なし版を、CLI は snippet 付きを選べる

## 懸念点 / 改善案

### 【高】IR.hs の `Block` フィールド名が不統一 ([IR.hs:244-285](../haskell/katari-compiler/src/Katari/IR.hs#L244-L285))

```haskell
BlockUser :: {body :: UserBlock} -> Block
BlockMatch :: {matchBlock :: MatchBlock} -> Block
BlockFor :: {forBlock :: ForBlock} -> Block
BlockHandle :: {handleBlock :: HandleBlock} -> Block
BlockTuple :: {tupleBlock :: TupleBlock} -> Block
```

- `BlockUser` だけ `body`、他は `matchBlock` / `forBlock` のように接頭辞重複
- どちらかに統一すべき (推奨: 全部 `body` で統一して JSON 表現も「contents 化」)
- これは JSON の互換性を破る変更なので runtime 再設計の今がやり時

### 【高】`CompileResult` 内 `Maybe` の使い分けが不整合 ([Compile.hs:93-112](../haskell/katari-compiler/src/Katari/Compile.hs#L93-L112))

```haskell
identifierResult :: Maybe IdentifierResult,  -- "Always returned" と doc にある
solverResult     :: Maybe SolverResult,       -- 同上
zonkResult       :: Maybe ZonkResult          -- 同上
```

docstring が「Always returned」と言っている 3 フィールドは型上 `Maybe` の必要がない。実装でも常に `Just` を返している ([Compile.hs:157-159](../haskell/katari-compiler/src/Katari/Compile.hs#L157-L159))。`Maybe` を外して呼び出し側の defensive な `fromMaybe` を不要にできる。

### 【中】`ImportDeclaration` の phase パラメータが無意味 ([AST.hs:185-200](../haskell/katari-compiler/src/Katari/AST.hs#L185-L200))

`ImportDeclaration phase` は `ImportKind + SourceSpan` のみで phase 依存フィールドゼロ。`retagImportDeclaration` というヘルパが必要になっている時点で、最初から phase なしにすべき。`Declaration phase` の sum tag 内で phase を消費しないコンストラクタを許す形に。

### 【中】`Internal.error` でのパニック ([Internal.hs:21-24](../haskell/katari-compiler/src/Katari/Internal.hs#L21-L24))

```haskell
internalError :: SourceSpan -> Text -> a
internalError location msg = error (...)
```

LSP / playground の long-running プロセスでは `error` は致命的。最低限「invariant violation」を `Diagnostic` (severity = Error, code = K9999) に変換して fail-soft する経路を用意したい。Production Ready の文脈では `error` の各使用箇所を監査する必要あり (後の step で grep する)。

### 【中】`QualifiedName` / `LiteralValue` の AST/IR 二重定義

- `Katari.Id.QualifiedName` と `Katari.IR.QualifiedName` ([IR.hs:130-166](../haskell/katari-compiler/src/Katari/IR.hs#L130-L166))
- `AST.LiteralValue` と `IR.LiteralValue`

理由は分かる (IR は JSON 表現が違う、LiteralValue は IR が AST に依存しない設計のため)。しかし命名が同一だと grep / IDE 補完で混乱する。「IR が AST に依存しないという制約は本当に必要か?」を再考すべき。Lowering は両方を import するので結局 dependency graph で繋がる。代案:

- IR 側を `IRQualifiedName` / `IRLiteralValue` にリネーム
- もしくは `Katari.Common.QualifiedName` / `Katari.Common.LiteralValue` に統合し、JSON 表現は `newtype` ラッパで差別化

### 【低】AST.hs の standalone deriving 量が多い (~330 行が deriving) ([AST.hs:1111-1436](../haskell/katari-compiler/src/Katari/AST.hs#L1111-L1436))

70 箇所の `deriving instance (EqPhase p) => Eq (Foo p)`。`QuantifiedConstraints` で `EqPhase` / `ShowPhase` を集約しているので「前置きはマシ」だが、TH 自動生成や `Generically` newtype を併用してさらに圧縮できる余地あり。ただし可読性とのトレードオフなので、現状でも許容範囲。**むしろ `Eq`/`Show` は本当に全ノードで必要か?** test 用なら test モジュール側で derive する手もある (production lib のサーフェスから外す)。

### 【低】`hasErrors` を 2 回呼んでいる ([Compile.hs:142-149](../haskell/katari-compiler/src/Katari/Compile.hs#L142-L149))

```haskell
shouldLower = not (hasErrors preLowerDiags)
shouldEmitArtefacts = shouldLower && not (hasErrors loweringDiags)
```

微小だが、`preLowerDiags` を 1 回スキャンして集約すれば 1 回で済む。気にするほどではないが、こういう「小さなだらしなさ」が production 品質を下げる。

### 【要確認】`Word32` vs `Int` の使い分け

IR は `Word32` ([IR.hs:97-123](../haskell/katari-compiler/src/Katari/IR.hs#L97-L123))、AST/SemanticType は `Int`。JSON 表現の自然さや 32-bit overflow を考えれば `Word32` は妥当だが、AST 側との混在による implicit conversion がコード中にないか後段で確認する。

## ここまでの全体評価

総じて**設計の骨格は非常にしっかりしている**。特に以下 3 点は OSS としても誇れる水準:

1. Trees-that-Grow を closed type family + `NameRefKind` で実用化
2. 5+4 ID 体系と `QualifiedName` 境界の二層分離
3. Pure pipeline + 統一 Diagnostic + 安定 code

OSS Production Ready を妨げる **show-stopper はまだ見つかっていない**。改善は主に「些末な不整合の解消」「`Maybe` 過剰利用の削減」「panic 経路の整理」で対応可能。

## 後段で追跡すべき未解決事項

- [ ] `internalError` の使用箇所一覧 → fail-soft 化の優先度判定
- [ ] `Word32 ↔ Int` 変換が implicit に発生していないか
- [ ] `Eq`/`Show` instance がライブラリ外部からどれだけ使われているか (test スコープに移せるか)
- [ ] `entries` Map の lookup 性能 (公開 API が呼ぶ頻度次第で `HashMap` 検討)
