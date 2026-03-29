{-# OPTIONS_GHC -Wno-orphans #-}

{- | Binary serialization for the Qatali IR.

Uses "Data.Binary" (a GHC boot library) with @Generic@-derived instances.
The file format wraps a 'Program' in a header with magic bytes and a version.

Orphan 'Binary' instances for 'Name', 'ModuleName', and
'QualifiedName' are defined here.
-}
module QataliCompiler.IR.Binary (
    -- * File format
    magicBytes,
    irVersion,
    -- * Encoding / decoding
    encodeProgram,
    decodeProgram,
) where

import           Data.Binary            (Binary (..), decodeOrFail, encode)
import qualified Data.ByteString.Lazy   as BL
import           Data.List.NonEmpty     (NonEmpty (..))
import qualified Data.List.NonEmpty     as NE
import           Data.Text              (Text)
import           Data.Word              (Word32)

import           QataliCompiler.IR.Instruction
import           QataliCompiler.IR.Module
import           QataliCompiler.IR.Types
import           QataliCompiler.Name    (ModuleName (..), Name (..), QualifiedName (..))

-- ---------------------------------------------------------------------------
-- Orphan Binary instances for name types

instance Binary Name where
    put (Name t) = put t
    get = Name <$> get

instance Binary ModuleName where
    put (ModuleName segs) = put (NE.toList segs)
    get = do
        xs <- get @[Text]
        case xs of
            []     -> fail "ModuleName: empty segment list"
            (h:tl) -> pure (ModuleName (h :| tl))

instance Binary QualifiedName where
    put (QualifiedName mmod n) = put mmod >> put n
    get = QualifiedName <$> get <*> get

-- ---------------------------------------------------------------------------
-- Binary instances for IR identifier newtypes

instance Binary VarId where
    put (VarId w) = put w
    get = VarId <$> get

instance Binary BlockId where
    put (BlockId w) = put w
    get = BlockId <$> get

instance Binary FuncId where
    put (FuncId w) = put w
    get = FuncId <$> get

instance Binary TypeId where
    put (TypeId w) = put w
    get = TypeId <$> get

instance Binary EffectId where
    put (EffectId w) = put w
    get = EffectId <$> get

instance Binary ConstId where
    put (ConstId w) = put w
    get = ConstId <$> get

-- ---------------------------------------------------------------------------
-- Binary instances for IR types (via Generic)

instance Binary NameTable
instance Binary Instr
instance Binary Terminator
instance Binary SwitchCase
instance Binary HandleInfo
instance Binary HandlerDef
instance Binary ReturnDef
instance Binary Program
instance Binary Module
instance Binary NominalTypeDef
instance Binary IREffectDef
instance Binary Constant
instance Binary Function
instance Binary Block

-- ---------------------------------------------------------------------------
-- File format

-- | Magic bytes: @QATA@ in ASCII.
magicBytes :: BL.ByteString
magicBytes = BL.pack [0x51, 0x41, 0x54, 0x41]

-- | IR format version. Increment on breaking changes.
irVersion :: Word32
irVersion = 1

-- | Encode a 'Program' to a lazy 'BL.ByteString' with a file header.
encodeProgram :: Program -> BL.ByteString
encodeProgram prog =
    magicBytes <> encode irVersion <> encode prog

-- | Decode a 'Program' from a lazy 'BL.ByteString'.
-- Returns @Left@ on any error (bad magic, wrong version, decode failure).
decodeProgram :: BL.ByteString -> Either String Program
decodeProgram bs = do
    let (magic, rest1) = BL.splitAt 4 bs
    if magic /= magicBytes
        then Left "Invalid magic bytes: not a Qatali IR file"
        else case decodeOrFail rest1 of
            Left (_, _, err) ->
                Left ("Failed to decode version: " <> err)
            Right (rest2, _, ver)
                | ver /= irVersion ->
                    Left ("Unsupported IR version: " <> show (ver :: Word32)
                          <> " (expected " <> show irVersion <> ")")
                | otherwise ->
                    case decodeOrFail rest2 of
                        Left (_, _, err) ->
                            Left ("Failed to decode program: " <> err)
                        Right (_, _, prog) ->
                            Right prog
