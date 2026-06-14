-- | The Build-Environment phase: a single global pass that collects every module's data / request
-- declarations (already name-resolved) into the type environment the checker consults. Global
-- because variance is inferred by a cross-module SCC fixed point and type-shape normalization needs
-- the arity / kind of data declared in other modules. Runs after Identify, before Check. This module
-- defines the phase's I/O; the collection / normalization / variance fixed point is not yet
-- implemented.
module Katari.Typechecker.Environment where

import GHC.List (List)
import Katari.Data.AST (Module, Phase (Identified))
import Katari.Data.Environment (DataEnvironment, RequestEnvironment, SynonymEnvironment, ValueEnvironment)
import Katari.Data.NormalizedType (NormalizedGenericArgument, NormalizedType)
import Katari.Diagnostics (Diagnostics)

-- | The read-only type environment the checker consults across the whole program:
--
--   * 'dataEnvironment' / 'requestEnvironment' — the normalized constructor / request shape and
--     inferred variance of every nominal data type and request;
--   * 'valueEnvironment' — the agent-typed scheme of every top-level @agent@ / @external@ /
--     @primitive@ (so a reference to one, including cross-module, types through one lookup);
--   * 'synonymEnvironment' — every type synonym's scheme, so a per-module checker can expand a
--     synonym defined elsewhere.
--
-- Per-module generic bounds and the subtyping @world@ are added locally by the checker (see
-- "Katari.Typechecker.Normalizer"), so they are not here.
data TypeEnvironment = TypeEnvironment
  { dataEnvironment :: DataEnvironment NormalizedType,
    requestEnvironment :: RequestEnvironment NormalizedType,
    valueEnvironment :: ValueEnvironment NormalizedType,
    synonymEnvironment :: SynonymEnvironment NormalizedGenericArgument
  }
  deriving stock (Eq, Show)

emptyTypeEnvironment :: TypeEnvironment
emptyTypeEnvironment =
  TypeEnvironment
    { dataEnvironment = mempty,
      requestEnvironment = mempty,
      valueEnvironment = mempty,
      synonymEnvironment = mempty
    }

-- | Build the global type environment from every identified module. The data / request / value
-- (agent / external / primitive) / synonym declarations are filtered out of the identified ASTs (no
-- separate signature artifact); their syntactic types are normalized, variance is inferred by a
-- global fixed point, and synonyms are expanded (recursion rejected here).
--
-- TODO: not yet implemented (returns the empty environment).
buildEnvironment :: List (Module Identified) -> (TypeEnvironment, Diagnostics)
buildEnvironment _modules = (emptyTypeEnvironment, mempty)
