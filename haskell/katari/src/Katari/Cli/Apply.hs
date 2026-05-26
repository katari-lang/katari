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

import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LC8
import Data.List (isSuffixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import GHC.Generics (Generic)
import Katari.Api.Client qualified as Api
import Katari.Api.Types qualified as Api
import Katari.Cli.Check qualified as Check
import Katari.Cli.Common qualified as Common
import Katari.Compile qualified as Compile
import Katari.Diagnostic (hasErrors)
import Katari.Project.Config qualified as Project
import Katari.Project.Discovery qualified as Project
import Katari.Project.Resolve qualified as Project
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
    optMessage :: Maybe Text,
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
          ( long "message"
              <> short 'm'
              <> metavar "TEXT"
              <> help "Commit-message-like label for this snapshot (shown in `katari ls snapshots` / admin UI)"
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
  -- 1. Find project + resolve dependencies (once).
  start <- maybe getCurrentDirectory pure opts.optProjectRoot
  mRoot <- Project.findProjectRoot start
  rootDir <- case mRoot of
    Just r -> pure r
    Nothing -> die "no katari.toml found in this or any parent directory"
  resolved <- do
    rpRes <- Project.loadResolvedProject rootDir
    case rpRes of
      Left err -> die (Text.unpack (Project.renderResolveError err))
      Right rp -> pure rp
  assembly <- case Project.assembleProject resolved of
    Left err -> die (Text.unpack (Project.renderResolveError err))
    Right a -> pure a
  let cfg = resolved.rootPackage.packageConfig
      sources =
        Map.map
          ( \e ->
              Compile.SourceEntry
                { Compile.filePath = e.sourcePath,
                  Compile.sourceText = e.sourceText
                }
          )
          assembly.sources
      fileTexts =
        Map.fromList
          [ (e.sourcePath, e.sourceText) | e <- Map.elems assembly.sources
          ]

  -- 2. Compile.
  let result = Compile.compile Compile.CompileInput {Compile.sources = sources}
  Check.emitDiagnostics fileTexts result.diagnostics
  if hasErrors result.diagnostics
    then exitWith (ExitFailure 1)
    else pure ()
  irModule <- case result.irModule of
    Just ir -> pure ir
    Nothing -> dieInternal "compile produced no IR module despite clean diagnostics"

  -- 3. Bundle ext-agent siblings (reuse the already-resolved packages).
  let packages = packagesFromResolved resolved
  sidecarBundle <- runKatariBundle packages

  -- 4. Talk to the runtime.
  let schemaJson = Common.schemaBundleJson result.schemaEntries
      projectName = case opts.optProjectName of
        Just n -> n
        Nothing -> cfg.packageSection.packageName
  client <- Common.resolveApiClient "apply" opts.optApiUrl
  readme <- readSiblingReadme rootDir
  project <-
    Api.upsertProject
      client
      Api.UpsertProjectRequest
        { Api.name = projectName,
          Api.description = cfg.packageSection.packageDescription,
          Api.readme = readme
        }
  snapshotId <-
    Api.uploadSnapshot
      client
      project.id
      Api.UploadSnapshotRequest
        { Api.irModule = Aeson.toJSON irModule,
          Api.sidecarBundle = sidecarBundle,
          Api.schemaBundle = schemaJson,
          Api.message = opts.optMessage
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

-- | User-facing error: configuration / usage problem. Exits with 2,
-- matching the convention shared by other CLI subcommands.
die :: String -> IO a
die msg = do
  hPutStrLn stderr ("katari apply: " <> msg)
  exitWith (ExitFailure 2)

-- | Internal-invariant violation: the compiler produced an unexpected
-- result, a bundler output failed to decode, etc. Distinct exit code
-- (70 = sysexits.h EX_SOFTWARE) so CI / wrappers can separate "user
-- did something wrong" from "katari itself is buggy".
dieInternal :: String -> IO a
dieInternal msg = do
  hPutStrLn stderr ("katari apply: internal error: " <> msg)
  exitWith (ExitFailure 70)

-- | Read @README.md@ next to @katari.toml@ if it exists. Any IO failure
-- (missing file, permission error, decode failure) → 'Nothing', which
-- the server interprets as "clear the readme field". We deliberately do
-- NOT walk up or look at alternative case spellings — operators who
-- want a README put it in the canonical place, and silently picking up
-- e.g. @Readme.markdown@ would be surprising.
readSiblingReadme :: FilePath -> IO (Maybe Text)
readSiblingReadme rootDir = do
  let path = rootDir </> "README.md"
  result <- try (TextIO.readFile path) :: IO (Either IOException Text)
  pure $ case result of
    Right body -> Just body
    Left _ -> Nothing

-- | Per-package (name, source-root) pair handed to the bundler. The
-- package name becomes the flat namespace prefix for that package's
-- sidecar agent registrations (Wave 6b-A3): each registered agent
-- @katari.agent("foo", ...)@ lands under @\<packageName\>.foo@ in the
-- dispatch registry.
data BundlePackage = BundlePackage
  { packageName :: Text.Text,
    sourceRoot :: FilePath
  }

-- | Extract @(packageName, sourceRoot)@ pairs from an already-resolved
-- project. Avoids a redundant 'loadResolvedProject' call.
packagesFromResolved :: Project.ResolvedProject -> [BundlePackage]
packagesFromResolved resolved =
  [ BundlePackage
      { packageName = p.packageConfig.packageSection.packageName,
        sourceRoot = p.packageRoot </> resolveSrc p.packageConfig
      }
    | p <- resolved.rootPackage : Map.elems resolved.depPackages
  ]
  where
    resolveSrc c = case c.sidecarSection of
      Just s | (r : _) <- filter (not . null) s.sidecarSourceRoots -> r
      _ -> c.packageSection.packageSrc

-- | Spawn @katari-bundle@ with one @--package \<name\>=\<path\>@ flag
-- per package and decode its JSON output.
runKatariBundle :: [BundlePackage] -> IO (Maybe Api.SidecarBundle)
runKatariBundle packages = do
  mEnv <- lookupEnv "KATARI_BUNDLE_BIN"
  let (cmd, prefixArgs) = case mEnv of
        Just envCmd
          | ".js" `isSuffixOf` envCmd -> ("node", [envCmd])
          | otherwise -> (envCmd, [])
        Nothing -> ("katari-bundle", [])
      args =
        prefixArgs
          <> concatMap
            (\p -> ["--package", Text.unpack p.packageName <> "=" <> p.sourceRoot])
            packages
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

-- | Wire shape of @katari-bundle@'s stdout.
data BundleResponse = BundleResponse {bundle :: Maybe Api.SidecarBundle}
  deriving stock (Show, Generic)
  deriving anyclass (Aeson.FromJSON)
