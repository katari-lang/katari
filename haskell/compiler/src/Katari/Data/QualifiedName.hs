module Katari.Data.QualifiedName where

import Data.Aeson (ToJSON (..), ToJSONKey (..), Value (String))
import Data.Aeson.Types (toJSONKeyText)
import Data.Text (Text)
import Katari.Data.ModuleName (ModuleName, renderModuleName)

-- | Qualified name, e.g. "path.to.module.name"
data QualifiedName = QualifiedName
  { moduleName :: ModuleName,
    name :: Text
  }
  deriving stock (Eq, Ord, Show)

instance ToJSON QualifiedName where
  toJSON qualifiedName = String $ renderQualifiedName qualifiedName

-- | As an object key (the IR's @entries@ map is keyed by 'QualifiedName'), rendered "module.name".
instance ToJSONKey QualifiedName where
  toJSONKey = toJSONKeyText renderQualifiedName

renderQualifiedName :: QualifiedName -> Text
renderQualifiedName qualifiedName = renderModuleName qualifiedName.moduleName <> "." <> qualifiedName.name
