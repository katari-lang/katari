-- | Tests for generic-argument inference at application sites ("Katari.Typechecker.Inference" plus its
-- wiring in "Katari.Typechecker.Check").
--
-- Two layers:
--
--   * End-to-end (the real contract): whole programs with the @primitive@ stdlib spliced in, so an
--     operator (which desugars to a generic @primitive.*@ call) and a user generic call exercise the
--     full propose / solve / dispose pipeline. Each case asserts the exact set of diagnostic codes,
--     including the should-fail cases (a bound violation is K3001, an un-inferrable parameter is K3016).
--
--   * White-box: 'collectConstraints' / 'solveConstraints' / 'deepGenerics' over hand-built types, so
--     the propose and solve steps are pinned down in isolation.
module Katari.Typechecker.InferenceSpec (spec) where

import Control.Monad.RWS.CPS (runRWS)
import Data.Foldable (toList)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.Id (GenericId (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.NormalizedType
import Katari.Data.SourceSpan (Located (..))
import Katari.Error (compilerErrorCode)
import Katari.Identifier (identifyModule, scanExports)
import Katari.Identifier.Monad (IdentifiedModule (..), ImportContext (..))
import Katari.Parser (parseModule)
import Katari.Stdlib qualified as Stdlib
import Katari.Typechecker (checkProgram)
import Katari.Typechecker.Check (arrayOf, integerType, namedObjectType, numberType, stringType)
import Katari.Typechecker.Environment (buildEnvironment)
import Katari.Typechecker.Inference
import Katari.Typechecker.Normalizer (Normalizer, SubtypingContext (..))
import Katari.Typechecker.ValueGraph (valueSCCs)
import Test.Hspec

spec :: Spec
spec = do
  describe "operator inference (end-to-end, desugared to generic primitive calls)" $ do
    it "integer + integer infers T = integer" $
      codesFor "agent f() -> integer { 1 + 1 }" `shouldBe` []
    it "integer + number widens T to number" $
      codesFor "agent f() -> number { 1 + 1.0 }" `shouldBe` []
    it "rejects the widened number result against an integer annotation (K3001)" $
      codesFor "agent f() -> integer { 1 + 1.0 }" `shouldContain` ["K3001"]
    it "divide always returns number (non-generic primitive)" $
      codesFor "agent f() -> number { 4 / 2 }" `shouldBe` []
    it "equality accepts any operand pair (unbounded T) and returns boolean" $
      codesFor "agent f() -> boolean { 1 == \"x\" }" `shouldBe` []
    it "less-than accepts numbers and returns boolean" $
      codesFor "agent f() -> boolean { 1 < 2 }" `shouldBe` []
    it "rejects a string operand to less-than via T's number bound (K3001)" $
      codesFor "agent f() -> boolean { \"a\" < \"b\" }" `shouldContain` ["K3001"]
    it "rejects a string operand to + via T's number bound (K3001)" $
      codesFor "agent f() -> number { 1 + \"x\" }" `shouldContain` ["K3001"]
    it "negate infers T = integer and preserves it" $
      codesFor "agent f() -> integer { -5 }" `shouldBe` []
    it "rejects negate on a string via T's number bound (K3001)" $
      codesFor "agent f() -> number { -\"x\" }" `shouldContain` ["K3001"]
    it "concat returns string (non-generic primitive)" $
      codesFor "agent f() -> string { \"a\" ++ \"b\" }" `shouldBe` []
    it "logical not returns boolean" $
      codesFor "agent f() -> boolean { !true }" `shouldBe` []

  describe "generic call inference (end-to-end)" $ do
    it "infers a type parameter from the value argument" $
      codesFor (identityDecl <> "agent run() -> integer { identity(value = 1) }") `shouldBe` []
    it "explicit application still works" $
      codesFor (identityDecl <> "agent run() -> integer { identity[integer](value = 1) }") `shouldBe` []
    it "rejects an inferred result against a mismatched annotation (K3001)" $
      codesFor (identityDecl <> "agent run() -> string { identity(value = 1) }") `shouldContain` ["K3001"]
    it "infers a parameter under the element of an array argument" $
      codesFor (firstDecl <> "agent run() -> integer { first(items = [1, 2, 3]) }") `shouldBe` []
    it "infers and checks a bounded parameter that is satisfied" $
      codesFor (boundedDecl <> "agent run() -> integer { num(value = 1) }") `shouldBe` []
    it "rejects a bounded parameter inferred to violate its bound (K3001)" $
      codesFor (boundedDecl <> "agent run() -> string { num(value = \"x\") }") `shouldContain` ["K3001"]

  describe "un-inferrable type arguments (should fail)" $ do
    it "reports a phantom parameter the arguments do not constrain (K3016)" $
      codesFor (phantomDecl <> "agent run() -> integer { phantom(value = 1) }") `shouldContain` ["K3016"]
    it "a bare (uncalled) generic reference is still rejected (K3015)" $
      codesFor (identityDecl <> "agent run() -> integer { let f = identity\n1 }") `shouldContain` ["K3015"]

  describe "handler inference (a handler is a generic value over R / E, applied at use)" $ do
    it "a bare handler (no application) is an unapplied generic value (K3015)" $
      codesFor (tickDecl <> "agent run() -> integer { let h = handler { request tick() -> integer { break 5 } }\n0 }") `shouldContain` ["K3015"]
    it "use applies the handler, inferring R / E from the continuation (break body)" $
      codesFor (tickDecl <> "agent run() -> integer { use handler { request tick() -> integer { break 5 } }\n0 }") `shouldBe` []
    it "use applies the handler, inferring R / E from the continuation (tail body)" $
      codesFor (tickDecl <> "agent run() -> integer { use handler { request tick() -> integer { 5 } }\n0 }") `shouldBe` []
    it "a request body may perform its own effect (joined into the handler effect)" $
      codesFor (tickDecl <> "request other() -> integer\nagent run() -> integer { use handler { request tick() -> integer { other() } }\n0 }") `shouldBe` []
    it "explicit handler[R, E] is a concrete handler value" $
      codesFor (tickDecl <> "agent run() -> integer { let h = handler[integer, all] { request tick() -> integer { next 5 } }\n0 }") `shouldBe` []
    it "a then clause transforms the result: its body need not match R" $
      codesFor (tickDecl <> "agent run() -> integer { use handler { request tick() -> integer { 5 } } then (r) { \"done\" }\n0 }") `shouldBe` []
    it "an explicit break bypasses then and the handler still typechecks" $
      codesFor "request a() -> integer\nrequest b() -> integer\nagent run() -> integer { use handler { request a() -> integer { break true } request b() -> integer { 5 } } then (r) { \"x\" }\n0 }" `shouldBe` []
    it "rejects a then binder whose annotation does not accept R (K3001)" $
      codesFor (tickDecl <> "agent run() -> integer { use handler { request tick() -> integer { 5 } } then (r : string) { r }\n0 }") `shouldContain` ["K3001"]
    it "infers the residual effect E from the continuation: the handled request is dropped" $
      -- The continuation performs foo (caught) and bar (residual), so E = {bar}; an agent declaring
      -- `with bar` is accepted.
      codesFor "request foo() -> integer\nrequest bar() -> integer\nagent f() -> integer with bar {\n  use handler { request foo() -> integer { 5 } }\n  let x = foo()\n  let y = bar()\n  x + y\n}" `shouldBe` []
    it "rejects an agent effect that excludes the inferred residual (K3001)" $
      codesFor "request foo() -> integer\nrequest bar() -> integer\nagent f() -> integer with foo {\n  use handler { request foo() -> integer { 5 } }\n  let x = foo()\n  let y = bar()\n  x + y\n}" `shouldContain` ["K3001"]

  describe "use-provider inference (continuation-driven)" $ do
    it "infers a provider's result type R from the continuation's return type" $
      -- `use foo` builds the continuation agent({value: int}) -> <enclosing return = string>, so foo's
      -- R is inferred to string from the continuation argument's return position.
      codesFor (providerDecl <> "agent run() -> string { let x : integer = use foo\n\"result\" }") `shouldBe` []
    it "rejects a use binder whose type the provider's continuation does not accept (K3001)" $
      codesFor (providerDecl <> "agent run() -> string { let x : string = use foo\n\"result\" }") `shouldContain` ["K3001"]

  describe "request handler generic inference (param-derived)" $ do
    it "infers the request's generic from a handler parameter annotation" $
      codesFor "request foo[a](x: a) -> a\nagent run() -> integer { let h = handler[integer, all] { request foo(x : integer) { next x } }\n0 }" `shouldBe` []
    it "still accepts an explicit request-handler signature" $
      codesFor "request foo[a](x: a) -> a\nagent run() -> integer { let h = handler[integer, all] { request foo[integer](x : integer) { next x } }\n0 }" `shouldBe` []
    it "rejects a next value that mismatches the inferred request generic (K3001)" $
      codesFor "request foo[a](x: a) -> a\nagent run() -> integer { let h = handler[integer, all] { request foo(x : integer) { next \"s\" } }\n0 }" `shouldContain` ["K3001"]
    it "reports a request generic the parameters cannot determine (K3016)" $
      codesFor "request mk[a]() -> a\nagent run() -> integer { let h = handler[integer, all] { request mk() { next 5 } }\n0 }" `shouldContain` ["K3016"]

  describe "effect-generic inference (a generic value quantified over an effect)" $ do
    it "infers a residual effect E from the argument's effect" $
      codesFor (runWithDecls <> "agent f() -> integer with tick { runWith(action = doTick) }") `shouldBe` []
    it "rejects the inferred effect against a too-narrow declared effect (K3001)" $
      codesFor (runWithDecls <> "agent f() -> integer with other { runWith(action = doTick) }") `shouldContain` ["K3001"]
    it "infers a pure residual from a pure argument" $
      codesFor "external agent pureAct() -> integer\nprimitive agent runWith[effect E](action: agent() -> integer with E) -> integer with E\nagent f() -> integer { runWith(action = pureAct) }" `shouldBe` []

  describe "constructor pattern inference (scrutinee-driven)" $ do
    it "binds a field at the scrutinee's instantiation (box[integer] binds v : integer)" $
      codesFor (boxDecl <> "agent f(b: box[integer]) -> integer { match (b) { case box(value => v) -> v } }") `shouldBe` []
    it "rejects using the inferred binder at a wrong type (K3001)" $
      codesFor (boxDecl <> "agent f(b: box[integer]) -> string { match (b) { case box(value => v) -> v } }") `shouldContain` ["K3001"]
    it "binds v : string for a box[string] scrutinee (rejects v + 1)" $
      codesFor (boxDecl <> "agent f(b: box[string]) -> integer { match (b) { case box(value => v) -> v + 1 } }") `shouldContain` ["K3001"]
    it "an explicit pattern signature still works" $
      codesFor (boxDecl <> "agent f(b: box[integer]) -> integer { match (b) { case box[integer](value => v) -> v } }") `shouldBe` []

  describe "collectConstraints (propose, white-box)" $ do
    it "records a lower bound for a bare metavariable in covariant position" $
      typeLowersOf metaA (runN (collectConstraints flexibleA integerType (typeVar metaA))) `shouldBe` [integerType]
    it "records a lower bound under an object field" $
      typeLowersOf metaA (runN (collectConstraints flexibleA (namedObjectType [("x", integerType)]) (namedObjectType [("x", typeVar metaA)]))) `shouldBe` [integerType]
    it "records a lower bound under an array element (covariant)" $
      typeLowersOf metaA (runN (collectConstraints flexibleA (arrayOf integerType) (arrayOf (typeVar metaA)))) `shouldBe` [integerType]
    it "collects from two argument occurrences of the same parameter" $
      typeLowersOf metaA (runN (collectConstraints flexibleA (namedObjectType [("l", integerType), ("r", numberType)]) (namedObjectType [("l", typeVar metaA), ("r", typeVar metaA)])))
        `shouldMatchList` [integerType, numberType]
    it "records nothing for a non-flexible, non-matching leaf" $
      Map.null (runN (collectConstraints flexibleA integerType stringType)).typeBounds `shouldBe` True

  describe "solveConstraints (solve, white-box)" $ do
    it "solves a single lower bound to itself" $
      solvedType metaA (runN (solveConstraints (registry [(metaA, "a", Nothing)]) (lowerType metaA integerType)))
        `shouldBe` Just integerType
    it "joins multiple lower bounds" $
      solvedType metaA (runN (solveConstraints (registry [(metaA, "a", Nothing)]) (lowerType metaA integerType <> lowerType metaA numberType)))
        `shouldBe` Just numberType
    it "reports a metavariable with no lower bound as un-inferrable" $
      (runN (solveConstraints (registry [(metaA, "a", Nothing)]) mempty)).uninferred `shouldBe` [metaA]
    it "solves a dependent metavariable after the one it mentions" $
      -- b's only lower bound is a; a's is integer, so both resolve to integer.
      solvedType metaB (runN (solveConstraints (registry [(metaA, "a", Nothing), (metaB, "b", Nothing)]) (lowerType metaA integerType <> lowerType metaB (typeVar metaA))))
        `shouldBe` Just integerType

  describe "deepGenerics" $ do
    it "finds a metavariable nested inside an array element" $
      Set.member metaA (deepGenerics (arrayOf (typeVar metaA))) `shouldBe` True
    it "finds a metavariable nested inside an object field" $
      Set.member metaA (deepGenerics (namedObjectType [("x", typeVar metaA)])) `shouldBe` True
    it "reports no generics for a closed type" $
      deepGenerics integerType `shouldBe` Set.empty

------------------------------------------------------------------------------------------------
-- End-to-end driver (stdlib spliced)
------------------------------------------------------------------------------------------------

-- | Every diagnostic code (all phases) of a single-module program checked with the @primitive@ stdlib
-- spliced in and default-imported, so operators resolve to real generic primitives.
codesFor :: Text -> [Text]
codesFor source =
  [compilerErrorCode located.value | located <- toList (parseDiagnostics <> identifyDiagnostics <> envDiagnostics <> checkDiagnostics)]
  where
    allSources = Map.toList Stdlib.stdlibSources <> [(ModuleName "test", source)]
    parsedResults = [(moduleName, parseModule moduleName text) | (moduleName, text) <- allSources]
    parsedModules = [(moduleName, fst result) | (moduleName, result) <- parsedResults]
    -- Parse diagnostics are folded in too, so a malformed test program surfaces (e.g. K1001) rather
    -- than silently passing as @[]@ when its body never type-checks.
    parseDiagnostics = foldMap (snd . snd) parsedResults
    importContext =
      ImportContext
        { moduleInterfaces = Map.fromList [(moduleName, scanExports moduleName parsed) | (moduleName, parsed) <- parsedModules],
          defaultImports = Stdlib.defaultImports
        }
    identifiedResults = [(moduleName, identifyModule importContext moduleName parsed) | (moduleName, parsed) <- parsedModules]
    modules = Map.fromList [(moduleName, (fst result).identifiedAst) | (moduleName, result) <- identifiedResults]
    identifyDiagnostics = foldMap (snd . snd) identifiedResults
    (typeEnvironment, envDiagnostics) = buildEnvironment modules
    (_, _, checkDiagnostics) = checkProgram typeEnvironment (valueSCCs modules) modules

identityDecl :: Text
identityDecl = "primitive agent identity[a](value: a) -> a\n"

boxDecl :: Text
boxDecl = "data box[a](value: a)\n"

-- | A value generic over an /effect/: @runWith[effect E]@ takes a thunk performing @E@ and runs it,
-- so @E@ is inferred from the argument's effect.
runWithDecls :: Text
runWithDecls =
  "request tick() -> integer\nrequest other() -> integer\nexternal agent doTick() -> integer with tick\n"
    <> "primitive agent runWith[effect E](action: agent() -> integer with E) -> integer with E\n"

firstDecl :: Text
firstDecl = "primitive agent first[a](items: array[a]) -> a\n"

boundedDecl :: Text
boundedDecl = "primitive agent num[a extends number](value: a) -> a\n"

phantomDecl :: Text
phantomDecl = "primitive agent phantom[a, b](value: a) -> a\n"

tickDecl :: Text
tickDecl = "request tick() -> integer\n"

-- | A @use@ provider generic in its continuation's result @R@ — the shape the continuation-driven
-- inference targets.
providerDecl :: Text
providerDecl = "external agent foo[R](continuation: agent(value: integer) -> R) -> R\n"

------------------------------------------------------------------------------------------------
-- White-box helpers
------------------------------------------------------------------------------------------------

-- | A standalone Normalizer run over an empty nominal environment — enough for the inference functions,
-- which only consult the environment for data-argument variance (none of these cases use data types).
runN :: Normalizer a -> a
runN action = let (result, _, _) = runRWS action emptyContext () in result
  where
    emptyContext =
      SubtypingContext
        { dataEnvironment = mempty,
          requestEnvironment = mempty,
          genericsInScope = mempty,
          world = bottomAttribute
        }

metaA :: GenericId
metaA = GenericId (ModuleName "<infer>") 0

metaB :: GenericId
metaB = GenericId (ModuleName "<infer>") 1

flexibleA :: Set.Set GenericId
flexibleA = Set.singleton metaA

-- | A bare type metavariable, the form 'collectConstraints' treats as an inference leaf.
typeVar :: GenericId -> NormalizedType
typeVar metavar = case metavarKinded GenericKindType metavar of
  NormalizedKindedTypeType normalizedType -> normalizedType
  _ -> bottomType

-- | A registry of type metavariables from @(id, name, bound)@ triples.
registry :: [(GenericId, Text, Maybe NormalizedKindedType)] -> Registry
registry entries = Map.fromList [(metavar, Metavar {name = name, kind = GenericKindType, bound = bound}) | (metavar, name, bound) <- entries]

typeLowersOf :: GenericId -> Constraints -> [NormalizedType]
typeLowersOf metavar constraints = maybe [] (.lowers) (Map.lookup metavar constraints.typeBounds)

solvedType :: GenericId -> SolveResult -> Maybe NormalizedType
solvedType metavar solveResult = case Map.lookup metavar solveResult.substitution of
  Just (NormalizedKindedTypeType normalizedType) -> Just normalizedType
  _ -> Nothing
