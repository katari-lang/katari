module Katari.DiagnosticsSpec (spec) where

import Data.Map qualified as Map
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Compile (CompileInput (..), CompileResult (..), compile)
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SemanticType (SemanticType (..))
import Katari.Data.SourceSpan (Located (..), Position (..), SourceSpan (..))
import Katari.Diagnostics (finalizeDiagnostics, hasErrors, partitionByOwnership, renderDiagnostics)
import Katari.Error (CompilerError (..), DiscardedValueErrorInfo (..), ExpectedShapeErrorInfo (..), GenericArityErrorInfo (..), IdentifierError (..), TypeError (..), UndefinedMemberErrorInfo (..), compilerErrorCode)
import Test.Hspec

spec :: Spec
spec = do
  describe "finalizeDiagnostics" $
    it "drops exact duplicates and orders by source position" $ do
      let sampleError = CompilerErrorType (TypeErrorGenericArity GenericArityErrorInfo {name = fooName, expected = [], actual = []})
          earlier = Located {value = sampleError, sourceSpan = spanAt "m.ktr" 1 1}
          later = Located {value = sampleError, sourceSpan = spanAt "m.ktr" 2 1}
      (\located -> located.sourceSpan) <$> finalizeDiagnostics (Seq.fromList [later, earlier, later])
        `shouldBe` [spanAt "m.ktr" 1 1, spanAt "m.ktr" 2 1]

  -- A misspelled member types as `never`, so the shape demand at the call fails too — and its span is
  -- EARLIER, so the report used to open with a "type never" mismatch and bury the K2002 that caused it.
  describe "finalizeDiagnostics (unresolved-name shadows)" $ do
    it "drops a `type never` shape error in a file that reports an unresolved name" $ do
      let diagnostics =
            Seq.fromList
              [ Located {value = shadowError, sourceSpan = spanAt "m.ktr" 2 3},
                Located {value = unresolvedError, sourceSpan = spanAt "m.ktr" 2 10}
              ]
      compilerErrorCode . (.value) <$> finalizeDiagnostics diagnostics `shouldBe` ["K2002"]

    it "keeps the same shape error in a file that resolves every name" $ do
      let diagnostics =
            Seq.fromList
              [ Located {value = shadowError, sourceSpan = spanAt "m.ktr" 2 3},
                Located {value = unresolvedError, sourceSpan = spanAt "other.ktr" 2 10}
              ]
      compilerErrorCode . (.value) <$> finalizeDiagnostics diagnostics `shouldBe` ["K3014", "K2002"]

    -- Suppression is presentation only: the shadow is still an error for gating purposes, so nothing
    -- lowers that would not have lowered before.
    it "does not make a shadowed program compile" $
      hasErrors (Seq.fromList [Located {value = shadowError, sourceSpan = spanAt "m.ktr" 1 1}]) `shouldBe` True

    it "reports only the root cause for a misspelled stdlib member (end to end)" $
      compiledMessages "agent main() -> string {\n  string.jion(parts = [\"a\"], separator = \",\")\n}"
        `shouldBe` ["test:2:10 K2002: Module prelude.string has no exported member `jion`; did you mean `join`?"]

  -- A warning inside a dependency is noise the reader cannot act on: they did not write that package.
  -- An error from the same file is not, because it stops the build and they need the location.
  describe "partitionByOwnership" $ do
    let owned = Set.singleton "app"
        ownWarning = Located {value = discardedWarning, sourceSpan = spanAt "app" 3 1}
        foreignWarning = Located {value = discardedWarning, sourceSpan = spanAt "memory" 144 3}
        foreignError = Located {value = shadowError, sourceSpan = spanAt "memory" 12 1}

    it "keeps a warning about an owned file" $
      partitionByOwnership owned [ownWarning] `shouldBe` ([ownWarning], [])

    it "withholds a warning about a file the reader does not own" $
      partitionByOwnership owned [foreignWarning] `shouldBe` ([], [foreignWarning])

    it "never withholds an error, wherever it comes from" $
      partitionByOwnership owned [foreignError] `shouldBe` ([foreignError], [])

    it "shows everything when the reader owns every file" $
      partitionByOwnership (Set.fromList ["app", "memory"]) [ownWarning, foreignWarning]
        `shouldBe` ([ownWarning, foreignWarning], [])

    it "keeps the surviving diagnostics in their finalized order" $
      fst (partitionByOwnership owned [ownWarning, foreignWarning, foreignError])
        `shouldBe` [ownWarning, foreignError]

fooName :: QualifiedName
fooName = QualifiedName {moduleName = ModuleName "test", name = "foo"}

spanAt :: FilePath -> Int -> Int -> SourceSpan
spanAt filePath line column = SourceSpan {filePath = filePath, start = Position {line, column}, end = Position {line, column}}

-- | The shape demand a `never`-typed reference fails: what an unresolved name leaves behind.
shadowError :: CompilerError
shadowError = CompilerErrorType (TypeErrorExpectedShape ExpectedShapeErrorInfo {expected = "a callable agent", actual = SemanticTypeNever})

-- | A warning-severity diagnostic (K3028): the one severity the ownership split acts on.
discardedWarning :: CompilerError
discardedWarning = CompilerErrorType (TypeErrorDiscardedValue DiscardedValueErrorInfo {discarded = SemanticTypeNever})

unresolvedError :: CompilerError
unresolvedError = CompilerErrorIdentifier (IdentifierErrorUndefinedMember UndefinedMemberErrorInfo {moduleName = ModuleName "prelude.string", name = "jion", suggestions = ["join"]})

compiledMessages :: Text -> [Text]
compiledMessages source =
  Text.lines (renderDiagnostics (compile CompileInput {sources = Map.singleton (ModuleName "test") source}).diagnostics)
