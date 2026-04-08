# KATARI Language Specification - Overview

**Version**: 0.2.0
**Date**: 2026-04-06

## 目次

- [00-overview.md](00-overview.md) - 本ドキュメント
- [01-syntax.md](01-syntax.md) - 構文仕様
- [02-type-system.md](02-type-system.md) - 型システム
- [03-discriminated-unions.md](03-discriminated-unions.md) - 判別可能 union
- [04-request-system.md](04-request-system.md) - Request System
- [05-module-system.md](05-module-system.md) - モジュールシステム
- [06-parallel.md](06-parallel.md) - Par 式 / 並行実行
- [07-katari-protocol.md](07-katari-protocol.md) - Katari Protocol
- [08-ir.md](08-ir.md) - 中間表現 (IR)
- [09-primitives.md](09-primitives.md) - 組み込み型・関数
- [10-servers.md](10-servers.md) - サーバー仕様

## 設計理念

KATARI は **AI オーケストレーション専用言語** である。複数のサーバー (AI サーバー、cron サーバー、Discord サーバー等) を連携させるための軽量な言語として設計されている。

### 基本方針

1. **エージェントベース実行モデル**: 全ての非プリミティブ関数呼び出しはエージェント (agent) の同期呼び出しである。`task_name(args)` は子エージェントを spawn して即座に完了を待つ。明示的な並行実行には `par` 式を使用する。各サーバーはエージェントの設計図である task と、エージェントを起動するエンドポイントを提供し、エージェント間のやり取りでオーケストレーションを実現する。
2. **単純さ**: オーケストレーションに必要な機能のみを搭載する。計算効率は求めない。効率が必要な処理は他の言語で書かれたサーバーに委譲する。
3. **分散実行**: Katari Protocol に基づく分散実行が言語の中核。全ての task は非同期であり、サーバー間通信を前提とする。
4. **型安全性**: Generics や型推論を排除しつつも、部分型・union/intersection・判別可能 union・request system による強い型安全性を維持する。
5. **JSON 互換性**: ランタイム値は JSON 互換 (null, integer, number, boolean, string, array, object)。semantic annotation により JSON Schema を自動生成する。

### エージェントモデル

KATARI の実行モデルはエージェント (agent) を中心に構成される。

- **task**: 実行可能な処理の定義。
- **agent**: task の実行インスタンス。固有の ID を持つ。
- **par**: 複数のブロックを並行実行する式。各ブロックは独立したエージェントとして起動され、全完了時に `array[T1 | T2 | ...]` を返す。
- **request**: エージェントが親エージェントに対して発行する要求。直接の親に送られ、未処理なら上位に転送される。
- **reply**: 親エージェントが request に対して値を返し、子エージェントの実行を再開させる。
- **handle block**: task body 内に記述する Koka 式のインラインハンドラ。子エージェントからの request を処理する。handle パラメータで状態を管理する。

通常の関数呼び出し `task_name(args)` は、子エージェントを spawn して即座に完了を待つ同期呼び出しである。`par` 式を使うことで、複数のエージェントを並行に実行できる。

### Cooperative Event Loop

各エージェントはシングルスレッドの cooperative event loop で動作する。エージェントは **suspension point** (task 呼び出し, par, for wait) でのみ子エージェントからの request を処理する。これにより「1 エージェント = 1 つのこと」の原則が維持される。

### Protocol の 6 操作

Katari Protocol は以下の 6 つの操作で構成される:

1. **spawn**: 新しいエージェントを生成する。
2. **request**: エージェントが親に対して要求を発行する。
3. **reply**: 親が request に対して値を返す。
4. **terminate**: 親がエージェントの実行を中断する。
5. **return**: エージェントが正常に完了し、結果を返す。
6. **terminate_ack**: エージェントが terminate を受理したことを通知する。

### Qatali からの変更点

| 機能                  | Qatali                     | KATARI                                  |
| --------------------- | -------------------------- | --------------------------------------- |
| Generics              | あり (type, data, fn, val) | なし (`array[T]` のみ特別対応)          |
| 型推論                | 制約ベース推論             | なし (全て決定的型チェック)             |
| Multi-shot effect     | あり                       | なし (one-shot request のみ)            |
| IR                    | 最適化あり                 | 単純 (パフォーマンス不要)               |
| Data type (nominal)   | あり                       | なし (object/record 型で代用)           |
| Record 型             | なし                       | あり                                    |
| External task/request | なし                       | あり                                    |
| Template literal      | 限定的                     | 柔軟                                    |
| result/option         | 型レベル                   | request で再現                          |
| pub/export            | あり                       | なし (全定義が公開、これは一時的なもの) |
| void 型               | あり                       | なし (null に統一)                      |
| Trait                 | あり                       | なし                                    |
| effect / handle       | effect + handle            | request + handle block                  |
| parallel              | なし                       | par                                     |
| fn                    | fn                         | task                                    |
| continue (handler)    | continue                   | reply                                   |

## 用語集

### 言語用語

| 用語                  | 説明                                                                   |
| --------------------- | ---------------------------------------------------------------------- |
| `null`                | null リテラル値、および null 型。unit 型としても使用。                 |
| `never`               | ボトム型。値を持たない型。                                             |
| `unknown`             | トップ型。全ての型のスーパータイプ。                                   |
| `integer`             | 任意精度整数。                                                         |
| `number`              | IEEE 754 倍精度浮動小数点数。`integer <: number`。                     |
| Record 型 (object)    | フィールド名と型の組で構成される構造体。`{name: string, age: integer}` |
| 判別可能 union (DISC) | `uniq` キーワードによって判別可能な object の union。                  |
| Semantic annotation   | `@ "説明"` 形式の注釈。JSON Schema の description として使用。         |
| Literal 型            | `0`, `"hello"`, `true` など、具体値そのものが型となるもの。            |

### Request / Handle Block 用語

| 用語              | 説明                                                                                                             |
| ----------------- | ---------------------------------------------------------------------------------------------------------------- |
| `request`         | エージェントが親(n世代上も可)エージェントに対して発行する要求の宣言。`request name(params) -> type` で定義する。 |
| `handle` block    | task body 内に記述する Koka 式のインラインハンドラ。子エージェントからの request を捕捉し処理する。              |
| handle パラメータ | handle block の引数として定義される状態。`reply ... with` で更新可能。                                           |
| `reply`           | handle block 内で request の呼び出し元に値を返して実行を再開させる制御。                                         |
| `break`           | handle block 内または for ループ内で、実行を中断して値を返す制御。                                               |
| `next`            | for ループ内で次のイテレーションに進む制御。`next with` で状態変数を更新可能。                                   |
| `throw`           | 組み込み request。全 task に暗黙的に含まれる。ランタイムがトップレベルハンドラを提供する。                       |
| suspension point  | エージェントが request queue をチェックするポイント。task 呼び出し, par, for wait。                              |
| self-request      | エージェントが自身の handler に対して request を perform すること。suspend → handler 実行 → reply → 再開。       |

### エージェント / 並行実行用語

| 用語  | 説明                                                                                                               |
| ----- | ------------------------------------------------------------------------------------------------------------------ |
| `par` | 複数のブロックを並行実行する式。`par [{ b1 }, { b2 }, ...]` で全ブロック完了後に `array[T1 \| T2 \| ...]` を返す。 |

### Protocol 用語

| 用語               | 説明                                                     |
| ------------------ | -------------------------------------------------------- |
| agent              | task の実行インスタンス。固有の agent ID を持つ。        |
| request (protocol) | エージェントが親エージェントに対して要求を発行する操作。 |
| reply (protocol)   | 親エージェントが request に対して値を返す操作。          |
| spawn              | 新しいエージェントを生成する操作。                       |
| terminate          | 親エージェントが子エージェントの実行を中断する操作。     |
| return (protocol)  | エージェントが正常に完了し、結果を親に返す操作。         |
| terminate_ack      | エージェントが terminate を受理したことを通知する操作。  |
| Katari Protocol    | サーバー間通信プロトコル。REST API ベース。              |
| runtime サーバー   | KATARI コードを実行するサーバー。                        |
| external task      | 外部サーバーに存在する task の宣言。                     |
| external request   | 外部サーバーが提供する request の宣言。                  |

## ファイル拡張子

KATARI ソースファイルの拡張子は `.ktr` とする。

## プロジェクト構成

```
src/
  main.ktr              # エントリポイント
  lib/
    cron.ktr            # cron 関連モジュール
    ai.ktr              # AI 関連モジュール
katari_config.yaml      # 外部サーバーの設定
docker-compose.yaml     # サーバー群の構成
.env                    # 環境変数
```

`katari_config.yaml` の例:

```yaml
runtime:
  port: 8000
  katari_endpoint: "http://localhost:8000/katari"

external_katari_endpoints:
  cron_server: "http://localhost:8001/katari"
  ai_server: "http://localhost:8002/katari"
```
