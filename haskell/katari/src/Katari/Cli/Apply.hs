-- | @katari apply@ — compile, bundle, upload.
--
-- Flow:
--
--   1. Locate the project + load its 'Project.ProjectConfig'
--      (to read @[api].url@ and the package name).
--   2. Run 'Compile.compile' on the assembled sources.
--   3. Spawn @katari-bundle@ to walk every package's @src/@ for
--      @ext-agent@ JS/TS siblings and produce a single ESM bundle.
--   4. @upsertProject@ + @uploadSnapshot@ via 'Katari.Api.Client'.
--
-- @katari-bundle@ is located via @$KATARI_BUNDLE_BIN@ first, then the
-- bare @katari-bundle@ on @PATH@. If the env var points at a @.js@
-- file we invoke it through @node@.
module Katari.Cli.Apply
  ( Options (..),
    optionsParser,
    run,
  )
where

import qualified Data.Aeson as Aeson
import Data.Aeson ((.=))
import qualified Data.ByteString.Lazy.Char8 as LC8
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import qualified Katari.Api.Client as Api
import qualified Katari.Api.Types as Api
import qualified Katari.Cli.Check as Check
import qualified Katari.Compile as Compile
import Katari.Diagnostic (hasErrors)
import qualified Katari.Project.Config as Project
import qualified Katari.Project.Discovery as Project
import qualified Katari.Project.Resolve as Project
import Katari.Schema (SchemaEntry (..))
import Options.Applicative
import System.Directory (getCurrentDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

data Options = Options
  { optProjectRoot :: Maybe FilePath,
    optProjectName :: Maybe Text,
    optApiUrl :: Maybe Text
  }
  deriving (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> optional
      ( strOption
          ( long "project"
              <> short 'p'
              <> metavar "DIR"
              <> help "Project root (defaults to walking up from cwd)"
          )
      )
    <*> optional
      ( strOption
          ( long "name"
              <> metavar "NAME"
              <> help "Override the project name registered with the runtime"
          )
      )
    <*> optional
      ( strOption
          ( long "api-url"
              <> metavar "URL"
              <> help "Override the [api].url from katari.toml"
          )
      )

run :: Options -> IO ()
run opts = do
  -- 1. Find project + load config.
  start <- maybe getCurrentDirectory pure opts.optProjectRoot
  mRoot <- Project.findProjectRoot start
  rootDir <- case mRoot of
    Just r -> pure r
    Nothing -> die "no katari.toml found in this or any parent directory"
  cfg <- loadCfg (rootDir </> Project.configFilename)

  -- 2. Compile via the shared loader.
  (input, fileTexts) <-
    Check.loadProject (Check.Options {optProjectRoot = Just rootDir})
  let result = Compile.compile input
  Check.emitDiagnostics fileTexts result.diagnostics
  if hasErrors result.diagnostics
    then exitWith (ExitFailure 1)
    else pure ()
  irModule <- case result.irModule of
    Just ir -> pure ir
    Nothing -> die "internal: compile produced no IR module despite clean diagnostics"

  -- 3. Bundle ext-agent siblings.
  sourceRoots <- gatherSourceRoots rootDir
  sidecarBundle <- runKatariBundle sourceRoots

  -- 4. Talk to the runtime.
  let schemaJson = buildSchemaBundle result.schemaEntries
      apiUrl = case opts.optApiUrl of
        Just u -> u
        Nothing -> cfg.runtimeSection.runtimeUrl
      projectName = case opts.optProjectName of
        Just n -> n
        Nothing -> cfg.packageSection.packageName
  auth <- Api.apiAuthFromEnv
  client <- Api.newApiClient apiUrl auth
  project <- Api.upsertProject client projectName
  snapshotId <-
    Api.uploadSnapshot
      client
      project.id
      Api.UploadSnapshotRequest
        { Api.irModule = irModule,
          Api.sidecarBundle = sidecarBundle,
          Api.schemaBundle = schemaJson
        }
  putStrLn
    ( "Applied snapshot "
        <> Text.unpack snapshotId
        <> " to project "
        <> Text.unpack project.name
        <> " ("
        <> Text.unpack project.id
        <> ")"
    )

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

die :: String -> IO a
die msg = do
  hPutStrLn stderr ("katari apply: " <> msg)
  exitWith (ExitFailure 2)

loadCfg :: FilePath -> IO Project.ProjectConfig
loadCfg path = do
  r <- Project.loadKatariToml path
  case r of
    Right c -> pure c
    Left err -> die ("config: " <> show err)

-- | Resolve every package's @[sidecar].sourceRoots@ (falling back to
-- @[compile].src@) and return absolute paths. The katari-bundle CLI
-- accepts absolute paths and walks each one recursively.
gatherSourceRoots :: FilePath -> IO [FilePath]
gatherSourceRoots rootDir = do
  rpRes <- Project.loadResolvedProject rootDir
  case rpRes of
    Left err -> die ("resolve: " <> show err)
    Right rp ->
      pure
        [ p.packageRoot </> resolveSrc p.packageConfig
          | p <- rp.rootPackage : Map.elems rp.depPackages
        ]
  where
    resolveSrc c =
      case c.sidecarSection of
        Just s | not (null s.sidecarSourceRoots) -> head s.sidecarSourceRoots
        _ -> c.packageSection.packageSrc

-- | Spawn @katari-bundle@ with one @--source-root@ flag per package
-- and decode its JSON output.
runKatariBundle :: [FilePath] -> IO (Maybe Api.SidecarBundle)
runKatariBundle sourceRoots = do
  mEnv <- lookupEnv "KATARI_BUNDLE_BIN"
  let (cmd, prefixArgs) = case mEnv of
        Just envCmd
          | ".js" `endsWith` envCmd -> ("node", [envCmd])
          | otherwise -> (envCmd, [])
        Nothing -> ("katari-bundle", [])
      args = prefixArgs <> concatMap (\r -> ["--source-root", r]) sourceRoots
  (exit, stdout, stderrOut) <- readProcessWithExitCode cmd args ""
  case exit of
    ExitFailure code ->
      die
        ( "katari-bundle exited "
            <> show code
            <> " (stderr: "
            <> stderrOut
            <> ")"
        )
    ExitSuccess -> case Aeson.eitherDecode (LC8.pack stdout) of
      Left err -> die ("katari-bundle returned unparseable JSON: " <> err)
      Right (resp :: BundleResponse) -> pure resp.bundle
  where
    endsWith suffix s = drop (length s - length suffix) s == suffix

-- | Wire shape of @katari-bundle@'s stdout.
data BundleResponse = BundleResponse {bundle :: Maybe Api.SidecarBundle}
  deriving stock (Show, Generic)
  deriving anyclass (Aeson.FromJSON)

-- | Same shape that 'Katari.Cli.Build' produces.
buildSchemaBundle :: Maybe [SchemaEntry] -> Aeson.Value
buildSchemaBundle mEntries =
  Aeson.object
    [ "schemaVersion" .= (1 :: Int),
      "agents" .= maybe ([] :: [Aeson.Value]) (map schemaEntryToAgent) mEntries
    ]

schemaEntryToAgent :: SchemaEntry -> Aeson.Value
schemaEntryToAgent e =
  Aeson.object
    [ "qualifiedName" .= e.name,
      "parameters" .= e.input,
      "returns" .= e.output,
      "description" .= e.description
    ]
