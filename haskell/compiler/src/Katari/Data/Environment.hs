module Katari.Data.Environment where

import Data.Map (Map)
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.Id (GenericId)
import Katari.Data.QualifiedName (QualifiedName)
import Katari.Data.Variant (Variance)

type DataEnvironment typeShape = Map QualifiedName (DataInfo typeShape)

type RequestEnvironment typeShape = Map QualifiedName (RequestInfo typeShape)

type GenericBoundEnvironment typeShape = Map GenericId typeShape

data DataInfo typeShape = DataInfo
  { name :: QualifiedName,
    genericParameter :: List Text,
    genericAssignment :: Map Text GenericId,
    variance :: Map Text Variance,
    -- | The shape of constructor
    -- Ex)
    -- data foo(x: number) ~> {x: number}
    -- data foo(...y: [number, string]) ~> tuple [number, string]
    constructor :: typeShape
  }
  deriving (Eq, Show)

data RequestInfo typeShape = RequestInfo
  { name :: QualifiedName,
    genericParameter :: List Text,
    genericAssignment :: Map Text GenericId,
    variance :: Map Text Variance,
    request :: (typeShape, typeShape) -- (request parameter, request return type)
  }
  deriving (Eq, Show)

modifyDataInfoTypeShape :: (a -> b) -> DataInfo a -> DataInfo b
modifyDataInfoTypeShape f dataInfo =
  dataInfo {constructor = f dataInfo.constructor}

modifyRequestInfoTypeShape :: (a -> b) -> RequestInfo a -> RequestInfo b
modifyRequestInfoTypeShape f requestInfo =
  let (requestParameter, requestReturnType) = requestInfo.request
   in requestInfo {request = (f requestParameter, f requestReturnType)}
