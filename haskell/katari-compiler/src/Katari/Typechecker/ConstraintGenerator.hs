-- | Typechecker phase 2:
-- Attach unsolved type variables to each expressions and patterns, and generate constraints for them.
-- Input : AST with unique identifiers attached to definitions (output of phase 1)
-- Output : AST with metadata of unsolved type variables, list of constraints for type variables
module Katari.Typechecker.ConstraintGenerator where

import Prelude ()
