module Katari.Data.Environment where

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.GenericKind (GenericKind)
import Katari.Data.Id (GenericId)
import Katari.Data.QualifiedName (QualifiedName)
import Katari.Data.Variant (Variance)

type DataEnvironment typeShape = Map QualifiedName (DataInfo typeShape)

type RequestEnvironment typeShape = Map QualifiedName (RequestInfo typeShape)

type GenericBoundEnvironment typeShape = Map GenericId typeShape

-- | One declared generic parameter of a data type or request. Everything keyed per parameter (its
-- id, kind, and variance) lives here in declaration order, so consumers never keep parallel
-- name-keyed maps in sync.
data GenericParameterInfo = GenericParameterInfo
  { name :: Text,
    genericId :: GenericId,
    kind :: GenericKind,
    variance :: Variance
  }
  deriving (Eq, Show)

data DataInfo typeShape = DataInfo
  { name :: QualifiedName,
    genericParameters :: List GenericParameterInfo,
    -- | The shape of constructor
    -- Ex)
    -- data foo(x: number) ~> {x: number}
    constructor :: typeShape
  }
  deriving (Eq, Show)

data RequestInfo typeShape = RequestInfo
  { name :: QualifiedName,
    genericParameters :: List GenericParameterInfo,
    request :: (typeShape, typeShape) -- (request parameter, request return type)
  }
  deriving (Eq, Show)

-- | The declared parameter names, in declaration order (the positional form for diagnostics).
genericParameterNames :: List GenericParameterInfo -> List Text
genericParameterNames parameters = (\parameter -> parameter.name) <$> parameters

-- | The parameter-name to generic-id map (used to build a constructor substitution).
genericIdsByName :: List GenericParameterInfo -> Map Text GenericId
genericIdsByName parameters = Map.fromList [(parameter.name, parameter.genericId) | parameter <- parameters]

-- | The parameter-name to variance map (used by the lattice and subtyping of generic arguments).
variancesByName :: List GenericParameterInfo -> Map Text Variance
variancesByName parameters = Map.fromList [(parameter.name, parameter.variance) | parameter <- parameters]

modifyDataInfoTypeShape :: (a -> b) -> DataInfo a -> DataInfo b
modifyDataInfoTypeShape f dataInfo =
  dataInfo {constructor = f dataInfo.constructor}

modifyRequestInfoTypeShape :: (a -> b) -> RequestInfo a -> RequestInfo b
modifyRequestInfoTypeShape f requestInfo =
  let (requestParameter, requestReturnType) = requestInfo.request
   in requestInfo {request = (f requestParameter, f requestReturnType)}
