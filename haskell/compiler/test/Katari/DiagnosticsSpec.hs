module Katari.DiagnosticsSpec (spec) where

import Data.Sequence qualified as Seq
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SourceSpan (Located (..), Position (..), SourceSpan (..))
import Katari.Diagnostics (finalizeDiagnostics)
import Katari.Error (CompilerError (..), GenericArityErrorInfo (..), TypeError (..))
import Test.Hspec

spec :: Spec
spec =
  describe "finalizeDiagnostics" $
    it "drops exact duplicates and orders by source position" $ do
      let sampleError = CompilerErrorType (TypeErrorGenericArity GenericArityErrorInfo {name = fooName, expected = [], actual = []})
          spanAt line column = SourceSpan {filePath = "m.ktr", start = Position {line, column}, end = Position {line, column}}
          earlier = Located {value = sampleError, sourceSpan = spanAt 1 1}
          later = Located {value = sampleError, sourceSpan = spanAt 2 1}
      (\located -> located.sourceSpan) <$> finalizeDiagnostics (Seq.fromList [later, earlier, later])
        `shouldBe` [spanAt 1 1, spanAt 2 1]

fooName :: QualifiedName
fooName = QualifiedName {moduleName = ModuleName "test", name = "foo"}
