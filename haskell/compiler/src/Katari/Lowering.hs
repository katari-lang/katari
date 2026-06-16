-- | The Lower phase: a 'Typed' AST to the runtime IR ('IRModule'), per module. The runtime uploads
-- modules individually, so there is no whole-program link step. Lowering also produces each
-- callable's schema (into 'IRModule.schemas'), since only it knows the 'BlockId's the schema is keyed
-- by. This module defines the phase's I/O; lowering is not yet implemented.
module Katari.Lowering where

import Katari.Data.AST (Module, Phase (Typed))
import Katari.Data.IR (IRModule (..), currentMetadata)
import Katari.Data.ModuleName (ModuleName)
import Katari.Diagnostics (Diagnostics)

-- | Lower one typed module to IR, with diagnostics (K4xxx range).
--
-- TODO: lowering not yet implemented (returns an empty module).
lowerModule :: ModuleName -> Module Typed -> (IRModule, Diagnostics)
lowerModule _moduleName _module =
  ( IRModule
      { metadata = currentMetadata,
        blocks = mempty,
        entries = mempty,
        names = mempty
      },
    mempty
  )
