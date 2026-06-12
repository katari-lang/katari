module Katari.Data.ModuleName where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)

-- | Dot separated module name, e.g. "path.to.module"
newtype ModuleName = ModuleName Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

renderModuleName :: ModuleName -> Text
renderModuleName (ModuleName moduleName) = moduleName
