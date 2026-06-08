module Katari.Data.Variant where

data Variance = Covariant | Contravariant | Invariant | Bivariant
  deriving (Eq, Show)

data Polarity = Pos | Neg
  deriving (Eq, Ord, Show)
