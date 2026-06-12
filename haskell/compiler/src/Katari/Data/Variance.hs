module Katari.Data.Variance where

data Variance = Covariant | Contravariant | Invariant | Bivariant
  deriving (Eq, Show)
