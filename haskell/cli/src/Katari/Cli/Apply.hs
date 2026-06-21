-- | @katari apply@ — resolve, compile, and deploy the project to the runtime as a new snapshot.
--
-- The flow follows the per-module deploy protocol (@docs\/2026-06-19-per-module-snapshot.md@ §3):
--
--   1. Resolve the dependency closure over the network and (re)write @katari.lock@.
--   2. Compile the assembled sources to one 'IRModule' per module.
--   3. Hash each module and read the runtime's current snapshot head to diff against.
--   4. Send the /complete/ desired manifest: every module's hash, inlining the IR only for the ones
--      the runtime does not already hold. Modules absent from the manifest are dropped from head.
module Katari.Cli.Apply
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Monad (when)
import Data.Aeson (toJSON)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Katari.Cli.Api
  ( ModuleUpload (..),
    ProjectRow (..),
    RuntimeClient,
    createProject,
    deploySnapshot,
    listHeadModules,
    listProjects,
    newRuntimeClient,
    runtimeAuthFromEnvironment,
  )
import Katari.Cli.Common (assembleSourcesOrExit, compileSourcesOrExit, dieIn, resolveProjectRoot, writeOrExit)
import Katari.Data.IR (IRModule)
import Katari.Data.ModuleName (ModuleName (..), renderModuleName)
import Katari.Project.Config (PackageSection (..), ProjectConfig (..), RuntimeSection (..))
import Katari.Project.Error (renderProjectError)
import Katari.Project.Lockfile (lockfileFilename, writeLockfile)
import Katari.Project.Resolve (ResolvedPackage (..), ResolvedProject (..), lockfileFromResolved, resolveProject)
import Katari.Project.Upload (ModuleHash (..), UploadPlan (..), hashModule, planUpload)
import Network.HTTP.Client.TLS (newTlsManager)
import Options.Applicative
import System.Environment (lookupEnv)
import System.FilePath ((</>))

data Options = Options
  { projectRoot :: Maybe FilePath,
    projectName :: Maybe Text,
    message :: Maybe Text,
    runtimeUrl :: Maybe Text
  }
  deriving stock (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> optional
      ( strOption
          ( long "project"
              <> short 'p'
              <> metavar "DIR"
              <> help "Project root (the directory containing katari.toml). Defaults to walking up from the current directory."
          )
      )
    <*> optional
      ( strOption
          ( long "name"
              <> metavar "NAME"
              <> help "Override the project name registered with the runtime (default: [package].name)"
          )
      )
    <*> optional
      ( strOption
          ( long "message"
              <> short 'm'
              <> metavar "TEXT"
              <> help "Label for this snapshot (default: \"katari apply\")"
          )
      )
    <*> optional
      ( strOption
          ( long "url"
              <> metavar "URL"
              <> help "Runtime URL. Overrides KATARI_API_URL and [runtime].url from katari.toml."
          )
      )

run :: Options -> IO ()
run options = do
  root <- resolveProjectRoot "apply" options.projectRoot

  -- 1. Resolve the closure over the network and persist the lockfile.
  manager <- newTlsManager
  resolved <-
    resolveProject manager root >>= \case
      Left projectError -> dieIn "apply" (renderProjectError projectError)
      Right resolved -> pure resolved
  writeOrExit "apply" "could not write lockfile" $
    writeLockfile (root </> lockfileFilename) (lockfileFromResolved resolved)

  -- 2. Compile.
  sources <- assembleSourcesOrExit "apply" resolved
  loweredModules <- compileSourcesOrExit sources
  when (Map.null loweredModules) $ dieIn "apply" "the project produced no modules to deploy"

  -- 3. Connect to the runtime and diff the build against its current head.
  let config = resolved.rootPackage.config :: ProjectConfig
  url <- resolveRuntimeUrl options.runtimeUrl config.runtime.url
  token <- runtimeAuthFromEnvironment
  -- Reuse the resolution manager so a single apply opens one TLS connection pool, not two.
  let client = newRuntimeClient manager url token
  let name = fromMaybe config.package.name options.projectName
  projects <- listProjects client
  projectId <- case filter (\project -> project.name == name) projects of
    (existing : _) -> pure existing.id
    [] -> do
      TextIO.putStrLn ("Creating project " <> name)
      created <- createProject client name config.package.description
      pure created.id
  runtimeHashes <- runtimeModuleHashes client projectId
  let plan = planUpload loweredModules runtimeHashes
  reportPlan url name plan

  -- 4. Send the complete desired manifest.
  let manifest = buildManifest loweredModules plan
      message = fromMaybe "katari apply" options.message
  snapshotId <- deploySnapshot client projectId message manifest
  TextIO.putStrLn ("Applied snapshot " <> snapshotId <> " to project " <> name)

-- | Resolve the runtime URL: the @--url@ override, then @KATARI_API_URL@, then @[runtime].url@.
resolveRuntimeUrl :: Maybe Text -> Text -> IO Text
resolveRuntimeUrl override fallback = case override of
  Just url -> pure url
  Nothing -> do
    environmentUrl <- lookupEnv "KATARI_API_URL"
    pure $ case environmentUrl of
      Just environmentValue | not (null environmentValue) -> Text.pack environmentValue
      _ -> fallback

-- | Read the runtime's current head manifest and key it the way 'planUpload' expects.
runtimeModuleHashes :: RuntimeClient -> Text -> IO (Map ModuleName ModuleHash)
runtimeModuleHashes client projectId = do
  headHashes <- listHeadModules client projectId
  pure (Map.fromList [(ModuleName name, ModuleHash hash) | (name, hash) <- Map.toList headHashes])

-- | Assemble the deploy manifest from the fresh build: every module's hash, inlining the IR only for
-- the modules the runtime does not already hold (the plan's 'changed' set).
buildManifest :: Map ModuleName IRModule -> UploadPlan -> Map Text ModuleUpload
buildManifest loweredModules plan =
  Map.fromList
    [ (renderModuleName moduleName, moduleUpload moduleName irModule)
      | (moduleName, irModule) <- Map.toList loweredModules
    ]
  where
    moduleUpload moduleName irModule =
      let ModuleHash hashText = hashModule irModule
       in ModuleUpload
            { hash = hashText,
              ir = if Map.member moduleName plan.changed then Just (toJSON irModule) else Nothing
            }

-- | Print a short summary of what the deploy will change.
reportPlan :: Text -> Text -> UploadPlan -> IO ()
reportPlan url name plan = do
  TextIO.putStrLn ("Deploying " <> name <> " to " <> url)
  TextIO.putStrLn
    ( "  "
        <> Text.pack (show (Map.size plan.changed))
        <> " changed, "
        <> Text.pack (show (Set.size plan.unchanged))
        <> " unchanged, "
        <> Text.pack (show (Set.size plan.removed))
        <> " removed"
    )
  mapM_ (\moduleName -> TextIO.putStrLn ("  + " <> renderModuleName moduleName)) (Map.keys plan.changed)
  mapM_ (\moduleName -> TextIO.putStrLn ("  - " <> renderModuleName moduleName)) (Set.toList plan.removed)
