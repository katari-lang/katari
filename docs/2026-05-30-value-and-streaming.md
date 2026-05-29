# 値モデル (v0.1.0: blob のみ)

> [overview](2026-05-30-overview.md) の D1-D11 の詳細。
>
> **v0.1.0 では observable streaming は実装しない**。 CORE が持つ値は常に
> `inline` か `ref(complete blob)`。 mid-stream consume / building state / live 出力は
> [v0.2-streaming](2026-05-30-v0.2-streaming.md) に分離した。 本ドキュメントは v0.1.0 の
> blob 値モデルに絞る。

## 1. event streaming と data streaming (D1)

- **event streaming** (離散 event の列): 既存の callback per event (sample 12-ext-cron)。
  言語にも runtime にも変更なし
- **data streaming** (一つの値が時間軸で materialize): observable には v0.2 送り。 v0.1.0 で
  AI を stream したい場合は **FFI-internal streaming** (= handler が LLM から受けながら
  Discord に post 等) で賄う。 CORE は chunk を観測しない

## 2. 言語 semantics: 値は ref-passing (D3)

> **Katari language semantics**: CORE は配線するだけ。 値 (large string / file) は ref で
> 受け渡され、 中身を inspect する操作 (`==` / pattern match / prim) のときだけ
> materialize される。 chunk-単位アクセスは言語操作ではない (= FFI service の data-plane
> affordance、 v0.2)。

これにより言語に streaming 固有の syntax / 型注釈は不要。

### materialize が fetch する操作・しない操作

ref の bytes を実際に fetch するのは **content を変形する prim だけ**。 多くは hash /
metadata で済む:

| 操作 | fetch? | 根拠 |
| --- | --- | --- |
| `==` (ref vs ref / ref vs inline) | しない | hash 比較 (inline は hash 化して比較) |
| `match x { "lit" => }` | しない | literal を hash して x の hash と比較 |
| `string_length` / `file_size` | しない | ref の size metadata |
| `string_concat` / f-string / `substring` | **する** | 新 content を作るので operand の bytes が要る |

fetch が要る場合、 fetch は **bounded** (= 値ストアからの読み出し、 無期限ではない) なので
engine は quantum 内で **inline await** する (= deterministic、 crash-safe を保つ。
[runtime-architecture §5](2026-05-30-runtime-architecture.md))。 無期限待ちが要る building
stream は v0.2。

## 3. ref = complete blob (v0.1.0) (D4, D8)

stream と blob を 1 つの **ref 概念**に統合する。 v0.1.0 では ref は **常に complete**:

```
v0.1.0 の ref 状態:
   produce (FFI handler が累積 or push→close)
       │
       ▼
   ┌──────────┐  ref_count=0  ┌─────────┐
   │ complete │──────────────▶│  swept  │
   └──────────┘               └─────────┘
       ▲ crash
   ┌──────────┐
   │ errored  │   (= produce 途中で host crash した row)
   └──────────┘
```

- producer (FFI handler) は complete blob を作って ref を返す。 CORE は close まで block
  (= α、 通常の delegation)。 **building state を CORE 値として観測しない**
- v0.2 で building / cancelled が観測可能な状態として追加される ([v0.2-streaming](2026-05-30-v0.2-streaming.md))

identity / dedup:

- **identity** = `id` (発行される一意 ID)。
- **hash** = complete 時に確定する content fingerprint。 **物理 dedup の key であって
  identity ではない**
- 同じ bytes を 2 回 produce すれば別 id の 2 つの ref (= 別 entity)、 物理 storage は
  hash で 1 つに dedup

## 4. 大きい complete blob の consume

大 file (音声等) も storage に **chunk 単位**で持つ (`value_blob_chunks`) ので、 consume は
range / chunk fetch で memory に全部載せずに済む。 CORE は file を ref-passing するだけで
materialize しないので CORE state を膨らませない。 mid-stream subscribe (= 完成前に読む) は
v0.2。 v0.1.0 は complete blob の chunk/range fetch のみ。

## 5. 値モデル: kind × rep の直交 (D5)

semantic type (`kind`) と storage state (`rep`) を別軸にする。 並列 variant
(`kind: "blob"`) は作らない (= pattern match / type system と不整合になるため)。

```ts
type Value =
  // Scalar — inline only
  | { kind: "number"; value: number }
  | { kind: "boolean"; value: boolean }
  | { kind: "null" }
  | { kind: "closure"; closureId: ClosureId }
  | { kind: "agentLiteral"; snapshot: string; qualifiedName: QualifiedName }  // D25

  // Byte sequences (BytesRep を共有)
  | { kind: "string"; rep: BytesRep }   // UTF-8 text
  | { kind: "file";   rep: BytesRep }   // opaque bytes
  | { kind: "secret"; rep: BytesRep }   // 暗号化は別レイヤ

  // Compound — v0.1.0 は inline 固定 (spec ルール)
  | { kind: "array";  elements: Value[] }
  | { kind: "tagged"; ctorId: QualifiedName; fields: Record<string, Value> }
  | { kind: "record"; entries: Record<string, Value> }

type BytesRep =
  | { kind: "inline"; bytes: Uint8Array }
  | { kind: "ref";                              // v0.1.0: 常に complete blob を指す
      module: "core" | "ffi" | "api";           // handle の持ち主 (project は ambient, D24)
      //   core/ffi → ephemeral (value_refs)、 api → persistent file (api_files)
      id: string;
      hash: string;                              // complete なので確定済み (→ value_blobs)
      size: number;
      contentType?: string;
    }
```

- v0.1.0 の `BytesRep` は inline / ref(complete) の 2 状態。 building / cancelled は v0.2
  ([v0.2-streaming](2026-05-30-v0.2-streaming.md)) で `ref` に追加される
- `BytesRep` は inline / ref の 2 状態のみ。 「blob」 「stream」 という語は消える
- v0.1.0 で rep が変動するのは `string` / `file` / `secret` のみ。 `array` / `record` /
  `tagged` / scalar は inline 固定 (spec)
- 「巨大 list を 1 個の ref にする」 は v0.1.0 では禁止。 list spine は常に inline、
  要素単位で string / file が ref 化される

## 6. string と file を別 primitive 型に (D6)

- `string` = UTF-8 text。 内容そのものに意味 (= 値型)
- `file` = opaque bytes。 entity 性が強い (= identity 型)
- 実装上は同じ `BytesRep` を共有 (= runtime コードは 1 セット、 言語型は 2 つ)
- stdlib の `Image` / `Audio` / `Document` newtype は **不要** (= 全部 `file` で統一)。
  contentType は `BytesRep` の metadata として持てば十分

binary を読む prim は partial read 中心 (`file_size`、 `image_dimensions` 等は header
だけ fetch)。 全展開 prim (`file_to_bytes` 的なもの) は提供しないか、 明示的に
materialize する旨を documented にする。

## 7. equality semantics (D7, D9)

| 比較               | semantics                                              |
| ------------------ | ------------------------------------------------------ |
| `string == string` | **content 比較**。 inline は bytes、 両 ref は hash、 mixed は materialize して比較 |
| `file == file`     | **identity 比較**。 `(module, id)` の一致のみ。 content は無関係 |

file の identity 比較を成立させるため、 **file は inline を持たない (= 常に ref、 id を持つ)**。
file を作る操作は必ず ref produce 経由 (= API upload / sidecar produce / `string_to_file`)。
言語に file literal は無い。

```katari
let f1 = upload_received()
let f2 = upload_received()      // 同 content、 別 entity
let s1 = file_to_string(f1)
let s2 = file_to_string(f2)

f1 == f2     // false (= 別 id)
s1 == s2     // true (= 同 content)
```

変換 prim:

**`file_to_string(f) -> string`** — re-tag だけ (zero-copy)。 f は常に ref。 `kind` を
file → string に付け替え、 `rep` (= 同じ ref) を流用する。 produce 不要。 string になった
後は content 比較 (hash) で振る舞い、 underlying content を file と共有する。

```
{ kind: "file", rep: ref(owner, id, ...) } → { kind: "string", rep: ref(owner, id, ...) }
```

**`string_to_file(s) -> file`** — 新 file ref を produce。 file は identity 型なので変換は
新 entity (= 新 id) を作る。 content は dedup されるので byte copy はない:

- s が inline → bytes を value store に書く (hash 計算 → dedup or 新規 blob) → 新 ref
- s が ref → content は既に store にある → 同じ hash を指す新 ref id を作る

```
{ kind: "string", rep: ... } → { kind: "file", rep: ref(owner=core, 新 id, hash, complete) }
```

ここで **CORE が value producer になる** (§10 参照)。

file は literal pattern match 不可 (= 型エラー)。 string は literal pattern OK (= 既存)。

## 8. blob の GC = reachability (D10)

ref には 2 種類あり、 寿命が違う ([storage-schema-and-api §2](2026-05-30-storage-schema-and-api.md)):

- **ephemeral ref** (`value_refs`、 owner=core/ffi): CORE/FFI の中間値。 **reachability GC**
- **persistent file** (`api_files`、 owner=api): user 管理。 明示削除のみ (GC 対象外)

blob (= file 本体の bytes) は両者から hash で参照され、 **参照が 0 で物理 delete**:

```
reachability GC (project actor 内、 tick と直列なので race なし):
  1. project の全 shard state を walk → reachable な ephemeral ref id を mark
     (= CORE scope の値 + in-flight delegation/escalation args)
  2. unreachable な ephemeral ref → value_refs から delete
  3. hash を指す value_refs + api_files が 0 の blob → 物理 delete
```

trigger:

| trigger                       | 対象                                              |
| ----------------------------- | ------------------------------------------------- |
| 定期 / heuristic GC (既存 closure GC と同枠) | unreachable な ephemeral ref + 孤立 blob |
| agent instance 完了 / cancel   | その instance の ephemeral ref (`owner_instance_id`) |
| project file 明示削除          | `api_files` row delete → 参照 0 で blob sweep       |
| snapshot / project 削除        | cascade で全 ref + file + blob delete               |

- **dedup**: 複数 ref が同 hash を指せるので、 blob 削除は「その hash を指す ephemeral ref +
  api_files が 0」 のとき
- ephemeral の reachability traversal は single-runtime 前提 (= project=single activation)。
  multi-server / within-project sharding での扱いは [v0.2-streaming](2026-05-30-v0.2-streaming.md)
- producer の途中 cancel (building stream) は v0.1.0 には無い (= producer は delegation 内で
  完結、 通常の terminate cascade)。 building-cancel / 動的 reachability は v0.2

## 9. file-upload も file-creation も complete ref を作る (D11)

両方とも「complete blob を produce して ref を返す」 同じ形。 producer (FFI handler / API
upload) は累積 or chunk push してから close し、 ref は complete になる。 CORE は close まで
block (= α)。

大 file (音声等) の consume は storage の chunk から range / chunk fetch (memory に全部
載せない)。 mid-stream subscribe (= 完成前に逐次読む) は v0.2。

consume 側の選択 (v0.1.0):

- `materialize` (= 全 bytes) — 小さい ref / 全体が必要なとき (CORE の `==` / match 等)
- `fetch range / chunk` — 大きい complete file を memory に全部載せず読む (FFI service)
- `subscribe` (= 完成前から chunk iterate) は v0.2 ([v0.2-streaming](2026-05-30-v0.2-streaming.md))

## 10. inline ↔ ref の昇格 と CORE の producer 化 (D31)

`string` / `secret` は inline か ref。 `file` は常に ref。 inline → ref の昇格タイミング:

> **in-tick の計算中は inline のまま (= 速い)。 値が externalization boundary を越える
> ときに、 threshold T を超える inline byte-sequence を owner=core の ref に昇格する。**

### 昇格は persist (shard → DB) でのみ行う

唯一の昇格境界は **shard の persist** (= snapshot serializer):

```
shard persist (async):
  shard の値を walk → threshold 超の inline byte-sequence を owner=core ref に昇格
  (= blob を value_blobs に書き、 value_refs(owner=core) を作り、 persist 形を ref に置換)
```

理由: 大きい inline が shard JSONB を膨らませると、 その shard を load する毎にコストが効く。
これが昇格の本来の目的。 in-memory の shard 値は inline のまま cache してよく (= 速い)、
persist 形だけ ref 化すれば次の quantum の load は軽い。

**bus / wire では昇格しない**:

- **bus event (CORE→CORE 等)** は Value のまま transient に流れる。 値は受信側 shard に
  着地し、 その shard の persist で昇格される (= bus level の昇格は不要)
- **valueToRaw (sidecar/REST wire)** は as-is で serialize (§11)。 inline → inline、
  ref → `$ref`。 昇格も materialize もしない (= 大 bytes を IPC に乗せない)

- `file` は昇格対象外 (= 既に ref)
- `secret` は v0.1.0 は inline 固定 (= 暗号化して持つ、 昇格は v0.2)
- threshold T はチューニング param (初期 ~4KB)

### CORE が value producer になるケース

owner=core の value が生じるのは:

1. **threshold 昇格** (上記)
2. **`string_to_file`** (§7、 新 file ref を produce)
3. 大きい値を明示的に作る prim (= 将来増えうる)

CORE は host process 内なので produce は **value store に直接書く** (= data plane HTTP を
通さない、 module-internal produce、 [runtime-architecture §8](2026-05-30-runtime-architecture.md))。
昇格後の bytes は `value_blobs(owner=core)` に置かれ、 sidecar 等の別 process は data plane
経由で fetch する。

### 注: AI 会話履歴は昇格に依存しない

LLM 応答は FFI が ref で返す (owner=ffi)。 `history = append(history, Message(content=response))`
と書くと array spine は inline・大きい content は ref のまま。 自然な書き方なら大きい
bytes は最初から ref で、 CORE 昇格は「CORE 内で巨大 inline string を作ってしまった」
場合 (= `format` で全 history を 1 本の prompt にする等) の保険。

## 11. RawValue wire format (D35)

`RawValue` = 値の **schema-less な JSON wire 表現**。 現状 `value-codec.ts` の
`valueToRaw` / `valueFromRaw` が担う。 内部 (engine / bus event) は `Value` (tagged union) の
まま流れ、 **RawValue は外部境界でだけ使う**:

- **sidecar IPC** (= `ParentToChild` / `ChildToParent` の args / value)
- **REST / external 境界** (= run args、 結果)

注: 永続化 (engine checkpoint) は RawValue ではなく `Value` 形の JSON (snapshot.ts、 secret
暗号化付き)。 data plane (`GET /value/...`) は RawValue ではなく **生 bytes** を返す。 RawValue
が運ぶのは「値の identity / 構造 + 小さい inline」 であって blob bytes ではない。

### v0.1.0 の encoding

| Value | RawValue |
| --- | --- |
| number / boolean / null | そのまま (`5` / `true` / `null`) |
| string (inline) | bare JSON string (`"hello"`) |
| **string / file (ref)** | **`$ref` envelope** (下記) |
| array | JSON array (要素を再帰) |
| record | plain object (discriminator なし = fall-through) |
| tagged | `{ "$constructor": "Mod.Ctor", ...fields }` |
| agentLiteral | `{ "$agent": ... }` (**snapshot を含む**、 下記) |
| closure | `{ "$agent": "closure:..." }` (machine-local stamp、 現状踏襲) |
| secret | `{ "$secret": "<plaintext>" }` (out のみ、 in は拒否。 v0.1.0 は inline 固定) |

### `$ref` envelope (新規)

```json
{
  "$ref": { "module": "core" | "ffi" | "api", "id": "<uuid>" },
  "as": "string" | "file",        // semantic kind (受信側が Value.kind を復元するため)
  "hash": "blake3:...",            // v0.1.0 は常に complete なので確定
  "size": 1234,
  "contentType": "image/png"       // optional
}
```

- `project` は載せない (= ambient、 D24)。 sidecar は `KATARI_PROJECT_ID` から、 receiver は
  自分の project context から補う
- v0.1.0 は ref が常に complete なので `hash` / `size` が必ず付く。 v0.2 の building ref
  (hash 未確定) の wire 形は v0.2 で追加

### agentLiteral は snapshot を含む (D25)

agentLiteral は code reference なので版に依存する。 `$agent` envelope は `(snapshot, qname)` を
運ぶ (現状は qname のみ)。 delegate event の `agentDefId` はこれから導出される
(= 受信 module が自分の registry で decode、 [overview §2](2026-05-30-overview.md))。

### discriminator routing (decode 優先順)

object を decode するとき、 reserved key の優先順で分岐し、 どれも無ければ record:

`$constructor` (tagged) → `$agent` (callable) → `$ref` (value reference) → `$secret` (拒否) → record

(現状の優先順に `$ref` を追加。 record が reserved key を持つと誤読される caveat は現状通り。)

### valueToRaw は as-is (= 昇格も materialize もしない)

RawValue は in-memory transient だが **IPC / wire に乗る**ので、 大きい bytes を inline で
乗せると重い。 よって valueToRaw は **as-is で serialize** し、 ref を materialize しない:

- inline (= 小さい) → bare JSON (1 hop で sidecar に届く)
- ref (= 大きい) → `$ref` envelope。 sidecar が bytes を要れば **data plane で lazy fetch**
  (= bytes 専用経路で 1 GET、 不要なら fetch しない)

つまり「bytes を運ぶのは data plane、 RawValue/IPC は control + 小さい inline + ref」 の
役割分担。 valueToRaw は **sync のまま** (= 昇格しないので blob 書き込み不要)。 昇格は persist
専用 (§10)。 decode (`valueFromRaw`) も sync (`$ref` → `{kind: as, rep: ref(...)}`)。

## 12. JSON Schema と ref: string は union にしない (D36)

rep (inline/ref) は **kind と直交**する。 runtime 値は `{kind:"string", rep: inline|ref}` で、
inline でも ref でも `kind` は `"string"`。 よって **値の検証は Value.kind で行えばよく、
JSON Schema を union にする必要はない**。

役割分担:

| 用途 | 何を検証 | string |
| --- | --- | --- |
| **AI tool calling** (`Katari.Schema`) | LLM が produce する RawValue | `type: "string"` (LLM は inline を作る) |
| **REST client args** | client が produce する RawValue | `type: "string"` (inline) |
| **call_agent / delegate / 戻り値** | 既に Value | **Value × SemanticType (kind 検証)** |

- **`string` → `type: "string"`** (= union にしない。 AI schema は clean)
- **`file` → `$ref` schema** (= file は reference。 LLM は file を produce できないので、
  file param を取る agent は基本 orchestration から呼ばれる)
- ref が現れる経路 (= 昇格された string / sidecar が返す大 string / 前段の値) は全部 **Value
  レベル**で、 そこは `kind` で検証する (= JSON Schema を通さない)

実装上: `schema-validate` を **RawValue × JSONSchema ではなく Value × SemanticType** で行う
(= rep 直交)。 これで AI が見る schema は `type: "string"` のままで、 ref は内部で透過的に扱える。
