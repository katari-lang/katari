module Katari.Data.GenericKind where

import Data.Text (Text)

-- | The kind of a generic parameter: a type, an effect, or an attribute. The checker uses it to
-- split the bracket arguments of an application (@foo[int, private]@) into their respective kinds.
data GenericKind = GenericKindType | GenericKindEffect | GenericKindAttribute
  deriving stock (Eq, Show)

-- | The kind's surface name, for diagnostics (@type@ / @effect@ / @attribute@).
renderGenericKind :: GenericKind -> Text
renderGenericKind = \case
  GenericKindType -> "type"
  GenericKindEffect -> "effect"
  GenericKindAttribute -> "attribute"
