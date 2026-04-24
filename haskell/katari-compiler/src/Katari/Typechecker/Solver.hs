-- | Typechecker phase 3:
-- Solve constraints for type variables.
-- Input : Constraints for type variables (output of phase 2)
-- Output : Mapping from type variables to their solved types, or error if unsolvable.
module Katari.Typechecker.Solver where