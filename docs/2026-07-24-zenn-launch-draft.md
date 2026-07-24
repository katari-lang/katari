---
title: "AIエージェントのための言語を作っている — Katari v0.1.0 と、一晩で建てたマルチエージェント常駐システム"
emoji: "🗣️"
type: "tech"
topics: ["ai", "agent", "言語処理系", "effectsystem", "katari"]
published: false
---

<!-- DRAFT — yukikurage レビュー用。公開前に: リポジトリ URL / docs URL の確定、tsukasa 実走スクショ、文体の最終調整 -->

## 何を作ったか

AI エージェントのオーケストレーションを書くための言語 **Katari** を作っています。このたび v0.1.0 を公開しました。

- コンパイラ (Haskell) が Katari ソースを IR にコンパイルし、常駐 runtime (TypeScript) がそれを実行・永続化します
- プログラムの実行状態は**耐久的**です。runtime を再起動しても、実行中のワークフローは続きからそのまま再開します
- 並行・並列が第一級です。「複数のエージェントが協調して動く」を、言語機構で直接書けます

この記事では言語の中身を、**「本当にマルチエージェントシステムに耐えるのか」を確かめるために一晩で建てた常駐システム**の話と一緒に紹介します。そもそもこの言語を作り始めた動機が「こういうものを書きたい」だったので、これはローンチ記事であると同時に、自作言語の耐久試験レポートでもあります。

## Katari の骨格: agent / request / handler

Katari の関数は `agent` と呼びます。effect system を実用に振り切っていて、**「能力 (capability)」はすべて request (= effect) として宣言し、handler が実装を与えます**。

```katari
@"The approval escalation: performed BEFORE a sensitive action runs."
request approve_action(description: string) -> boolean

agent start_watch(topic: string) -> string {
  if (approve_action(description = f"START watch ({topic})")) {
    ...
  } else {
    "(refused by the operator)"
  }
}
```

`approve_action` を**誰がどう答えるかは呼び出し側の文脈が決めます**。Discord のボタンで operator に聞く handler を挟んでもいいし、handler を挟まなければ escalation として実行の外側 (管理画面) に浮上します。「人間への問い合わせ」も「API キーの注入」も「別エージェントへの委譲」も、全部この一つの機構です。

型システムは effect row を追跡していて、**「この region で起こりうる全 request を handler が覆っているか」までコンパイル時に検査されます**。後述の `region.crashed` が象徴的ですが、「扱い忘れ」がランタイムの深夜の事故ではなくコンパイルエラーになります。

## 耐久性: 時刻さえ effect

runtime の replay 契約は「turn は耐久的入力の決定的関数」です。だから `Date.now()` に相当するものは言語内に存在せず、`time.now()` は runtime の reactor への外部呼び出しです。取得した時刻は観測した処理と**原子的に**永続化され、以後 replay で変わりません。sleep のデッドラインも cron の次回発火も永続化されます。

この上に「1週間後にリマインドする」「毎朝 7:30 にブリーフィングを組み立てる」が、**プロセスの生死と無関係に**素朴なコードで書けます。

## region: fork はするが join はしない

並行の中心は `region` — 構造化並行性の nursery です。設計上の際立った選択は **join が存在しない**こと。

- fiber は `-> null`。**結果は settle ではなく escalation で運ぶ** (伝えたいことがある task は、最後の行為としてそれを perform する)
- fiber たちの escalation は `region.watch` という一点 (white hole) に湧き上がり、そこを囲む handler が捌く
- nursery の ceiling (fiber が起こしうる effect の上界) を型引数で宣言するので、「region を扱う」ことが**全 request をカバーする総体的義務**としてコンパイル時に閉じる

そして今回の v0.1.0 で、**nursery 自身が registry になりました**。`fork` に名前タグ、`roster` は runtime の生存真実の直読 (ミラーが無いので絶対に stale にならない)、`cancel_by_id`、そして fiber の panic は raw panic ではなく **型付きイベント `region.crashed(id, name, message)`** として watch から湧きます。

```katari
use handler {
  request region.crashed(id: string, name: string, message: string) {
    if (name == source_name) {
      // 入力源の死はセッションの死 — supervisor が再起動する
      prelude.throw(error = source_died(message = message))
    } else {
      // 監視 fiber の死はモデルへの報告 — 必要なら再起動を「AI が」判断する
      ai.observation(source = "watch", content = f"(watch ${name} died: ${message})")
      next null
    }
  }
}
```

**crash の「意味」を決めるのはアプリの handler です。** runtime はデータを届けるだけ。そして `crashed` は watch の effect row に入っているので、この handler を書き忘れたプログラムはコンパイルが通りません。

## 耐久試験: 一晩でマルチエージェント常駐システムを建てる

Discord ボットとして始まったサンプルを、一晩で **tsukasa** — 複数の AI エージェントが協調する常駐システム — に組み替えました。

- **ONE region = メッセージバス**。唯一の dispatcher (逐次 handler) が全エージェントの会話 (`record[ai.session_state]`) を保持し、届くイベントはすべて宛先つき
- **エージェント間メールは micro-fiber**。送信ツールは「`agent_message` を perform するだけの fiber」を fork する。escalation は region の mailbox に**現在の turn の後ろに**並ぶので、turn 中の送信が逐次 dispatcher に再入してデッドロックすることが構造的にない。FIFO で、しかも耐久的 (mailbox は再起動を跨ぐ)
- **Discord への発言もツール**。エージェントの最終テキストは「自分用のメモ」で、喋りたければ `post_discord` を 0 回でも 5 回でも呼ぶ。無視も、二度返信も、cron からの深夜の独り言も、全部ただのツール使用
- **権限境界は store の幾何**。private な core エージェントと、公開チャンネルに住むキャラクターボット herald は、能力 (ツールリスト) が違うだけ。herald の投稿ツールはチャンネルを閉じ込み、herald が operator の生活を知る唯一の窓は「core が書き herald が読む 1 セル (公開ダイジェスト)」— private→public の継ぎ目がツールリストを読むだけで監査できる
- **SOUL システム**。人格は store 上の層 (identity / soul / user / ops) で、**ハードな文字数上限つき** (personality creep 対策を助言ではなく機構にする)。各 turn ごとに `ai.with_context` で注入するので、会話の compaction に人格が食われることがなく、自己改定 (`refine_soul`) は次の turn から効く

書いてみて確信したのは、**この言語の機構が (偶然ではなく) マルチエージェントの要請と噛み合う**ことです。region の mailbox がそのままメッセージキューになり、handler の逐次性がそのままアクター的直列化になり、effect row がそのまま「このシステムで起こりうる全て」の目録になる。

## 正直な摩擦も全部ログした

無傷だったとは言いません。構築中に当たった言語の摩擦は 13 件、すべて [`PAIN.md`](リンク) に記録しました。うち同夜に自己解決したもの:

- `mcp.open` — MCP サーバーへの listing 不要の接続 (pull 済みバインディングは静的に呼ぶので listing が無駄だった)
- エラーメッセージ 3 件の改善 — 「`io` は request ではないので波括弧の外で union する」「agent のパラメータ名は型の一部」「effect row は type synonym に括り出せる」を、エラー自身が教えるようにした
- 2 件は**誤診**だった — 文字列リテラルの match も object literal も言語に既にあった (ドキュメントが無かっただけ)。ドキュメントを直した

残りは設計判断として持ち越し (store の atomic RMW、宛先ごとの keyed-sequential handler、など)。**アプリを書いて言語に還流するループがこの速度で回る**のが、自作言語で一番楽しいところです。

## 使ってみる

```sh
# CLI と runtime (docker) — 詳細はドキュメントへ
katari init my_agent && cd my_agent
katari check && katari apply
katari run my_agent.main --detach
```

- ドキュメント: https://katari-lang.dev (エージェント向けに MCP でも提供: https://katari-lang.dev/mcp)
- リポジトリ: <!-- TODO: 公開 URL -->
- tsukasa (マルチエージェントの実例): <!-- TODO: 公開 URL -->

v0.1.0 は「趣味プロジェクトを載せて壊れたら教えてほしい」段階です。感想・issue お待ちしています。
