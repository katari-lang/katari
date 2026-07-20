module Katari.SchemaSpec (spec) where

import Data.Aeson (object, toJSON, (.=))
import Data.Map qualified as Map
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.Id (GenericId (..))
import Katari.Data.JSONSchema
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SemanticType
import Katari.Schema
import Test.Hspec

spec :: Spec
spec = do
  describe "toJSONSchema" $ do
    it "maps primitives to their JSON Schema types" $ do
      toJSONSchema noData SemanticTypeInteger `shouldBe` SchemaInteger
      toJSONSchema noData SemanticTypeString `shouldBe` SchemaString
      toJSONSchema noData SemanticTypeNull `shouldBe` SchemaNull

    it "maps never / unknown to bottom / top schemas" $ do
      toJSONSchema noData SemanticTypeNever `shouldBe` SchemaNever
      toJSONSchema noData SemanticTypeUnknown `shouldBe` SchemaAny

    it "maps a homogeneous array via items" $
      toJSONSchema noData (SemanticTypeArray SemanticTypeString)
        `shouldBe` SchemaArray SchemaString

    it "maps a tuple via prefixItems" $
      toJSONSchema noData (SemanticTypeTuple [SemanticTypeInteger, SemanticTypeString])
        `shouldBe` SchemaTuple [SchemaInteger, SchemaString]

    it "leaves an object open and drops optional fields from required" $
      toJSONSchema
        noData
        ( SemanticTypeObject $
            Map.fromList
              [ ("x", FieldInformation {semanticType = SemanticTypeInteger, optional = False}),
                ("y", FieldInformation {semanticType = SemanticTypeString, optional = True})
              ]
        )
        `shouldBe` SchemaObject
          ObjectSchema
            { properties = [("x", SchemaInteger), ("y", SchemaString)],
              required = ["x"],
              additionalProperties = AdditionalPropertiesBoolean True
            }

    it "maps a record to a schema-valued additionalProperties" $
      toJSONSchema noData (SemanticTypeRecord SemanticTypeString)
        `shouldBe` SchemaObject
          ObjectSchema
            { properties = [],
              required = [],
              additionalProperties = AdditionalPropertiesSchema SchemaString
            }

    it "maps a union to anyOf" $
      toJSONSchema noData (SemanticTypeUnion [SemanticTypeInteger, SemanticTypeNull])
        `shouldBe` SchemaAnyOf [SchemaInteger, SchemaNull]

    it "maps a string literal singleton to a const schema" $
      toJSONSchema noData (SemanticTypeStringLiteral "https://x")
        `shouldBe` SchemaConst (toJSON ("https://x" :: Text))

    it "maps a union of string literals to an anyOf of const schemas" $
      toJSONSchema noData (SemanticTypeUnion [SemanticTypeStringLiteral "fast", SemanticTypeStringLiteral "slow"])
        `shouldBe` SchemaAnyOf [SchemaConst (toJSON ("fast" :: Text)), SchemaConst (toJSON ("slow" :: Text))]

    it "reflects the base type through an attribute (private is transparent)" $
      toJSONSchema noData (SemanticTypeAttribute SemanticTypeString SemanticAttributePrivate)
        `shouldBe` SchemaString

    it "maps a file to a slim $katari_ref handle (identity only — a bare $katari_ref is complete)" $
      toJSONSchema noData SemanticTypeFile
        `shouldBe` SchemaObject
          ObjectSchema
            { properties = [("$katari_ref", SchemaString), ("$katari_semantic_kind", SchemaString)],
              required = ["$katari_ref"],
              additionalProperties = AdditionalPropertiesBoolean True
            }

    it "maps an agent to a $katari_agent reference object" $
      toJSONSchema noData (SemanticTypeAgent SemanticTypeString SemanticTypeString SemanticEffectPure)
        `shouldBe` SchemaObject
          ObjectSchema
            { properties = [("$katari_agent", SchemaAny)],
              required = ["$katari_agent"],
              additionalProperties = AdditionalPropertiesBoolean True
            }

    it "maps a generic to a $generic placeholder" $
      toJSONSchema noData (SemanticTypeGeneric genericT)
        `shouldBe` SchemaGeneric genericT

  describe "toJSONSchema with data definitions" $ do
    it "inline-expands a data type as a $katari_constructor tag over its fields nested under `$katari_value`" $
      -- The @box@'s one field is itself named @value@, so the nesting reads
      -- @{ $katari_constructor: "test.box", $katari_value: { value: <integer> } }@.
      toJSONSchema boxDefinitions (SemanticTypeData boxName (Map.singleton "T" (SemanticGenericArgumentType SemanticTypeInteger)))
        `shouldBe` dataSchema "test.box" [("value", SchemaInteger)] ["value"]

    it "drops an optional data field from the nested value's required" $
      toJSONSchema noteDefinitions (SemanticTypeData noteName mempty)
        `shouldBe` dataSchema "test.note" [("body", SchemaString), ("title", SchemaString)] ["body"]

    it "breaks a recursive data reference with an open schema" $
      toJSONSchema listDefinitions (SemanticTypeData listName mempty)
        `shouldBe` dataSchema "test.list" [("tail", SchemaAny)] ["tail"]

    it "stays open for an unknown data name" $
      toJSONSchema noData (SemanticTypeData boxName mempty) `shouldBe` SchemaAny

  describe "fillGenericSchema" $ do
    it "replaces a placeholder nested inside an array" $
      fillGenericSchema (Map.singleton genericT SchemaString) (SchemaArray (SchemaGeneric genericT))
        `shouldBe` SchemaArray SchemaString

    it "leaves an unbound placeholder unchanged" $
      fillGenericSchema Map.empty (SchemaGeneric genericT)
        `shouldBe` SchemaGeneric genericT

  describe "ToJSON" $ do
    it "serialises a tuple to prefixItems" $
      toJSON (SchemaTuple [SchemaInteger, SchemaString])
        `shouldBe` object
          [ "type" .= ("array" :: Text),
            "prefixItems" .= [object ["type" .= ("integer" :: Text)], object ["type" .= ("string" :: Text)]]
          ]

    it "serialises a record's value type under additionalProperties" $
      toJSON (toJSONSchema noData (SemanticTypeRecord SemanticTypeString))
        `shouldBe` object
          [ "type" .= ("object" :: Text),
            "properties" .= object [],
            "required" .= ([] :: [Text]),
            "additionalProperties" .= object ["type" .= ("string" :: Text)]
          ]

-- | The nested wire schema of a @data@ value: a @$katari_constructor@ const over the fields nested (as an open
-- object) under @$katari_value@, with the outer wrapper closed to exactly those two keys.
dataSchema :: Text -> List (Text, JSONSchema) -> List Text -> JSONSchema
dataSchema constructorName fields requiredFields =
  SchemaObject
    ObjectSchema
      { properties =
          [ ("$katari_constructor", SchemaConst (toJSON constructorName)),
            ( "$katari_value",
              SchemaObject
                ObjectSchema
                  { properties = fields,
                    required = requiredFields,
                    additionalProperties = AdditionalPropertiesBoolean True
                  }
            )
          ],
        required = ["$katari_constructor", "$katari_value"],
        additionalProperties = AdditionalPropertiesBoolean False
      }

noData :: DataDefinitions
noData = Map.empty

testModule :: ModuleName
testModule = ModuleName "test"

genericT :: GenericId
genericT = GenericId testModule 0

boxName :: QualifiedName
boxName = QualifiedName {moduleName = testModule, name = "box"}

-- | @data box[T](value: T)@ — one generic parameter @T@ bound to its 'GenericId'.
boxDefinitions :: DataDefinitions
boxDefinitions =
  Map.singleton
    boxName
    DataDefinition
      { fields = Map.singleton "value" FieldInformation {semanticType = SemanticTypeGeneric genericT, optional = False},
        parameterGenericIds = Map.singleton "T" genericT
      }

noteName :: QualifiedName
noteName = QualifiedName {moduleName = testModule, name = "note"}

-- | @data note(body: string, title?: string)@ — exercises an optional data field.
noteDefinitions :: DataDefinitions
noteDefinitions =
  Map.singleton
    noteName
    DataDefinition
      { fields =
          Map.fromList
            [ ("body", FieldInformation {semanticType = SemanticTypeString, optional = False}),
              ("title", FieldInformation {semanticType = SemanticTypeString, optional = True})
            ],
        parameterGenericIds = Map.empty
      }

listName :: QualifiedName
listName = QualifiedName {moduleName = testModule, name = "list"}

-- | @data list(tail: list)@ — a self-referential type, to exercise the recursion guard.
listDefinitions :: DataDefinitions
listDefinitions =
  Map.singleton
    listName
    DataDefinition
      { fields = Map.singleton "tail" FieldInformation {semanticType = SemanticTypeData listName mempty, optional = False},
        parameterGenericIds = Map.empty
      }
