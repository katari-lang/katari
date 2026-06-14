-- | The Build-Environment phase: a single global pass that collects every module's data / request
-- declarations (already name-resolved) into the type environment the checker consults. Global
-- because variance is inferred by a cross-module SCC fixed point and type-shape normalization needs
-- the arity / kind of data declared in other modules. Runs after Identify, before Check. This module
-- defines the phase's I/O; the collection / normalization / variance fixed point is not yet
-- implemented.
module Katari.Typechecker.Environment where

import GHC.List (List)
import Katari.Data.AST (Module, Phase (Identified))
import Katari.Data.Environment (DataEnvironment, RequestEnvironment)
import Katari.Data.NormalizedType (NormalizedType)
import Katari.Diagnostics (Diagnostics)

-- | The read-only type environment the checker consults: the normalized constructor shape and
-- inferred variance of every data type and request across the whole program. Per-module generic
-- bounds and the subtyping @world@ are added locally by the checker (see
-- "Katari.Typechecker.Normalizer"), so they are not here.
data TypeEnvironment = TypeEnvironment
  { dataEnvironment :: DataEnvironment NormalizedType,
    requestEnvironment :: RequestEnvironment NormalizedType
  }
  deriving stock (Eq, Show)

emptyTypeEnvironment :: TypeEnvironment
emptyTypeEnvironment = TypeEnvironment {dataEnvironment = mempty, requestEnvironment = mempty}

-- | Build the global type environment from every identified module. The data / request declarations
-- are filtered out of the identified ASTs (no separate signature artifact); their syntactic types
-- are normalized and variance is inferred by a global fixed point.
--
-- TODO: not yet implemented (returns the empty environment).
buildEnvironment :: List (Module Identified) -> (TypeEnvironment, Diagnostics)
buildEnvironment _modules = (emptyTypeEnvironment, mempty)
