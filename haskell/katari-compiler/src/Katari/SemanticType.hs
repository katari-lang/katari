module Katari.SemanticType where

import Data.Text (Text)
import Prelude ()

data SemanticType where
  SemanticTypeNull :: SemanticType
  SemanticTypeInteger :: SemanticType
  SemanticTypeNumber :: SemanticType
  SemanticTypeString :: SemanticType
  SemanticTypeBoolean :: SemanticType
  SemanticTypeFunction :: [(Text, SemanticType)] -> SemanticType -> SemanticType
  SemanticTypeArray :: SemanticType -> SemanticType
  SemanticTypeTuple :: [SemanticType] -> SemanticType
  -- | Id of a data definition
  SemanticTypeData :: Text -> SemanticType