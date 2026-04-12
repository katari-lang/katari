module Katari.Lowering
  ( LowerError (..),
    lowerModules,
  )
where

import Control.Monad (foldM)
import Control.Monad.State
  ( MonadState (..),
    MonadTrans (..),
    StateT (..),
    gets,
    modify,
  )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Word (Word32)
import Katari.IR
  ( AgentId,
    ConstId,
    ConstVal (..),
    ForId,
    HandlerId,
    IRAgentDef (..),
    IRForDef (..),
    IRHandleDef (..),
    IRModule (..),
    IRRequestDef (..),
    IRThread (..),
    Instruction (..),
    NameTable (..),
    RequestId,
    ThreadId,
    ThreadKind (..),
    VarId,
    emptyNameTable,
  )
import Katari.Module
  ( GlobalEnv (..),
    resolveQualified,
  )
import Katari.Syntax
  ( AgentDecl (..),
    BinOp (..),
    Block (..),
    CaseArm (..),
    Decl (..),
    Expr (..),
    ExternalAgentDecl (..),
    ExternalReqDecl (..),
    ForExpr (..),
    HandleStmt (..),
    Lit (..),
    Module (..),
    Pat (..),
    PrimTag (..),
    RequestDecl (..),
    Stmt (..),
    TemplElem (..),
    Type,
    UnOp (..),
  )

-- ---------------------------------------------------------------------------
-- Error
-- ---------------------------------------------------------------------------

newtype LowerError = LowerError String
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Lowering state
-- ---------------------------------------------------------------------------

data LowerSt = LowerSt
  { lsNextVar :: Word32,
    lsNextAgent :: Word32,
    lsNextRequest :: Word32,
    lsNextHandler :: Word32,
    lsNextFor :: Word32,
    lsNextThread :: Word32,
    lsNextLabel :: Int,
    lsCurrentModule :: Text,
    lsConstPool :: [ConstVal], -- reversed
    lsThreads :: [IRThread], -- reversed
    lsHandleDefs :: [IRHandleDef], -- reversed
    lsForDefs :: [IRForDef], -- reversed
    lsAgentDefs :: [IRAgentDef], -- reversed
    lsAgentIds :: Map Text Word32,
    lsReqIds :: Map Text Word32,
    lsRequests :: [IRRequestDef],
    lsNameTable :: NameTable
  }

type Lower a = StateT LowerSt (Either LowerError) a

-- ---------------------------------------------------------------------------
-- Instruction with placeholder labels
-- ---------------------------------------------------------------------------

type LabelId = Int

data AInstr
  = AI Instruction
  | AIBranch VarId LabelId LabelId
  | AIJump LabelId
  | AILabel LabelId
  | AISwitchL VarId [(ConstId, LabelId)] LabelId
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

lowerModules :: GlobalEnv -> [Module] -> Either LowerError IRModule
lowerModules ge modules = do
  let initSt =
        LowerSt
          { lsNextVar = 0,
            lsNextAgent = 0,
            lsNextRequest = 0,
            lsNextHandler = 0,
            lsNextFor = 0,
            lsNextThread = 0,
            lsNextLabel = 0,
            lsCurrentModule = "",
            lsConstPool = [],
            lsThreads = [],
            lsHandleDefs = [],
            lsForDefs = [],
            lsAgentDefs = [],
            lsAgentIds = Map.empty,
            lsReqIds = Map.empty,
            lsRequests = [],
            lsNameTable = emptyNameTable
          }
  ((), st) <- runStateT (lowerAll ge modules) initSt
  return
    IRModule
      { irmName = "main",
        irmNameTable = lsNameTable st,
        irmConsts = reverse (lsConstPool st),
        irmRequests = lsRequests st,
        irmThreads = reverse (lsThreads st),
        irmHandles = reverse (lsHandleDefs st),
        irmFors = reverse (lsForDefs st),
        irmAgents = reverse (lsAgentDefs st)
      }

lowerAll :: GlobalEnv -> [Module] -> Lower ()
lowerAll ge modules = do
  mapM_ (preregisterModule ge) modules
  mapM_ (lowerModule ge) modules

preregisterModule :: GlobalEnv -> Module -> Lower ()
preregisterModule ge m = do
  modify (\st -> st {lsCurrentModule = modName m})
  mapM_ (preregisterDecl ge (modName m)) (modDecls m)

preregisterDecl :: GlobalEnv -> Text -> Decl -> Lower ()
preregisterDecl _ge mname = \case
  DeclAgent _ td -> do
    _aid <- allocAgent (qualify mname (agentName td))
    return ()
  DeclRequest _ rd -> do
    let qname = qualify mname (reqName rd)
    rid <- allocRequest qname
    addRequestDef (IRRequestDef rid qname Nothing)
  DeclExtAgent _ etd -> do
    _aid <- allocAgent (qualify mname (extAgentName etd))
    return ()
  DeclExtReq _ erd -> do
    let qname = qualify mname (extReqName erd)
    rid <- allocRequest qname
    addRequestDef (IRRequestDef rid qname (Just (extReqFrom erd)))
  _ -> return ()

qualify :: Text -> Text -> Text
qualify mname local = mname <> "." <> local

resolveLocal :: GlobalEnv -> Text -> Text -> Text
resolveLocal = resolveQualified

lowerModule :: GlobalEnv -> Module -> Lower ()
lowerModule ge m = do
  modify (\st -> st {lsCurrentModule = modName m})
  mapM_ (lowerDecl ge (modName m)) (modDecls m)

lowerDecl :: GlobalEnv -> Text -> Decl -> Lower ()
lowerDecl ge mname = \case
  DeclAgent _ td -> lowerAgentDecl ge mname td
  _ -> return ()

-- ---------------------------------------------------------------------------
-- Agent lowering → FN_BODY thread + IRAgentDef
-- ---------------------------------------------------------------------------

lowerAgentDecl :: GlobalEnv -> Text -> AgentDecl -> Lower ()
lowerAgentDecl ge mname td = do
  let qname = qualify mname (agentName td)
  aid <- lookupAgent qname
  -- Allocate parameter variables
  paramVars <- mapM (\(n, _, _) -> do v <- freshVar; registerVarName v n; return (n, v)) (agentParams td)
  let allParams = map snd paramVars
      env0 = Map.fromList paramVars
  -- Lower body into instructions
  (retVar, instrs) <- lowerBlock ge env0 (agentBody td)
  -- Emit IComplete at end of FN_BODY
  let allInstrs = instrs ++ [AI (IComplete retVar)]
  -- Create FN_BODY thread
  tid <- emitThread TkFnBody allParams allInstrs
  -- Register agent def
  addAgentDef (IRAgentDef aid qname tid)

-- ---------------------------------------------------------------------------
-- Block lowering: returns (result VarId, [AInstr])
-- ---------------------------------------------------------------------------

type Env = Map Text VarId

lowerBlock :: GlobalEnv -> Env -> Block -> Lower (VarId, [AInstr])
lowerBlock ge env (Block stmts) = lowerStmts ge env stmts

lowerStmts :: GlobalEnv -> Env -> [Stmt] -> Lower (VarId, [AInstr])
lowerStmts ge env = \case
  [] -> do
    v <- freshVar
    return (v, [AI (ILoadNull v)])
  [s] -> lowerFinalStmt ge env s
  SHandle _sp hs : rest -> lowerHandleStmt ge env hs rest
  s : ss -> do
    (env', instrs) <- lowerNonFinalStmt ge env s
    (retVar, restInstrs) <- lowerStmts ge env' ss
    return (retVar, instrs ++ restInstrs)

-- Lower a non-final statement
lowerNonFinalStmt :: GlobalEnv -> Env -> Stmt -> Lower (Env, [AInstr])
lowerNonFinalStmt ge env = \case
  SLet _sp pat e -> do
    (v, instrs) <- lowerExpr ge env e
    (bindInstrs, env') <- lowerPatBind ge env v pat
    return (env', instrs ++ bindInstrs)
  SExpr _sp e -> do
    (_v, instrs) <- lowerExpr ge env e
    return (env, instrs)
  s -> do
    (_v, instrs) <- lowerFinalStmt ge env s
    return (env, instrs)

-- Lower the final statement of a block
lowerFinalStmt :: GlobalEnv -> Env -> Stmt -> Lower (VarId, [AInstr])
lowerFinalStmt ge env = \case
  SExpr _sp e -> lowerExpr ge env e
  SLet _sp _p e -> lowerExpr ge env e
  SReturn _sp e -> do
    (v, instrs) <- lowerExpr ge env e
    return (v, instrs ++ [AI (IReturn v)])
  SBreak _sp e -> do
    (v, instrs) <- lowerExpr ge env e
    return (v, instrs ++ [AI (IHandleBreak v)])
  SForBreak _sp e -> do
    (v, instrs) <- lowerExpr ge env e
    return (v, instrs ++ [AI (IForBreak v)])
  SContinue _sp e upd -> do
    (v, instrs) <- lowerExpr ge env e
    (updInstrs, stateUpds) <- lowerStateUpdates ge env (fromMaybe [] upd)
    return (v, instrs ++ updInstrs ++ [AI (IContinue v stateUpds)])
  SForContinue _sp upd -> do
    (updInstrs, stateUpds) <- lowerForStateUpdates ge env (fromMaybe [] upd)
    v <- freshVar
    return (v, updInstrs ++ [AI (IForContinue stateUpds)])
  SHandle _sp _hs -> do
    v <- freshVar
    return (v, [AI (ILoadNull v)])

-- ---------------------------------------------------------------------------
-- Handle lowering (core change)
-- ---------------------------------------------------------------------------

lowerHandleStmt :: GlobalEnv -> Env -> HandleStmt -> [Stmt] -> Lower (VarId, [AInstr])
lowerHandleStmt ge env hs rest = do
  hid <- freshHandler
  -- 1. Lower state init exprs in current thread
  (initInstrs, stateVars, stateInits) <- lowerHandleStateInits ge env (hParams hs)
  -- Build env extended with state variable names
  let stateNames = map (\(n, _, _, _) -> n) (hParams hs)
      stateEnv = foldr (\(n, v) e -> Map.insert n v e) env (zip stateNames stateVars)
  -- 2. Cut rest (remaining stmts) → HANDLER_TARGET thread
  bodyTid <- lowerHandlerTarget ge env rest
  -- 3. Request cases → REQUEST_HANDLER threads
  reqCases <- mapM (lowerReqCaseThread ge stateEnv) (hReqCases hs)
  -- 4. Then clause → HANDLE_THEN thread
  thenTid <- case hThenClause hs of
    Nothing -> return Nothing
    Just (var, body) -> do
      inputV <- freshVar
      registerVarName inputV var
      let thenEnv = Map.insert var inputV stateEnv
      (retV, bodyInstrs) <- lowerBlock ge thenEnv body
      tid <- emitThread TkHandleThen [inputV] (bodyInstrs ++ [AI (IComplete retV)])
      return (Just tid)
  -- 5. Register IRHandleDef
  addHandleDef
    IRHandleDef
      { ihdId = hid,
        ihdStateVars = stateVars,
        ihdStateInits = stateInits,
        ihdBody = bodyTid,
        ihdReqCases = reqCases,
        ihdThen = thenTid
      }
  -- 6. Emit IHandle in current thread
  dst <- freshVar
  return (dst, initInstrs ++ [AI (IHandle dst hid)])

lowerHandleStateInits ::
  GlobalEnv ->
  Env ->
  [(Text, Type, Maybe Text, Expr)] ->
  Lower ([AInstr], [VarId], [VarId])
lowerHandleStateInits ge env params = do
  results <-
    mapM
      ( \(n, _ty, _an, e) -> do
          (initV, instrs) <- lowerExpr ge env e
          stateV <- freshVar
          registerVarName stateV n
          return (stateV, initV, instrs)
      )
      params
  let allInstrs = concatMap (\(_, _, is) -> is) results
      stateVars = map (\(sv, _, _) -> sv) results
      initVars = map (\(_, iv, _) -> iv) results
  return (allInstrs, stateVars, initVars)

lowerHandlerTarget :: GlobalEnv -> Env -> [Stmt] -> Lower ThreadId
lowerHandlerTarget ge env stmts = do
  (retV, instrs) <- lowerStmts ge env stmts
  emitThread TkHandlerTarget [] (instrs ++ [AI (IComplete retV)])

lowerReqCaseThread ::
  GlobalEnv ->
  Env ->
  (Text, [Pat], Block) ->
  Lower (RequestId, ThreadId)
lowerReqCaseThread ge env (reqName, argPats, body) = do
  mname <- gets lsCurrentModule
  let qname = resolveLocal ge mname reqName
  rid <- lookupOrAllocRequest qname
  -- Allocate arg vars
  argVars <- mapM (const freshVar) argPats
  -- Bind patterns
  (bindInstrs, env') <-
    foldM
      ( \(accI, accEnv) (pat, v) -> do
          (is, e) <- lowerPatBind ge accEnv v pat
          return (accI ++ is, e)
      )
      ([], env)
      (zip argPats argVars)
  (retV, bodyInstrs) <- lowerBlock ge env' body
  tid <- emitThread TkRequestHandler argVars (bindInstrs ++ bodyInstrs ++ [AI (IComplete retV)])
  return (rid, tid)

-- ---------------------------------------------------------------------------
-- State update helpers
-- ---------------------------------------------------------------------------

lowerStateUpdates :: GlobalEnv -> Env -> [(Text, Expr)] -> Lower ([AInstr], [(VarId, VarId)])
lowerStateUpdates ge env upds = do
  results <-
    mapM
      ( \(n, e) -> do
          (v, instrs) <- lowerExpr ge env e
          let stateV = fromMaybe 0 (Map.lookup n env)
          return (instrs, (stateV, v))
      )
      upds
  let allInstrs = concatMap fst results
      pairs = map snd results
  return (allInstrs, pairs)

lowerForStateUpdates :: GlobalEnv -> Env -> [(Text, Expr)] -> Lower ([AInstr], [(VarId, VarId)])
lowerForStateUpdates = lowerStateUpdates

-- ---------------------------------------------------------------------------
-- For lowering
-- ---------------------------------------------------------------------------

lowerForExpr :: GlobalEnv -> Env -> ForExpr -> Lower (VarId, [AInstr])
lowerForExpr ge env fe = do
  fid <- freshForId
  let lets = fLetBinds fe
      vars = fVarBinds fe
  -- Lower var init exprs (state variables)
  varInits <-
    mapM
      ( \(n, _ty, e) -> do
          (v, instrs) <- lowerExpr ge env e
          stateV <- freshVar
          registerVarName stateV n
          return (n, stateV, v, instrs)
      )
      vars
  let varInstrs = concatMap (\(_, _, _, is) -> is) varInits
      stateVars = map (\(_, sv, _, _) -> sv) varInits
      stateInits = map (\(_, _, iv, _) -> iv) varInits
      varEnv = foldr (\(n, sv, _, _) e -> Map.insert n sv e) env varInits
  -- Lower let array exprs
  letResults <-
    mapM
      ( \(n, e) -> do
          (v, instrs) <- lowerExpr ge env e
          return (n, v, instrs)
      )
      lets
  let letInstrs = concatMap (\(_, _, is) -> is) letResults
      arrVars = map (\(_, v, _) -> v) letResults
  -- Allocate element vars
  elemVars <-
    mapM
      ( \(n, _) -> do
          ev <- freshVar
          registerVarName ev n
          return ev
      )
      lets
  let bodyEnv = foldr (\((n, _), ev) e -> Map.insert n ev e) varEnv (zip lets elemVars)
  -- Lower body → FOR_BODY thread (params = element vars)
  (_, bodyInstrs) <- lowerBlock ge bodyEnv (fBody fe)
  -- FOR_BODY must end with IForContinue or IForBreak (already emitted by SContinue/SForBreak)
  bodyTid <- emitThread TkForBody elemVars bodyInstrs
  -- Then clause → FOR_THEN thread
  thenTid <- case fThen fe of
    Nothing -> return Nothing
    Just fb -> do
      (tv, thenInstrs) <- lowerBlock ge varEnv fb
      tid <- emitThread TkForThen [] (thenInstrs ++ [AI (IComplete tv)])
      return (Just tid)
  -- Register IRForDef
  addForDef
    IRForDef
      { ifdId = fid,
        ifdIterVars = elemVars,
        ifdArrays = arrVars,
        ifdStateVars = stateVars,
        ifdStateInits = stateInits,
        ifdBody = bodyTid,
        ifdThen = thenTid
      }
  -- Emit IFor in current thread
  dst <- freshVar
  return (dst, letInstrs ++ varInstrs ++ [AI (IFor dst fid)])

-- ---------------------------------------------------------------------------
-- Par lowering
-- ---------------------------------------------------------------------------

lowerParExpr :: GlobalEnv -> Env -> [Block] -> Lower (VarId, [AInstr])
lowerParExpr ge env blocks = do
  tids <- mapM (lowerParBranch ge env) blocks
  dst <- freshVar
  return (dst, [AI (IPar dst tids)])

lowerParBranch :: GlobalEnv -> Env -> Block -> Lower ThreadId
lowerParBranch ge env block = do
  (retV, instrs) <- lowerBlock ge env block
  emitThread TkBlock [] (instrs ++ [AI (IComplete retV)])

-- ---------------------------------------------------------------------------
-- Pattern binding
-- ---------------------------------------------------------------------------

lowerPatBind :: GlobalEnv -> Env -> VarId -> Pat -> Lower ([AInstr], Env)
lowerPatBind ge env v = \case
  PVar n -> return ([], Map.insert n v env)
  PTyped n _ -> return ([], Map.insert n v env)
  PTag _ n -> return ([], Map.insert n v env)
  PLit _ -> return ([], env)
  PObj fields ->
    foldM
      ( \(accI, accEnv) (name, _, pat) -> do
          fv <- freshVar
          cid <- addConst (CVStr name)
          (subI, subEnv) <- lowerPatBind ge accEnv fv pat
          return (accI ++ [AI (IGetField fv v cid)] ++ subI, subEnv)
      )
      ([], env)
      fields
  PArr pats ->
    foldM
      ( \(accI, accEnv) (i, pat) -> do
          iv <- freshVar
          ev <- freshVar
          cid <- addConst (CVInt (toInteger (i :: Int)))
          (subI, subEnv) <- lowerPatBind ge accEnv ev pat
          return (accI ++ [AI (ILoadConst iv cid), AI (IArrGet ev v iv)] ++ subI, subEnv)
      )
      ([], env)
      (zip [0 ..] pats)

-- ---------------------------------------------------------------------------
-- Expression lowering
-- ---------------------------------------------------------------------------

lowerExpr :: GlobalEnv -> Env -> Expr -> Lower (VarId, [AInstr])
lowerExpr ge env = \case
  ELit _sp lit -> do
    v <- freshVar
    case lit of
      LNull -> return (v, [AI (ILoadNull v)])
      LBool b -> do
        cid <- addConst (CVBool b)
        return (v, [AI (ILoadConst v cid)])
      LInt i -> do
        cid <- addConst (CVInt i)
        return (v, [AI (ILoadConst v cid)])
      LNum n -> do
        cid <- addConst (CVNum n)
        return (v, [AI (ILoadConst v cid)])
      LStr s -> do
        cid <- addConst (CVStr s)
        return (v, [AI (ILoadConst v cid)])
  EVar _sp name -> do
    v <- freshVar
    case Map.lookup name env of
      Just src -> return (v, [AI (IMove v src)])
      Nothing -> return (v, [AI (ILoadNull v)])
  EField _sp e field -> do
    (src, instrs) <- lowerExpr ge env e
    v <- freshVar
    cid <- addConst (CVStr field)
    return (v, instrs ++ [AI (IGetField v src cid)])
  EArr _sp elems -> do
    results <- mapM (lowerExpr ge env) elems
    let allInstrs = concatMap snd results
        vars = map fst results
    dst <- freshVar
    return (dst, allInstrs ++ [AI (INewArray dst vars)])
  EObj _sp fields -> do
    results <-
      mapM
        ( \(name, _isUniq, e) -> do
            cid <- addConst (CVStr name)
            (v, instrs) <- lowerExpr ge env e
            return (cid, v, instrs)
        )
        fields
    let allInstrs = concatMap (\(_, _, is) -> is) results
        fieldPairs = map (\(cid, v, _) -> (cid, v)) results
    dst <- freshVar
    return (dst, allInstrs ++ [AI (INewObject dst fieldPairs)])
  ECall _sp callee args -> do
    argResults <- mapM (lowerExpr ge env) args
    let argInstrs = concatMap snd argResults
        argVars = map fst argResults
    case callee of
      EVar _ name -> do
        dst <- freshVar
        mname <- gets lsCurrentModule
        let qname = resolveLocal ge mname name
        case Map.lookup qname (geAgents ge) of
          Just _ai -> do
            aid <- lookupOrAllocAgent qname
            return (dst, argInstrs ++ [AI (ICall dst aid argVars)])
          Nothing ->
            case Map.lookup qname (geRequests ge) of
              Just _ri -> do
                rid <- lookupOrAllocRequest qname
                return (dst, argInstrs ++ [AI (IRequest dst rid argVars)])
              Nothing ->
                return (dst, argInstrs ++ [AI (ILoadNull dst)])
      EField _sp2 obj "__index__" -> do
        (arrVar, arrInstrs) <- lowerExpr ge env obj
        let idxVar = head argVars
        dst <- freshVar
        return (dst, argInstrs ++ arrInstrs ++ [AI (IArrGet dst arrVar idxVar)])
      _ -> do
        (_calleeVar, calleeInstrs) <- lowerExpr ge env callee
        dst <- freshVar
        return (dst, argInstrs ++ calleeInstrs ++ [AI (ILoadNull dst)])
  EBinOp _sp op l r -> do
    (lv, li) <- lowerExpr ge env l
    (rv, ri) <- lowerExpr ge env r
    dst <- freshVar
    let instr = lowerBinOp op dst lv rv
    return (dst, li ++ ri ++ [AI instr])
  EUnOp _sp op e -> do
    (src, instrs) <- lowerExpr ge env e
    dst <- freshVar
    let instr = case op of
          UnNeg -> INeg dst src
          UnNot -> INot dst src
    return (dst, instrs ++ [AI instr])
  EIf _sp cond thn els -> do
    (condV, condI) <- lowerExpr ge env cond
    lbl_then <- freshLabel
    lbl_else <- freshLabel
    lbl_end <- freshLabel
    (thnV, thnI) <- lowerBlock ge env thn
    (elsV, elsI) <- lowerBlock ge env els
    dst <- freshVar
    let instrs =
          condI
            ++ [ AIBranch condV lbl_then lbl_else,
                 AILabel lbl_then
               ]
            ++ thnI
            ++ [ AI (IMove dst thnV),
                 AIJump lbl_end,
                 AILabel lbl_else
               ]
            ++ elsI
            ++ [ AI (IMove dst elsV),
                 AIJump lbl_end,
                 AILabel lbl_end
               ]
    return (dst, instrs)
  EMatch _sp e arms -> do
    (scrutV, scrutI) <- lowerExpr ge env e
    lbl_end <- freshLabel
    dst <- freshVar
    armResults <- mapM (lowerArm ge env scrutV dst lbl_end) arms
    let armInstrs = concatMap fst armResults
    let fallthrough = AI (ILoadNull dst)
    return (dst, scrutI ++ armInstrs ++ [fallthrough, AILabel lbl_end])
  EFor _sp fe -> lowerForExpr ge env fe
  EPar _sp blocks -> lowerParExpr ge env blocks
  EBlock _sp b -> lowerBlock ge env b
  ETempl _sp elems -> do
    results <- mapM (lowerTemplElem ge env) elems
    let allInstrs = concatMap fst results
        strs = map snd results
    (v, extraInstrs) <- case strs of
      [] -> do
        fv <- freshVar
        cid <- addConst (CVStr "")
        return (fv, [AI (ILoadConst fv cid)])
      [sv] -> return (sv, [])
      (sv : svs) -> do
        (final, accI) <- foldM catStep (sv, []) svs
        return (final, accI)
    return (v, allInstrs ++ extraInstrs)
    where
      catStep (acc, accI) sv = do
        res <- freshVar
        return (res, accI ++ [AI (IConcat res acc sv)])

-- ---------------------------------------------------------------------------
-- Match arms
-- ---------------------------------------------------------------------------

lowerArm ::
  GlobalEnv ->
  Env ->
  VarId ->
  VarId ->
  LabelId ->
  CaseArm ->
  Lower ([AInstr], ())
lowerArm ge env scrutV dst lbl_end (CaseArm pat body) = do
  lbl_match <- freshLabel
  lbl_next <- freshLabel
  (checkInstrs, env') <- lowerPatCheck ge env scrutV pat lbl_match lbl_next
  (bodyV, bodyI) <- lowerBlock ge env' body
  let instrs =
        checkInstrs
          ++ [AILabel lbl_match]
          ++ bodyI
          ++ [AI (IMove dst bodyV), AIJump lbl_end, AILabel lbl_next]
  return (instrs, ())

lowerPatCheck ::
  GlobalEnv ->
  Env ->
  VarId ->
  Pat ->
  LabelId ->
  LabelId ->
  Lower ([AInstr], Env)
lowerPatCheck ge env scrutV pat lbl_match lbl_next = case pat of
  PVar n -> do
    let env' = Map.insert n scrutV env
    return ([AIJump lbl_match], env')
  PTyped n _ty -> do
    let env' = Map.insert n scrutV env
    return ([AIJump lbl_match], env')
  PLit lit -> do
    litVar <- freshVar
    cmpVar <- freshVar
    cid <- addConst (litConstVal lit)
    let instrs =
          [ AI (ILoadConst litVar cid),
            AI (ICmpEq cmpVar scrutV litVar),
            AIBranch cmpVar lbl_match lbl_next
          ]
    return (instrs, env)
  PTag tag varName -> do
    typeVar <- freshVar
    cmpVar <- freshVar
    tagStr <- freshVar
    tagCid <- addConst (CVStr (tagToStr tag))
    let instrs =
          [ AI (ITypeOf typeVar scrutV),
            AI (ILoadConst tagStr tagCid),
            AI (ICmpEq cmpVar typeVar tagStr),
            AIBranch cmpVar lbl_match lbl_next
          ]
    let env' = Map.insert varName scrutV env
    return (instrs, env')
  PObj fields -> do
    let uniqFields = [(name, p) | (name, True, p) <- fields]
        nonUniqFields = [(name, p) | (name, False, p) <- fields]
    case uniqFields of
      [(discName, PLit discLit)] -> do
        fieldVar <- freshVar
        cmpVar <- freshVar
        litVar <- freshVar
        nameCid <- addConst (CVStr discName)
        litCid <- addConst (litConstVal discLit)
        lbl_check_fields <- freshLabel
        (fieldInstrs, env') <- lowerObjFieldBindings ge env scrutV nonUniqFields lbl_match lbl_next
        let instrs =
              [ AI (IGetField fieldVar scrutV nameCid),
                AI (ILoadConst litVar litCid),
                AI (ICmpEq cmpVar fieldVar litVar),
                AIBranch cmpVar lbl_check_fields lbl_next,
                AILabel lbl_check_fields
              ]
                ++ fieldInstrs
        return (instrs, env')
      _ -> do
        lowerObjFieldBindings ge env scrutV (map (\(n, _, p) -> (n, p)) fields) lbl_match lbl_next
  PArr pats -> lowerArrPatBindings ge env scrutV pats lbl_match lbl_next

lowerObjFieldBindings ::
  GlobalEnv ->
  Env ->
  VarId ->
  [(Text, Pat)] ->
  LabelId ->
  LabelId ->
  Lower ([AInstr], Env)
lowerObjFieldBindings ge env scrutV fields lbl_match lbl_next = case fields of
  [] -> return ([AIJump lbl_match], env)
  (name, pat) : rest -> do
    fieldVar <- freshVar
    nameCid <- addConst (CVStr name)
    let getInstr = AI (IGetField fieldVar scrutV nameCid)
    lbl_sub_match <- freshLabel
    (checkInstrs, env') <- lowerPatCheck ge env fieldVar pat lbl_sub_match lbl_next
    (restInstrs, env'') <- lowerObjFieldBindings ge env' scrutV rest lbl_match lbl_next
    let instrs = [getInstr] ++ checkInstrs ++ [AILabel lbl_sub_match] ++ restInstrs
    return (instrs, env'')

lowerArrPatBindings ::
  GlobalEnv ->
  Env ->
  VarId ->
  [Pat] ->
  LabelId ->
  LabelId ->
  Lower ([AInstr], Env)
lowerArrPatBindings ge env scrutV pats lbl_match lbl_next = case pats of
  [] -> return ([AIJump lbl_match], env)
  _ -> do
    (instrs, env') <- go pats (0 :: Int) env
    return (instrs ++ [AIJump lbl_match], env')
  where
    go ps0 i e = case ps0 of
      [] -> return ([], e)
      p : ps -> do
        idxVar <- freshVar
        elemVar <- freshVar
        idxCid <- addConst (CVInt (toInteger i))
        let idxInstrs = [AI (ILoadConst idxVar idxCid), AI (IArrGet elemVar scrutV idxVar)]
        lbl_sub_match <- freshLabel
        (checkInstrs, e') <- lowerPatCheck ge e elemVar p lbl_sub_match lbl_next
        (restInstrs, e'') <- go ps (i + 1) e'
        let instrs = idxInstrs ++ checkInstrs ++ [AILabel lbl_sub_match] ++ restInstrs
        return (instrs, e'')

-- ---------------------------------------------------------------------------
-- Template elements
-- ---------------------------------------------------------------------------

lowerTemplElem :: GlobalEnv -> Env -> TemplElem -> Lower ([AInstr], VarId)
lowerTemplElem ge env = \case
  TemplStr s -> do
    v <- freshVar
    cid <- addConst (CVStr s)
    return ([AI (ILoadConst v cid)], v)
  TemplExpr e -> do
    (v, instrs) <- lowerExpr ge env e
    str <- freshVar
    return (instrs ++ [AI (IToString str v)], str)

-- ---------------------------------------------------------------------------
-- Binary op lowering
-- ---------------------------------------------------------------------------

lowerBinOp :: BinOp -> VarId -> VarId -> VarId -> Instruction
lowerBinOp op d l r = case op of
  OpAdd -> IAdd d l r
  OpSub -> ISub d l r
  OpMul -> IMul d l r
  OpDiv -> IDiv d l r
  OpConcat -> IConcat d l r
  OpLt -> ICmpLt d l r
  OpLe -> ICmpLe d l r
  OpGt -> ICmpGt d l r
  OpGe -> ICmpGe d l r
  OpEq -> ICmpEq d l r
  OpNe -> ICmpNe d l r
  OpAnd -> IAnd d l r
  OpOr -> IOr d l r

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

litConstVal :: Lit -> ConstVal
litConstVal = \case
  LNull -> CVNull
  LBool b -> CVBool b
  LInt i -> CVInt i
  LNum n -> CVNum n
  LStr s -> CVStr s

tagToStr :: PrimTag -> Text
tagToStr = \case
  TagBoolean -> "boolean"
  TagInteger -> "integer"
  TagNumber -> "number"
  TagString -> "string"

-- ---------------------------------------------------------------------------
-- Thread emission
-- ---------------------------------------------------------------------------

emitThread :: ThreadKind -> [VarId] -> [AInstr] -> Lower ThreadId
emitThread kind params instrs = do
  tid <- freshThreadId
  resolved <- liftEither (resolveLabels instrs)
  let thread = IRThread tid kind params resolved
  modify (\st -> st {lsThreads = thread : lsThreads st})
  return tid

-- ---------------------------------------------------------------------------
-- Label resolution (2-pass)
-- ---------------------------------------------------------------------------

resolveLabels :: [AInstr] -> Either LowerError [Instruction]
resolveLabels ais = do
  let labelMap = buildLabelMap ais 0
  mapM (resolveOne labelMap) (filter (not . isLabel) ais)

buildLabelMap :: [AInstr] -> Int -> Map LabelId Word32
buildLabelMap ais pos = case ais of
  [] -> Map.empty
  AILabel lbl : rest -> Map.insert lbl (fromIntegral pos) (buildLabelMap rest pos)
  _ : rest -> buildLabelMap rest (pos + 1)

isLabel :: AInstr -> Bool
isLabel = \case
  AILabel _ -> True
  _ -> False

resolveOne :: Map LabelId Word32 -> AInstr -> Either LowerError Instruction
resolveOne lm = \case
  AI instr -> Right instr
  AIBranch v l_t l_f -> do
    t <- lookupLabel lm l_t
    f <- lookupLabel lm l_f
    return (IBranch v t f)
  AIJump lbl -> do
    t <- lookupLabel lm lbl
    return (IJump t)
  AISwitchL v cases def -> do
    cs <- mapM (\(cid, lbl) -> do t <- lookupLabel lm lbl; return (cid, t)) cases
    d <- lookupLabel lm def
    return (ISwitch v cs d)
  AILabel _ -> Left (LowerError "Label in non-label position")

lookupLabel :: Map LabelId Word32 -> LabelId -> Either LowerError Word32
lookupLabel lm lbl =
  case Map.lookup lbl lm of
    Just pos -> Right pos
    Nothing -> Left (LowerError ("Undefined label: " ++ show lbl))

liftEither :: Either LowerError a -> Lower a
liftEither (Left e) = lift (Left e)
liftEither (Right a) = return a

-- ---------------------------------------------------------------------------
-- Allocation helpers
-- ---------------------------------------------------------------------------

freshVar :: Lower VarId
freshVar = do
  st <- get
  let v = lsNextVar st
  put st {lsNextVar = v + 1}
  return v

freshHandler :: Lower HandlerId
freshHandler = do
  st <- get
  let h = lsNextHandler st
  put st {lsNextHandler = h + 1}
  return h

freshLabel :: Lower LabelId
freshLabel = do
  st <- get
  let l = lsNextLabel st
  put st {lsNextLabel = l + 1}
  return l

freshForId :: Lower ForId
freshForId = do
  st <- get
  let f = lsNextFor st
  put st {lsNextFor = f + 1}
  return f

freshThreadId :: Lower ThreadId
freshThreadId = do
  st <- get
  let tid = lsNextThread st
  put st {lsNextThread = tid + 1}
  return tid

freshAgentId :: Lower AgentId
freshAgentId = do
  st <- get
  let aid = lsNextAgent st
  put st {lsNextAgent = aid + 1}
  return aid

allocAgent :: Text -> Lower AgentId
allocAgent name = do
  existing <- gets (Map.lookup name . lsAgentIds)
  case existing of
    Just aid -> return aid
    Nothing -> do
      aid <- freshAgentId
      modify
        ( \s ->
            s
              { lsAgentIds = Map.insert name aid (lsAgentIds s),
                lsNameTable =
                  (lsNameTable s)
                    { ntAgents = Map.insert aid name (ntAgents (lsNameTable s))
                    }
              }
        )
      return aid

allocRequest :: Text -> Lower RequestId
allocRequest name = do
  existing <- gets (Map.lookup name . lsReqIds)
  case existing of
    Just rid -> return rid
    Nothing -> do
      rid <- gets lsNextRequest
      modify
        ( \s ->
            s
              { lsNextRequest = rid + 1,
                lsReqIds = Map.insert name rid (lsReqIds s),
                lsNameTable =
                  (lsNameTable s)
                    { ntRequests = Map.insert rid name (ntRequests (lsNameTable s))
                    }
              }
        )
      return rid

lookupAgent :: Text -> Lower AgentId
lookupAgent name = do
  st <- get
  case Map.lookup name (lsAgentIds st) of
    Just aid -> return aid
    Nothing -> allocAgent name

lookupOrAllocAgent :: Text -> Lower AgentId
lookupOrAllocAgent = lookupAgent

lookupOrAllocRequest :: Text -> Lower RequestId
lookupOrAllocRequest = allocRequest

addConst :: ConstVal -> Lower ConstId
addConst cv = do
  st <- get
  let pool = lsConstPool st
      existing =
        [ fromIntegral (length pool - 1 - i)
          | (i, c) <- zip [0 ..] pool,
            c == cv
        ]
  case existing of
    (cid : _) -> return cid
    [] -> do
      let cid = fromIntegral (length pool)
      put st {lsConstPool = cv : pool}
      return cid

addAgentDef :: IRAgentDef -> Lower ()
addAgentDef ad = modify (\st -> st {lsAgentDefs = ad : lsAgentDefs st})

addHandleDef :: IRHandleDef -> Lower ()
addHandleDef hd = modify (\st -> st {lsHandleDefs = hd : lsHandleDefs st})

addForDef :: IRForDef -> Lower ()
addForDef fd = modify (\st -> st {lsForDefs = fd : lsForDefs st})

addRequestDef :: IRRequestDef -> Lower ()
addRequestDef rd = modify (\st -> st {lsRequests = rd : lsRequests st})

registerVarName :: VarId -> Text -> Lower ()
registerVarName vid name =
  modify
    ( \s ->
        s
          { lsNameTable =
              (lsNameTable s)
                { ntVars = Map.insert vid name (ntVars (lsNameTable s))
                }
          }
    )
