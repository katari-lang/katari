-- | Variance of a generic parameter and the lattice / composition the env-build's variance inference
-- runs over. 'Bivariant' is the bottom (a parameter used nowhere is bivariant); 'Invariant' is the
-- top (used in both polarities). Inference starts every parameter at 'Bivariant' and 'joinVariance's
-- in each occurrence's polarity until a fixed point.
module Katari.Data.Variance where

data Variance = Covariant | Contravariant | Invariant | Bivariant
  deriving (Eq, Show)

-- | Flip a polarity (what a contravariant position does to the variance observed inside it).
-- 'Invariant' and 'Bivariant' are self-dual.
flipVariance :: Variance -> Variance
flipVariance = \case
  Covariant -> Contravariant
  Contravariant -> Covariant
  Invariant -> Invariant
  Bivariant -> Bivariant

-- | The usage lattice's join: 'Bivariant' is the identity (no usage), equal polarities are kept, and
-- any two distinct non-bivariant polarities (e.g. co- and contra-) raise to 'Invariant'. Used to
-- accumulate a parameter's polarity across all its occurrences.
joinVariance :: Variance -> Variance -> Variance
joinVariance left right = case (left, right) of
  (Bivariant, other) -> other
  (other, Bivariant) -> other
  _ | left == right -> left
  _ -> Invariant

-- | Compose an outer position's variance with the variance observed inside it: a covariant position
-- passes the inner variance through, a contravariant one flips it, and an invariant one forces
-- 'Invariant' unless the inner thing is unused ('Bivariant'). The whole thing collapses to
-- 'Bivariant' if either factor is bivariant (an unused position, or a position over an unused
-- parameter, contributes no usage).
composeVariance :: Variance -> Variance -> Variance
composeVariance outer inner = case (outer, inner) of
  -- An unused position, or a position over an unused parameter, contributes no usage.
  (Bivariant, _) -> Bivariant
  (_, Bivariant) -> Bivariant
  (Covariant, _) -> inner
  (Contravariant, _) -> flipVariance inner
  (Invariant, _) -> Invariant
