module Katari.Typechecker
  ( TypeError (..),
    typecheck,
  )
where

import Control.Monad (forM_, unless, void)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Module
  ( GlobalEnv (..),
    RequestInfo (..),
    AgentInfo (..),
    ValInfo (..),
    resolveQualified,
  )
import Katari.Syntax
  ( BinOp (..),
    Block (..),
    CaseArm (..),
    Decl (..),
    Expr (..),
    ForExpr (..),
    HandleStmt (..),
    Lit (..),
    Module (..),
    ObjField (..),
    Pat (..),
    RequestEffect (..),
    SrcSpan,
    Stmt (..),
    AgentDecl (..),
    TemplElem (..),
    Type (..),
    UnOp (..),
    ValDecl (..),
  )
import Katari.Types
  ( BoolKind (..),
    Discriminator (..),
    FieldInfo (..),
    IntPart (..),
    NormalFields (..),
    NormalizedType (..),
    NumPart (..),
    NumericKind (..),
    ObjectFields (..),
    StringKind (..),
    intersectNT,
    isNeverNT,
    normalize,
    ntBool,
    ntInteger,
    ntNever,
    ntNull,
    ntNumber,
    ntString,
    patternTypeNT,
    subtractNT,
    subtypeNT,
    unionNT,
  )

-- ---------------------------------------------------------------------------
-- Type error
-- ---------------------------------------------------------------------------

data TypeError
  = TypeMismatch SrcSpan NormalizedType NormalizedType
  | UndefinedName SrcSpan Text
  | EffectMismatch SrcSpan [Text] [Text]
  | NonExhaustive SrcSpan
  | ValWithEffect SrcSpan Text
  | InvalidOp SrcSpan String
  | ArityMismatch SrcSpan Text Int Int -- site, name, expected, actual
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Type environment (local)
-- ---------------------------------------------------------------------------

data TypeEnv = TypeEnv
  { teVars :: Map Text NormalizedType,
    teGlobal :: GlobalEnv,
    teModuleName :: Text,
    teEffects :: Maybe (Set Text),
    teReturn :: Maybe NormalizedType,
    teContinue :: Maybe NormalizedType -- expected type for SContinue (current request's riRet)
  }

emptyTEnv :: GlobalEnv -> Text -> TypeEnv
emptyTEnv ge mname =
  TypeEnv
    { teVars = Map.empty,
      teGlobal = ge,
      teModuleName = mname,
      teEffects = Nothing,
      teReturn = Nothing,
      teContinue = Nothing
    }

-- | Resolve a local (possibly dotted) name to a fully-qualified name
-- visible in the current module's alias table. Returns the input unchanged
-- if no alias matches (the caller will then look up the input directly,
-- which succeeds for names that are already qualified).
resolveLocal :: TypeEnv -> Text -> Text
resolveLocal env = resolveQualified (teGlobal env) (teModuleName env)

-- | Rewrite every 'TAlias name' in a type to its fully-qualified form as
-- seen from the current module, so the result can be fed directly into
-- 'normalize' (which looks up qualified names in 'geTypeEnv').
qualifyType :: TypeEnv -> Type -> Type
qualifyType env = go
  where
    go t = case t of
      TAlias name -> TAlias (resolveLocal env name)
      TArray inner -> TArray (go inner)
      TUnion ts -> TUnion (map go ts)
      TInter ts -> TInter (map go ts)
      TObj flds -> TObj (map goField flds)
      _ -> t
    goField f = f {ofType = go (ofType f)}

-- | Normalize a type as seen from the current module, first qualifying any
-- local type alias references.
normalizeIn :: TypeEnv -> Type -> NormalizedType
normalizeIn env ty = normalize (qualifyType env ty) (geTypeEnv (teGlobal env))

withVar :: Text -> NormalizedType -> TypeEnv -> TypeEnv
withVar n t env = env {teVars = Map.insert n t (teVars env)}

withVars :: [(Text, NormalizedType)] -> TypeEnv -> TypeEnv
withVars kvs env = foldr (uncurry withVar) env kvs

-- ---------------------------------------------------------------------------
-- Monad alias
-- ---------------------------------------------------------------------------

type TC a = Either TypeError a

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

typecheck :: GlobalEnv -> [Module] -> Either TypeError ()
typecheck ge = mapM_ checkMod
  where
    checkMod m = mapM_ (checkDecl ge (modName m)) (modDecls m)

checkDecl :: GlobalEnv -> Text -> Decl -> TC ()
checkDecl ge mname = \case
  DeclAgent sp td -> checkAgent ge mname sp td
  DeclVal sp vd -> checkVal ge mname sp vd
  _ -> return ()

checkAgent :: GlobalEnv -> Text -> SrcSpan -> AgentDecl -> TC ()
checkAgent ge mname sp td = do
  let env0 = emptyTEnv ge mname
      paramVars = map (\(n, t, _) -> (n, normalizeIn env0 t)) (agentParams td)
      env1 = withVars paramVars env0
      retType = normalizeIn env0 (fromMaybe TNull (agentRet td))
      env2 = env1 {teReturn = Just retType}
  bodyType <- inferBlock env2 (agentBody td)
  unless (subtypeNT bodyType retType) $ Left (TypeMismatch sp bodyType retType)
  -- Effect checking (only when with annotation is explicit)
  case agentWith td of
    Nothing -> return () -- inferred: skip check
    Just eff -> do
      reqs <- collectRequestsBlock env2 (agentBody td)
      let nonThrow = Set.delete "prim.throw" reqs
      case eff of
        REAgent ->
          unless (Set.null nonThrow) $
            Left (EffectMismatch sp (Set.toList nonThrow) [])
        RENames ns -> do
          -- `with` 節に書かれた名前はローカル alias の可能性があるので qualify する。
          let qualifiedExpected =
                Set.fromList (map (resolveQualified ge mname) ns)
              excess = Set.difference nonThrow qualifiedExpected
          unless (Set.null excess) $
            Left (EffectMismatch sp (Set.toList excess) ns)

checkVal :: GlobalEnv -> Text -> SrcSpan -> ValDecl -> TC ()
checkVal ge mname sp vd = do
  let env = (emptyTEnv ge mname) {teEffects = Just Set.empty}
  nt <- inferExpr env (valExpr vd)
  -- val must be effect-free (throw is implicit and allowed everywhere)
  reqs <- collectRequestsExpr env (valExpr vd)
  let nonThrow = Set.delete "prim.throw" reqs
  case Set.toList nonThrow of
    [] -> return ()
    (r : _) -> Left (ValWithEffect sp r)
  -- Check declared type
  let declared = normalizeIn env (valType vd)
  unless (subtypeNT nt declared) $
    Left (TypeMismatch sp nt declared)

-- ---------------------------------------------------------------------------
-- Block inference
-- ---------------------------------------------------------------------------

inferBlock :: TypeEnv -> Block -> TC NormalizedType
inferBlock env (Block stmts) = goStmts env stmts

goStmts :: TypeEnv -> [Stmt] -> TC NormalizedType
goStmts env = \case
  [] -> return ntNull
  SHandle sp hs : rest -> inferHandle env sp hs rest
  [s] -> inferStmt env s
  s : ss -> do
    nt <- inferStmt env s
    if isNeverNT nt
      then return ntNever -- unreachable code after control statement
      else do
        env' <- updateEnv env s
        goStmts env' ss

-- | Handle statement: wraps remaining statements as the scope body.
-- The result type is the then clause's result (if present) or the scope body's type.
inferHandle :: TypeEnv -> SrcSpan -> HandleStmt -> [Stmt] -> TC NormalizedType
inferHandle env sp hs rest = do
  let ge = teGlobal env
  -- Check state var init expressions and collect types
  stateVarTypes <- mapM (\(name, ty, _, initExpr) -> do
    let nt = normalizeIn env ty
    initNT <- inferExpr env initExpr
    unless (subtypeNT initNT nt) $
      Left (TypeMismatch sp initNT nt)
    return (name, nt)) (hParams hs)
  let stateEnv = withVars stateVarTypes env
  -- Check each request case body with teContinue set to the request's return type
  forM_ (hReqCases hs) $ \(reqName, pats, body) -> do
    let qreq = resolveLocal env reqName
    case Map.lookup qreq (geRequests ge) of
      Nothing -> Left (UndefinedName sp reqName)
      Just ri -> do
        let paramTypes = map (\(_, t, _) -> normalizeAs ge (riHomeModule ri) t) (riParams ri)
        let continueType = normalizeAs ge (riHomeModule ri) (riRet ri)
        let patEnv =
              ( foldr
                  (\(pat, nt) e -> bindPat pat nt e)
                  stateEnv
                  (zip pats paramTypes)
              )
                { teContinue = Just continueType
                }
        void (inferBlock patEnv body)
  -- Process remaining statements as the handle scope body
  scopeType <- goStmts stateEnv rest
  -- Apply then clause: bind thenVar to scopeType, infer then body
  case hThenClause hs of
    Nothing -> return scopeType
    Just (thenVar, body) -> do
      let thenEnv = withVar thenVar scopeType stateEnv
      inferBlock thenEnv body

-- Check that the inferred type matches any type annotation in the pattern
checkPatAnnot :: TypeEnv -> SrcSpan -> Pat -> NormalizedType -> TC ()
checkPatAnnot env sp pat nt = case pat of
  PTyped _ ty ->
    let annotNT = normalizeIn env ty
     in unless (subtypeNT nt annotNT) $ Left (TypeMismatch sp nt annotNT)
  _ -> return ()

-- Update environment after statement
updateEnv :: TypeEnv -> Stmt -> TC TypeEnv
updateEnv env = \case
  SLet _sp pat e -> do
    nt <- inferExpr env e
    return (bindPat pat nt env)
  _ -> return env

inferStmt :: TypeEnv -> Stmt -> TC NormalizedType
inferStmt env = \case
  SLet sp pat e -> do
    nt <- inferExpr env e
    checkPatAnnot env sp pat nt
    return ntNull
  SHandle _ _ -> error "SHandle must be handled by goStmts/inferHandle"
  SExpr _sp e -> inferExpr env e
  SReturn sp e -> do
    nt <- inferExpr env e
    case teReturn env of
      Nothing -> Left (InvalidOp sp "return outside agent body")
      Just ret -> do
        unless (subtypeNT nt ret) $
          Left (TypeMismatch sp nt ret)
        return ntNever
  SContinue sp e _upd -> do
    nt <- inferExpr env e
    case teContinue env of
      Nothing -> Left (InvalidOp sp "continue outside request handler")
      Just expected -> do
        unless (subtypeNT nt expected) $
          Left (TypeMismatch sp nt expected)
        return ntNever
  SForContinue _sp _upd -> return ntNever
  SBreak _sp e -> do
    void (inferExpr env e)
    return ntNever
  SForBreak _sp e -> do
    void (inferExpr env e)
    return ntNever

-- Bind pattern to type in environment
bindPat :: Pat -> NormalizedType -> TypeEnv -> TypeEnv
bindPat pat nt env = case pat of
  PVar n -> withVar n nt env
  PTyped n ty -> withVar n (normalizeIn env ty) env
  PTag _ n -> withVar n nt env
  PLit _ -> env
  PArr pats ->
    let elemType = case nt of
          NTFields f -> fromMaybe NTUnknown (nfArray f)
          _ -> NTUnknown
     in foldr (`bindPat` elemType) env pats
  PObj fields ->
    foldr (\(name, _, p) e -> bindPat p (fieldType nt name) e) env fields

fieldType :: NormalizedType -> Text -> NormalizedType
fieldType nt name = case nt of
  NTFields f -> case nfObject f of
    Just ofields -> maybe NTUnknown fiType (Map.lookup name (ofFields ofields))
    Nothing -> NTUnknown
  NTDISC d ->
    foldr
      (\nf acc -> unionNT acc (fieldType (NTFields nf) name))
      ntNever
      (Map.elems (discMapping d))
  _ -> NTUnknown

-- ---------------------------------------------------------------------------
-- Expression inference
-- ---------------------------------------------------------------------------

inferExpr :: TypeEnv -> Expr -> TC NormalizedType
inferExpr env = \case
  ELit _ lit -> return (inferLit lit)
  EVar sp name -> lookupVar env sp name
  EField _sp e field -> do
    nt <- inferExpr env e
    return (fieldType nt field)
  EArr _sp elems -> case elems of
    [] -> return (NTFields emptyNF {nfArray = Just ntNever})
    _ -> do
      nts <- mapM (inferExpr env) elems
      let elemType = foldr1 unionNT nts
      return (NTFields emptyNF {nfArray = Just elemType})
  EObj _sp fields -> do
    fieldNTs <-
      mapM
        ( \(n, e) -> do
            nt <- inferExpr env e
            return (n, FieldInfo nt False Nothing)
        )
        fields
    return (NTFields emptyNF {nfObject = Just (ObjectFields (Map.fromList fieldNTs))})
  ECall sp callee args -> case callee of
    EVar _ name -> inferCall env sp name args
    EField _sp2 obj fname
      | fname == "__index__" -> do
          arrayNT <- inferExpr env obj
          mapM_ (inferExpr env) args
          return
            ( fromMaybe
                NTUnknown
                ( nfArray =<< case arrayNT of
                    NTFields f -> Just f
                    _ -> Nothing
                )
            )
      | otherwise -> do
          _ <- inferExpr env obj
          mapM_ (inferExpr env) args
          return NTUnknown
    _ -> do
      _ <- inferExpr env callee
      mapM_ (inferExpr env) args
      return NTUnknown
  EBinOp _sp op l r -> do
    lt <- inferExpr env l
    rt <- inferExpr env r
    return (inferBinOp op lt rt)
  EUnOp _sp op e -> do
    nt <- inferExpr env e
    return (inferUnOp op nt)
  EIf _sp cond thn els -> do
    _ <- inferExpr env cond
    t1 <- inferBlock env thn
    t2 <- inferBlock env els
    return (unionNT t1 t2)
  EMatch sp e arms -> do
    nt <- inferExpr env e
    (remaining, armTypes) <- foldStep nt [] arms
    -- Exhaustiveness check: remaining type must be Never.
    -- subtractNT is conservative for arrays/objects, so this may false-positive
    -- on some DISC-free cases. That's acceptable for now.
    unless (isNeverNT remaining) $ Left (NonExhaustive sp)
    case armTypes of
      [] -> return ntNever
      _ -> return (foldr1 unionNT armTypes)
    where
      foldStep :: NormalizedType -> [NormalizedType] -> [CaseArm] -> TC (NormalizedType, [NormalizedType])
      foldStep rem_ acc [] = return (rem_, reverse acc)
      foldStep rem_ acc (arm : rest) = do
        let patNT = patternTypeNT (caPat arm)
            narrowed = intersectNT rem_ patNT
            armEnv = bindPat (caPat arm) narrowed env
        bodyT <- inferBlock armEnv (caBody arm)
        let rem' = subtractNT rem_ patNT
        foldStep rem' (bodyT : acc) rest
  EFor _sp fe -> inferFor env fe
  EPar _sp blocks -> do
    ts <- mapM (inferBlock env) blocks
    let elemType = case ts of
          [] -> ntNever
          _ -> foldr1 unionNT ts
    return (NTFields emptyNF {nfArray = Just elemType})
  EBlock _sp b -> inferBlock env b
  ETempl _sp elems -> do
    forM_ elems $ \case
      TemplStr _ -> return ()
      TemplExpr e -> void (inferExpr env e)
    return ntString

inferFor :: TypeEnv -> ForExpr -> TC NormalizedType
inferFor env fe = do
  letBindTypes <-
    mapM
      ( \(n, e) -> do
          nt <- inferExpr env e
          let elemType = case nt of
                NTFields f -> fromMaybe NTUnknown (nfArray f)
                _ -> NTUnknown
          return (n, elemType)
      )
      (fLetBinds fe)
  varBindTypes <-
    mapM
      ( \(n, ty, e) -> do
          _ <- inferExpr env e
          let nt = normalizeIn env ty
          return (n, nt)
      )
      (fVarBinds fe)
  let env' = withVars (letBindTypes ++ varBindTypes) env
  _ <- inferBlock env' (fBody fe)
  breakNT <- collectForBreakNT env' (fBody fe)
  thenNT <- case fThen fe of
    Nothing -> return ntNull
    Just fb -> inferBlock env' fb
  return (unionNT thenNT breakNT)

-- Collect the union of all for_break expression types in a block,
-- NOT descending into nested for expressions.
-- Updates the environment as let-bindings are encountered.
collectForBreakNT :: TypeEnv -> Block -> TC NormalizedType
collectForBreakNT env (Block stmts) = goFBStmts env stmts
  where
    goFBStmts _ [] = return ntNever
    goFBStmts e (s : ss) = do
      nt <- collectForBreakStmt e s
      e' <- updateEnv e s
      rest <- goFBStmts e' ss
      return (unionNT nt rest)

collectForBreakStmt :: TypeEnv -> Stmt -> TC NormalizedType
collectForBreakStmt env = \case
  SForBreak _ e -> inferExpr env e
  SLet _ _ e -> collectForBreakExpr env e
  SExpr _ e -> collectForBreakExpr env e
  SReturn _ _ -> return ntNever
  SContinue {} -> return ntNever
  SBreak _ _ -> return ntNever
  SHandle _ hs -> do
    reqNTs <- mapM (\(_, _, b) -> collectForBreakNT env b) (hReqCases hs)
    thenNT <- maybe (return ntNever) (\(_, b) -> collectForBreakNT env b) (hThenClause hs)
    return (foldl unionNT thenNT reqNTs)
  _ -> return ntNever

collectForBreakExpr :: TypeEnv -> Expr -> TC NormalizedType
collectForBreakExpr env = \case
  EIf _ _ thn els -> do
    a <- collectForBreakNT env thn
    b <- collectForBreakNT env els
    return (unionNT a b)
  EMatch _ _ arms ->
    foldl unionNT ntNever <$> mapM (\(CaseArm _ body) -> collectForBreakNT env body) arms
  EBlock _ body -> collectForBreakNT env body
  EFor _ _ -> return ntNever -- don't descend into nested for
  _ -> return ntNever

-- | Qualify type aliases using a specific module's alias table (not the
--   current module). Used when normalizing parameter/return types of agents
--   and requests defined in other modules.
qualifyTypeAs :: GlobalEnv -> Text -> Type -> Type
qualifyTypeAs ge modName = go
  where
    resolve = resolveQualified ge modName
    go t = case t of
      TAlias n -> TAlias (resolve n)
      TArray inner -> TArray (go inner)
      TUnion ts -> TUnion (map go ts)
      TInter ts -> TInter (map go ts)
      TObj flds -> TObj (map goField flds)
      _ -> t
    goField f = f {ofType = go (ofType f)}

-- | Normalize a Type using a specific module's alias context.
normalizeAs :: GlobalEnv -> Text -> Type -> NormalizedType
normalizeAs ge modName ty = normalize (qualifyTypeAs ge modName ty) (geTypeEnv ge)

inferCall :: TypeEnv -> SrcSpan -> Text -> [Expr] -> TC NormalizedType
inferCall env sp name args = do
  let ge = teGlobal env
      qname = resolveLocal env name
  case Map.lookup qname (geAgents ge) of
    Just ai -> do
      checkArgs sp name (aiParams ai) args (aiHomeModule ai)
      return (normalizeAs ge (aiHomeModule ai) (aiRet ai))
    Nothing ->
      case Map.lookup qname (geRequests ge) of
        Just ri -> do
          checkArgs sp name (riParams ri) args (riHomeModule ri)
          return (normalizeAs ge (riHomeModule ri) (riRet ri))
        Nothing ->
          case Map.lookup name (teVars env) of
            Just nt -> do
              mapM_ (inferExpr env) args
              return nt
            Nothing -> Left (UndefinedName sp name)
  where
    checkArgs :: SrcSpan -> Text -> [(Text, Type, Maybe Text)] -> [Expr] -> Text -> TC ()
    checkArgs callSp callName params callArgs homeModule = do
      let ge = teGlobal env
          expected = length params
          actual = length callArgs
      unless (expected == actual) $
        Left (ArityMismatch callSp callName expected actual)
      forM_ (zip params callArgs) $ \((_pn, pty, _pa), argE) -> do
        argNT <- inferExpr env argE
        let paramNT = normalizeAs ge homeModule pty
        unless (subtypeNT argNT paramNT) $
          Left (TypeMismatch callSp argNT paramNT)

lookupVar :: TypeEnv -> SrcSpan -> Text -> TC NormalizedType
lookupVar env sp name =
  case Map.lookup name (teVars env) of
    Just nt -> return nt
    Nothing ->
      let qname = resolveLocal env name
       in case Map.lookup qname (geVals (teGlobal env)) of
            Just vi -> return (viType vi)
            Nothing -> Left (UndefinedName sp name)

-- ---------------------------------------------------------------------------
-- Literal inference
-- ---------------------------------------------------------------------------

inferLit :: Lit -> NormalizedType
inferLit = \case
  LNull -> ntNull
  LBool b -> NTFields emptyNF {nfBoolean = Just (BoolLits (Set.singleton b))}
  LInt i -> NTFields emptyNF {nfNumeric = Just (NumericKind (IntLits (Set.singleton i)) NumAbsent)}
  LNum n -> NTFields emptyNF {nfNumeric = Just (NumericKind IntAbsent (NumLits (Set.singleton n)))}
  LStr s -> NTFields emptyNF {nfString = Just (StringLits (Set.singleton s))}

-- ---------------------------------------------------------------------------
-- Operator type inference
-- ---------------------------------------------------------------------------

inferBinOp :: BinOp -> NormalizedType -> NormalizedType -> NormalizedType
inferBinOp op lt rt = case op of
  OpAdd -> numericResult lt rt
  OpSub -> numericResult lt rt
  OpMul -> numericResult lt rt
  OpDiv -> ntNumber
  OpConcat
    | isStringType lt && isStringType rt -> ntString
    | otherwise ->
        let et1 = arrayElemType lt
            et2 = arrayElemType rt
         in NTFields emptyNF {nfArray = Just (unionNT et1 et2)}
  OpLt -> ntBool
  OpLe -> ntBool
  OpGt -> ntBool
  OpGe -> ntBool
  OpEq -> ntBool
  OpNe -> ntBool
  OpAnd -> ntBool
  OpOr -> ntBool

inferUnOp :: UnOp -> NormalizedType -> NormalizedType
inferUnOp op nt = case op of
  UnNeg -> nt
  UnNot -> ntBool

numericResult :: NormalizedType -> NormalizedType -> NormalizedType
numericResult lt rt
  | isIntegerType lt && isIntegerType rt = ntInteger
  | otherwise = ntNumber

isIntegerType :: NormalizedType -> Bool
isIntegerType = \case
  NTFields f -> case nfNumeric f of
    Just (NumericKind ip NumAbsent) -> ip /= IntAbsent
    _ -> False
  _ -> False

isStringType :: NormalizedType -> Bool
isStringType = \case
  NTFields f -> case nfString f of Just _ -> True; _ -> False
  _ -> False

arrayElemType :: NormalizedType -> NormalizedType
arrayElemType = \case
  NTFields f -> fromMaybe NTUnknown (nfArray f)
  _ -> NTUnknown

emptyNF :: NormalFields
emptyNF = NormalFields False Nothing Nothing Nothing Nothing Nothing

-- ---------------------------------------------------------------------------
-- Effect (request) collection
-- ---------------------------------------------------------------------------

-- Collect the set of request names that may occur in a block,
-- accounting for handle blocks removing handled requests.
-- All returned names are fully qualified.
collectRequestsBlock :: TypeEnv -> Block -> TC (Set Text)
collectRequestsBlock env (Block stmts) = collectRequestsStmts env stmts

collectRequestsStmts :: TypeEnv -> [Stmt] -> TC (Set Text)
collectRequestsStmts env stmts = case stmts of
  [] -> return Set.empty
  SHandle _ hs : rest -> do
    -- Collect from the scope body (everything after this handle)
    restReqs <- collectRequestsStmts env rest
    -- Remove requests handled by this handle block (resolve to qualified).
    let handledNames =
          Set.fromList [resolveLocal env n | (n, _, _) <- hReqCases hs]
    let scopeReqs = Set.difference restReqs handledNames
    -- Add requests from handler case bodies (they escape to outer scope)
    caseReqs <- mapM (\(_, _, b) -> collectRequestsBlock env b) (hReqCases hs)
    -- Add requests from handle param init exprs
    initReqs <- mapM (\(_, _, _, e) -> collectRequestsExpr env e) (hParams hs)
    -- Add requests from then clause body
    thenReqs <-
      maybe
        (return Set.empty)
        (\(_, b) -> collectRequestsBlock env b)
        (hThenClause hs)
    return $ Set.unions (scopeReqs : thenReqs : caseReqs ++ initReqs)
  s : rest -> do
    a <- collectRequestsStmt env s
    b <- collectRequestsStmts env rest
    return (Set.union a b)

collectRequestsStmt :: TypeEnv -> Stmt -> TC (Set Text)
collectRequestsStmt env = \case
  SLet _ _ e -> collectRequestsExpr env e
  SExpr _ e -> collectRequestsExpr env e
  SReturn _ e -> collectRequestsExpr env e
  SContinue _ e _ -> collectRequestsExpr env e
  SBreak _ e -> collectRequestsExpr env e
  SForBreak _ e -> collectRequestsExpr env e
  _ -> return Set.empty

collectRequestsExpr :: TypeEnv -> Expr -> TC (Set Text)
collectRequestsExpr env = \case
  ECall _ (EVar _ name) args -> do
    argReqs <- Set.unions <$> mapM (collectRequestsExpr env) args
    let ge = teGlobal env
        qname = resolveLocal env name
    let direct = case Map.lookup qname (geRequests ge) of
          Just _ -> Set.singleton qname
          Nothing -> Set.empty
    let transitive = case Map.lookup qname (geAgents ge) of
          Just ai -> agentEffectSet env ai
          Nothing -> Set.empty
    return (Set.unions [direct, transitive, argReqs])
  ECall _ callee args -> do
    a <- collectRequestsExpr env callee
    b <- Set.unions <$> mapM (collectRequestsExpr env) args
    return (Set.union a b)
  EIf _ cond thn els -> do
    a <- collectRequestsExpr env cond
    b <- collectRequestsBlock env thn
    c <- collectRequestsBlock env els
    return (Set.unions [a, b, c])
  EMatch _ e arms -> do
    a <- collectRequestsExpr env e
    bs <- mapM (\(CaseArm _ body) -> collectRequestsBlock env body) arms
    return (Set.unions (a : bs))
  EFor _ fe -> do
    ls <- mapM (\(_, e) -> collectRequestsExpr env e) (fLetBinds fe)
    vs <- mapM (\(_, _, e) -> collectRequestsExpr env e) (fVarBinds fe)
    b <- collectRequestsBlock env (fBody fe)
    f <- maybe (return Set.empty) (collectRequestsBlock env) (fThen fe)
    return (Set.unions (ls ++ vs ++ [b, f]))
  EPar _ blocks ->
    Set.unions <$> mapM (collectRequestsBlock env) blocks
  EBlock _ b -> collectRequestsBlock env b
  ETempl _ els ->
    Set.unions <$> mapM goElem els
    where
      goElem = \case
        TemplStr _ -> return Set.empty
        TemplExpr e -> collectRequestsExpr env e
  EBinOp _ _ l r ->
    Set.union <$> collectRequestsExpr env l <*> collectRequestsExpr env r
  EUnOp _ _ e -> collectRequestsExpr env e
  EField _ e _ -> collectRequestsExpr env e
  EArr _ elems ->
    Set.unions <$> mapM (collectRequestsExpr env) elems
  EObj _ fields ->
    Set.unions <$> mapM (\(_, e) -> collectRequestsExpr env e) fields
  _ -> return Set.empty

-- Extract the declared effect set from an agent's with annotation.
-- Agents with no annotation (inferred) are treated as having no known effects.
-- The names declared in `with` may be unqualified local references in the
-- agent's home module, so we resolve them via the alias table of the module
-- they were declared in. We don't track that module here, so we instead use
-- the *caller's* module context. Since `with` names are eventually compared
-- against fully-qualified request names from the callee site, the caller-
-- module alias table is what matters for comparison purposes. Any name that
-- fails to resolve is passed through unchanged.
agentEffectSet :: TypeEnv -> AgentInfo -> Set Text
agentEffectSet env ai = case aiWith ai of
  Just REAgent -> Set.empty
  Just (RENames ns) -> Set.fromList (map (resolveLocal env) ns)
  Nothing -> Set.empty
