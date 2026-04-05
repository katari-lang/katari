# Json 周り・FFI と並列処理の追加

## 概要

現在の Qatali を完全なオーケストレーション・サービスにするために、Runtime を作成する前に、Json 型の実装、trait の実装、FFI と並列処理の追加を行いたい。

- AST / 構文 / 型チェックの変更
  - モジュールシステム
  - match / case に condition を追加
  - Json 型を実装
  - trait を実装
  - toJson, fromJson の自動導出を実装
  - 並列処理の実装
  - FFI の実装
- 上記変更に対する IR の設計変更

まずは、AST / 構文 / 型チェックの変更を行い、IR の設計変更は最後にまとめて行う。その間はいい感じに IR 関連のエラーを無視して OK。
実装は既存の物を大きく変えても OK。編集コストや後方互換性は気にしない。

## まず、シンタックス改善

Rust に寄せる。

```
// fn 定義
fn function_name(arg1: Type1, arg2: Type2) -> ReturnType with effect { // -> Return Type, effect は省略可能
  ...
}

// effect を省略すると "effect なし"、Return type を省略すると "return type は推論" と少し違う意味になることに注意。
// なお、 generics 省略は "generics なし"、trait 省略は "trait なし"。return type だけ推論になる

// return type なし、effect ありも可能
fn function_name(arg1: Type1, arg2: Type2) with effect {
  ...
}

// generics は function_name のあと
fn function_name<T>(arg: T) -> T {
  ...
}

// 制御文のルール
// 1. fn 定義の block の中の最後の行は、return or value
// 2. if や match の中では return は使えない。最後の行が value で、それが返値となる。
// 3. (変更) effect handler の operation clause の中では、最後の行は break か continue でなければいけない。
// 4. (変更) effect handler の return clause の中では、最後の行は value でなければいけない。
// 4. (変更) handle block with {...} の block の中では、return を使えない。最後の行が value で、それに return clause を適用したものがhandle式の返値の型となる

// let 定義
let variable_name: Type = value; // 型注釈は省略可能

// generics は variable_name のあと
let variable_name<T> = value;

// data 定義
data TypeName<in out T sub number> {
  field1: Type1,
  field2: Type2,
  ...
}

// tuple の場合
data TypeName<in out T>(field1: Type1, field2: Type2, ...)

// コンストラクタ
TypeName { field1 = value1, field2 = value2, ... }

// tuple の場合
TypeName(value1, value2, ...)

// type 定義
type TypeName<T sub number> = ... // 型エイリアス

// 匿名 fn
(arg1: Type1, arg2: Type2) -> ReturnType with effect  { ... } // Return Type と effect は省略可能


// effect 定義
// effect 定義も variance, 型 bound を明記できる
effect EffectName<out T sub number>(arg1: Type1, arg2: Type2) -> ReturnType

// if 式
if condition {
  ...
} else if condition2 {
  ...
} else {
  ...
}

// match / case 定義
match value {
  case Pattern1 if ... => {...}
  case Pattern2 => {...}
  ...
}
// 重要な変更 : Pattern には Generics を指定できる。
// が、それはGenerics の指定ではなく、Generics の受け取りである！
// 例:

let main () {
  mathc r {
    Ok<T>(v) => {... /* ここで T を使える。*/ } // T は型引数の指定ではなく、むしろ型変数の導入。なので Ok<int> とか Ok<T | U> とかは書けない。あくまで変数名のみが記述可能省略も可能。
    Err<E>(e) => {... }
  }
}

// 型システム:
// 実は従来とあまり変わらない。従来のシステムでは、r の型が T_r とし、Ok(v) が現れた時点で、Ok が必要としている Generics の数 → 1 個 なので 1 つの Generics 変数を新たに作り、これを G とする。 Ok<G> <: T_r という **Assumption** を追加し、さらに、Ok のコンストラクタを見ると、その第一引数は G 型であることが分かるので、v の型変数を X とし、 G <: X という **Constraint** を追加する、という流れでした
// この、新たに Generics 変数をつくる、という部分を、すでに記述された Generics 変数名に差し替えるだけです。(指定されていなかったら従来通り生成)
// これによって、case の中で、Generics 変数へのアクセスができ、他の関数呼び出しとかで指定可能！ (うれしい)


// handle 定義
// 重要: 後述するが、一旦 one-shot (0 or 1) にする。IR もそれに合わせて簡略化する。
handle {... (ブロック)} with {
  case EffectName<T>(p1, p2) => {...} // Effect の場合も match と同様に generics の受け取りが可能。T はこの case の中で型変数として使える。
  ...
}

// primitive な関数や普通の関数は全部 snake_case。
// 型は UpperCamelCase。
```

全体的にセミコロンは合っても良いしなくてもいい　ない場合は改行がセミコロンと同じ役割を果たす。

また、基本的に、unit であるような返り値は、`null` を用いる。

## モジュールシステム

現状構文レベルのみで存在するので、型システム上でも完璧に動くようにする。
基本的には、モジュール名 (path の配列？) とそれぞれのファイルの中身が飛んでくるのでそれぞれパース、まとめて型チェック

また、以下の仕様変更をお願いします。

- モジュールは表記するのではなく、ファイル path から自動で導出される。
  - たとえば、`src/utils/json.qtl` というファイルがあれば、モジュール名は `utils.json` になる。
  - この処理は compiler ではなく cli 側で行うかも。compiler はあくまで module の名前だけを知っていて、ファイル構造は cli (プロジェクトマネージャー) が管理する。
- 宣言の前に `pub` を付けることができる。他のモジュールから呼べるのは `pub` が付いた `let` と `fn` だけである。(`pub let`, `pub fn`) 付けない場合は private として扱われる。private 宣言のための構文は特に必要ない。
  - ただし、`data`、`type`, `effect`、`trait` の**type level**は常に公開されているものとする。例えば、`data User { ... }` と書けば、`user.User` 型はアクセス可能。
  - `data`, `effect` は `pub` を付けることができる。これを付けると、コンストラクタも公開できる。例えば、`pub data User { id: Int, name: String }` と書けば、`User` 型と `User` コンストラクタが両方アクセス可能になる。pub を付けないと User 型のみアクセス可能になり、コンストラクタはアクセスできない (パターンマッチとしても使えない)。これはスマートコンストラクタを実装するために必要。

- import には次の 3 種類がある
  - `import "path.to.module"`: `module.fn_name` という形ですべての pub 関数 / 定義にアクセスできるようになる。path は無視して、最後のモジュール名でのみアクセス可能。複数の異なるパスで、同じモジュール名になった場合はエラー。その場合は alias を提案する。
  - `import "path.to.module" as alias`: モジュール全体をインポートし、`alias.name` でアクセスできるようにする。
  - `import { name1, name2 } from "path.to.module"`: モジュールから特定の名前の関数だけをインポートする。これはグローバルに展開され、`name1`、`name2` としてアクセスできるようになる。名前が衝突した場合はエラー。
    - この記法と上 2 つのいずれかは兼用できる。
  - data, type, effect、trait も同様に、import 可能。 `import { User } from "path.to.module"` とすれば、`User` 型がアクセス可能になる。`import "path.to.user"` なら `user.User` でアクセス。コンストラクタについても、`user.User {id = ...}` みたいにするし、さらに、パターンマッチの時も同様。
    - ただし、`data`, `effect` に `pub` がついていない場合は、型はアクセス可能だが、コンストラクタはアクセスできない。親切なエラーメッセージが必要かも
    - 逆に言うと、`pub` が付いているなら `import` は type とコンストラクタをセットで import することになる。
- 循環した module import はエラー。

- 再 export
  - `export "path.to.module"`: そのモジュールを自分のモジュールの一部として再エクスポートする。例えば、`export "utils.json"` と書けば、`json.Json` などが自分のモジュールの一部としてアクセス可能になる。
  - `export { name1, name2 } from "path.to.module"`: 特定の名前だけを再エクスポートする。例えば、`export { Json } from "utils.json"` と書けば、`Json` 型だけが自分のモジュールの一部としてアクセス可能になる。
  - ここで、data, effect の再 export は、type と コンストラクタどちらも export することになることに注意。
  - これは aliasing の仕組みで、実態は元のファイルの定義を参照することに注意。

- 基本的に言語側から提供するのは `prim`, `prim.sub_module` という名前の module。`prim` は常に import されているものとみなす。また、`prim` のサブディレクトリは `sub_module.val_name` という名前でアクセスする。
- つまり、仮想的に以下のように import されているものとみなす。

```
import {... // 全部 import} from "prim"
import "prim.json"  // (つまり json.toString みたいな感じでアクセス可能。)
import "prim.ffi"
...
```

## match / case に condition を追加

match 式に condition を追加して、場合分けできるようにする。

```
match r {
  case Ok(v) if v > 0 => handle_positive(v)
  case Ok(v) if v <= 0 => handle_non_positive(v)
  case Err(e) => fallback(e)
}
```

type narrowing は実装しなくても良い。つまり、型システム上はあまり変更点はない。condition が正しく boolean (かその sub) を返すか確かめる。 AST とパーサーかな。

## effect system, 型チェッカー改善

effect system を 0 or 1 effect にする。continue は関数ではなく制御構文として導入するように変更。それに伴って構文も continue(...) ではなく、最終行に continue value; みたいな感じで書くように変更。IR もそれに合わせて簡略化する。

また、handler variable という変数 (に見える構文) を導入する。

```
handle {
  ...
} with {
  // handler variable の初期化
  var foo: number = 0;
  case Effect1(...) => {
    ...
    // 最後の行は **必ず** break か continue
    break value;
  }
  case Effect2(...) => {
    ...
    // foo は毎回 **別の実態として** 導入されるので、クロージャ―などを作っても後から更新されることはない。
    fn inner() {
      ...
      // handler variable はこの関数の中でもアクセス可能。値はこの周回の foo で固定されていて、後々の更新により、更新されることはない
      let x = foo;
      ...
    }
    ...
    continue value with {
      // handler variable を更新
      // 実際には別の実態として foo を作って、それに代入
      foo = ...; // 右辺に foo は使える
    }
    // handler variable が無い場合は単に break value で OK。handler variable を使うことで、effect handler 内部で状態を持てる
  }
  return v => {
    ...
    // この中でも foo は使える
    ...
    // return claude の最後の行は必ず value
    v + foo
  }
}
```

基本的に、continue value と書いた場合、その value の型 T は Effect 定義 effect Effect(...) -> U に対して T <: U である必要がある。
break value と書いた場合、その value の型は handle ブロックの型と一致する。return clause の最終行の型も同様に、handle ブロックの型と一致する必要がある。

effect system の型チェッカーも HM style に寄せる。

つまり、関数が出てきたら、一旦その関数のシグネチャの effect を E とする、各関数呼び出しについて、その関数が effect を必要としている場合、その effect を E' とする。Constraint として E' <: E を追加。

constraints は effect の constraints も表せる (直和にする？)

のちのち trait でも同じようなことをする。

また、 effect も generics として導入できるようにする。現状 generics は 1. Type, 2. Effect のみ許可する。kind 分析もする (type か effect かを判定) with の後ろにあれば effect, そこ以外なら type。どちらにもないなら type に寄せる。どっちにもある場合エラー。

(このためにも type の型チェッカと同様の型チェッカを effect にも適用する必要がある。)

この機能は後述する parallel の実装で必要になる。

また、`type` synonym でも effect の演算が記述できるようにする。

例:

```
effect ReadConfig() -> Config
effect WriteLog(message: string) -> null

type EssentialEffects = ReadConfig | WriteLog

fn doSomething() with EssentialEffects {
  let config = ReadConfig();
  ...
  WriteLog("Did something");
}
```

こちらも、type 定義の右辺について kind 推論を行う。確定できなかったら type とする。

確定できない例 → T, U は type

```
type F<T, U> = T | U
```

確定できる例 → T は effect, U は type

```
type F<T, U> = (arg: U) => int with (T | ReadConfig)
```

確定できる例 2 → T は effect

```
type F<T> = ReadConfig | T // with 節にあるわけではないがx、effect として使われているので effect

fn foo<T> () with F<T> { // F<T> は effect として使われているので、F<T> は effect
  ...
}
```

また、handler の型チェック時は、match 式と同等の事をする。

```
handle {
  ...
  // このブロック内で発生する effect を E とする。
} with {
  // それぞれの case について、Effect1 の generics を内部的に G として導入。Effect1<G> <: E を assumption として型付けする。
  case Effect1(...) => ...
}
```

たとえば、 Throw<A> | Throw<B> という effect を handle する場合 case Throw(x) => ... という case でどちらも hanlde する。 x の型は A | B になることが期待される (これは assumption から導出される。)すなわち、 Throw<G>(x) であると内部的に読んで、assumption として Throw<G> <: Throw<A> | Throw<B> を追加する。これの assumption 分解により G <: A | B となる。(assumption 分解において、ここの soundness は逆転することに注意。G <: A | B ならば Throw<G> <: Throw<A> | Throw<B> とは限らないが、Throw<G> <: Throw<A> | Throw<B> ならば G <: A | B である。)ところで、Throw はその中身は G であるので、x の型を未知型変数 X として、 X >: G constraint に追加する。
最終的に、X >: G を解決する時、G の upper bound である A | B が用いられるはず。

ついでに、外部に与える effect の推論もちゃんとする必要がある。

1. handle 式が使われた場所の effect を E1 とする。
2. handle 対象ブロック内で発生する effect を E2 とする。
3. case でマッチする effect を E3 とする。
4. それぞれの clause 内で発火する effect を E4 とする。

これらについて、Constraint として E2 <: (E1 | E3) と E4 <: E1 を追加する。

handler のネストに対しても同様。

## Throw エフェクトの追加

`prim` モジュールに、仮想的に追加される。(つまり Throw で参照可能)

```
effect Throw<out T>(
  message: T
) -> null
```

prim モジュールの各種操作は、エラーを発生させる可能性があるとき、Throw<T> を用いる。

## Json 型の実装

Json 型は仮想的に、次のように構成される。(実際にライブラリがあるわけではない。)　全て `prim.json` というモジュールに入っているとみなされる。immutable なデータ構造。string と data の変換の中間表現である。

```
data JsonObject // これは primitive 型。(厳密には data ではない)
pub data JsonArray(elems: Array<Json>)
pub data JsonString(value: string)
pub data JsonNumber(value: number)
pub data JsonBoolean(value: boolean)
pub data JsonNull

type Json = JsonObject | JsonArray | JsonString | JsonNumber | JsonBoolean | JsonNull

// また、次の data 型を実装

data JsonParseError(message: string)
data JsonFieldNotFoundError(field: string)

// 次の関数を標準装備する。

fn to_string(json: Json) -> string
fn from_string(s: string) -> Json with Throw<JsonParseError>
fn get(obj: JsonObject, key: string) -> Json with Throw<JsonFieldNotFoundError>
fn make_object(fields: Array<(string, Json)>) -> JsonObject
```

また、`Json` 型のみ、`prim` から直接アクセス可能であるとする。

仮想的な prim ファイル

```
export { Json } from "prim.json"
```

使用感は以下のような感じ

```
let original_data = "{ \"name\": \"Alice\", \"age\": 30 }";

fn main() -> string {
  handle {
    let json = json.from_string(original_data);
    let name = json.get(json, "name");
    let age = json.get(json, "age");
    return `Name: ${name}, Age: ${age}`;
  } with {
    Throw(e) => {
      match e {
        case JsonParseError(msg) => return `Failed to parse JSON: ${msg}`;
        case JsonFieldNotFoundError(field) => return `Missing field in JSON: ${field}`;
      }
    }
  }
}
```

## Task Effect の導入

Task Effect は Haskell における IO のような effect を表す。なお、Task は effect として定義されているのではなく、primitive に与えられた effect である。

`Task` はデフォルトで非同期処理を表す。これは構造の parallel で使う。また、停止シグナルが伝播する。これは後述

また、Task 文脈では次の関数が使用できる。

`prim.log`

```
fn info(message: string) -> null with Task
fn warn(message: string) -> null with Task
fn error(message: string) -> null with Task
```

`prim.task`

```
fn panic(message: string) -> never with Task
```

最終的に、実行されるのは Task のみを持った関数である。 (名前は任意で、実行時に指定する)

```
fn main() with Task {
  ...
}
```

## trait を実装

trait の仕組みと impl の仕組みを実装する。trait は型クラスのようなもの。impl は trait を特定の型に実装するためのもの。
Rust の trait より Haskell の type class に近い。

```
// trait 定義はほとんど effect 定義と同一 variance と型境界
trait TraitName<out T1 sub number, out T2>(arg1: T1, arg2: T2) -> T3

// data と同様、variance を明記する。

// impl 定義
fn type1typ2TraitName(arg1: Type1, arg2: Type2) -> Type3 {
  ... // Type 3 を返す block
}
// 定義した関数を trait の impl として実装
// Type には具体的な型が入る (generics は入らない。)
// 型引数を取る Type の場合は、それぞれの型引数も完全な型である必要がある。
impl type1typ2TraitName as TraitName<Type1, Type2>

// impl した関数の呼び出し構文　generics を明示
TraitName<Type1, Type2>(arg1, arg2)
// ↑この関数の型は
// fn TraitName<T1 sub number, T2>[TraitName<T1, T2>](arg1: T1, arg2: T2) -> T3 である。これは trait 定義時に内部的に作られる関数


// trait を使用する関数の定義
fn function_name<T>[TraitName<T>, TraitName2](arg: T) {
  ...
}

// 匿名関数にはくっ付けられない。コレは generics と同様。
// フルの関数定義は次のようになる。

fn function_name<T>[traits](arg: T) -> ReturnType with effect {
  ...
}
```

```
trait Id<out T>(value: T) -> number

fn user_id<User>(value: User) -> number {
  return value.id;
}
impl user_id as Id<User>

fn print_id<T>[Id<T>](x: T) {
  let id = Id<T>(x);
  print(`ID: ${id}`);
}

fn main() {
  let user = User { id: 123, name: "Alice" };
  print_id<User>(user); // OK
  print_id<number>(123); // エラー。Id<number> の impl はないから。
}

// こういうのも可能
// 内部的には、trait をアノテーションに書く = 暗黙の引数を追加　ということになる
let get_id<T>[Id<T>] = Id<T>();
```

型チェック :

fn / val の定義時、その関数の trait アノテーションを記録しておく。TR_1, TR_2,... とする。
さらに、それと現在 import されている impl を全て見て、それを TR_A, TR_B,... とする。
これら二つの合併に対してそれを、TRs とする。

関数呼び出し時、その関数が trait アノテーションを持つ場合、その trait アノテーションを TR's として、その全てに対して次を行う。その中の一つが TR' だったとする。

TRs の **すべての** trait TR_i について、TR' <: TR であるかを確かめる。(この際、generic bounds も用いる。)その中で、**ただ一つのみ** 成り立った場合、型チェック成功。そうでなかった場合は、エラー。また、trait の大小関係も variance を考慮する。例えば Id<int> は Id<number> があれば実装されたとみなす。in out だった場合は Id<int> と Id<number> は別の impl として扱われるべきである。

この時、どの impl に解決されたかはどうにかして覚えておく必要があるかも…… (IR 生成時に同様のチェックを挟むのは非効率、非モジュラーだから)

また impl f as tr の型チェックも行う。

```
// trait 定義がこういう形だったとする
trait Tr<out T, in U>(arg1: T1, arg2: T2) -> T3 // T1, T2, T3 は T, U の式
// これを impl する関数がこういう形だったとする
fn f(arg1: Type1, arg2: Type2) -> Type3 { ... }
// これを impl f as Tr<TypeA, TypeB> としたとする。
impl f as Tr<TypeA, TypeB>
```

型チェック時はまず Tr の定義の T, U に TypeA, TypeB を当てはめた結果の関数 (arg1: T1, arg2: T2) -> T3 を得る。この型を A とする。
typeof f <: A であればよい。

// いろんな例

```
trait Id<out T>(value: T) -> number
fn impl_id_number(x: number) -> number {
  return x;
}
impl impl_id_number as Id<number>

fn impl_id_user<User>(x: User) -> number {
  return x.id;
}

fn foo1[Id<int>](x: int) {
  let id = Id<int>(x); // これはエラー。Id<int> <: TR を満たす TR は 1. foo で導入された Id<int>。 // 2. global で定義された Id<number> の二つがある
}
fn foo2(x: int) {
  let id = Id<int>(x); // これはOK
}
fn foo3<T>[Id<T>](x: int) {
  let id = Id<T>(x); // これはOK
}
fn foo4<T sub int>[Id<T>](x: int) {
  let id = Id<T>(x); // これはエラー。 Id<T> <: Id<T> も Id<T> <: Id<number> もどちらも成り立つから。
}
fn foo5<T, U>[Id<T>, Id<U>](x: int) {
  let id = Id<T>(x); // これは OK。 T <: U は一般には満たされない。 T <: T のみ満たされる。 (したがって唯一)
}
fn foo6<T, U sup T>[Id<T>, Id<U>](x: int) {
  let id = Id<T>(x); // これはエラー。 Id<T> <: Id<T> が満たされるのは良いとして、Id<T> <: Id<U> は T <: U に decompose され、これは前提条件 U sup T より満たされる→重複エラー
}
```

```
trait Id<out T>(value: T) -> number
fn impl_id_number(x: number) -> number {
  return x;
}
impl impl_id_number as Id<int>

fn impl_id_int(x: int) -> number {
  return x;
}
impl impl_id_int as Id<int>

fn main() {
  let id2 = Id<number>(123); // これは OK。Id<number> の impl は impl_id_number だけであるから。
  let id1 = Id<int>(123); // これはエラー。Id<int> の impl は impl_id_number と impl_id_int の二つがあるから。
}
```

↓似ているがこっちは OK

```
trait Id<out T>(value: T) -> number
fn impl_id_number(x: number) -> number {
  return x;
}
impl impl_id_number as Id<int> // これは OK。まず、impl_id_number の型は (number) -> number である。次に、Id<int> を見ると、これは Id<T> の T に int を当てはめたものであるから、(value: int) -> number という関数の型を持つことになる。最後に、(number) -> number <: (int) -> number であるから、impl_id_number は Id<int> の impl として有効である。
impl impl_id_number s Id<number> // これも OK

fn main() {
  let id2 = Id<number>(123); // これは OK。Id<number> の impl は impl_id_number だけであるから。
  let id1 = Id<int>(123); // 重要: これは OK。Id<int> の impl は一見二つあるように見えるが、その実態は impl_id_number だけであるから。
}
```

↓またこれも OK

```
// variance を in out (invariant) にする。
trait Id<in out T>(value: T) -> number
fn impl_id_number(x: number) -> number {
  return x;
}
impl impl_id_number as Id<int>

fn impl_id_int(x: int) -> number {
  return x;
}
impl impl_id_int as Id<int>

fn main() {
  let id2 = Id<number>(123); // これは OK。Id<number> の impl は impl_id_number だけであるから。
  let id1 = Id<int>(123); // Id<int> <: Id<number> は成り立たない。 Id の variance が invariant であるため。
}
```

```
trait Id<out T>(value: T) -> number

// 重複して同じ type に対して impl しても問題はない (使う側で必ず重複エラーが出るだけ) (なので compiler の親切として waring を出すのはありかもだが、MVP には含めない。)
fn impl_id_number(x: number) -> number {
  return x;
}
impl impl_id_number as Id<int>

fn impl_id_number2(x: number) -> number {
  return x;
}
impl impl_id_number2 as Id<int>
```

複数の型パラメータを持つ trait。さらに変性も複雑

```
trait Converter<out T, in U>(input: T) -> U

fn impl_converter_string_int(s: string) -> int {
  return parseInt(s);
}
impl impl_converter_string_int as Converter<string, int> // これで T <: string, number <: U なる type に対して Converter を実装したことになる。

fn main() {
  let c1: number = Converter<"0" | "1", number>("0") // OK
}
```

with パラメータを持つ trait

```
effect ConvertError(message: string) -> never
trait EffectfulConverter<out T, in U>(input: T) -> U with ConvertError

fn impl_effectful_converter_string_int(s: string) -> int with ConvertError {
  let n = parseInt(s)
  if (isNaN(n)) {
    throw ConvertError(`Cannot convert ${s} to int`)
  }
  return n;
}
impl impl_effectful_converter_string_int as EffectfulConverter<string, int> // 同様に型検査する。effect 節は covariant なので ConvertError <: ConvertError で OK
```

effect を generics として取る trait

MVP では、ある impl を起点として別の impl をするような trait 機能は実装しない。将来必ず実装するので、そこは考慮して設計する必要がある。

例(MVP では実装しない):

```
fn show_array<T>[Show<T>](arr: Array<T>) -> string {
  return "[" + arr.map(x => Show<T>(x)).join(", ") + "]";
}
impl<T>[Show<T>] show_array<T> as Show<Array<T>> // Show<T> を実装しているすべての T に対してShow<Array<T>> を実装する。
```

## impl 自動導出機構、serialize, deserialize の自動導出を実装

コンパイラ側で impl を用意してあげることができる。その場合の構文はこう

```
derive TraitName<Type1, Type2>
```

`prim.json` に次の trait を (仮想的に) 追加

```
effect JsonDeserializationError(message: string) -> never

trait Serialize <out T>(value: T) -> Json
trait Deserialize<out T>(json: Json) -> T with JsonDeserializationError
```

さらに、Serialize, Deserialize の impl を自動導出する機構を実装。これは data 定義について次を満たすときに可能。

1. それが object 形式の data である。
2. 全てのフィールドが Json に変換可能な型である (つまり、ToJson の impl が存在する)。

例:

```
data User<ID> {
  id: ID,
  name: string,
  isAdmin: boolean
}

derive json.Serialize<User<int>>
derive json.Deserialize<User<int>>

fn main() {
  let user = User<int> { id: 123, name: "Alice", isAdmin: false }
  let json: Json = json.Serialize<User<int>>(user)
  handle {
    let parsedUser = json.Deserialize<User<int>>(json)
    print(`Parsed user: ${parsedUser.name}`)
  } with {
    case json.JsonDeserializationError(msg) => print(`Failed to parse JSON: ${msg}`)
  }
}
```

なお、中身は以下のようになるだろう。

```
fn serialize_user(user: User) -> Json {
  return json.make_object([
    ("id", json.JsonNumber(user.id)),
    ("name", json.JsonString(user.name)),
    ("isAdmin", json.JsonBoolean(user.isAdmin))
  ]);
}

fn deserialize_user(json: Json) -> User with json.JsonDeserializationError {
  let idJson = json.get(json, "id");
  let nameJson = json.get(json, "name");
  let isAdminJson = json.get(json, "isAdmin");

  match (idJson, nameJson, isAdminJson) {
    case (json.JsonNumber(id), json.JsonString(name), json.JsonBoolean(isAdmin)) =>
      return User { id: id, name: name, isAdmin: isAdmin };
    case _ =>
      throw json.JsonDeserializationError("Invalid JSON format for User");
  }
}
```

また、primitive 型についても serialize, deserialize をデフォルトで用意しておく。すなわち

```
Serialize<number>, Serialize<string>, Serialize<boolean>, Serialize<null> の impl と Deserialize<number>, Deserialize<string>, Deserialize<boolean>, Deserialize<null>
```

Array については見送り。どうするのがベストだろう　今 impl から impl 生やせないからな……

## 並列処理の実装

並列計算を可能にする。Algebraic Effects を並列時に実行した場合の動作は後述。

それぞれ、`prim.parallel` というモジュールに入っているとみなされる。次の primitive function があるものとして型付けをする。

```
// 任意の effect E について、
fn all<T, E>(tasks: Array<() -> T with (E | Task)>) -> Array<T> with (E | Task)
```

一旦 any とかは無し

### Algebraic Effects の動作

all の task の中で operation call が発生した場合の処理。
キューイングが必要となる。

次を満たすように実装したい

- 同時に処理している operation call は 1 つだけであること
- 並列に計算できること。

```
handle {
  let results = parallel.all<int, CurrentEffects>([
    () => {
      // task 1
      ...
      Op(v); // operation call
      ...
    },
    () => {
      // task 2
      ...
      Op(v); // operation call
      ...
    },
    ...
  ]);
  return results.sum();
} with {
  case Op(...) => {
    // Op のハンドリング
    ...
    continue value;
  }
  case Op2(...) => {
    // Op2 のハンドリング
    ...
    break value;
  }
}
```

1. parallel.all は全てのタスクを同時に開始する。このとき、operation queue を作っておく
2. タスクの中で Op(v) が呼び出される。このとき、この task は operation queue に Op を入れて、一時停止 (後々再開できるように、queue の構造はいい感じにしておく必要がある。)
   ただし、他のタスクは停止しない。他のタスクも同様に operation call をすると、queue にいれて一時停止する。
3. parallel.all は queue を前から消費していき、上位の handler に投げる。
4. handler が結果を返したら、continue なら、その値で該当 task を再開。break なら、その他タスクを強制的に停止する。(停止シグナルを送る) break の右辺が handle 式の返り値となる。
5. タスクが完了したら、他のタスクが完了するまで値をどこかに記録しておく。
6. 全てのタスクが完了したら、parallel.all の返り値として、全てのタスクの結果を配列にして返す。

なお、handler variable は、並列処理の中でも共有する (そのためのキュー)

## FFI の実装

まずは JavaScript の FFI を実装する。同名の JavaScript ファイルから、関数を呼び出せる。

たとえば、foo.js

```javascript
export let bar = async (ctx, x) => {
  ctx.return(x + 1);
};
```

foo.qtl

```
foreign fn bar(x: number) -> number with Throw<FFIError> // return type は省略できない。**使える型は Serialize / Deserialize trait を impl しているもの** に限られる。FFIError Effect は必ず含まれる。
```

その他の effect が入っていても動く。関数を foreign fn 定義する場合、export するのは次のオブジェクトである。

```javascript
export let effect_test = async (ctx, arg1, arg2, ...) => {
  // arg は runtime 側で serialize -> to_string, js 側で Json.parse されたものが入る。
  // return / call に渡した値は js 側で Json.stringify -> runtime 側で from_string -> deserialize される。
  let config = await ctx.call("config.ReadConfig", []); // Effect を呼び出す。effect の名前は ffi が定義されているモジュールでの、呼び出しと同じ。
  // たとえば↑は `util.config` に ReadConfig effect が定義されていて、FFI しているのは `foo.js` と `foo.qtl`、`foo.qtl` の中で `import "util.config"` としている場合。
  // `import "util.config" as baz` としている場合は `ctx.call("baz.ReadConfig", [])` となるし、`import { ReadConfig } from "util.config"` としている場合は `ctx.call("ReadConfig", [])` となる。
  let result = await someAsyncOperation(arg1, arg2, config);
  ctx.return(result); // return で処理を戻せる。
}
```

```
foreign fn effect_test(x: number) -> number with (Throw<FFIError> | ReadConfig | Task) // effect の arg, return type も Serialize / Deserialize trait を impl している必要がある。
```

注意点 : Task について

- effect に Task を付けなくてはいけないのは次の場合である。
  - FFI 関数が、"call" の待機を除く場所で、非同期な場合。
  - 逆に "call" の待機をする場所では await を使える。例:
  ```javascript
  // この関数は Task なし、ReadConfig Effect だけで OK
  export let foo = async (ctx, x) => {
    let result = await ctx.call("config.ReadConfig", []); // これは await できる。
    // これ以外に await が無ければ Task は必要ない (もちろん純粋である必要はある)
    // この静的検証は……　一旦行わない。
    ctx.return(result);
  };
  ```

また、FFIError effect は prim.ffi モジュールに定義されているものとする。

```
data FFIFunctionNotFoundError(name: string)

data FFIError = FFIFunctionNotFoundError | JsonParseError | JsonFieldNotFoundError | JsonDeserializationError | ... // 将来的に増える可能性がある effect もここに追加していく。
```

IR 的には、一旦すべての export がバンドルされたデカい javascript があることを仮定する (これは cli が別途 esbuild を呼び出して作成)

たとえば、次のような FFI が想定できる。

cron.js

```javascript
export let cron = async (ctx, schedule) => {
  // 今回は setInterval
  // ctx.onBreak で、handler が break した時の処理を登録できる
  let intervalId = setInterval(() => {
    ctx.call("Triggered", []); // 今回は返り値になにもしない
  }, schedule);
  ctx.onBreak(() => {
    clearInterval(intervalId);
  });
};
```

↑ これは無限に値を返さない task なので完了しないが、handle 式が break したとき、停止シグナルが伝播し、最終的には ctx.onBreak に登録された関数が呼び出される。これにより、setInterval を止めることができる。

cron.qtl

```
effect Triggered() -> null
foreign fn cron(schedule: number) -> null with (FFIError | Triggered | Task)
```

main.qtl

```
import "cron"

fn main() with Task {
  handle {
    cron.cron(1000); // 1秒ごとに Triggered Effect を呼び出す。
  } with {
    case cron.Triggered() => {
      log.info("Triggered!");
      continue null;
    }
    case Throw(e) => {
      // 今エラー握りつぶしてるの微妙だが、match e でそれぞれ処理するのもだるいから何かしら方法考える (TODO)
      log.error(`Error in cron: ${e}`);
      break null;
    }
  }
}
```

再起動耐性: TODO

## 上記変更に対する IR の設計変更

IR の設計を全面的に見直し、上記実装に耐えうるかを精査。変更必要がある点があれば、後方互換性、編集コストを無視して大胆に変更 OK。

Task は結局以下の処理を適切に実行する必要がある

- log 各種
- panic
- handle / operation call
- FFI call
- parallel.all

複雑な effect handling が動くか確認。例えば、

1. ネストした handler 内で
2. parallel.all を使い
3. さらにその中で FFI 呼び出し

等

また、どこまで IR の責務でどこから Runtime の責務かも今一度、整理して考えなおしてください。
