# Step 3: 既存ライブラリ活用と車輪の再発明の排除

## 結論

全体としては **Haskell エコシステムを適切に使えている** が、3 箇所に明確な「車輪の再発明」と 3 つの「未使用依存」が見つかった。修正は局所的で、breaking change なしに片付く。

## 既に十分活用できているライブラリ

| ライブラリ | 用途 | 評価 |
| --- | --- | --- |
| `Data.Map.Strict` | 全 phase の symbol table / IR table | ✓ Lazy 版を一切使っていない |
| `Data.Set` | constraint set / scope tracking | ✓ |
| `aeson` (`genericToJSON` / `TaggedObject` / `UntaggedValue`) | IR / Diagnostic JSON | ✓ 75 箇所、mature な使い方 |
| `megaparsec` (custom Stream / VisualStream / TraversableStream) | Lexer の token stream | ✓ 教科書通り |
| `parser-combinators` (`Control.Monad.Combinators.Expr.makeExprParser`) | 演算子優先順位 | ✓ |
| `mtl` (`ReaderT`, `State`) | Identifier / ConstraintGen / Lowering monad | ✓ 具体型を明示 (典型的に良いプラクティス) |
| `Data.Functor.Const` | `foldVariable` の fold-via-traverse | ✓ エレガント ([SemanticType.hs:211](../haskell/katari-compiler/src/Katari/SemanticType.hs#L211)) |

## 車輪の再発明 (修正推奨)

### 【高】Tarjan SCC を手書き ([ImportGraph.hs:51-83](../haskell/katari-compiler/src/Katari/Typechecker/ImportGraph.hs#L51-L83))

50 行のミニ Tarjan 実装。コメント自身が認めている:

```haskell
-- | Minimal Tarjan implementation. Not optimised for large graphs (we
-- expect <1000 modules) but stable and dependency-free.
strongComponents :: Map ModuleName (Set ModuleName) -> [ModuleName] -> [[ModuleName]]
```

**`containers` は既に dependency**。`Data.Graph.stronglyConnComp` が直接使える:

```haskell
import Data.Graph (SCC (..), stronglyConnComp)

findImportCycles :: Map ModuleName (Module Parsed) -> [[ModuleName]]
findImportCycles modules =
  let edges = [(name, name, Set.toList imports)
              | (name, mod_) <- Map.toList modules
              , let imports = importsOf mod_]
   in [vs | CyclicSCC vs <- stronglyConnComp edges]
       <> [[v] | (v, _, succs) <- edges, v `elem` succs]  -- self-loops
```

これで 50 行 → 10 行。`containers` 内部実装は十分に最適化されている (libraries/containers/src/Data/Graph.hs)。

### 【中】手書きの `(!?)` ([Render.hs:111-115](../haskell/katari-compiler/src/Katari/Diagnostic/Render.hs#L111-L115))

```haskell
-- | Safe list index.
(!?) :: [a] -> Int -> Maybe a
[] !? _ = Nothing
(x : _) !? 0 = Just x
(_ : rest) !? n = rest !? (n - 1)
```

`safe` は既に dependency。`Safe.atMay` で 1 行に置換可能。

さらに重要な点: **`renderSnippet` で `Text.lines source` から List indexing で目当ての行を取得**しているため、毎回 O(n) スキャン。複数 diagnostic がある場合は累積的に遅い。

```haskell
-- 現状 (Render.hs:88-90)
let sourceLines = Text.lines source
    lineIndex = sourceSpan.start.line - 1
    line = fromMaybe "" (sourceLines !? lineIndex)
```

ファイル単位でキャッシュすれば毎回 `Text.lines` を呼ばずに済む。LSP / CLI で複数の diagnostic を 1 ファイル内で持つケースがあるならここは要修正。Vector で素直に index access。

### 【高】`Data.List.nub` (O(n²)) を Solver hot path で使用 ([Substitution.hs:269-270](../haskell/katari-compiler/src/Katari/Typechecker/Solver/Substitution.hs#L269-L270))

```haskell
let solvedLowers = nub (filter containsNoTypeVars ((.boundType) <$> lowers))
    solvedUppers = nub (filter containsNoTypeVars ((.boundType) <$> uppers))
```

`nub :: Eq a => [a] -> [a]` は **O(n²)**。`SemanticType` には `Ord` instance がある ([SemanticType.hs:108](../haskell/katari-compiler/src/Katari/SemanticType.hs#L108)) ので:

```haskell
import Data.Set qualified as Set
let solvedLowers = Set.toList . Set.fromList $ filter containsNoTypeVars (map (.boundType) lowers)
```

で O(n log n)。Solver の bound 計算は loop の中で何度も呼ばれる ([Solver.hs:141-156](../haskell/katari-compiler/src/Katari/Typechecker/Solver.hs#L141-L156)) ので、大きなプログラムで効く可能性。

## cabal の未使用 dependency

`katari-compiler.cabal:74-87`:

```cabal
build-depends:
    aeson,
    base >=4.18 && <5,
    bytestring,        -- ← 未使用
    containers,
    megaparsec,
    mtl,
    parser-combinators,
    safe,
    scientific,        -- ← 未使用
    text,
    transformers,
    vector             -- ← 未使用
```

```sh
$ grep -rE '^import Data.Vector|^import Data.ByteString|Scientific' Katari/
# (空)
```

**3 つとも 1 度も import されていない。** 宣言を削除すべき。CI のビルド時間 / dependency footprint / `pkg-config` の noise を減らせる。

## 採用を検討すべきライブラリ

### `prettyprinter` (推奨)

`Diagnostic.Render` 全体が Text 連結ベース。OSS のコンパイラとしては:

- ANSI color (severity 別色付け)
- Wrap-aware layout (端末幅に応じて改行)
- Indent / nesting 管理

を `prettyprinter` + `prettyprinter-ansi-terminal` で得られる。Rust の `codespan-reporting` のような snippet 表示も可能。

現状の `Render.hs` は ~115 行で「動くが地味」。prettyprinter 化で実装は減らないが、表現力と保守性が劇的に上がる。OSS 公開の見栄えに直結する。

**優先度**: OSS 公開時に「コンパイラの error 出力が貧弱」と思われないために中以上。

### `text-builder` または `Data.Text.Builder` (任意)

現状の `<>` チェイン (Text 同士) は内部的に `Text` の Append。長文時に `Builder` 経由のほうが速い。ただし Diagnostic は短いものが多いので、優先度は低い。

### `Data.IntMap.Strict` (検討)

`Map VariableId X` のキー `VariableId` は `newtype VariableId Int`。`IntMap` は dense Int キーで `Map` より速い。ただしホットパスで効くかは未測定。

優先度低。ベンチを取ってから判断。

### `optics` / `lens` (見送り推奨)

AST が深いネストなので一見 `lens` / `optics` が役立ちそうだが、`OverloadedRecordDot` + `RecordWildCards` で十分機能している。導入による依存の重さに見合わない。**見送り推奨。**

## 全体評価

「車輪の再発明」は 3 件しかなく、いずれも **修正は半日仕事** (Tarjan 削除 / `(!?)` 削除 / `nub` 置換)。本質的な問題ではないが OSS 品質では避けたいレベルの汚れ。

`prettyprinter` 採用は本物の改善になる。OSS 公開前にやっておくと、リリース時の見栄えが大きく変わる。

## 後段で追跡すべき未解決事項

- [ ] `renderSnippet` の per-file `Text.lines` キャッシュ化 (実害は CLI batch 使用時のみ)
- [ ] `Map VariableId X` を `IntMap` 化したときの実測ベンチ (Step 4 で評価)
- [ ] `prettyprinter` 導入の判断は OSS リリース計画と相談
