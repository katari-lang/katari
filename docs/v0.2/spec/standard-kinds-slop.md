# 標準の種別 仕様

版：0.2-draft　／　Katari が標準として提供するリソースの種別を定める。種別の枠は Katari Protocol の仕様（`katari-protocol.md`）の §3.5 にある。設計の過程は `../records/2026-10-23-katari-protocol-design-record.md` を参照する。

以下、「Protocol §n」は `katari-protocol.md` の節を指す。

---

## 1. sink

一方向のイベントの受け口。型引数を一つとり、それがイベントの型である（`katariRef` では `{ "kind": "sink", "targs": [ <イベントの型> ] }`）。

### 1.1 状態

issuer は、sink ごとにイベントの型を持つ。届いたイベントの処理は、上の層が持つ。

### 1.2 メソッド

| メソッド | params | result |
|---|---|---|
| `sink/emit` | `{ grant, event }` | `null`（受理した） |

- `event` がイベントの型に合わなければ、受理する前に -32602 を返す。
- `emit` の成功は「受理した」を意味し、「処理を終えた」は意味しない。
- issuer は、Protocol §2.5 のエラー（一時的な障害、バグ・設定の誤り、失効、型の不一致）以外の理由で `emit` を拒否してはならない。流量の制限は `unavailable` で表す。
- イベントにバイト列を入れるべきでない。バイト列は blob として渡す。

### 1.3 順序

- 順序は保証しない。順序が要る場合は、送信者が Protocol §2.4 のチャネルを用いる。
- Katari Runtime は、同じ activation から同じ sink への `emit` を、書いた順に届ける（チャネルのキーは `(aid, sink の URI)`）。

---

## 2. blob

バイト列。型引数はとらない。

### 2.1 状態

issuer は、blob ごとにバイト列を持つ。置き場（外部ストレージなど）は実装が決める。

### 2.2 メソッド

| メソッド | params | result |
|---|---|---|
| `blob/fetch` | `{ grant, offset?, length? }` | `{ data, size }` |

- `data` は指定した範囲のバイト列の base64、`size` は全体の大きさ（バイト）である。
- 大きなバイト列は、範囲を分けて取得する。`length` を省略したときは、既定の範囲（付録 A）とする。
- issuer は、blob の内容を変えてはならない。同じ blob への `blob/fetch` は、いつ、どの範囲で呼んでも、同じバイト列の該当する部分を返す。
- 書き込みは、相手に blob の Ref を渡して取りに行かせる形で表す。

---

## 付録 A. 既定値

| 項目 | 既定値 | 制約 |
|---|---|---|
| `blob/fetch` の既定の範囲 | 1 MiB | base64 と JWS で符号化しても、エンベロープの大きさの上限（Protocol 付録 A）に収まる |

## 付録 B. 未決事項

- `stream` 種別。sink は単発のイベントのための種別のままにし、順序・背圧・再開を持つストリームは別の種別として足す。
- バイト列をそのまま運ぶ `blob/fetch` の binding（JSON-RPC の中に base64 で入れる代わりに、HTTP の GET と Range で返す）。
