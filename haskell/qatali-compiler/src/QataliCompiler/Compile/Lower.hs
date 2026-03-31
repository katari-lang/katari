{- | Lowering pass: AST (SrcSpan) → Qatali IR.

Translates the parsed AST into the register-based, basic-block IR.
Type information is used only for choosing Int vs Float arithmetic
(via SimpleType tracking). The type checker has already validated correctness.
-}
module QataliCompiler.Compile.Lower (
    lowerModule,
) where

import           Control.Monad              (forM, forM_)
import           Control.Monad.Reader       (ReaderT (..), asks, local, runReaderT)
import           Control.Monad.State.Strict (StateT (..), gets, modify', runStateT)
import           Data.Foldable              (foldlM)
import           Data.List.NonEmpty          (toList)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Maybe                 (isNothing, mapMaybe)
import qualified Data.Set                   as Set
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Word                  (Word16, Word32)

import           QataliCompiler.Diagnostic  (Diagnostic, mkError)
import           QataliCompiler.IR.Instruction
import           QataliCompiler.IR.Module   (Block (..), Constant (..), Function (..),
                                              IREffectDef (..), Module (..), NominalTypeDef (..),
                                              Program (..))
import           QataliCompiler.IR.Types
import           QataliCompiler.Name        (ModuleName (..), Name (..), QualifiedName (..),
                                              unName, unqualify)
import           QataliCompiler.SrcLoc      (SrcSpan (..), noSpan)
import qualified QataliCompiler.Syntax.AST  as AST
import           QataliCompiler.Syntax.Literal (Literal (..))
import           QataliCompiler.Type.Defs      (DataDef (..), TypeDefs (..))

-- | Reserved name for the continuation variable inside handler closures.
-- Uses @$@ prefix to avoid collision with user-defined names.
contName :: Name
contName = Name "$cont"

-- =========================================================================
-- SimpleType
-- =========================================================================

data SimpleType = STInt | STFloat | STString | STBool | STNull | STUnknown
    deriving (Eq)

-- =========================================================================
-- Lowering monad
-- =========================================================================

data LowerEnv = LowerEnv
    { leModuleName     :: !ModuleName
    , leTypeDefs       :: !TypeDefs
    , leLocals         :: !(Map Name VarId)
    , leEffectIds      :: !(Map Name EffectId)
    , leDataIds        :: !(Map Name TypeId)
    , leFuncNames      :: !(Map Name FuncId)
    , leResolvedImpls  :: !(Map SrcSpan Name)
    -- ^ Trait call sites resolved to impl function names by the type checker.
    , leHandlerVarNames :: ![Name]
    -- ^ Names of handler variables currently in scope (for continue with updates).
    }

data SavedBlockState = SavedBlockState
    { sbsCurrentBlockId :: !BlockId
    , sbsCurrentInstrs  :: ![Instr]
    , sbsBlocks         :: ![Block]
    , sbsNextBlock      :: !Word16
    , sbsNextVar        :: !Word32
    , sbsVarTypes       :: !(Map VarId SimpleType)
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
    <*> gets lsNextVar
    <*> gets lsVarTypes

restoreBlockState :: SavedBlockState -> LowerM ()
restoreBlockState sbs = modify' (\s -> s
    { lsCurrentBlockId = sbsCurrentBlockId sbs
    , lsCurrentInstrs  = sbsCurrentInstrs sbs
    , lsBlocks         = sbsBlocks sbs
    , lsNextBlock      = sbsNextBlock sbs
    , lsNextVar        = sbsNextVar sbs
    , lsVarTypes       = sbsVarTypes sbs
    })

startFreshBlocks :: LowerM ()
startFreshBlocks = modify' (\s -> s
    { lsNextBlock      = 1
    , lsCurrentBlockId = BlockId 0
    , lsCurrentInstrs  = []
    , lsBlocks         = []
    , lsNextVar        = 0
    , lsVarTypes       = Map.empty
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
    AST.EFn _ _ ps _ _ body ->
        let pn = Set.fromList [AST.paramName p | p <- ps]
        in  freeVarsFnBody body `Set.difference` pn
    AST.EMatch _ s arms -> freeVarsExpr s <> foldMap fvArm arms
    AST.EIf _ c t me -> freeVarsExpr c <> freeVarsExpr t <> foldMap freeVarsExpr me
    AST.EBlock _ stmts -> freeVarsStmts stmts
    AST.EHandle _ body hvars cs mr ->
        freeVarsExpr body <> foldMap fvHVar hvars <> foldMap fvHC cs <> foldMap fvHR mr
    AST.EConstruct _ _ fs -> foldMap (freeVarsExpr . snd) fs
    AST.EArray _ es -> foldMap fvAE es
    AST.EIndex _ a i -> freeVarsExpr a <> freeVarsExpr i
    AST.EReturn _ me -> foldMap freeVarsExpr me
    AST.ETemplateLit _ segs -> foldMap fvSeg segs
    AST.EBinOp _ _ l r -> freeVarsExpr l <> freeVarsExpr r
    AST.EUnaryOp _ _ e -> freeVarsExpr e
    AST.EContinue _ e mUpdates ->
        Set.insert contName (freeVarsExpr e)
        <> foldMap (foldMap (freeVarsExpr . snd)) mUpdates
    AST.EBreak _ e -> freeVarsExpr e
  where
    fvArm arm = (freeVarsExpr (AST.maBody arm) <> foldMap freeVarsExpr (AST.maGuard arm))
                `Set.difference` patBound (AST.maPat arm)
    fvHVar hv = freeVarsExpr (AST.hvInit hv)
    fvHC hc = (freeVarsExpr (AST.hcBody hc) `Set.difference` foldMap patBound (AST.hcParams hc))
              `Set.difference` Set.singleton contName
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
    AST.PCon _ _ _ ps -> foldMap patBound ps
    AST.PRecord _ _ _ fs -> foldMap (patBound . snd) fs
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
    AST.EBinOp _ AST.OpAnd l r -> lowerShortCircuit True l r
    AST.EBinOp _ AST.OpOr  l r -> lowerShortCircuit False l r
    AST.EBinOp _ op l r -> lowerBinOp op l r
    AST.EUnaryOp _ op e -> lowerUnaryOp op e
    AST.EIf _ c t me -> lowerIf c t me
    AST.EBlock _ stmts -> lowerStmts stmts
    AST.EApp ann callee _tyArgs args -> lowerApp ann callee args
    AST.EFn _ _tp params _mrt _meff body -> lowerFn params body
    AST.EMatch _ scrut arms -> lowerMatch scrut arms
    AST.EHandle _ body hvars cases mRet -> lowerHandle body hvars cases mRet
    AST.EConstruct ann qn fields -> lowerConstruct ann qn fields
    AST.EArray _ elems -> lowerArray elems
    AST.EIndex _ a i -> lowerIndex a i
    AST.EReturn _ me -> lowerReturn me
    AST.ETemplateLit _ segs -> lowerTemplateLit segs
    AST.EContinue ann argE mUpdates -> lowerContinue ann argE mUpdates
    AST.EBreak _ valE -> lowerReturn (Just valE)

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
-- Short-circuit Boolean operators
-- =========================================================================

-- | Short-circuit evaluation for @&&@ (isAnd=True) and @||@ (isAnd=False).
--
-- @a && b@ compiles to: eval a; if a then eval b else false
-- @a || b@ compiles to: eval a; if a then true else eval b
lowerShortCircuit :: Bool -> AST.Expr SrcSpan -> AST.Expr SrcSpan -> LowerM VarId
lowerShortCircuit isAnd lE rE = do
    resultV <- freshVar
    setVarType resultV STBool
    lv <- lowerExpr lE
    rhsBid   <- freshBlock
    mergeBid <- freshBlock
    if isAnd
        then do
            -- a && b: if a then eval b else false
            shortBid <- freshBlock
            finishBlock (TBranch lv rhsBid shortBid) shortBid
            -- short-circuit block: result = false
            cid <- addConstant (CBool False)
            emitInstr (ILoadConst resultV cid)
            finishBlock (TJump mergeBid) rhsBid
        else do
            -- a || b: if a then true else eval b
            shortBid <- freshBlock
            finishBlock (TBranch lv shortBid rhsBid) shortBid
            -- short-circuit block: result = true
            cid <- addConstant (CBool True)
            emitInstr (ILoadConst resultV cid)
            finishBlock (TJump mergeBid) rhsBid
    -- rhs block: eval b, result = b
    rv <- lowerExpr rE
    emitInstr (IMove resultV rv)
    finishBlock (TJump mergeBid) mergeBid
    pure resultV

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
    pickBin AST.OpConcat _    d a b = IConcat d a b
    pickBin AST.OpAnd _       _ _ _ = error "unreachable: OpAnd handled by lowerShortCircuit"
    pickBin AST.OpOr  _       _ _ _ = error "unreachable: OpOr handled by lowerShortCircuit"

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
lowerApp ann callee args = do
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
        -- Check for statically resolved trait impl
        mImplName <- asks (Map.lookup ann . leResolvedImpls)
        case mImplName of
            Just implName -> do
                mfid <- asks (Map.lookup implName . leFuncNames)
                case mfid of
                    Just fid -> finishBlock (TCallDirect dst fid argVs contBid) contBid
                    Nothing  -> do
                        funV <- lowerExpr callee
                        finishBlock (TCall dst funV argVs contBid) contBid
            Nothing ->
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
            -- Last arm: verify pattern defensively, panic if it fails
            panicBid <- freshBlock
            matchBid <- freshBlock
            bindings <- compileAndBindPat scrutV (AST.maPat arm) panicBid matchBid
            applyGuard (AST.maGuard arm) bindings panicBid
            bodyV <- withLocals bindings (lowerExpr (AST.maBody arm))
            emitInstr (IMove resultV bodyV)
            finishBlock (TJump mergeBid) panicBid
            finishBlock TUnreachable mergeBid
        go (arm:rest) = do
            matchBid <- freshBlock
            nextBid  <- freshBlock
            bindings <- compileAndBindPat scrutV (AST.maPat arm) nextBid matchBid
            applyGuard (AST.maGuard arm) bindings nextBid
            bodyV <- withLocals bindings (lowerExpr (AST.maBody arm))
            emitInstr (IMove resultV bodyV)
            finishBlock (TJump mergeBid) nextBid
            go rest
    go arms
    pure resultV

-- | Apply match guard: branch on guard expression to success or fail block.
-- After this, the current block is the one that passed the guard.
applyGuard :: Maybe (AST.Expr SrcSpan) -> [(Name, VarId)] -> BlockId -> LowerM ()
applyGuard Nothing _ _ = pure ()
applyGuard (Just guardE) bindings failBid = do
    guardV <- withLocals bindings (lowerExpr guardE)
    guardSuccBid <- freshBlock
    finishBlock (TBranch guardV guardSuccBid failBid) guardSuccBid

-- =========================================================================
-- Pattern compilation
-- =========================================================================

-- | Unified pattern compilation: checks the pattern (branching to failBid on
-- mismatch) and produces variable bindings in one pass, avoiding duplicate
-- field extraction.
compileAndBindPat :: VarId -> AST.Pat SrcSpan -> BlockId -> BlockId -> LowerM [(Name, VarId)]
compileAndBindPat scrutV pat failBid succBid = case pat of
    AST.PVar _ name -> do
        registerVarName scrutV name
        finishBlock (TJump succBid) succBid
        pure [(name, scrutV)]
    AST.PWild _ -> do
        finishBlock (TJump succBid) succBid
        pure []
    AST.PLit _ lit -> do
        litV <- case lit of
            LitNull -> do v <- freshVar; emitInstr (ILoadNull v); pure v
            _       -> do v <- freshVar; cid <- addConstant (litToConst lit); emitInstr (ILoadConst v cid); pure v
        cmpV <- freshVar
        emitInstr (ICmpEq cmpV scrutV litV)
        finishBlock (TBranch cmpV succBid failBid) succBid
        pure []
    AST.PCon _ qn _tyVars subPats -> do
        let name = qnName qn
        mtid <- asks (Map.lookup name . leDataIds)
        case mtid of
            Just tid -> do
                tagV <- freshVar
                emitInstr (IGetTag tagV scrutV)
                matchBid <- freshBlock
                finishBlock (TSwitch tagV [(CaseTag tid, matchBid)] failBid) matchBid
                bindings <- concat <$> forM (zip [0..] subPats) (\(i, subP) -> do
                    fV <- freshVar
                    emitInstr (IGetField fV scrutV i)
                    nb <- freshBlock
                    compileAndBindPat fV subP failBid nb)
                finishBlock (TJump succBid) succBid
                pure bindings
            Nothing -> do
                finishBlock (TJump succBid) succBid
                pure []
    AST.PRecord _ qn _tyVars fieldPats -> do
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
                bindings <- concat <$> forM fieldPats (\(fname, subP) -> do
                    let idx = maybe 0 id (lookupIdx fname fieldOrder)
                    fV <- freshVar
                    emitInstr (IGetField fV scrutV (fromIntegral idx))
                    nb <- freshBlock
                    compileAndBindPat fV subP failBid nb)
                finishBlock (TJump succBid) succBid
                pure bindings
            Nothing -> do
                finishBlock (TJump succBid) succBid
                pure []
    AST.PArray _ sp -> do
        let beforeLen = length (AST.spBefore sp)
            afterLen  = length (AST.spAfter sp)
            minLen    = beforeLen + afterLen
        lenV <- freshVar
        emitInstr (IArrLen lenV scrutV)
        minV <- freshVar
        cid <- addConstant (CInt (fromIntegral minLen))
        emitInstr (ILoadConst minV cid)
        cmpV <- freshVar
        if isNothing (AST.spSpread sp)
            then emitInstr (ICmpEq cmpV lenV minV)
            else emitInstr (ICmpGe cmpV lenV minV)
        chkBid <- freshBlock
        finishBlock (TBranch cmpV chkBid failBid) chkBid
        -- Before elements
        beforeBinds <- concat <$> forM (zip [0..] (AST.spBefore sp)) (\(i, subP) -> do
            idxV <- freshVar
            ic <- addConstant (CInt i)
            emitInstr (ILoadConst idxV ic)
            eV <- freshVar
            emitInstr (IArrGet eV scrutV idxV)
            nb <- freshBlock
            compileAndBindPat eV subP failBid nb)
        -- After elements: index (len - afterLen + i)
        afterBinds <- concat <$> forM (zip [0..] (AST.spAfter sp)) (\(i, subP) -> do
            offC <- addConstant (CInt (fromIntegral afterLen - i))
            offV <- freshVar
            emitInstr (ILoadConst offV offC)
            idxV <- freshVar
            emitInstr (ISubInt idxV lenV offV)
            eV <- freshVar
            emitInstr (IArrGet eV scrutV idxV)
            nb <- freshBlock
            compileAndBindPat eV subP failBid nb)
        -- Spread element: slice arr[beforeLen .. len - afterLen]
        spreadBinds <- case AST.spSpread sp of
            Nothing -> pure []
            Just (_, subP) -> do
                fromC <- addConstant (CInt (fromIntegral beforeLen))
                fromV <- freshVar
                emitInstr (ILoadConst fromV fromC)
                toOffC <- addConstant (CInt (fromIntegral afterLen))
                toOffV <- freshVar
                emitInstr (ILoadConst toOffV toOffC)
                toV <- freshVar
                emitInstr (ISubInt toV lenV toOffV)
                sliceV <- freshVar
                emitInstr (IArrSlice sliceV scrutV fromV toV)
                nb <- freshBlock
                compileAndBindPat sliceV subP failBid nb
        finishBlock (TJump succBid) succBid
        pure (beforeBinds ++ afterBinds ++ spreadBinds)

lookupIdx :: Name -> [Name] -> Maybe Int
lookupIdx _ [] = Nothing
lookupIdx n (x:xs)
    | n == x    = Just 0
    | otherwise = (+ 1) <$> lookupIdx n xs

-- | Bind-only pattern matching (for let/handler params where the type checker
-- guarantees the pattern always matches). Failures jump to TUnreachable.
bindPat :: VarId -> AST.Pat SrcSpan -> LowerM [(Name, VarId)]
bindPat scrutV pat = do
    panicBid <- freshBlock
    contBid  <- freshBlock
    bindings <- compileAndBindPat scrutV pat panicBid contBid
    -- panicBid: should never be reached
    finishBlock TUnreachable contBid
    pure bindings

-- =========================================================================
-- Handle expression
-- =========================================================================

lowerHandle :: AST.Expr SrcSpan -> [AST.HandleVar SrcSpan] -> [AST.HandleCase SrcSpan]
            -> Maybe (AST.HandleReturn SrcSpan) -> LowerM VarId
lowerHandle bodyExpr hvars cases mReturn = do
    let hvarNames = map AST.hvName hvars
        nHVars   = length hvars

    -- 0. Compile handler variable initial values
    hvarInitVs <- forM hvars $ \hv -> lowerExpr (AST.hvInit hv)

    -- 1. Compile body as zero-arg closure (unchanged)
    bodyClosV <- compileClosure (freeVarsExpr bodyExpr) [] $ \_ ->
        lowerExpr bodyExpr

    -- 2. Handler cases — each compiled as a separate closure
    --    Params: [captures..., effect_args..., continuation, hvar_1, hvar_2, ...]
    handlerClosures <- forM cases $ \hc -> do
        let effName = qnName (AST.hcEffect hc)
        meid <- asks (Map.lookup effName . leEffectIds)
        eid <- case meid of
            Just e  -> pure e
            Nothing -> lowerError noSpan ("unknown effect: " <> unName effName)

        -- Free variables: handler body FV minus pattern-bound, contName, and hvar names
        let handlerFV = freeVarsExpr (AST.hcBody hc)
                        `Set.difference` foldMap patBound (AST.hcParams hc)
                        `Set.difference` Set.singleton contName
                        `Set.difference` Set.fromList hvarNames

        -- Extra params: effect args + continuation + handler vars
        let nEffArgs = length (AST.hcParams hc)
            nExtra   = nEffArgs + 1 + nHVars

        handlerClosV <- compileClosure handlerFV (replicate nExtra STUnknown) $ \extraParams -> do
            let argParamVars  = take nEffArgs extraParams
                contParamVar  = extraParams !! nEffArgs
                hvarParamVars = drop (nEffArgs + 1) extraParams
            -- Bind effect arg patterns
            argBinds <- concat <$> forM (zip argParamVars (AST.hcParams hc))
                         (\(av, p) -> bindPat av p)
            -- Compile handler body with continuation + handler vars in scope
            let hvarBinds = zip hvarNames hvarParamVars
            withLocals (argBinds ++ [(contName, contParamVar)] ++ hvarBinds) $
                local (\env -> env { leHandlerVarNames = hvarNames }) $
                    lowerExpr (AST.hcBody hc)

        pure (eid, handlerClosV)

    -- 3. Return handler — compiled as a separate closure (if present)
    --    Params: [captures..., body_return_value, hvar_1, hvar_2, ...]
    mRetClosV <- case mReturn of
        Nothing -> pure Nothing
        Just hr -> do
            let retFV = freeVarsExpr (AST.hrBody hr)
                        `Set.difference` Set.singleton (AST.hrParam hr)
                        `Set.difference` Set.fromList hvarNames
            closV <- compileClosure retFV (replicate (1 + nHVars) STUnknown) $ \extraParams -> do
                let retArgV       = head extraParams
                    hvarParamVars = tail extraParams
                registerVarName retArgV (AST.hrParam hr)
                let hvarBinds = zip hvarNames hvarParamVars
                withLocals ([(AST.hrParam hr, retArgV)] ++ hvarBinds) $
                    lowerExpr (AST.hrBody hr)
            pure (Just closV)

    -- 4. Emit THandle with handler variable inits
    resultV <- freshVar
    contBid <- freshBlock
    finishBlock (THandle (HandleInfo bodyClosV handlerClosures mRetClosV resultV contBid hvarInitVs)) contBid
    pure resultV

-- | Compile a closure: a separate 'Function' that captures free variables.
--
-- @compileClosure freeVars extraParamTypes bodyFn@ does the following:
--
-- 1. Filters @freeVars@ against current @leLocals@ to determine captures.
-- 2. Allocates a fresh 'FuncId'.
-- 3. Creates parameters: @[capture_params..., extra_params...]@.
-- 4. Calls @bodyFn extra_param_varids@ to compile the body (which should
--    return the result 'VarId'). The capture bindings are already in scope.
-- 5. Emits 'IMakeClosure' and returns the closure 'VarId'.
compileClosure :: Set.Set Name -> [SimpleType] -> ([VarId] -> LowerM VarId) -> LowerM VarId
compileClosure freeVars extraParamTypes bodyFn = do
    fid <- freshFunc
    locals <- asks leLocals
    let capNames = filter (`Set.member` freeVars) (Map.keys locals)
        capVars  = mapMaybe (`Map.lookup` locals) capNames

    saved <- saveBlockState
    startFreshBlocks

    -- Capture parameters (fresh VarIds inside the new function)
    capBinds <- forM capNames $ \n -> do
        v <- freshNamedVar n STUnknown; pure (n, v)

    -- Extra parameters (effect args, continuation, return value, etc.)
    extraParamVars <- forM extraParamTypes $ \st -> do
        v <- freshVar; setVarType v st; pure v

    let allParams = map snd capBinds ++ extraParamVars

    retV <- withLocals capBinds (bodyFn extraParamVars)
    finishBlockFinal (TReturn retV)
    blocks <- collectBlocks

    modify' (\s -> s { lsFunctions = Function fid (fromIntegral (length allParams)) allParams blocks : lsFunctions s })
    restoreBlockState saved

    dst <- freshVar
    emitInstr (IMakeClosure dst fid capVars)
    pure dst

-- =========================================================================
-- Continue (one-shot) with handler variable updates
-- =========================================================================

lowerContinue :: SrcSpan -> AST.Expr SrcSpan -> Maybe [(Name, AST.Expr SrcSpan)] -> LowerM VarId
lowerContinue ann argE mUpdates = do
    argV <- lowerExpr argE
    mContVar <- asks (Map.lookup contName . leLocals)
    case mContVar of
        Nothing -> lowerError ann "continue used outside of a handler case"
        Just contVar -> do
            -- Build handler variable update values in declaration order
            hvarNames <- asks leHandlerVarNames
            hvUpdateVs <- forM hvarNames $ \hvName ->
                case mUpdates >>= lookup hvName of
                    Just updateE -> lowerExpr updateE
                    Nothing      -> lookupLocalOrError ann hvName  -- use current value
            resultV <- freshVar
            contBid <- freshBlock
            finishBlock (TContinue contVar argV hvUpdateVs resultV contBid) contBid
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
    AST.DeclData _ _isPub name _ _kind fields -> do
        mtid <- asks (Map.lookup name . leDataIds)
        forM_ mtid $ \t ->
            modify' (\s -> s { lsNominalTypes = NominalTypeDef t (fromIntegral (length fields)) (map (unName . fst) fields) : lsNominalTypes s })

    AST.DeclEffect _ _isPub name _ fields _ -> do
        meid <- asks (Map.lookup name . leEffectIds)
        forM_ meid $ \e ->
            modify' (\s -> s { lsEffectDefs = IREffectDef e (fromIntegral (length fields)) : lsEffectDefs s })

    AST.DeclFn _ _isPub name _ _traits params _ _ body -> do
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

    AST.DeclForeignFn _ name params _retTyE _mEffTyE -> do
        mfid <- asks (Map.lookup name . leFuncNames)
        forM_ mfid $ \fid -> do
            saved <- saveBlockState
            startFreshBlocks
            pvs <- forM params $ \p ->
                freshNamedVar (AST.paramName p) (resolveTyExprSimple (AST.paramType p))
            -- Build module name text for FFI lookup
            modName <- asks leModuleName
            let ModuleName segs = modName
                modNameText = T.intercalate "." (toList segs)
            resultV <- freshVar
            contBid <- freshBlock
            finishBlock (TFfiCall resultV modNameText (unName name) pvs contBid) contBid
            finishBlockFinal (TReturn resultV)
            blocks <- collectBlocks
            modify' (\s -> s { lsFunctions = Function fid (fromIntegral (length pvs)) pvs blocks : lsFunctions s })
            restoreBlockState saved

    AST.DeclType {} -> pure ()
    AST.DeclImport {} -> pure ()
    AST.DeclExport {} -> pure ()
    AST.DeclLet {} -> pure ()
    AST.DeclTrait {} -> pure ()
    AST.DeclImpl {} -> pure ()
    AST.DeclDerive {} -> pure ()

-- =========================================================================
-- Module lowering (entry point)
-- =========================================================================

lowerModule :: TypeDefs -> Map SrcSpan Name -> AST.Module SrcSpan -> Either [Diagnostic] Program
lowerModule defs resolvedImpls astMod = do
    let modName = AST.modName astMod
        decls   = AST.modDecls astMod
        (dataIds, effIds, funcIds, initState) = preAllocateIds decls

    let env0 = LowerEnv
            { leModuleName     = modName
            , leTypeDefs       = defs
            , leLocals         = Map.empty
            , leEffectIds      = effIds
            , leDataIds        = dataIds
            , leFuncNames      = funcIds
            , leResolvedImpls  = resolvedImpls
            , leHandlerVarNames = []
            }

    ((), finalState) <- runStateT (runReaderT (mainPass decls) env0) initState

    let irMod = Module
            { mName         = modName
            , mNameTable    = lsNameTable finalState
            , mNominalTypes = reverse (lsNominalTypes finalState)
            , mEffects      = reverse (lsEffectDefs finalState)
            , mConstants    = reverse (lsConstants finalState)
            , mFunctions    = reverse (lsFunctions finalState)
            }
    Right (Program [irMod])

preAllocateIds :: [AST.Decl SrcSpan]
               -> (Map Name TypeId, Map Name EffectId, Map Name FuncId, LowerState)
preAllocateIds decls =
    let (dids, s1) = foldr allocData (Map.empty, initS) decls
        (eids, s2) = foldr allocEff  (Map.empty, s1) decls
        (fids, s3) = foldr allocFn   (Map.empty, s2) decls
    in (dids, eids, fids, s3)
  where
    initS = LowerState 0 0 0 0 0 0 [] Map.empty emptyNameTable (BlockId 0) [] [] [] [] [] Map.empty

    allocData (AST.DeclData _ _ name _ _ _) (m, s) =
        let tid = TypeId (lsNextType s)
            nt  = lsNameTable s
        in ( Map.insert name tid m
           , s { lsNextType = lsNextType s + 1
               , lsNameTable = nt { ntTypes = Map.insert tid (unName name) (ntTypes nt) } })
    allocData _ acc = acc

    allocEff (AST.DeclEffect _ _ name _ _ _) (m, s) =
        let eid = EffectId (lsNextEffect s)
            nt  = lsNameTable s
        in ( Map.insert name eid m
           , s { lsNextEffect = lsNextEffect s + 1
               , lsNameTable = nt { ntEffects = Map.insert eid (unName name) (ntEffects nt) } })
    allocEff _ acc = acc

    allocFn (AST.DeclFn _ _ name _ _ _ _ _ _) (m, s) =
        let fid = FuncId (lsNextFunc s)
            nt  = lsNameTable s
            qn  = unqualify name
        in ( Map.insert name fid m
           , s { lsNextFunc = lsNextFunc s + 1
               , lsNameTable = nt { ntFuncs = Map.insert fid qn (ntFuncs nt) } })
    -- Foreign fn: allocate a FuncId for the wrapper function
    allocFn (AST.DeclForeignFn _ name _ _ _) (m, s) =
        let fid = FuncId (lsNextFunc s)
            nt  = lsNameTable s
            qn  = unqualify name
        in ( Map.insert name fid m
           , s { lsNextFunc = lsNextFunc s + 1
               , lsNameTable = nt { ntFuncs = Map.insert fid qn (ntFuncs nt) } })
    -- Top-level let: each binding becomes a zero-arg function callable by name
    allocFn (AST.DeclLet _ _ target _ _ _) (m, s) =
        case letTargetName target of
            Just name ->
                let fid = FuncId (lsNextFunc s)
                    nt  = lsNameTable s
                    qn  = unqualify name
                in ( Map.insert name fid m
                   , s { lsNextFunc = lsNextFunc s + 1
                       , lsNameTable = nt { ntFuncs = Map.insert fid qn (ntFuncs nt) } })
            Nothing -> (m, s)
    allocFn _ acc = acc

    letTargetName :: AST.LetTarget SrcSpan -> Maybe Name
    letTargetName (AST.LetName n) = Just n
    letTargetName (AST.LetPat _)  = Nothing

mainPass :: [AST.Decl SrcSpan] -> LowerM ()
mainPass decls = do
    forM_ decls lowerDecl
    -- Compile top-level lets as individual named zero-arg functions
    forM_ decls $ \case
        AST.DeclLet _ _ target _ _ rhs -> case target of
            AST.LetName name -> do
                mfid <- asks (Map.lookup name . leFuncNames)
                forM_ mfid $ \fid -> do
                    saved <- saveBlockState
                    startFreshBlocks
                    retV <- lowerExpr rhs
                    finishBlockFinal (TReturn retV)
                    blocks <- collectBlocks
                    modify' (\s -> s { lsFunctions = Function fid 0 [] blocks : lsFunctions s })
                    restoreBlockState saved
            AST.LetPat _ -> lowerError noSpan "top-level pattern destructuring is not supported"
        _ -> pure ()
