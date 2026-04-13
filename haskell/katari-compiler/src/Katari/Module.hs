module Katari.Module
  ( GlobalEnv (..),
    AgentInfo (..),
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

import Control.Monad (forM_, unless)
import Data.List (partition)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Katari.Syntax
  ( AgentDecl (..),
    Decl (..),
    ExternalAgentDecl (..),
    ExternalReqDecl (..),
    ImportDecl (..),
    Module (..),
    ObjField (..),
    RequestDecl (..),
    RequestEffect (..),
    Type (..),
    TypeAliasDecl (..),
    ValDecl (..),
  )
import Katari.Types
  ( NormalizedType,
    normalize,
    ntNever,
  )

-- ---------------------------------------------------------------------------
-- Global environment
-- ---------------------------------------------------------------------------

data AgentInfo = AgentInfo
  { aiParams :: [(Text, Type, Maybe Text)], -- (name, type, annotation)
    aiRet :: Type,
    aiWith :: Maybe RequestEffect,
    aiExtFrom :: Maybe Text, -- for external agents
    aiAnnot :: Maybe Text, -- @"..." description for schema
    aiHomeModule :: Text -- defining module (for TAlias resolution in Type)
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

data TypeInfo = TypeInfo
  { tyAlias :: Type,
    tyHomeModule :: Text
  }
  deriving (Show)

-- | All keys in the maps below are **qualified names** (e.g. "prim.div",
--   "lib.cron.schedule"). Local (unqualified) names are resolved per-module
--   via 'geAliases', which maps each module name to a map from locally-visible
--   names (those brought into scope by declarations or import statements) to
--   their fully-qualified names.
data GlobalEnv = GlobalEnv
  { geAgents :: Map Text AgentInfo,
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
    { geAgents = Map.empty,
      geRequests = Map.empty,
      geVals = Map.empty,
      geTypes = Map.empty,
      geTypeEnv = Map.empty,
      geAliases = Map.empty
    }

-- | Virtual module name under which primitive agents/requests live.
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

-- prim built-in agents. すべて qualified name (prim.<name>) で登録する。
-- 短縮名エイリアスは一切提供しない。ユーザコードは `import prim { ... }`
-- や `import prim.log { ... }` を明示的に書くことで参照する。
primAgents :: Map Text AgentInfo
primAgents =
  Map.fromList
    [ -- to_string :: integer | number | boolean | string | null -> string (純粋)
      ( "prim.to_string",
        AgentInfo
          { aiParams = [("v", TUnion [TInteger, TNumber, TBoolean, TString, TNull], Nothing)],
            aiRet = TString,
            aiWith = Just (RENames []),
            aiExtFrom = Nothing,
            aiAnnot = Nothing,
            aiHomeModule = primModuleName
          }
      ),
      -- div :: (integer | number, integer | number) -> integer (floor division)
      ( "prim.div",
        AgentInfo
          { aiParams =
              [ ("a", TUnion [TInteger, TNumber], Nothing),
                ("b", TUnion [TInteger, TNumber], Nothing)
              ],
            aiRet = TInteger,
            aiWith = Just (RENames []),
            aiExtFrom = Nothing,
            aiAnnot = Nothing,
            aiHomeModule = primModuleName
          }
      ),
      -- mod :: (integer | number, integer | number) -> number
      ( "prim.mod",
        AgentInfo
          { aiParams =
              [ ("a", TUnion [TInteger, TNumber], Nothing),
                ("b", TUnion [TInteger, TNumber], Nothing)
              ],
            aiRet = TNumber,
            aiWith = Just (RENames []),
            aiExtFrom = Nothing,
            aiAnnot = Nothing,
            aiHomeModule = primModuleName
          }
      ),
      -- parse_integer :: string -> integer with parse_error
      ( "prim.parse_integer",
        AgentInfo
          { aiParams = [("s", TString, Nothing)],
            aiRet = TInteger,
            aiWith = Just (RENames ["prim.parse_error"]),
            aiExtFrom = Nothing,
            aiAnnot = Nothing,
            aiHomeModule = primModuleName
          }
      ),
      -- parse_number :: string -> number with parse_error
      ( "prim.parse_number",
        AgentInfo
          { aiParams = [("s", TString, Nothing)],
            aiRet = TNumber,
            aiWith = Just (RENames ["prim.parse_error"]),
            aiExtFrom = Nothing,
            aiAnnot = Nothing,
            aiHomeModule = primModuleName
          }
      ),
      -- parse_boolean :: string -> boolean with parse_error
      ( "prim.parse_boolean",
        AgentInfo
          { aiParams = [("s", TString, Nothing)],
            aiRet = TBoolean,
            aiWith = Just (RENames ["prim.parse_error"]),
            aiExtFrom = Nothing,
            aiAnnot = Nothing,
            aiHomeModule = primModuleName
          }
      ),
      -- log.info / log.warn / log.error :: string -> null (純粋)
      ( "prim.log.info",
        AgentInfo
          { aiParams = [("msg", TString, Nothing)],
            aiRet = TNull,
            aiWith = Just (RENames []),
            aiExtFrom = Nothing,
            aiAnnot = Nothing,
            aiHomeModule = primModuleName
          }
      ),
      ( "prim.log.warn",
        AgentInfo
          { aiParams = [("msg", TString, Nothing)],
            aiRet = TNull,
            aiWith = Just (RENames []),
            aiExtFrom = Nothing,
            aiAnnot = Nothing,
            aiHomeModule = primModuleName
          }
      ),
      ( "prim.log.error",
        AgentInfo
          { aiParams = [("msg", TString, Nothing)],
            aiRet = TNull,
            aiWith = Just (RENames []),
            aiExtFrom = Nothing,
            aiAnnot = Nothing,
            aiHomeModule = primModuleName
          }
      ),
      -- length :: array[unknown] -> integer
      ( "prim.length",
        AgentInfo
          { aiParams = [("arr", TArray TUnknown, Nothing)],
            aiRet = TInteger,
            aiWith = Just (RENames []),
            aiExtFrom = Nothing,
            aiAnnot = Nothing,
            aiHomeModule = primModuleName
          }
      ),
      -- slice :: (array[unknown], integer, integer) -> array[unknown]
      ( "prim.slice",
        AgentInfo
          { aiParams =
              [ ("arr", TArray TUnknown, Nothing),
                ("from", TInteger, Nothing),
                ("to", TInteger, Nothing)
              ],
            aiRet = TArray TUnknown,
            aiWith = Just (RENames []),
            aiExtFrom = Nothing,
            aiAnnot = Nothing,
            aiHomeModule = primModuleName
          }
      ),
      -- ref_agent :: string -> { url, agent_def_id, name, description, arg_type }
      ( "prim.ref_agent",
        AgentInfo
          { aiParams = [("name", TString, Nothing)],
            aiRet =
              TObj
                [ ObjField "url" False False TString Nothing,
                  ObjField "agent_def_id" False False TString Nothing,
                  ObjField "name" False False TString Nothing,
                  ObjField "description" False False TString Nothing,
                  ObjField "arg_type" False False TUnknown Nothing
                ],
            aiWith = Just (RENames []),
            aiExtFrom = Nothing,
            aiAnnot = Just "外部エージェントの参照情報を返す",
            aiHomeModule = primModuleName
          }
      )
    ]

-- ---------------------------------------------------------------------------
-- Build global environment (4 steps)
-- ---------------------------------------------------------------------------

-- | Build a 'GlobalEnv' from a list of parsed modules.
--
-- Step 1: Register all declarations under qualified names + set up
--         per-module alias tables. Val types are left as placeholders;
--         type aliases are stored raw (not yet resolved).
-- Step 2: Resolve import statements (copy aliases across modules).
-- Step 3: Resolve all type aliases in dependency order → 'geTypeEnv'.
-- Step 4: Normalize val types using the now-complete 'geTypeEnv'.
buildGlobalEnv :: [Module] -> Either ModuleError GlobalEnv
buildGlobalEnv modules = do
  let env0 =
        emptyEnv
          { geAgents = primAgents,
            geRequests = primRequests,
            geAliases = Map.singleton primModuleName primLocalAliases
          }
  env1 <- foldMEither registerModuleDecls env0 modules
  env2 <- foldMEither resolveImportsModule env1 modules
  env3 <- resolveAllTypes env2
  normalizeAllVals env3 modules

primLocalAliases :: Map Text Text
primLocalAliases =
  Map.fromList $
    [(stripPrefix qn, qn) | qn <- Map.keys primAgents]
      ++ [(stripPrefix qn, qn) | qn <- Map.keys primRequests]
  where
    stripPrefix t = fromMaybe t (T.stripPrefix (primModuleName <> ".") t)

foldMEither :: (a -> b -> Either e a) -> a -> [b] -> Either e a
foldMEither f acc = \case
  [] -> Right acc
  x : rest -> f acc x >>= \acc' -> foldMEither f acc' rest

-- ---------------------------------------------------------------------------
-- Step 1: Register declarations (no type resolution, no val normalization)
-- ---------------------------------------------------------------------------

registerModuleDecls :: GlobalEnv -> Module -> Either ModuleError GlobalEnv
registerModuleDecls env (Module _fp mname decls) =
  foldMEither (registerDecl mname) env decls

registerDecl :: Text -> GlobalEnv -> Decl -> Either ModuleError GlobalEnv
registerDecl mname env = \case
  DeclAgent _ td -> do
    let local = agentName td
        qname = qualify mname local
    checkUniqueName env qname
    Right $
      addAlias mname local qname $
        env {geAgents = Map.insert qname (agentInfo mname td) (geAgents env)}
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
    -- Placeholder; will be normalized in Step 4
    Right $
      addAlias mname local qname $
        env {geVals = Map.insert qname (ValInfo ntNever mname) (geVals env)}
  DeclType _ td -> do
    let local = tyaName td
        qname = qualify mname local
    checkUniqueName env qname
    Right $
      addAlias mname local qname $
        env {geTypes = Map.insert qname (TypeInfo (tyaType td) mname) (geTypes env)}
  DeclImport _ _ -> Right env
  DeclExtAgent _ etd -> do
    let local = extAgentName etd
        qname = qualify mname local
    checkUniqueName env qname
    Right $
      addAlias mname local qname $
        env {geAgents = Map.insert qname (extAgentInfo mname etd) (geAgents env)}
  DeclExtReq _ erd -> do
    let local = extReqName erd
        qname = qualify mname local
    checkUniqueName env qname
    Right $
      addAlias mname local qname $
        env {geRequests = Map.insert qname (extRequestInfo mname erd) (geRequests env)}

qualify :: Text -> Text -> Text
qualify mname local = mname <> "." <> local

addAlias :: Text -> Text -> Text -> GlobalEnv -> GlobalEnv
addAlias mname local qname env =
  let tbl = fromMaybe Map.empty (Map.lookup mname (geAliases env))
      tbl' = Map.insert local qname tbl
   in env {geAliases = Map.insert mname tbl' (geAliases env)}

-- ---------------------------------------------------------------------------
-- Step 2: Resolve imports
-- ---------------------------------------------------------------------------

resolveImportsModule :: GlobalEnv -> Module -> Either ModuleError GlobalEnv
resolveImportsModule env (Module _fp mname decls) = do
  -- prim を暗黙インポート（prim モジュール自身は除く）
  let env' =
        if mname == primModuleName
          then env
          else
            let primAls = fromMaybe Map.empty (Map.lookup primModuleName (geAliases env))
             in foldr (\(local, qname) e -> addAlias mname local qname e) env (Map.toList primAls)
  foldMEither (resolveImportDecl mname) env' [i | DeclImport _ i <- decls]

resolveImportDecl :: Text -> GlobalEnv -> ImportDecl -> Either ModuleError GlobalEnv
resolveImportDecl mname env imp = do
  let targetMod = T.intercalate "." (impPath imp)
  targetAliases <- case Map.lookup targetMod (geAliases env) of
    Just aliases -> Right aliases
    Nothing -> Left (UnknownImport targetMod)
  selected <- case impNames imp of
    Nothing -> Right (Map.toList targetAliases)
    Just ns ->
      mapM
        ( \n -> case Map.lookup n targetAliases of
            Just q -> Right (n, q)
            Nothing -> Left (UnknownImportName targetMod n)
        )
        ns
  let prefixed = case impAlias imp of
        Nothing -> selected
        Just a -> [(a <> "." <> n, q) | (n, q) <- selected]
  Right $
    foldr
      (\(local, qname) e -> addAlias mname local qname e)
      env
      prefixed

-- ---------------------------------------------------------------------------
-- Step 3: Resolve all type aliases → geTypeEnv
-- ---------------------------------------------------------------------------

-- | Resolve every type alias in dependency order. Detects cycles and
-- unknown alias references.
resolveAllTypes :: GlobalEnv -> Either ModuleError GlobalEnv
resolveAllTypes env = do
  -- Check for unknown alias references
  forM_ (Map.toList (geTypes env)) $ \(_qname, TypeInfo ty mname) -> do
    let modAliases = aliasesFor env mname
    forM_ (typeAliasRefs ty) $ \ref -> do
      let qualified = qualifyName modAliases ref
      unless (Map.member qualified (geTypes env)) $
        Left (UnknownTypeAlias ref)
  -- Iterative resolution in dependency order
  go (Map.toList (geTypes env)) env Set.empty
  where
    go [] e _ = Right e
    go remaining e resolved =
      let (ready, notReady) = partition (depsResolved e resolved) remaining
       in if null ready
            then Left (RecursiveTypeAlias (map fst notReady))
            else do
              e' <- foldMEither resolveOne e ready
              go notReady e' (resolved <> Set.fromList (map fst ready))

    depsResolved e resolved (_, TypeInfo ty mname) =
      let modAliases = aliasesFor e mname
          deps = [qualifyName modAliases n | n <- typeAliasRefs ty]
       in all (`Set.member` resolved) deps

    resolveOne e (qname, TypeInfo ty mname) =
      let modAliases = aliasesFor e mname
          qualifiedTy = qualifyTypeWith modAliases ty
          nt = normalize qualifiedTy (geTypeEnv e)
       in Right $ e {geTypeEnv = Map.insert qname nt (geTypeEnv e)}

-- | Collect all TAlias references from a Type.
typeAliasRefs :: Type -> [Text]
typeAliasRefs = \case
  TAlias name -> [name]
  TArray t -> typeAliasRefs t
  TUnion ts -> concatMap typeAliasRefs ts
  TInter ts -> concatMap typeAliasRefs ts
  TObj fs -> concatMap (typeAliasRefs . ofType) fs
  _ -> []

-- | Qualify all TAlias names in a Type using a module's alias table.
qualifyTypeWith :: Map Text Text -> Type -> Type
qualifyTypeWith aliases = go
  where
    go = \case
      TAlias n -> TAlias (qualifyName aliases n)
      TArray t -> TArray (go t)
      TUnion ts -> TUnion (map go ts)
      TInter ts -> TInter (map go ts)
      TObj fs -> TObj [f {ofType = go (ofType f)} | f <- fs]
      t -> t

qualifyName :: Map Text Text -> Text -> Text
qualifyName aliases name = fromMaybe name (Map.lookup name aliases)

-- ---------------------------------------------------------------------------
-- Step 4: Normalize val types with complete geTypeEnv
-- ---------------------------------------------------------------------------

normalizeAllVals :: GlobalEnv -> [Module] -> Either ModuleError GlobalEnv
normalizeAllVals = foldMEither normalizeModuleVals

normalizeModuleVals :: GlobalEnv -> Module -> Either ModuleError GlobalEnv
normalizeModuleVals env (Module _fp mname decls) =
  foldMEither (normalizeValDecl mname) env decls

normalizeValDecl :: Text -> GlobalEnv -> Decl -> Either ModuleError GlobalEnv
normalizeValDecl mname env = \case
  DeclVal _ vd ->
    let qname = qualify mname (valName vd)
        modAliases = aliasesFor env mname
        qualifiedTy = qualifyTypeWith modAliases (valType vd)
        nt = normalize qualifiedTy (geTypeEnv env)
     in Right $ env {geVals = Map.insert qname (ValInfo nt mname) (geVals env)}
  _ -> Right env

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

checkUniqueName :: GlobalEnv -> Text -> Either ModuleError ()
checkUniqueName env name
  | Map.member name (geAgents env) = Left (DuplicateName name)
  | Map.member name (geRequests env) = Left (DuplicateName name)
  | Map.member name (geVals env) = Left (DuplicateName name)
  | Map.member name (geTypes env) = Left (DuplicateName name)
  | otherwise = Right ()

-- ---------------------------------------------------------------------------
-- Info extractors
-- ---------------------------------------------------------------------------

agentInfo :: Text -> AgentDecl -> AgentInfo
agentInfo mname td =
  AgentInfo
    { aiParams = agentParams td,
      aiRet = fromMaybe TNull (agentRet td),
      aiWith = agentWith td,
      aiExtFrom = Nothing,
      aiAnnot = agentAnnot td,
      aiHomeModule = mname
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

extAgentInfo :: Text -> ExternalAgentDecl -> AgentInfo
extAgentInfo mname etd =
  AgentInfo
    { aiParams = extAgentParams etd,
      aiRet = fromMaybe TNull (extAgentRet etd),
      aiWith = extAgentWith etd,
      aiExtFrom = Just (extAgentFrom etd),
      aiAnnot = extAgentAnnot etd,
      aiHomeModule = mname
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
