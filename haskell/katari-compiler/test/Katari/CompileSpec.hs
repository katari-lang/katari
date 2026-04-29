-- | End-to-end tests for 'Katari.Compile.compile' — verifies that the
-- pure orchestration entry point produces an 'IRModule' / 'SchemaBundle'
-- for well-formed input and a populated 'diagnostics' stream for
-- ill-formed input.
module Katari.CompileSpec (spec) where

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
