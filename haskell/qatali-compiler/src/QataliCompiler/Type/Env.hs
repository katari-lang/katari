{- | Type environment (context) used during type checking.

Maps variable names to their types, and tracks type\/data\/effect definitions.
-}
module QataliCompiler.Type.Env (
    -- * Value environment
    TyEnv (..),
    empty,
    extend,
    extendMany,
    lookupType,
) where

import           Data.Map.Strict     (Map)
import qualified Data.Map.Strict     as Map
import           QataliCompiler.Name (Name)
import           QataliCompiler.Type.Type (Type)

-- | A typing environment mapping variable names to types.
newtype TyEnv = TyEnv { unTyEnv :: Map Name Type }
    deriving (Eq, Show)

-- | Empty environment.
empty :: TyEnv
empty = TyEnv Map.empty

-- | Extend the environment with a single binding.
extend :: Name -> Type -> TyEnv -> TyEnv
extend n t (TyEnv m) = TyEnv (Map.insert n t m)

-- | Extend the environment with multiple bindings.
extendMany :: [(Name, Type)] -> TyEnv -> TyEnv
extendMany xs env = foldr (uncurry extend) env xs

-- | Look up a name in the environment.
lookupType :: Name -> TyEnv -> Maybe Type
lookupType n (TyEnv m) = Map.lookup n m
