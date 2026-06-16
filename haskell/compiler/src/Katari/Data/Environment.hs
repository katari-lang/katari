-- | Global Type environments
-- Typechecker.Enviroment will collect the data, requests, and synonyms (not values, because retrun & effect types should be inferred)
-- Checker will collect values for each SCC
module Katari.Data.Environment where

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.GenericKind (GenericKind)
import Katari.Data.Id (GenericId)
import Katari.Data.NormalizedType (NormalizedKindedType, NormalizedType)
import Katari.Data.QualifiedName (QualifiedName)
import Katari.Data.Variance (Variance)

type DataEnvironment = Map QualifiedName DataInformation

type RequestEnvironment = Map QualifiedName RequestInformation

type ValueEnvironment = Map QualifiedName ValueInformation

type SynonymEnvironment = Map QualifiedName SynonymInformation

-- | One declared generic parameter of a data type or request. This is the single source of truth for a generic's bound
data GenericParameterInformation = GenericParameterInformation
  { genericId :: GenericId,
    kind :: GenericKind,
    variance :: Variance,
    -- | The declared @extends@ upper bound, normalized; 'Nothing' for an unbounded parameter
    upperBound :: Maybe NormalizedKindedType
  }
  deriving (Eq, Show)

data GenericParameters = GenericParameters
  { parameterNames :: List Text, -- Index ~> parameter name
    parameterInformation :: Map Text GenericParameterInformation -- Name ~> parameter info
  }
  deriving (Eq, Show)

data DataInformation = DataInformation
  { name :: QualifiedName,
    genericParameters :: GenericParameters,
    -- | The shape of constructor
    -- Ex)
    -- data foo(x: number) ~> {x: number}
    constructor :: NormalizedType
  }
  deriving (Eq, Show)

data RequestInformation = RequestInformation
  { name :: QualifiedName,
    genericParameters :: GenericParameters,
    request :: (NormalizedType, NormalizedType) -- (request parameter, request return type)
  }
  deriving (Eq, Show)

-- | A top-level agent / external / primitive / data / request declaration.
data ValueInformation = ValueInformation
  { name :: QualifiedName,
    genericParameters :: GenericParameters,
    valueType :: NormalizedType
  }
  deriving (Eq, Show)

-- | A type-synonym scheme: recursion is rejected by the env-build, so expansion terminates.
data SynonymInformation = SynonymInformation
  { name :: QualifiedName,
    genericParameters :: GenericParameters,
    definition :: NormalizedKindedType
  }
  deriving (Eq, Show)

-- | The declared parameters in declaration order, each paired with its name. The single place the
-- 'parameterNames' order and the 'parameterInformation' map are zipped back together, so consumers
-- that need ordered, named parameters (argument elaboration, id substitution) share one definition.
orderedParameters :: GenericParameters -> List (Text, GenericParameterInformation)
orderedParameters parameters =
  [(name, info) | name <- parameters.parameterNames, Just info <- [Map.lookup name parameters.parameterInformation]]

-- | The declared parameter names, in declaration order (the positional form for diagnostics / zips).
genericParameterNames :: GenericParameters -> List Text
genericParameterNames parameters = parameters.parameterNames

-- | The generic-id to parameter-name map. Variance inference keys a declaration's own generics by
-- name rather than by id (ids are only unique once paired with their module), so it reads occurrences
-- back through this.
namesByGenericId :: GenericParameters -> Map GenericId Text
namesByGenericId parameters = Map.fromList [(info.genericId, name) | (name, info) <- orderedParameters parameters]

-- | The generic-id to declared-kind map of a declaration's parameters. The elaborator wraps a generic
-- leaf at the kind looked up here, because a bare type-name reference no longer carries its kind (see
-- 'Katari.Data.Id.TypeResolution').
parameterKinds :: GenericParameters -> Map GenericId GenericKind
parameterKinds parameters = Map.fromList [(info.genericId, info.kind) | info <- Map.elems parameters.parameterInformation]
