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
import Katari.Data.NormalizedType (NormalizedKindedType, NormalizedObject, NormalizedType)
import Katari.Data.QualifiedName (QualifiedName)
import Katari.Data.Variance (Variance)

type DataEnvironment = Map QualifiedName DataInformation

type RequestEnvironment = Map QualifiedName RequestInformation

type ValueEnvironment = Map QualifiedName Scheme

type SynonymEnvironment = Map QualifiedName SynonymInformation

-- | One declared generic parameter of a data type or request. This is the single source of truth for a generic's bound
data GenericParameterInformation = GenericParameterInformation
  { genericId :: GenericId,
    kind :: GenericKind,
    variance :: Variance,
    -- | @literal name@ — call-site inference proposes a string literal argument's singleton type for
    -- this parameter instead of @string@. An unmarked parameter never binds a singleton implicitly.
    bindsLiteral :: Bool,
    -- | The declared @extends@ upper bound, normalized; 'Nothing' for an unbounded parameter
    upperBound :: Maybe NormalizedKindedType
  }
  deriving (Eq, Show)

-- | A declaration's generic parameters. 'parameterInformation' (name -> info) is the essential
-- representation — generics are keyed by name everywhere downstream (the normalized types, the IR).
-- 'parameterNames' is only the declaration order, needed to bind /positional/ application arguments
-- (@foo[int, string]@) to names at the AST boundary; nothing else should depend on it.
data GenericParameters = GenericParameters
  { parameterNames :: List Text,
    parameterInformation :: Map Text GenericParameterInformation
  }
  deriving (Eq, Show)

emptyGenericParameters :: GenericParameters
emptyGenericParameters = GenericParameters {parameterNames = [], parameterInformation = mempty}

-- | Re-key a by-name argument map to a by-id map through the parameter name↔id correspondence: each
-- declared parameter's id mapped to the argument supplied under its name (a name with no argument is
-- dropped). The single name→id bridge every instantiation site shares — a data / request application, a
-- synonym expansion, a value scheme.
reKeyByGenericId :: GenericParameters -> Map Text a -> Map GenericId a
reKeyByGenericId parameters arguments =
  Map.fromList
    [ (info.genericId, argument)
      | (name, info) <- Map.toList parameters.parameterInformation,
        Just argument <- [Map.lookup name arguments]
    ]

-- | The inverse of 'reKeyByGenericId': re-key a by-id substitution back to a by-name map (each declared
-- parameter's name mapped to the argument its id resolves to; an unresolved id is dropped). Shared by
-- the sites that present an inferred / explicit substitution by name — a handler's request arguments and
-- the Typed-AST instantiation record.
instantiationByName :: GenericParameters -> Map GenericId a -> Map Text a
instantiationByName parameters substitution =
  Map.fromList
    [ (name, argument)
      | (name, info) <- Map.toList parameters.parameterInformation,
        Just argument <- [Map.lookup info.genericId substitution]
    ]

-- | A value's type as carried in every environment (top-level values and locals alike): its
-- quantified generic parameters plus the type body, which references those generics by 'GenericId'.
-- A non-generic value has empty 'genericParameters'. Synthesis / checking work with bare
-- 'NormalizedType's (a scheme is instantiated at the reference site), so 'Scheme' appears only where
-- a value is stored, never as an expression's synthesized type.
data Scheme = Scheme
  { genericParameters :: GenericParameters,
    valueType :: NormalizedType
  }
  deriving (Eq, Show)

-- | A non-generic scheme over a bare type.
monoScheme :: NormalizedType -> Scheme
monoScheme bodyType = Scheme {genericParameters = emptyGenericParameters, valueType = bodyType}

data DataInformation = DataInformation
  { name :: QualifiedName,
    genericParameters :: GenericParameters,
    -- | The constructor's read shape — always an object (@data foo(x: number)@ ~> @{x: number}@), so
    -- a field read needs no shape check.
    constructor :: NormalizedObject
  }
  deriving (Eq, Show)

data RequestInformation = RequestInformation
  { name :: QualifiedName,
    genericParameters :: GenericParameters,
    parameterType :: NormalizedType,
    returnType :: NormalizedType,
    -- | A marker effect (@effect name[generics]@): an entry with NO operations. Markers live in the
    -- request environment on purpose — every effect-row mechanism (arity, bounds, variance, tails,
    -- overrides, subsumption) dispatches on the row's @QualifiedName -> arguments@ map, so a second
    -- row-entry kind would fork all of them; the flag is consulted only where a marker genuinely
    -- differs (a handler may not name one, and lowering drops it from the requests schema).
    marker :: Bool
  }
  deriving (Eq, Show)

-- | A type-synonym scheme: recursion is rejected by the env-build, so expansion terminates.
data SynonymInformation = SynonymInformation
  { name :: QualifiedName,
    genericParameters :: GenericParameters,
    definition :: NormalizedKindedType
  }
  deriving (Eq, Show)
