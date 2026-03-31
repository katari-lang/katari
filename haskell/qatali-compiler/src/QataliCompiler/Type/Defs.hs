{- | Type definitions registry.

Holds the environment of all type\/data\/effect declarations and
variance lookup helpers.
-}
module QataliCompiler.Type.Defs (
    TypeDefs (..),
    DataDef (..),
    DataKind (..),
    TypeSynDef (..),
    EffectDef (..),
    TraitDef (..),
    ImplDef (..),
    ModuleInterface (..),
    emptyTypeDefs,
    emptyModuleInterface,
    mergeTypeDefs,
    getVariancesDef,
    getEffectVariancesDef,
) where

import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map

import           QataliCompiler.Name        (Name, ModuleName)
import           QataliCompiler.Type.Type

-- ---------------------------------------------------------------------------
-- Type definitions environment

-- | Whether a data type is a record (field access allowed) or tuple (positional only).
data DataKind = DataRecord | DataTuple
    deriving (Eq, Show)

-- | A data type definition (name + variance per param + bound per param).
data DataDef = DataDef
    { ddKind       :: !DataKind
    -- ^ Record or tuple
    , ddParamNames :: ![Name]
    -- ^ Type parameter names (for substitution)
    , ddParams     :: ![DataTypeParam]
    -- ^ One per type argument; variance only
    , ddBounds     :: ![Bound]
    -- ^ Bound for each type argument (parallel to ddParams)
    , ddFields     :: ![(Name, Type)]
    -- ^ Constructor fields
    }
    deriving (Show)

-- | A type synonym definition.
data TypeSynDef = TypeSynDef
    { tsParams :: ![TypeParam]
    , tsBody   :: !Type
    }
    deriving (Show)

-- | An effect definition.
data EffectDef = EffectDef
    { edParamNames :: ![Name]
    -- ^ Type parameter names (for substitution in handlers)
    , edParams     :: ![DataTypeParam]
    , edBounds     :: ![Bound]
    , edFields     :: ![(Name, Type)]
    , edReturnTy   :: !Type
    }
    deriving (Show)

-- | A trait definition (like a type class): name + params + fields + return type.
data TraitDef = TraitDef
    { trParamNames :: ![Name]
    , trParams     :: ![DataTypeParam]
    , trBounds     :: ![Bound]
    , trFields     :: ![(Name, Type)]
    , trReturnTy   :: !Type
    }
    deriving (Show)

-- | An impl mapping: a function implements a trait for given type arguments.
data ImplDef = ImplDef
    { idFnName    :: !Name
    , idTraitName :: !Name
    , idTypeArgs  :: ![Type]
    }
    deriving (Show)

-- | All type\/data\/effect definitions in scope.
data TypeDefs = TypeDefs
    { tdData    :: !(Map Name DataDef)
    , tdTypes   :: !(Map Name TypeSynDef)
    , tdEffects :: !(Map Name EffectDef)
    , tdTraits  :: !(Map Name TraitDef)
    , tdImpls   :: ![ImplDef]
    }
    deriving (Show)

emptyTypeDefs :: TypeDefs
emptyTypeDefs = TypeDefs Map.empty Map.empty Map.empty Map.empty []

mergeTypeDefs :: TypeDefs -> TypeDefs -> TypeDefs
mergeTypeDefs a b = TypeDefs
    { tdData    = tdData    a `Map.union` tdData    b
    , tdTypes   = tdTypes   a `Map.union` tdTypes   b
    , tdEffects = tdEffects a `Map.union` tdEffects b
    , tdTraits  = tdTraits  a `Map.union` tdTraits  b
    , tdImpls   = tdImpls   a <>           tdImpls  b
    }

-- | The exported interface of a compiled module.
data ModuleInterface = ModuleInterface
    { miModuleName :: !ModuleName
    , miTypeDefs   :: !TypeDefs          -- ^ exported type/data/effect defs
    , miValues     :: !(Map Name Type)   -- ^ exported value bindings (pub only)
    }
    deriving (Show)

emptyModuleInterface :: ModuleName -> ModuleInterface
emptyModuleInterface mn = ModuleInterface mn emptyTypeDefs Map.empty

-- ---------------------------------------------------------------------------
-- Variance lookups

-- | Get variance list for a data type's parameters.
-- Invariant: the name must be a known data type with matching arity.
getVariancesDef :: TypeDefs -> Name -> Int -> [Variance]
getVariancesDef defs name len = case Map.lookup name (tdData defs) of
    Just dd | length (ddParams dd) == len -> map dtpVariance (ddParams dd)
    _ -> error $ "getVariancesDef: unknown data type or arity mismatch: " ++ show name

-- | Get variance list for an effect's type parameters.
-- Invariant: the name must be a known effect with matching arity.
getEffectVariancesDef :: TypeDefs -> Name -> Int -> [Variance]
getEffectVariancesDef defs name len = case Map.lookup name (tdEffects defs) of
    Just ed | length (edParams ed) == len -> map dtpVariance (edParams ed)
    _ -> error $ "getEffectVariancesDef: unknown effect or arity mismatch: " ++ show name
