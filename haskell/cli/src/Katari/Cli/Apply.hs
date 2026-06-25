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
import Data.Aeson (FromJSON (..), Value, toJSON, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.List (isSuffixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import GHC.List (List)
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
import Katari.Cli.Common (assembleSourcesOrExit, compileSourcesOrExit, dieIn, resolveProjectRoot, resolveRuntimeUrl, writeOrExit)
import Katari.Data.IR (IRModule)
import Katari.Data.ModuleName (ModuleName (..), renderModuleName)
import Katari.Project.Config (PackageSection (..), ProjectConfig (..), RuntimeSection (..), SidecarSection (..))
import Katari.Project.Error (renderProjectError)
import Katari.Project.Lockfile (lockfileFilename, writeLockfile)
import Katari.Project.Resolve (ResolvedPackage (..), ResolvedProject (..), lockfileFromResolved, resolveProject)
import Katari.Project.Upload (ModuleHash (..), UploadPlan (..), hashModule, planUpload)
import Network.HTTP.Client.TLS (newTlsManager)
import Options.Applicative
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

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

  -- 4. Bundle the FFI sidecars (reusing the resolved closure) and send the complete desired manifest.
  sidecarBundle <- runKatariBundle (packagesFromResolved resolved)
  let manifest = buildManifest loweredModules plan
      message = fromMaybe "katari apply" options.message
  snapshotId <- deploySnapshot client projectId message sidecarBundle manifest
  TextIO.putStrLn ("Applied snapshot " <> snapshotId <> " to project " <> name)

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

-- ---------------------------------------------------------------------------
-- FFI sidecar bundling
-- ---------------------------------------------------------------------------

-- | A package handed to @katari-bundle@: its name (the flat namespace prefix every
-- @katari.agent(name, ...)@ in its sidecar registers under, i.e. @\<packageName\>.name@ — the key the
-- compiler lowers an @external agent@ to) and the absolute source root holding its sidecar entry.
data BundlePackage = BundlePackage
  { packageName :: Text,
    sourceRoot :: FilePath
  }

-- | Every package in the resolved closure (root + dependencies) as a bundler input. A package's sidecar
-- source root is the first @[sidecar].sourceRoots@ entry, or @[package].src@ when it declares no sidecar
-- section. Packages with no sidecar contribute nothing — the bundler skips a root holding no handler.
packagesFromResolved :: ResolvedProject -> List BundlePackage
packagesFromResolved resolved =
  [ BundlePackage
      { packageName = package.config.package.name,
        sourceRoot = package.root </> sidecarSourceRoot package.config
      }
    | package <- resolved.rootPackage : Map.elems resolved.depPackages
  ]
  where
    sidecarSourceRoot config = case config.sidecar of
      Just section | (root : _) <- section.sourceRoots -> root
      _ -> config.package.src

-- | Spawn @katari-bundle@ with one @--package \<name\>=\<path\>@ flag per package and decode its
-- @{ bundle }@ stdout — the compiled sidecar, or 'Nothing' when no package has one. The binary is found
-- via @KATARI_BUNDLE_BIN@ (a JS file — @.js@ / @.mjs@ / @.cjs@ — is run through @node@, for a dev checkout)
-- or on @PATH@.
runKatariBundle :: List BundlePackage -> IO (Maybe Value)
runKatariBundle packages = do
  binOverride <- lookupEnv "KATARI_BUNDLE_BIN"
  let isJsFile path = any (`isSuffixOf` path) [".js", ".mjs", ".cjs"]
      (bundleCommand, prefixArguments) = case binOverride of
        Just path | isJsFile path -> ("node", [path])
        Just path -> (path, [])
        Nothing -> ("katari-bundle", [])
      arguments =
        prefixArguments
          <> concatMap
            (\package -> ["--package", Text.unpack package.packageName <> "=" <> package.sourceRoot])
            packages
  (exitCode, output, errorOutput) <- readProcessWithExitCode bundleCommand arguments ""
  case exitCode of
    ExitFailure code ->
      dieIn
        "apply"
        ("katari-bundle exited " <> Text.pack (show code) <> " (stderr: " <> Text.pack errorOutput <> ")")
    -- The bundler writes UTF-8 JSON on stdout; re-encode the decoded String as UTF-8 (a Char8 pack would
    -- truncate a multibyte char to its low byte — e.g. a box-drawing char in a comment → NUL, which
    -- Postgres then rejects).
    ExitSuccess -> case Aeson.eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.pack output)) of
      Left decodeError -> dieIn "apply" ("katari-bundle returned unparseable JSON: " <> Text.pack decodeError)
      Right (response :: BundleResponse) -> pure response.bundle

-- | The wire shape of @katari-bundle@'s stdout: @{ "bundle": SidecarBundle | null }@. The bundle is kept
-- opaque (a 'Value') — it is produced by our own bundler and stored verbatim by the runtime, so the CLI
-- never needs to interpret it.
newtype BundleResponse = BundleResponse {bundle :: Maybe Value}

instance FromJSON BundleResponse where
  parseJSON = withObject "BundleResponse" $ \object' -> BundleResponse <$> object' .: "bundle"
