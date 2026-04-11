# KATARI Language Specification - Module System

## 概要

KATARI のモジュールシステムは、ファイルパスに基づく階層的なモジュール名を使用する。全ての定義は公開される (pub/export キーワードなし)。

## モジュール名とファイルパス

### ファイルパスからモジュール名への変換

ソースディレクトリ (`src/`) からの相対パスがモジュール名となる:

```
src/main.ktr         → main
src/lib/cron.ktr     → lib.cron
src/lib/ai.ktr       → lib.ai
src/utils/format.ktr → utils.format
```

### モジュール名の構造

```
ModuleName = identifier ('.' identifier)*
```

例: `main`, `lib.cron`, `utils.format`

## Import

### 基本構文

```katari
import lib.cron
```

モジュール内の全定義が現在のスコープに追加される。修飾名でアクセスする:

```katari
import lib.cron
cron.schedule("0 0 * * *")
```

### エイリアス

```katari
import lib.cron as c
c.schedule("0 0 * * *")
```

### 選択的インポート

```katari
import lib.cron { schedule, notify }
schedule("0 0 * * *")  // 修飾名なしでアクセス可能
```

選択的インポートした名前は修飾なしで使用可能。

### 修飾名アクセス

```katari
import lib.cron
cron.schedule("0 0 * * *")    // OK: 末尾のモジュール名で修飾
lib.cron.schedule("0 0 * * *") // OK: 完全修飾名
```

エイリアスを指定した場合は、エイリアスのみで修飾:

```katari
import lib.cron as c
c.schedule("0 0 * * *")       // OK
cron.schedule("0 0 * * *")    // NG: エイリアスが指定されているため元の名前は使えない
```

## 名前解決

名前解決は以下の順序で行う:

1. **ローカルスコープ**: 現在のブロック内の let バインディング、タスクパラメータ
2. **非修飾名のスコープ** (以下は同一優先度、衝突はエラー):
   - **モジュールスコープ**: 現在のモジュール内の val, task, request, type 定義
   - **選択的インポート**: `import M { name }` で取り込んだ名前
   - **prim モジュール**: 暗黙的にインポートされる組み込み定義

修飾名 (`module.name`) の場合:
1. インポートしたモジュールのエイリアスまたは末尾名でマッチ
2. 完全修飾名でマッチ

### 名前衝突

- **ローカルスコープは最優先**: ローカルの let バインディングやパラメータは常に他の定義を隠す。
- **モジュールスコープ・選択的インポート・prim 間の衝突は全てコンパイルエラー**: 同名の定義がこれら 3 つのスコープに複数存在する場合、エラーとなる。修飾名またはエイリアス import を使用して解消する。

```katari
// 例: prim の to_string と衝突する場合
import utils.string { to_string }  // prim.to_string と衝突 → コンパイルエラー

// 解決方法 1: エイリアス import で修飾名を使う
import utils.string as str
str.to_string(42)
prim.to_string(42)

// 解決方法 2: 選択的インポートしない
import utils.string
string.to_string(42)
```

## コンパイル順序

モジュールはトポロジカルソート順にコンパイルされる。循環依存は禁止 (コンパイルエラー)。

```
lib.cron (依存なし)
lib.ai   (依存なし)
main     (lib.cron, lib.ai に依存)
```

## 公開範囲

全ての定義 (val, task, request, external task, external request, type) は自動的に公開される。アクセス制御キーワードは存在しない。

## prim モジュール

`prim` モジュールは暗黙的にインポートされ、以下の組み込み定義を提供する:

### prim (トップレベル)

```katari
// 値を文字列に変換 (純粋関数)
task to_string(x: integer | number | boolean | string | null) -> string

// パース関連 request
request parse_error(message: string) -> never

// パース関数
task parse_integer(s: string) -> integer with parse_error
task parse_number(s: string) -> number with parse_error
task parse_boolean(s: string) -> boolean with parse_error

// エラー (組み込み request)
request throw(message: string) -> never

// 並行実行 (par は構文であり prim 関数ではない。詳細は 01-syntax.md を参照)
```

### prim.log

```katari
task info(message: string) -> null
task warn(message: string) -> null
task error(message: string) -> null
```

ログ関数は request を発生させない (ログ出力はランタイムが直接処理)。

## QualifiedName

内部的に、全ての定義は QualifiedName で一意に識別される:

```
QualifiedName = {
  module: ModuleName,   // 例: "lib.cron"
  name: string,         // 例: "schedule"
}
```

QualifiedName は以下の用途で使用される:
- NameTable によるデバッグ (TaskId ↔ QualifiedName マッピング)
- Katari Protocol での task/request 識別
- 実行状態の永続化と復元

## external 宣言とモジュール

`external task` / `external request` は `from "server_name:name"` で外部サーバーの task/request を参照する。`server_name` は `katari_config.yaml` の `external_katari_endpoints` で定義されたサーバー名と対応する。

```katari
// lib/cron.ktr
@"一定間隔でnotify requestを発行するタスク"
external task schedule(cron: string) -> null with notify from "cron_server:schedule"

@"notify request"
external request notify(time: string) -> null from "cron_server:notify"
```

ランタイム起動時、各 external 宣言について:
1. `katari_config.yaml` から `server_name` に対応するエンドポイント URL を取得
2. `GET /task` または `GET /request` で該当する task/request の情報を取得
3. `task_id` / `request_id` と URL を保持

## プロジェクト構成

```
project_root/
  src/
    main.ktr              # main モジュール
    lib/
      cron.ktr            # lib.cron モジュール
      ai.ktr              # lib.ai モジュール
  katari_config.yaml      # 設定ファイル
  docker-compose.yaml     # サーバー構成
```
