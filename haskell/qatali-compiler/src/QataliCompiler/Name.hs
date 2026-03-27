module QataliCompiler.Name (
    Name (..),
    ModuleName (..),
    QualifiedName (..),
    qualify,
    unqualify,
    mkName,
    mkModuleName,
) where

import           Data.List.NonEmpty (NonEmpty (..))
import           Data.Text          (Text)

-- | An unqualified identifier (e.g. @foo@, @Bar@).
newtype Name = Name {unName :: Text}
    deriving (Eq, Ord, Show)

-- | A module name as a non-empty list of segments (e.g. @Qatali.Core@).
newtype ModuleName = ModuleName {segments :: NonEmpty Text}
    deriving (Eq, Ord, Show)

-- | A possibly-qualified name (e.g. @Qatali.Core.foo@).
data QualifiedName = QualifiedName
    { qnModule :: !(Maybe ModuleName)
    , qnName   :: !Name
    }
    deriving (Eq, Ord, Show)

qualify :: ModuleName -> Name -> QualifiedName
qualify m n = QualifiedName (Just m) n

unqualify :: Name -> QualifiedName
unqualify = QualifiedName Nothing

mkName :: Text -> Name
mkName = Name

mkModuleName :: [Text] -> Maybe ModuleName
mkModuleName segs =
    case segs of
        []       -> Nothing
        (x : xs) -> Just $ ModuleName (x :| xs)
