{- | Module-level IR structures for the Qatali bytecode.

A 'Program' is a collection of 'Module's, each containing nominal type
definitions, effect definitions, a constant pool, and compiled functions.
-}
module QataliCompiler.IR.Module (
    -- * Program
    Program (..),
    -- * Module
    Module (..),
    -- * Function
    Function (..),
    -- * Block
    Block (..),
    -- * Type and effect definitions
    NominalTypeDef (..),
    IREffectDef (..),
    -- * Constants
    Constant (..),
) where

import           Data.Text                  (Text)
import           Data.Word                  (Word16)
import           GHC.Generics               (Generic)

import           QataliCompiler.IR.Instruction
import           QataliCompiler.IR.Types
import           QataliCompiler.Name        (ModuleName)

-- | A complete program ready for execution.
data Program = Program
    { pModules :: ![Module]
    }
    deriving (Eq, Show, Generic)

-- | A single module.
data Module = Module
    { mName         :: !ModuleName
      -- ^ Module name (e.g. @MyApp.Core@).
    , mNameTable    :: !NameTable
      -- ^ ID → name mappings for debugging, persistence, and hot-swapping.
    , mNominalTypes :: ![NominalTypeDef]
      -- ^ Nominal type definitions used in this module.
    , mEffects      :: ![IREffectDef]
      -- ^ Effect definitions used in this module.
    , mConstants    :: ![Constant]
      -- ^ Constant pool. Indexed by 'ConstId' (0-based).
    , mFunctions    :: ![Function]
      -- ^ Functions defined in this module.
    , mEntryFunc    :: !(Maybe FuncId)
      -- ^ Optional entry point (the module's top-level init function).
    }
    deriving (Eq, Show, Generic)

-- | A nominal type definition (corresponds to a @data@ declaration).
data NominalTypeDef = NominalTypeDef
    { ntId         :: !TypeId
      -- ^ Global type tag.
    , ntFieldCount :: !Word16
      -- ^ Number of fields (positional).
    , ntFieldNames :: ![Text]
      -- ^ Field names (for debugging / pretty printing).
      -- Length should equal 'ntFieldCount'.
    }
    deriving (Eq, Show, Generic)

-- | An effect definition (corresponds to an @effect@ declaration).
data IREffectDef = IREffectDef
    { edId       :: !EffectId
      -- ^ Global effect identifier.
    , edArgCount :: !Word16
      -- ^ Number of arguments the effect takes.
    }
    deriving (Eq, Show, Generic)

-- | A constant value in the constant pool.
data Constant
    = CInt    !Integer
    | CFloat  !Double
    | CString !Text
    | CBool   !Bool
    | CNull
    deriving (Eq, Ord, Show, Generic)

-- | A function definition.
data Function = Function
    { fId         :: !FuncId
      -- ^ Global function identifier.
    , fParamCount :: !Word16
      -- ^ Number of parameters.
    , fParams     :: ![VarId]
      -- ^ Parameter variable IDs. Length should equal 'fParamCount'.
    , fBlocks     :: ![Block]
      -- ^ Basic blocks. The first block is the entry block.
    }
    deriving (Eq, Show, Generic)

-- | A basic block: a sequence of instructions followed by a terminator.
data Block = Block
    { bId         :: !BlockId
      -- ^ Block identifier (index within the function).
    , bInstrs     :: ![Instr]
      -- ^ Instructions (no control flow).
    , bTerminator :: !Terminator
      -- ^ How the block ends (control flow).
    }
    deriving (Eq, Show, Generic)
