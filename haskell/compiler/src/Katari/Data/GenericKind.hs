module Katari.Data.GenericKind where

-- | The kind of a generic parameter: a type, an effect, or an attribute. The checker uses it to
-- split the bracket arguments of an application (@foo[int, private]@) into their respective kinds.
data GenericKind where
  GenericKindType :: GenericKind
  GenericKindEffect :: GenericKind
  GenericKindAttribute :: GenericKind
  deriving stock (Eq, Show)
