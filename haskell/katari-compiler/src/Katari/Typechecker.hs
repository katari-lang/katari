module Katari.Typechecker
  ( TypeError (..),
    typecheck,
  )
where

import Control.Monad (forM, forM_, unless)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Katari.Module
import Katari.Syntax
import Katari.Types

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
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Type environment (local)
-- ---------------------------------------------------------------------------

data TypeEnv = TypeEnv
  { teVars :: Map Text NormalizedType,
    teGlobal :: GlobalEnv,
    teEffects :: Maybe (Set Text),
    teReturn :: Maybe NormalizedType
  }

emptyTEnv :: GlobalEnv -> TypeEnv
emptyTEnv ge =
  TypeEnv
    { teVars = Map.empty,
      teGlobal = ge,
      teEffects = Nothing,
      teReturn = Nothing
    }

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
typecheck ge modules = mapM_ checkMod modules
  where
    checkMod m = mapM_ (checkDecl ge) (modDecls m)

checkDecl :: GlobalEnv -> Decl -> TC ()
checkDecl ge = \case
  DeclTask sp td -> checkTask ge sp td
  DeclVal sp vd -> checkVal ge sp vd
  _ -> return ()

checkTask :: GlobalEnv -> SrcSpan -> TaskDecl -> TC ()
checkTask ge sp td = do
  let env0 = emptyTEnv ge
      paramVars = map (\(n, t) -> (n, normalize t (geTypeEnv ge))) (taskParams td)
      env1 = withVars paramVars env0
      retType = normalize (fromMaybe TNull (taskRet td)) (geTypeEnv ge)
      env2 = env1 {teReturn = Just retType}
  bodyType <- inferBlock env2 (taskBody td)
  unless (subtypeNT bodyType retType) $ Left (TypeMismatch sp bodyType retType)
  -- Effect checking (only when with annotation is explicit)
  case taskWith td of
    Nothing -> return () -- inferred: skip check
    Just eff -> do
      reqs <- collectRequestsBlock ge (taskBody td)
      let nonThrow = Set.delete "throw" reqs
      case eff of
        RETask ->
          unless (Set.null nonThrow) $
            Left (EffectMismatch sp (Set.toList nonThrow) [])
        RENames ns -> do
          let excess = Set.difference nonThrow (Set.fromList ns)
          unless (Set.null excess) $
            Left (EffectMismatch sp (Set.toList excess) ns)

checkVal :: GlobalEnv -> SrcSpan -> ValDecl -> TC ()
checkVal ge _sp vd = do
  let env = (emptyTEnv ge) {teEffects = Just Set.empty}
  _ <- inferExpr env (valExpr vd)
  return ()

-- ---------------------------------------------------------------------------
-- Block inference
-- ---------------------------------------------------------------------------

inferBlock :: TypeEnv -> Block -> TC NormalizedType
inferBlock env (Block stmts) = goStmts env stmts

goStmts :: TypeEnv -> [Stmt] -> TC NormalizedType
goStmts env stmts = case stmts of
  [] -> return ntNull
  [s] -> inferStmt env s
  s : ss -> do
    checkStmt env s
    env' <- updateEnv env s
    goStmts env' ss

-- Side-effect checking for non-final statements
checkStmt :: TypeEnv -> Stmt -> TC ()
checkStmt env = \case
  SHandle sp hs -> () <$ inferStmt env (SHandle sp hs)
  SExpr _sp e -> () <$ inferExpr env e
  SLet sp pat e -> do
    nt <- inferExpr env e
    checkPatAnnot sp pat nt (geTypeEnv (teGlobal env))
  _ -> return ()

-- Check that the inferred type matches any type annotation in the pattern
checkPatAnnot :: SrcSpan -> Pat -> NormalizedType -> Map Text NormalizedType -> TC ()
checkPatAnnot sp pat nt typeEnv = case pat of
  PTyped _ ty ->
    let annotNT = normalize ty typeEnv
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
    checkPatAnnot sp pat nt (geTypeEnv (teGlobal env))
    return ntNull
  SHandle sp hs -> do
    let ge = teGlobal env
        typeEnv = geTypeEnv ge
    -- Check state var init expressions and collect types
    stateVarTypes <- forM (hParams hs) $ \(name, ty, initExpr) -> do
      let nt = normalize ty typeEnv
      _ <- inferExpr env initExpr
      return (name, nt)
    let stateEnv = withVars stateVarTypes env
    -- Check each request case body (state vars + request args in scope)
    forM_ (hReqCases hs) $ \(reqName, pats, body) ->
      case Map.lookup reqName (geRequests ge) of
        Nothing -> Left (UndefinedName sp reqName)
        Just ri -> do
          let paramTypes = map (\(_, t) -> normalize t typeEnv) (riParams ri)
          let patEnv =
                foldr
                  (\(pat, nt) e -> bindPat pat nt e)
                  stateEnv
                  (zip pats paramTypes)
          _ <- inferBlock patEnv body
          return ()
    -- Check return case body (state vars in scope, return var bound to Unknown)
    case hReturnCase hs of
      Nothing -> return ()
      Just (retVar, body) -> do
        let retEnv = withVar retVar NTUnknown stateEnv
        _ <- inferBlock retEnv body
        return ()
    return ntNull
  SExpr _sp e -> inferExpr env e
  SReturn _sp e -> do
    nt <- inferExpr env e
    case teReturn env of
      Nothing -> return ntNull
      Just ret -> do
        unless (subtypeNT nt ret) $
          Left (TypeMismatch noSpan ret nt)
        return nt
  SReply _sp e _upd -> inferExpr env e >> return ntNull
  SNext _sp _upd -> return ntNull
  SBreak _sp e -> inferExpr env e >> return ntNull
  SForBreak _sp e -> inferExpr env e >> return ntNull

-- Bind pattern to type in environment
bindPat :: Pat -> NormalizedType -> TypeEnv -> TypeEnv
bindPat pat nt env = case pat of
  PVar n -> withVar n nt env
  PTyped n _ -> withVar n nt env
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
    Just ofields -> case Map.lookup name (ofFields ofields) of
      Just fi -> fiType fi
      Nothing -> NTUnknown
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
            return (n, FieldInfo nt False)
        )
        fields
    return (NTFields emptyNF {nfObject = Just (ObjectFields (Map.fromList fieldNTs))})
  ECall _sp callee args -> case callee of
    EVar _ name -> inferCall env noSpan name args
    EField _sp2 obj fname
      | fname == "__index__" -> do
          arrayNT <- inferExpr env obj
          _ <- mapM (inferExpr env) args
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
  EMatch _sp e arms -> do
    nt <- inferExpr env e
    armTypes <- mapM (inferArm env nt) arms
    case armTypes of
      [] -> return ntNever
      _ -> return (foldr1 unionNT armTypes)
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
      TemplExpr e -> () <$ inferExpr env e
    return ntString

inferArm :: TypeEnv -> NormalizedType -> CaseArm -> TC NormalizedType
inferArm env scrutineeType (CaseArm pat body) = do
  let patNT = patternTypeNT pat
      env' = bindPat pat (intersectNT scrutineeType patNT) env
  inferBlock env' body

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
          let nt = normalize ty (geTypeEnv (teGlobal env))
          return (n, nt)
      )
      (fVarBinds fe)
  let env' = withVars (letBindTypes ++ varBindTypes) env
  _ <- inferBlock env' (fBody fe)
  breakNT <- collectForBreakNT env' (fBody fe)
  finalNT <- case fFinally fe of
    Nothing -> return ntNull
    Just fb -> inferBlock env' fb
  return (unionNT finalNT breakNT)

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
  SReturn _ e -> collectForBreakExpr env e
  SReply _ e _ -> collectForBreakExpr env e
  SBreak _ e -> collectForBreakExpr env e
  SHandle _ hs -> do
    reqNTs <- mapM (\(_, _, b) -> collectForBreakNT env b) (hReqCases hs)
    retNT <- maybe (return ntNever) (\(_, b) -> collectForBreakNT env b) (hReturnCase hs)
    return (foldl unionNT retNT reqNTs)
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

inferCall :: TypeEnv -> SrcSpan -> Text -> [Expr] -> TC NormalizedType
inferCall env _sp name args = do
  let ge = teGlobal env
  mapM_ (inferExpr env) args
  case Map.lookup name (geTasks ge) of
    Just ti -> return (normalize (tiRet ti) (geTypeEnv ge))
    Nothing ->
      case Map.lookup name (geRequests ge) of
        Just ri -> return (normalize (riRet ri) (geTypeEnv ge))
        Nothing ->
          case Map.lookup name (teVars env) of
            Just nt -> return nt
            Nothing -> return NTUnknown

lookupVar :: TypeEnv -> SrcSpan -> Text -> TC NormalizedType
lookupVar env sp name =
  case Map.lookup name (teVars env) of
    Just nt -> return nt
    Nothing ->
      case Map.lookup name (geVals (teGlobal env)) of
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
collectRequestsBlock :: GlobalEnv -> Block -> TC (Set Text)
collectRequestsBlock ge (Block stmts) = collectRequestsStmts ge stmts

collectRequestsStmts :: GlobalEnv -> [Stmt] -> TC (Set Text)
collectRequestsStmts ge stmts = case stmts of
  [] -> return Set.empty
  SHandle _ hs : rest -> do
    -- Collect from the scope body (everything after this handle)
    restReqs <- collectRequestsStmts ge rest
    -- Remove requests handled by this handle block
    let handledNames = Set.fromList [n | (n, _, _) <- hReqCases hs]
    let scopeReqs = Set.difference restReqs handledNames
    -- Add requests from handler case bodies (they escape to outer scope)
    caseReqs <- mapM (\(_, _, b) -> collectRequestsBlock ge b) (hReqCases hs)
    -- Add requests from handle param init exprs
    initReqs <- mapM (\(_, _, e) -> collectRequestsExpr ge e) (hParams hs)
    -- Add requests from return case body
    retReqs <- maybe (return Set.empty) (\(_, b) -> collectRequestsBlock ge b) (hReturnCase hs)
    return $ Set.unions (scopeReqs : retReqs : caseReqs ++ initReqs)
  s : rest -> do
    a <- collectRequestsStmt ge s
    b <- collectRequestsStmts ge rest
    return (Set.union a b)

collectRequestsStmt :: GlobalEnv -> Stmt -> TC (Set Text)
collectRequestsStmt ge = \case
  SLet _ _ e -> collectRequestsExpr ge e
  SExpr _ e -> collectRequestsExpr ge e
  SReturn _ e -> collectRequestsExpr ge e
  SReply _ e _ -> collectRequestsExpr ge e
  SBreak _ e -> collectRequestsExpr ge e
  SForBreak _ e -> collectRequestsExpr ge e
  _ -> return Set.empty

collectRequestsExpr :: GlobalEnv -> Expr -> TC (Set Text)
collectRequestsExpr ge = \case
  ECall _ (EVar _ name) args -> do
    argReqs <- Set.unions <$> mapM (collectRequestsExpr ge) args
    let direct = case Map.lookup name (geRequests ge) of
          Just _ -> Set.singleton name
          Nothing -> Set.empty
    let transitive = case Map.lookup name (geTasks ge) of
          Just ti -> taskEffectSet ti
          Nothing -> Set.empty
    return (Set.unions [direct, transitive, argReqs])
  ECall _ callee args -> do
    a <- collectRequestsExpr ge callee
    b <- Set.unions <$> mapM (collectRequestsExpr ge) args
    return (Set.union a b)
  EIf _ cond thn els -> do
    a <- collectRequestsExpr ge cond
    b <- collectRequestsBlock ge thn
    c <- collectRequestsBlock ge els
    return (Set.unions [a, b, c])
  EMatch _ e arms -> do
    a <- collectRequestsExpr ge e
    bs <- mapM (\(CaseArm _ body) -> collectRequestsBlock ge body) arms
    return (Set.unions (a : bs))
  EFor _ fe -> do
    ls <- mapM (\(_, e) -> collectRequestsExpr ge e) (fLetBinds fe)
    vs <- mapM (\(_, _, e) -> collectRequestsExpr ge e) (fVarBinds fe)
    b <- collectRequestsBlock ge (fBody fe)
    f <- maybe (return Set.empty) (collectRequestsBlock ge) (fFinally fe)
    return (Set.unions (ls ++ vs ++ [b, f]))
  EPar _ blocks ->
    Set.unions <$> mapM (collectRequestsBlock ge) blocks
  EBlock _ b -> collectRequestsBlock ge b
  ETempl _ els ->
    Set.unions <$> mapM goElem els
    where
      goElem = \case
        TemplStr _ -> return Set.empty
        TemplExpr e -> collectRequestsExpr ge e
  EBinOp _ _ l r ->
    Set.union <$> collectRequestsExpr ge l <*> collectRequestsExpr ge r
  EUnOp _ _ e -> collectRequestsExpr ge e
  EField _ e _ -> collectRequestsExpr ge e
  EArr _ elems ->
    Set.unions <$> mapM (collectRequestsExpr ge) elems
  EObj _ fields ->
    Set.unions <$> mapM (\(_, e) -> collectRequestsExpr ge e) fields
  _ -> return Set.empty

-- Extract the declared effect set from a task's with annotation.
-- Tasks with no annotation (inferred) are treated as having no known effects.
taskEffectSet :: TaskInfo -> Set Text
taskEffectSet ti = case tiWith ti of
  Just RETask -> Set.empty
  Just (RENames ns) -> Set.fromList ns
  Nothing -> Set.empty
