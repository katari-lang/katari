module Katari.Typechecker.ProgramSpec (spec) where

import Data.Foldable (toList)
import Data.Map qualified as Map
import Data.Text (Text)
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.SourceSpan (Located (..))
import Katari.Diagnostics (Diagnostics)
import Katari.Error (CompilerError (..), compilerErrorCode, typeErrorCode)
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

  it "rejects a non-string interpolation in a template (K3001)" $
    typeErrorCodes [("test", "agent greet(count: integer) -> string { f\"n=${count}\" }")] `shouldContain` ["K3001"]

  it "accepts a parameter default that matches its type" $
    typeErrorCodes [("test", "agent inc(x: number ?= 1) -> number { x }")] `shouldBe` []

  it "rejects a parameter default that violates its type (K3001)" $
    typeErrorCodes [("test", "agent inc(x: number ?= \"a\") -> number { x }")] `shouldContain` ["K3001"]

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

  -- @lift@ considers covariant positions only: a value private only in a /contravariant/ data position
  -- does not taint what a pure observation of it yields, but a /covariant/ one does.
  it "accepts a pure call observing a value private in a contravariant data position" $
    typeErrorCodes [("test", "data Sink[T](consume: agent(x: T) -> null)\nagent observe(s: Sink[integer of private]) -> integer { 0 }\nagent caller(s: Sink[integer of private]) -> integer { observe(s = s) }")] `shouldBe` []

  it "rejects a pure call observing a value private in a covariant data position (K3001)" $
    typeErrorCodes [("test", "data Box[T](value: T)\nagent observe(b: Box[integer of private]) -> integer { 0 }\nagent caller(b: Box[integer of private]) -> integer { observe(b = b) }")] `shouldContain` ["K3001"]

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

  -- A handler request body is deferred, and a @then@ finalizer runs once after its construct, so
  -- neither may @return@ to the enclosing agent: such a jump is misplaced (K3012).
  it "rejects a `return` inside a handler request body (K3012)" $
    typeErrorCodes [("test", "request tick() -> integer\nagent f() -> integer { let h = handler[integer, all] { request tick() -> integer { return 5 } }\nreturn 0 }")] `shouldContain` ["K3012"]

  it "rejects a `return` inside a `for` then clause (K3012)" $
    typeErrorCodes [("test", "agent f() -> integer { for (x in [1]) { next x } then (r) { return 0 } }")] `shouldContain` ["K3012"]

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

------------------------------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------------------------------

-- | The codes of every /type/ error a whole-program run emits (so @== []@ asserts a clean check).
typeErrorCodes :: [(Text, Text)] -> [Text]
typeErrorCodes sources =
  [typeErrorCode typeError | located <- toList (runProgramDiagnostics sources), CompilerErrorType typeError <- [located.value]]

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
