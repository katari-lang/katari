-- | The lowered intermediate representation handed to the runtime, per module. NOTE: the IR itself
-- is not yet designed for the scrap-and-build — this is a placeholder shell that fixes the lowering
-- seam (its fields are filled in once the IR is designed). The runtime uploads modules
-- individually, so there is no whole-program link step / merged @Program@.
module Katari.Data.IR where

import Katari.Data.ModuleName (ModuleName)

-- | One module's lowered output (blocks, entry points, name table, ...). Placeholder.
newtype LoweredModule = LoweredModule
  { moduleName :: ModuleName
  -- TODO: blocks / entries / name table
  }
  deriving stock (Eq, Show)
