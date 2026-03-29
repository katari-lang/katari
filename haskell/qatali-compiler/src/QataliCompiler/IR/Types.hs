{- | Identifier newtypes and name table for the Qatali IR.

All variables, functions, types, effects, and constants are referenced
by numeric IDs in the IR for compactness and fast execution.
A 'NameTable' maps these IDs back to human-readable names for
debugging, PostgreSQL persistence, and hot-swapping.
-}
module QataliCompiler.IR.Types (
    -- * Variable identifier
    VarId (..),
    -- * Block identifier
    BlockId (..),
    -- * Function identifier
    FuncId (..),
    -- * Nominal type tag
    TypeId (..),
    -- * Effect identifier
    EffectId (..),
    -- * Constant pool index
    ConstId (..),
    -- * Name table
    NameTable (..),
    emptyNameTable,
) where

import           Data.Map.Strict        (Map)
import qualified Data.Map.Strict        as Map
import           Data.Text              (Text)
import           Data.Word              (Word16, Word32)
import           GHC.Generics           (Generic)

import           QataliCompiler.Name    (Name, QualifiedName)

-- | A variable identifier within a function scope.
newtype VarId = VarId { unVarId :: Word32 }
    deriving (Eq, Ord, Show)
    deriving newtype (Enum)

-- | A basic block index within a function.
newtype BlockId = BlockId { unBlockId :: Word16 }
    deriving (Eq, Ord, Show)
    deriving newtype (Enum)

-- | A function identifier (globally unique within a program).
newtype FuncId = FuncId { unFuncId :: Word32 }
    deriving (Eq, Ord, Show)
    deriving newtype (Enum)

-- | A nominal type tag (globally unique within a program).
newtype TypeId = TypeId { unTypeId :: Word32 }
    deriving (Eq, Ord, Show)
    deriving newtype (Enum)

-- | An effect identifier (globally unique within a program).
newtype EffectId = EffectId { unEffectId :: Word32 }
    deriving (Eq, Ord, Show)
    deriving newtype (Enum)

-- | An index into the module's constant pool.
newtype ConstId = ConstId { unConstId :: Word32 }
    deriving (Eq, Ord, Show)
    deriving newtype (Enum)

-- | Maps numeric IDs back to human-readable names.
--
-- The name table is shipped alongside the IR bytecode but can be
-- stripped for production deployments. The runtime uses it for:
--
-- * __Hot-swapping__: look up @FuncId@ by @QualifiedName@ to replace
--   a running function definition.
-- * __PostgreSQL persistence__: convert @VarId@ to @Name@ when saving
--   execution state.
-- * __Debugging / monitoring__: provide human-readable identifiers.
data NameTable = NameTable
    { ntVars    :: !(Map VarId Name)
      -- ^ Variable ID → variable name.
    , ntFuncs   :: !(Map FuncId QualifiedName)
      -- ^ Function ID → qualified name (hot-swap key).
    , ntTypes   :: !(Map TypeId Text)
      -- ^ Type ID → type name.
    , ntEffects :: !(Map EffectId Text)
      -- ^ Effect ID → effect name.
    }
    deriving (Eq, Show, Generic)

-- | An empty name table.
emptyNameTable :: NameTable
emptyNameTable = NameTable Map.empty Map.empty Map.empty Map.empty
