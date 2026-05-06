# Step 4: Production Ready 課題の洗い出し

OSS として公開する上での「**信頼性 / パフォーマンス / テスト容易性 / ドキュメント**」を監査した。

## 1. Panic 経路の監査

### 全 panic 一覧 (8 箇所)

| 場所 | 種類 | 補足 |
| --- | --- | --- |
| [Internal.hs:23](../haskell/katari-compiler/src/Katari/Internal.hs#L23) | `error` | `internalError` 本体 |
| [Internal.hs:30](../haskell/katari-compiler/src/Katari/Internal.hs#L30) | `error` | `internalErrorNoSpan` 本体 |
| [Lowering.hs:501](../haskell/katari-compiler/src/Katari/Lowering.hs#L501) | **bare `error`** | "ModuleId not in zonkedModuleNames" |
| [Identifier.hs:638](../haskell/katari-compiler/src/Katari/Typechecker/Identifier.hs#L638) | **bare `error`** | "scope stack underflow (compiler bug)" |
| [Lowering.hs:365](../haskell/katari-compiler/src/Katari/Lowering.hs#L365) | `internalErrorNoSpan` | "primBlockId: unknown primitive" |
| [Lowering.hs:552, 553, 562, 563](../haskell/katari-compiler/src/Katari/Lowering.hs#L552) | `internalErrorNoSpan` | req/ctor id pre-allocation invariants |
| [Lowering.hs:816, 842](../haskell/katari-compiler/src/Katari/Lowering.hs#L816) | `internalErrorNoSpan` | "must be peeled by lowerBlockInto" |
| [Identifier.hs:1690, 2043](../haskell/katari-compiler/src/Katari/Typechecker/Identifier.hs#L1690) | `Internal.internalError` | 各種 invariant |

### 個別評価

#### 【高】Bare `error` で `Internal.error` を使っていない箇所が 2 つある

[Lowering.hs:501](../haskell/katari-compiler/src/Katari/Lowering.hs#L501) と [Identifier.hs:638](../haskell/katari-compiler/src/Katari/Typechecker/Identifier.hs#L638) は `Katari.Internal` を経由していない bare `error`。スタックトレースなし、フォーマット非統一。

**修正**: 全部 `Internal.internalError` 経由に統一。これだけで grep ヒット率が安定し、CI で `error` の bare 使用を禁止できる:

```bash
grep -nE '\berror\b' src/ | grep -v 'Internal.hs'  # CI で 0 件チェック
```

#### 【高】LSP / playground での panic 影響

現在の `internalErrorNoSpan` は `error` を呼ぶだけなので、LSP / playground のような **long-running プロセスでは即座にプロセス全体が落ちる**。compile が pure 関数なので catch できないわけではないが、それは embedder 側の責務になる。

OSS 公開時、LSP / playground は別 process で `compile` を呼ぶ運用なら 1 リクエストの失敗で済むが、in-process embed では破滅的。

**推奨改善**:
1. `compile` のシグネチャを変えずに、Lowering / Identifier 側で `try`-能力を持つよう refactor は重い。代案として
2. `Diagnostic` に `SeverityFatal` (新設) または `code = "K9999"` の internal error を入れて、partial result (Nothing) を返す
3. Panic を本気で止めたいなら Lowering を `Either` に変えるが breaking で大きい

短期解決: doc に「`compile` は pure だが invariant 違反時に `error` を投げ得る。LSP / playground 等は子 process で実行することを推奨」と明記。`Internal.error` の各箇所が「コンパイラバグの場合のみ」発生することは現にコードコメントで明示されている。

#### 【中】Lexer の `head $ readHex` ([Lexer.hs:767](../haskell/katari-compiler/src/Katari/Lexer.hs#L767))

```haskell
pure . fst . head $ readHex [hex1, hex2, hex3, hex4]
```

`hexDigitChar` で各文字を validate 済みのため、`readHex` は確実に `[(_, "")]` を返す前提。**前提は正しい**が、「parse とハンドリングが離れている」「`safe` パッケージは既に dependency」という観点から書き換え推奨:

```haskell
case readHex [hex1, hex2, hex3, hex4] of
  ((codepoint, _) : _) -> pure (chr codepoint)
  [] -> internalErrorNoSpan "lexUnicodeEscape: hex chars failed to parse despite hexDigitChar validation"
```

または `Numeric.readHex` のスペック上の保証 (overflow なし、空入力時に `[]`) を信じるなら現状でも実害は少ない。優先度は低い。

#### 【低】Lexer の `last allTokens` ([Lexer.hs:955](../haskell/katari-compiler/src/Katari/Lexer.hs#L955))

```haskell
nextSourcePos remainingTokens allTokens fallback = case remainingTokens of
  WithSourceSpan span_ _ : _ -> ...
  [] -> case allTokens of
    [] -> fallback
    _ -> let WithSourceSpan span_ _ = last allTokens in ...
```

`_ ->` 分岐は非空が確定しているので `last` は安全。✓ ただし型レベルで保証されていない (`NonEmpty` を使えば良かった)。リファクタリング優先度は低い。

## 2. パフォーマンス監査

### Hot path の懸念

#### 【中】`Solver.Substitution.nub` (Step 3 で既出)

[Substitution.hs:269-270](../haskell/katari-compiler/src/Katari/Typechecker/Solver/Substitution.hs#L269-L270) の `nub` は O(n²)。Step 3 で対応済み。

#### 【中】`Lowering.lsCurrentEmitted :: [Statement]` の build-up

[Lowering.hs:170-173](../haskell/katari-compiler/src/Katari/Lowering.hs#L170-L173) で statements を逆順蓄積、`runWithFreshBuffer` で reverse。

```haskell
lsCurrentEmitted :: [Statement]
```

**問題**: `[Statement]` は lazy list。`emit` が `\s -> s {lsCurrentEmitted = stmt : s.lsCurrentEmitted}` だと thunks が積み上がる。`StrictData` は cons cell の field を strict にするが、`stmt :` 自体の WHNF 評価は trigger しない。

**確認**: `emit` 実装の strictness 評価が必要。BangPattern 1 個追加で済む可能性。

実害は通常コードで限定的だが、生成 IR が大きいプロジェクト (1k+ statements の関数) では効く可能性あり。

#### 【低】`compile :: CompileInput -> CompileResult` の全 lazy result

```haskell
compile input =
  let (parsed, parseDiags) = parseSources input.sources
      ...
  in CompileResult { irModule = finalIR, ... }
```

`CompileResult` の構築は完全に lazy。LSP は段階的に force すれば良いが、batch CLI で `irModule = Nothing` の判定だけして diagnostics を出さないユースケースだと、`identifierResult` 等の重い結果が無駄に保持される。

**改善案**: `CompileResult` のフィールドを `!Maybe` (BangPattern) で strict 化、または `compile` が利用シーンに応じて部分結果を返す variant を提供。

優先度: 通常使用では発生しない。後回し可。

#### 【低】`Map.findWithDefault` を 17 箇所で使用

defensive な使い方が多く、内部 invariant 違反を `Set.empty` 等で silent に補完するパターンがあるかもしれない。各箇所を audit して「invariant 違反は internalError、それ以外は findWithDefault」の使い分けを明確化すべき。

## 3. テスト容易性

### テスト規模

- **6923 行のテスト** vs ~15000 行の source = **46% テスト比率**。健全。
- すべて hspec ベース。

### 不足している種類

#### 【高】Property-based test がない

Compiler のような結合度が高いコードベースでは、**property test** が大きな価値を持つ。例:

- `lex >>> parse >>> identify >>> ...` のラウンドトリップ
- 任意の AST に対し `lower` が成功するなら IR JSON が roundtrip 可能
- `solve` の出力は `typeSubstitution` が total

`hedgehog` または `QuickCheck` を `cabal` に追加し、最低 5-10 個の core property を入れるだけで OSS としての信頼性が大きく上がる。

#### 【高】Golden test (snapshot test) がない

```sh
$ find haskell -name "*.json" -o -name "*.golden" -o -name "*.ktr"
# (empty)
```

**IR JSON は外部公開仕様** (TS runtime が直接読む)。Golden test がないと、JSON schema を不注意に変えても気付けない。

`tasty-golden` または独自 hspec マッチャで「サンプル `.ktr` を compile して期待 IR JSON と比較」するテストを追加すべき。最低でも 5-10 サンプルあれば、IR の binary compatibility を CI で保護できる。

#### 【中】Sample fixtures がない

テストはすべて inline string。実プログラム (`samples/` は haskell-old 向けで対象外) に近い fixture を作って regression suite にすべき。

### コードカバレッジ

`stack test --coverage` で計測可能だが、現状の cabal/stack 設定に coverage 出力の仕組みがない。CI で出力 + Codecov 連携を入れる。

## 4. ドキュメント

### 良い点

- **22 モジュール全てが docstring 付き module-header を持つ**。設計判断・パイプライン・各 phase の役割が日本語で明文化されている。日本語前提の OSS なら良い、英語のグローバル OSS にする場合は翻訳が必要。

### 不足

#### 【中】Haddock の `>>>` (doctest) がゼロ

```sh
$ grep -rn '^-- >>>' src/
# (empty)
```

公開 API の使い方の例が doc 内に書かれていない。`Katari.Compile.compile` だけでも、典型的な呼び出し例を doc に入れるべき。

#### 【中】README / CHANGELOG / CONTRIBUTING が未確認

`haskell/katari-compiler/` 直下に `README.md` / `CHANGELOG.md` がない。OSS リポジトリとしてはトップレベルにこれらが必要。

#### 【低】Diagnostic コードの完全な registry

CLAUDE.md に「The full registry lives in CHANGELOG.md (Phase 14)」とあるが、CHANGELOG 自体が未確認。code → 説明 → 例 の表が公開ドキュメントに必要。

## 5. 上記をまとめた優先度マトリクス

| 重要度 \ 工数 | 半日 | 1-2 日 | 1 週間+ |
| --- | --- | --- | --- |
| **高** | bare `error` を `Internal.error` に統一; cabal の未使用 dep 削除 (Step 3 由来) | Golden test スイート追加; CHANGELOG / README 整備 | Property test スイート (`hedgehog` 統合) |
| **中** | `Lexer:767` の `head readHex` 改善; doc に「invariant 違反時 panic」明記 | `prettyprinter` 化 (Step 3) ; haddock に `>>>` 例追加; `lsCurrentEmitted` strict 化 | `Internal.error` を `Diagnostic K9999` 化する compile 経路の整備 |
| **低** | `last allTokens` を NonEmpty 化 | `Map → IntMap` ベンチ + 移行 | 多言語化 (英語化) |

## 6. Show-stopper 判定

OSS Production Ready に **show-stopper はない**。すべて修正は局所的・低リスク。

修正コスト感:
- 「**最低限の OSS 公開**」: 半日列の項目 + Golden tests + README/CHANGELOG = **3 日**
- 「**Production-grade OSS**」: + Property test + prettyprinter + 例 doc = **追加 1 週間**

## 後段で追跡すべき未解決事項

- [ ] `lsCurrentEmitted` の thunks 蓄積を実測 (大きなプログラムで GC 統計を取る)
- [ ] `Map.findWithDefault` 17 箇所の audit (invariant violation が混じっていないか)
- [ ] CHANGELOG.md に diagnostic code registry が実在するか確認
- [ ] LSP / playground が in-process で `compile` を呼ぶアーキテクチャかどうか確認 (もし in-process なら panic 経路の整備優先度が上がる)
