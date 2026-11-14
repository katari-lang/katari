# slim BlobRefValue — file 値は identity のみを運ぶ

## 背景

`file` 値（`BlobRefValue`）は `{ blobId, semanticKind, hash, size, contentType? }` を運んでいた。
hash/size/contentType は blobs テーブル行（SoT）のキャッシュであり、値がそのまま wire form
（`{"$katari_ref", "size", "hash", ...}`）として AI の読み書き面に露出していた。

実地で起きた事故: モデルが `view_image` に `{"$katari_ref": "..."}` だけを replay し、decode が
size/hash を要求して panic → serve ループ全体が死亡。一次対応としてスキーマで full handle を
必須化したが、これは「信頼できない語り手（モデル）にキャッシュの複写責任を負わせる」逆向きの
修正だった。さらに、モデルが偽の size/hash を書いても decode はそれを信じるため、エラーにすら
ならない silent corruption 面が存在した。

## 決定

1. **`BlobRefValue` は identity のみ**: `{ kind: "ref", semanticKind, blobId }`。
   メタデータ（hash / size / contentType / owner）は blobs 行が唯一の SoT で、
   必要な場所（`prelude.files` prim、files API、port）が行を読む。
2. **wire form は `{ "$katari_ref": id, "$katari_semantic_kind": kind }`**。受け入れは bare
   `{"$katari_ref"}` で完全（semanticKind は `file` にデフォルト）。wire が余分に運ぶフィールドは
   無視する — 偽造できるものが存在しない。
3. **ref の `==` は blob IDENTITY**（同一 blob id）。file はリソースでありリテラルではない:
   同じバイト列を 2 回アップロードすれば別の file。
4. **将来の大文字列昇格（R5/CORE promotion）の前提条件**: 昇格 string の `==` は構造的
   （内容比較）でなければならないので、昇格を実装する時は **content-addressed な blob id
   （blobId = content hash）で mint すること**。そうすれば identity 比較がそのまま内容比較になり、
   hash フィールドを値に戻す必要は永久にない。

## 帰結

- モデルが handle を replay する負担は「id を 1 個コピーする」だけ。コピーミスで壊れる
  メタデータは存在しない。
- `prelude.files.size` / `content_type` は PrimContext の warm blob catalog
  （ProjectStore.blobs — actor ロード時に全行ロード済み）から行を読む。
  dangling id（`free` 済み/削除済み/捏造）はそこで **catchable な `throw[prelude.files.gone]` を送出する**
  （e044b80; read-after-free は panic ではなく、プログラムが捕捉できる典型エラー）。
- port の `KatariFile` は size/contentType を blob side channel（download 応答のヘッダ）から
  遅延取得する。hash は消費者がいないため API から削除。
- console の file 表示は size/contentType が wire に無ければ単に省く（FileChip は元々 null 許容）。
