module Katari.Data.QualifiedName where

import Data.Aeson (ToJSON (..), Value (String))
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

renderQualifiedName :: QualifiedName -> Text
renderQualifiedName qualifiedName = renderModuleName qualifiedName.moduleName <> "." <> qualifiedName.name
