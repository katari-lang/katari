module Katari.Emit
  ( emitModule
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BB
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word8, Word32, Word64)
import Data.Bits (shiftR, (.&.), (.|.))
import Data.List (foldl')

import Katari.IR

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

emitModule :: IRModule -> ByteString
emitModule m = BS.toStrict (BB.toLazyByteString builder)
  where
    builder = mconcat
      [ header
      , emitText (irmName m)
      , emitVec emitConst (irmConsts m)
      , emitVec emitRequestDef (irmRequests m)
      , emitVec emitTask (irmTasks m)
      ]

-- ---------------------------------------------------------------------------
-- Header: "KTRI" + version 0x00 0x01
-- ---------------------------------------------------------------------------

header :: BB.Builder
header = BB.byteString (BS.pack [0x4b, 0x54, 0x52, 0x49, 0x00, 0x01])
-- "KTRI" = 0x4b 0x54 0x52 0x49

-- ---------------------------------------------------------------------------
-- LEB128 unsigned
-- ---------------------------------------------------------------------------

leb128 :: Word32 -> BB.Builder
leb128 0 = BB.word8 0
leb128 n = go n
  where
    go 0 = mempty
    go v =
      let b    = fromIntegral (v .&. 0x7f) :: Word8
          rest = v `shiftR` 7
      in if rest == 0
         then BB.word8 b
         else BB.word8 (b .|. 0x80) <> go rest

leb128_64 :: Word64 -> BB.Builder
leb128_64 0 = BB.word8 0
leb128_64 n = go n
  where
    go 0 = mempty
    go v =
      let b    = fromIntegral (v .&. 0x7f) :: Word8
          rest = v `shiftR` 7
      in if rest == 0
         then BB.word8 b
         else BB.word8 (b .|. 0x80) <> go rest

-- Integer: signed LEB128
sleb128 :: Integer -> BB.Builder
sleb128 n = go n
  where
    go v =
      let b    = fromIntegral (v .&. 0x7f) :: Word8
          rest = v `shiftR` 7
          done = (rest == 0 && (b .&. 0x40) == 0) ||
                 (rest == -1 && (b .&. 0x40) /= 0)
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
emitConst CVNull     = BB.word8 0x00
emitConst (CVBool b) = BB.word8 0x01 <> BB.word8 (if b then 1 else 0)
emitConst (CVInt  i) = BB.word8 0x02 <> sleb128 i
emitConst (CVNum  n) = BB.word8 0x03 <> BB.doubleLE n
emitConst (CVStr  s) = BB.word8 0x04 <> emitText s

-- ---------------------------------------------------------------------------
-- Request definition
-- ---------------------------------------------------------------------------

emitRequestDef :: IRRequestDef -> BB.Builder
emitRequestDef rd =
  leb128 (irReqId rd) <>
  emitText (irReqName rd) <>
  case irReqFrom rd of
    Nothing -> BB.word8 0
    Just f  -> BB.word8 1 <> emitText f

-- ---------------------------------------------------------------------------
-- Task
-- ---------------------------------------------------------------------------

emitTask :: IRTask -> BB.Builder
emitTask t =
  leb128 (irTaskId t) <>
  emitText (irTaskName t) <>
  emitVec (leb128) (irTaskParams t) <>
  emitVec emitInstr (irTaskBody t) <>
  emitVec emitHandleBlock (irTaskHandlers t)

-- ---------------------------------------------------------------------------
-- Handle block
-- ---------------------------------------------------------------------------

emitHandleBlock :: IRHandleBlock -> BB.Builder
emitHandleBlock hb =
  leb128 (irhId hb) <>
  emitVec leb128 (irhStateVars hb) <>
  emitVec emitReqCase (irhReqCases hb) <>
  case irhReturnCase hb of
    Nothing    -> BB.word8 0
    Just instrs -> BB.word8 1 <> emitVec emitInstr instrs

emitReqCase :: (RequestId, [Instruction]) -> BB.Builder
emitReqCase (rid, instrs) = leb128 rid <> emitVec emitInstr instrs

-- ---------------------------------------------------------------------------
-- Instructions with opcodes
-- ---------------------------------------------------------------------------

emitInstr :: Instruction -> BB.Builder
emitInstr (ILoadConst v c)         = op 0x01 <> leb128 v <> leb128 c
emitInstr (ILoadNull  v)           = op 0x02 <> leb128 v
emitInstr (IMove      v1 v2)       = op 0x03 <> leb128 v1 <> leb128 v2
-- Object
emitInstr (INewObject v fields)    = op 0x10 <> leb128 v <>
                                      emitVec (\(c,fv) -> leb128 c <> leb128 fv) fields
emitInstr (IGetField  v o c)       = op 0x11 <> leb128 v <> leb128 o <> leb128 c
emitInstr (ISetField  o v c sv)    = op 0x12 <> leb128 o <> leb128 v <> leb128 c <> leb128 sv
emitInstr (IHasField  v o c)       = op 0x13 <> leb128 v <> leb128 o <> leb128 c
-- Array
emitInstr (INewArray  v elems)     = op 0x20 <> leb128 v <> emitVec leb128 elems
emitInstr (IArrGet    v a i)       = op 0x21 <> leb128 v <> leb128 a <> leb128 i
emitInstr (IArrLen    v a)         = op 0x22 <> leb128 v <> leb128 a
emitInstr (IArrPush   v a e)       = op 0x23 <> leb128 v <> leb128 a <> leb128 e
emitInstr (IArrConcat v a b)       = op 0x24 <> leb128 v <> leb128 a <> leb128 b
emitInstr (IArrSlice  v a i j)     = op 0x25 <> leb128 v <> leb128 a <> leb128 i <> leb128 j
-- Int arithmetic
emitInstr (IAddInt v l r)          = op 0x30 <> leb128 v <> leb128 l <> leb128 r
emitInstr (ISubInt v l r)          = op 0x31 <> leb128 v <> leb128 l <> leb128 r
emitInstr (IMulInt v l r)          = op 0x32 <> leb128 v <> leb128 l <> leb128 r
emitInstr (IModInt v l r)          = op 0x33 <> leb128 v <> leb128 l <> leb128 r
emitInstr (INegInt v s)            = op 0x34 <> leb128 v <> leb128 s
-- Float arithmetic
emitInstr (IAddFlt v l r)          = op 0x40 <> leb128 v <> leb128 l <> leb128 r
emitInstr (ISubFlt v l r)          = op 0x41 <> leb128 v <> leb128 l <> leb128 r
emitInstr (IMulFlt v l r)          = op 0x42 <> leb128 v <> leb128 l <> leb128 r
emitInstr (IDivFlt v l r)          = op 0x43 <> leb128 v <> leb128 l <> leb128 r
emitInstr (INegFlt v s)            = op 0x44 <> leb128 v <> leb128 s
emitInstr (IDiv    v l r)          = op 0x45 <> leb128 v <> leb128 l <> leb128 r
-- Compare
emitInstr (ICmpEq v l r)           = op 0x50 <> leb128 v <> leb128 l <> leb128 r
emitInstr (ICmpNe v l r)           = op 0x51 <> leb128 v <> leb128 l <> leb128 r
emitInstr (ICmpLt v l r)           = op 0x52 <> leb128 v <> leb128 l <> leb128 r
emitInstr (ICmpLe v l r)           = op 0x53 <> leb128 v <> leb128 l <> leb128 r
emitInstr (ICmpGt v l r)           = op 0x54 <> leb128 v <> leb128 l <> leb128 r
emitInstr (ICmpGe v l r)           = op 0x55 <> leb128 v <> leb128 l <> leb128 r
-- Logical
emitInstr (IAnd v l r)             = op 0x60 <> leb128 v <> leb128 l <> leb128 r
emitInstr (IOr  v l r)             = op 0x61 <> leb128 v <> leb128 l <> leb128 r
emitInstr (INot v s)               = op 0x62 <> leb128 v <> leb128 s
-- String / conversion
emitInstr (IStrConcat v l r)       = op 0x70 <> leb128 v <> leb128 l <> leb128 r
emitInstr (IToString  v s)         = op 0x71 <> leb128 v <> leb128 s
emitInstr (IIntToFlt  v s)         = op 0x72 <> leb128 v <> leb128 s
emitInstr (ITypeOf    v s)         = op 0x73 <> leb128 v <> leb128 s
-- Control
emitInstr (IJump   t)              = op 0x80 <> leb128 t
emitInstr (IBranch v t f)          = op 0x81 <> leb128 v <> leb128 t <> leb128 f
emitInstr (ISwitch v cases def)    = op 0x82 <> leb128 v <>
                                      emitVec (\(c,t) -> leb128 c <> leb128 t) cases <>
                                      leb128 def
emitInstr (IReturn v)              = op 0x83 <> leb128 v
-- Agent
emitInstr (ICall    v tid args)    = op 0x90 <> leb128 v <> leb128 tid <> emitVec leb128 args
emitInstr (IPar     v branches)    = op 0x91 <> leb128 v <>
                                      emitVec (\(tid,args) -> leb128 tid <> emitVec leb128 args) branches
emitInstr (IRequest v rid args)    = op 0x92 <> leb128 v <> leb128 rid <> emitVec leb128 args
-- Handle
emitInstr (IHandleBegin hid)       = op 0xa0 <> leb128 hid
emitInstr (IHandleEnd   hid)       = op 0xa1 <> leb128 hid
emitInstr (IReply v hid upds)      = op 0xa2 <> leb128 v <> leb128 hid <>
                                      emitVec (\(si,sv) -> leb128 si <> leb128 sv) upds
emitInstr (IBreak v hid)           = op 0xa3 <> leb128 v <> leb128 hid
-- For
emitInstr (INext upds)             = op 0xb0 <>
                                      emitVec (\(si,sv) -> leb128 si <> leb128 sv) upds
emitInstr (IForBreak v)            = op 0xb1 <> leb128 v

op :: Word8 -> BB.Builder
op = BB.word8
