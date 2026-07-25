module Katari.Typechecker.ProgramSpec (spec) where

import Data.Foldable (toList)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.SourceSpan (Located (..))
import Katari.Diagnostics (Diagnostics)
import Katari.Error (CompilerError (..), compilerErrorCode, renderTypeError, typeErrorCode)
import Katari.Identifier (identifyModule, scanExports)
import Katari.Identifier.Monad (IdentifiedModule (..), ImportContext (..))
import Katari.Parser (parseModule)
import Katari.Typechecker (checkProgram)
import Katari.Typechecker.Environment (buildEnvironment)
import Katari.Typechecker.ValueGraph (valueSCCs)
import Test.Hspec

-- | The checker resolves references to every kind of seeded value (data constructor / external /
-- primitive / request), not just agents — so these whole-program checks emit no type errors where
-- before the value's scheme was missing (K3011 "not yet typed").
spec :: Spec
spec = describe "checkProgram (value-scheme seeding)" $ do
  it "resolves a data constructor reference" $
    typeErrorCodes [("test", "data point(x: integer)\nagent make() -> point { point(x = 1) }")] `shouldBe` []

  it "reads a field from a data value" $
    typeErrorCodes [("test", "data point(x: integer)\nagent getX(p: point) -> integer { p.x }")] `shouldBe` []

  it "resolves a request reference" $
    typeErrorCodes [("test", "request tick() -> integer\nagent run() -> integer { tick() }")] `shouldBe` []

  it "resolves an external agent reference" $
    typeErrorCodes [("test", "external agent ext(value: integer) -> integer\nagent run() -> integer { ext(value = 1) }")] `shouldBe` []

  it "resolves a primitive agent reference" $
    typeErrorCodes [("test", "primitive agent prim(value: integer) -> integer\nagent run() -> integer { prim(value = 1) }")] `shouldBe` []

  it "instantiates a generic primitive applied explicitly" $
    typeErrorCodes [("test", "primitive agent identity[a](value: a) -> a\nagent run() -> integer { identity[integer](value = 1) }")] `shouldBe` []

  it "infers a generic primitive's type argument from the call (no explicit application needed)" $
    typeErrorCodes [("test", "primitive agent identity[a](value: a) -> a\nagent run() -> integer { identity(value = 1) }")] `shouldBe` []

  it "uses a generic's bound when checking the body (a `T extends number` is a number)" $
    typeErrorCodes [("test", "agent widen[T extends number](x: T) -> number { x }")] `shouldBe` []

  it "accepts an explicit type argument that satisfies the bound" $
    typeErrorCodes [("test", "primitive agent num[a extends number](value: a) -> a\nagent run() -> integer { num[integer](value = 1) }")] `shouldBe` []

  it "rejects an explicit type argument that violates the bound (K3001)" $
    typeErrorCodes [("test", "primitive agent num[a extends number](value: a) -> a\nagent run() -> string { num[string](value = \"x\") }")] `shouldContain` ["K3001"]

  it "accepts a bounded data type applied in an annotation when the argument satisfies the bound" $
    typeErrorCodes [("test", "data box[a extends number](value: a)\nagent run(b: box[integer]) -> integer { b.value }")] `shouldBe` []

  it "rejects a bounded data type applied in an annotation when the argument violates the bound (K3001)" $
    typeErrorCodes [("test", "data box[a extends number](value: a)\nagent run(b: box[string]) -> integer { 0 }")] `shouldContain` ["K3001"]

  it "accepts a string interpolation in a template" $
    typeErrorCodes [("test", "agent greet(name: string) -> string { f\"hi ${name}\" }")] `shouldBe` []

  it "accepts a number and a boolean interpolation in a template (rendered canonically)" $
    typeErrorCodes [("test", "agent greet(count: integer, flag: boolean) -> string { f\"n=${count} f=${flag}\" }")] `shouldBe` []

  it "rejects a null interpolation in a template (K3001)" $
    typeErrorCodes [("test", "agent greet(name: string | null) -> string { f\"hi ${name}\" }")] `shouldContain` ["K3001"]

  it "accepts a parameter default that matches its type" $
    typeErrorCodes [("test", "agent inc(x: number ?= 1) -> number { x }")] `shouldBe` []

  it "rejects a parameter default that violates its type (K3001)" $
    typeErrorCodes [("test", "agent inc(x: number ?= \"a\") -> number { x }")] `shouldContain` ["K3001"]

  it "a `lacks` effect parameter lets a handler peel the reserved request off a generic row" $
    typeErrorCodes
      [ ( "test",
          "request settled(text: string) -> null\n\
          \request noise() -> null\n\
          \agent with_first[effect E lacks settled](task: agent (value: null) -> string with E) -> string with E {\n\
          \  use handler { request settled(text: string) -> null { break text } }\n\
          \  settled(text = task(value = null))\n\
          \  \"(unreachable)\"\n\
          \}\n\
          \agent caller() -> string with noise {\n\
          \  agent task(value: null) -> string { noise(); \"done\" }\n\
          \  with_first(task = task)\n\
          \}"
        )
      ]
      `shouldBe` []

  it "rejects a call whose task performs the reserved request (the lacks constraint, K3001)" $
    typeErrorCodes
      [ ( "test",
          "request settled(text: string) -> null\n\
          \agent with_first[effect E lacks settled](task: agent (value: null) -> string with E) -> string with E {\n\
          \  use handler { request settled(text: string) -> null { break text } }\n\
          \  settled(text = task(value = null))\n\
          \  \"(unreachable)\"\n\
          \}\n\
          \agent caller() -> string {\n\
          \  agent task(value: null) -> string { settled(text = \"sneaky\"); \"done\" }\n\
          \  with_first(task = task)\n\
          \}"
        )
      ]
      `shouldContain` ["K3001"]

  it "rejects a `lacks` entry that is not a bare request name (K3026)" $
    typeErrorCodes
      [ ( "test",
          "agent bad[effect E lacks integer](task: agent (value: null) -> string with E) -> string with E {\n\
          \  task(value = null)\n\
          \}"
        )
      ]
      `shouldContain` ["K3026"]

  it "a catch-all handler covers a still-generic tail (the coverage split: {...E, fail[unknown]} absorbs bare E)" $
    typeErrorCodes
      [ ( "test",
          "request fail[T](error: T) -> null\n\
          \agent supervise[T, effect E](task: agent (value: null) -> T with E, recover: agent (value: null) -> T with E) -> T with E {\n\
          \  use handler { request fail(error: unknown) -> null { break recover(value = null) } }\n\
          \  task(value = null)\n\
          \}\n\
          \agent caller() -> string {\n\
          \  agent task(value: null) -> string { fail(error = \"boom\"); \"ok\" }\n\
          \  agent recover(value: null) -> string { \"crashed\" }\n\
          \  supervise(task = task, recover = recover)\n\
          \}"
        )
      ]
      `shouldBe` []

  it "a NARROW handler over a still-generic tail stays rejected (K3001 — no covering instantiation)" $
    typeErrorCodes
      [ ( "test",
          "request fail[T](error: T) -> null\n\
          \agent bad[effect E](task: agent (value: null) -> string with E) -> string with E {\n\
          \  use handler { request fail(error: string) -> null { break \"caught\" } }\n\
          \  task(value = null)\n\
          \}"
        )
      ]
      `shouldContain` ["K3001"]

  it "a handler at the top payload discharges a still-generic tail's request (extract-and-compare: top instantiation fits unknown)" $
    typeErrorCodes
      [ ( "test",
          "request fail[T](error: T) -> null\n\
          \agent supervise[T, effect E](task: agent (value: null) -> T with E, recover: agent (value: null) -> T with {...E lacks fail}) -> T with {...E lacks fail} {\n\
          \  use handler { request fail(error: unknown) -> null { break recover(value = null) } }\n\
          \  task(value = null)\n\
          \}\n\
          \agent caller() -> string {\n\
          \  agent task(value: null) -> string { fail(error = \"boom\"); \"ok\" }\n\
          \  agent recover(value: null) -> string { \"crashed\" }\n\
          \  supervise(task = task, recover = recover)\n\
          \}"
        )
      ]
      `shouldBe` []

  it "a handler at a NARROWER payload over a still-generic tail is a type error (K3001 — the tail's top instantiation does not fit)" $
    typeErrorCodes
      [ ( "test",
          "request fail[T](error: T) -> null\n\
          \agent bad[effect E](task: agent (value: null) -> string with E) -> string with E {\n\
          \  use handler { request fail(error: string) -> null { break \"caught\" } }\n\
          \  task(value = null)\n\
          \}"
        )
      ]
      `shouldContain` ["K3001"]

  it "the subtraction form {...E lacks req} drops a concrete entry and constrains the tail" $
    typeErrorCodes
      [ ( "test",
          "request fail[T](error: T) -> null\n\
          \agent shed[effect E](task: agent (value: null) -> string with {...E, fail[string]}) -> string with {...E lacks fail} {\n\
          \  use handler { request fail(error: string) -> null { break \"caught\" } }\n\
          \  task(value = null)\n\
          \}"
        )
      ]
      `shouldBe` []

  it "the extraction unions the tail's upper bound first: a handler at the bound's instantiation covers" $
    typeErrorCodes
      [ ( "test",
          "request tagged[T](value: T) -> null\n\
          \agent drain[effect E extends tagged[string]](task: agent (value: null) -> string with E) -> string with {...E lacks tagged} {\n\
          \  use handler { request tagged(value: string) -> null { next null } }\n\
          \  task(value = null)\n\
          \}"
        )
      ]
      `shouldBe` []

  it "extraction from the any effect is the covariant top: a narrow handler over `with all` is a type error (K3001)" $
    typeErrorCodes
      [ ( "test",
          "request fail[T](error: T) -> null\n\
          \agent bad(task: agent (value: null) -> string with all) -> string with all {\n\
          \  use handler { request fail(error: string) -> null { break \"caught\" } }\n\
          \  task(value = null)\n\
          \}"
        )
      ]
      `shouldContain` ["K3001"]

  it "a catch-all at unknown covers the any effect" $
    typeErrorCodes
      [ ( "test",
          "request fail[T](error: T) -> null\n\
          \agent ok(task: agent (value: null) -> string with all) -> string with all {\n\
          \  use handler { request fail(error: unknown) -> never { break \"caught\" } }\n\
          \  task(value = null)\n\
          \}"
        )
      ]
      `shouldBe` []

  it "a fully annotated local agent may recurse, directly and through a nested agent" $
    typeErrorCodes
      [ ( "test",
          "agent run(flag: boolean) -> string {\n\
          \  agent bounce(value: boolean) -> string with pure {\n\
          \    agent inner(inner_value: boolean) -> string with pure {\n\
          \      match (inner_value) { case true -> bounce(value = false) case false -> \"done\" }\n\
          \    }\n\
          \    inner(inner_value = value)\n\
          \  }\n\
          \  bounce(value = flag)\n\
          \}"
        )
      ]
      `shouldBe` []

  it "an under-annotated recursive local agent reports the annotation requirement (K3013), not a panic" $
    typeErrorCodes
      [ ( "test",
          "agent run() -> string {\n\
          \  agent loop_step(value: string) -> string {\n\
          \    loop_step(value = value)\n\
          \  }\n\
          \  loop_step(value = \"x\")\n\
          \}"
        )
      ]
      `shouldContain` ["K3013"]

  it "a for `then` clause may read a `var` state variable" $
    typeErrorCodes [("test", "agent run() -> integer { for (x in [1], var total = 0) { next x with total = total + x } then (r) { total } }")] `shouldBe` []

  it "a record pattern reads a field from a nominal data value" $
    typeErrorCodes [("test", "data point(x: integer)\nagent getX(p: point) -> integer { match (p) { case { x => v } -> v } }")] `shouldBe` []

  it "calls a value whose generic bound is a function type" $
    typeErrorCodes [("test", "agent apply[F extends agent (x: integer) -> integer](f: F) -> integer { f(x = 1) }")] `shouldBe` []

  it "rejects duplicate generic parameter names (K2003)" $
    allErrorCodes [("test", "agent foo[a, a](x: integer) -> integer { x }")] `shouldContain` ["K2003"]

  it "a generic's own `extends` bound does not resolve to itself (K2001)" $
    allErrorCodes [("test", "agent foo[a extends a](x: a) -> a { x }")] `shouldContain` ["K2001"]

  -- Attribute soundness: a pure private agent is callable in a public context, but its result is
  -- private, so it cannot be laundered back to public.
  it "rejects returning a pure private agent's result as public (K3001)" $
    typeErrorCodes [("test", "private agent secret() -> integer { 1 }\nagent leak() -> integer { secret() }")] `shouldContain` ["K3001"]

  it "accepts a pure private agent's result inside a private agent" $
    typeErrorCodes [("test", "private agent secret() -> integer { 1 }\nprivate agent ok() -> integer { secret() }")] `shouldBe` []

  -- A field read is observed through its container, so a field of a private value is itself private.
  it "rejects using a field read off a private value as public (K3001)" $
    typeErrorCodes [("test", "data point(x: integer)\nprivate agent make() -> point { point(x = 1) }\nagent f() -> integer { make().x }")] `shouldContain` ["K3001"]

  it "accepts a field read off a private value inside a private agent" $
    typeErrorCodes [("test", "data point(x: integer)\nprivate agent make() -> point { point(x = 1) }\nprivate agent f() -> integer { make().x }")] `shouldBe` []

  -- A variable pattern always matches; its annotation must be a supertype of the scrutinee, and it
  -- does not narrow the match (a wildcard fallback cannot rescue a too-narrow binder).
  it "rejects a variable pattern whose annotation is narrower than the scrutinee (K3001)" $
    typeErrorCodes [("test", "agent f(e: number) -> integer { match (e) { case x: integer -> 0 } }")] `shouldContain` ["K3001"]

  it "rejects the narrow variable pattern even with a wildcard fallback (K3001)" $
    typeErrorCodes [("test", "agent f(e: number) -> integer { match (e) { case x: integer -> 0\ncase _ -> 1 } }")] `shouldContain` ["K3001"]

  it "accepts a variable pattern whose annotation is a supertype of the scrutinee" $
    typeErrorCodes [("test", "agent f(e: integer) -> integer { match (e) { case x: number -> 0 } }")] `shouldBe` []

  -- A match is first-match, so a later arm only sees values no earlier arm matched: a variable /
  -- wildcard binder therefore narrows to that residual. After `case null` covers null, a following
  -- `case rest` binds `rest` at the non-null residual — the plain, in-language way to fold a nullable.
  it "narrows a variable binder to the non-null residual after a null arm" $
    typeErrorCodes [("test", "agent f(v: integer | null) -> integer { match (v) { case null -> 0\ncase rest -> rest } }")] `shouldBe` []

  -- The residual also satisfies an annotated binder's supertype requirement: over the non-null
  -- residual `integer`, an `(x: integer)` arm is accepted where the full `integer | null` scrutinee
  -- would have been rejected.
  it "accepts an annotated binder at the residual type after a null arm" $
    typeErrorCodes [("test", "agent f(v: integer | null) -> integer { match (v) { case null -> 0\ncase x: integer -> x } }")] `shouldBe` []

  -- Narrowing subtracts a matched `data` constructor too (null is a value, `box` a constructor): after
  -- the null arm the residual keeps only `box`, so `rest` binds at `box`.
  it "narrows a data-or-null scrutinee to the data type after a null arm" $
    typeErrorCodes [("test", "data box(x: integer)\nagent f(v: box | null) -> box { match (v) { case null -> box(x = 0)\ncase rest -> rest } }")] `shouldBe` []

  -- A match left non-exhaustive by one constructor reports exactly ONE diagnostic — the uncovered
  -- constructor — and does not cascade the byproduct of the constructor-subtype escape hatch (the
  -- expanded record vs. the supertype: "Object layers are incompatible … actual: record"). Regression
  -- for the double diagnostic the coverage check used to emit at a single span.
  it "reports one diagnostic for a non-exhaustive data-union match (no cascaded record-layer noise)" $ do
    let messages =
          typeErrorMessages
            [("test", "data red()\ndata green()\ndata blue()\nagent f(c: red | green | blue) -> integer { match (c) { case red() -> 1\ncase green() -> 2 } }")]
    length messages `shouldBe` 1
    messages `shouldSatisfy` any (Text.isInfixOf "not a subtype either: test.blue")
    messages `shouldSatisfy` (not . any (Text.isInfixOf "Object layers are incompatible"))

  -- Narrowing is residual, not unconditional: a first-arm variable still sees the full scrutinee, so a
  -- lone `case rest` over `integer | null` binds `rest` nullable (K3001 on the non-null return).
  it "does not narrow a first-arm variable binder (still sees the full scrutinee, K3001)" $
    typeErrorCodes [("test", "agent f(v: integer | null) -> integer { match (v) { case rest -> rest } }")] `shouldContain` ["K3001"]

  -- A match observes its scrutinee: a pure arm carries the scrutinee's privacy into the result.
  it "rejects a match whose pure arm launders a private scrutinee to public (K3001)" $
    typeErrorCodes [("test", "private agent sec() -> integer { 1 }\nagent f() -> integer { match (sec()) { case _ -> 0 } }")] `shouldContain` ["K3001"]

  it "accepts a private match result inside a private agent" $
    typeErrorCodes [("test", "private agent sec() -> integer { 1 }\nprivate agent f() -> integer { match (sec()) { case _ -> 0 } }")] `shouldBe` []

  -- A non-pure arm cannot be lifted across worlds, so a private scrutinee requires a private world.
  it "rejects a non-pure arm matching a private scrutinee in a public world (K3001)" $
    typeErrorCodes [("test", "request tick() -> integer\nprivate agent sec() -> integer { 1 }\nagent f() -> integer { match (sec()) { case _ -> tick() } }")] `shouldContain` ["K3001"]

  it "accepts a non-pure arm matching a private scrutinee inside a private agent" $
    typeErrorCodes [("test", "request tick() -> integer\nprivate agent sec() -> integer { 1 }\nprivate agent f() -> integer { match (sec()) { case _ -> tick() } }")] `shouldBe` []

  -- Destructuring positions past the fixed prefix may be absent, so they read as @T | null@.
  it "rejects using an out-of-range tuple-pattern position as non-null (K3001)" $
    typeErrorCodes [("test", "agent f(arr: array[number]) -> number { match (arr) { case [a, b, c] -> c\ncase _ -> 0 } }")] `shouldContain` ["K3001"]

  -- A bounded application written inside another declaration's `extends` bound is itself checked.
  it "rejects a bound violation written inside another type's extends bound (K3001)" $
    typeErrorCodes [("test", "data B[U extends number](u: U)\ndata A[T extends B[string]](t: T)")] `shouldContain` ["K3001"]

  -- `if` observes its condition just like `match` observes its scrutinee.
  it "rejects an `if` whose pure branches launder a private condition to public (K3001)" $
    typeErrorCodes [("test", "private agent flag() -> boolean { true }\nagent f() -> integer { if (flag()) { 1 } else { 0 } }")] `shouldContain` ["K3001"]

  it "accepts a private `if` result inside a private agent" $
    typeErrorCodes [("test", "private agent flag() -> boolean { true }\nprivate agent f() -> integer { if (flag()) { 1 } else { 0 } }")] `shouldBe` []

  -- A `return` / `break` / `next` escaping an arm or branch makes it non-pure, so a private value
  -- cannot drive an escaping jump in a public world.
  it "rejects a match arm that returns on a private scrutinee in a public world (K3001)" $
    typeErrorCodes [("test", "private agent sec() -> integer { 1 }\nagent f() -> integer { match (sec()) { case _ -> { return 0 } } }")] `shouldContain` ["K3001"]

  it "accepts a match arm that returns on a private scrutinee inside a private agent" $
    typeErrorCodes [("test", "private agent sec() -> integer { 1 }\nprivate agent f() -> integer { match (sec()) { case _ -> { return 0 } } }")] `shouldBe` []

  it "rejects an `if` branch that returns on a private condition in a public world (K3001)" $
    typeErrorCodes [("test", "private agent flag() -> boolean { true }\nagent f() -> integer { if (flag()) { return 0 } else { 1 } }")] `shouldContain` ["K3001"]

  -- A jump captured by a nested `for` does not escape the arm, so the arm stays pure (no over-rejection).
  -- 'allErrorCodes' (all phases) guards against a silent parse/identify failure masking a spurious pass.
  it "accepts a private-scrutinee arm whose nested `for` jump is captured" $
    allErrorCodes [("test", "private agent sec() -> integer { 1 }\nagent f() -> array[integer] of private { match (sec()) { case _ -> for (x in [1, 2]) { next x } } }")] `shouldBe` []

  -- An optional object field may be absent, so reading it yields @T | null@, not @T@.
  it "rejects reading an optional object field as non-null (K3001)" $
    typeErrorCodes [("test", "agent f(r: {x?: integer}) -> integer { r.x }")] `shouldContain` ["K3001"]

  it "accepts reading an optional object field at a nullable type" $
    typeErrorCodes [("test", "agent f(r: {x?: integer}) -> integer | null { r.x }")] `shouldBe` []

  -- Duplicate field labels are rejected (K2003) like duplicate call-argument / parameter labels.
  it "rejects a record literal with duplicate field labels (K2003)" $
    allErrorCodes [("test", "agent f() -> integer { let r = {x = 1, x = 2}\n0 }")] `shouldContain` ["K2003"]

  it "rejects an object type with duplicate field labels (K2003)" $
    allErrorCodes [("test", "agent f(r: {x: integer, x: string}) -> integer { 0 }")] `shouldContain` ["K2003"]

  it "rejects a record pattern with duplicate field labels (K2003)" $
    allErrorCodes [("test", "agent f(r: {x: integer}) -> integer { match (r) { case {x => a, x => b} -> a } }")] `shouldContain` ["K2003"]

  -- A pure call lifts by the argument's /excess/ over the parameter: a private the parameter does not
  -- expect (a private value reaching a public position) leaks and taints the result, while one the
  -- parameter already expects is absorbed. Passing a private-carrying argument to a /public/ parameter
  -- is what exposes this, and it happens only at covariant positions: a private in a contravariant data
  -- position is read out at a public type (contravariance flips the check), so it never leaks.
  it "accepts a pure call passing a value private in a contravariant data position to a public parameter" $
    typeErrorCodes [("test", "data Sink[T](consume: agent(x: T) -> null)\nagent observe(s: Sink[integer]) -> integer { 0 }\nagent caller(s: Sink[integer of private]) -> integer { observe(s = s) }")] `shouldBe` []

  it "rejects a pure call passing a value private in a covariant data position to a public parameter (K3001)" $
    typeErrorCodes [("test", "data Box[T](value: T)\nagent observe(b: Box[integer]) -> integer { 0 }\nagent caller(b: Box[integer of private]) -> integer { observe(b = b) }")] `shouldContain` ["K3001"]

  -- A pure call whose parameter /expects/ the private (a sink @agent(value: string of private)@) absorbs
  -- the secret argument: nothing leaks, so the return stays at its declared public type. Guards the
  -- regression where any private argument tainted the result even when the parameter already required it.
  it "accepts a pure call passing a private argument to a parameter that expects private" $
    allErrorCodes [("test", "agent sink(value: string of private) -> integer { 0 }\nagent f(key: string of private) -> integer { sink(value = key) }")] `shouldBe` []

  -- The `prelude.http.fetch` information-flow rule, tested at the type layer where it lives (attribute
  -- subtyping: public <: private, so a public value fits a private-capable sink but a private value does
  -- NOT fit a public one). `fetchLike` mirrors fetch's exact parameter attributes: `url` / `method` are
  -- public `string`, while `headers` values AND `body` are `string of private` (the deliberate submission
  -- surfaces). A public-world caller may submit a secret header AND a secret body to the destination
  -- server, because each private-capable parameter absorbs its private argument (nothing is observed, so
  -- the result stays public and the `io` call needs no private world).
  it "accepts a public-world caller submitting a private header AND a private body to fetch's private-capable sinks" $
    allErrorCodes [("test", fetchLike <> "agent submit() -> integer with io { fetch_like(url = \"https://api.test\", method = \"POST\", headers = { authorization = secret() }, body = secret()) }")] `shouldBe` []

  -- The honest negative that keeps the rule from decaying into "every parameter is a private sink": the
  -- `url` stays a PUBLIC sink, so a private value reaching it is a type error (K3001). A URL leaks into
  -- logs, caches, proxies, and `Referer` headers — not the destination server — so a secret must never
  -- ride it, even though the very same secret is accepted in the body one argument over.
  it "rejects a private value reaching fetch's public `url` sink (K3001)" $
    typeErrorCodes [("test", fetchLike <> "agent leak() -> integer with io { fetch_like(url = secret(), method = \"POST\", headers = { authorization = secret() }, body = \"\") }")] `shouldContain` ["K3001"]

  -- A shape inspector (field read / iteration / destructure) requires the value to be /solely/ the
  -- shape it reads: a @... | null@ (or otherwise mixed) union is rejected (K3014), so the dropped
  -- member can no longer surface as a non-null result. A call already demanded a lone function.
  it "rejects reading a field off a nullable object union (K3014)" $
    typeErrorCodes [("test", "agent f(r: {x: integer} | null) -> integer { r.x }")] `shouldContain` ["K3014"]

  it "accepts reading a field shared by every member of an object union" $
    typeErrorCodes [("test", "agent f(r: {x: integer} | {x: integer, y: integer}) -> integer { r.x }")] `shouldBe` []

  it "rejects iterating a nullable array union (K3014)" $
    typeErrorCodes [("test", "agent f(xs: array[integer] | null) -> array[integer] { for (x in xs) { next x } }")] `shouldContain` ["K3014"]

  -- Exhaustiveness is base-type coverage, not observation, so an exhaustive non-wildcard match over a
  -- private scrutinee is accepted (the public covers are compared ignoring attributes).
  it "accepts an exhaustive match over a private scrutinee" $
    typeErrorCodes [("test", "private agent sec() -> boolean { true }\nagent f() -> boolean of private { match (sec()) { case true -> true\ncase false -> false } }")] `shouldBe` []

  it "still rejects a non-exhaustive match (K3001)" $
    typeErrorCodes [("test", "agent f(b: boolean) -> integer { match (b) { case true -> 1 } }")] `shouldContain` ["K3001"]

  -- A handler request body is deferred and a handler @then@ finalizer is jumpless, so neither may
  -- @return@ to the enclosing agent: such a jump is misplaced (K3012). A @for@'s @then@, by contrast,
  -- inherits the outer control context, so a @return@ there validly targets the enclosing agent.
  it "rejects a `return` inside a handler request body (K3012)" $
    typeErrorCodes [("test", "request tick() -> integer\nagent f() -> integer { let h = handler[integer, all] { request tick() -> integer { return 5 } }\nreturn 0 }")] `shouldContain` ["K3012"]

  it "accepts a `return` inside a `for` then clause (it targets the enclosing agent)" $
    typeErrorCodes [("test", "agent f() -> integer { for (x in [1]) { next x } then (r) { return 0 } }")] `shouldNotContain` ["K3012"]

  it "rejects a `return` inside a handler then clause (K3012)" $
    typeErrorCodes [("test", "request tick() -> integer\nagent f() -> integer { let h = handler[integer, all] { request tick() -> integer { next 5 } } then (r) { return r }\nreturn 0 }")] `shouldContain` ["K3012"]

  -- The handled name resolves in the type namespace (shared with data types / synonyms / generics), and
  -- a constructor-pattern name in the variable namespace (shared with agents / requests / locals): a
  -- wrong-kind name is a user error (K3017), reported rather than crashing the checker.
  it "reports a handler whose name is a data type, not a request (K3017)" $
    typeErrorCodes [("test", "data box(x: integer)\nagent f() -> integer { use handler { request box(x: integer) -> integer { break 0 } }\n0 }")] `shouldContain` ["K3017"]

  it "reports a handler whose name is an in-scope generic, not a request (K3017)" $
    typeErrorCodes [("test", "agent f[E]() -> integer { use handler { request E() -> integer { break 0 } }\n0 }")] `shouldContain` ["K3017"]

  it "reports a constructor pattern whose name is a request, not a data type (K3017)" $
    typeErrorCodes [("test", "request ask(q: string) -> string\nagent f(v: integer) -> integer { match (v) { case ask(q => a) -> 1 } }")] `shouldContain` ["K3017"]

  it "does not flag a handler on a genuine request" $
    typeErrorCodes [("test", "request tick() -> integer\nagent f() -> integer { use handler { request tick() -> integer { break 0 } }\n0 }")] `shouldBe` []

  -- A `return` after a `use` rides the continuation's effect (an internal `EXIT` escape) back to the
  -- enclosing agent, where it is discharged and checked against the agent's return type.
  it "checks a `return` after a `use` against the enclosing agent's return type" $
    typeErrorCodes [("test", "request tick() -> integer\nagent f() -> integer { use handler { request tick() -> integer { break 0 } }\nreturn 5 }")] `shouldBe` []

  it "rejects a `return` after a `use` whose value mismatches the agent's return type (K3001)" $
    typeErrorCodes [("test", "request tick() -> integer\nagent f() -> integer { use handler { request tick() -> integer { break 0 } }\nreturn \"wrong\" }")] `shouldContain` ["K3001"]

  -- Destructuring distributes the container's privacy to its components (like a `match` scrutinee), so a
  -- private value's elements may not escape to a public context.
  it "a let-destructured element of a private value is itself private (K3001 on public escape)" $
    typeErrorCodes [("test", "private agent sec() -> [integer, integer] { [1, 2] }\nagent leak() -> integer { let [a, b] = sec()\n a }")] `shouldContain` ["K3001"]

  -- `for` is a control construct: iterating a private source with effects leaks its shape, so the body
  -- must be pure (its observed attribute must fit the world).
  it "rejects a `for` with effects over a private source (K3001)" $
    typeErrorCodes [("test", "private agent sec() -> array[integer] { [1] }\nrequest ping() -> null\nagent f() -> array[integer] with ping { for (x in sec()) { ping()\nnext 0 } }")] `shouldContain` ["K3001"]

  it "accepts a `for` with effects over a public source" $
    typeErrorCodes [("test", "request ping() -> null\nagent f() -> array[integer] with ping { for (x in [1]) { ping()\nnext 0 } }")] `shouldBe` []

  -- Bare constructor fields: `point(x)` binds the field `x` (= `point(x => x)`). No longer ambiguous
  -- with a type filter, which is now its own keyword form.
  it "binds a bare constructor-pattern field to the label-named variable" $
    typeErrorCodes [("test", "data point(x: integer)\nagent f(p: point) -> integer { match (p) { case point(x) -> x } }")] `shouldBe` []

  -- Type filters are the fixed runtime tags; `agent`, `array`, `record` match any such value, and the
  -- inner pattern sees the type extracted from the scrutinee.
  it "matches an agent value with an `agent` type filter" $
    typeErrorCodes [("test", "agent f(g: agent(integer) -> integer) -> integer { match (g) { case agent(h) -> 0 } }")] `shouldBe` []

  it "an `array` filter extracts the scrutinee's element type for the inner pattern" $
    typeErrorCodes [("test", "agent f(xs: array[integer]) -> array[integer] { match (xs) { case array(ys) -> ys } }")] `shouldBe` []

  -- A `record` filter reads a nominal data value's read shape, so a nested record pattern sees the
  -- data's actual field type, not `unknown`.
  it "a `record` filter over a data value extracts its constructor field type" $
    typeErrorCodes [("test", "data box(value: integer)\nagent f(b: box) -> integer { match (b) { case record({value => v}) -> v } }")] `shouldBe` []

  it "rejects using a `record`-extracted data field at a wrong type (K3001)" $
    typeErrorCodes [("test", "data box(value: integer)\nagent f(b: box) -> string { match (b) { case record({value => v}) -> v } }")] `shouldContain` ["K3001"]

  -- A type filter over an `unknown`-base scrutinee still carries the scrutinee's handle attribute onto
  -- the binder (the `narrowToFilter` fallback lifts it), so a private value's destructured element may
  -- not escape to a public context — the same rule as a layered scrutinee.
  it "a type-filter binder over a private unknown value is itself private (K3001 on public escape)" $
    typeErrorCodes [("test", "private agent sec(x: unknown) -> unknown { x }\nagent leak() -> array[unknown] { let array(a) = sec(x = 1)\n a }")] `shouldContain` ["K3001"]

  -- An agent parameter pattern declares its type by /reverse inference/ from the pattern: a type filter
  -- `number(y)` declares the parameter `number` and binds `y : number`; a record / nested filter works
  -- the same way.
  it "reverse-infers an agent parameter's type from a type-filter pattern" $
    typeErrorCodes [("test", "agent f(p => number(y)) -> number { y }")] `shouldBe` []

  it "reverse-infers an agent parameter's type from a record pattern with a filtered field" $
    typeErrorCodes [("test", "agent f(label => number(y)) -> number { y }")] `shouldBe` []

  it "constrains a caller by the reverse-inferred parameter type (K3001 on a wrong argument)" $
    typeErrorCodes [("test", "agent f(p => number(y)) -> number { y }\nagent run() -> number { f(p = \"x\") }")] `shouldContain` ["K3001"]

  -- A binder's inner annotation must accept every value the filter admits: `number(y : integer)` is an
  -- error because `number </: integer`.
  it "rejects a type-filter binder whose inner annotation is narrower than the filter (K3001)" $
    typeErrorCodes [("test", "agent f(p => number(y : integer)) -> number { y }")] `shouldContain` ["K3001"]

  it "still requires an annotation on a bare-variable agent parameter pattern (K3013)" $
    typeErrorCodes [("test", "agent f(p => x) -> integer { x }")] `shouldContain` ["K3013"]

  it "rejects using the extracted element type at a wrong type (K3001)" $
    typeErrorCodes [("test", "agent f(xs: array[integer]) -> array[string] { match (xs) { case array(ys) -> ys } }")] `shouldContain` ["K3001"]

  it "narrows with a primitive type filter (integer)" $
    typeErrorCodes [("test", "agent f(v: integer | string) -> integer { match (v) { case integer(n) -> n\ncase string(s) -> 0 } }")] `shouldBe` []

  -- A defaulted constructor / request parameter is optional at the call site (the caller may omit it),
  -- while a constructed value's field still reads as its (non-null) declared type.
  it "lets a caller omit a defaulted data-constructor argument" $
    typeErrorCodes [("test", "data point(x: integer, y: integer ?= 0)\nagent make() -> point { point(x = 1) }")] `shouldBe` []

  it "still reads a defaulted field as non-null (the read shape keeps it required)" $
    typeErrorCodes [("test", "data point(x: integer, y: integer ?= 0)\nagent getY(p: point) -> integer { p.y }")] `shouldBe` []

  it "still rejects omitting a required (non-defaulted) data argument (K3001)" $
    typeErrorCodes [("test", "data point(x: integer, y: integer)\nagent make() -> point { point(x = 1) }")] `shouldContain` ["K3001"]

  it "lets a caller omit a defaulted request argument" $
    typeErrorCodes [("test", "request log(line: string, level: integer ?= 0) -> null\nagent run() -> null with log { log(line = \"hi\") }")] `shouldBe` []

  it "lets a caller omit a defaulted agent parameter" $
    typeErrorCodes [("test", "agent inc(x: integer ?= 1) -> integer { x }\nagent run() -> integer { inc() }")] `shouldBe` []

  it "still rejects omitting a required agent parameter (K3001)" $
    typeErrorCodes [("test", "agent inc(x: integer) -> integer { x }\nagent run() -> integer { inc() }")] `shouldContain` ["K3001"]

  -- Every signature-determined callable (data / request / external / primitive) shares the one
  -- 'callShape' rule, so a defaulted parameter is omittable on an external / primitive agent too.
  it "lets a caller omit a defaulted external-agent parameter" $
    typeErrorCodes [("test", "external agent ext(value: integer, flag: integer ?= 0) -> integer\nagent run() -> integer { ext(value = 1) }")] `shouldBe` []

  it "lets a caller omit a defaulted primitive-agent parameter" $
    typeErrorCodes [("test", "primitive agent prim(value: integer, flag: integer ?= 0) -> integer\nagent run() -> integer { prim(value = 1) }")] `shouldBe` []

  it "still rejects omitting a required external-agent parameter (K3001)" $
    typeErrorCodes [("test", "external agent ext(value: integer, flag: integer) -> integer\nagent run() -> integer { ext(value = 1) }")] `shouldContain` ["K3001"]

  -- Container defaults: a default is a constant literal tree, checked against the declared type the
  -- same way a literal expression would be (an empty array is a closed sequence, so it subtypes any
  -- `array[T]`; a record default is a closed object).
  it "accepts an empty-array default on an array parameter" $
    typeErrorCodes [("test", "agent f(items: array[string] ?= []) -> integer { 0 }")] `shouldBe` []

  it "accepts a populated array default whose elements fit the element type" $
    typeErrorCodes [("test", "agent f(items: array[integer] ?= [1, 2]) -> integer { 0 }")] `shouldBe` []

  it "rejects an array default whose element type mismatches (K3001)" $
    typeErrorCodes [("test", "agent f(items: array[string] ?= [1]) -> integer { 0 }")] `shouldContain` ["K3001"]

  it "accepts a record default matching an object parameter and keeps the field readable" $
    typeErrorCodes [("test", "agent f(point: {x: integer} ?= {x = 1}) -> integer { point.x }")] `shouldBe` []

  it "rejects a record default missing a required field (K3001)" $
    typeErrorCodes [("test", "agent f(point: {x: integer} ?= {}) -> integer { point.x }")] `shouldContain` ["K3001"]

  it "accepts a nested container default and lets the caller omit the parameter" $
    typeErrorCodes [("test", "agent f(rows: array[{name: string}] ?= [{name = \"a\"}]) -> integer { 0 }\nagent run() -> integer { f() }")] `shouldBe` []

  it "accepts an empty-array default on a data-constructor parameter" $
    typeErrorCodes [("test", "data box(items: array[integer] ?= [])\nagent make() -> box { box() }")] `shouldBe` []

  -- `with io` and `with pure` are effect-row keywords (like `all` / `never`), so an agent that does io
  -- can spell that row explicitly, and a pure agent can pin its emptiness without the `throw[never]`
  -- workaround.
  it "accepts a `with io` row on an agent that calls an external" $
    typeErrorCodes [("test", "external agent ext(value: integer) -> integer\nagent run() -> integer with io { ext(value = 1) }")] `shouldBe` []

  it "accepts a `with pure` row on a pure agent" $
    typeErrorCodes [("test", "agent run() -> integer with pure { 1 }")] `shouldBe` []

  -- io cannot be discharged into a pure row (there is no handler for it), so `with pure` over an
  -- external call is rejected (K3001) — the very mismatch the missing surface syntax used to hide.
  it "rejects a `with pure` row on an agent that calls an external (K3001)" $
    typeErrorCodes [("test", "external agent ext(value: integer) -> integer\nagent run() -> integer with pure { ext(value = 1) }")] `shouldContain` ["K3001"]

  it "rejects a `with pure` row on an agent that performs a request (K3001)" $
    typeErrorCodes [("test", "request tick() -> integer\nagent run() -> integer with pure { tick() }")] `shouldContain` ["K3001"]

  -- An undeclared named argument is currently accepted (the callee's parameter object is open at
  -- @rest = unknown@): the runtime ignores the extra key. Pinned so the behaviour is intentional, not
  -- an accident, and a future tightening to reject unexpected arguments is a deliberate change.
  it "currently accepts an undeclared named call argument" $
    typeErrorCodes [("test", "data point(x: integer, y: integer)\nagent make() -> point { point(x = 1, y = 2, bogus = 9) }")] `shouldBe` []

  -- Message hints (asserted as substrings, not full renderings, so wording may still evolve).
  it "K3011 on a non-request override entry names the union spelling (`| io`)" $
    typeErrorMessages [("test", "agent f[effect E]() -> null with {...E, io} { null }")]
      `shouldSatisfy` any
        (\message -> "K3011" `Text.isInfixOf` message && "only unioned" `Text.isInfixOf` message && "| io" `Text.isInfixOf` message)

  it "K3001 on an agent-parameter NAME mismatch reports the names, not a bogus optionality" $
    let messages =
          typeErrorMessages
            [ ( "test",
                "external agent watch(tick: agent (time: number) -> null) -> null\n\
                \agent go() -> null {\n\
                \  agent my_tick(moment: number) -> null { null }\n\
                \  watch(tick = my_tick)\n\
                \}"
              )
            ]
     in do
          messages `shouldSatisfy` any (Text.isInfixOf "expected a parameter named `time`, found `moment`")
          messages `shouldSatisfy` (not . any (Text.isInfixOf "Optional field cannot be a subtype of a required field: moment"))

  it "K3001 on a genuinely optional record field keeps the optionality message" $
    typeErrorMessages
      [ ( "test",
          "agent f(point: {x: integer}) -> integer { point.x }\n\
          \agent g(input: {x?: integer}) -> integer { f(point = input) }"
        )
      ]
      `shouldSatisfy` any (Text.isInfixOf "Optional field cannot be a subtype of a required field: x")

  it "K3013 on an unreadable `use` binder names the pin-the-arguments fix and the synonym idiom" $
    -- A provider generic in its continuation's VALUE type (@A@) leaves the binder's type unreadable
    -- until @A@ is pinned: inference cannot run before the binder is in scope, so the type cannot be
    -- read off the provider. Neither annotated nor made concrete, so K3013 — naming both the "pin the
    -- type arguments" fix and the effect-row synonym idiom the annotate path wants. (A binder that IS
    -- readable — a handler's null continuation, a concrete provider — no longer reports at all.)
    typeErrorMessages
      [ ( "test",
          "external agent prov[A, R, effect E](continuation: agent (value: A) -> R with E) -> R with E\n\
          \agent f() -> null {\n\
          \  let x = use prov\n\
          \  null\n\
          \}"
        )
      ]
      `shouldSatisfy` ( \messages ->
                          any (Text.isInfixOf "could not read the binder's type from the provider") messages
                            && any (Text.isInfixOf "a type synonym can name the row once") messages
                      )

  -- The doc-on-let / doc-on-nested-agent annotations have no typing effect: a documented binding
  -- checks exactly like its undocumented twin (the stamp is a run-time value attribute).
  it "a documented let checks exactly like an undocumented one" $
    allErrorCodes
      [ ( "test",
          "agent read_digest(name: string) -> string { name }\n\
          \agent main() -> string {\n\
          \  @\"the herald's window on the operator\"\n\
          \  let herald_view = read_digest\n\
          \  herald_view(name = \"x\")\n\
          \}"
        )
      ]
      `shouldBe` []

  it "a documented let's value keeps flowing as its real type (return / record / re-binding)" $
    allErrorCodes
      [ ( "test",
          "agent main() -> integer {\n\
          \  @\"a documented number\"\n\
          \  let count = 1\n\
          \  @\"overwritten stamp\"\n\
          \  let again = count\n\
          \  let wrapped = { inner = again }\n\
          \  wrapped.inner\n\
          \}"
        )
      ]
      `shouldBe` []

  it "a documented nested agent declaration checks like an undocumented one" $
    allErrorCodes
      [ ( "test",
          "agent main() -> integer {\n\
          \  @\"a documented helper\"\n\
          \  agent helper(x: integer) -> integer { x }\n\
          \  helper(x = 2)\n\
          \}"
        )
      ]
      `shouldBe` []

------------------------------------------------------------------------------------------------
-- Fixtures
------------------------------------------------------------------------------------------------

-- | A local mirror of @prelude.http.fetch@'s information-flow shape (the driver seeds no prelude): the
-- @url@ / @method@ are public sinks, the @headers@ values and the @body@ are private-capable sinks, and
-- the call is impure (@io@). Paired with a @secret@ agent that yields a private @string@.
fetchLike :: Text
fetchLike =
  "external agent fetch_like(url: string, method: string, headers: record[string of private], body: string of private) -> integer with io\n"
    <> "private agent secret() -> string { \"x\" }\n"

------------------------------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------------------------------

-- | The codes of every /type/ error a whole-program run emits (so @== []@ asserts a clean check).
typeErrorCodes :: [(Text, Text)] -> [Text]
typeErrorCodes sources =
  [typeErrorCode typeError | located <- toList (runProgramDiagnostics sources), CompilerErrorType typeError <- [located.value]]

-- | The rendered messages of every /type/ error a whole-program run emits — for the hint tests,
-- which assert a substring (the codes alone cannot see a message improvement).
typeErrorMessages :: [(Text, Text)] -> [Text]
typeErrorMessages sources =
  [renderTypeError typeError | located <- toList (runProgramDiagnostics sources), CompilerErrorType typeError <- [located.value]]

-- | The codes of every diagnostic across all phases, so identifier-phase errors (K2xxx) are visible
-- too — the type-only 'typeErrorCodes' driver drops them.
allErrorCodes :: [(Text, Text)] -> [Text]
allErrorCodes sources = [compilerErrorCode located.value | located <- toList (runProgramDiagnostics sources)]

-- | Parse, identify, build the type environment, and run 'checkProgram'; the combined diagnostics of
-- the identify, env-build, and check phases.
runProgramDiagnostics :: [(Text, Text)] -> Diagnostics
runProgramDiagnostics sources =
  identifyDiagnostics <> envDiagnostics <> checkDiagnostics
  where
    parsedModules = [(ModuleName name, fst (parseModule (ModuleName name) source)) | (name, source) <- sources]
    importContext =
      ImportContext
        { moduleInterfaces = Map.fromList [(moduleName, scanExports moduleName parsedModule) | (moduleName, parsedModule) <- parsedModules],
          defaultImports = []
        }
    identifiedResults = [(moduleName, identifyModule importContext moduleName parsedModule) | (moduleName, parsedModule) <- parsedModules]
    modules = Map.fromList [(moduleName, (fst result).identifiedAst) | (moduleName, result) <- identifiedResults]
    identifyDiagnostics = foldMap (snd . snd) identifiedResults
    (typeEnvironment, envDiagnostics) = buildEnvironment modules
    (_, _, checkDiagnostics) = checkProgram typeEnvironment (valueSCCs modules) modules
