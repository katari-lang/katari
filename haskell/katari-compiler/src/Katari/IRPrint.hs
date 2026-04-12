module Katari.IRPrint
  ( printIRModule,
  )
where

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
      "=== threads ===",
      T.intercalate "\n" (map (printThread irm) (irmThreads irm)),
      "",
      "=== handles ===",
      T.intercalate "\n" (map (printHandleDef irm) (irmHandles irm)),
      "",
      "=== for_loops ===",
      T.intercalate "\n" (map (printForDef irm) (irmFors irm)),
      "",
      "=== agents ===",
      T.intercalate "\n" (map printAgentDef (irmAgents irm))
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
-- Threads
-- ---------------------------------------------------------------------------

printThread :: IRModule -> IRThread -> Text
printThread irm t =
  T.unlines $
    [ "thread["
        <> showId (itId t)
        <> "] "
        <> showKind (itKind t)
        <> " params=("
        <> commaSep (map (vn nt) (itParams t))
        <> ")"
    ]
      ++ printInstrs 4 irm (itBody t)
  where
    nt = irmNameTable irm

showKind :: ThreadKind -> Text
showKind = \case
  TkFnBody -> "FN_BODY"
  TkBlock -> "BLOCK"
  TkHandlerTarget -> "HANDLER_TARGET"
  TkRequestHandler -> "REQUEST_HANDLER"
  TkHandleThen -> "HANDLE_THEN"
  TkForBody -> "FOR_BODY"
  TkForThen -> "FOR_THEN"

-- ---------------------------------------------------------------------------
-- Handle definitions
-- ---------------------------------------------------------------------------

printHandleDef :: IRModule -> IRHandleDef -> Text
printHandleDef irm hd =
  T.unlines $
    [ "handle["
        <> showId (ihdId hd)
        <> "] states=["
        <> commaSep (map (vn nt) (ihdStateVars hd))
        <> "] inits=["
        <> commaSep (map (vn nt) (ihdStateInits hd))
        <> "] body=thread["
        <> showId (ihdBody hd)
        <> "]"
        <> maybe "" (\tid -> " then=thread[" <> showId tid <> "]") (ihdThen hd)
    ]
      ++ map printReqCase (ihdReqCases hd)
  where
    nt = irmNameTable irm
    printReqCase (rid, tid) =
      "  req["
        <> showId rid
        <> "] "
        <> rn nt rid
        <> ": thread["
        <> showId tid
        <> "]"

-- ---------------------------------------------------------------------------
-- For definitions
-- ---------------------------------------------------------------------------

printForDef :: IRModule -> IRForDef -> Text
printForDef irm fd =
  "for["
    <> showId (ifdId fd)
    <> "] iters=["
    <> commaSep (map (vn nt) (ifdIterVars fd))
    <> "] arrays=["
    <> commaSep (map (vn nt) (ifdArrays fd))
    <> "] states=["
    <> commaSep (map (vn nt) (ifdStateVars fd))
    <> "] inits=["
    <> commaSep (map (vn nt) (ifdStateInits fd))
    <> "] body=thread["
    <> showId (ifdBody fd)
    <> "]"
    <> maybe "" (\tid -> " then=thread[" <> showId tid <> "]") (ifdThen fd)
  where
    nt = irmNameTable irm

-- ---------------------------------------------------------------------------
-- Agent definitions
-- ---------------------------------------------------------------------------

printAgentDef :: IRAgentDef -> Text
printAgentDef ad =
  "agent["
    <> showId (iadId ad)
    <> "] "
    <> iadName ad
    <> " entry=thread["
    <> showId (iadEntry ad)
    <> "]"

-- ---------------------------------------------------------------------------
-- Instructions
-- ---------------------------------------------------------------------------

printInstrs :: Int -> IRModule -> [Instruction] -> [Text]
printInstrs indent irm =
  zipWith
    ( \i instr ->
        T.replicate indent " " <> showId (fromIntegral (i :: Int)) <> ": " <> printInstr irm instr
    )
    [0 ..]

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
  IJump lbl -> "jump @" <> showId lbl
  IBranch c t f -> "branch " <> vn nt c <> " ? @" <> showId t <> " : @" <> showId f
  ISwitch v cases def ->
    "switch "
      <> vn nt v
      <> " {"
      <> commaSep [cv cs k <> " => @" <> showId lbl | (k, lbl) <- cases]
      <> ", default => @"
      <> showId def
      <> "}"
  IComplete v -> "complete " <> vn nt v
  IReturn v -> "return " <> vn nt v
  ICall v tid args ->
    vn nt v <> " = call " <> an nt tid <> "(" <> commaSep (map (vn nt) args) <> ")"
  IPar v tids ->
    vn nt v <> " = par [" <> commaSep (map (\tid -> "thread[" <> showId tid <> "]") tids) <> "]"
  IRequest v rid args ->
    vn nt v <> " = request " <> rn nt rid <> "(" <> commaSep (map (vn nt) args) <> ")"
  IHandle v hid ->
    vn nt v <> " = handle hnd" <> showId hid
  IContinue v upds ->
    "continue "
      <> vn nt v
      <> (if null upds then "" else " {" <> commaSep [vn nt sv <> " := " <> vn nt nv | (sv, nv) <- upds] <> "}")
  IHandleBreak v -> "handle_break " <> vn nt v
  IFor v fid ->
    vn nt v <> " = for for" <> showId fid
  IForContinue upds ->
    "for_continue"
      <> (if null upds then "" else " {" <> commaSep [vn nt sv <> " := " <> vn nt nv | (sv, nv) <- upds] <> "}")
  IForBreak v -> "for_break " <> vn nt v

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

vn :: NameTable -> Word32 -> Text
vn nt vid = case Map.lookup vid (ntVars nt) of
  Just n -> n <> "%" <> T.pack (show vid)
  Nothing -> "v" <> T.pack (show vid)

an :: NameTable -> Word32 -> Text
an nt aid = case Map.lookup aid (ntAgents nt) of
  Just n -> n
  Nothing -> "agent" <> T.pack (show aid)

rn :: NameTable -> Word32 -> Text
rn nt rid = case Map.lookup rid (ntRequests nt) of
  Just n -> n
  Nothing -> "req" <> T.pack (show rid)

cv :: [ConstVal] -> Word32 -> Text
cv cs i
  | fromIntegral i < length cs = showConst (cs !! fromIntegral i)
  | otherwise = "const[" <> T.pack (show i) <> "]"

showId :: Word32 -> Text
showId = T.pack . show

commaSep :: [Text] -> Text
commaSep = T.intercalate ", "
