module Katari.Data.Environment where

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.GenericKind (GenericKind)
import Katari.Data.Id (GenericId)
import Katari.Data.QualifiedName (QualifiedName)
import Katari.Data.Variance (Variance)

type DataEnvironment typeShape = Map QualifiedName (DataInfo typeShape)

type RequestEnvironment typeShape = Map QualifiedName (RequestInfo typeShape)

-- | Top-level callables that are neither nominal data constructors nor requests — @agent@,
-- @external agent@ and @primitive agent@ declarations. They are treated uniformly as a top-level
-- variable bound to an @agent@-typed value (its 'valueType' is the agent type), so the checker types
-- a reference / application to any of them through one lookup, including cross-module references.
type ValueEnvironment typeShape = Map QualifiedName (ValueInfo typeShape)

-- | Type synonyms (@type name[generics] = T@), collected and expanded by the global env-build so a
-- per-module checker can resolve a synonym defined in another module. The definition is kept as a
-- generic argument because a synonym is kind-agnostic: it may alias a type, an effect or an
-- attribute (see 'Katari.Data.AST.SyntacticTypeExpression').
type SynonymEnvironment argumentShape = Map QualifiedName (SynonymInfo argumentShape)

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

-- | A top-level agent / external / primitive, as a generic-scheme over an @agent@-typed value.
-- Mirrors 'DataInfo' / 'RequestInfo': 'genericParameters' carries the declaration's generics (by
-- name, with their id / kind), and 'valueType' is the agent type the name is bound to (e.g.
-- @agent {x: number} -> string@). Application instantiates the generics by name, so the per-module
-- id space of 'genericParameters' never escapes this scheme.
data ValueInfo typeShape = ValueInfo
  { name :: QualifiedName,
    genericParameters :: List GenericParameterInfo,
    valueType :: typeShape
  }
  deriving (Eq, Show)

-- | A type-synonym scheme: its generics and the (kind-agnostic) definition they abstract over.
-- Expansion substitutes the arguments by name into 'definition'; recursion is rejected by the
-- env-build, so expansion terminates.
data SynonymInfo argumentShape = SynonymInfo
  { name :: QualifiedName,
    genericParameters :: List GenericParameterInfo,
    definition :: argumentShape
  }
  deriving (Eq, Show)

-- | The declared parameter names, in declaration order (the positional form for diagnostics).
genericParameterNames :: List GenericParameterInfo -> List Text
genericParameterNames = map (.name)

-- | The parameter-name to generic-id map (used to build a constructor substitution).
genericIdsByName :: List GenericParameterInfo -> Map Text GenericId
genericIdsByName parameters = Map.fromList [(parameter.name, parameter.genericId) | parameter <- parameters]

-- | The parameter-name to variance map (used by the lattice and subtyping of generic arguments).
variancesByName :: List GenericParameterInfo -> Map Text Variance
variancesByName parameters = Map.fromList [(parameter.name, parameter.variance) | parameter <- parameters]
