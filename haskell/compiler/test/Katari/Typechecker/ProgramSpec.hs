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
