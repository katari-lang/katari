module Katari.Typechecker.ModuleInterface
  ( ModuleInterface (..),
    extractModuleInterface,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Katari.Id (QualifiedName (..))
import Katari.TypeScheme (TypeScheme)
import Katari.Typechecker.Identifier (VariableData (..))

-- | A module's public surface: each exported callable's full type /scheme/
-- (body + generic quantifiers), so an importer sees its generics too.
data ModuleInterface = ModuleInterface
  { exportedTypes :: Map QualifiedName TypeScheme
  }
  deriving (Eq, Show)

extractModuleInterface ::
  Text ->
  Map QualifiedName VariableData ->
  -- | All resolved schemes in scope after the module is checked (imports + this
  -- module's own signatures); the own ones are filtered out below.
  Map QualifiedName TypeScheme ->
  ModuleInterface
extractModuleInterface moduleName variables schemes =
  ModuleInterface
    { exportedTypes =
        Map.fromList
          [ (qualifiedName, scheme)
            | (qualifiedName, _variableData) <- Map.toList variables,
              qualifiedName.module_ == moduleName,
              Just scheme <- [Map.lookup qualifiedName schemes]
          ]
    }
