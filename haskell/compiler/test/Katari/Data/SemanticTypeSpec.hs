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
                reason = "The actual type can be a number, which the expected type does not admit"
              }
        )
        `shouldBe` "K3001: The actual type can be a number, which the expected type does not admit\n  expected: string\n  actual:   integer"
    -- Two packages' same-named constructors are unreadable when both spell `auth_error`, so the pair of
    -- lines is rendered under one style that qualifies exactly the colliding name and nothing else.
    it "qualifies a name two modules claim, and leaves every other name bare" $
      renderTypeError
        ( TypeErrorSubtype $
            SubtypeErrorInfo
              { expected =
                  SemanticGenericArgumentType
                    ( SemanticTypeUnion
                        [ SemanticTypeData slackAuthError mempty,
                          SemanticTypeData httpAuthError mempty,
                          SemanticTypeData httpBadTimezone mempty
                        ]
                    ),
                actual = SemanticGenericArgumentType (SemanticTypeData httpBadTimezone mempty),
                reason = "reason"
              }
        )
        `shouldBe` "K3001: reason\n  expected: slack.auth_error | http.auth_error | bad_timezone\n  actual:   bad_timezone"
    it "renders a generic-arity error from its structured fields" $
      renderTypeError (TypeErrorGenericArity $ GenericArityErrorInfo {name = fooName, expected = ["T"], actual = []})
        `shouldBe` "K3008: Generic arguments do not match the declaration of test.foo\n  expected: [T]\n  actual:   []"

  describe "severityOf" $ do
    it "classifies a type error as an error" $
      severityOf (CompilerErrorType (TypeErrorGenericArity GenericArityErrorInfo {name = fooName, expected = ["T"], actual = []})) `shouldBe` SeverityError

    -- The one type diagnostic that does not fail the build. Asserted here as well as end-to-end, because
    -- the whole design of K3028 rests on it: a discard is well-typed, and rejecting one would leave no way
    -- to call an outcome-answering agent for its effect alone.
    it "classifies a discarded value as a warning" $
      severityOf (CompilerErrorType (TypeErrorDiscardedValue DiscardedValueErrorInfo {discarded = SemanticTypeString})) `shouldBe` SeverityWarning

  -- The predicate behind K3028. Its cases are not "is this null" but "could a value of this type tell the
  -- reader what happened", which is why the three container families and the callable answer False-to-the-
  -- warning while a bare data type does not.
  describe "answersNothing" $ do
    it "holds for null and for never" $ do
      answersNothing SemanticTypeNull `shouldBe` True
      answersNothing SemanticTypeNever `shouldBe` True

    it "holds for a container of nothings (a `for` / `parallel` run for effect)" $ do
      answersNothing (SemanticTypeArray SemanticTypeNull) `shouldBe` True
      answersNothing (SemanticTypeTuple [SemanticTypeNull, SemanticTypeNull]) `shouldBe` True
      answersNothing (SemanticTypeRecord SemanticTypeNull) `shouldBe` True
      answersNothing (SemanticTypeObject mempty) `shouldBe` True

    it "fails for a container of answers — the array carries every one of them" $
      answersNothing (SemanticTypeArray (SemanticTypeData fooName mempty)) `shouldBe` False

    it "holds for a callable: a capability says what may happen next, never what did" $
      answersNothing (SemanticTypeAgent SemanticTypeNull SemanticTypeNull SemanticEffectPure) `shouldBe` True

    it "fails for a data type, even a nullary one — the author chose it over null" $
      answersNothing (SemanticTypeData fooName mempty) `shouldBe` False

    it "looks through an information-flow label, which says who may read, not whether there is anything to" $ do
      answersNothing (SemanticTypeAttribute SemanticTypeNull SemanticAttributePrivate) `shouldBe` True
      answersNothing (SemanticTypeAttribute SemanticTypeString SemanticAttributePrivate) `shouldBe` False

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

-- Two packages' @auth_error@ plus one name only one of them declares: the exact shape a K3001 expected
-- row had when it read @auth_error | auth_error | bad_timezone@.
slackAuthError :: QualifiedName
slackAuthError = QualifiedName {moduleName = ModuleName "slack", name = "auth_error"}

httpAuthError :: QualifiedName
httpAuthError = QualifiedName {moduleName = ModuleName "prelude.http", name = "auth_error"}

httpBadTimezone :: QualifiedName
httpBadTimezone = QualifiedName {moduleName = ModuleName "prelude.time", name = "bad_timezone"}
