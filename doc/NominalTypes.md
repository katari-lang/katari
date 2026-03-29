# オブジェクトの廃止と公称型化

## 概要

Object の union が単純に計算できない問題が現状あります。

```
{type: 0, foo: string} | {type: 1, bar: number} /= {type: 0 | 1}
```

しかし、union 型は 1.open union を表現するんのに楽 2. effect system と相性が良い　という利点があります。

そこで、オブジェクト自体を廃止し、全てを公称型とすることで、union の計算を単純にします。

## 各種概念

まず、概念を整理します。

- 公称型 (Nominal Type): 型の同一性が名前で決まります。

- レコード

```
// このように宣言
data User<out ID> {
  id: ID,
  name: string,
  age: number
}
// name, age という名前のフィールドを持つ User という名前の型
// コンストラクタ
let user1 = User {
  id = 1,
  name = "Alice",
  age = 30
}
// フィールドアクセス
let name = user1.name
// match
match user1 {
  User {id, name, age} => ...
}
// let match
let User {id, name, age} = user1
```

- タプル

```
// このように宣言
data Point(x: number, y: number)
// Point という名前の型で、x と y を取るが、x, y は名前で識別されるものではなく、位置で識別される
// コンストラクタ
let p1 = Point(1, 2)
// match
match p1 {
  Point(x, y) => ...
}
// let match
let Point(x, y) = p1
// フィールドアクセスはできない。
```

## 型チェッカの実装

sup, sub, out, in, in out などについては今と変わらない。union, intersection も存在。 object 型だけなくします。

### 基本動作

- Constraint の左辺と右辺は通常の Type (generics の型変数含む) + 未知変数です。(または、Effect Type + 未知変数 (effect) → これも Constraint の一種とみなすので、直和で同様に扱えばよさそう)
- generics の型変数の境界
  - generics の型変数には境界が存在します。
  - これを Assumption と呼ぶ。Assumption の集合は別で保持しておく。→ Γ とする
- generics と未知変数の違い
  - どちらも Text であらわされる名前で管理します。
  - Generics
    - ユーザーがプログラムで直接導入した generics や、パターンマッチで導入される。Assumption に境界を持つ (持たなければ never / unknown が境界)
    - Constraint を Solve するときは **Genericsがその範囲内を任意に動くとき、どの場合でも成立する** ことが必要
  - 未知変数
    - Constraints を作る時に導入される、AST のそれぞれの Expr に紐づく型
    - たとえば、let x = expr という式があったら、expr に対して未知変数 T_expr を導入。さらに x にも未知変数 T_x を導入して、T_expr <: T_x という制約を作る。
    - pr が f(t) であったなら、T_f, T_t を導入して、T_f <: (T_t -> T_expr) という制約を作る。
    - 最終的にそれぞれの未知変数に対して Bound が求まる (Constraint を Solve するごとにコレに追加されていく)
      - この未知変数に関連する Constraint が無くなった + 未知変数の期待値の下限 <: その上限　となった場合、未知変数は解決可能とされる。
    - Constraint を Solve するときは **未知変数に期待する範囲に、なにかしらの型が存在する** ことが必要
- 動作フローは次の通り。
  - Assumptions, Constraints を集める。
  - Constraints を最初から見ていく。その場で判定可能なものは判定(Assumptions を考慮)。より小さい単位の Constraint に分解できるものは分解して、Constraints の集合に追加する。
    - 未知変数に対する Bound も更新していく
    - 分解したものは一旦別の Constraints に入れておいてループ後にそれを次の Constraints とするのが良いかも (変数置換の時楽)
  - ↑を一周して、Constraints, 未知変数 Bound が空で無かったらまた繰り返す
    - この際に未知変数をいい感じに消去していきたい
  - 最終的に Constraints の集合と、未知変数 Bound の集合が空になれば OK。
  - なお、実際には世界線を分岐させることがあるので、1 ループは Constraints -> Constraints[] である (それぞれの Constraints に対してまたループを適用) (全てのパスを並列に計算し、どれか一つでも成功すれば成功。)

#### Assumption と Constraints の生成

- 注意点
  - Generics は名前を一意にしておく (例えば、別の場所で同じ名前の generics が使われることがあるが、それは区別したい)
  - Generics の導入順を覚えておく。ネストした定義の時
    - たとえば let x<T> = expr という式があったら T を generics として導入。これを 0 番目とする。ただし、同時に複数導入されたとき、例えば let x<T, U> = expr という式があったら、T を 0 番目、U を 1 番目とする。expr が次のようになっていたとする。
    ```
    let y<V> = expr2
    let z<W> = expr3
    ...
    ```
    すると、V は 2, W も 2 とする。これは Generics の依存順を表す。ここでは、 T -> U, (T, U) -> V, (T, U) -> W という依存関係になる。この順番を generics の level と呼ぶ。この概念は後で使うが、より level が高い generics は、より level が低い generics に依存できるが、その逆はできないことに注意。

- いまいちど確認すること
  - let x<T> = expr で導入された generics は、x を使用する**いかなる場合であっても** T を指定しなければいけない。
  - fn f<T>(arg: T) であれば、f を使用する**いかなる場合であっても** T を指定しなければいけない。
  - ↑の制約等は Assumption / Constraints の生成時に検証する。

- 境界の動作について
  - 境界外の値が入るとエラー
    - 以前は data を特殊な扱いしていましたが(neverになる)、一旦エラーになるように変更。そちらの方がアルゴリズムが簡単なので。後々変えるかも
  - この境界チェックも Constraints に入れる。
  - 導入された generics の境界は Assumptions に入る。

- match / case について
  - case では、それぞれの nominal type の generics について **Generics** を導入する。その境界 Assumption はもっとも外側なら match の対象の型、ネストしている場合、親の型が入る
    - さらに、nominal type の generics の境界自体も Assumptions に入れる。
    - ここの動作分かりにくいと思いますが、memento-compiler がまさに同じようなことをしてるので参照してください。
  - それぞれの変数に対しては未解決変数を割り当てる。
  - 例

  ```
  // 恣意的な変な例
  data Box<out T sub number> {
    value: T | string
  }

  ...

  match expr {
    case Box {value: v} => {...}
  }
  ```

  - expr の型が T_expr であったとする。Box には generics が一つ必要であるから、generics G_Box を導入する。Assumptions に G_Box <: number と Box<G_Box> <: T_expr を追加。
  - v には未知変数 T_v を割り当てる。ここで Box の中を参照し G_Box | string <: T_v という制約を追加する。
  - match の戻り値は、それぞれの case について union をとったものである。

#### 分解 / 解決

ジェネリクスを G, 未知変数を X とする。

左辺の never, 右辺の unknown はすぐに解決する。

- never <: T → 消去
- T <: unknown → 消去

左辺と右辺が両方とも Primitive, Literal の場合、解決

- 左辺と右辺が同じ場合は消去
- int literal <: int → 消去
- int <: number → 消去
- string literal <: string → 消去
- booealean literal <: boolean → 消去
- number literal <: number → 消去
- number literal <: int → 消去
- それ以外は失敗 (ですよね？一応確かめて。)

左辺と右辺が両方ともNominal Type (Function<...>, User<...>, ...) の場合分解 / 失敗

- 両辺が違うNominal Type → 失敗
- Function<Args1, Return1, Effect1> <: Function<Args2, Return2, Effect2> → 分解して、Args2 <: Args1, Return1 <: Return2, Effect1 <: Effect2 を追加 (関数の引数は反変、戻り値は共変、Effect は共変)
- User<...> <: User<...> → 変性に従い分割
  - たとえば user<out ID> であれば、ID の部分は共変なので、User<A> <: User<B> → A <: B に分解

左辺と右辺が (Nominal Type) と (Primitive, Literal) の組み合わせの場合

- 失敗

左辺の union, 右辺の intersection は分解する。

- (T1 | T2) <: T3 → T1 <: T3, T2 <: T3
- T1 <: (T2 & T3) → T1 <: T2, T1 <: T3

左辺と右辺が両方とも Generics

- 左辺と右辺が同じ場合は消去
- 左辺と右辺が異なる場合 → level が高い方の generics を、その (左辺なら上界の intersection、右辺なら下界の union) で置換して分解
  - たとえば、左辺が G1, 右辺が G2 で、G1 の level が G2 より高い場合、G1 をその上界の intersection で置換して分解する。逆に、G2 の level が G1 より高い場合、G2 をその下界の union で置換して分解する。
  - 両辺のレベルが同じ → 通常ありえない？と思われる。一応 warn を出して、左辺をその上界の intersection で置換して分解することにする。
    - ありえない理由: 同一のコンテキストに、同じレベルの generics が複数存在することはなさそう (同時に複数導入しても左が 0, 右が 1 とかになるはず)。

左辺か右辺が Genericsで、もう一方が Primitive, Literal, Nominal Type

- 左辺が Generics なら、Generics をその上界の intersection で置換したもので置換
- 右辺が Generics なら、Generics をその下界の union で置換したもので置換

左辺と右辺のどちらかが、Primitive, Literal, あるいは、Nominal Type (Function<...>, User<...>,... ) で、もう一方が、(右辺なら union, 左辺なら intersection)

- 場合分け
  - 右辺が union の場合、それぞれの要素に対して制約を作り、それぞれを現在の制約に足したものに世界線分岐する
  - 左辺が intersection の場合も同様。

左辺が intersection, 右辺が union → これめんどい

- 今回は左辺 intersection で分岐する

左辺か右辺が未知変数で、もう一方が Nominal Type

- 未知変数を他の変数で置換、または generics 境界外の可能性を場合分け。
- 次の二つの場合に世界線分岐
  - Nominal type と同じ形をしている。
    - たとえば X <: User<A> の場合。未知変数 Y を新たに導入して、Y <: A としたものに置換。さらに X = User<Y> を変数置換リクエストに追加 (★)
  - 未知変数が (左辺なら never)、(右辺なら unknown) になる場合
    - たとえば X <: User<A> の場合。この Constraint を削除(解決) して、X の Bound の上に never を追加する (逆もしかり)

左辺と右辺が両方とも未知変数

- 両方の未知変数の Bound にお互いを追加する。

左辺か右辺が未知変数で、もう一方が Primitive, Literal, Generics

- 未知変数の Bound に、Primitive, Literal, Generics を追加する。

↑ これでパターンとしては全部だよね？(検証して。)

#### 変数置換

上の操作で、次の二つが生成される。

- 次の Constraints[] (世界線ごとに)
- 未知変数の Bound の集合
  - 次ループではコピーして世界線ごとに更新する必要があることに注意
- (★) で導入された変数置換リクエスト

ここから、未知変数を削っていく作業をする。

- まず、(★) を処理する。Constraints と Bounds 内の未知変数全てを置換し、さらに、未知変数の Bound を分解して Constraints に追加
  - たとえば、{Box<0 | 1>} <: X <: {Box<int>, Box<number>} という Boundsがあり、X = Box<Y> という置換リクエストがあったとする。次の Constraints (世界線それぞれ) に、Box<0 | 1> <: Box<Y> と Box<Y> <: Box<int>, Box<Y> <: Box<number> をすべてを追加する。
- 次に、できるだけ未知変数を置換する。
  - 上下の集合に同じ型があるような未知変数を見つける。
  - それをその型で置換する。置換後は↑と同じ処理をする。
  - この操作を繰り返す。
- 最後に、残った未知変数の Bound 左右の**全ての組み合わせ** について、左辺 <: 右辺 という Constraint を追加する。これは世界線それぞれについて追加。
  - たとえば、X の Bound が {A, B} <: X <: {C, D} であったとする。すると、次の Constraints (世界線それぞれ) に A <: C, A <: D, B <: C, B <: D をすべて追加する。
  - この操作で X が消える訳ではないことに注意。これは Constraint の追加であって置換ではないので、まだ Constraints に残っている X や、ほかの Bound に残っている X は消去されない。

#### Assumptions について

Assumptions も事前と、変数置換後分解の必要がある。これは memento-compiler 参照。

## 効率化

適宜 Normalize をして、余計な項を消す。特に右辺の union と左辺の intersection は、消せると結構効率化できるはず。

## 廃止する概念

object 型 {x: number, y: number, ...}
tuple 型 (number, number, ...)

## 補遺

~/projects/memento/memento-compiler をよく参照してください。かなり似たようなことをしています。memento-compiler の型チェッカをもっと整理した形で書くのは歓迎です。
memento-compiler をコピーするのではなく、きちんとロジックを理解したうえで、より良い形で実装してください。
リファクタリング・機能変更に使えるコストを無限と仮定します。1 からプロジェクトを作ったときにこうなるであろう、を想定してコードを書いてください。
このドキュメントの追記欄には、あなたが覚えているべきだと判断したすべての物事を追記してください。適宜このドキュメントを見返しながら作業してください。

# 追記
