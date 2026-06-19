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

  it "rejects a generic primitive referenced without explicit application (K3015)" $
    typeErrorCodes [("test", "primitive agent identity[a](value: a) -> a\nagent run() -> integer { identity(value = 1) }")] `shouldContain` ["K3015"]

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
    (_, checkDiagnostics) = checkProgram typeEnvironment (valueSCCs modules) modules
