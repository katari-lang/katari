module Katari.Module
  ( GlobalEnv (..),
    TaskInfo (..),
    RequestInfo (..),
    ValInfo (..),
    TypeInfo (..),
    ModuleError (..),
    buildGlobalEnv,
    primRequests,
    primModuleName,
    resolveQualified,
    aliasesFor,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Katari.Syntax
  ( Decl (..),
    ExternalReqDecl (..),
    ExternalTaskDecl (..),
    ImportDecl (..),
    Module (..),
    ObjField (..),
    RequestDecl (..),
    RequestEffect (..),
    TaskDecl (..),
    Type (..),
    TypeAliasDecl (..),
    ValDecl (..),
  )
import Katari.Types
  ( FieldInfo (..),
    NormalFields (..),
    NormalizedType (..),
    ObjectFields (..),
    intersectNT,
    isNeverNT,
    normalize,
    ntBool,
    ntInteger,
    ntNever,
    ntNull,
    ntNumber,
    ntString,
    tryMakeDISC,
    unionNT,
  )

-- ---------------------------------------------------------------------------
-- Global environment
-- ---------------------------------------------------------------------------

data TaskInfo = TaskInfo
  { tiParams :: [(Text, Type, Maybe Text)], -- (name, type, annotation)
    tiRet :: Type,
    tiWith :: Maybe RequestEffect,
    tiExtFrom :: Maybe Text, -- for external tasks
    tiAnnot :: Maybe Text, -- @"..." description for schema
    tiHomeModule :: Text -- defining module (for TAlias resolution in Type)
  }
  deriving (Show)

data RequestInfo = RequestInfo
  { riParams :: [(Text, Type, Maybe Text)],
    riRet :: Type,
    riExtFrom :: Maybe Text, -- for external requests
    riAnnot :: Maybe Text,
    riHomeModule :: Text
  }
  deriving (Show)

data ValInfo = ValInfo
  { viType :: NormalizedType,
    viHomeModule :: Text
  }
  deriving (Show)

newtype TypeInfo = TypeInfo
  { tyAlias :: Type
  }
  deriving (Show)

-- | All keys in the maps below are **qualified names** (e.g. "prim.div",
--   "lib.cron.schedule"). Local (unqualified) names are resolved per-module
--   via 'geAliases', which maps each module name to a map from locally-visible
--   names (those brought into scope by declarations or import statements) to
--   their fully-qualified names.
data GlobalEnv = GlobalEnv
  { geTasks :: Map Text TaskInfo,
    geRequests :: Map Text RequestInfo,
    geVals :: Map Text ValInfo,
    geTypes :: Map Text TypeInfo,
    geTypeEnv :: Map Text NormalizedType,
    geAliases :: Map Text (Map Text Text)
  }
  deriving (Show)

emptyEnv :: GlobalEnv
emptyEnv =
  GlobalEnv
    { geTasks = Map.empty,
      geRequests = Map.empty,
      geVals = Map.empty,
      geTypes = Map.empty,
      geTypeEnv = Map.empty,
      geAliases = Map.empty
    }

-- | Virtual module name under which primitive tasks/requests live.
primModuleName :: Text
primModuleName = "prim"

-- | Look up a local name in the current module's alias table, returning
--   the fully-qualified name if found. Falls back to the argument itself
--   (treated as already-qualified) when no alias is present.
resolveQualified :: GlobalEnv -> Text -> Text -> Text
resolveQualified ge modName name =
  case Map.lookup modName (geAliases ge) of
    Just aliases -> fromMaybe name (Map.lookup name aliases)
    Nothing -> name

-- | Return the alias table for a given module (empty if the module has no
--   entries).
aliasesFor :: GlobalEnv -> Text -> Map Text Text
aliasesFor ge modName = fromMaybe Map.empty (Map.lookup modName (geAliases ge))

-- ---------------------------------------------------------------------------
-- Error
-- ---------------------------------------------------------------------------

data ModuleError
  = DuplicateName Text
  | UnknownTypeAlias Text
  | RecursiveTypeAlias [Text]
  | UnknownImport Text
  | UnknownImportName Text Text
  | RecursiveImport [Text]
  | AmbiguousName Text [Text]
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Primitive definitions
-- ---------------------------------------------------------------------------

-- prim module built-ins: throw and parse_error
primRequests :: Map Text RequestInfo
primRequests =
  Map.fromList
    [ ( "prim.throw",
        RequestInfo
          { riParams = [("message", TString, Nothing)],
            riRet = TNever,
            riExtFrom = Nothing,
            riAnnot = Nothing,
            riHomeModule = primModuleName
          }
      ),
      ( "prim.parse_error",
        RequestInfo
          { riParams = [("message", TString, Nothing)],
            riRet = TNever,
            riExtFrom = Nothing,
            riAnnot = Nothing,
            riHomeModule = primModuleName
          }
      )
    ]

-- prim built-in tasks. すべて qualified name (prim.<name>) で登録する。
-- 短縮名エイリアスは一切提供しない。ユーザコードは `import prim { ... }`
-- や `import prim.log { ... }` を明示的に書くことで参照する。
primTasks :: Map Text TaskInfo
primTasks =
  Map.fromList
    [ -- to_string :: integer | number | boolean | string | null -> string (純粋)
      ( "prim.to_string",
        TaskInfo
          { tiParams = [("v", TUnion [TInteger, TNumber, TBoolean, TString, TNull], Nothing)],
            tiRet = TString,
            tiWith = Just (RENames []),
            tiExtFrom = Nothing,
            tiAnnot = Nothing,
            tiHomeModule = primModuleName
          }
      ),
      -- div :: (integer | number, integer | number) -> integer (floor division)
      ( "prim.div",
        TaskInfo
          { tiParams =
              [ ("a", TUnion [TInteger, TNumber], Nothing),
                ("b", TUnion [TInteger, TNumber], Nothing)
              ],
            tiRet = TInteger,
            tiWith = Just (RENames []),
            tiExtFrom = Nothing,
            tiAnnot = Nothing,
            tiHomeModule = primModuleName
          }
      ),
      -- mod :: (integer | number, integer | number) -> number
      ( "prim.mod",
        TaskInfo
          { tiParams =
              [ ("a", TUnion [TInteger, TNumber], Nothing),
                ("b", TUnion [TInteger, TNumber], Nothing)
              ],
            tiRet = TNumber,
            tiWith = Just (RENames []),
            tiExtFrom = Nothing,
            tiAnnot = Nothing,
            tiHomeModule = primModuleName
          }
      ),
      -- parse_integer :: string -> integer with parse_error
      ( "prim.parse_integer",
        TaskInfo
          { tiParams = [("s", TString, Nothing)],
            tiRet = TInteger,
            tiWith = Just (RENames ["prim.parse_error"]),
            tiExtFrom = Nothing,
            tiAnnot = Nothing,
            tiHomeModule = primModuleName
          }
      ),
      -- parse_number :: string -> number with parse_error
      ( "prim.parse_number",
        TaskInfo
          { tiParams = [("s", TString, Nothing)],
            tiRet = TNumber,
            tiWith = Just (RENames ["prim.parse_error"]),
            tiExtFrom = Nothing,
            tiAnnot = Nothing,
            tiHomeModule = primModuleName
          }
      ),
      -- parse_boolean :: string -> boolean with parse_error
      ( "prim.parse_boolean",
        TaskInfo
          { tiParams = [("s", TString, Nothing)],
            tiRet = TBoolean,
            tiWith = Just (RENames ["prim.parse_error"]),
            tiExtFrom = Nothing,
            tiAnnot = Nothing,
            tiHomeModule = primModuleName
          }
      ),
      -- log.info / log.warn / log.error :: string -> null (純粋)
      ( "prim.log.info",
        TaskInfo
          { tiParams = [("msg", TString, Nothing)],
            tiRet = TNull,
            tiWith = Just (RENames []),
            tiExtFrom = Nothing,
            tiAnnot = Nothing,
            tiHomeModule = primModuleName
          }
      ),
      ( "prim.log.warn",
        TaskInfo
          { tiParams = [("msg", TString, Nothing)],
            tiRet = TNull,
            tiWith = Just (RENames []),
            tiExtFrom = Nothing,
            tiAnnot = Nothing,
            tiHomeModule = primModuleName
          }
      ),
      ( "prim.log.error",
        TaskInfo
          { tiParams = [("msg", TString, Nothing)],
            tiRet = TNull,
            tiWith = Just (RENames []),
            tiExtFrom = Nothing,
            tiAnnot = Nothing,
            tiHomeModule = primModuleName
          }
      )
    ]

-- ---------------------------------------------------------------------------
-- Build global environment (2 passes)
-- ---------------------------------------------------------------------------

-- | Build a 'GlobalEnv' from a list of parsed modules.
--
-- Pass 1: register every declaration under its fully-qualified name
-- (modName <> "." <> localName) and set up the module's own alias table so
-- that declarations defined in the same module are visible by their
-- unqualified name.
--
-- Pass 2: resolve import statements by copying entries from the target
-- module's alias table into the importing module's alias table.
buildGlobalEnv :: [Module] -> Either ModuleError GlobalEnv
buildGlobalEnv modules = do
  -- Seed with prim module entries. The prim module alias table starts empty;
  -- prim.* qualified names are always resolvable because that's their key.
  let env0 =
        emptyEnv
          { geTasks = primTasks,
            geRequests = primRequests,
            geAliases = Map.singleton primModuleName primLocalAliases
          }
  -- Pass 1: register all declarations in all modules.
  env1 <- foldMEither registerModule env0 modules
  -- Pass 2: resolve imports.
  foldMEither resolveImportsModule env1 modules

-- | Local aliases inside the virtual prim module itself. These let
-- `prim.*` qualified names also appear under their short form when a
-- prim-internal file references them. The prim module is not user-authored
-- right now, so these mostly exist for consistency.
primLocalAliases :: Map Text Text
primLocalAliases =
  Map.fromList $
    [(stripPrefix qn, qn) | qn <- Map.keys primTasks]
      ++ [(stripPrefix qn, qn) | qn <- Map.keys primRequests]
  where
    stripPrefix t = fromMaybe t (T.stripPrefix (primModuleName <> ".") t)

foldMEither :: (a -> b -> Either e a) -> a -> [b] -> Either e a
foldMEither f acc xs = case xs of
  [] -> Right acc
  x : rest -> f acc x >>= \acc' -> foldMEither f acc' rest

-- Pass 1: register declarations under qualified names.
registerModule :: GlobalEnv -> Module -> Either ModuleError GlobalEnv
registerModule env (Module _fp mname decls) =
  foldMEither (registerDecl mname) env decls

registerDecl :: Text -> GlobalEnv -> Decl -> Either ModuleError GlobalEnv
registerDecl mname env decl = case decl of
  DeclTask _ td -> do
    let local = taskName td
        qname = qualify mname local
    checkUniqueName env qname
    Right $
      addAlias mname local qname $
        env {geTasks = Map.insert qname (taskInfo mname td) (geTasks env)}
  DeclRequest _ rd -> do
    let local = reqName rd
        qname = qualify mname local
    checkUniqueName env qname
    Right $
      addAlias mname local qname $
        env {geRequests = Map.insert qname (requestInfo mname rd) (geRequests env)}
  DeclVal _ vd -> do
    let local = valName vd
        qname = qualify mname local
    checkUniqueName env qname
    let nt = normalize (valType vd) (geTypeEnv env)
    Right $
      addAlias mname local qname $
        env {geVals = Map.insert qname (ValInfo nt mname) (geVals env)}
  DeclType _ td -> do
    let local = tyaName td
        qname = qualify mname local
    let envWithType =
          env {geTypes = Map.insert qname (TypeInfo (tyaType td)) (geTypes env)}
    resolved <- resolveTypeAlias qname (tyaType td) envWithType [qname]
    Right $
      addAlias mname local qname $
        envWithType
          { geTypeEnv = Map.insert qname resolved (geTypeEnv envWithType)
          }
  DeclImport _ _ -> Right env -- handled in pass 2
  DeclExtTask _ etd -> do
    let local = extTaskName etd
        qname = qualify mname local
    checkUniqueName env qname
    Right $
      addAlias mname local qname $
        env {geTasks = Map.insert qname (extTaskInfo mname etd) (geTasks env)}
  DeclExtReq _ erd -> do
    let local = extReqName erd
        qname = qualify mname local
    checkUniqueName env qname
    Right $
      addAlias mname local qname $
        env {geRequests = Map.insert qname (extRequestInfo mname erd) (geRequests env)}

qualify :: Text -> Text -> Text
qualify mname local = mname <> "." <> local

-- | Insert a single alias (local name → qualified name) into a module's
-- alias table.
addAlias :: Text -> Text -> Text -> GlobalEnv -> GlobalEnv
addAlias mname local qname env =
  let tbl = fromMaybe Map.empty (Map.lookup mname (geAliases env))
      tbl' = Map.insert local qname tbl
   in env {geAliases = Map.insert mname tbl' (geAliases env)}

-- Pass 2: resolve imports.
resolveImportsModule :: GlobalEnv -> Module -> Either ModuleError GlobalEnv
resolveImportsModule env (Module _fp mname decls) =
  foldMEither (resolveImportDecl mname) env [i | DeclImport _ i <- decls]

resolveImportDecl ::
  Text ->
  GlobalEnv ->
  ImportDecl ->
  Either ModuleError GlobalEnv
resolveImportDecl mname env imp = do
  let targetMod = T.intercalate "." (impPath imp)
  -- The target module must have been registered (either by registerModule
  -- or by being the built-in prim module).
  targetAliases <- case Map.lookup targetMod (geAliases env) of
    Just aliases -> Right aliases
    Nothing -> Left (UnknownImport targetMod)
  -- Select which names to bring in.
  selected <- case impNames imp of
    Nothing -> Right (Map.toList targetAliases)
    Just ns ->
      mapM
        ( \n -> case Map.lookup n targetAliases of
            Just q -> Right (n, q)
            Nothing -> Left (UnknownImportName targetMod n)
        )
        ns
  -- Apply alias prefix if present.
  let prefixed = case impAlias imp of
        Nothing -> selected
        Just a -> [(a <> "." <> n, q) | (n, q) <- selected]
  -- Merge into the importing module's alias table.
  Right $
    foldr
      (\(local, qname) e -> addAlias mname local qname e)
      env
      prefixed

checkUniqueName :: GlobalEnv -> Text -> Either ModuleError ()
checkUniqueName env name
  | Map.member name (geTasks env) = Left (DuplicateName name)
  | Map.member name (geRequests env) = Left (DuplicateName name)
  | Map.member name (geVals env) = Left (DuplicateName name)
  | Map.member name (geTypes env) = Left (DuplicateName name)
  | otherwise = Right ()

-- Resolve a type alias (detect cycles)
resolveTypeAlias ::
  Text ->
  Type ->
  GlobalEnv ->
  [Text] ->
  Either ModuleError NormalizedType
resolveTypeAlias _rootName ty env visited = resolveType ty
  where
    resolveType t = case t of
      TNull -> Right ntNull
      TBoolean -> Right ntBool
      TInteger -> Right ntInteger
      TNumber -> Right ntNumber
      TString -> Right ntString
      TNever -> Right ntNever
      TUnknown -> Right NTUnknown
      TLitBool b -> Right (normalize (TLitBool b) Map.empty)
      TLitInt i -> Right (normalize (TLitInt i) Map.empty)
      TLitNum n -> Right (normalize (TLitNum n) Map.empty)
      TLitStr s -> Right (normalize (TLitStr s) Map.empty)
      TArray inner -> do
        nt <- resolveType inner
        return (NTFields emptyFields {nfArray = Just nt})
      TUnion ts -> do
        nts <- mapM resolveType ts
        return (foldr unionNT ntNever nts)
      TInter ts -> do
        nts <- mapM resolveType ts
        return (foldr intersectNT NTUnknown nts)
      TAlias name
        | name `elem` visited -> Left (RecursiveTypeAlias visited)
        | otherwise -> case Map.lookup name (geTypeEnv env) of
            Just nt -> Right nt
            Nothing -> case Map.lookup name (geTypes env) of
              Just (TypeInfo ty') ->
                resolveTypeAlias name ty' env (name : visited)
              Nothing -> Right ntNever -- unknown alias
      TObj flds -> do
        resolved <- mapM (resolveType . ofType) flds
        let ofields =
              Map.fromList
                [ ( ofName f,
                    FieldInfo
                      { fiType = nt,
                        fiOptional = ofOptional f,
                        fiAnnot = ofAnnot f
                      }
                  )
                  | (f, nt) <- zip flds resolved
                ]
            neverPropagated =
              any
                (\fi -> not (fiOptional fi) && isNeverNT (fiType fi))
                (Map.elems ofields)
        if neverPropagated
          then return ntNever
          else case tryMakeDISC flds ofields (geTypeEnv env) of
            Just disc -> return (NTDISC disc)
            Nothing ->
              return (NTFields emptyFields {nfObject = Just (ObjectFields ofields)})

emptyFields :: NormalFields
emptyFields = NormalFields False Nothing Nothing Nothing Nothing Nothing

-- ---------------------------------------------------------------------------
-- Info extractors
-- ---------------------------------------------------------------------------

taskInfo :: Text -> TaskDecl -> TaskInfo
taskInfo mname td =
  TaskInfo
    { tiParams = taskParams td,
      tiRet = fromMaybe TNull (taskRet td),
      tiWith = taskWith td,
      tiExtFrom = Nothing,
      tiAnnot = taskAnnot td,
      tiHomeModule = mname
    }

requestInfo :: Text -> RequestDecl -> RequestInfo
requestInfo mname rd =
  RequestInfo
    { riParams = reqParams rd,
      riRet = reqRet rd,
      riExtFrom = Nothing,
      riAnnot = reqAnnot rd,
      riHomeModule = mname
    }

extTaskInfo :: Text -> ExternalTaskDecl -> TaskInfo
extTaskInfo mname etd =
  TaskInfo
    { tiParams = extTaskParams etd,
      tiRet = fromMaybe TNull (extTaskRet etd),
      tiWith = extTaskWith etd,
      tiExtFrom = Just (extTaskFrom etd),
      tiAnnot = extTaskAnnot etd,
      tiHomeModule = mname
    }

extRequestInfo :: Text -> ExternalReqDecl -> RequestInfo
extRequestInfo mname erd =
  RequestInfo
    { riParams = extReqParams erd,
      riRet = extReqRet erd,
      riExtFrom = Just (extReqFrom erd),
      riAnnot = extReqAnnot erd,
      riHomeModule = mname
    }
