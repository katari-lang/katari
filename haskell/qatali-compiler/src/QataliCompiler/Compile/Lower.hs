{- | Lowering pass: AST (SrcSpan) → Qatali IR.

Translates the parsed AST into the register-based, basic-block IR.
Type information is used only for choosing Int vs Float arithmetic
(via SimpleType tracking). The type checker has already validated correctness.
-}
module QataliCompiler.Compile.Lower (
    lowerModule,
) where

import           Control.Monad              (forM, forM_, foldM, when)
import           Control.Monad.Reader       (ReaderT (..), asks, local, runReaderT)
import           Control.Monad.State.Strict (StateT (..), gets, modify', runStateT)
import           Data.Foldable              (foldlM)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (mapMaybe)
import qualified Data.Set                   as Set
import           Data.Text                  (Text)
import           Data.Word                  (Word16, Word32)

import           QataliCompiler.Diagnostic  (Diagnostic, mkError)
import           QataliCompiler.IR.Instruction
import           QataliCompiler.IR.Module   (Block (..), Constant (..), Function (..),
                                              IREffectDef (..), Module (..), NominalTypeDef (..),
                                              Program (..))
import           QataliCompiler.IR.Types
import           QataliCompiler.Name        (ModuleName, Name (..), QualifiedName (..),
                                              unqualify)
import           QataliCompiler.SrcLoc      (SrcSpan (..), noSpan)
import qualified QataliCompiler.Syntax.AST  as AST
import           QataliCompiler.Syntax.Literal (Literal (..))
import           QataliCompiler.Type.Defs      (DataDef (..), TypeDefs (..))

-- =========================================================================
-- SimpleType
-- =========================================================================

data SimpleType = STInt | STFloat | STString | STBool | STNull | STUnknown
    deriving (Eq)

-- =========================================================================
-- Lowering monad
-- =========================================================================

data LowerEnv = LowerEnv
    { leModuleName   :: !ModuleName
    , leTypeDefs     :: !TypeDefs
    , leLocals       :: !(Map Name VarId)
    , leEffectIds    :: !(Map Name EffectId)
    , leDataIds      :: !(Map Name TypeId)
    , leFuncNames    :: !(Map Name FuncId)
    , leContinuation :: !(Maybe VarId)
    }

data SavedBlockState = SavedBlockState
    { sbsCurrentBlockId :: !BlockId
    , sbsCurrentInstrs  :: ![Instr]
    , sbsBlocks         :: ![Block]
    , sbsNextBlock      :: !Word16
    }

data LowerState = LowerState
    { lsNextVar        :: !Word32
    , lsNextFunc       :: !Word32
    , lsNextType       :: !Word32
    , lsNextEffect     :: !Word32
    , lsNextConst      :: !Word32
    , lsNextBlock      :: !Word16
    , lsConstants      :: ![Constant]
    , lsConstMap       :: !(Map Constant ConstId)
    , lsNameTable      :: !NameTable
    , lsCurrentBlockId :: !BlockId
    , lsCurrentInstrs  :: ![Instr]
    , lsBlocks         :: ![Block]
    , lsFunctions      :: ![Function]
    , lsNominalTypes   :: ![NominalTypeDef]
    , lsEffectDefs     :: ![IREffectDef]
    , lsVarTypes       :: !(Map VarId SimpleType)
    }

type LowerM = ReaderT LowerEnv (StateT LowerState (Either [Diagnostic]))

lowerError :: SrcSpan -> Text -> LowerM a
lowerError sp msg = do
    _ <- pure ()  -- force monadic context
    ReaderT $ \_ -> StateT $ \_ -> Left [mkError sp msg]

-- =========================================================================
-- Fresh ID generators
-- =========================================================================

freshVar :: LowerM VarId
freshVar = do
    n <- gets lsNextVar
    modify' (\s -> s { lsNextVar = n + 1 })
    pure (VarId n)

freshNamedVar :: Name -> SimpleType -> LowerM VarId
freshNamedVar name st = do
    v <- freshVar
    registerVarName v name
    setVarType v st
    pure v

freshBlock :: LowerM BlockId
freshBlock = do
    n <- gets lsNextBlock
    modify' (\s -> s { lsNextBlock = n + 1 })
    pure (BlockId n)

freshFunc :: LowerM FuncId
freshFunc = do
    n <- gets lsNextFunc
    modify' (\s -> s { lsNextFunc = n + 1 })
    pure (FuncId n)


-- =========================================================================
-- Constants
-- =========================================================================

addConstant :: Constant -> LowerM ConstId
addConstant c = do
    m <- gets lsConstMap
    case Map.lookup c m of
        Just cid -> pure cid
        Nothing -> do
            cid <- ConstId <$> gets lsNextConst
            modify' (\s -> s
                { lsNextConst = lsNextConst s + 1
                , lsConstants = c : lsConstants s
                , lsConstMap  = Map.insert c cid m
                })
            pure cid

-- =========================================================================
-- Instruction emission & block management
-- =========================================================================

emitInstr :: Instr -> LowerM ()
emitInstr i = modify' (\s -> s { lsCurrentInstrs = i : lsCurrentInstrs s })

finishBlock :: Terminator -> BlockId -> LowerM ()
finishBlock term nextId = do
    bid    <- gets lsCurrentBlockId
    instrs <- gets lsCurrentInstrs
    let block = Block bid (reverse instrs) term
    modify' (\s -> s
        { lsBlocks         = block : lsBlocks s
        , lsCurrentBlockId = nextId
        , lsCurrentInstrs  = []
        })

finishBlockFinal :: Terminator -> LowerM ()
finishBlockFinal term = do
    bid    <- gets lsCurrentBlockId
    instrs <- gets lsCurrentInstrs
    let block = Block bid (reverse instrs) term
    modify' (\s -> s
        { lsBlocks        = block : lsBlocks s
        , lsCurrentInstrs = []
        })

-- =========================================================================
-- Block state save/restore (for nested functions)
-- =========================================================================

saveBlockState :: LowerM SavedBlockState
saveBlockState = SavedBlockState
    <$> gets lsCurrentBlockId
    <*> gets lsCurrentInstrs
    <*> gets lsBlocks
    <*> gets lsNextBlock

restoreBlockState :: SavedBlockState -> LowerM ()
restoreBlockState sbs = modify' (\s -> s
    { lsCurrentBlockId = sbsCurrentBlockId sbs
    , lsCurrentInstrs  = sbsCurrentInstrs sbs
    , lsBlocks         = sbsBlocks sbs
    , lsNextBlock      = sbsNextBlock sbs
    })

startFreshBlocks :: LowerM ()
startFreshBlocks = modify' (\s -> s
    { lsNextBlock      = 1
    , lsCurrentBlockId = BlockId 0
    , lsCurrentInstrs  = []
    , lsBlocks         = []
    })

collectBlocks :: LowerM [Block]
collectBlocks = reverse <$> gets lsBlocks

-- =========================================================================
-- Name table registration
-- =========================================================================

registerVarName :: VarId -> Name -> LowerM ()
registerVarName v name = modify' (\s -> s
    { lsNameTable = let nt = lsNameTable s
                    in nt { ntVars = Map.insert v name (ntVars nt) }
    })


-- =========================================================================
-- Variable type tracking
-- =========================================================================

setVarType :: VarId -> SimpleType -> LowerM ()
setVarType v st = modify' (\s -> s { lsVarTypes = Map.insert v st (lsVarTypes s) })

getVarType :: VarId -> LowerM SimpleType
getVarType v = Map.findWithDefault STUnknown v <$> gets lsVarTypes

-- =========================================================================
-- Local variable management
-- =========================================================================

withLocals :: [(Name, VarId)] -> LowerM a -> LowerM a
withLocals bindings = local (\env -> env
    { leLocals = foldr (\(n, v) m -> Map.insert n v m) (leLocals env) bindings
    })

lookupLocalOrError :: SrcSpan -> Name -> LowerM VarId
lookupLocalOrError sp name = do
    mv <- asks (Map.lookup name . leLocals)
    case mv of
        Just v  -> pure v
        Nothing -> lowerError sp ("unbound variable: " <> unName name)

-- =========================================================================
-- SimpleType helpers
-- =========================================================================

resolveTyExprSimple :: AST.TyExpr SrcSpan -> SimpleType
resolveTyExprSimple = \case
    AST.TyCon _ qn -> resolveQN qn
    AST.TyVar _ (Name "integer") -> STInt
    AST.TyVar _ (Name "number")  -> STFloat
    AST.TyVar _ (Name "string")  -> STString
    AST.TyVar _ (Name "boolean") -> STBool
    AST.TyVar _ (Name "null")    -> STNull
    _ -> STUnknown
  where
    resolveQN (QualifiedName _ (Name "integer")) = STInt
    resolveQN (QualifiedName _ (Name "number"))  = STFloat
    resolveQN (QualifiedName _ (Name "string"))  = STString
    resolveQN (QualifiedName _ (Name "boolean")) = STBool
    resolveQN (QualifiedName _ (Name "null"))    = STNull
    resolveQN _ = STUnknown

litSimpleType :: Literal -> SimpleType
litSimpleType = \case
    LitInteger _ -> STInt
    LitNumber  _ -> STFloat
    LitString  _ -> STString
    LitBoolean _ -> STBool
    LitNull      -> STNull

-- =========================================================================
-- Free variable analysis
-- =========================================================================

freeVarsExpr :: AST.Expr SrcSpan -> Set.Set Name
freeVarsExpr = \case
    AST.EVar _ (QualifiedName Nothing n) -> Set.singleton n
    AST.EVar _ _ -> Set.empty
    AST.ELit _ _ -> Set.empty
    AST.EApp _ f _ args -> freeVarsExpr f <> foldMap freeVarsExpr args
    AST.EFn _ _ ps _ body ->
        let pn = Set.fromList [AST.paramName p | p <- ps]
        in  freeVarsFnBody body `Set.difference` pn
    AST.EMatch _ s arms -> freeVarsExpr s <> foldMap fvArm arms
    AST.EIf _ c t me -> freeVarsExpr c <> freeVarsExpr t <> foldMap freeVarsExpr me
    AST.EBlock _ stmts -> freeVarsStmts stmts
    AST.EHandle _ body cs mr ->
        freeVarsExpr body <> foldMap fvHC cs <> foldMap fvHR mr
    AST.EConstruct _ _ fs -> foldMap (freeVarsExpr . snd) fs
    AST.EArray _ es -> foldMap fvAE es
    AST.EIndex _ a i -> freeVarsExpr a <> freeVarsExpr i
    AST.EReturn _ me -> foldMap freeVarsExpr me
    AST.ETemplateLit _ segs -> foldMap fvSeg segs
    AST.EBinOp _ _ l r -> freeVarsExpr l <> freeVarsExpr r
    AST.EUnaryOp _ _ e -> freeVarsExpr e
    AST.EContinue _ e -> freeVarsExpr e
  where
    fvArm arm = freeVarsExpr (AST.maBody arm) `Set.difference` patBound (AST.maPat arm)
    fvHC hc = freeVarsExpr (AST.hcBody hc) `Set.difference` foldMap patBound (AST.hcParams hc)
    fvHR hr = freeVarsExpr (AST.hrBody hr) `Set.difference` Set.singleton (AST.hrParam hr)
    fvAE (AST.AElem e) = freeVarsExpr e
    fvAE (AST.ASpread e) = freeVarsExpr e
    fvSeg (AST.TmplStr _ _) = Set.empty
    fvSeg (AST.TmplExpr e) = freeVarsExpr e

freeVarsFnBody :: AST.FnBody SrcSpan -> Set.Set Name
freeVarsFnBody (AST.FnExpr e) = freeVarsExpr e
freeVarsFnBody (AST.FnBlock _ s) = freeVarsStmts s

freeVarsStmts :: [AST.Stmt SrcSpan] -> Set.Set Name
freeVarsStmts [] = Set.empty
freeVarsStmts (AST.StmtExpr e : ss) = freeVarsExpr e <> freeVarsStmts ss
freeVarsStmts (AST.StmtLet _ target _ e : ss) =
    freeVarsExpr e <> (freeVarsStmts ss `Set.difference` letTargetBound target)
freeVarsStmts (AST.StmtReturn _ me : _) = foldMap freeVarsExpr me

letTargetBound :: AST.LetTarget SrcSpan -> Set.Set Name
letTargetBound (AST.LetName n) = Set.singleton n
letTargetBound (AST.LetPat p) = patBound p

patBound :: AST.Pat SrcSpan -> Set.Set Name
patBound = \case
    AST.PVar _ n -> Set.singleton n
    AST.PLit _ _ -> Set.empty
    AST.PWild _ -> Set.empty
    AST.PCon _ _ ps -> foldMap patBound ps
    AST.PRecord _ _ fs -> foldMap (patBound . snd) fs
    AST.PArray _ sp ->
        foldMap patBound (AST.spBefore sp)
        <> foldMap (\(_, p) -> patBound p) (AST.spSpread sp)
        <> foldMap patBound (AST.spAfter sp)

-- =========================================================================
-- Expression lowering
-- =========================================================================

lowerExpr :: AST.Expr SrcSpan -> LowerM VarId
lowerExpr = \case
    AST.ELit _ lit -> lowerLit lit
    AST.EVar ann qn -> lowerVar ann qn
    AST.EBinOp _ op l r -> lowerBinOp op l r
    AST.EUnaryOp _ op e -> lowerUnaryOp op e
    AST.EIf _ c t me -> lowerIf c t me
    AST.EBlock _ stmts -> lowerStmts stmts
    AST.EApp ann callee _tyArgs args -> lowerApp ann callee args
    AST.EFn _ _tp params _mrt body -> lowerFn params body
    AST.EMatch _ scrut arms -> lowerMatch scrut arms
    AST.EHandle _ body cases mRet -> lowerHandle body cases mRet
    AST.EConstruct ann qn fields -> lowerConstruct ann qn fields
    AST.EArray _ elems -> lowerArray elems
    AST.EIndex _ a i -> lowerIndex a i
    AST.EReturn _ me -> lowerReturn me
    AST.ETemplateLit _ segs -> lowerTemplateLit segs
    AST.EContinue ann argE -> lowerContinue ann argE

-- =========================================================================
-- Literal
-- =========================================================================

lowerLit :: Literal -> LowerM VarId
lowerLit lit = do
    dst <- freshVar
    setVarType dst (litSimpleType lit)
    case lit of
        LitNull -> emitInstr (ILoadNull dst)
        _       -> do
            cid <- addConstant (litToConst lit)
            emitInstr (ILoadConst dst cid)
    pure dst

litToConst :: Literal -> Constant
litToConst = \case
    LitInteger n -> CInt n
    LitNumber  d -> CFloat d
    LitString  s -> CString s
    LitBoolean b -> CBool b
    LitNull      -> CNull

-- =========================================================================
-- Variable
-- =========================================================================

lowerVar :: SrcSpan -> QualifiedName -> LowerM VarId
lowerVar ann qn = do
    let name = qnName qn
    -- Check known function → wrap as closure
    mfid <- asks (Map.lookup name . leFuncNames)
    case mfid of
        Just fid -> do
            -- Only wrap if not also a local (locals shadow functions)
            mloc <- asks (Map.lookup name . leLocals)
            case mloc of
                Just v  -> pure v
                Nothing -> do
                    dst <- freshVar
                    emitInstr (IMakeClosure dst fid [])
                    pure dst
        Nothing -> lookupLocalOrError ann name

-- =========================================================================
-- Binary operators
-- =========================================================================

lowerBinOp :: AST.BinOp -> AST.Expr SrcSpan -> AST.Expr SrcSpan -> LowerM VarId
lowerBinOp op lE rE = do
    lv <- lowerExpr lE
    rv <- lowerExpr rE
    dst <- freshVar
    lt <- getVarType lv
    rt <- getVarType rv
    let st = combineST lt rt
    setVarType dst (resultType op st)
    emitInstr (pickBin op st dst lv rv)
    pure dst
  where
    combineST STFloat _ = STFloat
    combineST _ STFloat = STFloat
    combineST STInt STInt = STInt
    combineST a _ = a

    resultType AST.OpEq  _ = STBool
    resultType AST.OpNeq _ = STBool
    resultType AST.OpLt  _ = STBool
    resultType AST.OpLe  _ = STBool
    resultType AST.OpGt  _ = STBool
    resultType AST.OpGe  _ = STBool
    resultType AST.OpAnd _ = STBool
    resultType AST.OpOr  _ = STBool
    resultType AST.OpConcat _ = STString
    resultType _ st = st

    pickBin AST.OpAdd STFloat d a b = IAddFlt d a b
    pickBin AST.OpAdd _       d a b = IAddInt d a b
    pickBin AST.OpSub STFloat d a b = ISubFlt d a b
    pickBin AST.OpSub _       d a b = ISubInt d a b
    pickBin AST.OpMul STFloat d a b = IMulFlt d a b
    pickBin AST.OpMul _       d a b = IMulInt d a b
    pickBin AST.OpDiv STFloat d a b = IDivFlt d a b
    pickBin AST.OpDiv _       d a b = IDivInt d a b
    pickBin AST.OpMod _       d a b = IModInt d a b
    pickBin AST.OpEq  _       d a b = ICmpEq d a b
    pickBin AST.OpNeq _       d a b = ICmpNe d a b
    pickBin AST.OpLt  _       d a b = ICmpLt d a b
    pickBin AST.OpLe  _       d a b = ICmpLe d a b
    pickBin AST.OpGt  _       d a b = ICmpGt d a b
    pickBin AST.OpGe  _       d a b = ICmpGe d a b
    pickBin AST.OpAnd _       d a b = IAnd d a b
    pickBin AST.OpOr  _       d a b = IOr d a b
    pickBin AST.OpConcat _    d a b = IConcat d a b

-- =========================================================================
-- Unary operators
-- =========================================================================

lowerUnaryOp :: AST.UnaryOp -> AST.Expr SrcSpan -> LowerM VarId
lowerUnaryOp op e = do
    v <- lowerExpr e
    dst <- freshVar
    vt <- getVarType v
    case op of
        AST.OpNeg -> case vt of
            STFloat -> do setVarType dst STFloat; emitInstr (INegFlt dst v)
            _       -> do setVarType dst STInt;   emitInstr (INegInt dst v)
        AST.OpNot -> do
            setVarType dst STBool
            emitInstr (INot dst v)
    pure dst

-- =========================================================================
-- If expression
-- =========================================================================

lowerIf :: AST.Expr SrcSpan -> AST.Expr SrcSpan -> Maybe (AST.Expr SrcSpan) -> LowerM VarId
lowerIf cond thenE mElse = do
    condV <- lowerExpr cond
    resultV <- freshVar
    thenBid <- freshBlock
    elseBid <- freshBlock
    mergeBid <- freshBlock
    finishBlock (TBranch condV thenBid elseBid) thenBid
    thenV <- lowerExpr thenE
    emitInstr (IMove resultV thenV)
    finishBlock (TJump mergeBid) elseBid
    case mElse of
        Just elseE -> do
            elseV <- lowerExpr elseE
            emitInstr (IMove resultV elseV)
        Nothing -> emitInstr (ILoadNull resultV)
    finishBlock (TJump mergeBid) mergeBid
    pure resultV

-- =========================================================================
-- Block / statements
-- =========================================================================

lowerStmts :: [AST.Stmt SrcSpan] -> LowerM VarId
lowerStmts [] = do
    v <- freshVar
    emitInstr (ILoadNull v)
    pure v
lowerStmts [s] = lowerStmt s
lowerStmts (s:ss) = case s of
    AST.StmtLet _ target _mTy rhs -> do
        rhsV <- lowerExpr rhs
        bindings <- lowerLetTarget target rhsV
        withLocals bindings (lowerStmts ss)
    _ -> do
        _ <- lowerStmt s
        lowerStmts ss

lowerStmt :: AST.Stmt SrcSpan -> LowerM VarId
lowerStmt = \case
    AST.StmtExpr e -> lowerExpr e
    AST.StmtLet _ target _mTy rhs -> do
        rhsV <- lowerExpr rhs
        _ <- lowerLetTarget target rhsV
        v <- freshVar
        emitInstr (ILoadNull v)
        pure v
    AST.StmtReturn _ me -> lowerReturn me

lowerLetTarget :: AST.LetTarget SrcSpan -> VarId -> LowerM [(Name, VarId)]
lowerLetTarget (AST.LetName name) rhsV = do
    registerVarName rhsV name
    pure [(name, rhsV)]
lowerLetTarget (AST.LetPat pat) rhsV = bindPat rhsV pat

-- =========================================================================
-- Return
-- =========================================================================

lowerReturn :: Maybe (AST.Expr SrcSpan) -> LowerM VarId
lowerReturn me = do
    retV <- case me of
        Just e  -> lowerExpr e
        Nothing -> do v <- freshVar; emitInstr (ILoadNull v); pure v
    nextBid <- freshBlock
    finishBlock (TReturn retV) nextBid
    v <- freshVar
    emitInstr (ILoadNull v)
    pure v

-- =========================================================================
-- Function application
-- =========================================================================

lowerApp :: SrcSpan -> AST.Expr SrcSpan -> [AST.Expr SrcSpan] -> LowerM VarId
lowerApp _ann callee args = do
    -- Check if callee is an effect
    case callee of
        AST.EVar _ (QualifiedName _ effName) -> do
            meid <- asks (Map.lookup effName . leEffectIds)
            case meid of
                Just eid -> do
                    argVs <- mapM lowerExpr args
                    dst <- freshVar
                    contBid <- freshBlock
                    finishBlock (TPerform dst eid argVs contBid) contBid
                    pure dst
                Nothing -> callExpr
        _ -> callExpr
  where
    callExpr = do
        argVs <- mapM lowerExpr args
        dst <- freshVar
        contBid <- freshBlock
        case callee of
            AST.EVar _ (QualifiedName _ name) -> do
                mfid <- asks (Map.lookup name . leFuncNames)
                mloc <- asks (Map.lookup name . leLocals)
                case (mloc, mfid) of
                    (Just locV, _) ->
                        finishBlock (TCall dst locV argVs contBid) contBid
                    (Nothing, Just fid) ->
                        finishBlock (TCallDirect dst fid argVs contBid) contBid
                    _ -> do
                        funV <- lowerExpr callee
                        finishBlock (TCall dst funV argVs contBid) contBid
            _ -> do
                funV <- lowerExpr callee
                finishBlock (TCall dst funV argVs contBid) contBid
        pure dst

-- =========================================================================
-- Anonymous function (closure)
-- =========================================================================

lowerFn :: [AST.Param SrcSpan] -> AST.FnBody SrcSpan -> LowerM VarId
lowerFn params body = do
    fid <- freshFunc
    let bodyFV = freeVarsFnBody body
        paramNames = Set.fromList [AST.paramName p | p <- params]
        needed = bodyFV `Set.difference` paramNames
    locals <- asks leLocals
    let captureNames = filter (`Set.member` needed) (Map.keys locals)
        captureVars  = mapMaybe (`Map.lookup` locals) captureNames

    saved <- saveBlockState
    startFreshBlocks

    paramVarIds <- forM params $ \p ->
        freshNamedVar (AST.paramName p) (resolveTyExprSimple (AST.paramType p))
    captureBindings <- forM captureNames $ \n -> do
        v <- freshNamedVar n STUnknown
        pure (n, v)

    let allParams = map snd captureBindings ++ paramVarIds
        bindings  = zip (map AST.paramName params) paramVarIds ++ captureBindings

    retV <- withLocals bindings $ case body of
        AST.FnExpr e     -> lowerExpr e
        AST.FnBlock _ ss -> lowerStmts ss

    finishBlockFinal (TReturn retV)
    blocks <- collectBlocks

    modify' (\s -> s { lsFunctions = Function fid (fromIntegral (length allParams)) allParams blocks : lsFunctions s })
    restoreBlockState saved

    dst <- freshVar
    emitInstr (IMakeClosure dst fid captureVars)
    pure dst

-- =========================================================================
-- Match expression
-- =========================================================================

lowerMatch :: AST.Expr SrcSpan -> [AST.MatchArm SrcSpan] -> LowerM VarId
lowerMatch scrut arms = do
    scrutV <- lowerExpr scrut
    resultV <- freshVar
    mergeBid <- freshBlock

    let go [] = finishBlock TUnreachable mergeBid
        go [arm] = do
            bindings <- bindPat scrutV (AST.maPat arm)
            bodyV <- withLocals bindings (lowerExpr (AST.maBody arm))
            emitInstr (IMove resultV bodyV)
            finishBlock (TJump mergeBid) mergeBid
        go (arm:rest) = do
            matchBid <- freshBlock
            nextBid  <- freshBlock
            compilePat scrutV (AST.maPat arm) nextBid matchBid
            bindings <- bindPat scrutV (AST.maPat arm)
            bodyV <- withLocals bindings (lowerExpr (AST.maBody arm))
            emitInstr (IMove resultV bodyV)
            finishBlock (TJump mergeBid) nextBid
            go rest
    go arms
    pure resultV

-- =========================================================================
-- Pattern compilation
-- =========================================================================

compilePat :: VarId -> AST.Pat SrcSpan -> BlockId -> BlockId -> LowerM ()
compilePat scrutV pat failBid succBid = case pat of
    AST.PVar _ _ -> finishBlock (TJump succBid) succBid
    AST.PWild _  -> finishBlock (TJump succBid) succBid
    AST.PLit _ lit -> do
        litV <- case lit of
            LitNull -> do v <- freshVar; emitInstr (ILoadNull v); pure v
            _       -> do v <- freshVar; cid <- addConstant (litToConst lit); emitInstr (ILoadConst v cid); pure v
        cmpV <- freshVar
        emitInstr (ICmpEq cmpV scrutV litV)
        finishBlock (TBranch cmpV succBid failBid) succBid
    AST.PCon _ qn subPats -> do
        let name = qnName qn
        mtid <- asks (Map.lookup name . leDataIds)
        case mtid of
            Just tid -> do
                tagV <- freshVar
                emitInstr (IGetTag tagV scrutV)
                matchBid <- freshBlock
                finishBlock (TSwitch tagV [(CaseTag tid, matchBid)] failBid) matchBid
                forM_ (zip [0..] subPats) $ \(i, subP) -> do
                    fV <- freshVar
                    emitInstr (IGetField fV scrutV i)
                    nb <- freshBlock
                    compilePat fV subP failBid nb
                finishBlock (TJump succBid) succBid
            Nothing -> finishBlock (TJump succBid) succBid
    AST.PRecord _ qn fieldPats -> do
        let name = qnName qn
        mtid <- asks (Map.lookup name . leDataIds)
        defs <- asks leTypeDefs
        case mtid of
            Just tid -> do
                tagV <- freshVar
                emitInstr (IGetTag tagV scrutV)
                matchBid <- freshBlock
                finishBlock (TSwitch tagV [(CaseTag tid, matchBid)] failBid) matchBid
                let mdd = Map.lookup name (tdData defs)
                    fieldOrder = maybe [] (map fst . ddFields) mdd
                forM_ fieldPats $ \(fname, subP) -> do
                    let idx = maybe 0 id (lookupIdx fname fieldOrder)
                    fV <- freshVar
                    emitInstr (IGetField fV scrutV (fromIntegral idx))
                    nb <- freshBlock
                    compilePat fV subP failBid nb
                finishBlock (TJump succBid) succBid
            Nothing -> finishBlock (TJump succBid) succBid
    AST.PArray _ sp -> do
        let minLen = length (AST.spBefore sp) + length (AST.spAfter sp)
        lenV <- freshVar
        emitInstr (IArrLen lenV scrutV)
        minV <- freshVar
        cid <- addConstant (CInt (fromIntegral minLen))
        emitInstr (ILoadConst minV cid)
        cmpV <- freshVar
        if null (AST.spSpread sp)
            then emitInstr (ICmpEq cmpV lenV minV)
            else emitInstr (ICmpGe cmpV lenV minV)
        chkBid <- freshBlock
        finishBlock (TBranch cmpV chkBid failBid) chkBid
        forM_ (zip [0..] (AST.spBefore sp)) $ \(i, subP) -> do
            idxV <- freshVar
            ic <- addConstant (CInt i)
            emitInstr (ILoadConst idxV ic)
            eV <- freshVar
            emitInstr (IArrGet eV scrutV idxV)
            nb <- freshBlock
            compilePat eV subP failBid nb
        finishBlock (TJump succBid) succBid

bindPat :: VarId -> AST.Pat SrcSpan -> LowerM [(Name, VarId)]
bindPat scrutV = \case
    AST.PVar _ name -> do
        registerVarName scrutV name
        pure [(name, scrutV)]
    AST.PWild _ -> pure []
    AST.PLit _ _ -> pure []
    AST.PCon _ _ subPats ->
        concat <$> forM (zip [0..] subPats) (\(i, subP) -> do
            fV <- freshVar
            emitInstr (IGetField fV scrutV i)
            bindPat fV subP)
    AST.PRecord _ qn fieldPats -> do
        defs <- asks leTypeDefs
        let name = qnName qn
            mdd = Map.lookup name (tdData defs)
            fieldOrder = maybe [] (map fst . ddFields) mdd
        concat <$> forM fieldPats (\(fname, subP) -> do
            let idx = maybe 0 id (lookupIdx fname fieldOrder)
            fV <- freshVar
            emitInstr (IGetField fV scrutV (fromIntegral idx))
            bindPat fV subP)
    AST.PArray _ sp ->
        concat <$> forM (zip [0..] (AST.spBefore sp)) (\(i, subP) -> do
            idxV <- freshVar
            ic <- addConstant (CInt i)
            emitInstr (ILoadConst idxV ic)
            eV <- freshVar
            emitInstr (IArrGet eV scrutV idxV)
            bindPat eV subP)

lookupIdx :: Name -> [Name] -> Maybe Int
lookupIdx _ [] = Nothing
lookupIdx n (x:xs)
    | n == x    = Just 0
    | otherwise = (+ 1) <$> lookupIdx n xs

-- =========================================================================
-- Handle expression
-- =========================================================================

lowerHandle :: AST.Expr SrcSpan -> [AST.HandleCase SrcSpan]
            -> Maybe (AST.HandleReturn SrcSpan) -> LowerM VarId
lowerHandle bodyExpr cases mReturn = do
    -- 1. Compile body as zero-arg closure
    bodyFid <- freshFunc
    let bodyFV = freeVarsExpr bodyExpr
    locals <- asks leLocals
    let capNames = filter (`Set.member` bodyFV) (Map.keys locals)
        capVars  = mapMaybe (`Map.lookup` locals) capNames

    saved <- saveBlockState
    startFreshBlocks
    capBinds <- forM capNames $ \n -> do
        v <- freshNamedVar n STUnknown; pure (n, v)
    retV <- withLocals capBinds (lowerExpr bodyExpr)
    finishBlockFinal (TReturn retV)
    bodyBlocks <- collectBlocks
    modify' (\s -> s { lsFunctions = Function bodyFid (fromIntegral (length capBinds)) (map snd capBinds) bodyBlocks : lsFunctions s })
    restoreBlockState saved

    bodyClosV <- freshVar
    emitInstr (IMakeClosure bodyClosV bodyFid capVars)

    -- 2. Handler cases
    handlers <- forM cases $ \hc -> do
        let effName = AST.hcEffect hc
        meid <- asks (Map.lookup effName . leEffectIds)
        eid <- case meid of
            Just e  -> pure e
            Nothing -> lowerError noSpan ("unknown effect: " <> unName effName)

        argVars <- forM (AST.hcParams hc) $ \_ -> freshVar
        contVar <- freshVar
        hBid <- freshBlock

        curBid <- gets lsCurrentBlockId
        curIns <- gets lsCurrentInstrs
        modify' (\s -> s { lsCurrentBlockId = hBid, lsCurrentInstrs = [] })

        argBinds <- concat <$> forM (zip argVars (AST.hcParams hc)) (\(av, p) -> bindPat av p)
        hRetV <- withLocals argBinds $
            local (\env -> env { leContinuation = Just contVar }) $
                lowerExpr (AST.hcBody hc)
        finishBlockFinal (THandleRet hRetV)

        modify' (\s -> s { lsCurrentBlockId = curBid, lsCurrentInstrs = curIns })
        pure (eid, HandlerDef hBid argVars contVar)

    -- 3. Return clause
    mRetDef <- case mReturn of
        Nothing -> pure Nothing
        Just hr -> do
            rArgV <- freshNamedVar (AST.hrParam hr) STUnknown
            rBid <- freshBlock
            curBid <- gets lsCurrentBlockId
            curIns <- gets lsCurrentInstrs
            modify' (\s -> s { lsCurrentBlockId = rBid, lsCurrentInstrs = [] })
            rBodyV <- withLocals [(AST.hrParam hr, rArgV)] (lowerExpr (AST.hrBody hr))
            finishBlockFinal (THandleRet rBodyV)
            modify' (\s -> s { lsCurrentBlockId = curBid, lsCurrentInstrs = curIns })
            pure (Just (ReturnDef rBid rArgV))

    -- 4. Emit THandle
    resultV <- freshVar
    contBid <- freshBlock
    finishBlock (THandle (HandleInfo bodyClosV handlers mRetDef resultV contBid)) contBid
    pure resultV

-- =========================================================================
-- Continue (multi-shot)
-- =========================================================================

lowerContinue :: SrcSpan -> AST.Expr SrcSpan -> LowerM VarId
lowerContinue ann argE = do
    argV <- lowerExpr argE
    mContVar <- asks leContinuation
    case mContVar of
        Nothing -> lowerError ann "continue used outside of a handler case"
        Just contVar -> do
            resultV <- freshVar
            contBid <- freshBlock
            finishBlock (TContinue contVar argV resultV contBid) contBid
            pure resultV

-- =========================================================================
-- Construct
-- =========================================================================

lowerConstruct :: SrcSpan -> QualifiedName -> [(Name, AST.Expr SrcSpan)] -> LowerM VarId
lowerConstruct ann qn fields = do
    let name = qnName qn
    mtid <- asks (Map.lookup name . leDataIds)
    case mtid of
        Nothing -> lowerError ann ("unknown data type: " <> unName name)
        Just tid -> do
            defs <- asks leTypeDefs
            let mdd = Map.lookup name (tdData defs)
                fieldOrder = maybe [] (map fst . ddFields) mdd
            fieldVs <- forM fieldOrder $ \fname ->
                case lookup fname fields of
                    Just e  -> lowerExpr e
                    Nothing -> do v <- freshVar; emitInstr (ILoadNull v); pure v
            dst <- freshVar
            emitInstr (IConstruct dst tid fieldVs)
            pure dst

-- =========================================================================
-- Array
-- =========================================================================

lowerArray :: [AST.ArrayElem SrcSpan] -> LowerM VarId
lowerArray elems = go [] elems
  where
    go acc [] = do
        vs <- mapM lowerExpr (reverse acc)
        dst <- freshVar
        emitInstr (INewArray dst vs)
        pure dst
    go acc (AST.AElem e : rest) = go (e : acc) rest
    go acc (AST.ASpread e : rest) = do
        vs <- mapM lowerExpr (reverse acc)
        arrV <- freshVar
        emitInstr (INewArray arrV vs)
        spreadV <- lowerExpr e
        concatV <- freshVar
        emitInstr (IArrConcat concatV arrV spreadV)
        goConcat concatV rest

    goConcat arrV [] = pure arrV
    goConcat arrV (AST.AElem e : rest) = do
        eV <- lowerExpr e
        nV <- freshVar
        emitInstr (IArrPush nV arrV eV)
        goConcat nV rest
    goConcat arrV (AST.ASpread e : rest) = do
        sV <- lowerExpr e
        nV <- freshVar
        emitInstr (IArrConcat nV arrV sV)
        goConcat nV rest

-- =========================================================================
-- Index
-- =========================================================================

lowerIndex :: AST.Expr SrcSpan -> AST.Expr SrcSpan -> LowerM VarId
lowerIndex arrE idxE = do
    arrV <- lowerExpr arrE
    idxV <- lowerExpr idxE
    dst <- freshVar
    emitInstr (IArrGet dst arrV idxV)
    pure dst

-- =========================================================================
-- Template literal
-- =========================================================================

lowerTemplateLit :: [AST.TemplateSegment SrcSpan] -> LowerM VarId
lowerTemplateLit [] = do
    dst <- freshVar
    cid <- addConstant (CString "")
    emitInstr (ILoadConst dst cid)
    setVarType dst STString
    pure dst
lowerTemplateLit segs = do
    vs <- forM segs $ \case
        AST.TmplStr _ (Name s) -> do
            v <- freshVar; cid <- addConstant (CString s)
            emitInstr (ILoadConst v cid); setVarType v STString; pure v
        AST.TmplExpr e -> lowerExpr e
    foldlM (\acc v -> do
        dst <- freshVar; setVarType dst STString
        emitInstr (IConcat dst acc v); pure dst
        ) (head vs) (tail vs)

-- =========================================================================
-- Declaration lowering
-- =========================================================================

lowerDecl :: AST.Decl SrcSpan -> LowerM ()
lowerDecl = \case
    AST.DeclData _ name _ _kind fields -> do
        mtid <- asks (Map.lookup name . leDataIds)
        forM_ mtid $ \t ->
            modify' (\s -> s { lsNominalTypes = NominalTypeDef t (fromIntegral (length fields)) (map (unName . fst) fields) : lsNominalTypes s })

    AST.DeclEffect _ name _ fields _ -> do
        meid <- asks (Map.lookup name . leEffectIds)
        forM_ meid $ \e ->
            modify' (\s -> s { lsEffectDefs = IREffectDef e (fromIntegral (length fields)) : lsEffectDefs s })

    AST.DeclFn _ name _ params _ body -> do
        mfid <- asks (Map.lookup name . leFuncNames)
        forM_ mfid $ \fid -> do
            saved <- saveBlockState
            startFreshBlocks
            pvs <- forM params $ \p ->
                freshNamedVar (AST.paramName p) (resolveTyExprSimple (AST.paramType p))
            let binds = zip (map AST.paramName params) pvs
            retV <- withLocals binds $ case body of
                AST.FnExpr e     -> lowerExpr e
                AST.FnBlock _ ss -> lowerStmts ss
            finishBlockFinal (TReturn retV)
            blocks <- collectBlocks
            modify' (\s -> s { lsFunctions = Function fid (fromIntegral (length pvs)) pvs blocks : lsFunctions s })
            restoreBlockState saved

    AST.DeclType {} -> pure ()
    AST.DeclImport {} -> pure ()
    AST.DeclLet {} -> pure ()

-- =========================================================================
-- Module lowering (entry point)
-- =========================================================================

lowerModule :: TypeDefs -> AST.Module SrcSpan -> Either [Diagnostic] Program
lowerModule defs astMod = do
    let modName = AST.modName astMod
        decls   = AST.modDecls astMod
        (dataIds, effIds, funcIds, initState) = preAllocateIds decls

    let env0 = LowerEnv
            { leModuleName   = modName
            , leTypeDefs     = defs
            , leLocals       = Map.empty
            , leEffectIds    = effIds
            , leDataIds      = dataIds
            , leFuncNames    = funcIds
            , leContinuation = Nothing
            }

    ((), finalState) <- runStateT (runReaderT (mainPass decls) env0) initState

    let irMod = Module
            { mName         = modName
            , mNameTable    = lsNameTable finalState
            , mNominalTypes = reverse (lsNominalTypes finalState)
            , mEffects      = reverse (lsEffectDefs finalState)
            , mConstants    = reverse (lsConstants finalState)
            , mFunctions    = reverse (lsFunctions finalState)
            , mEntryFunc    = if hasTopLevelLets decls
                              then Just (FuncId (lsNextFunc initState - 1))
                              else Nothing
            }
    Right (Program [irMod])

preAllocateIds :: [AST.Decl SrcSpan]
               -> (Map Name TypeId, Map Name EffectId, Map Name FuncId, LowerState)
preAllocateIds decls =
    let (dids, s1) = foldr allocData (Map.empty, initS) decls
        (eids, s2) = foldr allocEff  (Map.empty, s1) decls
        (fids, s3) = foldr allocFn   (Map.empty, s2) decls
        s4 = if hasTopLevelLets decls
             then s3 { lsNextFunc = lsNextFunc s3 + 1 }
             else s3
    in (dids, eids, fids, s4)
  where
    initS = LowerState 0 0 0 0 0 0 [] Map.empty emptyNameTable (BlockId 0) [] [] [] [] [] Map.empty

    allocData (AST.DeclData _ name _ _ _) (m, s) =
        let tid = TypeId (lsNextType s)
            nt  = lsNameTable s
        in ( Map.insert name tid m
           , s { lsNextType = lsNextType s + 1
               , lsNameTable = nt { ntTypes = Map.insert tid (unName name) (ntTypes nt) } })
    allocData _ acc = acc

    allocEff (AST.DeclEffect _ name _ _ _) (m, s) =
        let eid = EffectId (lsNextEffect s)
            nt  = lsNameTable s
        in ( Map.insert name eid m
           , s { lsNextEffect = lsNextEffect s + 1
               , lsNameTable = nt { ntEffects = Map.insert eid (unName name) (ntEffects nt) } })
    allocEff _ acc = acc

    allocFn (AST.DeclFn _ name _ _ _ _) (m, s) =
        let fid = FuncId (lsNextFunc s)
            nt  = lsNameTable s
            qn  = unqualify name
        in ( Map.insert name fid m
           , s { lsNextFunc = lsNextFunc s + 1
               , lsNameTable = nt { ntFuncs = Map.insert fid qn (ntFuncs nt) } })
    allocFn _ acc = acc

hasTopLevelLets :: [AST.Decl SrcSpan] -> Bool
hasTopLevelLets = any (\case AST.DeclLet {} -> True; _ -> False)

mainPass :: [AST.Decl SrcSpan] -> LowerM ()
mainPass decls = do
    forM_ decls lowerDecl
    let topLets = [(target, rhs) | AST.DeclLet _ target _ _ rhs <- decls]
    when (not (null topLets)) $ do
        entryFid <- FuncId . subtract 1 <$> gets lsNextFunc
        saved <- saveBlockState
        startFreshBlocks
        _ <- foldM (\binds (target, rhs) -> do
            rhsV <- withLocals binds (lowerExpr rhs)
            newBinds <- lowerLetTarget target rhsV
            pure (binds ++ newBinds)
            ) [] topLets
        nullV <- freshVar
        emitInstr (ILoadNull nullV)
        finishBlockFinal (TReturn nullV)
        blocks <- collectBlocks
        modify' (\s -> s { lsFunctions = Function entryFid 0 [] blocks : lsFunctions s })
        restoreBlockState saved
