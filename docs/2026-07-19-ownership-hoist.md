# Blob 所有権の hoist(上向きイベント駆動, v0.1.0)

owner 決定(2026-07-19): blob の所有権 ascent を **値到達性駆動から「上向きイベント無条件・全件 hoist」へ**変更する。
scope の ascent(reachability drag)は**一切変えない** — 変わるのは blob だけ。本ノートは新規則・境界条件・
なぜ値駆動をやめたか・なぜ cancel だけが暗黙 reclaim なのかを記述する。実装は本 wave で完了(runtime のみ)。

## 動機 — text 平面は id を運ぶが所有権を運ばない

blob の id は **value の外の text 平面**を通って伝播する: AI transcript、`stringify` された JSON tree
(`$katari_ref` が生の string leaf として乗る)。この text を保持する caller は id で blob を覚えているが、
その blob は value の `ref` として到達可能ではない。旧・値駆動 ascent(`reachableResources` walker)は value に
乗った resource しか上げないので、**value に乗らなかった blob は producer instance の完了と同時に FK cascade で
消える**(`blobs.owner_instance_id ON DELETE CASCADE`)。すると AI が id で覚えている blob が忽然と失われる。

## 新規則

> instance が**観測可能な上向きイベント**(`delegateAck` の結果、`escalate` が運ぶ ask)を送るたび、その時点で
> own している**全ての blob**を、1 段上(受信側の caller instance)へ**無条件・全件 reassign する**(hoist)。

- 値到達性は問わない。value に乗った blob(scope 経由の `ref`)は従来どおり value 駆動の release→reown で上がり、
  乗らなかった残りを hoist が拾う。両者は同じ caller instance に合流する(実装は release を先に走らせ、hoist は
  「まだ issuer 所有のまま = value に乗らなかった分」だけを動かす — 既存の値駆動 blob ascent は無変更)。
- scope は対象外。closure が捕捉する scope 鎖は今も value 駆動の reachability drag のみで動く
  (`docs/2026-06-15-runtime-domain-model.md` の Ascent 節)。hoist は blob だけ。

**不変条件**: blob は観測可能な上向きイベントでのみ delegation chain を 1 段ずつ上に移動し、cancel(や failure)は
その時点でカット位置より下にある保有分を正確に刈る。escalate の hoist は**各ホップで**適用される — 中継 instance
(ffi call が子の ask を relay 再送する、core が子の escalate を re-raise する)の再送も上向きイベントなので、そこでも
1 段上がる。

## seam — なぜ送信側(callee 側の `Reactor.send`)か

hoist は**送信側**、送信 instance 自身の commit の中で走る。理由は FK cascade のタイミングにある:

- blob row は所有 instance と cascade delete する。完了 instance の teardown はその envelope を drop し、まだ own して
  いる blob をその**同じ commit**(最終 `delegateAck` を emit する commit)で消す。caller が react するのは**後続
  commit**なので、受信側で reassign しようとすると blob は既に cascade 済みで存在しない。**受信側案は原理的に成立
  しない**(task が挙げた「caller の onDelegateAck で reassign」案はこの理由で不採用)。
- teardown より前・送信 instance の commit の中でのみ「blob がまだ存在し、かつ移動先が判る」。そこで reassign する。
  `core-reactor.ts` の `runTurnWith` は `send`(→ hoist)を teardown より前に走らせるので、正常完了では hoist が先に
  済み、teardown の `reclaimBlobsOwnedBy` は自然に空振りする。

### 送信側は移動先(caller instance)をどう知るか — delegate に `caller` を積む

送信側は callee reactor で、caller **instance** を本来知らない(caller-side の delegation row は caller reactor が
持つ; 外部呼び出しでは cross-reactor)。そこで **`delegate` イベントに `caller: InstanceId` を足し**、base `Reactor.send`
が delegate を送る際に issuer(= caller instance)を stamp する。callee は受信辺(`acceptDelegation`)にそれを記録し、
後で上向きイベントを送るとき `handledCallerInstanceOf(delegation)` を読んで reassign 先にする。

- **durability**: この caller instance は callee 側の envelope には持たないが、`delegations.caller_instance_id`
  (**全 delegation の SoT**)として永続する。restart 後、core は自分が発行した row だけでなく**自分宛て
  (`to = core`)の全 delegation**を引いて caller instance を再導出する(`core.load` の `summoningDelegations`)。
  これにより webhook subscriber / mcp.serve continuation / ffi inner delegation が召喚した core instance —
  caller-side row を core が持たない — の hoist 先も restart を跨いで正しく蘇る。外部呼び出しの reloaded call
  だけは at-most-once recovery で失敗し(in-memory の produced blob も消えている)そもそも hoist しないので、
  `undefined` で足りる。reassign は必ずそれを正当化するイベントと同一 turn/commit で永続化される(restart 後に
  「イベントは届いたが所有権が動いていない」もその逆も起こらない)。

## 境界条件

1. **run→api 境界は hoist しない**(現行の値駆動 ascent のまま)。run instance は永続で、そこへ全件 hoist すると
   run のたびに全 blob が run の一生ぶん pin される。`send` は `handledCallerOf(delegation) === "api"` のとき hoist を
   skip する。結果値が運ぶ `ref` は従来どおり value 駆動で run へ ascend し、運ばれなかった run-root 所有 blob は
   run teardown の reclaim で回収される(既存動作を維持)。
2. **scope は対象外**(上述)。value 駆動 release/reown と reachability GC は無変更。
3. **cancel/teardown は無変更** — `markInstanceDropped` → `reclaimBlobsOwnedBy` が唯一の暗黙 reclaim。正常完了は最終
   ack の hoist が先に走るので teardown は空振りする。
4. `adoptDetachedProducedBlobs`(外部呼び出しの produced-blob 採用)は**撤去済み**。hoist が produced blob を
   無条件で caller instance へ上げる(値に乗らなくても)ので、per-call の採用 backstop は不要になった。
   `reassignOwnedBlobs` の `blobIds?` 引数(採用用の narrow 経路)も併せて削除し、whole-holding hoist 専用の
   シグネチャに整理した。

## なぜ cancel だけが暗黙 reclaim なのか

正常完了・escalate・relay の全ての上向きイベントは blob を明示的に 1 段上げてから teardown する。**failure も
同じく hoist する**: program-level の `prelude.throw` / panic も、reactor 級の `raiseThrow` / `raisePanic` も、
すべて `send` 経由で escalate するので、他の上向きイベントと同様に payload の運ぶ値を release し、raiser の残り
blob を caller へ hoist する。これは必須で、typed throw の payload は callee の無条件 wire decode で**本物の `ref`
を運ぶ**ことがあり(その ref を catcher が読めるよう in-transit へ release する)、id を text 平面でのみ運ぶケース
でも hoist が blob を caller へ上げる — どちらも hoist しなければ失敗 instance の teardown が blob を刈って
catcher の ref を dangling(`files.gone`)にしてしまう。

したがって teardown 時に instance が持つ blob は「**上向きイベントを一度も送らずに死んだ instance の保有分**」
だけになる — cancel で上流イベントが飛ぶ前に切られた subtree、あるいは instance 成立前の pre-instance panic
(hoist 先の受信辺がまだ無く、hoist は自然に skip される)の分だ。これはまさに「cut より下にある保有分」であり、
`reclaimBlobsOwnedBy` がそれを正確に刈る。よって暗黙 reclaim は cancel(と上向きイベント前に死ぬ subtree)の
1 経路に集約される。

## 実装メモ

- **`blobsByOwner` index**: `scopesByOwner` と対称に `ProjectStore` へ追加(`engine/blob.ts` が register/re-own/free/
  hoist で維持、load 時再構築 `rebuildBlobOwnerIndex`)。teardown reclaim と hoist の per-owner 走査は index 参照で O(所有分)。
- **`reassignOwnedBlobs(from, to)`**: `from` の**保有全件**を index 経由で hoist(`blobsByOwner` の bucket を
  コピーして走査、ledger 全走査なし)。かつての produced-blob 採用向け `blobIds?` 引数は撤去済み — hoist が
  その役割を包含する。
- 変更は runtime のみ。event schema は outbox の JSONB payload に optional field を足すだけで DB migration 不要。

## 関連

- scope の値駆動 ascent と capture 参照: `docs/2026-06-15-runtime-domain-model.md`(Ascent 節)。
- blob ref の value 表現: `docs/2026-07-09-slim-blob-ref.md`。
