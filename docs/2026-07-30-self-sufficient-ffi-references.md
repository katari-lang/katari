# 自己充足する FFI 参照 — プロセスローカル状態を durable な値が指してはならない

2026-07-30。v0.1.0 公開直後の設計決定。owner との対話から導出。

## 症状

v0.1.0 の examples レビューで見つかった: **FFI backed の常駐(discord/slack の watcher)は
ランタイム再起動を生き延びず、しかも tutorial が教えていた回復手順(`region.crashed` で re-fork)は
ちょうど無音のクラッシュループを作る。**

機構:

1. `discord.provider` が `create_discord_client(token)` を 1 回呼び、返ったハンドル文字列を
   `connection` request で配る。sidecar 側の registry は **プロセスローカルな module state**
   (`const clients = new Map()`)で、`connectionOf` は miss で bare throw = panic。
2. 完了した effect は commit され、復旧は再実行ではなく **committed state からの replay**
   (`concepts/durable-execution.md`: "recovery replays from committed state instead of re-running your effects")。
3. ⇒ 再起動後の replay は **同じハンドル文字列を、Map が空の新プロセスに配る**。
   以後その handle 経由の全呼び出しが panic。re-fork しても stale なままなのでループする。

## 誤診の記録(3 案とも却下)

owner の指摘で順に落ちた。記録として残す — どれも「漏れを管理する」案で、漏れ自体を消していない。

1. **`connection` を直和(`available | lost`)にする**: 却下。`provide` の契約は
   「このブロックの内側では connection が serve されている」であり、**可用性は provider の責務**。
   直和にすると契約を呼び出し側に押し付ける。e2b の `session_ready | session_unavailable` が正しいのは
   あれが**ユーザーが明示的に作るセッション**だから。ambient な資源に同じ形を当てるのは誤り。
2. **prim `process.identity()` + epoch 比較**: 却下。**処理系の都合(プロセス境界)が DSL に侵食する**。
   epoch は「ポインタが腐った」ことを検知する道具で、腐る事実は残る。
   (なお根拠として引いた「prim は replay で再計算される」も論の向きが誤り。time-reactor のコメントは
   prim の**危険性**を述べたもので、機構の土台ではない。`create_discord_client` が再発火しないのは
   replay の癖ではなく **単に終わった計算だから**。replay は無罪。)
3. **descriptor(名前 + credential)+ port/runtime の資源機構**: 却下。統一機構としては筋が通るが、
   「名前と credential を一緒に持つ意味は?」という問いが本質を暴いた(下記)。

## 法則

> **durable なプログラムが持てるのは durable な値だけ。プロセスメモリへのポインタはそれではない。
> だから境界を越えて言語側に来てはいけない。**

Katari はこの判断をデータ平面では既にしている: `store` は行へのポインタではなく **キー** を渡す。
だから store のハンドルが再起動で腐ることは原理的に起こらない。**FFI 平面だけがしていなかった。**

## 規則(実装が従うもの)

> **FFI 呼び出しは、行為に必要なもの(遠隔の名前 + credential)を受け取る。
> sidecar はそれをキーにローカルにキャッシュしてよいが、durable な値がキャッシュを指してはならない。**

「名前と credential を一緒に持つ」意味は **参照の自己充足性**である: その 2 つが揃っていれば
**どのプロセスからでも**その資源を使える。だから再確立という概念が要らない。

## 既にツリー内にある模範例: e2b

```katari
external agent e2b_run_in(session: string, code: string, api_key: string of private) -> unknown
data session_data(session_id: string, api_key: string)   // 名前 + credential
```

doc は「`e2b_run_in` replays to reach the same sandbox」と述べている。sidecar は live な
オブジェクトを一切持たない ⇒ **e2b は再起動バグに構造的に免疫がある**。

| | 参照の中身 | プロセスを越えられるか |
|---|---|---|
| e2b | 遠隔サービスの id + credential | ✅ 何も壊れない |
| discord / slack | ローカルメモリ上の client へのポインタ | ❌ 壊れる |

## 決定

discord / slack を e2b の形に寄せる。**新しい prim も descriptor 型も port の機構も runtime 変更も不要。**
概念は増えるどころか減る(`create_*_client` / `*_close` / `connection` request が消滅する)。

1. **無状態化できる操作**(send / try_send / ask の投稿部 / limits 等):
   各呼び出しが `token` を受け取る。REST はログイン不要なので完全に無状態。
   sidecar が token キーで REST client を再利用するのは**純粋な最適化で誰からも見えない**。
2. **本質的に live な操作**(gateway の watch、interaction を待つ ask):
   **自分の呼び出しの寿命だけ** socket を持つ。再起動で死ぬのは at-most-once として当然で、
   fiber を re-fork すれば新しい socket ができる。
3. **gateway の共有**: sidecar 内部で token をキーに socket を共有し、live な watch/ask が 0 に
   なったら閉じる(refcount)。**規則に従っている** — durable な値がそれを指さないので、
   再起動時はキャッシュが空なだけで、指していた呼び出しも既に死んでいる。
4. **`provider` の役割**: credential を scope に配るだけになる。credential source は既に
   durable な data 値なので、これは `credentials` が既に持っている機能そのもの。

## 帰結: 今日入れた対処は撤去する

v0.1.0 で examples 4 本と tutorial / ffi-sidecars に入れた
`replay.forever` + panic converter + `region.crashed` → `replay.interrupted` の supervisor 一式は、
**機構が無い前提での正しい対処**だった。この規則が入ると不要になるので撤去する — 残すと
「必要な儀式」を教えることになる。

`ffi-sidecars` ガイドには代わりに**規則そのもの**を書き、e2b を模範例として引く。

## 直らないもの(仕様として明記)

in-flight の呼び出し自体は再起動で死ぬ(at-most-once。原理的に避けられない)。
**変わるのは、re-fork が機能するようになること。** 死ぬのは中断された呼び出し 1 回だけになり、
session の建て直しは不要、desk の状態(会話・収集済みの返信)は残る。

## v0.1.1 スコープ

1. discord 0.7.0 / slack 0.5.0: sidecar + package を上記の形に(破壊的)
2. examples 4 本 + tutorial + ffi-sidecars から儀式を撤去、ガイドに規則を明記
3. katari-verify を 0.1.0 / 最新 snapshot へ再 pin
4. レビューが洗い出した診断・API の小欠陥(別 doc の台帳)
5. パッケージ再公開 → snapshot cut → 消費者再 pin
