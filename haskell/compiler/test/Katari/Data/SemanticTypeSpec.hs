module Katari.Data.SemanticTypeSpec (spec) where

import Data.Map qualified as Map
import Katari.Data.Id (GenericId (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SemanticType
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
      renderSemanticType (SemanticTypeArray (SemanticTypeGeneric (GenericId (ModuleName "test") 0)))
        `shouldBe` "array[T0]"
    it "renders a string literal singleton quoted, exactly as written" $
      renderSemanticType (SemanticTypeStringLiteral "https://x")
        `shouldBe` "\"https://x\""
    it "renders a string literal singleton with source escapes (round-trips through the lexer)" $
      renderSemanticType (SemanticTypeStringLiteral "a\n\"b\\")
        `shouldBe` "\"a\\n\\\"b\\\\\""

  -- The escalation report renders nested names 'QualifiedByLastSegment' so two modules' same-named
  -- requests / data types stay distinguishable, and deduplicates the resulting qualified union. The
  -- 'BareName' surfaces (error messages, hover, docs) must stay byte-for-byte unchanged.
  describe "renderSemanticType/Effect (NameStyle)" $ do
    it "qualifies a union of two modules' same-named requests by last segment" $
      renderSemanticEffectWith
        QualifiedByLastSegment
        (SemanticEffectUnion [SemanticEffectRequest gmailCredential mempty, SemanticEffectRequest calendarCredential mempty])
        `shouldBe` "gmail.credential | google_calendar.credential"
    it "leaves the same union bare (and hence conflated) under BareName — error messages are unchanged" $
      renderSemanticEffect
        (SemanticEffectUnion [SemanticEffectRequest gmailCredential mempty, SemanticEffectRequest calendarCredential mempty])
        `shouldBe` "credential | credential"
    it "deduplicates a genuinely repeated request in a qualified union" $
      renderSemanticEffectWith
        QualifiedByLastSegment
        (SemanticEffectUnion [SemanticEffectRequest gmailCredential mempty, SemanticEffectRequest gmailCredential mempty])
        `shouldBe` "gmail.credential"
    it "does NOT deduplicate a repeated leaf under BareName — the bare surface stays byte-stable" $
      renderSemanticEffect
        (SemanticEffectUnion [SemanticEffectRequest gmailCredential mempty, SemanticEffectRequest gmailCredential mempty])
        `shouldBe` "credential | credential"
    it "qualifies and deduplicates a data-type union (a throw payload) too" $
      renderSemanticTypeWith
        QualifiedByLastSegment
        (SemanticTypeUnion [SemanticTypeData gmailApiError mempty, SemanticTypeData calendarApiError mempty, SemanticTypeData gmailApiError mempty])
        `shouldBe` "gmail.api_error | google_calendar.api_error"
    it "carries the qualifier into a request's nested generic effect argument (the approve_async[E] shape)" $
      renderSemanticEffectLeavesWith
        QualifiedByLastSegment
        ( SemanticEffectRequest
            holdApprove
            (Map.singleton "E" (SemanticGenericArgumentEffect (SemanticEffectUnion [SemanticEffectRequest gmailCredential mempty, SemanticEffectRequest calendarCredential mempty])))
        )
        `shouldBe` ["hold.approve_async[gmail.credential | google_calendar.credential]"]

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
    it "renders a generic-arity error from its structured fields" $
      renderTypeError (TypeErrorGenericArity $ GenericArityErrorInfo {name = fooName, expected = ["T"], actual = []})
        `shouldBe` "K3008: Generic arguments do not match the declaration of test.foo\n  expected: [T]\n  actual:   []"

  describe "severityOf" $
    it "classifies a type error as an error" $
      severityOf (CompilerErrorType (TypeErrorGenericArity GenericArityErrorInfo {name = fooName, expected = ["T"], actual = []})) `shouldBe` SeverityError

fooName :: QualifiedName
fooName = QualifiedName {moduleName = ModuleName "test", name = "foo"}

-- Same short name (@credential@ / @api_error@) under different modules — the case the escalation report
-- must keep distinguishable; the module names are multi-segment so the last-segment qualifier is exercised.
gmailCredential :: QualifiedName
gmailCredential = QualifiedName {moduleName = ModuleName "acme.gmail", name = "credential"}

calendarCredential :: QualifiedName
calendarCredential = QualifiedName {moduleName = ModuleName "acme.google_calendar", name = "credential"}

gmailApiError :: QualifiedName
gmailApiError = QualifiedName {moduleName = ModuleName "acme.gmail", name = "api_error"}

calendarApiError :: QualifiedName
calendarApiError = QualifiedName {moduleName = ModuleName "acme.google_calendar", name = "api_error"}

holdApprove :: QualifiedName
holdApprove = QualifiedName {moduleName = ModuleName "acme.hold", name = "approve_async"}
