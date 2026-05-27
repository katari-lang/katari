module Katari.Typechecker.ModuleInterface
  ( ModuleInterface (..),
    extractModuleInterface,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Katari.Id (QualifiedName (..), VariableResolution (..))
import Katari.SemanticType (Resolved, SemanticType)
import Katari.Typechecker.Identifier (VariableData (..))

data ModuleInterface = ModuleInterface
  { exportedTypes :: Map QualifiedName (SemanticType Resolved)
  }
  deriving (Eq, Show)

extractModuleInterface ::
  Text ->
  Map QualifiedName VariableData ->
  Map VariableResolution (SemanticType Resolved) ->
  ModuleInterface
extractModuleInterface moduleName variables typeEnvironment =
  ModuleInterface
    { exportedTypes =
        Map.fromList
          [ (qualifiedName, resolvedType)
            | (qualifiedName, _variableData) <- Map.toList variables,
              qualifiedName.module_ == moduleName,
              Just resolvedType <- [Map.lookup (ResolvedTopLevel qualifiedName) typeEnvironment]
          ]
    }
