-- | The Check (typecheck) phase: bidirectional type & effect checking of an identified module
-- against the global 'TypeEnvironment', producing a 'Typed' AST (every expression / pattern carries
-- its 'Katari.Data.SemanticType.SemanticType') and diagnostics. Per-module: once the environment is
-- built, modules check independently. The cross-module type info lives in the environment, so a
-- module's result is just its own typed AST.
--
-- This is the phase's entry point and top-level orchestration (the declaration dispatch), mirroring
-- "Katari.Parser" / "Katari.Identifier": the per-kind checking walks live in the @Katari.Typechecker.*@
-- submodules ('Katari.Typechecker.Normalizer' for the type lattice, 'Katari.Typechecker.Environment'
-- for the global env). The checker is not yet implemented.
module Katari.Typechecker where

import Katari.Data.AST (Module, Phase (Identified, Typed))
import Katari.Diagnostics (Diagnostics)
import Katari.Typechecker.Environment (TypeEnvironment)

-- | Check one identified module against the global type environment, producing its typed AST and
-- diagnostics (K3xxx range). Match-exhaustiveness is folded in here for now (no separate phase).
--
-- TODO: the bidirectional checker is not yet implemented.
checkModule :: TypeEnvironment -> Module Identified -> (Module Typed, Diagnostics)
checkModule _environment _module = error "Katari.Typechecker.checkModule: not yet implemented"
