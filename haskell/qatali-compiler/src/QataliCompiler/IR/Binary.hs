{-# OPTIONS_GHC -Wno-orphans #-}

{- | Binary serialization for the Qatali IR.

Uses "Data.Binary" with explicit opcode tags for 'Instr' and 'Terminator'
to ensure forward/backward compatibility — new constructors get new opcode
numbers appended at the end, and old numbers are never reused.

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

import           Data.Binary                   (Binary (..), decodeOrFail,
                                                encode, putWord8)
import qualified Data.ByteString.Lazy          as BL
import           Data.List.NonEmpty            (NonEmpty (..))
import qualified Data.List.NonEmpty            as NE
import           Data.Text                     (Text)
import           Data.Word                     (Word32, Word8)

import           QataliCompiler.IR.Instruction
import           QataliCompiler.IR.Module
import           QataliCompiler.IR.Types
import           QataliCompiler.Name           (ModuleName (..), Name (..),
                                                QualifiedName (..))

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
-- Binary instances for IR types (via Generic, stable shapes)

instance Binary NameTable
instance Binary HandleInfo
instance Binary SwitchCase
instance Binary Program
instance Binary Module
instance Binary NominalTypeDef
instance Binary IREffectDef
instance Binary Constant
instance Binary Function
instance Binary Block

-- ---------------------------------------------------------------------------
-- Instr: explicit opcode tags
--
-- IMPORTANT: When adding new instructions, append a new opcode number.
-- Never reuse or reorder existing opcode numbers.

instance Binary Instr where
    put instr = case instr of
        ILoadConst   d c       -> putWord8 0x01 >> put d >> put c
        ILoadNull    d         -> putWord8 0x02 >> put d
        IMove        d s       -> putWord8 0x03 >> put d >> put s
        IAddInt      d a b     -> putWord8 0x04 >> put d >> put a >> put b
        ISubInt      d a b     -> putWord8 0x05 >> put d >> put a >> put b
        IMulInt      d a b     -> putWord8 0x06 >> put d >> put a >> put b
        IDivInt      d a b     -> putWord8 0x07 >> put d >> put a >> put b
        IModInt      d a b     -> putWord8 0x08 >> put d >> put a >> put b
        INegInt      d a       -> putWord8 0x09 >> put d >> put a
        IAddFlt      d a b     -> putWord8 0x0A >> put d >> put a >> put b
        ISubFlt      d a b     -> putWord8 0x0B >> put d >> put a >> put b
        IMulFlt      d a b     -> putWord8 0x0C >> put d >> put a >> put b
        IDivFlt      d a b     -> putWord8 0x0D >> put d >> put a >> put b
        INegFlt      d a       -> putWord8 0x0E >> put d >> put a
        ICmpEq       d a b     -> putWord8 0x0F >> put d >> put a >> put b
        ICmpNe       d a b     -> putWord8 0x10 >> put d >> put a >> put b
        ICmpLt       d a b     -> putWord8 0x11 >> put d >> put a >> put b
        ICmpLe       d a b     -> putWord8 0x12 >> put d >> put a >> put b
        ICmpGt       d a b     -> putWord8 0x13 >> put d >> put a >> put b
        ICmpGe       d a b     -> putWord8 0x14 >> put d >> put a >> put b
        IAnd         d a b     -> putWord8 0x15 >> put d >> put a >> put b
        IOr          d a b     -> putWord8 0x16 >> put d >> put a >> put b
        INot         d a       -> putWord8 0x17 >> put d >> put a
        IConcat      d a b     -> putWord8 0x18 >> put d >> put a >> put b
        IConstruct   d t fs    -> putWord8 0x19 >> put d >> put t >> put fs
        IGetField    d s i     -> putWord8 0x1A >> put d >> put s >> put i
        IGetTag      d s       -> putWord8 0x1B >> put d >> put s
        INewArray    d es      -> putWord8 0x1C >> put d >> put es
        IArrGet      d a i     -> putWord8 0x1D >> put d >> put a >> put i
        IArrLen      d a       -> putWord8 0x1E >> put d >> put a
        IArrPush     d a v     -> putWord8 0x1F >> put d >> put a >> put v
        IArrConcat   d a b     -> putWord8 0x20 >> put d >> put a >> put b
        IArrSlice    d a f t   -> putWord8 0x21 >> put d >> put a >> put f >> put t
        IMakeClosure d f cs    -> putWord8 0x22 >> put d >> put f >> put cs
        IIntToFlt    d s       -> putWord8 0x23 >> put d >> put s
        IFltToInt    d s       -> putWord8 0x24 >> put d >> put s

    get = do
        tag <- get @Word8
        case tag of
            0x01 -> ILoadConst   <$> get <*> get
            0x02 -> ILoadNull    <$> get
            0x03 -> IMove        <$> get <*> get
            0x04 -> IAddInt      <$> get <*> get <*> get
            0x05 -> ISubInt      <$> get <*> get <*> get
            0x06 -> IMulInt      <$> get <*> get <*> get
            0x07 -> IDivInt      <$> get <*> get <*> get
            0x08 -> IModInt      <$> get <*> get <*> get
            0x09 -> INegInt      <$> get <*> get
            0x0A -> IAddFlt      <$> get <*> get <*> get
            0x0B -> ISubFlt      <$> get <*> get <*> get
            0x0C -> IMulFlt      <$> get <*> get <*> get
            0x0D -> IDivFlt      <$> get <*> get <*> get
            0x0E -> INegFlt      <$> get <*> get
            0x0F -> ICmpEq       <$> get <*> get <*> get
            0x10 -> ICmpNe       <$> get <*> get <*> get
            0x11 -> ICmpLt       <$> get <*> get <*> get
            0x12 -> ICmpLe       <$> get <*> get <*> get
            0x13 -> ICmpGt       <$> get <*> get <*> get
            0x14 -> ICmpGe       <$> get <*> get <*> get
            0x15 -> IAnd         <$> get <*> get <*> get
            0x16 -> IOr          <$> get <*> get <*> get
            0x17 -> INot         <$> get <*> get
            0x18 -> IConcat      <$> get <*> get <*> get
            0x19 -> IConstruct   <$> get <*> get <*> get
            0x1A -> IGetField    <$> get <*> get <*> get
            0x1B -> IGetTag      <$> get <*> get
            0x1C -> INewArray    <$> get <*> get
            0x1D -> IArrGet      <$> get <*> get <*> get
            0x1E -> IArrLen      <$> get <*> get
            0x1F -> IArrPush     <$> get <*> get <*> get
            0x20 -> IArrConcat   <$> get <*> get <*> get
            0x21 -> IArrSlice    <$> get <*> get <*> get <*> get
            0x22 -> IMakeClosure <$> get <*> get <*> get
            0x23 -> IIntToFlt    <$> get <*> get
            0x24 -> IFltToInt    <$> get <*> get
            _    -> fail ("Unknown Instr opcode: " <> show tag)

-- ---------------------------------------------------------------------------
-- Terminator: explicit opcode tags

instance Binary Terminator where
    put term = case term of
        TReturn        v           -> putWord8 0x01 >> put v
        TJump          b           -> putWord8 0x02 >> put b
        TBranch        c t f       -> putWord8 0x03 >> put c >> put t >> put f
        TSwitch        v cs d      -> putWord8 0x04 >> put v >> put cs >> put d
        TCall          d f as c    -> putWord8 0x05 >> put d >> put f >> put as >> put c
        TCallDirect    d f as c    -> putWord8 0x06 >> put d >> put f >> put as >> put c
        TTailCall      f as        -> putWord8 0x07 >> put f >> put as
        TTailCallDirect f as       -> putWord8 0x08 >> put f >> put as
        TPerform       d e as c    -> putWord8 0x09 >> put d >> put e >> put as >> put c
        THandle        hi          -> putWord8 0x0A >> put hi
        TContinue      k v hvs d c -> putWord8 0x0B >> put k >> put v >> put hvs >> put d >> put c
        TUnreachable               -> putWord8 0x0C
        TFfiCall       d mn fn as c -> putWord8 0x0D >> put d >> put mn >> put fn >> put as >> put c
        TParAll        d ts c      -> putWord8 0x0E >> put d >> put ts >> put c

    get = do
        tag <- get @Word8
        case tag of
            0x01 -> TReturn        <$> get
            0x02 -> TJump          <$> get
            0x03 -> TBranch        <$> get <*> get <*> get
            0x04 -> TSwitch        <$> get <*> get <*> get
            0x05 -> TCall          <$> get <*> get <*> get <*> get
            0x06 -> TCallDirect    <$> get <*> get <*> get <*> get
            0x07 -> TTailCall      <$> get <*> get
            0x08 -> TTailCallDirect <$> get <*> get
            0x09 -> TPerform       <$> get <*> get <*> get <*> get
            0x0A -> THandle        <$> get
            0x0B -> TContinue      <$> get <*> get <*> get <*> get <*> get
            0x0C -> pure TUnreachable
            0x0D -> TFfiCall       <$> get <*> get <*> get <*> get <*> get
            0x0E -> TParAll        <$> get <*> get <*> get
            _    -> fail ("Unknown Terminator opcode: " <> show tag)

-- ---------------------------------------------------------------------------
-- File format

-- | Magic bytes: @QATA@ in ASCII.
magicBytes :: BL.ByteString
magicBytes = BL.pack [0x51, 0x41, 0x54, 0x41]

-- | IR format version. Increment on breaking changes.
irVersion :: Word32
irVersion = 3

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
