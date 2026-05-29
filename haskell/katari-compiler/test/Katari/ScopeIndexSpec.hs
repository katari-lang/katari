module Katari.ScopeIndexSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Compile (CompileInput (..), CompileResult (..), SourceEntry (..))
import Katari.Query (QuerySnapshot (..))
import Katari.SourceSpan (Position (..))
import Katari.TestSupport (compileSync)
import Katari.Typechecker.Identifier (SymbolEntry (..))
import Katari.Typechecker.ScopeIndex (scopeAt)
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

identify :: Text -> IO QuerySnapshot
identify src = do
  let result =
        compileSync
          CompileInput
            { sources =
                Map.singleton
                  "main"
                  SourceEntry {filePath = "<test>", sourceText = src},
              cache = Map.empty
            }
  pure result.querySnapshot

namesVisibleAt :: QuerySnapshot -> Position -> [Text]
namesVisibleAt snap pos =
  let frames = scopeAt snap.scopeIndex "<test>" pos
      combined = Map.unions frames
   in Set.toAscList (Set.fromList (Map.keys combined))

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Katari.Typechecker.ScopeIndex" $ do
  it "sees agent parameters inside the body" $ do
    -- agent foo(name: string) -> string {
    --   name   <- line 2
    -- }
    r <- identify "agent foo(name = name: string) -> string {\n  name\n}\n"
    let visible = namesVisibleAt r Position {line = 2, column = 3}
    visible `shouldSatisfy` ("name" `elem`)

  it "sees a let-binding from the same block" $ do
    -- agent foo() -> integer {
    --   let x = 1
    --   x       <- line 3
    -- }
    r <-
      identify $
        Text.unlines
          [ "agent foo() -> integer {",
            "  let x = 1",
            "  x",
            "}"
          ]
    let visible = namesVisibleAt r Position {line = 3, column = 3}
    visible `shouldSatisfy` ("x" `elem`)

  it "innermost frame shadows outer" $ do
    -- A let binding in an inner block should shadow an outer same-named
    -- binding when both spans contain the cursor.
    r <-
      identify $
        Text.unlines
          [ "agent foo() -> integer {",
            "  let x = 1",
            "  let y = {",
            "    let x = 2",
            "    x", -- ← line 5
            "  }",
            "  y",
            "}"
          ]
    let frames = scopeAt r.scopeIndex "<test>" (Position {line = 5, column = 5})
    -- innermost is the inner block, which should bind `x`. Whichever
    -- VariableId is in the innermost frame should differ from the one
    -- in the outer frame.
    case frames of
      (inner : outer : _) -> do
        let innerX = Map.lookup "x" inner
            outerX = Map.lookup "x" outer
        innerX `shouldNotBe` Nothing
        outerX `shouldNotBe` Nothing
        ((.variableSymbol) <$> innerX) `shouldNotBe` ((.variableSymbol) <$> outerX)
      _ ->
        expectationFailure $ "expected at least 2 nested frames, got " <> show (length frames)

  it "does not see for-loop var outside the loop" $ do
    -- agent foo() -> integer {
    --   for (let x in [1, 2, 3]) { 0 }
    --   x   <- line 3, must NOT be visible
    -- }
    r <-
      identify $
        Text.unlines
          [ "agent foo() -> integer {",
            "  for (let x in [1, 2, 3]) { 0 }",
            "  0",
            "}"
          ]
    let visible = namesVisibleAt r Position {line = 3, column = 3}
    visible `shouldNotSatisfy` ("x" `elem`)
