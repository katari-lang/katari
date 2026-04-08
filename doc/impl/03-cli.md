# CLI 実装 (`katari` コマンド)

spec 参照: `05-module-system.md`, `10-servers.md`

---

## サブコマンド

### `katari build [src_dir]`

ソースディレクトリ (`src/` デフォルト) をコンパイルして IR バイナリを生成。

```
処理フロー:
1. src/ 以下の .ktr ファイルを収集
2. ファイルパス → モジュール名変換 (src/lib/cron.ktr → lib.cron)
3. import 宣言を解析してモジュールグラフ構築
4. トポロジカルソートで依存順を決定 (循環依存はエラー)
5. 各モジュールをコンパイル (compiler の compileModules を呼ぶ)
6. dist/*.ktri として出力
```

### `katari check [src_dir]`

型検査のみ実行 (IR 生成なし)。エラー・警告を報告。

### `katari run [--server addr] task_name [args...]`

ランタイムサーバーに対して `POST /run` を送信し、結果を待機して標準出力に表示。

```
処理フロー:
1. katari_config.yaml を読み込んで runtime の base URL を取得
2. GET /task で task 定義を確認
3. POST /run { task_id, args } を送信
4. GET /run/:run_id をポーリングして完了待ち
5. 結果を JSON 形式で出力
```

### `katari apply [--server addr] dist/*.ktri`

IR バイナリをランタイムサーバーにデプロイ。

```
処理フロー:
1. 指定した .ktri ファイルを読み込む
2. runtime の POST /apply にバイナリ送信
```

---

## 設定ファイル

### `katari_config.yaml`

```yaml
runtime:
  port: 8000
  katari_endpoint: "http://localhost:8000/katari"

external_katari_endpoints:
  cron:    "http://localhost:8001/katari"
  ai:      "http://localhost:8002/katari"
  discord: "http://localhost:8003/katari"
  sandbox: "http://localhost:8004/katari"
```

- `runtime.katari_endpoint`: コンパイラが `external` の解決に使用する他、`katari apply` の送信先
- `external_katari_endpoints`: `from "server:name"` の `server` 部分に対応するエンドポイント

---

## モジュール名変換規則

```
src/main.ktr       → main
src/lib/cron.ktr   → lib.cron
src/utils/time.ktr → utils.time
```

`src/` ディレクトリを起点に、パス区切り `/` を `.` に変換し、`.ktr` 拡張子を除去。
