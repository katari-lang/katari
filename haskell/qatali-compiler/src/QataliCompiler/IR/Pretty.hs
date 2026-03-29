{- | Pretty printing for the Qatali IR.

Uses the 'NameTable' to display human-readable variable and function names
alongside their numeric IDs.
-}
module QataliCompiler.IR.Pretty (
    prettyProgram,
    prettyModule,
    prettyFunction,
    prettyBlock,
    prettyInstr,
    prettyTerminator,
) where

import           Data.List.NonEmpty         (toList)
import qualified Data.Map.Strict            as Map
import           Prettyprinter

import           QataliCompiler.IR.Instruction
import           QataliCompiler.IR.Module
import           QataliCompiler.IR.Types
import           QataliCompiler.Name        (ModuleName (..), Name (..), QualifiedName (..))

-- ---------------------------------------------------------------------------
-- Helpers

prettyModName :: ModuleName -> Doc ann
prettyModName (ModuleName segs) = hcat (punctuate dot (map pretty (toList segs)))

-- | Show a VarId, annotated with its name from the table if available.
prettyVar :: NameTable -> VarId -> Doc ann
prettyVar nt v =
    let base = "%" <> pretty (unVarId v)
    in case Map.lookup v (ntVars nt) of
        Just (Name n) -> base <> "(" <> pretty n <> ")"
        Nothing       -> base

-- | Show a FuncId, annotated with its name from the table if available.
prettyFuncRef :: NameTable -> FuncId -> Doc ann
prettyFuncRef nt f =
    let base = "@" <> pretty (unFuncId f)
    in case Map.lookup f (ntFuncs nt) of
        Just qn -> base <> "(" <> prettyQName qn <> ")"
        Nothing -> base

prettyQName :: QualifiedName -> Doc ann
prettyQName (QualifiedName Nothing (Name n))  = pretty n
prettyQName (QualifiedName (Just m) (Name n)) = prettyModName m <> dot <> pretty n

prettyTypeRef :: NameTable -> TypeId -> Doc ann
prettyTypeRef nt t =
    let base = "t" <> pretty (unTypeId t)
    in case Map.lookup t (ntTypes nt) of
        Just n  -> base <> "(" <> pretty n <> ")"
        Nothing -> base

prettyEffRef :: NameTable -> EffectId -> Doc ann
prettyEffRef nt e =
    let base = "eff" <> pretty (unEffectId e)
    in case Map.lookup e (ntEffects nt) of
        Just n  -> base <> "(" <> pretty n <> ")"
        Nothing -> base

prettyBlockRef :: BlockId -> Doc ann
prettyBlockRef (BlockId b) = "block" <> pretty b

prettyConstRef :: ConstId -> Doc ann
prettyConstRef (ConstId c) = "c" <> pretty c

prettyVars :: NameTable -> [VarId] -> Doc ann
prettyVars nt vs = brackets (hsep (punctuate comma (map (prettyVar nt) vs)))

-- ---------------------------------------------------------------------------
-- Program / Module

prettyProgram :: Program -> Doc ann
prettyProgram prog =
    vsep (map prettyModule prog.pModules)

prettyModule :: Module -> Doc ann
prettyModule m =
    let nt = m.mNameTable
    in vsep
        [ "module" <+> prettyModName m.mName <+> lbrace
        , indent 2 $ vsep $
            -- Types
            [ prettyNominalType nt td | td <- m.mNominalTypes ]
            ++
            -- Effects
            [ prettyEffectDef nt ed | ed <- m.mEffects ]
            ++
            -- Constants
            (if null m.mConstants then []
             else [mempty, "constants" <+> lbrace
                  , indent 2 $ vsep
                      [ prettyConstRef (ConstId (fromIntegral i))
                        <> ":" <+> prettyConst c
                      | (i, c) <- zip [(0::Int)..] m.mConstants
                      ]
                  , rbrace])
            ++
            -- Functions
            [ prettyFunction nt f | f <- m.mFunctions ]
            ++
            -- Entry
            (case m.mEntryFunc of
                Nothing -> []
                Just fid -> [mempty, "entry" <+> prettyFuncRef nt fid])
        , rbrace
        ]

prettyNominalType :: NameTable -> NominalTypeDef -> Doc ann
prettyNominalType nt td =
    "type" <+> prettyTypeRef nt td.ntId
    <+> parens (pretty td.ntFieldCount <+> "fields:"
               <+> hsep (punctuate comma (map pretty td.ntFieldNames)))

prettyEffectDef :: NameTable -> IREffectDef -> Doc ann
prettyEffectDef nt ed =
    "effect" <+> prettyEffRef nt ed.edId
    <+> parens (pretty ed.edArgCount <+> "args")

prettyConst :: Constant -> Doc ann
prettyConst = \case
    CInt i    -> pretty i
    CFloat f  -> pretty f
    CString s -> dquotes (pretty s)
    CBool b   -> if b then "true" else "false"
    CNull     -> "null"

-- ---------------------------------------------------------------------------
-- Function / Block

prettyFunction :: NameTable -> Function -> Doc ann
prettyFunction nt f =
    vsep
        [ "func" <+> prettyFuncRef nt f.fId
          <+> parens (hsep (punctuate comma (map (prettyVar nt) f.fParams)))
          <+> lbrace
        , indent 2 $ vsep
            [ prettyBlock nt b | b <- f.fBlocks ]
        , rbrace
        ]

prettyBlock :: NameTable -> Block -> Doc ann
prettyBlock nt b =
    vsep $
        [ prettyBlockRef b.bId <> colon ]
        ++ [ indent 2 (prettyInstr nt i) | i <- b.bInstrs ]
        ++ [ indent 2 (prettyTerminator nt b.bTerminator) ]

-- ---------------------------------------------------------------------------
-- Instructions

prettyInstr :: NameTable -> Instr -> Doc ann
prettyInstr nt = \case
    ILoadConst d c  -> pv d <+> "=" <+> "load_const" <+> prettyConstRef c
    ILoadNull d     -> pv d <+> "=" <+> "null"
    IMove d s       -> pv d <+> "=" <+> pv s

    IAddInt d a b   -> binOp d "add_int" a b
    ISubInt d a b   -> binOp d "sub_int" a b
    IMulInt d a b   -> binOp d "mul_int" a b
    IDivInt d a b   -> binOp d "div_int" a b
    IModInt d a b   -> binOp d "mod_int" a b
    INegInt d a     -> unOp  d "neg_int" a

    IAddFlt d a b   -> binOp d "add_flt" a b
    ISubFlt d a b   -> binOp d "sub_flt" a b
    IMulFlt d a b   -> binOp d "mul_flt" a b
    IDivFlt d a b   -> binOp d "div_flt" a b
    INegFlt d a     -> unOp  d "neg_flt" a

    ICmpEq d a b    -> binOp d "cmp_eq" a b
    ICmpNe d a b    -> binOp d "cmp_ne" a b
    ICmpLt d a b    -> binOp d "cmp_lt" a b
    ICmpLe d a b    -> binOp d "cmp_le" a b
    ICmpGt d a b    -> binOp d "cmp_gt" a b
    ICmpGe d a b    -> binOp d "cmp_ge" a b

    IAnd d a b      -> binOp d "and" a b
    IOr  d a b      -> binOp d "or"  a b
    INot d a        -> unOp  d "not" a

    IConcat d a b   -> binOp d "concat" a b

    IConstruct d tid fs ->
        pv d <+> "=" <+> "construct" <+> prettyTypeRef nt tid <+> prettyVars nt fs
    IGetField d s idx ->
        pv d <+> "=" <+> pv s <> "." <> pretty idx
    IGetTag d s ->
        pv d <+> "=" <+> "tag" <> parens (pv s)

    INewArray d es  -> pv d <+> "=" <+> "new_array" <+> prettyVars nt es
    IArrGet d a i   -> pv d <+> "=" <+> pv a <> brackets (pv i)
    IArrLen d a     -> pv d <+> "=" <+> "arr_len" <> parens (pv a)
    IArrPush d a v  -> pv d <+> "=" <+> "arr_push" <> parens (pv a <> comma <+> pv v)
    IArrConcat d a b -> binOp d "arr_concat" a b

    INewTuple d es  -> pv d <+> "=" <+> "new_tuple" <+> prettyVars nt es
    ITupGet d t idx -> pv d <+> "=" <+> pv t <> "." <> pretty idx

    IMakeClosure d fid caps ->
        pv d <+> "=" <+> "closure" <+> prettyFuncRef nt fid <+> prettyVars nt caps

    IIntToFlt d s   -> unOp d "int_to_flt" s
    IFltToInt d s   -> unOp d "flt_to_int" s
  where
    pv :: VarId -> Doc ann
    pv = prettyVar nt

    binOp :: VarId -> Doc ann -> VarId -> VarId -> Doc ann
    binOp d op a b = pv d <+> "=" <+> op <+> pv a <+> pv b

    unOp :: VarId -> Doc ann -> VarId -> Doc ann
    unOp d op a = pv d <+> "=" <+> op <+> pv a

-- ---------------------------------------------------------------------------
-- Terminators

prettyTerminator :: NameTable -> Terminator -> Doc ann
prettyTerminator nt = \case
    TReturn v ->
        "return" <+> pv v

    TJump bid ->
        "jump" <+> prettyBlockRef bid

    TBranch c t f ->
        "branch" <+> pv c <+> prettyBlockRef t <+> prettyBlockRef f

    TSwitch s cases def ->
        vsep $ ["switch" <+> pv s <+> lbrace]
            ++ [ indent 2 $ prettyCase sc <+> "->" <+> prettyBlockRef bid
               | (sc, bid) <- cases
               ]
            ++ [ indent 2 $ "_ ->" <+> prettyBlockRef def ]
            ++ [ rbrace ]

    TCall d f args cont ->
        "call" <+> pv d <+> "=" <+> pv f
        <> tupled (map pv args) <+> "->" <+> prettyBlockRef cont

    TCallDirect d fid args cont ->
        "call_direct" <+> pv d <+> "=" <+> prettyFuncRef nt fid
        <> tupled (map pv args) <+> "->" <+> prettyBlockRef cont

    TTailCall f args ->
        "tail_call" <+> pv f <> tupled (map pv args)

    TTailCallDirect fid args ->
        "tail_call_direct" <+> prettyFuncRef nt fid <> tupled (map pv args)

    TPerform d eid args cont ->
        "perform" <+> pv d <+> "=" <+> prettyEffRef nt eid
        <> tupled (map pv args) <+> "->" <+> prettyBlockRef cont

    THandle hi ->
        vsep
            [ "handle" <+> lbrace
            , indent 2 $ vsep
                [ "body:" <+> pv hi.hBody
                , vsep [ "on" <+> prettyEffRef nt eid <+> "->" <+> prettyBlockRef hd.hdBlock
                         <+> parens ("args:" <+> prettyVars nt hd.hdArgs
                                    <> comma <+> "cont:" <+> pv hd.hdCont)
                       | (eid, hd) <- hi.hHandlers
                       ]
                , case hi.hReturnDef of
                    Nothing -> mempty
                    Just rd -> "return" <+> pv rd.rdArg <+> "->" <+> prettyBlockRef rd.rdBlock
                , "result:" <+> pv hi.hResultVar <+> "->" <+> prettyBlockRef hi.hContBlock
                ]
            , rbrace
            ]

    TContinue k v d cont ->
        "continue" <+> pv d <+> "=" <+> pv k <+> pv v
        <+> "->" <+> prettyBlockRef cont

    THandleRet v ->
        "handle_ret" <+> pv v

    TUnreachable ->
        "unreachable"
  where
    pv :: VarId -> Doc ann
    pv = prettyVar nt

    prettyCase :: SwitchCase -> Doc ann
    prettyCase = \case
        CaseTag tid  -> prettyTypeRef nt tid
        CaseInt i    -> pretty i
        CaseStr s    -> dquotes (pretty s)
        CaseBool b   -> if b then "true" else "false"
