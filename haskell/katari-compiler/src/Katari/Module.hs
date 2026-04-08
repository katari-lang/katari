module Katari.Module
  ( GlobalEnv (..)
  , TaskInfo (..)
  , RequestInfo (..)
  , ValInfo (..)
  , TypeInfo (..)
  , ModuleError (..)
  , buildGlobalEnv
  , primRequests
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)

import Katari.Syntax
import Katari.Types

-- ---------------------------------------------------------------------------
-- Global environment
-- ---------------------------------------------------------------------------

data TaskInfo = TaskInfo
  { tiParams  :: [(Text, Type)]
  , tiRet     :: Type
  , tiWith    :: Maybe RequestEffect
  , tiExtFrom :: Maybe Text   -- for external tasks
  } deriving (Show)

data RequestInfo = RequestInfo
  { riParams  :: [(Text, Type)]
  , riRet     :: Type
  , riExtFrom :: Maybe Text   -- for external requests
  } deriving (Show)

data ValInfo = ValInfo
  { viType :: NormalizedType
  } deriving (Show)

data TypeInfo = TypeInfo
  { tyAlias :: Type
  } deriving (Show)

data GlobalEnv = GlobalEnv
  { geTasks    :: Map Text TaskInfo
  , geRequests :: Map Text RequestInfo
  , geVals     :: Map Text ValInfo
  , geTypes    :: Map Text TypeInfo
  , geTypeEnv  :: Map Text NormalizedType  -- resolved type aliases
  } deriving (Show)

emptyEnv :: GlobalEnv
emptyEnv = GlobalEnv
  { geTasks    = Map.empty
  , geRequests = Map.empty
  , geVals     = Map.empty
  , geTypes    = Map.empty
  , geTypeEnv  = Map.empty
  }

-- ---------------------------------------------------------------------------
-- Error
-- ---------------------------------------------------------------------------

data ModuleError
  = DuplicateName  Text
  | UnknownTypeAlias Text
  | RecursiveTypeAlias [Text]
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Primitive definitions
-- ---------------------------------------------------------------------------

-- prim module built-ins: throw is defined here
primRequests :: Map Text RequestInfo
primRequests = Map.fromList
  [ ("throw", RequestInfo
      { riParams = [("message", TString)]
      , riRet    = TNever
      , riExtFrom = Nothing
      })
  ]

primTasks :: Map Text TaskInfo
primTasks = Map.fromList
  [ ("to_string", TaskInfo [("v", TUnknown)] TString Nothing Nothing)
  , ("prim.log.info",  TaskInfo [("msg", TString)] TNull Nothing Nothing)
  , ("prim.log.warn",  TaskInfo [("msg", TString)] TNull Nothing Nothing)
  , ("prim.log.error", TaskInfo [("msg", TString)] TNull Nothing Nothing)
  -- div :: integer -> integer -> integer (floor division)
  , ("prim.div", TaskInfo [("a", TInteger), ("b", TInteger)] TInteger Nothing Nothing)
  -- mod :: number -> number -> number
  , ("prim.mod", TaskInfo [("a", TNumber), ("b", TNumber)] TNumber Nothing Nothing)
  -- parse_integer :: string -> integer | null
  , ("prim.parse_integer", TaskInfo [("s", TString)] (TUnion [TInteger, TNull]) Nothing Nothing)
  -- parse_number :: string -> number | null
  , ("prim.parse_number", TaskInfo [("s", TString)] (TUnion [TNumber, TNull]) Nothing Nothing)
  ]

-- ---------------------------------------------------------------------------
-- Build global environment
-- ---------------------------------------------------------------------------

buildGlobalEnv :: [Module] -> Either ModuleError GlobalEnv
buildGlobalEnv modules = do
  let env0 = emptyEnv
        { geTasks    = primTasks
        , geRequests = primRequests
        }
  -- Collect all declarations
  foldM addModule env0 modules

foldM :: Monad m => (a -> b -> m a) -> a -> [b] -> m a
foldM _ acc []     = return acc
foldM f acc (x:xs) = f acc x >>= \acc' -> foldM f acc' xs

addModule :: GlobalEnv -> Module -> Either ModuleError GlobalEnv
addModule env (Module _fp decls) = foldM addDecl env decls

addDecl :: GlobalEnv -> Decl -> Either ModuleError GlobalEnv
addDecl env (DeclTask _ td) = do
  checkUniqueName env (taskName td)
  return env { geTasks = Map.insert (taskName td) (taskInfo td) (geTasks env) }

addDecl env (DeclRequest _ rd) = do
  checkUniqueName env (reqName rd)
  return env { geRequests = Map.insert (reqName rd) (requestInfo rd) (geRequests env) }

addDecl env (DeclVal _ vd) = do
  checkUniqueName env (valName vd)
  let nt = normalize (valType vd) (geTypeEnv env)
  return env { geVals = Map.insert (valName vd) (ValInfo nt) (geVals env) }

addDecl env (DeclType _ td) = do
  let name = tyaName td
  -- Add type alias (resolve later)
  let newEnv = env { geTypes = Map.insert name (TypeInfo (tyaType td)) (geTypes env) }
  -- Resolve the type
  resolved <- resolveTypeAlias name (tyaType td) newEnv [name]
  return newEnv { geTypeEnv = Map.insert name resolved (geTypeEnv newEnv) }

addDecl env (DeclImport _ _) = return env  -- imports handled at module load time

addDecl env (DeclExtTask _ etd) = do
  checkUniqueName env (extTaskName etd)
  return env { geTasks = Map.insert (extTaskName etd) (extTaskInfo etd) (geTasks env) }

addDecl env (DeclExtReq _ erd) = do
  checkUniqueName env (extReqName erd)
  return env { geRequests = Map.insert (extReqName erd) (extRequestInfo erd) (geRequests env) }

checkUniqueName :: GlobalEnv -> Text -> Either ModuleError ()
checkUniqueName env name
  | Map.member name (geTasks env)    = Left (DuplicateName name)
  | Map.member name (geRequests env) = Left (DuplicateName name)
  | Map.member name (geVals env)     = Left (DuplicateName name)
  | Map.member name (geTypes env)    = Left (DuplicateName name)
  | otherwise                        = Right ()

-- Resolve a type alias (detect cycles)
resolveTypeAlias :: Text -> Type -> GlobalEnv -> [Text]
                 -> Either ModuleError NormalizedType
resolveTypeAlias rootName ty env visited =
  resolveType ty
  where
    resolveType TNull       = Right ntNull
    resolveType TBoolean    = Right ntBool
    resolveType TInteger    = Right ntInteger
    resolveType TNumber     = Right ntNumber
    resolveType TString     = Right ntString
    resolveType TNever      = Right ntNever
    resolveType TUnknown    = Right NTUnknown
    resolveType (TLitBool b) = Right (normalize (TLitBool b) Map.empty)
    resolveType (TLitInt  i) = Right (normalize (TLitInt  i) Map.empty)
    resolveType (TLitNum  n) = Right (normalize (TLitNum  n) Map.empty)
    resolveType (TLitStr  s) = Right (normalize (TLitStr  s) Map.empty)
    resolveType (TArray   t) = do
      nt <- resolveType t
      return (NTFields emptyFields { nfArray = Just nt })
    resolveType (TUnion ts) = do
      nts <- mapM resolveType ts
      return (foldr unionNT ntNever nts)
    resolveType (TInter ts) = do
      nts <- mapM resolveType ts
      return (foldr intersectNT NTUnknown nts)
    resolveType (TAlias name) =
      if name `elem` visited
      then Left (RecursiveTypeAlias visited)
      else case Map.lookup name (geTypeEnv env) of
             Just nt -> Right nt
             Nothing -> case Map.lookup name (geTypes env) of
               Just (TypeInfo ty') ->
                 resolveTypeAlias name ty' env (name:visited)
               Nothing -> Right ntNever  -- unknown alias
    resolveType (TObj flds) = do
      resolved <- mapM resolveField flds
      let ofields = Map.fromList
            [ (ofName f, FieldInfo { fiType = nt, fiOptional = ofOptional f })
            | (f, nt) <- zip flds resolved ]
          neverPropagated = any (\fi -> not (fiOptional fi) && isNeverNT (fiType fi))
                                (Map.elems ofields)
      if neverPropagated
        then return ntNever
        else return (NTFields emptyFields { nfObject = Just (ObjectFields ofields) })
    resolveField f = resolveType (ofType f)

emptyFields :: NormalFields
emptyFields = NormalFields False Nothing Nothing Nothing Nothing Nothing

-- ---------------------------------------------------------------------------
-- Info extractors
-- ---------------------------------------------------------------------------

taskInfo :: TaskDecl -> TaskInfo
taskInfo td = TaskInfo
  { tiParams  = taskParams td
  , tiRet     = fromMaybe TNull (taskRet td)
  , tiWith    = taskWith td
  , tiExtFrom = Nothing
  }

requestInfo :: RequestDecl -> RequestInfo
requestInfo rd = RequestInfo
  { riParams  = reqParams rd
  , riRet     = reqRet rd
  , riExtFrom = Nothing
  }

extTaskInfo :: ExternalTaskDecl -> TaskInfo
extTaskInfo etd = TaskInfo
  { tiParams  = extTaskParams etd
  , tiRet     = fromMaybe TNull (extTaskRet etd)
  , tiWith    = extTaskWith etd
  , tiExtFrom = Just (extTaskFrom etd)
  }

extRequestInfo :: ExternalReqDecl -> RequestInfo
extRequestInfo erd = RequestInfo
  { riParams  = extReqParams erd
  , riRet     = extReqRet erd
  , riExtFrom = Just (extReqFrom erd)
  }
