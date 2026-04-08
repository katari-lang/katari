module Katari.Lowering
  ( LowerError (..)
  , lowerModules
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word32)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.List (nub, (\\))
import Control.Monad (foldM)
import Control.Monad.State

import Katari.Syntax
import Katari.IR
import Katari.Module

-- ---------------------------------------------------------------------------
-- Error
-- ---------------------------------------------------------------------------

data LowerError = LowerError String
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Lowering state
-- ---------------------------------------------------------------------------

data LowerSt = LowerSt
  { lsNextVar        :: Word32
  , lsNextTask       :: Word32
  , lsNextRequest    :: Word32
  , lsNextHandler    :: Word32
  , lsNextLabel      :: Int             -- dedicated label counter
  , lsStateVarIdxMap :: Map Text Word32 -- current state var name → index (for next/reply with)
  , lsCurrentHandler :: Maybe HandlerId -- handler ID currently being lowered (for reply/break)
  , lsForBreakCtx    :: Maybe (VarId, LabelId) -- (dst, lbl_after) for SForBreak inside for loops
  , lsConstPool      :: [ConstVal]      -- reversed
  , lsTasks          :: [IRTask]        -- accumulated tasks
  , lsTaskIds        :: Map Text Word32 -- task name → ID
  , lsReqIds         :: Map Text Word32 -- request name → ID
  , lsRequests       :: [IRRequestDef]  -- accumulated request defs
  , lsNameTable      :: NameTable
  }

type Lower a = StateT LowerSt (Either LowerError) a

-- ---------------------------------------------------------------------------
-- Instruction with placeholder labels
-- ---------------------------------------------------------------------------

type LabelId = Int

data AInstr
  = AI  Instruction
  | AIBranch    VarId LabelId LabelId
  | AIJump      LabelId
  | AILabel     LabelId
  | AISwitchL   VarId [(ConstId, LabelId)] LabelId
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

lowerModules :: GlobalEnv -> [Module] -> Either LowerError IRModule
lowerModules ge modules = do
  let initSt = LowerSt
        { lsNextVar        = 0
        , lsNextTask       = 0
        , lsNextRequest    = 0
        , lsNextHandler    = 0
        , lsNextLabel      = 0
        , lsStateVarIdxMap = Map.empty
        , lsCurrentHandler = Nothing
        , lsForBreakCtx    = Nothing
        , lsConstPool      = []
        , lsTasks          = []
        , lsTaskIds        = Map.empty
        , lsReqIds         = Map.empty
        , lsRequests       = []
        , lsNameTable      = emptyNameTable
        }
  ((), st) <- runStateT (lowerAll ge modules) initSt
  return IRModule
    { irmName      = "main"
    , irmNameTable = lsNameTable st
    , irmConsts    = reverse (lsConstPool st)
    , irmRequests  = lsRequests st
    , irmTasks     = reverse (lsTasks st)
    }

lowerAll :: GlobalEnv -> [Module] -> Lower ()
lowerAll ge modules = do
  -- Pre-register all tasks and requests with IDs
  mapM_ (preregisterModule ge) modules
  -- Lower all tasks
  mapM_ (lowerModule ge) modules

preregisterModule :: GlobalEnv -> Module -> Lower ()
preregisterModule ge m =
  mapM_ (preregisterDecl ge) (modDecls m)

preregisterDecl :: GlobalEnv -> Decl -> Lower ()
preregisterDecl ge (DeclTask _ td) = do
  tid <- allocTask (taskName td)
  return ()
preregisterDecl ge (DeclRequest _ rd) = do
  rid <- allocRequest (reqName rd)
  addRequestDef (IRRequestDef rid (reqName rd) Nothing)
preregisterDecl ge (DeclExtTask _ etd) = do
  _tid <- allocTask (extTaskName etd)
  return ()
preregisterDecl ge (DeclExtReq _ erd) = do
  rid <- allocRequest (extReqName erd)
  addRequestDef (IRRequestDef rid (extReqName erd) (Just (extReqFrom erd)))
preregisterDecl _  _ = return ()

lowerModule :: GlobalEnv -> Module -> Lower ()
lowerModule ge m =
  mapM_ (lowerDecl ge) (modDecls m)

lowerDecl :: GlobalEnv -> Decl -> Lower ()
lowerDecl ge (DeclTask _ td)    = lowerTask ge td Map.empty
lowerDecl ge (DeclExtTask _ _)  = return ()  -- no body to lower
lowerDecl _  _                  = return ()

-- ---------------------------------------------------------------------------
-- Task lowering
-- ---------------------------------------------------------------------------

lowerTask :: GlobalEnv -> TaskDecl -> Map Text VarId -> Lower ()
lowerTask ge td extraCaptures = do
  tid <- lookupTask (taskName td)
  -- Allocate parameter variables
  paramVars <- mapM (\(n, _) -> do v <- freshVar; return (n, v)) (taskParams td)
  let captures = Map.toList extraCaptures
  captureVars <- mapM (\(n, cv) -> return (n, cv)) captures
  let allParams = map snd paramVars
      env0 = Map.fromList (paramVars ++ captureVars)
  -- Lower body
  (retVar, instrs, handlers) <- lowerBlock ge env0 (taskBody td)
  -- Append IReturn
  let retInstr = AI (IReturn retVar)
      allInstrs = instrs ++ [retInstr]
  -- Resolve labels
  resolved <- liftEither (resolveLabels allInstrs)
  let irTask = IRTask
        { irTaskId       = tid
        , irTaskName     = taskName td
        , irTaskParams   = allParams
        , irTaskBody     = resolved
        , irTaskHandlers = handlers
        }
  addTask irTask

liftEither :: Either LowerError a -> Lower a
liftEither (Left e)  = lift (Left e)
liftEither (Right a) = return a

-- ---------------------------------------------------------------------------
-- Block lowering: returns (result VarId, instructions, handle blocks)
-- ---------------------------------------------------------------------------

type Env = Map Text VarId

lowerBlock :: GlobalEnv -> Env -> Block -> Lower (VarId, [AInstr], [IRHandleBlock])
lowerBlock ge env (Block stmts) = lowerStmts ge env stmts

lowerStmts :: GlobalEnv -> Env -> [Stmt] -> Lower (VarId, [AInstr], [IRHandleBlock])
lowerStmts ge env [] = do
  v <- freshVar
  return (v, [AI (ILoadNull v)], [])
lowerStmts ge env [s] = lowerFinalStmt ge env s
lowerStmts ge env (SHandle _sp hs : rest) = do
  -- Handle statement: allocate handler, lower scope (rest), emit Begin/End
  hid <- freshHandler
  -- Lower the handle params (init exprs)
  (paramInstrs, stateVars) <- lowerHandleParams ge env (hParams hs)
  -- Build env extended with state variable names → their VarIds
  let stateNames = map (\(n,_,_) -> n) (hParams hs)
      stateEnv   = foldr (\(n, v) e -> Map.insert n v e) env (zip stateNames stateVars)
  -- Lower the handlers (with stateEnv so bodies can reference state vars)
  (reqCases, retCase) <- lowerHandlers ge stateEnv hid hs
  let handler = IRHandleBlock
        { irhId         = hid
        , irhStateVars  = stateVars
        , irhReqCases   = reqCases
        , irhReturnCase = retCase
        }
  -- Lower the rest of the block (the handle scope)
  (retVar, restInstrs, restHandlers) <- lowerStmts ge env rest
  let beginInstr = AI (IHandleBegin hid)
      endInstr   = AI (IHandleEnd   hid)
  return ( retVar
         , paramInstrs ++ [beginInstr] ++ restInstrs ++ [endInstr]
         , handler : restHandlers
         )
lowerStmts ge env (s:ss) = do
  (env', instrs, handlers) <- lowerNonFinalStmt ge env s
  (retVar, restInstrs, restHandlers) <- lowerStmts ge env' ss
  return (retVar, instrs ++ restInstrs, handlers ++ restHandlers)

-- Lower a non-final statement (not the last one)
lowerNonFinalStmt :: GlobalEnv -> Env -> Stmt -> Lower (Env, [AInstr], [IRHandleBlock])
lowerNonFinalStmt ge env (SLet _sp pat e) = do
  (v, instrs, handlers) <- lowerExpr ge env e
  (bindInstrs, env') <- lowerPatBind ge env v pat
  return (env', instrs ++ bindInstrs, handlers)
lowerNonFinalStmt ge env (SExpr _sp e) = do
  (_v, instrs, handlers) <- lowerExpr ge env e
  return (env, instrs, handlers)
lowerNonFinalStmt ge env s = do
  -- For other stmts (return, etc.), lower and discard env change
  (_v, instrs, handlers) <- lowerFinalStmt ge env s
  return (env, instrs, handlers)

-- Lower the final statement of a block
lowerFinalStmt :: GlobalEnv -> Env -> Stmt -> Lower (VarId, [AInstr], [IRHandleBlock])
lowerFinalStmt ge env (SExpr _sp e)    = lowerExpr ge env e
lowerFinalStmt ge env (SLet _sp _p e) = lowerExpr ge env e
lowerFinalStmt ge env (SReturn _sp e)  = do
  (v, instrs, handlers) <- lowerExpr ge env e
  return (v, instrs ++ [AI (IReturn v)], handlers)
lowerFinalStmt ge env (SBreak _sp e) = do
  (v, instrs, handlers) <- lowerExpr ge env e
  hid <- gets (maybe 0 id . lsCurrentHandler)
  return (v, instrs ++ [AI (IBreak v hid)], handlers)
lowerFinalStmt ge env (SForBreak _sp e) = do
  (v, instrs, handlers) <- lowerExpr ge env e
  ctx <- gets lsForBreakCtx
  case ctx of
    Just (dstV, lbl_after) ->
      -- Set for-expression result to v, then jump past the finally block
      return (v, instrs ++ [AI (IMove dstV v), AIJump lbl_after], handlers)
    Nothing ->
      -- Fallback: emit IForBreak (runtime must handle it)
      return (v, instrs ++ [AI (IForBreak v)], handlers)
lowerFinalStmt ge env (SReply _sp e upd) = do
  (v, instrs, handlers) <- lowerExpr ge env e
  updates <- lowerStateUpdates ge env (fromMaybe [] upd)
  let (updInstrs, stateUpds) = updates
  hid <- gets (maybe 0 id . lsCurrentHandler)
  return (v, instrs ++ updInstrs ++ [AI (IReply v hid stateUpds)], handlers)
lowerFinalStmt ge env (SNext _sp upd) = do
  updates <- lowerStateUpdates ge env (fromMaybe [] upd)
  let (updInstrs, stateUpds) = updates
  v <- freshVar
  return (v, updInstrs ++ [AI (INext stateUpds), AI (ILoadNull v)], [])
lowerFinalStmt ge env (SHandle _sp hs) = do
  v <- freshVar
  return (v, [AI (ILoadNull v)], [])

lowerStateUpdates :: GlobalEnv -> Env -> [(Text, Expr)] -> Lower ([AInstr], [(Word32, VarId)])
lowerStateUpdates ge env upds = do
  idxMap <- gets lsStateVarIdxMap
  results <- mapM (\(n, e) -> do
    (v, instrs, _) <- lowerExpr ge env e
    let idx = maybe 0 id (Map.lookup n idxMap)
    return (instrs, (idx, v))) upds
  let allInstrs = concatMap fst results
      pairs     = map snd results
  return (allInstrs, pairs)

-- ---------------------------------------------------------------------------
-- Handle block lowering
-- ---------------------------------------------------------------------------

lowerHandleParams :: GlobalEnv -> Env -> [(Text, Type, Expr)]
                  -> Lower ([AInstr], [VarId])
lowerHandleParams ge env params = do
  results <- mapM (\(_n, _ty, e) -> do
    (v, instrs, _) <- lowerExpr ge env e
    return (v, instrs)) params
  let allInstrs = concatMap snd results
      vars = map fst results
  return (allInstrs, vars)

lowerHandlers :: GlobalEnv -> Env -> HandlerId -> HandleStmt
              -> Lower ([(RequestId, [Instruction])], Maybe [Instruction])
lowerHandlers ge env hid hs = do
  -- Set state var index map and current handler ID for reply/break in req/return cases
  let paramIdxMap = Map.fromList (zip (map (\(n,_,_)->n) (hParams hs)) [0..])
  oldIdxMap  <- gets lsStateVarIdxMap
  oldHandler <- gets lsCurrentHandler
  modify (\st -> st { lsStateVarIdxMap = paramIdxMap, lsCurrentHandler = Just hid })
  reqCases <- mapM (lowerReqCase ge env) (hReqCases hs)
  retCase  <- case hReturnCase hs of
    Nothing        -> return Nothing
    Just (var, body) -> do
      v <- freshVar
      let env' = Map.insert var v env
      (retV, instrs, _) <- lowerBlock ge env' body
      resolved <- liftEither (resolveLabels (instrs ++ [AI (IReturn retV)]))
      return (Just resolved)
  modify (\st -> st { lsStateVarIdxMap = oldIdxMap, lsCurrentHandler = oldHandler })
  return (reqCases, retCase)

-- Bind a pattern against a VarId holding the value.
-- Returns instructions needed for field/index access and the extended env.
lowerPatBind :: GlobalEnv -> Env -> VarId -> Pat -> Lower ([AInstr], Env)
lowerPatBind _  env v (PVar n)     = return ([], Map.insert n v env)
lowerPatBind _  env v (PTyped n _) = return ([], Map.insert n v env)
lowerPatBind _  env v (PTag _ n)   = return ([], Map.insert n v env)
lowerPatBind _  env _ (PLit _)     = return ([], env)
lowerPatBind ge env v (PObj fields) =
  foldM (\(accI, accEnv) (name, _, pat) -> do
    fv  <- freshVar
    cid <- addConst (CVStr name)
    (subI, subEnv) <- lowerPatBind ge accEnv fv pat
    return (accI ++ [AI (IGetField fv v cid)] ++ subI, subEnv)
  ) ([], env) fields
lowerPatBind ge env v (PArr pats) =
  foldM (\(accI, accEnv) (i, pat) -> do
    iv  <- freshVar
    ev  <- freshVar
    cid <- addConst (CVInt (toInteger (i :: Int)))
    (subI, subEnv) <- lowerPatBind ge accEnv ev pat
    return (accI ++ [AI (ILoadConst iv cid), AI (IArrGet ev v iv)] ++ subI, subEnv)
  ) ([], env) (zip [0..] pats)

lowerReqCase :: GlobalEnv -> Env -> (Text, [Pat], Block)
             -> Lower (RequestId, [Instruction])
lowerReqCase ge env (reqName, argPats, body) = do
  rid <- lookupOrAllocRequest reqName
  -- Allocate one fresh var per argument position
  argVars <- mapM (\_ -> freshVar) argPats
  -- Bind each pattern against its argument var
  (bindInstrs, env') <- foldM
    (\(accI, accEnv) (pat, v) -> do
      (is, e) <- lowerPatBind ge accEnv v pat
      return (accI ++ is, e))
    ([], env)
    (zip argPats argVars)
  (retV, instrs, _) <- lowerBlock ge env' body
  resolved <- liftEither (resolveLabels (bindInstrs ++ instrs ++ [AI (IReturn retV)]))
  return (rid, resolved)

-- ---------------------------------------------------------------------------
-- Expression lowering
-- ---------------------------------------------------------------------------

lowerExpr :: GlobalEnv -> Env -> Expr -> Lower (VarId, [AInstr], [IRHandleBlock])

lowerExpr _ge _env (ELit _sp lit) = do
  v <- freshVar
  case lit of
    LNull   -> return (v, [AI (ILoadNull v)], [])
    LBool b -> do
      cid <- addConst (CVBool b)
      return (v, [AI (ILoadConst v cid)], [])
    LInt  i -> do
      cid <- addConst (CVInt i)
      return (v, [AI (ILoadConst v cid)], [])
    LNum  n -> do
      cid <- addConst (CVNum n)
      return (v, [AI (ILoadConst v cid)], [])
    LStr  s -> do
      cid <- addConst (CVStr s)
      return (v, [AI (ILoadConst v cid)], [])

lowerExpr _ge env (EVar _sp name) = do
  v <- freshVar
  case Map.lookup name env of
    Just src -> return (v, [AI (IMove v src)], [])
    Nothing  -> do
      -- Unknown var: load null (error in type checker, but we're lenient here)
      return (v, [AI (ILoadNull v)], [])

lowerExpr ge env (EField _sp e field) = do
  (src, instrs, handlers) <- lowerExpr ge env e
  v  <- freshVar
  cid <- addConst (CVStr field)
  return (v, instrs ++ [AI (IGetField v src cid)], handlers)

lowerExpr ge env (EArr _sp elems) = do
  results <- mapM (lowerExpr ge env) elems
  let allInstrs = concatMap (\(_, is, _) -> is) results
      allHandlers = concatMap (\(_, _, hs) -> hs) results
      vars = map (\(v, _, _) -> v) results
  dst <- freshVar
  return (dst, allInstrs ++ [AI (INewArray dst vars)], allHandlers)

lowerExpr ge env (EObj _sp fields) = do
  results <- mapM (\(name, e) -> do
    cid <- addConst (CVStr name)
    (v, instrs, handlers) <- lowerExpr ge env e
    return (cid, v, instrs, handlers)) fields
  let allInstrs = concatMap (\(_, _, is, _) -> is) results
      allHandlers = concatMap (\(_, _, _, hs) -> hs) results
      fieldPairs = map (\(cid, v, _, _) -> (cid, v)) results
  dst <- freshVar
  return (dst, allInstrs ++ [AI (INewObject dst fieldPairs)], allHandlers)

lowerExpr ge env (ECall _sp callee args) = do
  -- Lower args
  argResults <- mapM (lowerExpr ge env) args
  let argInstrs = concatMap (\(_, is, _) -> is) argResults
      argHandlers = concatMap (\(_, _, hs) -> hs) argResults
      argVars = map (\(v, _, _) -> v) argResults
  -- Determine what we're calling
  case callee of
    EVar _ name -> do
      dst <- freshVar
      case Map.lookup name (geTasks ge) of
        Just _ti -> do
          tid <- lookupOrAllocTask name
          return (dst, argInstrs ++ [AI (ICall dst tid argVars)], argHandlers)
        Nothing  ->
          case Map.lookup name (geRequests ge) of
            Just _ri -> do
              rid <- lookupOrAllocRequest name
              return (dst, argInstrs ++ [AI (IRequest dst rid argVars)], argHandlers)
            Nothing ->
              -- Treat as variable call - simplify to load null
              return (dst, argInstrs ++ [AI (ILoadNull dst)], argHandlers)
    EField _sp2 obj "__index__" -> do
      (arrVar, arrInstrs, arrHandlers) <- lowerExpr ge env obj
      let idxVar = head argVars  -- should have exactly 1 arg
      dst <- freshVar
      return (dst, argInstrs ++ arrInstrs ++ [AI (IArrGet dst arrVar idxVar)], argHandlers ++ arrHandlers)
    _ -> do
      (calleeVar, calleeInstrs, calleeHandlers) <- lowerExpr ge env callee
      dst <- freshVar
      return (dst, argInstrs ++ calleeInstrs ++ [AI (ILoadNull dst)], argHandlers ++ calleeHandlers)

lowerExpr ge env (EBinOp _sp op l r) = do
  (lv, li, lh) <- lowerExpr ge env l
  (rv, ri, rh) <- lowerExpr ge env r
  dst <- freshVar
  let instr = lowerBinOp op dst lv rv
  return (dst, li ++ ri ++ [AI instr], lh ++ rh)

lowerExpr ge env (EUnOp _sp op e) = do
  (src, instrs, handlers) <- lowerExpr ge env e
  dst <- freshVar
  let instr = case op of
                UnNeg -> INegInt dst src  -- simplified
                UnNot -> INot    dst src
  return (dst, instrs ++ [AI instr], handlers)

lowerExpr ge env (EIf _sp cond thn els) = do
  (condV, condI, condH) <- lowerExpr ge env cond
  -- Allocate labels
  lbl_then  <- freshLabel
  lbl_else  <- freshLabel
  lbl_end   <- freshLabel
  (thnV, thnI, thnH) <- lowerBlock ge env thn
  (elsV, elsI, elsH) <- lowerBlock ge env els
  dst <- freshVar
  -- Assembly:
  -- condI; branch condV lbl_then lbl_else
  -- lbl_then: thnI; move dst thnV; jump lbl_end
  -- lbl_else: elsI; move dst elsV; jump lbl_end
  -- lbl_end:
  let instrs =
        condI ++
        [AIBranch condV lbl_then lbl_else,
         AILabel lbl_then] ++
        thnI ++
        [AI (IMove dst thnV), AIJump lbl_end,
         AILabel lbl_else] ++
        elsI ++
        [AI (IMove dst elsV), AIJump lbl_end,
         AILabel lbl_end]
  return (dst, instrs, condH ++ thnH ++ elsH)

lowerExpr ge env (EMatch _sp e arms) = do
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

lowerExpr ge env (EFor _sp fe) = do
  dst <- freshVar
  let lets = fLetBinds fe
      vars = fVarBinds fe
  -- Lower var init exprs
  varInits <- mapM (\(n, _ty, e) -> do
    (v, instrs, _) <- lowerExpr ge env e
    return (n, v, instrs)) vars
  let varInstrs = concatMap (\(_, _, is) -> is) varInits
      varEnv = foldr (\(n, v, _) e -> Map.insert n v e) env varInits
  -- Lower let array exprs
  letResults <- mapM (\(n, e) -> do
    (v, instrs, _) <- lowerExpr ge env e
    return (n, v, instrs)) lets
  let letInstrs = concatMap (\(_, _, is) -> is) letResults
  -- For now, support exactly one let binding (iterate over one array)
  case letResults of
    [(letName, arrVar, _)] -> do
      -- Loop variables: index counter
      idxVar  <- freshVar
      lenVar  <- freshVar
      condVar <- freshVar
      elemVar <- freshVar
      idxCid  <- addConst (CVInt 0)
      oneCid  <- addConst (CVInt 1)
      oneVar  <- freshVar
      newIdxVar <- freshVar
      lbl_loop  <- freshLabel
      lbl_body  <- freshLabel
      lbl_end   <- freshLabel
      lbl_after <- freshLabel   -- after the entire for expression (break target)
      let env' = Map.insert letName elemVar varEnv
      -- Set state var index map and for-break context
      let varIdxMap = Map.fromList (zip (map (\(n,_,_)->n) vars) [0..])
      oldIdxMap  <- gets lsStateVarIdxMap
      oldBreakCtx <- gets lsForBreakCtx
      modify (\st -> st { lsStateVarIdxMap = varIdxMap
                        , lsForBreakCtx    = Just (dst, lbl_after) })
      (_, bodyI, bodyH) <- lowerBlock ge env' (fBody fe)
      modify (\st -> st { lsStateVarIdxMap = oldIdxMap
                        , lsForBreakCtx    = oldBreakCtx })
      -- Finally block
      (finV, finI, finH) <- case fFinally fe of
        Nothing -> do
          fv <- freshVar
          return (fv, [AI (ILoadNull fv)], [])
        Just fb -> lowerBlock ge varEnv fb
      let instrs =
            letInstrs ++ varInstrs ++
            [ AI (ILoadConst idxVar idxCid)
            , AI (IArrLen lenVar arrVar)
            , AILabel lbl_loop
            , AI (ICmpGe condVar idxVar lenVar)
            , AIBranch condVar lbl_end lbl_body
            , AILabel lbl_body
            , AI (IArrGet elemVar arrVar idxVar)
            ] ++
            bodyI ++
            [ AI (ILoadConst oneVar oneCid)
            , AI (IAddInt newIdxVar idxVar oneVar)
            , AI (IMove idxVar newIdxVar)
            , AIJump lbl_loop
            , AILabel lbl_end
            ] ++
            finI ++
            [ AI (IMove dst finV)
            , AILabel lbl_after   -- break jumps here, skipping finally
            ]
      return (dst, instrs, bodyH ++ finH)
    _ -> do
      -- No let bindings or multiple - simplified fallback
      v <- freshVar
      return (v, letInstrs ++ varInstrs ++ [AI (ILoadNull v)], [])

lowerExpr ge env (EPar _sp blocks) = do
  dst <- freshVar
  let captures = Map.toList env
  parTasks <- mapM (lowerParBlock ge env captures) blocks
  let taskArgs = map (\(tid, captureVars) -> (tid, captureVars)) parTasks
  return (dst, [AI (IPar dst taskArgs)], [])

lowerExpr ge env (EBlock _sp b) = lowerBlock ge env b

lowerExpr ge env (ETempl _sp elems) = do
  results <- mapM (lowerTemplElem ge env) elems
  let allInstrs = concatMap fst results
      strs = map snd results
  (v, extraInstrs) <- case strs of
    [] -> do fv <- freshVar; return (fv, [AI (ILoadNull fv)])
    [sv] -> return (sv, [])
    (sv:svs) -> foldM' sv [] svs
  return (v, allInstrs ++ extraInstrs, [])
  where
    foldM' acc _ [] = return (acc, [])
    foldM' acc _ (sv:svs) = do
      res <- freshVar
      (finalV, rest) <- foldM' res [] svs
      return (finalV, [AI (IStrConcat res acc sv)] ++ rest)

lowerArm :: GlobalEnv -> Env -> VarId -> VarId -> LabelId -> CaseArm
         -> Lower ([AInstr], [IRHandleBlock])
lowerArm ge env scrutV dst lbl_end (CaseArm pat body) = do
  lbl_match <- freshLabel
  lbl_next  <- freshLabel
  -- Generate pattern check
  (checkInstrs, env') <- lowerPatCheck ge env scrutV pat lbl_match lbl_next
  (bodyV, bodyI, bodyH) <- lowerBlock ge env' body
  let instrs = checkInstrs ++
               [AILabel lbl_match] ++
               bodyI ++
               [AI (IMove dst bodyV), AIJump lbl_end, AILabel lbl_next]
  return (instrs, bodyH)

lowerPatCheck :: GlobalEnv -> Env -> VarId -> Pat -> LabelId -> LabelId
              -> Lower ([AInstr], Env)
lowerPatCheck ge env scrutV (PVar n) lbl_match lbl_next = do
  -- Always matches, bind variable
  let env' = Map.insert n scrutV env
  return ([AIJump lbl_match], env')
lowerPatCheck ge env scrutV (PTyped n _ty) lbl_match lbl_next = do
  let env' = Map.insert n scrutV env
  return ([AIJump lbl_match], env')
lowerPatCheck ge env scrutV (PLit lit) lbl_match lbl_next = do
  -- Compare literal
  litVar <- freshVar
  cmpVar <- freshVar
  cid <- addConst (litConstVal lit)
  let instrs =
        [ AI (ILoadConst litVar cid)
        , AI (ICmpEq cmpVar scrutV litVar)
        , AIBranch cmpVar lbl_match lbl_next
        ]
  return (instrs, env)
lowerPatCheck ge env scrutV (PTag tag varName) lbl_match lbl_next = do
  -- Type-tag check using ITypeOf
  typeVar <- freshVar
  cmpVar  <- freshVar
  tagStr  <- freshVar
  tagCid  <- addConst (CVStr (tagToStr tag))
  let instrs =
        [ AI (ITypeOf typeVar scrutV)
        , AI (ILoadConst tagStr tagCid)
        , AI (ICmpEq cmpVar typeVar tagStr)
        , AIBranch cmpVar lbl_match lbl_next
        ]
  let env' = Map.insert varName scrutV env
  return (instrs, env')
lowerPatCheck ge env scrutV (PObj fields) lbl_match lbl_next = do
  -- For DISC pattern (one uniq field): use field access + compare
  -- For non-DISC: check each field
  let uniqFields = [(name, pat) | (name, True, pat) <- fields]
      nonUniqFields = [(name, pat) | (name, False, pat) <- fields]
  case uniqFields of
    [(discName, PLit discLit)] -> do
      -- DISC pattern: get field, compare
      fieldVar <- freshVar
      cmpVar   <- freshVar
      litVar   <- freshVar
      nameCid  <- addConst (CVStr discName)
      litCid   <- addConst (litConstVal discLit)
      -- Bind other field variables
      lbl_check_fields <- freshLabel
      (fieldInstrs, env') <- lowerObjFieldBindings ge env scrutV nonUniqFields lbl_match lbl_next
      let instrs =
            [ AI (IGetField fieldVar scrutV nameCid)
            , AI (ILoadConst litVar litCid)
            , AI (ICmpEq cmpVar fieldVar litVar)
            , AIBranch cmpVar lbl_check_fields lbl_next
            , AILabel lbl_check_fields
            ] ++ fieldInstrs
      return (instrs, env')
    _ -> do
      -- Non-DISC: bind all fields and jump to match
      (instrs, env') <- lowerObjFieldBindings ge env scrutV (map (\(n,_,p)->(n,p)) fields) lbl_match lbl_next
      return (instrs, env')
lowerPatCheck ge env scrutV (PArr pats) lbl_match lbl_next = do
  -- Simplified: just bind variables by index
  (instrs, env') <- lowerArrPatBindings ge env scrutV pats lbl_match lbl_next
  return (instrs, env')

lowerObjFieldBindings :: GlobalEnv -> Env -> VarId -> [(Text, Pat)] -> LabelId -> LabelId
                      -> Lower ([AInstr], Env)
lowerObjFieldBindings ge env _ [] lbl_match _ =
  return ([AIJump lbl_match], env)
lowerObjFieldBindings ge env scrutV ((name, pat):rest) lbl_match lbl_next = do
  fieldVar <- freshVar
  nameCid  <- addConst (CVStr name)
  let getInstr = AI (IGetField fieldVar scrutV nameCid)
  -- Recursively check sub-pattern
  lbl_sub_match <- freshLabel
  (checkInstrs, env') <- lowerPatCheck ge env fieldVar pat lbl_sub_match lbl_next
  (restInstrs, env'') <- lowerObjFieldBindings ge env' scrutV rest lbl_match lbl_next
  let instrs = [getInstr] ++ checkInstrs ++ [AILabel lbl_sub_match] ++ restInstrs
  return (instrs, env'')

lowerArrPatBindings :: GlobalEnv -> Env -> VarId -> [Pat] -> LabelId -> LabelId
                    -> Lower ([AInstr], Env)
lowerArrPatBindings ge env _ [] lbl_match _ =
  return ([AIJump lbl_match], env)
lowerArrPatBindings ge env scrutV pats lbl_match lbl_next = do
  -- Simplified: get each element by index
  (instrs, env') <- go pats 0 env
  return (instrs ++ [AIJump lbl_match], env')
  where
    go [] _ e = return ([], e)
    go (p:ps) i e = do
      idxVar  <- freshVar
      elemVar <- freshVar
      idxCid  <- addConst (CVInt (toInteger i))
      let idxInstrs = [AI (ILoadConst idxVar idxCid), AI (IArrGet elemVar scrutV idxVar)]
      lbl_sub_match <- freshLabel
      (checkInstrs, e') <- lowerPatCheck ge e elemVar p lbl_sub_match lbl_next
      (restInstrs, e'') <- go ps (i+1) e'
      let instrs = idxInstrs ++ checkInstrs ++ [AILabel lbl_sub_match] ++ restInstrs
      return (instrs, e'')

lowerParBlock :: GlobalEnv -> Env -> [(Text, VarId)] -> Block
              -> Lower (TaskId, [VarId])
lowerParBlock ge env captures block = do
  let synName = T.pack ("__par_" ++ show (length captures))
  tid <- freshTaskId
  let captureVars = map snd captures
      paramVars = zip (map fst captures) captureVars
  (retV, instrs, handlers) <- lowerBlock ge (Map.fromList paramVars) block
  let allInstrs = instrs ++ [AI (IReturn retV)]
  resolved <- liftEither (resolveLabels allInstrs)
  let irTask = IRTask
        { irTaskId       = tid
        , irTaskName     = synName
        , irTaskParams   = captureVars
        , irTaskBody     = resolved
        , irTaskHandlers = handlers
        }
  addTask irTask
  return (tid, captureVars)

lowerTemplElem :: GlobalEnv -> Env -> TemplElem -> Lower ([AInstr], VarId)
lowerTemplElem _ge _env (TemplStr s) = do
  v <- freshVar
  cid <- addConst (CVStr s)
  return ([AI (ILoadConst v cid)], v)
lowerTemplElem ge env (TemplExpr e) = do
  (v, instrs, _) <- lowerExpr ge env e
  str <- freshVar
  return (instrs ++ [AI (IToString str v)], str)

-- ---------------------------------------------------------------------------
-- Binary op lowering
-- ---------------------------------------------------------------------------

lowerBinOp :: BinOp -> VarId -> VarId -> VarId -> Instruction
lowerBinOp OpAdd d l r = IAddInt d l r  -- simplified: always int
lowerBinOp OpSub d l r = ISubInt d l r
lowerBinOp OpMul d l r = IMulInt d l r
lowerBinOp OpDiv d l r = IDiv    d l r
lowerBinOp OpConcat d l r = IStrConcat d l r  -- or IArrConcat
lowerBinOp OpLt  d l r = ICmpLt d l r
lowerBinOp OpLe  d l r = ICmpLe d l r
lowerBinOp OpGt  d l r = ICmpGt d l r
lowerBinOp OpGe  d l r = ICmpGe d l r
lowerBinOp OpEq  d l r = ICmpEq d l r
lowerBinOp OpNe  d l r = ICmpNe d l r
lowerBinOp OpAnd d l r = IAnd   d l r
lowerBinOp OpOr  d l r = IOr    d l r

-- ---------------------------------------------------------------------------
-- Helper: literal to ConstVal
-- ---------------------------------------------------------------------------

litConstVal :: Lit -> ConstVal
litConstVal LNull     = CVNull
litConstVal (LBool b) = CVBool b
litConstVal (LInt  i) = CVInt  i
litConstVal (LNum  n) = CVNum  n
litConstVal (LStr  s) = CVStr  s

tagToStr :: PrimTag -> Text
tagToStr TagBoolean = "boolean"
tagToStr TagInteger = "integer"
tagToStr TagNumber  = "number"
tagToStr TagString  = "string"

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
buildLabelMap [] _ = Map.empty
buildLabelMap (AILabel lbl : rest) pos =
  Map.insert lbl (fromIntegral pos) (buildLabelMap rest pos)
buildLabelMap (_ : rest) pos =
  buildLabelMap rest (pos + 1)

isLabel :: AInstr -> Bool
isLabel (AILabel _) = True
isLabel _           = False

resolveOne :: Map LabelId Word32 -> AInstr -> Either LowerError Instruction
resolveOne lm (AI instr)                  = Right instr
resolveOne lm (AIBranch v l_t l_f)       = do
  t <- lookupLabel lm l_t
  f <- lookupLabel lm l_f
  return (IBranch v t f)
resolveOne lm (AIJump lbl)               = do
  t <- lookupLabel lm lbl
  return (IJump t)
resolveOne lm (AISwitchL v cases def)    = do
  cs  <- mapM (\(cid, lbl) -> do t <- lookupLabel lm lbl; return (cid, t)) cases
  d   <- lookupLabel lm def
  return (ISwitch v cs d)
resolveOne _  (AILabel _)               = Left (LowerError "Label in non-label position")

lookupLabel :: Map LabelId Word32 -> LabelId -> Either LowerError Word32
lookupLabel lm lbl =
  case Map.lookup lbl lm of
    Just pos -> Right pos
    Nothing  -> Left (LowerError ("Undefined label: " ++ show lbl))

-- ---------------------------------------------------------------------------
-- Allocation helpers
-- ---------------------------------------------------------------------------

freshVar :: Lower VarId
freshVar = do
  st <- get
  let v = lsNextVar st
  put st { lsNextVar = v + 1 }
  return v

freshHandler :: Lower HandlerId
freshHandler = do
  st <- get
  let h = lsNextHandler st
  put st { lsNextHandler = h + 1 }
  return h

freshLabel :: Lower LabelId
freshLabel = do
  st <- get
  let l = lsNextLabel st
  put st { lsNextLabel = l + 1 }
  return l

freshTaskId :: Lower TaskId
freshTaskId = do
  st <- get
  let tid = lsNextTask st
  put st { lsNextTask = tid + 1 }
  return tid

allocTask :: Text -> Lower TaskId
allocTask name = do
  existing <- gets (Map.lookup name . lsTaskIds)
  case existing of
    Just tid -> return tid
    Nothing  -> do
      tid <- freshTaskId
      modify (\s -> s
        { lsTaskIds  = Map.insert name tid (lsTaskIds s)
        , lsNameTable = (lsNameTable s)
            { ntTasks = Map.insert tid name (ntTasks (lsNameTable s)) }
        })
      return tid

allocRequest :: Text -> Lower RequestId
allocRequest name = do
  existing <- gets (Map.lookup name . lsReqIds)
  case existing of
    Just rid -> return rid
    Nothing  -> do
      rid <- gets lsNextRequest
      modify (\s -> s
        { lsNextRequest = rid + 1
        , lsReqIds      = Map.insert name rid (lsReqIds s)
        , lsNameTable   = (lsNameTable s)
            { ntRequests = Map.insert rid name (ntRequests (lsNameTable s)) }
        })
      return rid

lookupTask :: Text -> Lower TaskId
lookupTask name = do
  st <- get
  case Map.lookup name (lsTaskIds st) of
    Just tid -> return tid
    Nothing  -> allocTask name

lookupOrAllocTask :: Text -> Lower TaskId
lookupOrAllocTask = lookupTask

lookupOrAllocRequest :: Text -> Lower RequestId
lookupOrAllocRequest = allocRequest

addConst :: ConstVal -> Lower ConstId
addConst cv = do
  st <- get
  -- Check if already in pool
  let pool = lsConstPool st
      existing = [ fromIntegral (length pool - 1 - i)
                 | (i, c) <- zip [0..] pool, c == cv ]
  case existing of
    (cid:_) -> return cid
    []      -> do
      let cid = fromIntegral (length pool)
      put st { lsConstPool = cv : pool }
      return cid

addTask :: IRTask -> Lower ()
addTask task = modify (\st -> st { lsTasks = task : lsTasks st })

addRequestDef :: IRRequestDef -> Lower ()
addRequestDef rd = modify (\st -> st { lsRequests = rd : lsRequests st })
