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
import Data.Text qualified as T
import Data.Word (Word32)
import Katari.IR
  ( AgentId,
    AgentKind (..),
    ConstId,
    ConstVal (..),
    ForId,
    HandlerId,
    IRForScope (..),
    IRHandleScope (..),
    IRModule (..),
    IRRequestDef (..),
    IRAgent (..),
    Instruction (..),
    NameTable (..),
    RequestId,
    VarId,
    emptyNameTable,
  )
import Katari.Module
  ( GlobalEnv (..),
    resolveQualified,
  )
import Katari.Syntax
  ( BinOp (..),
    Block (..),
    CaseArm (..),
    Decl (..),
    Expr (..),
    ExternalReqDecl (..),
    ExternalAgentDecl (..),
    ForExpr (..),
    HandleStmt (..),
    Lit (..),
    Module (..),
    Pat (..),
    PrimTag (..),
    RequestDecl (..),
    Stmt (..),
    AgentDecl (..),
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
    lsNextLabel :: Int, -- dedicated label counter
    lsStateVarIdxMap :: Map Text Word32, -- current state var name → index (for continue/break with)
    lsCurrentHandler :: Maybe HandlerId, -- handler ID currently being lowered (for continue/break)
    lsCurrentFor :: Maybe ForId, -- current for scope ID (for break/continue)
    lsForBreakCtx :: Maybe (VarId, LabelId, ForId), -- (dst, lbl_after, for_id) for SForBreak
    lsCurrentModule :: Text, -- module name currently being lowered (for name resolution)
    lsConstPool :: [ConstVal], -- reversed
    lsAgents :: [IRAgent], -- accumulated agents
    lsForScopes :: [IRForScope], -- accumulated for scopes for current agent
    lsAgentIds :: Map Text Word32, -- qualified agent name → ID
    lsReqIds :: Map Text Word32, -- qualified request name → ID
    lsRequests :: [IRRequestDef], -- accumulated request defs
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
            lsNextLabel = 0,
            lsStateVarIdxMap = Map.empty,
            lsCurrentHandler = Nothing,
            lsCurrentFor = Nothing,
            lsForBreakCtx = Nothing,
            lsCurrentModule = "",
            lsConstPool = [],
            lsAgents = [],
            lsForScopes = [],
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
        irmAgents = reverse (lsAgents st)
      }

lowerAll :: GlobalEnv -> [Module] -> Lower ()
lowerAll ge modules = do
  -- Pre-register all agents and requests with IDs
  mapM_ (preregisterModule ge) modules
  -- Lower all agents
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

-- Resolve a local name to its qualified form using the global alias table
-- for the current module.
resolveLocal :: GlobalEnv -> Text -> Text -> Text
resolveLocal = resolveQualified

lowerModule :: GlobalEnv -> Module -> Lower ()
lowerModule ge m = do
  modify (\st -> st {lsCurrentModule = modName m})
  mapM_ (lowerDecl ge (modName m)) (modDecls m)

lowerDecl :: GlobalEnv -> Text -> Decl -> Lower ()
lowerDecl ge mname = \case
  DeclAgent _ td -> lowerAgent ge mname td Map.empty
  DeclExtAgent _ _ -> return () -- no body to lower
  _ -> return ()

-- ---------------------------------------------------------------------------
-- Agent lowering
-- ---------------------------------------------------------------------------

lowerAgent :: GlobalEnv -> Text -> AgentDecl -> Map Text VarId -> Lower ()
lowerAgent ge mname td extraCaptures = do
  let qname = qualify mname (agentName td)
  aid <- lookupAgent qname
  -- Save and reset per-agent accumulators
  oldForScopes <- gets lsForScopes
  modify (\st -> st {lsForScopes = []})
  -- Allocate parameter variables
  paramVars <- mapM (\(n, _, _) -> do v <- freshVar; return (n, v)) (agentParams td)
  let captures = Map.toList extraCaptures
  captureVars <- mapM (\(n, cv) -> return (n, cv)) captures
  let allParams = map snd paramVars
      env0 = Map.fromList (paramVars ++ captureVars)
  -- Lower body
  (retVar, instrs, handlers) <- lowerBlock ge env0 (agentBody td)
  -- Append IReturn
  let retInstr = AI (IReturn retVar)
      allInstrs = instrs ++ [retInstr]
  -- Resolve labels
  resolved <- liftEither (resolveLabels allInstrs)
  forScopes <- gets lsForScopes
  let irAgent =
        IRAgent
          { iraId = aid,
            iraKind = UserDefined,
            iraName = qname,
            iraParams = allParams,
            iraBody = resolved,
            iraHandlers = handlers,
            iraForScopes = reverse forScopes
          }
  addAgent irAgent
  modify (\st -> st {lsForScopes = oldForScopes})

liftEither :: Either LowerError a -> Lower a
liftEither (Left e) = lift (Left e)
liftEither (Right a) = return a

-- ---------------------------------------------------------------------------
-- Block lowering: returns (result VarId, instructions, handle blocks)
-- ---------------------------------------------------------------------------

type Env = Map Text VarId

lowerBlock :: GlobalEnv -> Env -> Block -> Lower (VarId, [AInstr], [IRHandleScope])
lowerBlock ge env (Block stmts) = lowerStmts ge env stmts

lowerStmts :: GlobalEnv -> Env -> [Stmt] -> Lower (VarId, [AInstr], [IRHandleScope])
lowerStmts ge env stmts = case stmts of
  [] -> do
    v <- freshVar
    return (v, [AI (ILoadNull v)], [])
  [s] -> lowerFinalStmt ge env s
  SHandle _sp hs : rest -> do
    -- Handle statement: allocate handler, lower scope (rest), emit Begin/End
    hid <- freshHandler
    -- Lower the handle params (init exprs)
    (paramInstrs, stateVars) <- lowerHandleParams ge env (hParams hs)
    -- Build env extended with state variable names → their VarIds
    let stateNames = map (\(n, _, _, _) -> n) (hParams hs)
        stateEnv = foldr (\(n, v) e -> Map.insert n v e) env (zip stateNames stateVars)
    -- Lower the handlers (with stateEnv so bodies can reference state vars)
    (reqCases, thenClause, innerHs) <- lowerHandlers ge stateEnv hid hs
    let handler =
          IRHandleScope
            { irhId = hid,
              irhStateVars = stateVars,
              irhReqCases = reqCases,
              irhThenClause = thenClause
            }
    -- Lower the rest of the block (the handle scope)
    (scopeVar, restInstrs, restHandlers) <- lowerStmts ge env rest
    dst <- freshVar
    let beginInstr = AI (IHandleBegin hid)
        endInstr = AI (IHandleEnd dst scopeVar hid)
    return
      ( dst,
        paramInstrs ++ [beginInstr] ++ restInstrs ++ [endInstr],
        innerHs ++ [handler] ++ restHandlers
      )
  s : ss -> do
    (env', instrs, handlers) <- lowerNonFinalStmt ge env s
    (retVar, restInstrs, restHandlers) <- lowerStmts ge env' ss
    return (retVar, instrs ++ restInstrs, handlers ++ restHandlers)

-- Lower a non-final statement (not the last one)
lowerNonFinalStmt :: GlobalEnv -> Env -> Stmt -> Lower (Env, [AInstr], [IRHandleScope])
lowerNonFinalStmt ge env stmt = case stmt of
  SLet _sp pat e -> do
    (v, instrs, handlers) <- lowerExpr ge env e
    (bindInstrs, env') <- lowerPatBind ge env v pat
    return (env', instrs ++ bindInstrs, handlers)
  SExpr _sp e -> do
    (_v, instrs, handlers) <- lowerExpr ge env e
    return (env, instrs, handlers)
  s -> do
    -- For other stmts (return, etc.), lower and discard env change
    (_v, instrs, handlers) <- lowerFinalStmt ge env s
    return (env, instrs, handlers)

-- Lower the final statement of a block
lowerFinalStmt :: GlobalEnv -> Env -> Stmt -> Lower (VarId, [AInstr], [IRHandleScope])
lowerFinalStmt ge env = \case
  SExpr _sp e -> lowerExpr ge env e
  SLet _sp _p e -> lowerExpr ge env e
  SReturn _sp e -> do
    (v, instrs, handlers) <- lowerExpr ge env e
    return (v, instrs ++ [AI (IReturn v)], handlers)
  SBreak _sp e -> do
    (v, instrs, handlers) <- lowerExpr ge env e
    hid <- gets (fromMaybe 0 . lsCurrentHandler)
    return (v, instrs ++ [AI (IHandleBreak v hid)], handlers)
  SForBreak _sp e -> do
    (v, instrs, handlers) <- lowerExpr ge env e
    ctx <- gets lsForBreakCtx
    case ctx of
      Just (dstV, lbl_after, fid) ->
        return (v, instrs ++ [AI (IForBreak v fid), AI (IMove dstV v), AIJump lbl_after], handlers)
      Nothing ->
        liftEither (Left (LowerError "for_break outside of for expression"))
  SContinue _sp e upd -> do
    (v, instrs, handlers) <- lowerExpr ge env e
    (updInstrs, stateUpds) <- lowerStateUpdates ge env (fromMaybe [] upd)
    hid <- gets (fromMaybe 0 . lsCurrentHandler)
    return (v, instrs ++ updInstrs ++ [AI (IContinue v hid stateUpds)], handlers)
  SForContinue _sp upd -> do
    -- For-loop state: update vars directly via IMove (not slot-based like handlers)
    moveInstrs <-
      mapM
        ( \(n, e) -> do
            (newV, instrs, _) <- lowerExpr ge env e
            case Map.lookup n env of
              Just targetV -> return (instrs ++ [AI (IMove targetV newV)])
              Nothing -> return instrs
        )
        (fromMaybe [] upd)
    fid <- gets (fromMaybe 0 . lsCurrentFor)
    v <- freshVar
    return (v, concat moveInstrs ++ [AI (IForContinue fid []), AI (ILoadNull v)], [])
  SHandle _sp _hs -> do
    v <- freshVar
    return (v, [AI (ILoadNull v)], [])

lowerStateUpdates :: GlobalEnv -> Env -> [(Text, Expr)] -> Lower ([AInstr], [(Word32, VarId)])
lowerStateUpdates ge env upds = do
  idxMap <- gets lsStateVarIdxMap
  results <-
    mapM
      ( \(n, e) -> do
          (v, instrs, _) <- lowerExpr ge env e
          let idx = fromMaybe 0 (Map.lookup n idxMap)
          return (instrs, (idx, v))
      )
      upds
  let allInstrs = concatMap fst results
      pairs = map snd results
  return (allInstrs, pairs)

-- ---------------------------------------------------------------------------
-- Handle block lowering
-- ---------------------------------------------------------------------------

lowerHandleParams ::
  GlobalEnv ->
  Env ->
  [(Text, Type, Maybe Text, Expr)] ->
  Lower ([AInstr], [VarId])
lowerHandleParams ge env params = do
  results <-
    mapM
      ( \(_n, _ty, _an, e) -> do
          (v, instrs, _) <- lowerExpr ge env e
          return (v, instrs)
      )
      params
  let allInstrs = concatMap snd results
      vars = map fst results
  return (allInstrs, vars)

lowerHandlers ::
  GlobalEnv ->
  Env ->
  HandlerId ->
  HandleStmt ->
  Lower ([(RequestId, [VarId], [Instruction])], Maybe (VarId, [Instruction]), [IRHandleScope])
lowerHandlers ge env hid hs = do
  -- Set state var index map and current handler ID for continue/break in req/then cases
  let paramIdxMap = Map.fromList (zip (map (\(n, _, _, _) -> n) (hParams hs)) [0 ..])
  oldIdxMap <- gets lsStateVarIdxMap
  oldHandler <- gets lsCurrentHandler
  modify (\st -> st {lsStateVarIdxMap = paramIdxMap, lsCurrentHandler = Just hid})
  reqResults <- mapM (lowerReqCase ge env) (hReqCases hs)
  let reqCases = map (\(rid, argVs, instrs, _) -> (rid, argVs, instrs)) reqResults
      innerFromReq = concatMap (\(_, _, _, hs') -> hs') reqResults
  (thenClause, innerFromThen) <- case hThenClause hs of
    Nothing -> return (Nothing, [])
    Just (var, body) -> do
      inputV <- freshVar -- runtime fills this with scope result
      let env' = Map.insert var inputV env
      (retV, instrs, innerHs) <- lowerBlock ge env' body
      -- IHandleBreak retV hid: "this is the then-clause result, set handle dst to retV"
      resolved <- liftEither (resolveLabels (instrs ++ [AI (IHandleBreak retV hid)]))
      return (Just (inputV, resolved), innerHs)
  modify (\st -> st {lsStateVarIdxMap = oldIdxMap, lsCurrentHandler = oldHandler})
  return (reqCases, thenClause, innerFromReq ++ innerFromThen)

-- Bind a pattern against a VarId holding the value.
-- Returns instructions needed for field/index access and the extended env.
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

lowerReqCase ::
  GlobalEnv ->
  Env ->
  (Text, [Pat], Block) ->
  Lower (RequestId, [VarId], [Instruction], [IRHandleScope])
lowerReqCase ge env (reqName, argPats, body) = do
  mname <- gets lsCurrentModule
  let qname = resolveLocal ge mname reqName
  rid <- lookupOrAllocRequest qname
  -- Allocate one fresh var per argument position (runtime fills these with request args)
  argVars <- mapM (const freshVar) argPats
  -- Bind each pattern against its argument var
  (bindInstrs, env') <-
    foldM
      ( \(accI, accEnv) (pat, v) -> do
          (is, e) <- lowerPatBind ge accEnv v pat
          return (accI ++ is, e)
      )
      ([], env)
      (zip argPats argVars)
  (retV, instrs, innerHs) <- lowerBlock ge env' body
  resolved <- liftEither (resolveLabels (bindInstrs ++ instrs ++ [AI (IReturn retV)]))
  return (rid, argVars, resolved, innerHs)

-- ---------------------------------------------------------------------------
-- Expression lowering
-- ---------------------------------------------------------------------------

lowerExpr :: GlobalEnv -> Env -> Expr -> Lower (VarId, [AInstr], [IRHandleScope])
lowerExpr ge env = \case
  ELit _sp lit -> do
    v <- freshVar
    case lit of
      LNull -> return (v, [AI (ILoadNull v)], [])
      LBool b -> do
        cid <- addConst (CVBool b)
        return (v, [AI (ILoadConst v cid)], [])
      LInt i -> do
        cid <- addConst (CVInt i)
        return (v, [AI (ILoadConst v cid)], [])
      LNum n -> do
        cid <- addConst (CVNum n)
        return (v, [AI (ILoadConst v cid)], [])
      LStr s -> do
        cid <- addConst (CVStr s)
        return (v, [AI (ILoadConst v cid)], [])
  EVar _sp name -> do
    v <- freshVar
    case Map.lookup name env of
      Just src -> return (v, [AI (IMove v src)], [])
      Nothing ->
        -- Unknown var: load null (error in type checker, but we're lenient here)
        return (v, [AI (ILoadNull v)], [])
  EField _sp e field -> do
    (src, instrs, handlers) <- lowerExpr ge env e
    v <- freshVar
    cid <- addConst (CVStr field)
    return (v, instrs ++ [AI (IGetField v src cid)], handlers)
  EArr _sp elems -> do
    results <- mapM (lowerExpr ge env) elems
    let allInstrs = concatMap (\(_, is, _) -> is) results
        allHandlers = concatMap (\(_, _, hs) -> hs) results
        vars = map (\(v, _, _) -> v) results
    dst <- freshVar
    return (dst, allInstrs ++ [AI (INewArray dst vars)], allHandlers)
  EObj _sp fields -> do
    results <-
      mapM
        ( \(name, _isUniq, e) -> do
            cid <- addConst (CVStr name)
            (v, instrs, handlers) <- lowerExpr ge env e
            return (cid, v, instrs, handlers)
        )
        fields
    let allInstrs = concatMap (\(_, _, is, _) -> is) results
        allHandlers = concatMap (\(_, _, _, hs) -> hs) results
        fieldPairs = map (\(cid, v, _, _) -> (cid, v)) results
    dst <- freshVar
    return (dst, allInstrs ++ [AI (INewObject dst fieldPairs)], allHandlers)
  ECall _sp callee args -> do
    -- Lower args
    argResults <- mapM (lowerExpr ge env) args
    let argInstrs = concatMap (\(_, is, _) -> is) argResults
        argHandlers = concatMap (\(_, _, hs) -> hs) argResults
        argVars = map (\(v, _, _) -> v) argResults
    -- Determine what we're calling
    case callee of
      EVar _ name -> do
        dst <- freshVar
        mname <- gets lsCurrentModule
        let qname = resolveLocal ge mname name
        case Map.lookup qname (geAgents ge) of
          Just _ai -> do
            aid <- lookupOrAllocAgent qname
            return (dst, argInstrs ++ [AI (ICall dst aid argVars)], argHandlers)
          Nothing ->
            case Map.lookup qname (geRequests ge) of
              Just _ri -> do
                rid <- lookupOrAllocRequest qname
                return (dst, argInstrs ++ [AI (IRequest dst rid argVars)], argHandlers)
              Nothing ->
                -- Treat as variable call - simplify to load null
                return (dst, argInstrs ++ [AI (ILoadNull dst)], argHandlers)
      EField _sp2 obj "__index__" -> do
        (arrVar, arrInstrs, arrHandlers) <- lowerExpr ge env obj
        let idxVar = head argVars -- should have exactly 1 arg
        dst <- freshVar
        return (dst, argInstrs ++ arrInstrs ++ [AI (IArrGet dst arrVar idxVar)], argHandlers ++ arrHandlers)
      _ -> do
        (_calleeVar, calleeInstrs, calleeHandlers) <- lowerExpr ge env callee
        dst <- freshVar
        return (dst, argInstrs ++ calleeInstrs ++ [AI (ILoadNull dst)], argHandlers ++ calleeHandlers)
  EBinOp _sp op l r -> do
    (lv, li, lh) <- lowerExpr ge env l
    (rv, ri, rh) <- lowerExpr ge env r
    dst <- freshVar
    let instr = lowerBinOp op dst lv rv
    return (dst, li ++ ri ++ [AI instr], lh ++ rh)
  EUnOp _sp op e -> do
    (src, instrs, handlers) <- lowerExpr ge env e
    dst <- freshVar
    let instr = case op of
          UnNeg -> INeg dst src
          UnNot -> INot dst src
    return (dst, instrs ++ [AI instr], handlers)
  EIf _sp cond thn els -> do
    (condV, condI, condH) <- lowerExpr ge env cond
    -- Allocate labels
    lbl_then <- freshLabel
    lbl_else <- freshLabel
    lbl_end <- freshLabel
    (thnV, thnI, thnH) <- lowerBlock ge env thn
    (elsV, elsI, elsH) <- lowerBlock ge env els
    dst <- freshVar
    -- Assembly:
    -- condI; branch condV lbl_then lbl_else
    -- lbl_then: thnI; move dst thnV; jump lbl_end
    -- lbl_else: elsI; move dst elsV; jump lbl_end
    -- lbl_end:
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
    return (dst, instrs, condH ++ thnH ++ elsH)
  EMatch _sp e arms -> do
    (scrutV, scrutI, scrutH) <- lowerExpr ge env e
    lbl_end <- freshLabel
    dst <- freshVar
    -- For each arm: lower pattern check, body
    armResults <- mapM (lowerArm ge env scrutV dst lbl_end) arms
    let armInstrs = concatMap fst armResults
        armHandlers = concatMap snd armResults
    -- After all arms, load null (shouldn't reach if exhaustive)
    let fallthrough = AI (ILoadNull dst)
    return (dst, scrutI ++ armInstrs ++ [fallthrough, AILabel lbl_end], scrutH ++ armHandlers)
  EFor _sp fe -> do
    dst <- freshVar
    let lets = fLetBinds fe
        vars = fVarBinds fe
    -- Lower var init exprs
    varInits <-
      mapM
        ( \(n, _ty, e) -> do
            (v, instrs, _) <- lowerExpr ge env e
            return (n, v, instrs)
        )
        vars
    let varInstrs = concatMap (\(_, _, is) -> is) varInits
        varEnv = foldr (\(n, v, _) e -> Map.insert n v e) env varInits
    -- Lower let array exprs
    letResults <-
      mapM
        ( \(n, e) -> do
            (v, instrs, _) <- lowerExpr ge env e
            return (n, v, instrs)
        )
        lets
    let letInstrs = concatMap (\(_, _, is) -> is) letResults
        letArrs = [(n, v) | (n, v, _) <- letResults]
    case letArrs of
      [] -> do
        v <- freshVar
        return (v, letInstrs ++ varInstrs ++ [AI (ILoadNull v)], [])
      _ -> do
        -- Loop variables
        idxVar <- freshVar
        idxCid <- addConst (CVInt 0)
        oneCid <- addConst (CVInt 1)
        oneVar <- freshVar
        condVar <- freshVar
        newIdxVar <- freshVar
        lbl_loop <- freshLabel
        lbl_body <- freshLabel
        lbl_end <- freshLabel
        lbl_after <- freshLabel -- after the entire for expression (break target)
        -- Compute length of each array and then min
        lenVars <- mapM (const freshVar) letArrs
        let lenInstrs =
              [ AI (IArrLen lv av)
                | ((_, av), lv) <- zip letArrs lenVars
              ]
        -- Compute minimum length across all let arrays:
        -- minVar starts as lenVars[0]; for each subsequent l:
        --   if l < minVar then minVar := l
        (minVar, minInstrs) <- case lenVars of
          [] -> do
            m <- freshVar
            return (m, [AI (ILoadConst m idxCid)])
          [l] -> return (l, [])
          (l : ls) -> do
            m <- freshVar
            let initMove = [AI (IMove m l)]
            stepInstrs <-
              mapM
                ( \l' -> do
                    cmp <- freshVar
                    lbl_if <- freshLabel
                    lbl_cont <- freshLabel
                    return
                      [ AI (ICmpLt cmp l' m),
                        AIBranch cmp lbl_if lbl_cont,
                        AILabel lbl_if,
                        AI (IMove m l'),
                        AIJump lbl_cont,
                        AILabel lbl_cont
                      ]
                )
                ls
            return (m, initMove ++ concat stepInstrs)
        -- Get elements at current index for each let binding
        elemVars <- mapM (const freshVar) letArrs
        let getInstrs =
              [ AI (IArrGet ev av idxVar)
                | ((_, av), ev) <- zip letArrs elemVars
              ]
            env' =
              foldr
                (\((n, _), ev) e -> Map.insert n ev e)
                varEnv
                (zip letArrs elemVars)
        -- Allocate for scope
        fid <- freshForId
        -- Set state var index map and for-break context
        let varIdxMap = Map.fromList (zip (map (\(n, _, _) -> n) vars) [0 ..])
        oldIdxMap <- gets lsStateVarIdxMap
        oldBreakCtx <- gets lsForBreakCtx
        oldFor <- gets lsCurrentFor
        modify
          ( \st ->
              st
                { lsStateVarIdxMap = varIdxMap,
                  lsForBreakCtx = Just (dst, lbl_after, fid),
                  lsCurrentFor = Just fid
                }
          )
        (_, bodyI, bodyH) <- lowerBlock ge env' (fBody fe)
        modify
          ( \st ->
              st
                { lsStateVarIdxMap = oldIdxMap,
                  lsForBreakCtx = oldBreakCtx,
                  lsCurrentFor = oldFor
                }
          )
        -- Then block
        (thnV, thnI, thnH) <- case fThen fe of
          Nothing -> do
            fv <- freshVar
            return (fv, [AI (ILoadNull fv)], [])
          Just fb -> lowerBlock ge varEnv fb
        -- Lower then block for IRForScope (resolved instructions)
        resolvedThen <- case fThen fe of
          Nothing -> return Nothing
          Just fb -> do
            (tv, ti, _) <- lowerBlock ge varEnv fb
            resolved <- liftEither (resolveLabels (ti ++ [AI (IReturn tv)]))
            return (Just resolved)
        -- Register for scope
        modify (\st -> st {lsForScopes = IRForScope fid resolvedThen : lsForScopes st})
        let instrs =
              letInstrs
                ++ varInstrs
                ++ [AI (IForBegin fid)]
                ++ [AI (ILoadConst idxVar idxCid)]
                ++ lenInstrs
                ++ minInstrs
                ++ [ AILabel lbl_loop,
                     AI (ICmpGe condVar idxVar minVar),
                     AIBranch condVar lbl_end lbl_body,
                     AILabel lbl_body
                   ]
                ++ getInstrs
                ++ bodyI
                ++ [ AI (ILoadConst oneVar oneCid),
                     AI (IAdd newIdxVar idxVar oneVar),
                     AI (IMove idxVar newIdxVar),
                     AIJump lbl_loop,
                     AILabel lbl_end
                   ]
                ++ thnI
                ++ [ AI (IMove dst thnV),
                     AI (IForEnd dst thnV fid),
                     AILabel lbl_after -- break jumps here, skipping then
                   ]
        return (dst, instrs, bodyH ++ thnH)
  EPar _sp blocks -> do
    dst <- freshVar
    let captures = Map.toList env
    parAgents <- mapM (lowerParBlock ge env captures) blocks
    let agentArgs = map (\(aid, captureVars) -> (aid, captureVars)) parAgents
    return (dst, [AI (IPar dst agentArgs)], [])
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
    return (v, allInstrs ++ extraInstrs, [])
    where
      catStep (acc, accI) sv = do
        res <- freshVar
        return (res, accI ++ [AI (IConcat res acc sv)])

lowerArm ::
  GlobalEnv ->
  Env ->
  VarId ->
  VarId ->
  LabelId ->
  CaseArm ->
  Lower ([AInstr], [IRHandleScope])
lowerArm ge env scrutV dst lbl_end (CaseArm pat body) = do
  lbl_match <- freshLabel
  lbl_next <- freshLabel
  -- Generate pattern check
  (checkInstrs, env') <- lowerPatCheck ge env scrutV pat lbl_match lbl_next
  (bodyV, bodyI, bodyH) <- lowerBlock ge env' body
  let instrs =
        checkInstrs
          ++ [AILabel lbl_match]
          ++ bodyI
          ++ [AI (IMove dst bodyV), AIJump lbl_end, AILabel lbl_next]
  return (instrs, bodyH)

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
    -- Always matches, bind variable
    let env' = Map.insert n scrutV env
    return ([AIJump lbl_match], env')
  PTyped n _ty -> do
    let env' = Map.insert n scrutV env
    return ([AIJump lbl_match], env')
  PLit lit -> do
    -- Compare literal
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
    -- Type-tag check using ITypeOf
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
    -- For DISC pattern (one uniq field): use field access + compare
    -- For non-DISC: check each field
    let uniqFields = [(name, p) | (name, True, p) <- fields]
        nonUniqFields = [(name, p) | (name, False, p) <- fields]
    case uniqFields of
      [(discName, PLit discLit)] -> do
        -- DISC pattern: get field, compare
        fieldVar <- freshVar
        cmpVar <- freshVar
        litVar <- freshVar
        nameCid <- addConst (CVStr discName)
        litCid <- addConst (litConstVal discLit)
        -- Bind other field variables
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
        -- Non-DISC: bind all fields and jump to match
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
    -- Recursively check sub-pattern
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
    -- Simplified: get each element by index
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

lowerParBlock ::
  GlobalEnv ->
  Env ->
  [(Text, VarId)] ->
  Block ->
  Lower (AgentId, [VarId])
lowerParBlock ge _env captures block = do
  let synName = T.pack ("__par_" ++ show (length captures))
  aid <- freshAgentId
  -- Save and reset per-agent accumulators
  oldForScopes <- gets lsForScopes
  modify (\st -> st {lsForScopes = []})
  let captureVars = map snd captures
      paramVars = zip (map fst captures) captureVars
  (retV, instrs, handlers) <- lowerBlock ge (Map.fromList paramVars) block
  let allInstrs = instrs ++ [AI (IReturn retV)]
  resolved <- liftEither (resolveLabels allInstrs)
  forScopes <- gets lsForScopes
  let irAgent =
        IRAgent
          { iraId = aid,
            iraKind = ParBranch,
            iraName = synName,
            iraParams = captureVars,
            iraBody = resolved,
            iraHandlers = handlers,
            iraForScopes = reverse forScopes
          }
  addAgent irAgent
  modify (\st -> st {lsForScopes = oldForScopes})
  return (aid, captureVars)

lowerTemplElem :: GlobalEnv -> Env -> TemplElem -> Lower ([AInstr], VarId)
lowerTemplElem ge env = \case
  TemplStr s -> do
    v <- freshVar
    cid <- addConst (CVStr s)
    return ([AI (ILoadConst v cid)], v)
  TemplExpr e -> do
    (v, instrs, _) <- lowerExpr ge env e
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
-- Helper: literal to ConstVal
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
-- Label resolution (2-pass)
-- ---------------------------------------------------------------------------

resolveLabels :: [AInstr] -> Either LowerError [Instruction]
resolveLabels ais = do
  -- First pass: compute label positions
  let labelMap = buildLabelMap ais 0
  -- Second pass: replace labels
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
  -- Check if already in pool
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

addAgent :: IRAgent -> Lower ()
addAgent agent = modify (\st -> st {lsAgents = agent : lsAgents st})

addRequestDef :: IRRequestDef -> Lower ()
addRequestDef rd = modify (\st -> st {lsRequests = rd : lsRequests st})
