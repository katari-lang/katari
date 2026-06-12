module Katari.Data.SemanticTypeSpec (spec) where

import Data.Map qualified as Map
import Data.Sequence qualified as Seq
import Katari.Data.Id (GenericId (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SemanticType
import Katari.Data.SourceSpan (Located (..), Position (..), SourceSpan (..))
import Katari.Error
import Test.Hspec

spec :: Spec
spec = do
  describe "renderSemanticType" $ do
    it "renders unions of primitives" $
      renderSemanticType (SemanticTypeUnion [SemanticTypeInteger, SemanticTypeNull])
        `shouldBe` "integer | null"
    it "renders objects, eliding null from optional fields" $
      renderSemanticType
        ( SemanticTypeObject $
            Map.fromList
              [ ("x", FieldInformation {semanticType = SemanticTypeInteger, optional = False}),
                ("y", FieldInformation {semanticType = SemanticTypeUnion [SemanticTypeNull, SemanticTypeString], optional = True})
              ]
        )
        `shouldBe` "{x: integer, y?: string}"
    it "renders agent types with named parameters and a with clause" $
      renderSemanticType
        ( SemanticTypeAgent
            (SemanticTypeObject (Map.singleton "x" FieldInformation {semanticType = SemanticTypeInteger, optional = False}))
            SemanticTypeString
            (SemanticEffectRequest fooName mempty)
        )
        `shouldBe` "agent(x: integer) -> string with foo"
    it "parenthesises a union under of" $
      renderSemanticType (SemanticTypeAttribute (SemanticTypeUnion [SemanticTypeInteger, SemanticTypeString]) SemanticAttributePrivate)
        `shouldBe` "(integer | string) of private"
    it "renders data arguments positionally when single" $
      renderSemanticType (SemanticTypeData fooName (Map.singleton "T" (SemanticGenericArgumentType SemanticTypeInteger)))
        `shouldBe` "foo[integer]"
    it "renders array and generic placeholders" $
      renderSemanticType (SemanticTypeArray (SemanticTypeGeneric (GenericId 0)))
        `shouldBe` "array[T0]"

  describe "renderTypeError" $ do
    it "includes the code and the rendered types" $
      renderTypeError
        ( TypeErrorSubtype $
            SubtypeErrorInfo
              { expected = SemanticGenericArgumentType SemanticTypeString,
                actual = SemanticGenericArgumentType SemanticTypeInteger,
                reason = "Number layers are incompatible"
              }
        )
        `shouldBe` "K3001: Number layers are incompatible\n  expected: string\n  actual:   integer"
    it "renders an unknown-data error from its structured name" $
      renderTypeError (TypeErrorUnknownData $ UnknownDataErrorInfo {expected = fooName})
        `shouldBe` "K3003: Unknown data: test.foo"
    it "renders a generic-arity error from its structured fields" $
      renderTypeError (TypeErrorGenericArity $ GenericArityErrorInfo {name = fooName, expected = ["T"], actual = []})
        `shouldBe` "K3008: Generic arguments do not match the declaration of test.foo\n  expected: [T]\n  actual:   []"

  describe "severityOf" $
    it "classifies a type error as an error" $
      severityOf (CompilerErrorType (TypeErrorUnknownData UnknownDataErrorInfo {expected = fooName})) `shouldBe` SeverityError

  describe "finalizeDiagnostics" $
    it "drops exact duplicates and orders by source position" $ do
      let unknownData = CompilerErrorType (TypeErrorUnknownData UnknownDataErrorInfo {expected = fooName})
          spanAt line column = SourceSpan {filePath = "m.ktr", start = Position {line, column}, end = Position {line, column}}
          earlier = Located {value = unknownData, sourceSpan = spanAt 1 1}
          later = Located {value = unknownData, sourceSpan = spanAt 2 1}
      (\located -> located.sourceSpan) <$> finalizeDiagnostics (Seq.fromList [later, earlier, later])
        `shouldBe` [spanAt 1 1, spanAt 2 1]

fooName :: QualifiedName
fooName = QualifiedName {moduleName = ModuleName "test", name = "foo"}
