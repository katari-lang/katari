module Katari.Typechecker
  ( TypeError (..)
  , typecheck
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Maybe (fromMaybe)
import Control.Monad (forM_, when, unless)

import Katari.Syntax
import Katari.Types
import Katari.Module

-- ---------------------------------------------------------------------------
-- Type error
-- ---------------------------------------------------------------------------

data TypeError
  = TypeMismatch    SrcSpan NormalizedType NormalizedType
  | UndefinedName   SrcSpan Text
  | EffectMismatch  SrcSpan [Text] [Text]
  | NonExhaustive   SrcSpan
  | ValWithEffect   SrcSpan Text
  | InvalidOp       SrcSpan String
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Type environment (local)
-- ---------------------------------------------------------------------------

data TypeEnv = TypeEnv
  { teVars    :: Map Text NormalizedType
  , teGlobal  :: GlobalEnv
  , teEffects :: Maybe (Set Text)
  , teReturn  :: Maybe NormalizedType
  }

emptyTEnv :: GlobalEnv -> TypeEnv
emptyTEnv ge = TypeEnv
  { teVars    = Map.empty
  , teGlobal  = ge
  , teEffects = Nothing
  , teReturn  = Nothing
  }

withVar :: Text -> NormalizedType -> TypeEnv -> TypeEnv
withVar n t env = env { teVars = Map.insert n t (teVars env) }

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
checkDecl ge (DeclTask sp td) = checkTask ge sp td
checkDecl ge (DeclVal  sp vd) = checkVal  ge sp vd
checkDecl _  _                = return ()

checkTask :: GlobalEnv -> SrcSpan -> TaskDecl -> TC ()
checkTask ge sp td = do
  let env0      = emptyTEnv ge
      paramVars = map (\(n, t) -> (n, normalize t (geTypeEnv ge))) (taskParams td)
      env1      = withVars paramVars env0
      retType   = normalize (fromMaybe TNull (taskRet td)) (geTypeEnv ge)
      env2      = env1 { teReturn = Just retType }
  _ <- inferBlock env2 (taskBody td)
  -- Effect checking (only when with annotation is explicit)
  case taskWith td of
    Nothing  -> return ()  -- inferred: skip check
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
  let env = (emptyTEnv ge) { teEffects = Just Set.empty }
  _ <- inferExpr env (valExpr vd)
  return ()

-- ---------------------------------------------------------------------------
-- Block inference
-- ---------------------------------------------------------------------------

inferBlock :: TypeEnv -> Block -> TC NormalizedType
inferBlock env (Block stmts) = goStmts env stmts

goStmts :: TypeEnv -> [Stmt] -> TC NormalizedType
goStmts _   []     = return ntNull
goStmts env [s]    = inferStmt env s
goStmts env (s:ss) = do
  env' <- updateEnv env s
  goStmts env' ss

-- Update environment after statement
updateEnv :: TypeEnv -> Stmt -> TC TypeEnv
updateEnv env (SLet _sp pat e) = do
  nt <- inferExpr env e
  return (bindPat pat nt env)
updateEnv env _ = return env

inferStmt :: TypeEnv -> Stmt -> TC NormalizedType
inferStmt env (SLet _sp _pat e)  = inferExpr env e >>= \_ -> return ntNull
inferStmt env (SHandle _sp _hs)  = return ntNull
inferStmt env (SExpr _sp e)      = inferExpr env e
inferStmt env (SReturn _sp e) = do
  nt <- inferExpr env e
  case teReturn env of
    Nothing  -> return ntNull
    Just ret -> do
      unless (subtypeNT nt ret) $
        Left (TypeMismatch noSpan ret nt)
      return nt
inferStmt env (SReply _sp e _upd) = inferExpr env e >>= \_ -> return ntNull
inferStmt env (SNext _sp _upd)    = return ntNull
inferStmt env (SBreak _sp e)      = inferExpr env e >>= \_ -> return ntNull
inferStmt env (SForBreak _sp e)   = inferExpr env e >>= \_ -> return ntNull

-- Bind pattern to type in environment
bindPat :: Pat -> NormalizedType -> TypeEnv -> TypeEnv
bindPat (PVar n)     nt env = withVar n nt env
bindPat (PTyped n _) nt env = withVar n nt env
bindPat (PTag _ n)   nt env = withVar n nt env
bindPat (PLit _)     _  env = env
bindPat (PArr pats) nt env =
  let elemType = case nt of
                   NTFields f -> fromMaybe NTUnknown (nfArray f)
                   _          -> NTUnknown
  in foldr (\p e -> bindPat p elemType e) env pats
bindPat (PObj fields) nt env =
  foldr (\(name, _, pat) e -> bindPat pat (fieldType nt name) e) env fields

fieldType :: NormalizedType -> Text -> NormalizedType
fieldType (NTFields f) name =
  case nfObject f of
    Just ofields -> case Map.lookup name (ofFields ofields) of
      Just fi -> fiType fi
      Nothing -> NTUnknown
    Nothing -> NTUnknown
fieldType (NTDISC d) name =
  foldr (\nf acc -> unionNT acc (fieldType (NTFields nf) name)) ntNever
        (Map.elems (discMapping d))
fieldType _ _ = NTUnknown

-- ---------------------------------------------------------------------------
-- Expression inference
-- ---------------------------------------------------------------------------

inferExpr :: TypeEnv -> Expr -> TC NormalizedType

inferExpr _env (ELit _ lit) = return (inferLit lit)

inferExpr env (EVar sp name) = lookupVar env sp name

inferExpr env (EField _sp e field) = do
  nt <- inferExpr env e
  return (fieldType nt field)

inferExpr env (EArr _sp elems) = do
  case elems of
    [] -> return (NTFields emptyNF { nfArray = Just ntNever })
    _  -> do
      nts <- mapM (inferExpr env) elems
      let elemType = foldr1 unionNT nts
      return (NTFields emptyNF { nfArray = Just elemType })

inferExpr env (EObj _sp fields) = do
  fieldNTs <- mapM (\(n, e) -> do
    nt <- inferExpr env e
    return (n, FieldInfo nt False)) fields
  return (NTFields emptyNF { nfObject = Just (ObjectFields (Map.fromList fieldNTs)) })

inferExpr env (ECall _sp callee args) =
  case callee of
    EVar _ name -> inferCall env noSpan name args
    EField _sp2 obj fname ->
      if fname == "__index__"
        then do
          arrayNT <- inferExpr env obj
          _ <- mapM (inferExpr env) args
          return (fromMaybe NTUnknown (nfArray =<< case arrayNT of
                                                     NTFields f -> Just f
                                                     _ -> Nothing))
        else do
          _ <- inferExpr env obj
          mapM_ (inferExpr env) args
          return NTUnknown
    _ -> do
      _ <- inferExpr env callee
      mapM_ (inferExpr env) args
      return NTUnknown

inferExpr env (EBinOp _sp op l r) = do
  lt <- inferExpr env l
  rt <- inferExpr env r
  return (inferBinOp op lt rt)

inferExpr env (EUnOp _sp op e) = do
  nt <- inferExpr env e
  return (inferUnOp op nt)

inferExpr env (EIf _sp cond thn els) = do
  _ <- inferExpr env cond
  t1 <- inferBlock env thn
  t2 <- inferBlock env els
  return (unionNT t1 t2)

inferExpr env (EMatch _sp e arms) = do
  nt <- inferExpr env e
  armTypes <- mapM (inferArm env nt) arms
  case armTypes of
    [] -> return ntNever
    _  -> return (foldr1 unionNT armTypes)

inferExpr env (EFor _sp fe) = inferFor env fe

inferExpr env (EPar _sp blocks) = do
  ts <- mapM (inferBlock env) blocks
  let elemType = case ts of
                   [] -> ntNever
                   _  -> foldr1 unionNT ts
  return (NTFields emptyNF { nfArray = Just elemType })

inferExpr env (EBlock _sp b) = inferBlock env b

inferExpr env (ETempl _sp elems) = do
  forM_ elems $ \el ->
    case el of
      TemplStr _  -> return ()
      TemplExpr e -> () <$ inferExpr env e
  return ntString

inferArm :: TypeEnv -> NormalizedType -> CaseArm -> TC NormalizedType
inferArm env scrutineeType (CaseArm pat body) = do
  let patNT = patternTypeNT pat
      env'  = bindPat pat (intersectNT scrutineeType patNT) env
  inferBlock env' body

inferFor :: TypeEnv -> ForExpr -> TC NormalizedType
inferFor env fe = do
  letBindTypes <- mapM (\(n, e) -> do
    nt <- inferExpr env e
    let elemType = case nt of
                     NTFields f -> fromMaybe NTUnknown (nfArray f)
                     _          -> NTUnknown
    return (n, elemType)) (fLetBinds fe)
  varBindTypes <- mapM (\(n, ty, e) -> do
    _ <- inferExpr env e
    let nt = normalize ty (geTypeEnv (teGlobal env))
    return (n, nt)) (fVarBinds fe)
  let env' = withVars (letBindTypes ++ varBindTypes) env
  _ <- inferBlock env' (fBody fe)
  case fFinally fe of
    Nothing -> return ntNull
    Just fb -> inferBlock env' fb

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
lookupVar env _sp name =
  case Map.lookup name (teVars env) of
    Just nt -> return nt
    Nothing ->
      case Map.lookup name (geVals (teGlobal env)) of
        Just vi -> return (viType vi)
        Nothing -> return NTUnknown

-- ---------------------------------------------------------------------------
-- Literal inference
-- ---------------------------------------------------------------------------

inferLit :: Lit -> NormalizedType
inferLit LNull     = ntNull
inferLit (LBool b) = NTFields emptyNF { nfBoolean = Just (BoolLits (Set.singleton b)) }
inferLit (LInt  i) = NTFields emptyNF { nfNumeric  = Just (NumericKind (IntLits (Set.singleton i)) NumAbsent) }
inferLit (LNum  n) = NTFields emptyNF { nfNumeric  = Just (NumericKind IntAbsent (NumLits (Set.singleton n))) }
inferLit (LStr  s) = NTFields emptyNF { nfString   = Just (StringLits (Set.singleton s)) }

-- ---------------------------------------------------------------------------
-- Operator type inference
-- ---------------------------------------------------------------------------

inferBinOp :: BinOp -> NormalizedType -> NormalizedType -> NormalizedType
inferBinOp OpAdd lt rt = numericResult lt rt
inferBinOp OpSub lt rt = numericResult lt rt
inferBinOp OpMul lt rt = numericResult lt rt
inferBinOp OpDiv _  _  = ntNumber
inferBinOp OpConcat lt rt
  | isStringType lt && isStringType rt = ntString
  | otherwise =
      let et1 = arrayElemType lt
          et2 = arrayElemType rt
      in NTFields emptyNF { nfArray = Just (unionNT et1 et2) }
inferBinOp OpLt  _ _ = ntBool
inferBinOp OpLe  _ _ = ntBool
inferBinOp OpGt  _ _ = ntBool
inferBinOp OpGe  _ _ = ntBool
inferBinOp OpEq  _ _ = ntBool
inferBinOp OpNe  _ _ = ntBool
inferBinOp OpAnd _ _ = ntBool
inferBinOp OpOr  _ _ = ntBool

inferUnOp :: UnOp -> NormalizedType -> NormalizedType
inferUnOp UnNeg nt = nt
inferUnOp UnNot _  = ntBool

numericResult :: NormalizedType -> NormalizedType -> NormalizedType
numericResult lt rt
  | isIntegerType lt && isIntegerType rt = ntInteger
  | otherwise = ntNumber

isIntegerType :: NormalizedType -> Bool
isIntegerType (NTFields f) = case nfNumeric f of
  Just (NumericKind ip NumAbsent) -> ip /= IntAbsent
  _ -> False
isIntegerType _ = False

isStringType :: NormalizedType -> Bool
isStringType (NTFields f) = case nfString f of Just _ -> True; _ -> False
isStringType _ = False

arrayElemType :: NormalizedType -> NormalizedType
arrayElemType (NTFields f) = fromMaybe NTUnknown (nfArray f)
arrayElemType _ = NTUnknown

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
collectRequestsStmts _ge [] = return Set.empty
collectRequestsStmts ge (SHandle _ hs : rest) = do
  -- Collect from the scope body (everything after this handle)
  restReqs <- collectRequestsStmts ge rest
  -- Remove requests handled by this handle block
  let handledNames = Set.fromList [n | (n, _, _) <- hReqCases hs]
  let scopeReqs    = Set.difference restReqs handledNames
  -- Add requests from handler case bodies (they escape to outer scope)
  caseReqs <- mapM (\(_, _, b) -> collectRequestsBlock ge b) (hReqCases hs)
  -- Add requests from handle param init exprs
  initReqs <- mapM (\(_, _, e) -> collectRequestsExpr ge e) (hParams hs)
  -- Add requests from return case body
  retReqs  <- maybe (return Set.empty) (\(_, b) -> collectRequestsBlock ge b) (hReturnCase hs)
  return $ Set.unions (scopeReqs : retReqs : caseReqs ++ initReqs)
collectRequestsStmts ge (s : rest) = do
  a <- collectRequestsStmt ge s
  b <- collectRequestsStmts ge rest
  return (Set.union a b)

collectRequestsStmt :: GlobalEnv -> Stmt -> TC (Set Text)
collectRequestsStmt ge (SLet    _ _ e)  = collectRequestsExpr ge e
collectRequestsStmt ge (SExpr   _ e)    = collectRequestsExpr ge e
collectRequestsStmt ge (SReturn _ e)    = collectRequestsExpr ge e
collectRequestsStmt ge (SReply  _ e _)  = collectRequestsExpr ge e
collectRequestsStmt ge (SBreak  _ e)    = collectRequestsExpr ge e
collectRequestsStmt ge (SForBreak _ e)  = collectRequestsExpr ge e
collectRequestsStmt _  _                = return Set.empty

collectRequestsExpr :: GlobalEnv -> Expr -> TC (Set Text)
collectRequestsExpr ge (ECall _ (EVar _ name) args) = do
  argReqs <- Set.unions <$> mapM (collectRequestsExpr ge) args
  let direct     = case Map.lookup name (geRequests ge) of
                     Just _  -> Set.singleton name
                     Nothing -> Set.empty
  let transitive = case Map.lookup name (geTasks ge) of
                     Just ti -> taskEffectSet ti
                     Nothing -> Set.empty
  return (Set.unions [direct, transitive, argReqs])
collectRequestsExpr ge (ECall _ callee args) = do
  a <- collectRequestsExpr ge callee
  b <- Set.unions <$> mapM (collectRequestsExpr ge) args
  return (Set.union a b)
collectRequestsExpr ge (EIf _ cond thn els) = do
  a <- collectRequestsExpr ge cond
  b <- collectRequestsBlock ge thn
  c <- collectRequestsBlock ge els
  return (Set.unions [a, b, c])
collectRequestsExpr ge (EMatch _ e arms) = do
  a  <- collectRequestsExpr ge e
  bs <- mapM (\(CaseArm _ body) -> collectRequestsBlock ge body) arms
  return (Set.unions (a : bs))
collectRequestsExpr ge (EFor _ fe) = do
  ls <- mapM (\(_, e)    -> collectRequestsExpr ge e) (fLetBinds fe)
  vs <- mapM (\(_, _, e) -> collectRequestsExpr ge e) (fVarBinds fe)
  b  <- collectRequestsBlock ge (fBody fe)
  f  <- maybe (return Set.empty) (collectRequestsBlock ge) (fFinally fe)
  return (Set.unions (ls ++ vs ++ [b, f]))
collectRequestsExpr ge (EPar _ blocks) =
  Set.unions <$> mapM (collectRequestsBlock ge) blocks
collectRequestsExpr ge (EBlock _ b)    = collectRequestsBlock ge b
collectRequestsExpr ge (ETempl _ els)  =
  Set.unions <$> mapM goElem els
  where
    goElem (TemplStr _)  = return Set.empty
    goElem (TemplExpr e) = collectRequestsExpr ge e
collectRequestsExpr ge (EBinOp _ _ l r) =
  Set.union <$> collectRequestsExpr ge l <*> collectRequestsExpr ge r
collectRequestsExpr ge (EUnOp  _ _ e)  = collectRequestsExpr ge e
collectRequestsExpr ge (EField _ e _)  = collectRequestsExpr ge e
collectRequestsExpr ge (EArr _ elems)  =
  Set.unions <$> mapM (collectRequestsExpr ge) elems
collectRequestsExpr ge (EObj _ fields) =
  Set.unions <$> mapM (\(_, e) -> collectRequestsExpr ge e) fields
collectRequestsExpr _  _               = return Set.empty

-- Extract the declared effect set from a task's with annotation.
-- Tasks with no annotation (inferred) are treated as having no known effects.
taskEffectSet :: TaskInfo -> Set Text
taskEffectSet ti = case tiWith ti of
  Just RETask       -> Set.empty
  Just (RENames ns) -> Set.fromList ns
  Nothing           -> Set.empty
