module Katari.Data.QualifiedName where

import Data.Aeson (ToJSON (..), Value (String))
import Data.Text (Text)
import Data.Text.Prettyprint.Doc.Render.Tutorials.StackMachineTutorial (render)
import GHC.Generics (Generic)
import Katari.Data.ModuleName (ModuleName, renderModuleName)

-- | Qualified name, e.g. "path.to.module.name"
data QualifiedName = QualifiedName
  { module_ :: ModuleName,
    name :: Text
  }
  deriving (Eq, Ord, Show, Generic)

instance ToJSON QualifiedName where
  toJSON :: QualifiedName -> Value
  toJSON qualifiedName = String $ renderQualifiedName qualifiedName

renderQualifiedName :: QualifiedName -> Text
renderQualifiedName qualifiedName = renderModuleName qualifiedName.module_ <> "." <> qualifiedName.name
