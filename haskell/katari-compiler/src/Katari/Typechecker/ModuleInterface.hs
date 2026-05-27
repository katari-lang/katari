module Katari.Typechecker.ModuleInterface
  ( ModuleInterface (..),
    extractModuleInterface,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Katari.Id (QualifiedName (..), VariableId)
import Katari.SemanticType (Resolved, SemanticType)
import Katari.Typechecker.Identifier (VariableData (..))

data ModuleInterface = ModuleInterface
  { exportedTypes :: Map QualifiedName (SemanticType Resolved)
  }
  deriving (Show)

extractModuleInterface ::
  Text ->
  Map VariableId VariableData ->
  Map VariableId (SemanticType Resolved) ->
  ModuleInterface
extractModuleInterface moduleName variables typeEnvironment =
  ModuleInterface
    { exportedTypes =
        Map.fromList
          [ (qualifiedName, resolvedType)
            | (variableId, variableData) <- Map.toList variables,
              Just qualifiedName <- [variableData.variableQualifiedName],
              qualifiedName.module_ == moduleName,
              Just resolvedType <- [Map.lookup variableId typeEnvironment]
          ]
    }
