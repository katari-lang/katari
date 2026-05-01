# Changelog — katari-compiler

## Unreleased (Phase 19 — Production-Ready Refactoring)

### Breaking changes

#### IR JSON shape

Constructor names in the IR JSON now carry the full type-name prefix and are
serialized verbatim (PascalCase). Runtime consumers must update tag names:

| Old tag              | New tag                    |
| -------------------- | -------------------------- |
| `SCall`              | `StatementCall`            |
| `SMakeClosure`       | `StatementMakeClosure`     |
| `SLoadLiteral`       | `StatementLoadLiteral`     |
| `SMatch`             | `StatementMatch`           |
| `SFor`               | `StatementFor`             |
| `SExit`              | `StatementExit`            |
| `SCont`              | `StatementCont`            |
| `SBindPattern`       | `StatementBindPattern`     |
| `MPAny`              | `MatchPatternAny`          |
| `MPVariable`         | `MatchPatternVariable`     |
| `MPLiteral`          | `MatchPatternLiteral`      |
| `MPConstructor`      | `MatchPatternConstructor`  |
| `MPTuple`            | `MatchPatternTuple`        |
| `CTBlock`            | `CallTargetBlock`          |
| `CTValue`            | `CallTargetValue`          |
| `LVInteger`          | `LiteralValueInteger`      |
| `LVNumber`           | `LiteralValueNumber`       |
| `LVString`           | `LiteralValueString`       |
| `LVBoolean`          | `LiteralValueBoolean`      |
| `LVNull`             | `LiteralValueNull`         |
| `ExitReturn`         | `ExitKindReturn`           |
| `ExitBreak`          | `ExitKindBreak`            |
| `ExitForBreak`       | `ExitKindForBreak`         |
| `ContNext`           | `ContKindNext`             |
| `ContForNext`        | `ContKindForNext`          |

PascalCase を使う理由: `foo` (変数) と `Foo` (コンストラクタ) は Katari 言語で
意味が異なるため、JSON レベルでも大文字・小文字を区別する必要がある。
`lowerHead` による camelCase 変換は行わない。

Schema / Diagnostic / Constraint / NormalizedType のコンストラクタも同様にリネーム
(内部型なので JSON 公開形式への影響は IRModule のみ)。

#### IRModule に `metadata` フィールドを追加

```json
{
  "metadata": { "schemaVersion": 1 },
  "name": "main",
  "blocks": { ... },
  "entries": { ... },
  "nameTable": { ... }
}
```

`schemaVersion` が runtime の期待値と一致しない場合はロードを拒否することを推奨。

#### CallTarget / entries は変更なし

`CallTarget = CallTargetBlock | CallTargetValue` の意味論は維持。
`IRModule.entries :: Map QualifiedName BlockId` も変更なし。

### New features

#### `CompileResult.identifierResult`

```haskell
identifierResult :: Maybe IdentifierResult
```

LSP / CLI が agent listing・未使用変数検出・qualified-name lookup を実装するのに必要な
名前解決テーブルを `CompileResult` 経由で取得できるようになった。

#### `Katari.Query` — LSP / CLI 向け query layer

```haskell
lookupAtPosition  :: ZonkResult -> FilePath -> Position -> Maybe HoverInfo
buildOccurrenceIndex :: ZonkResult -> OccurrenceIndex
identifyAtPosition :: ZonkResult -> FilePath -> Position -> Maybe ResolvedReference
findReferences    :: OccurrenceIndex -> ResolvedReference -> [SourceSpan]
findDefinition    :: ZonkResult -> FilePath -> Position -> Maybe SourceSpan
```

Position は **code-point 単位** (LSP layer が UTF-16 オフセットを変換してから渡す)。
`OccurrenceIndex` は一度 `buildOccurrenceIndex` で構築してから繰り返し query する。

#### `Katari.Diagnostic.Render` — CLI 向けレンダリング

```haskell
renderDiagnostic      :: Map FilePath Text -> Diagnostic -> Text
renderDiagnosticPlain :: Diagnostic -> Text
```

source text dependency を `Katari.Diagnostic` 本体から分離するため別モジュールに設置。

#### `Katari.Diagnostic` helpers

```haskell
filterAtLeast   :: Severity -> [Diagnostic] -> [Diagnostic]
sortBySpan      :: [Diagnostic] -> [Diagnostic]
groupByFilePath :: [Diagnostic] -> Map FilePath [Diagnostic]
```

### Internal refactoring (コンパイラ利用者への影響なし)

- 全直和型を GADTs 構文 (`data T where ...`) に統一
- 全コンストラクタに型名プレフィックスを付与 (`stripXXPrefix` 全廃)
- `Parser a` を返す全関数に `parse` プレフィックス付与
- `Lexer a` を返す全関数に `lex` プレフィックス付与
- 短縮変数名を全廃 (ドメイン値はフルネーム)
- `passThroughX` boilerplate を全廃 (TYG phase 推移が identity 変換)
- `zonkedModuleNames` を廃止 (`Module Zonked` の `moduleName` フィールドを使用)
- `lsVarBlockIds` を `lsTopLevelBlocks` にリネーム (top-level callable のみ格納、local agent は `localVars` Reader へ)
- `CompileResult.zonkResult` を追加 (Zonker 結果を Query layer へ直接渡せるように)
