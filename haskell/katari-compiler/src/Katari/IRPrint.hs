module Katari.IRPrint
  ( printIRModule,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import Katari.IR
  ( AgentKind (..),
    ConstVal (..),
    IRForScope (..),
    IRHandleScope (..),
    IRModule (..),
    IRRequestDef (..),
    IRAgent (..),
    Instruction (..),
    NameTable (..),
  )

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
      "=== agents ===",
      T.intercalate "\n" (map (printAgent irm) (irmAgents irm))
    ]

-- ---------------------------------------------------------------------------
-- Constant pool
-- ---------------------------------------------------------------------------

printConsts :: [ConstVal] -> Text
printConsts cs = T.unlines (zipWith go [0 :: Int ..] cs)
  where
    go i c = "  [" <> T.pack (show i) <> "] " <> showConst c

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
-- Agent
-- ---------------------------------------------------------------------------

printAgent :: IRModule -> IRAgent -> Text
printAgent irm agent =
  T.unlines $
    [ "agent "
        <> iraName agent
        <> " [id="
        <> showId (iraId agent)
        <> ", kind="
        <> (case iraKind agent of UserDefined -> "user"; ParBranch -> "par")
        <> "]",
      "  params: " <> commaSep (map (vn nt) (iraParams agent)),
      "  body:"
    ]
      ++ printInstrs 4 irm (iraBody agent)
      ++ (if null (iraHandlers agent)
        then []
        else "  handlers:" : concatMap (printHandleScope irm) (iraHandlers agent))
      ++ (if null (iraForScopes agent)
        then []
        else "  for_scopes:" : concatMap (printForScope irm) (iraForScopes agent))
  where
    nt = irmNameTable irm

printHandleScope :: IRModule -> IRHandleScope -> [Text]
printHandleScope irm hb =
  [ "    handle["
      <> showId (irhId hb)
      <> "] states=["
      <> commaSep (map (vn nt) (irhStateVars hb))
      <> "]"
  ]
    ++ concatMap printReqCase (irhReqCases hb)
    ++ case irhThenClause hb of
      Nothing -> []
      Just (inputV, instrs) ->
        ("      then(" <> vn nt inputV <> "):") : printInstrs 8 irm instrs
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

printForScope :: IRModule -> IRForScope -> [Text]
printForScope irm fs =
  ("    for[" <> showId (irfsId fs) <> "]")
    : case irfsThen fs of
      Nothing -> []
      Just instrs ->
        "      then:" : printInstrs 8 irm instrs

printInstrs :: Int -> IRModule -> [Instruction] -> [Text]
printInstrs indent irm =
  zipWith
    ( \i instr ->
        T.replicate indent " " <> showId (fromIntegral (i :: Int)) <> ": " <> printInstr irm instr
    )
    [0 ..]

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
  IArrSlice v a s e -> vn nt v <> " = slice(" <> vn nt a <> ", " <> vn nt s <> ", " <> vn nt e <> ")"
  IAdd v a b -> vn nt v <> " = " <> vn nt a <> " + " <> vn nt b
  ISub v a b -> vn nt v <> " = " <> vn nt a <> " - " <> vn nt b
  IMul v a b -> vn nt v <> " = " <> vn nt a <> " * " <> vn nt b
  IDiv v a b -> vn nt v <> " = " <> vn nt a <> " / " <> vn nt b
  IMod v a b -> vn nt v <> " = " <> vn nt a <> " % " <> vn nt b
  INeg v a -> vn nt v <> " = -" <> vn nt a
  ICmpEq v a b -> vn nt v <> " = " <> vn nt a <> " == " <> vn nt b
  ICmpNe v a b -> vn nt v <> " = " <> vn nt a <> " != " <> vn nt b
  ICmpLt v a b -> vn nt v <> " = " <> vn nt a <> " < " <> vn nt b
  ICmpLe v a b -> vn nt v <> " = " <> vn nt a <> " <= " <> vn nt b
  ICmpGt v a b -> vn nt v <> " = " <> vn nt a <> " > " <> vn nt b
  ICmpGe v a b -> vn nt v <> " = " <> vn nt a <> " >= " <> vn nt b
  IAnd v a b -> vn nt v <> " = " <> vn nt a <> " && " <> vn nt b
  IOr v a b -> vn nt v <> " = " <> vn nt a <> " || " <> vn nt b
  INot v a -> vn nt v <> " = !" <> vn nt a
  IConcat v a b -> vn nt v <> " = " <> vn nt a <> " ++ " <> vn nt b
  IToString v a -> vn nt v <> " = to_string(" <> vn nt a <> ")"
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
      <> an nt tid
      <> "("
      <> commaSep (map (vn nt) args)
      <> ")"
  IPar v agents ->
    vn nt v
      <> " = par ["
      <> commaSep [an nt tid <> "(" <> commaSep (map (vn nt) args) <> ")" | (tid, args) <- agents]
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
  IContinue v hid upds ->
    "continue "
      <> vn nt v
      <> " hnd"
      <> showId hid
      <> (if null upds then "" else " {" <> commaSep ["[" <> showId i <> "] := " <> vn nt fv | (i, fv) <- upds] <> "}")
  IHandleBreak v hid -> "handle_break " <> vn nt v <> " hnd" <> showId hid
  IForBegin fid -> "for_begin for" <> showId fid
  IForEnd dst src fid ->
    vn nt dst <> " = for_end for" <> showId fid <> "(" <> vn nt src <> ")"
  IForContinue fid upds ->
    "for_continue for" <> showId fid <> " {" <> commaSep ["[" <> showId i <> "] := " <> vn nt fv | (i, fv) <- upds] <> "}"
  IForBreak v fid -> "for_break " <> vn nt v <> " for" <> showId fid

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Resolve a VarId to a human-readable name
vn :: NameTable -> Word32 -> Text
vn nt vid = case Map.lookup vid (ntVars nt) of
  Just n -> n <> "%" <> T.pack (show vid)
  Nothing -> "v" <> T.pack (show vid)

-- Resolve an AgentId to a name
an :: NameTable -> Word32 -> Text
an nt aid = case Map.lookup aid (ntAgents nt) of
  Just n -> n
  Nothing -> "agent" <> T.pack (show aid)

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
