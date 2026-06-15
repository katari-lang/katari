module Katari.Data.ModuleName where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)

-- | Dot separated module name, e.g. "path.to.module"
newtype ModuleName = ModuleName Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

renderModuleName :: ModuleName -> Text
renderModuleName (ModuleName moduleName) = moduleName

-- | Build a module name from its @.@-separated segments (@["path", "to"]@ -> @path.to@). The single
-- home of the join convention, used wherever a module name is assembled from parts (e.g. a stdlib
-- file path in "Katari.Stdlib") so the separator lives in one place.
moduleNameFromSegments :: List Text -> ModuleName
moduleNameFromSegments segments = ModuleName (Text.intercalate "." segments)

-- | The last @.@-separated segment of a module name (@a.b.c@ -> @c@). Used as a default qualifier
-- (a bare @import@ alias, a default-import qualifier).
lastSegment :: ModuleName -> Text
lastSegment (ModuleName moduleName) = Text.takeWhileEnd (/= '.') moduleName

-- | Whether @root@ covers @candidate@: @root@ itself, or one of its @root.@-prefixed descendants.
-- The @.@ guard keeps @a@ from covering a mere name-prefix sibling like @ab@. The single home of the
-- module-ancestry convention (default-import coverage, reserved-namespace checks).
covers :: ModuleName -> ModuleName -> Bool
covers root candidate =
  root == candidate || (renderModuleName root <> ".") `Text.isPrefixOf` renderModuleName candidate
