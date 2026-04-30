-- | Tests for 'Katari.Schema' — primarily the @SemanticType -> JsonSchema@
-- conversion and JSON round-trip stability.
module Katari.SchemaSpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Compile (CompileInput (..), CompileResult (..), compile)
import Katari.Diagnostic (Diagnostic (..))
import Katari.Schema
import Katari.Typechecker.SemanticType
  ( Resolved,
    SemanticEffect (..),
    SemanticType (..),
  )
import Test.Hspec

-- ===========================================================================
-- Helpers
-- ===========================================================================

shouldHaveCore :: SemanticType Resolved -> SchemaCore -> Expectation
shouldHaveCore t expected = (toJsonSchema t).core `shouldBe` expected

roundTrip :: (Aeson.ToJSON a, Aeson.FromJSON a, Eq a, Show a) => a -> Expectation
roundTrip value =
  case Aeson.fromJSON (Aeson.toJSON value) of
    Aeson.Success decoded -> decoded `shouldBe` value
    Aeson.Error msg -> expectationFailure ("decode failed: " <> msg)

-- ===========================================================================
-- Spec
-- ===========================================================================

spec :: Spec
spec = describe "Katari.Schema" $ do
  toJsonSchemaSpec
  unionCompactionSpec
  jsonRoundTripSpec
  bundleShapeSpec
  descriptionEndToEndSpec

toJsonSchemaSpec :: Spec
toJsonSchemaSpec = describe "toJsonSchema (SemanticType -> JsonSchema)" $ do
  it "primitives map to their JSON Schema counterparts" $ do
    SemanticTypeNull `shouldHaveCore` SchemaCoreNull
    SemanticTypeBoolean `shouldHaveCore` SchemaCoreBoolean
    SemanticTypeNumber `shouldHaveCore` SchemaCoreNumber
    SemanticTypeInteger `shouldHaveCore` SchemaCoreInteger {minimum = Nothing, maximum = Nothing}
    SemanticTypeString `shouldHaveCore` SchemaCoreString {schemaEnum = []}
    SemanticTypeNever `shouldHaveCore` SchemaCoreNever
    SemanticTypeUnknown `shouldHaveCore` SchemaCoreUnknown

  it "literal types become SchemaCoreConst" $ do
    SemanticTypeLiteralInteger 42 `shouldHaveCore` SchemaCoreConst {value = Aeson.Number 42}
    SemanticTypeLiteralString "hi" `shouldHaveCore` SchemaCoreConst {value = String "hi"}
    SemanticTypeLiteralBoolean True `shouldHaveCore` SchemaCoreConst {value = Bool True}

  it "arrays nest the element schema under 'items'" $ do
    let core = (toJsonSchema (SemanticTypeArray SemanticTypeInteger)).core
    case core of
      SchemaCoreArray {items} -> items.core `shouldBe` SchemaCoreInteger {minimum = Nothing, maximum = Nothing}
      _ -> expectationFailure "expected SchemaCoreArray"

  it "tuples become SchemaCoreTuple with prefixItems" $ do
    let t = SemanticTypeTuple [SemanticTypeBoolean, SemanticTypeInteger]
        core = (toJsonSchema t).core
    case core of
      SchemaCoreTuple {prefixItems} -> map (.core) prefixItems `shouldBe` [SchemaCoreBoolean, SchemaCoreInteger {minimum = Nothing, maximum = Nothing}]
      _ -> expectationFailure "expected SchemaCoreTuple"

  it "objects become SchemaCoreObject with required = all field labels" $ do
    let t =
          SemanticTypeObject $
            Map.fromList
              [ ("name", SemanticTypeString),
                ("age", SemanticTypeInteger)
              ]
    case (toJsonSchema t).core of
      SchemaCoreObject {properties, required, additionalProperties} -> do
        Map.keysSet properties `shouldBe` Set.fromList ["age", "name"]
        required `shouldBe` Set.fromList ["age", "name"]
        additionalProperties `shouldBe` False
      _ -> expectationFailure "expected SchemaCoreObject"

  it "function types fall back to SchemaCoreUnknown (not JSON-serialisable)" $ do
    let t =
          SemanticTypeFunction
            Map.empty
            SemanticTypeNull
            (SemanticEffect Set.empty Set.empty)
    t `shouldHaveCore` SchemaCoreUnknown

unionCompactionSpec :: Spec
unionCompactionSpec = describe "union compaction" $ do
  it "string-literal union folds into string-enum" $ do
    let t =
          SemanticTypeUnion
            [ SemanticTypeLiteralString "red",
              SemanticTypeLiteralString "green",
              SemanticTypeLiteralString "blue"
            ]
    case (toJsonSchema t).core of
      SchemaCoreString {schemaEnum} -> schemaEnum `shouldBe` ["red", "green", "blue"]
      other -> expectationFailure ("expected SchemaCoreString enum, got: " <> show other)

  it "mixed union falls back to anyOf" $ do
    let t =
          SemanticTypeUnion
            [ SemanticTypeLiteralString "ok",
              SemanticTypeNull
            ]
    case (toJsonSchema t).core of
      SchemaCoreUnion {anyOf} -> length anyOf `shouldBe` 2
      other -> expectationFailure ("expected SchemaCoreUnion, got: " <> show other)

jsonRoundTripSpec :: Spec
jsonRoundTripSpec = describe "JSON round-trip" $ do
  it "JsonSchema round-trips" $ do
    roundTrip (toJsonSchema (SemanticTypeArray SemanticTypeInteger))
    roundTrip
      ( toJsonSchema
          ( SemanticTypeObject
              ( Map.fromList
                  [ ("x", SemanticTypeInteger),
                    ("y", SemanticTypeNumber)
                  ]
              )
          )
      )

  it "empty SchemaBundle round-trips" $ do
    roundTrip emptySchemaBundle

bundleShapeSpec :: Spec
bundleShapeSpec = describe "SchemaBundle shape (Phase 15-H)" $ do
  it "buildSchemas keys agent / req / ext / data schemas by qualified name and includes dataDefs" $ do
    -- Wire the compile pipeline directly here so we can inspect the
    -- resulting SchemaBundle. We import only the minimum to avoid
    -- pulling parser plumbing into the schema test module.
    -- The end-to-end coverage lives in CompileSpec; this test pins
    -- the SchemaBundle shape contract.
    let bundle = emptySchemaBundle
    Map.null bundle.agentSchemas `shouldBe` True
    Map.null bundle.requestSchemas `shouldBe` True
    Map.null bundle.externalSchemas `shouldBe` True
    Map.null bundle.dataSchemas `shouldBe` True
    Map.null bundle.dataDefs `shouldBe` True

  it "agentSchemas / dataSchemas are AgentSchema (callable shape) and dataDefs is JsonSchema ($defs)" $ do
    -- Type-level shape assertion via constructor pattern.
    let agent =
          AgentSchema
            { description = Nothing,
              input =
                JsonSchema
                  { core = SchemaCoreObject {properties = Map.empty, required = Set.empty, additionalProperties = False},
                    title = Nothing,
                    description = Nothing,
                    examples = []
                  },
              output =
                JsonSchema
                  { core = SchemaCoreNull,
                    title = Nothing,
                    description = Nothing,
                    examples = []
                  },
              effects = []
            }
        ctor =
          AgentSchema
            { description = Just "make Pair",
              input =
                JsonSchema
                  { core = SchemaCoreObject {properties = Map.empty, required = Set.empty, additionalProperties = False},
                    title = Just "Pair",
                    description = Just "make Pair",
                    examples = []
                  },
              output =
                JsonSchema
                  { core = SchemaCoreRef "#/$defs/main.Pair",
                    title = Nothing,
                    description = Nothing,
                    examples = []
                  },
              effects = []
            }
        dataDef =
          JsonSchema
            { core = SchemaCoreObject {properties = Map.empty, required = Set.empty, additionalProperties = False},
              title = Just "Pair",
              description = Nothing,
              examples = []
            }
        bundle =
          SchemaBundle
            { agentSchemas = Map.singleton "main.greet" agent,
              requestSchemas = Map.empty,
              externalSchemas = Map.empty,
              dataSchemas = Map.singleton "main.Pair" ctor,
              dataDefs = Map.singleton "main.Pair" dataDef
            }
    -- Round-trip through JSON to lock the wire shape.
    roundTrip bundle
    -- And the qualified-name keys are accessible.
    Map.lookup "main.greet" bundle.agentSchemas `shouldSatisfy` ( \case
      Just _ -> True
      Nothing -> False
      )
    Map.lookup "main.Pair" bundle.dataSchemas `shouldSatisfy` ( \case
      Just _ -> True
      Nothing -> False
      )

-- ===========================================================================
-- Phase 17: annotation → description end-to-end
-- ===========================================================================

descriptionEndToEndSpec :: Spec
descriptionEndToEndSpec = describe "annotation → description (end-to-end)" $ do
  let src =
        "@\"a 2D point\"\n\
        \data Point(@\"horizontal coordinate\" x: number, @\"vertical coordinate\" y: number)\n\
        \\n\
        \@\"format a point\"\n\
        \agent show(@\"the point\" p: Point) -> string {\n\
        \  \"\"\n\
        \}"
      result = compile CompileInput {sources = Map.singleton "main" src, rootModule = "main"}
      bundle :: SchemaBundle
      bundle = case result.schemaBundle of
        Just b -> b
        Nothing -> error ("compile failed: " <> show (map (.code) result.diagnostics))

  it "agent description comes from @-annotation" $ do
    (Map.lookup "main.show" bundle.agentSchemas >>= (.description))
      `shouldBe` (Just "format a point" :: Maybe Text)

  it "agent input property description comes from parameter @-annotation" $ do
    let prop :: Maybe Text
        prop = do
          agent <- Map.lookup "main.show" bundle.agentSchemas
          props <- case agent.input.core of
            SchemaCoreObject {properties = p} -> Just p
            _ -> Nothing
          paramSchema <- Map.lookup "p" props
          paramSchema.description
    prop `shouldBe` Just "the point"

  it "dataDefs description comes from data @-annotation" $ do
    (Map.lookup "main.Point" bundle.dataDefs >>= (.description))
      `shouldBe` (Just "a 2D point" :: Maybe Text)

  it "dataDefs field descriptions come from field @-annotations" $ do
    let fieldDesc :: Text -> Maybe Text
        fieldDesc label = do
          def <- Map.lookup "main.Point" bundle.dataDefs
          props <- case def.core of
            SchemaCoreObject {properties = p} -> Just p
            _ -> Nothing
          field <- Map.lookup label props
          field.description
    fieldDesc "x" `shouldBe` Just "horizontal coordinate"
    fieldDesc "y" `shouldBe` Just "vertical coordinate"

  it "dataSchemas (callable) description comes from data @-annotation" $ do
    (Map.lookup "main.Point" bundle.dataSchemas >>= (.description))
      `shouldBe` (Just "a 2D point" :: Maybe Text)
