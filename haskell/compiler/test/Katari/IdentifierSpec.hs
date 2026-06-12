module Katari.IdentifierSpec (spec) where

import Data.Sequence qualified as Seq
import Katari.Data.Id (GenericId (..), LocalVariableId (..), VariableResolution (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SourceSpan (Located (..), Position (..), SourceSpan (..))
import Katari.Diagnostics (reportAt)
import Katari.Error (CompilerError (..), TypeError (..), UnknownDataErrorInfo (..))
import Katari.Identifier
import Test.Hspec

spec :: Spec
spec = do
  describe "fresh-id supply" $
    it "hands out increasing generic ids" $
      fst (runIdentifier environment (sequence [freshGenericId, freshGenericId, freshGenericId]))
        `shouldBe` [GenericId 0, GenericId 1, GenericId 2]

  describe "scope" $ do
    it "finds a binding added with withVariable" $
      fst (runIdentifier environment (withVariable "x" boundX (lookupVariable "x")))
        `shouldBe` Just boundX
    it "restores the scope on exit" $
      fst (runIdentifier environment (withVariable "x" boundX (pure ()) >> lookupVariable "x"))
        `shouldBe` Nothing

  describe "diagnostics" $
    it "accumulates reported errors" $
      snd (runIdentifier environment (reportAt someSpan someError))
        `shouldBe` Seq.singleton Located {value = someError, sourceSpan = someSpan}

environment :: IdentifierEnvironment
environment = IdentifierEnvironment {moduleName = ModuleName "test", scope = emptyScope}

boundX :: VariableResolution
boundX = VariableResolutionLocalVariable (LocalVariableId 7)

someSpan :: SourceSpan
someSpan = SourceSpan {filePath = "m.ktr", start = position, end = position}
  where
    position = Position {line = 1, column = 1}

someError :: CompilerError
someError = CompilerErrorType (TypeErrorUnknownData UnknownDataErrorInfo {expected = QualifiedName {moduleName = ModuleName "test", name = "foo"}})
