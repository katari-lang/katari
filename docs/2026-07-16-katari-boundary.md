# katari と runtime の境界 — 組み込みは「書ける合成の効率化版」(設計原則とロードマップ)

owner の原則(2026-07-16): katari-lang はシンプルに保ち、ユーザーが部品を合成して自由に組める状態が
よい。極論、**oauth と mcp の動作が katari-lang 上だけで定義できるのが理想**で、組み込みはその
効率化・堅牢化版として動く。runtime が面倒を見過ぎることは柔軟性の欠落である。

## 判定原則

**組み込み(mcp/oauth reactor 等)は、公開 primitive で書ける合成の効率化版でなければならない。**
組み込みだけが使える内部能力を作らない — 表現不能な能力が要るなら、(特化 primitive をそのまま
組み込むのではなく)**より小さな一般 primitive に分解して言語に渡す**か、明示的な mechanism 境界と
して文書化する。

- **Runtime(mechanism)が持つ**: 耐久性/原子性、capability routing、seal/privacy、at-most-once、
  escalation の輸送、cross-run 調整(single-flight 等)、**UI(ただしデータを描くだけ — 挙動を知らない)**。
- **Katari(policy/合成)が持つ**: protocol(OAuth の grant も MCP の JSON-RPC も「ただのプログラム」)、
  retry / error handling / resilience、部品の合成。

## ギャップ台帳(pure Katari で full OAuth/MCP に足りないもの)

v0.1.0 時点の判定。「分解」= 特化でなく最小の一般 primitive として言語に足す。

| 能力 | 状態 | 判定 |
|---|---|---|
| HTTP client / JSON | ✓ `http.fetch` `json` | 済 |
| 人間への認可 pause/resume | ✓ ユーザー request → answerable escalation(uniform escalation の成果) | 済 |
| scope 型付け(runST) | ✓ phantom effect は通常宣言 | 済 |
| 認証の合成 | ✓ `oauth.token` / `mcp.headers` / configured client + `authorization_parameters` | 済(v0.1.0) |
| PKCE / state 素材 | ✗ | **v0.1.x: `crypto.random_bytes / sha256 / base64url`**(`oauth.pkce` の様な特化はしない) |
| プログラムが書ける durable KV | ✗(env は operator 専用) | **v0.1.x: `store.get/set/cas`**(project-scoped、private 対応、sealed)。最大の enabler(token/cursor/dedupe/idempotency)。並行制御は CAS のみ — lock は durable runtime では footgun |
| escalation の presentation | ✗ request 名 sniff(`prelude.oauth.authorize` → カード) | **v0.1.x: presentation-as-data** — escalation がヒント(例: `link`)をデータで運び、UI はデータを描くだけ。組み込み oauth も同じチャネルの一利用者になり、名前 sniff が消える |
| 安定した public callback URL | ✗(webhook.inbound は capability URL を mint する設計) | **将来(慎重に)**: 名前付き安定 route は別のセキュリティモデル(URL でなく state/内容で認証)。当面 runtime の `/oauth/callback` は mechanism 境界 |
| tool 値の mint | ✗(reflection に make が無い) | **v0.1.x: `reflection.make_agent(metadata, body)`** — schema+closure から agent 値。「tool = データ→値」を言語に開く |
| SSE / streaming transport | ✗ | **defer**(大物。POST-only MCP は現に動く) |
| cross-run single-flight | ✗(表現不能) | **mechanism 境界として受容** — pure Katari 版は稀な二重 refresh を許容、組み込みが hardened 版 |

## v0.1.0 の決定(owner、2026-07-16)

**Option A**: v0.1.0 は現組み込みで ship。分解ロードマップ(crypto / store / presentation-as-data /
make_agent / 安定 route / streaming)は v0.1.x。ただし**ユーザーのカスタム性が十分であること**が条件で、
その唯一の workaround 不能な穴 = `oauth_clients.authorization_parameters`(provider 固有の authorize
パラメータ。Google の `access_type=offline&prompt=consent` が代表)は v0.1.0 に含める。
