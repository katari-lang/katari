# CLAUDE.md — QATALI Compiler

このファイルは `haskell/qatali-compiler` で作業するための実務ガイドです。

## プロジェクト概要

`qatali-compiler` は Qatali 言語のコンパイラ・型検査系の中核ライブラリです。

主な責務:

- 構文解析（Lexer/Parser）
- 型表現（`Type` / `NormalizedType`）
- 型正規化・部分型判定
- 型検査
- IR 生成と整形出力

ビルド構成:

- Haskell Stack ワークスペースの一部として管理
- `stack.yaml` の LTS は `lts-22.44`（GHC 9.6.7）
- `GHC2021` を採用

---

## 開発用コマンド

作業ディレクトリは通常、リポジトリルート（`/home/yukikurage/projects/qatali`）を想定します。

### よく使うコマンド（リポジトリルート）

- コンパイラのみビルド
  - `just build-compiler`
  - または `stack build qatali-compiler`

- コンパイラのテスト実行
  - `just test-hs-pkg qatali-compiler`
  - または `stack test qatali-compiler`

- Haskell 全体ビルド / テスト
  - `just build-hs`
  - `just test-hs`

- フォーマット / リント
  - `just fmt-hs`
  - `just lint-hs`

- 変更監視ビルド
  - `just watch-hs`

### 直接 `qatali-compiler` ディレクトリで作業する場合

- `stack build qatali-compiler`
- `stack test qatali-compiler`

---

## ディレクトリ構造

`haskell/qatali-compiler/`

- `src/QataliCompiler/`
  - `Parse/` : 字句解析・構文解析
  - `Syntax/` : AST・リテラル定義
  - `Type/` : 型定義、型正規化、部分型判定
  - `Typecheck/` : 型検査ロジック
  - `IR/` : 中間表現と Pretty Printer
  - `Codegen/` : 出力生成
  - `Compile/` : コンパイルの下位段
  - `Lib.hs` : ライブラリエントリ
- `test/Spec.hs` : テストエントリ
- `package.yaml` : Hpack 設定（原本）
- `qatali-compiler.cabal` : 生成物（通常は `package.yaml` から再生成）

---

## コーディング規約

### 全般

- 既存スタイル（インデント、命名、コメント方針）を維持する。
- 不要なリファクタリングは避け、差分は最小に保つ。
- 公開 API を変更する場合は、必要性を明確にする。

### 関数定義スタイル（重要）

- **同一関数のパターンを複数行に列挙するより、`case` 式を優先する。**
  - 推奨:
    - `f x y = case (x, y) of ...`
  - 非推奨:
    - `f A _ = ...`
    - `f _ B = ...`
    - `f (C x) (D y) = ...`

理由:

- 分岐条件が 1 箇所にまとまり、読みやすい
- 網羅性・優先順位が追いやすい
- 関連ロジックを局所化しやすい

### 型・エラーハンドリング

- 型注釈を積極的に維持する。
- TODO コメントは「何が未実装か」を具体化する。
- `Diagnostic` を使ったエラー報告の流れを壊さない。

### フォーマット・リント

- Haskell 変更後は `just fmt-hs` / `just lint-hs` を通す。
- 警告（`-Wall` など）を増やさない。

---

## 変更時チェックリスト

- [ ] 変更ファイルのビルドが通る
- [ ] `qatali-compiler` のテストが通る
- [ ] 既存コメント・ドキュメントとの整合がある
- [ ] 差分が不要に広がっていない

---

## 補足

- 依存やモジュール公開設定は `package.yaml` を正とし、必要に応じて Cabal ファイルを再生成する。
- 仕様追加時は、まず `Type` / `Normalize` / `Subtype` / `Typecheck` の影響範囲を確認してから実装する。
