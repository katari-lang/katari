---
title: 構文案: Kotlin 風
description: 式指向・型注釈・ブロック。header が親向けの interface、body は宣言の集合、run だけが逐次
---

`syntax-requirements.md` の要件 A〜F に対する案。意味論は固定、構文だけを決める。

## 1. 概要

3 文で:

1. `component` は params（時変）から **宣言の集合** を組み立てる。宣言は React の子要素のように reconcile され、runtime が terraform のように init / update / dispose する。
2. 子は `val` で宣言する。`-> Tag` を付けた子の event は自分の `inbox` に `Tag(event)` として届く。付けなかった子には run から `child.send(msg)` で送れる（子が inbox を header で公開していれば）。
3. `run { }`（または `loop { }`）が唯一の逐次コード。`await` で待ち、`var` で宣言した state を書く。

### keyword

| 種類 | keyword |
| --- | --- |
| Katari 固有 | `component` `tool` `extern` `migrate` `inbox` `emits` `run` `moved` |
| 借用（Kotlin / JS） | `val` `var` `export` `fun` `if` `else` `for` `in` `when` `is` `loop` `break` `try` `catch` `finally` `throw` `await` |
| `extern` 内の文脈語 | `update` `restart` `finish` `lifecycle` |

`emit` `send` `next` `all` `first` `all(...)` `race(...)` `outcome { }` `watch { }` `bind` は組み込み関数・メソッドで、keyword ではない。
`key = ...` は子の構築子に渡せる予約名の引数（React の `key`）。

### 宣言と逐次の見分け方

- 宣言（body）: `val` `var` `inbox` `export` `fun` と、宣言だけを含む `if (…) { … }`、`val 名前 = for (…) { … }`。代入文は無い（`var` の `=` は初期値）。
- 逐次: `run { }` `loop { }` `tool … { }` と component 内の `fun … { }` の中だけ。`await`・代入 `x = e`・`break`・`throw` はここにしか現れない。
- body の `for` は必ず `val 名前 = for`（値は `Map`）。run の `for` は裸の文。
- body の `if` の中身は宣言だけ。run の `if` は文。

component の header（`(...)` と `inbox` と `emits`）が親から触れるもの全部。body は親から見えない（`export` した値だけが output として見える）。

## 2. 要件ごとの表現

### A. component 定義

| | 表現 | 例 |
| --- | --- | --- |
| A1 | 名前と型付き params。params は時変で、変われば body が reconcile される | `component Worker(task: Task, model: String = "default") { … }` |
| A2 | body は宣言の集合。順序なし | `{ val a = …  var n = 0  loop { … } }` |
| A3 | `export` の付いた宣言の直積が output。無ければ `Unit` | `export var reply: String? = null` → output `{ reply: String? }` |
| A4 | `inbox` を **header に書けば公開**（親が `send` できる）、**body に書けば内部用**（配線した子の event だけ） | 公開: `component Agent(cfg: Config) inbox Ask(q: String) \| Stop { … }`<br>内部: `component Echo(id: String) { inbox Message(msg: discord.Message) … }` |
| A5 | header の `emits` に直和を書く | `component Approval(req: Request) emits Decided(ok: Boolean) { … }` |

### B. 宣言

| | 表現 | 例 |
| --- | --- | --- |
| B1 | `val 名前 = Child(args)`。名前が address。`key =` で同一性を上書き | `val pr = github.pr(repo, head = branch.name, key = change.id)` |
| B2 | 配線する子は `-> Tag` を付ける。付けない子は `.send` を持てる。配線した子は `.send` を持たない（型エラー）。`for` の中の配線は `Tag(key, event)` の 2 引数 | 配線: `val ch = discord.channel(id) -> Message`<br>send: `val agent = Agent(cfg)` … `agent.send(Ask("…"))` |
| B3 | `var 名前: 型 = 初期値`。body にしか書けず、代入は run の中だけ | `var users: Map<UserId, User> = {}` |
| B4 | `if (cond) { 宣言… }`。中の宣言は外からは `T?` で見える。単独なら `val x = if (cond) Child(…)` | `if (reviewing) { val pr = github.pr(…) }` … `await { pr?.url }` |
| B5 | `val 名前 = for ((k, v) in map) { 宣言…; 最後の式 }`。値は `Map<K, V>`、`k` が要素の key | `val workers = for ((id, task) in tasks) { Worker(task) -> Done }` |
| B6 | `export` を `val` / `var` の前に付ける | `export val tools = [summarize.bind(lang = "ja")]` |
| B7 | `run { … }` は 1 つ。`loop { … }` は `run { loop { … } }` の省略形 | `loop { val m = await inbox.next() … }` |

### C. run の中

| | 表現 | 例 |
| --- | --- | --- |
| C1 | 次の 1 件 / 溜まった全件（1 件以上になるまで待つ）/ 条件に合う最初の 1 件（合わないものは残る） | `await inbox.next()` / `await inbox.all()` / `await inbox.first { it is Stop }` |
| C2 | `emit(Tag(…))` | `emit(Done(result))` |
| C3 | `child.send(Tag(…))` | `agent.send(Ask(q))` |
| C4 | `await tool(args)`。Fault は伝播。`outcome { … }` で `Ok(v) \| Fault(e)` として受ける | `val s = await summarize(text)` / `val o = outcome { await summarize(text) }` |
| C5 | `await { expr }`: `expr` が `Boolean` なら true まで、`T?` なら非 null まで待ち、その値を返す。collectLatest は `watch { expr }.collectLatest { v -> … }` | `val url = await { pr?.url }` / `watch { users }.collectLatest { us -> … }` |
| C6 | `名前 = expr`（run の中だけ） | `history += turn` |
| C7 | run の中の `val r = Resource(args)` はそのブロックの間だけ存在する | `val typing = discord.typing(ch.id)` |
| C8 | `await all(a = f(), b = g())` → record。`await race(A = f(), B = g())` → `A(v) \| B(v)`。動的: `await all(for ((k, t) in tasks) work(t))` → `Map` | 下の例 4 |
| C9 | `loop` `for (x in xs)` `break` `when (x) { Tag(a) -> … }` `try { } catch (e: Fault) { }` `throw` | Kotlin と同じ。`when` の分岐は構築子パターン |
| C10 | `run { … } finally { … }`。完走・失敗・cancel のどれでも走る | 下の例 4 |
| C11 | run の中は `val` だけ。`var` は body | — |

### D. tool と純粋関数

| | 表現 | 例 |
| --- | --- | --- |
| D1 | `tool 名前(args): 結果型 { 逐次; 最後の式 }` | `tool summarize(text: String, lang: String): Summary { … }` |
| D2 | `名前.bind(arg = v)` が tool 値 | `summarize.bind(lang = "ja")` |
| D3 | `fun 名前(args): 型 = 式`（top-level。純粋） | `fun short(s: String): Boolean = s.length < 10` |
| D4 | component の中の `fun 名前(args) { 逐次 }`。state を書け、`await` できる。値にならない（`bind` 不可、`export` 不可） | 下の例 2 |

### E. 外部 component

| | 表現 |
| --- | --- |
| E1 | `extern 名前(args) -> { output } inbox … emits …`。header の形は `component` と同じ。body は無い |
| E2 | 引数ごとに `update` / `restart` / `finish` を後置。`lifecycle { replace = allowed \| never, on_boot = restart \| resume, dispose = detach \| keep \| delete }` |

### F. 更新

| | 表現 |
| --- | --- |
| F1 | `migrate 名前(from = 版) { moved a -> b  state b: T = old.a…  inbox { Old(x) -> New(x, …) }  run { l1@ -> l2@ (local = v) } }` |
| F2 | 任意の文に Kotlin 風 label `名前@` を付ける。`val r = ask@ await human.ask(…)`。migration と plan は `run.ask` で参照する |

## 3. 例

### 1. echo bot

```kotlin
component Echo(channelId: String) {
    inbox Message(msg: discord.Message)

    val ch = discord.channel(channelId) -> Message

    loop {
        val Message(msg) = await inbox.next()
        await discord.post(ch.id, "echo: " + msg.text)
    }
}
```

channel は購読（event を受ける子）なので send しない。投稿は tool `discord.post`。

### 2. ターン制 bot

```kotlin
component TurnBot(channelId: String, model: String) {
    inbox Message(msg: discord.Message)

    val ch = discord.channel(channelId) -> Message
    var history: List<Turn> = []

    fun turn(texts: List<String>) {
        val typing = discord.typing(ch.id)                    // この fun が走る間だけ存在
        val reply = infer@ await llm.chat(model, history, texts)
        history += Turn(user = texts, bot = reply)
        await discord.post(ch.id, reply)
    }

    loop {
        val batch = await inbox.all()
        turn(batch.map { it.msg.text })
    }
}
```

### 3. ユーザーごとの常駐

```kotlin
component Lobby(channelId: String) {
    inbox Seen(msg: discord.Message)
        | Conv(user: UserId, event: Conversation.Event)

    val ch = discord.channel(channelId) -> Seen
    var users: Map<UserId, User> = {}

    val conversations = for ((id, user) in users) {
        Conversation(channelId, user) -> Conv
    }

    loop {
        when (await inbox.next()) {
            Seen(msg) -> users += (msg.author.id to msg.author)
            Conv(user, Gone) -> users -= user
        }
    }
}

component Conversation(channelId: String, user: User)
    emits Gone
{
    inbox Said(msg: discord.Message) | Expired

    val mine = discord.channel(channelId, author = user.id) -> Said   // 自分の分だけ購読
    var lastSeen: Instant = now()
    val idle = time.after(30.days, since = lastSeen) -> Expired       // since が変わるたび update

    loop {
        when (await inbox.next()) {
            Said(msg) -> {
                lastSeen = msg.at
                val reply = reply@ await llm.chat(user, msg.text)
                await discord.post(channelId, reply)
            }
            Expired -> {
                emit(Gone)
                break
            }
        }
    }
}
```

### 4. 承認

```kotlin
component Approval(request: Request)
    emits Decided(ok: Boolean)
{
    run {
        val result = decision@ await race(
            Answer  = human.ask(request.approver, request.text),
            Timeout = time.sleep(3.days),
        )
        when (result) {
            Answer(a) -> emit(Decided(ok = a.yes))
            Timeout   -> emit(Decided(ok = false))
        }
    } finally {
        await notify.post(request.approver, "request ${request.id} is closed")
    }
}
```

親が条件を false にして Approval を dispose すると `decision@` が cancel され、`finally` が走る。

### 5. PR パイプライン

```kotlin
component Pipeline(repo: Repo, change: Change)
    emits Merged(sha: String)
{
    val branch = github.branch(repo, name = change.name)        // component と同じ寿命
    var reviewing: Boolean = false

    if (reviewing) {
        val pr = github.pr(repo, head = branch.name, base = "main", title = change.title)
    }

    run {
        await github.push(branch.name, change.diff)
        reviewing = true
        val url = opened@ await { pr?.url }                     // pr が存在して url が出るまで待つ
        loop {
            val verdict = review@ await reviewer.review(url)
            if (verdict.ok) break
            val patch = await fixer.fix(verdict.comments)
            await github.push(branch.name, patch)
        }
        val sha = merge@ await { pr?.mergedSha }
        reviewing = false
        emit(Merged(sha))
    }
}
```

### 6. orchestrator

```kotlin
component Worker(task: Task)
    emits Done(result: Result)
{
    run {
        emit(Done(await llm.solve(task)))
    }
}

component Orchestrator(goal: String)
    emits Finished(results: Map<TaskId, Result>)
{
    inbox Report(id: TaskId, event: Worker.Event)

    var tasks: Map<TaskId, Task> = {}
    var results: Map<TaskId, Result> = {}

    val workers = for ((id, task) in tasks) {
        Worker(task) -> Report                                  // 届く形は Report(id, Done(result))
    }

    run {
        tasks = plan@ await planner.plan(goal)
        loop {
            val Report(id, Done(result)) = await inbox.next()
            results += (id to result)
            if (results.size == tasks.size) break
        }
        emit(Finished(results))
    }
}
```

### 7. 常駐 agent に send して、返事を state で読む

```kotlin
component Agent(cfg: Config)
    inbox Ask(id: Int, q: String) | Stop                        // header にあるので公開
{
    export var reply: Reply? = null

    loop {
        when (await inbox.next()) {
            Ask(id, q) -> reply = Reply(id, await llm.chat(cfg, q))
            Stop -> break
        }
    }
}

component Caller(cfg: Config) {
    val agent = Agent(cfg)                                      // -> が無いので send できる。agent の event は受けない

    run {
        agent.send(Ask(id = 1, q = "status?"))
        val answer = wait@ await { agent.reply?.takeIf { it.id == 1 } }
        agent.send(Stop)
    }
}
```

`val agent = Agent(cfg) -> Tag` と書いた場合は `agent.send` が型エラーになる。

### 8. 動的 attach

```kotlin
component Attach(spec: Spec) {
    var linked: Source? = null

    if (linked != null) {
        export val plugin = link(linked)                        // 承認後だけ存在。output は plugin: Plugin.Output?
    }

    run {
        val generated = generate@ await codegen.generate(spec)
        val ok = approve@ await human.confirm(spec.owner, "link ${generated.name}?")
        if (!ok) throw Fault("rejected by ${spec.owner}")
        linked = generated
    }
}
```

### 9. 外部 component の宣言

```kotlin
extern discord.channel(
    token: Secret restart,                  // 差し替え → dispose して作り直す
    id: String update,                      // 差し替え → その場で付け替える
    author: UserId? = null update,
) -> { id: String, name: String }
    emits Message(msg: discord.Message)
    lifecycle { replace = allowed, on_boot = restart, dispose = detach }

extern pay.charge(
    customer: Customer finish,              // 差し替えても動かない（1 回きり）
    amount: Money finish,
) -> { receipt: Receipt? }
    emits Charged(receipt: Receipt) | Declined(reason: String)
    lifecycle { replace = never, on_boot = resume, dispose = keep }

extern human.review(owner: UserId update, subject: Source restart)
    inbox Nudge(text: String)               // 公開 inbox を持つ外部 component
    emits Approved | Rejected(reason: String)
    lifecycle { replace = allowed, on_boot = resume, dispose = delete }
```

### 10. migration

v3 の Conversation:

```kotlin
component Conversation(channelId: String, user: User) emits Gone {
    inbox Said(msg: discord.Message) | Expired
    val mine = discord.channel(channelId, author = user.id) -> Said
    var history: List<String> = []
    loop {
        when (await inbox.next()) {
            Said(msg) -> {
                history += msg.text
                val reply = reply@ await llm.chat(user, history)
                await discord.post(channelId, reply)
            }
            Expired -> { emit(Gone); break }
        }
    }
}
```

v4 では `history: List<String>` を `log: List<Turn>` に、`mine` を `subscription` に改名し、`Said` に `source` を足し、`reply@` を `infer@` に改名して local `retries` を足す。

```kotlin
component Conversation(channelId: String, user: User) emits Gone {
    inbox Said(msg: discord.Message, source: String) | Expired
    val subscription = discord.channel(channelId, author = user.id) -> Said
    var log: List<Turn> = []
    loop {
        when (await inbox.next()) {
            Said(msg, source) -> {
                val retries = 0
                val reply = infer@ await llm.chat(user, log, msg.text)
                log += Turn(user = msg.text, bot = reply, source = source)
                await discord.post(channelId, reply)
            }
            Expired -> { emit(Gone); break }
        }
    }
}

migrate Conversation(from = 3) {
    moved mine -> subscription                              // address の改名。子は作り直さない
    moved history -> log
    state log: List<Turn> = old.history.map { Turn(user = it, bot = "", source = "discord") }
    inbox { Said(msg) -> Said(msg, source = "discord") }    // 溜まっている message の変換
    run { reply@ -> infer@ (retries = 0) }                  // reply@ で待っていた thread は infer@ で待つ。無い local を補う
}
```

`old` は各節で旧版の値（`state` では旧 state、`run` では旧 local）を指す。

## 4. 自己評価

### 読みやすさ

- Kotlin 読者には `val` / `var` / `when` / `fun` / label がそのまま。React 読者には `export` と `key =`、terraform 読者には `extern` の `lifecycle` が馴染む。
- 向きの規律は 3 箇所で見える: header（`inbox` があれば親が send できる）、子の宣言（`-> Tag` があれば受ける、無ければ送る）、run（`emit` は上へ、`.send` は下へ）。
- 「宣言か逐次か」は `run` / `loop` / `tool` / `fun` の `{ }` の内側かどうかだけ。body に代入文が書けないので、逐次コードが body に紛れ込むことはない。
- 要件 B2 の「配線した子に send しない」は `-> Tag` を付けた子が `.send` を持たないことで型レベルで守られる。「send する子から event を受けない」は `-> Tag` を付けないと event が入らないことで守られる。

### 曖昧さ

- `await { expr }` が `Boolean` と `T?` で意味を変える（true まで / 非 null まで）。型で決まるので実装は一意だが、読者が `Boolean?` を書いたとき迷う。`until { }` を分ける案と比較が要る。
- run の中の `val r = Resource(args)`（ブロック寿命の resource）と `val n = f(x)`（ただの局所値）が同じ形。型（component か値か）で決まるが、見た目では区別できない。
- `fun` が top-level では純粋、component 内では手続き。位置で意味が変わる。`proc` を足して分ける案もあるが keyword が増える。
- `-> Tag` の `->` は `when` の分岐の `->` と同じ記号。body には `when` が無いので構文上は衝突しないが、目には二重。
- `if (cond) { val pr = … }` の外から `pr` が `T?` で見えるルールは、Kotlin の scope と違う（Kotlin では見えない）。

### 要件を満たせなかった点・未確定

- 条件付き宣言ブロック（B4）自体には名前が無い。中の宣言が address を持つので「全ての宣言は名前を持つ」は保てるが、plan 上でブロックの条件そのものを指す名前は無い。
- C1 の `inbox.first { pred }` の結果は inbox 型のまま（`Stop` に絞られない）。構築子で絞る `inbox.first<Stop>()` の形と、どちらを採るか決めていない。
- C5 の collectLatest を `watch { }.collectLatest { }` と Kotlin Flow の語彙で書いたが、Kotlin を知らない読者には説明が要る。
- E2 の `finish` の意味（差し替えで終端扱い）は要件の 1 語から推定した。`lifecycle` の値の語彙（`detach` / `keep` / `delete`）も仮。
- migration の `run { l1@ -> l2@ (…) }` は label の 1 対 1 対応だけを扱う。label が消えた thread をどうするか（最寄りの label に戻すか、失敗にするか）は書いていない。
- 出力の型を header に書く手段が無い（`export` から導出するだけ）。外部 component は `-> { … }` で書くので、component と extern で output の書き方が非対称。
