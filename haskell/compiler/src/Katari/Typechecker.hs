-- | The Check (typecheck) phase: bidirectional type & effect checking, producing a 'Typed' AST
-- (every expression / pattern carries its 'Katari.Data.SemanticType.SemanticType') and diagnostics.
--
-- Whole-program, not per module: an @agent@ may infer its return / effect from the agents it calls,
-- and those callees can live in other modules and form mutual-recursion cycles, so the checker walks
-- the value-dependency SCCs ('Katari.Typechecker.ValueGraph.valueSCCs') to grow the value environment
-- dependency-first. A 'Data.Graph.CyclicSCC' is a (mutually) recursive group whose members must
-- annotate their return / effect (inference does not cross a recursion). The data / request / synonym
-- type info is signature-determined and already complete in the 'TypeEnvironment'.
--
-- This is the phase's entry point and orchestration, mirroring "Katari.Parser" / "Katari.Identifier":
-- the per-kind checking walks live in the @Katari.Typechecker.*@ submodules ('Katari.Typechecker.Normalizer'
-- for the type lattice, 'Katari.Typechecker.Environment' for the global env, 'Katari.Typechecker.ValueGraph'
-- for the dependency order). The checker is not yet implemented.
module Katari.Typechecker where

import Data.Graph (SCC)
import Data.Map (Map)
import GHC.List (List)
import Katari.Data.AST (Module, Phase (Identified, Typed))
import Katari.Data.ModuleName (ModuleName)
import Katari.Diagnostics (Diagnostics)
import Katari.Typechecker.Environment (TypeEnvironment)
import Katari.Typechecker.ValueGraph (ValueNode)

-- | Check the whole identified program against the global type environment, walking the value
-- dependency order ('Katari.Typechecker.ValueGraph.valueSCCs') so a value's inferred return / effect
-- can be read from its callees first. Produces each module's typed AST and all diagnostics (K3xxx
-- range). Match-exhaustiveness is folded in here for now (no separate phase).
--
-- TODO: the bidirectional checker is not yet implemented. The stub preserves the module keys (so the
-- downstream lowering sees the right module set) while every typed AST stays bottom until then.
checkProgram ::
  TypeEnvironment ->
  List (SCC ValueNode) ->
  Map ModuleName (Module Identified) ->
  (Map ModuleName (Module Typed), Diagnostics)
checkProgram _environment _valueOrder modules =
  (error "Katari.Typechecker.checkProgram: not yet implemented" <$ modules, mempty)
