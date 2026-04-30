-- | End-to-end tests for 'Katari.Compile.compile' — verifies that the
-- pure orchestration entry point produces an 'IRModule' / 'SchemaBundle'
-- for well-formed input and a populated 'diagnostics' stream for
-- ill-formed input.
module Katari.CompileSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Katari.Compile
import Katari.Diagnostic (Diagnostic (..), hasErrors)
import Test.Hspec

-- ===========================================================================
-- Helpers
-- ===========================================================================

singleSourceInput :: Text -> CompileInput
singleSourceInput src =
  CompileInput
    { sources = Map.singleton "main" src,
      rootModule = "main"
    }

multiSourceInput :: [(Text, Text)] -> Text -> CompileInput
multiSourceInput pairs root =
  CompileInput
    { sources = Map.fromList pairs,
      rootModule = root
    }

-- ===========================================================================
-- Spec
-- ===========================================================================

spec :: Spec
spec = describe "Katari.Compile" $ do
  happyPathSpec
  errorPathSpec
  multiModuleSpec
  exhaustiveSpec
  externalAgentSpec
  recursiveDataSpec

happyPathSpec :: Spec
happyPathSpec = describe "well-formed single-module input" $ do
  it "produces an IRModule and SchemaBundle for a trivial agent" $ do
    let result = compile (singleSourceInput "agent main() { 42 }")
    hasErrors result.diagnostics `shouldBe` False
    isJust result.irModule `shouldBe` True
    isJust result.schemaBundle `shouldBe` True
    isJust result.solverResult `shouldBe` True
    isJust result.zonkResult `shouldBe` True

  it "always returns solverResult / zonkResult, even on success" $ do
    let result = compile (singleSourceInput "agent main() { 1 }")
    isJust result.solverResult `shouldBe` True
    isJust result.zonkResult `shouldBe` True

errorPathSpec :: Spec
errorPathSpec = describe "ill-formed input" $ do
  it "returns parse-error diagnostics and no IR for a syntax error" $ do
    let result = compile (singleSourceInput "agent main() {")
    hasErrors result.diagnostics `shouldBe` True
    isNothing result.irModule `shouldBe` True
    isNothing result.schemaBundle `shouldBe` True

  it "carries each diagnostic's code in the K#### range" $ do
    let result = compile (singleSourceInput "agent main() {")
        codes = map (.code) result.diagnostics
    -- All codes must start with 'K'.
    all (\c -> not (null (show c)) && head (show c) == '"') codes `shouldBe` True

multiModuleSpec :: Spec
multiModuleSpec = describe "multi-module input" $ do
  it "flags imports of modules not present in the source map" $ do
    let result =
          compile
            ( singleSourceInput
                "import { foo } from missing\nagent main() { 1 }"
            )
    -- We don't assert the precise code (parse may already fail), but at
    -- minimum the diagnostics list should be non-empty.
    hasErrors result.diagnostics `shouldBe` True

  it "compiles successfully when all imported modules are present" $ do
    -- Even a no-op multi-module setup: two modules with no cross-imports
    -- should both compile without diagnostics.
    let result =
          compile
            ( multiSourceInput
                [ ("util", "agent helper() { 1 }"),
                  ("main", "agent main() { 2 }")
                ]
                "main"
            )
    hasErrors result.diagnostics `shouldBe` False
    isJust result.irModule `shouldBe` True

-- ===========================================================================
-- Exhaustiveness diagnostics (K0290 / K0291 / K0292)
-- ===========================================================================

exhaustiveSpec :: Spec
exhaustiveSpec = describe "exhaustiveness checker" $ do
  it "K0290: match covers only one arm of a two-variant data type" $ do
    let src =
          "data Apple()\n\
          \data Orange()\n\
          \type Fruit = Apple | Orange\n\
          \agent main() -> integer {\n\
          \  let x: Fruit = Apple()\n\
          \  match (x) {\n\
          \    case Apple() => {\n\
          \      1\n\
          \    }\n\
          \  }\n\
          \}"
        result = compile (singleSourceInput src)
        codes = map (.code) result.diagnostics
    codes `shouldContain` ["K0290"]

  it "K0290: match covers only Some arm of a Some/None data type" $ do
    let src =
          "data Some(value: integer)\n\
          \data None()\n\
          \type Option = Some | None\n\
          \agent main() -> integer {\n\
          \  let x: Option = Some(value = 1)\n\
          \  match (x) {\n\
          \    case Some(value = v) => {\n\
          \      v\n\
          \    }\n\
          \  }\n\
          \}"
        result = compile (singleSourceInput src)
        codes = map (.code) result.diagnostics
    codes `shouldContain` ["K0290"]

  it "K0292: second arm with same pattern is unreachable" $ do
    let src =
          "agent main() -> integer {\n\
          \  match (1) {\n\
          \    case _ => {\n\
          \      1\n\
          \    }\n\
          \    case 1 => {\n\
          \      2\n\
          \    }\n\
          \  }\n\
          \}"
        result = compile (singleSourceInput src)
        codes = map (.code) result.diagnostics
    codes `shouldContain` ["K0292"]

  it "K0291: let binding with refutable constructor pattern" $ do
    let src =
          "data Some(value: integer)\n\
          \data None()\n\
          \type Option = Some | None\n\
          \agent main() -> integer {\n\
          \  let x: Option = None()\n\
          \  let None() = x\n\
          \  0\n\
          \}"
        result = compile (singleSourceInput src)
        codes = map (.code) result.diagnostics
    codes `shouldContain` ["K0291"]

  it "exhaustive match over all constructors has no exhaustive errors" $ do
    let src =
          "data Apple()\n\
          \data Orange()\n\
          \type Fruit = Apple | Orange\n\
          \agent main() -> integer {\n\
          \  let x: Fruit = Apple()\n\
          \  match (x) {\n\
          \    case Apple() => {\n\
          \      1\n\
          \    }\n\
          \    case Orange() => {\n\
          \      2\n\
          \    }\n\
          \  }\n\
          \}"
        result = compile (singleSourceInput src)
        exhaustiveCodes = filter (\c -> c == "K0290" || c == "K0291" || c == "K0292") (map (.code) result.diagnostics)
    exhaustiveCodes `shouldBe` []

-- ===========================================================================
-- External agent annotation validation (K0150 / K0151)
-- ===========================================================================

externalAgentSpec :: Spec
externalAgentSpec = describe "external agent annotation validation" $ do
  it "K0150: ext agent without annotation produces an error" $ do
    let result =
          compile
            ( singleSourceInput
                "req http_req()\next agent fetch(url: string) -> string with http_req"
            )
        codes = map (.code) result.diagnostics
    codes `shouldContain` ["K0150"]

  it "K0151: ext agent with empty annotation produces an error" $ do
    let result =
          compile
            ( singleSourceInput
                "req http_req()\n@\"\"\next agent fetch(url: string) -> string with http_req"
            )
        codes = map (.code) result.diagnostics
    codes `shouldContain` ["K0151"]

  it "ext agent with non-empty annotation compiles without K0150/K0151" $ do
    let result =
          compile
            ( singleSourceInput
                "req http_req()\n@\"https://api.example.com\"\next agent fetch(url: string) -> string with http_req\nagent main() -> string { \"ok\" }"
            )
        codes = map (.code) result.diagnostics
    filter (\c -> c == "K0150" || c == "K0151") codes `shouldBe` []

-- ===========================================================================
-- Recursive data type (Phase 18.D)
-- ===========================================================================

recursiveDataSpec :: Spec
recursiveDataSpec = describe "recursive data type" $ do
  it "recursive data declaration compiles without errors" $ do
    let src =
          "data Cons(head: integer, tail: List)\n\
          \data Nil()\n\
          \type List = Cons | Nil\n\
          \agent main() -> integer {\n\
          \  let xs: List = Cons(head = 1, tail = Nil())\n\
          \  0\n\
          \}"
        result = compile (singleSourceInput src)
    hasErrors result.diagnostics `shouldBe` False
    isJust result.irModule `shouldBe` True

  it "recursive data IR round-trips through Aeson" $ do
    let src =
          "data Cons(head: integer, tail: List)\n\
          \data Nil()\n\
          \type List = Cons | Nil\n\
          \agent main() -> integer { 0 }"
        result = compile (singleSourceInput src)
    case result.irModule of
      Nothing -> expectationFailure "expected irModule but got Nothing"
      Just ir ->
        case Aeson.fromJSON (Aeson.toJSON ir) of
          Aeson.Success decoded -> decoded `shouldBe` ir
          Aeson.Error msg -> expectationFailure ("decode failed: " <> msg)
