-- | The Lower phase: a 'Typed' AST to the runtime IR ('LoweredModule'), per module. The runtime
-- uploads modules individually, so there is no whole-program link step. This module defines the
-- phase's I/O; lowering is not yet implemented.
module Katari.Lowering where

import Katari.Data.AST (Module, Phase (Typed))
import Katari.Data.IR (LoweredModule (..))
import Katari.Data.ModuleName (ModuleName)
import Katari.Diagnostics (Diagnostics)

-- | Lower one typed module to IR, with diagnostics (K4xxx range).
--
-- TODO: lowering not yet implemented (returns the empty shell for the module).
lowerModule :: ModuleName -> Module Typed -> (LoweredModule, Diagnostics)
lowerModule moduleName _module = (LoweredModule {moduleName = moduleName}, mempty)
