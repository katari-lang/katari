module Katari.Emit
  ( emitModule,
  )
where

import Data.Bits (shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as BB
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Word (Word32, Word8)
import Katari.IR
  ( ConstVal (..),
    IRAgentDef (..),
    IRForDef (..),
    IRHandleDef (..),
    IRModule (..),
    IRRequestDef (..),
    IRThread (..),
    Instruction (..),
    ThreadKind (..),
  )

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

emitModule :: IRModule -> ByteString
emitModule m = BS.toStrict (BB.toLazyByteString builder)
  where
    builder =
      mconcat
        [ header,
          emitText (irmName m),
          emitVec emitConst (irmConsts m),
          emitVec emitRequestDef (irmRequests m),
          emitVec emitThread (irmThreads m),
          emitVec emitHandleDef (irmHandles m),
          emitVec emitForDef (irmFors m),
          emitVec emitAgentDef (irmAgents m)
        ]

-- ---------------------------------------------------------------------------
-- Header: "KTRI" + version 0x00 0x02
-- ---------------------------------------------------------------------------

header :: BB.Builder
header = BB.byteString (BS.pack [0x4b, 0x54, 0x52, 0x49, 0x00, 0x02])

-- ---------------------------------------------------------------------------
-- LEB128 unsigned
-- ---------------------------------------------------------------------------

leb128 :: Word32 -> BB.Builder
leb128 n
  | n == 0 = BB.word8 0
  | otherwise = go n
  where
    go v
      | v == 0 = mempty
      | otherwise =
          let b = fromIntegral (v .&. 0x7f) :: Word8
              rest = v `shiftR` 7
           in if rest == 0
                then BB.word8 b
                else BB.word8 (b .|. 0x80) <> go rest

-- Integer: signed LEB128
sleb128 :: Integer -> BB.Builder
sleb128 = go
  where
    go v =
      let b = fromIntegral (v .&. 0x7f) :: Word8
          rest = v `shiftR` 7
          done =
            (rest == 0 && (b .&. 0x40) == 0)
              || (rest == -1 && (b .&. 0x40) /= 0)
       in if done
            then BB.word8 b
            else BB.word8 (b .|. 0x80) <> go rest

-- ---------------------------------------------------------------------------
-- Text encoding: LEB128(len) + UTF-8
-- ---------------------------------------------------------------------------

emitText :: Text -> BB.Builder
emitText t =
  let bs = TE.encodeUtf8 t
   in leb128 (fromIntegral (BS.length bs)) <> BB.byteString bs

-- ---------------------------------------------------------------------------
-- Vector: LEB128(count) + items
-- ---------------------------------------------------------------------------

emitVec :: (a -> BB.Builder) -> [a] -> BB.Builder
emitVec f xs = leb128 (fromIntegral (length xs)) <> foldMap f xs

-- ---------------------------------------------------------------------------
-- Constant pool
-- ---------------------------------------------------------------------------

emitConst :: ConstVal -> BB.Builder
emitConst = \case
  CVNull -> BB.word8 0x00
  CVBool b -> BB.word8 0x01 <> BB.word8 (if b then 1 else 0)
  CVInt i -> BB.word8 0x02 <> sleb128 i
  CVNum n -> BB.word8 0x03 <> BB.doubleLE n
  CVStr s -> BB.word8 0x04 <> emitText s

-- ---------------------------------------------------------------------------
-- Request definition
-- ---------------------------------------------------------------------------

emitRequestDef :: IRRequestDef -> BB.Builder
emitRequestDef rd =
  leb128 (irReqId rd)
    <> emitText (irReqName rd)
    <> case irReqFrom rd of
      Nothing -> BB.word8 0
      Just f -> BB.word8 1 <> emitText f

-- ---------------------------------------------------------------------------
-- Thread
-- ---------------------------------------------------------------------------

emitThread :: IRThread -> BB.Builder
emitThread t =
  leb128 (itId t)
    <> BB.word8 (emitThreadKind (itKind t))
    <> emitVec leb128 (itParams t)
    <> emitVec emitInstr (itBody t)

emitThreadKind :: ThreadKind -> Word8
emitThreadKind = \case
  TkFnBody -> 0
  TkBlock -> 1
  TkHandlerTarget -> 2
  TkRequestHandler -> 3
  TkHandleThen -> 4
  TkForBody -> 5
  TkForThen -> 6

-- ---------------------------------------------------------------------------
-- Handle definition
-- ---------------------------------------------------------------------------

emitHandleDef :: IRHandleDef -> BB.Builder
emitHandleDef hd =
  leb128 (ihdId hd)
    <> emitVec leb128 (ihdStateVars hd)
    <> emitVec leb128 (ihdStateInits hd)
    <> leb128 (ihdBody hd)
    <> emitVec emitReqCase (ihdReqCases hd)
    <> emitMaybe leb128 (ihdThen hd)

emitReqCase :: (Word32, Word32) -> BB.Builder
emitReqCase (rid, tid) = leb128 rid <> leb128 tid

-- ---------------------------------------------------------------------------
-- For definition
-- ---------------------------------------------------------------------------

emitForDef :: IRForDef -> BB.Builder
emitForDef fd =
  leb128 (ifdId fd)
    <> emitVec leb128 (ifdIterVars fd)
    <> emitVec leb128 (ifdArrays fd)
    <> emitVec leb128 (ifdStateVars fd)
    <> emitVec leb128 (ifdStateInits fd)
    <> leb128 (ifdBody fd)
    <> emitMaybe leb128 (ifdThen fd)

-- ---------------------------------------------------------------------------
-- Agent definition
-- ---------------------------------------------------------------------------

emitAgentDef :: IRAgentDef -> BB.Builder
emitAgentDef ad =
  leb128 (iadId ad)
    <> emitText (iadName ad)
    <> leb128 (iadEntry ad)

-- ---------------------------------------------------------------------------
-- Maybe encoding: 0 = Nothing, 1 + value = Just
-- ---------------------------------------------------------------------------

emitMaybe :: (a -> BB.Builder) -> Maybe a -> BB.Builder
emitMaybe _ Nothing = BB.word8 0
emitMaybe f (Just x) = BB.word8 1 <> f x

-- ---------------------------------------------------------------------------
-- Instructions with opcodes
-- ---------------------------------------------------------------------------

emitInstr :: Instruction -> BB.Builder
emitInstr = \case
  ILoadConst v c -> op 0x01 <> leb128 v <> leb128 c
  ILoadNull v -> op 0x02 <> leb128 v
  IMove v1 v2 -> op 0x03 <> leb128 v1 <> leb128 v2
  -- Object
  INewObject v fields ->
    op 0x10
      <> leb128 v
      <> emitVec (\(c, fv) -> leb128 c <> leb128 fv) fields
  IGetField v o c -> op 0x11 <> leb128 v <> leb128 o <> leb128 c
  ISetField o v c sv -> op 0x12 <> leb128 o <> leb128 v <> leb128 c <> leb128 sv
  IHasField v o c -> op 0x13 <> leb128 v <> leb128 o <> leb128 c
  -- Array
  INewArray v elems -> op 0x20 <> leb128 v <> emitVec leb128 elems
  IArrGet v a i -> op 0x21 <> leb128 v <> leb128 a <> leb128 i
  IArrLen v a -> op 0x22 <> leb128 v <> leb128 a
  IArrPush v a e -> op 0x23 <> leb128 v <> leb128 a <> leb128 e
  IArrSlice v a i j -> op 0x25 <> leb128 v <> leb128 a <> leb128 i <> leb128 j
  -- Arithmetic
  IAdd v l r -> op 0x30 <> leb128 v <> leb128 l <> leb128 r
  ISub v l r -> op 0x31 <> leb128 v <> leb128 l <> leb128 r
  IMul v l r -> op 0x32 <> leb128 v <> leb128 l <> leb128 r
  IDiv v l r -> op 0x33 <> leb128 v <> leb128 l <> leb128 r
  IMod v l r -> op 0x34 <> leb128 v <> leb128 l <> leb128 r
  INeg v s -> op 0x35 <> leb128 v <> leb128 s
  -- Compare
  ICmpEq v l r -> op 0x50 <> leb128 v <> leb128 l <> leb128 r
  ICmpNe v l r -> op 0x51 <> leb128 v <> leb128 l <> leb128 r
  ICmpLt v l r -> op 0x52 <> leb128 v <> leb128 l <> leb128 r
  ICmpLe v l r -> op 0x53 <> leb128 v <> leb128 l <> leb128 r
  ICmpGt v l r -> op 0x54 <> leb128 v <> leb128 l <> leb128 r
  ICmpGe v l r -> op 0x55 <> leb128 v <> leb128 l <> leb128 r
  -- Logical
  IAnd v l r -> op 0x60 <> leb128 v <> leb128 l <> leb128 r
  IOr v l r -> op 0x61 <> leb128 v <> leb128 l <> leb128 r
  INot v s -> op 0x62 <> leb128 v <> leb128 s
  -- String/array concat, conversion
  IConcat v l r -> op 0x70 <> leb128 v <> leb128 l <> leb128 r
  IToString v s -> op 0x71 <> leb128 v <> leb128 s
  ITypeOf v s -> op 0x73 <> leb128 v <> leb128 s
  -- Control
  IJump t -> op 0x80 <> leb128 t
  IBranch v t f -> op 0x81 <> leb128 v <> leb128 t <> leb128 f
  ISwitch v cases def ->
    op 0x82
      <> leb128 v
      <> emitVec (\(c, t) -> leb128 c <> leb128 t) cases
      <> leb128 def
  IComplete v -> op 0x84 <> leb128 v
  IReturn v -> op 0x83 <> leb128 v
  -- Agent
  ICall v tid args -> op 0x90 <> leb128 v <> leb128 tid <> emitVec leb128 args
  IPar v tids -> op 0x91 <> leb128 v <> emitVec leb128 tids
  IRequest v rid args -> op 0x92 <> leb128 v <> leb128 rid <> emitVec leb128 args
  -- Handle
  IHandle v hid -> op 0xa0 <> leb128 v <> leb128 hid
  IContinue v upds ->
    op 0xa2
      <> leb128 v
      <> emitVec (\(sv, nv) -> leb128 sv <> leb128 nv) upds
  IHandleBreak v -> op 0xa3 <> leb128 v
  -- For
  IFor v fid -> op 0xb2 <> leb128 v <> leb128 fid
  IForContinue upds ->
    op 0xb0
      <> emitVec (\(sv, nv) -> leb128 sv <> leb128 nv) upds
  IForBreak v -> op 0xb1 <> leb128 v

op :: Word8 -> BB.Builder
op = BB.word8
