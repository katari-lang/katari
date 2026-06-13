-- | The Check (typecheck) phase: bidirectional type & effect checking of an identified module
-- against the global 'TypeEnvironment', producing a 'Typed' AST (every expression / pattern carries
-- its 'Katari.Data.SemanticType.SemanticType') and diagnostics. Per-module: once the environment is
-- built, modules check independently. The cross-module type info lives in the environment, so a
-- module's result is just its own typed AST. This module defines the phase's I/O; the checker is not
-- yet implemented.
module Katari.Typechecker.Check where

import Katari.Data.AST (Module, Phase (Identified, Typed))
import Katari.Diagnostics (Diagnostics)
import Katari.Typechecker.Environment (TypeEnvironment)

-- | Check one identified module against the global type environment, producing its typed AST and
-- diagnostics (K3xxx range). Match-exhaustiveness is folded in here for now (no separate phase).
--
-- TODO: the bidirectional checker is not yet implemented.
checkModule :: TypeEnvironment -> Module Identified -> (Module Typed, Diagnostics)
checkModule _environment _module = error "Katari.Typechecker.Check.checkModule: not yet implemented"
