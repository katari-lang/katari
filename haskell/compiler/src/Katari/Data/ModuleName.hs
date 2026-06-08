module Katari.Data.ModuleName where

import Data.Aeson (FromJSON, ToJSON (..))
import Data.Aeson.Types (FromJSON (..))
import Data.Text (Text)
import GHC.Generics (Generic)

-- | Dot separated module name, e.g. "path.to.module"
newtype ModuleName = ModuleName Text
  deriving (Eq, Ord, Show, Generic)

instance ToJSON ModuleName where
  toJSON (ModuleName module_) = toJSON module_

instance FromJSON ModuleName where
  parseJSON = fmap ModuleName . parseJSON

renderModuleName :: ModuleName -> Text
renderModuleName (ModuleName module_) = module_
