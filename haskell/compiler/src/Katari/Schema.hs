-- | The Schema phase: the public JSON schema (input / output / requests) of each callable in a typed
-- module, for the runtime / API. Per-module. This module defines the phase's I/O; the 'SchemaEntry'
-- shape is a placeholder and generation is not yet implemented.
module Katari.Schema where

import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST (Module, Phase (Typed))
import Katari.Data.ModuleName (ModuleName)

-- | One exported callable's schema. Placeholder — the schema shape is not yet designed.
newtype SchemaEntry = SchemaEntry
  { name :: Text
  -- TODO: input / output / requests JSON schema
  }
  deriving stock (Eq, Show)

-- | Build the schema entries of one typed module.
--
-- TODO: schema generation not yet implemented (returns no entries).
buildSchema :: ModuleName -> Module Typed -> List SchemaEntry
buildSchema _moduleName _module = []
