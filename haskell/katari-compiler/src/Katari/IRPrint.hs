module Katari.IRPrint
  ( printIRModule,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import Katari.IR

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

printIRModule :: IRModule -> Text
printIRModule irm =
  T.intercalate
    "\n"
    [ "module: " <> irmName irm,
      "",
      "=== consts ===",
      printConsts (irmConsts irm),
      "",
      "=== requests ===",
      printRequests (irmRequests irm),
      "",
      "=== tasks ===",
      T.intercalate "\n" (map (printTask irm) (irmTasks irm))
    ]

-- ---------------------------------------------------------------------------
-- Constant pool
-- ---------------------------------------------------------------------------

printConsts :: [ConstVal] -> Text
printConsts cs = T.unlines (zipWith go [0 :: Int ..] cs)
  where
    go i cv = "  [" <> T.pack (show i) <> "] " <> showConst cv

showConst :: ConstVal -> Text
showConst = \case
  CVNull -> "null"
  CVBool b -> if b then "true" else "false"
  CVInt i -> T.pack (show i)
  CVNum d -> T.pack (show d)
  CVStr s -> "\"" <> s <> "\""

-- ---------------------------------------------------------------------------
-- Request definitions
-- ---------------------------------------------------------------------------

printRequests :: [IRRequestDef] -> Text
printRequests rs = T.unlines (map go rs)
  where
    go r =
      "  ["
        <> T.pack (show (irReqId r))
        <> "] "
        <> irReqName r
        <> maybe "" (\f -> " (from: " <> f <> ")") (irReqFrom r)

-- ---------------------------------------------------------------------------
-- Task
-- ---------------------------------------------------------------------------

printTask :: IRModule -> IRTask -> Text
printTask irm task =
  T.unlines $
    [ "task " <> irTaskName task <> " [id=" <> showId (irTaskId task) <> "]",
      "  params: " <> commaSep (map (vn nt) (irTaskParams task)),
      "  body:"
    ]
      ++ printInstrs 4 irm (irTaskBody task)
      ++ if null (irTaskHandlers task)
        then []
        else ["  handlers:"] ++ concatMap (printHandleBlock irm) (irTaskHandlers task)
  where
    nt = irmNameTable irm

printHandleBlock :: IRModule -> IRHandleBlock -> [Text]
printHandleBlock irm hb =
  [ "    handle["
      <> showId (irhId hb)
      <> "] states=["
      <> commaSep (map (vn nt) (irhStateVars hb))
      <> "]"
  ]
    ++ concatMap printReqCase (irhReqCases hb)
    ++ case irhReturnCase hb of
      Nothing -> []
      Just (inputV, instrs) ->
        ("      return(" <> vn nt inputV <> "):") : printInstrs 8 irm instrs
  where
    nt = irmNameTable irm
    printReqCase (rid, argVs, instrs) =
      ( "      request["
          <> showId rid
          <> "] "
          <> rn nt rid
          <> "("
          <> commaSep (map (vn nt) argVs)
          <> "):"
      )
        : printInstrs 8 irm instrs

printInstrs :: Int -> IRModule -> [Instruction] -> [Text]
printInstrs indent irm instrs =
  zipWith
    ( \i instr ->
        T.replicate indent " " <> showId (fromIntegral (i :: Int)) <> ": " <> printInstr irm instr
    )
    [0 ..]
    instrs

-- ---------------------------------------------------------------------------
-- Instructions
-- ---------------------------------------------------------------------------

printInstr :: IRModule -> Instruction -> Text
printInstr irm instr =
  let nt = irmNameTable irm
      cs = irmConsts irm
   in printI nt cs instr

printI :: NameTable -> [ConstVal] -> Instruction -> Text
printI nt cs = \case
  ILoadConst v c -> vn nt v <> " = " <> cv cs c
  ILoadNull v -> vn nt v <> " = null"
  IMove d s -> vn nt d <> " = " <> vn nt s
  INewObject v fs -> vn nt v <> " = {" <> commaSep [cv cs k <> ": " <> vn nt fv | (k, fv) <- fs] <> "}"
  IGetField v o c -> vn nt v <> " = " <> vn nt o <> "." <> cv cs c
  ISetField o _ c fv -> vn nt o <> "." <> cv cs c <> " = " <> vn nt fv
  IHasField v o c -> vn nt v <> " = has_field(" <> vn nt o <> ", " <> cv cs c <> ")"
  INewArray v es -> vn nt v <> " = [" <> commaSep (map (vn nt) es) <> "]"
  IArrGet v a i -> vn nt v <> " = " <> vn nt a <> "[" <> vn nt i <> "]"
  IArrLen v a -> vn nt v <> " = len(" <> vn nt a <> ")"
  IArrPush v a e -> vn nt v <> " = push(" <> vn nt a <> ", " <> vn nt e <> ")"
  IArrConcat v a b -> vn nt v <> " = concat(" <> vn nt a <> ", " <> vn nt b <> ")"
  IArrSlice v a s e -> vn nt v <> " = slice(" <> vn nt a <> ", " <> vn nt s <> ", " <> vn nt e <> ")"
  IAddInt v a b -> vn nt v <> " = " <> vn nt a <> " +i " <> vn nt b
  ISubInt v a b -> vn nt v <> " = " <> vn nt a <> " -i " <> vn nt b
  IMulInt v a b -> vn nt v <> " = " <> vn nt a <> " *i " <> vn nt b
  IModInt v a b -> vn nt v <> " = " <> vn nt a <> " %i " <> vn nt b
  INegInt v a -> vn nt v <> " = -i" <> vn nt a
  IAddFlt v a b -> vn nt v <> " = " <> vn nt a <> " +f " <> vn nt b
  ISubFlt v a b -> vn nt v <> " = " <> vn nt a <> " -f " <> vn nt b
  IMulFlt v a b -> vn nt v <> " = " <> vn nt a <> " *f " <> vn nt b
  IDivFlt v a b -> vn nt v <> " = " <> vn nt a <> " /f " <> vn nt b
  INegFlt v a -> vn nt v <> " = -f" <> vn nt a
  IDiv v a b -> vn nt v <> " = " <> vn nt a <> " / " <> vn nt b
  ICmpEq v a b -> vn nt v <> " = " <> vn nt a <> " == " <> vn nt b
  ICmpNe v a b -> vn nt v <> " = " <> vn nt a <> " != " <> vn nt b
  ICmpLt v a b -> vn nt v <> " = " <> vn nt a <> " < " <> vn nt b
  ICmpLe v a b -> vn nt v <> " = " <> vn nt a <> " <= " <> vn nt b
  ICmpGt v a b -> vn nt v <> " = " <> vn nt a <> " > " <> vn nt b
  ICmpGe v a b -> vn nt v <> " = " <> vn nt a <> " >= " <> vn nt b
  IAnd v a b -> vn nt v <> " = " <> vn nt a <> " && " <> vn nt b
  IOr v a b -> vn nt v <> " = " <> vn nt a <> " || " <> vn nt b
  INot v a -> vn nt v <> " = !" <> vn nt a
  IStrConcat v a b -> vn nt v <> " = " <> vn nt a <> " ++ " <> vn nt b
  IToString v a -> vn nt v <> " = to_string(" <> vn nt a <> ")"
  IIntToFlt v a -> vn nt v <> " = int_to_flt(" <> vn nt a <> ")"
  ITypeOf v a -> vn nt v <> " = typeof(" <> vn nt a <> ")"
  IJump lbl -> "jump " <> showId lbl
  IBranch c t f -> "branch " <> vn nt c <> " ? @" <> showId t <> " : @" <> showId f
  ISwitch v cases def ->
    "switch "
      <> vn nt v
      <> " {"
      <> commaSep [cv cs k <> " => @" <> showId lbl | (k, lbl) <- cases]
      <> ", default => @"
      <> showId def
      <> "}"
  IReturn v -> "return " <> vn nt v
  ICall v tid args ->
    vn nt v
      <> " = call "
      <> tn nt tid
      <> "("
      <> commaSep (map (vn nt) args)
      <> ")"
  IPar v tasks ->
    vn nt v
      <> " = par ["
      <> commaSep [tn nt tid <> "(" <> commaSep (map (vn nt) args) <> ")" | (tid, args) <- tasks]
      <> "]"
  IRequest v rid args ->
    vn nt v
      <> " = request "
      <> rn nt rid
      <> "("
      <> commaSep (map (vn nt) args)
      <> ")"
  IHandleBegin hid -> "handle_begin hnd" <> showId hid
  IHandleEnd dst src hid ->
    vn nt dst <> " = handle_end hnd" <> showId hid <> "(" <> vn nt src <> ")"
  IReply v hid upds ->
    "reply "
      <> vn nt v
      <> " hnd"
      <> showId hid
      <> (if null upds then "" else " {" <> commaSep ["[" <> showId i <> "] := " <> vn nt fv | (i, fv) <- upds] <> "}")
  IBreak v hid -> "break " <> vn nt v <> " hnd" <> showId hid
  INext upds ->
    "next {" <> commaSep ["[" <> showId i <> "] := " <> vn nt fv | (i, fv) <- upds] <> "}"
  IForBreak v -> "for_break " <> vn nt v

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Resolve a VarId to a human-readable name
vn :: NameTable -> Word32 -> Text
vn nt vid = case Map.lookup vid (ntVars nt) of
  Just n -> n <> "%" <> T.pack (show vid)
  Nothing -> "v" <> T.pack (show vid)

-- Resolve a TaskId to a name
tn :: NameTable -> Word32 -> Text
tn nt tid = case Map.lookup tid (ntTasks nt) of
  Just n -> n
  Nothing -> "task" <> T.pack (show tid)

-- Resolve a RequestId to a name
rn :: NameTable -> Word32 -> Text
rn nt rid = case Map.lookup rid (ntRequests nt) of
  Just n -> n
  Nothing -> "req" <> T.pack (show rid)

-- Show a const value inline (from const pool by index)
cv :: [ConstVal] -> Word32 -> Text
cv cs i
  | fromIntegral i < length cs = showConst (cs !! fromIntegral i)
  | otherwise = "const[" <> T.pack (show i) <> "]"

showId :: Word32 -> Text
showId = T.pack . show

commaSep :: [Text] -> Text
commaSep = T.intercalate ", "
