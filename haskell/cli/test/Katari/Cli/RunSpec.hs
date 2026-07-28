module Katari.Cli.RunSpec (spec) where

import Data.Map qualified as Map
import Data.Text (Text)
import GHC.List (List)
import Katari.Cli.Command.Run (runsOnDefaults)
import Katari.Data.JSONSchema (JSONSchema (..))
import Katari.Data.SemanticType (FieldInformation (..), SemanticType (..))
import Katari.Schema (DataDefinitions, describedWith, toJSONSchema)
import Test.Hspec

spec :: Spec
spec = do
  describe "runsOnDefaults" $ do
    it "runs an all-optional agent on its defaults" $
      runsOnDefaults (inputSchemaOf [("count", Optional)]) `shouldBe` True

    it "asks for an argument when a parameter is required" $
      runsOnDefaults (inputSchemaOf [("count", Required)]) `shouldBe` False

    it "runs a DOCUMENTED all-optional agent on its defaults too" $
      -- The regression this pins: a `description` overlay is what the compiler wraps a documented
      -- declaration's schema in, and a reader that matched the bare object BENEATH the overlay would
      -- see "not a shape I recognise" and fall through to the required-parameters branch — demanding
      -- `--arg` off a terminal and opening a pointless interview on one. A description annotates and
      -- never constrains, so documenting a declaration must not change how it is RUN.
      runsOnDefaults (documented (inputSchemaOf [("count", Optional)])) `shouldBe` True

    it "still asks for an argument when a documented agent has a required parameter" $
      runsOnDefaults (documented (inputSchemaOf [("count", Required)])) `shouldBe` False

    it "sees through a doubly-documented schema" $
      -- Overlays compose (a described type under a described declaration), so peeling must be total.
      runsOnDefaults (documented (documented (inputSchemaOf []))) `shouldBe` True

    it "asks for an argument when the input schema is not an object at all" $
      -- Nothing says an unrecognised input may be omitted, so the interview stands.
      runsOnDefaults SchemaAny `shouldBe` False

-- | Whether a parameter carries a default (the caller may omit it) or must be supplied.
data Optionality = Optional | Required
  deriving stock (Eq, Show)

-- | An agent's input schema as the compiler emits it: the parameter record, each parameter named with
-- whether it may be omitted. Built through 'toJSONSchema' rather than spelled out by hand, so the
-- fixture FOLLOWS the encoding instead of pinning a stale copy that would stay green through a change.
inputSchemaOf :: List (Text, Optionality) -> JSONSchema
inputSchemaOf parameters =
  toJSONSchema
    noData
    ( SemanticTypeObject $
        Map.fromList
          [ (name, FieldInformation {semanticType = SemanticTypeString, optional = optionality == Optional})
            | (name, optionality) <- parameters
          ]
    )

-- | A schema under the @description@ overlay a documented declaration gets, applied with the compiler's
-- own overlay helper — the one 'toJSONSchema' itself uses.
documented :: JSONSchema -> JSONSchema
documented = describedWith (Just "What this agent does.")

noData :: DataDefinitions
noData = Map.empty
