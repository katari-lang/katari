-- | Shared helpers for CLI subcommands.
--
-- Before this module existed, `mkClient` / `tryLoadApiUrl` /
-- `resolveProjectId` were copy-pasted across seven `Cli/*.hs` modules
-- with subtle drift in error messages, error handling for malformed
-- `katari.toml`, and fall-through behaviour. Centralising them removes
-- ~120 lines and gives users a single canonical error message per
-- failure mode.
module Katari.Cli.Common
  ( -- * Client construction
    resolveApiClient,

    -- * Project config loading
    tryLoadProjectConfig,
    loadProjectConfigOrDie,

    -- * Project id resolution
    resolveProjectId,

    -- * Schema bundle helpers
    schemaBundleJson,
    schemaEntryToAgent,

    -- * Error handling
    dieIn,
    runWithApiErrors,
  )
where

import Control.Exception (catch)
import qualified Data.Aeson as Aeson
import Data.Aeson ((.=))
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Katari.Api.Client as Api
import qualified Katari.Api.Types as Api
import Katari.Schema (SchemaEntry (..))
import qualified Katari.Project.Config as Project
import qualified Katari.Project.Discovery as Project
import System.Directory (getCurrentDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

-- | Construct an `ApiClient` for a CLI command.
--
-- The URL comes from (in priority order):
--
--   1. The explicit override (e.g. @--api-url@ on the CLI).
--   2. The @KATARI_API_URL@ environment variable, when non-empty.
--   3. The surrounding @katari.toml@'s @[runtime].url@.
--   4. (No further fallback — bail with a fixed message.)
--
-- The bearer token always comes from @KATARI_API_KEY@ in the
-- environment; @katari.toml@ no longer carries it.
resolveApiClient :: Text -> Maybe Text -> IO Api.ApiClient
resolveApiClient subcmdName mOverride = do
  url <- case mOverride of
    Just u -> pure u
    Nothing -> do
      mEnvUrl <- lookupNonEmpty "KATARI_API_URL"
      case mEnvUrl of
        Just u -> pure u
        Nothing -> do
          mUrl <- tryLoadProjectUrl
          case mUrl of
            Just u -> pure u
            Nothing ->
              dieIn
                subcmdName
                "no --api-url provided, KATARI_API_URL unset, and no surrounding katari.toml's [runtime].url found"
  auth <- Api.apiAuthFromEnv
  Api.newApiClient url auth

-- | Read an env var, treating empty / unset as 'Nothing'.
lookupNonEmpty :: String -> IO (Maybe Text)
lookupNonEmpty name = do
  v <- lookupEnv name
  pure $ case v of
    Just s | not (null s) -> Just (Text.pack s)
    _ -> Nothing

-- | Load the surrounding @katari.toml@. Returns 'Nothing' if no
-- project root is found OR if parsing failed (the parse error is
-- swallowed — for commands that don't strictly require config).
tryLoadProjectConfig :: IO (Maybe Project.ProjectConfig)
tryLoadProjectConfig = do
  cwd <- getCurrentDirectory
  mRoot <- Project.findProjectRoot cwd
  case mRoot of
    Nothing -> pure Nothing
    Just root ->
      Project.loadKatariToml (root </> Project.configFilename) >>= \case
        Right cfg -> pure (Just cfg)
        Left _ -> pure Nothing

-- | Like 'tryLoadProjectConfig' but bails with the parse error if the
-- file exists but cannot be read. Used by commands that strictly
-- require the config (e.g. @katari add@, @katari apply@).
loadProjectConfigOrDie :: Text -> FilePath -> IO Project.ProjectConfig
loadProjectConfigOrDie subcmdName path =
  Project.loadKatariToml path >>= \case
    Right cfg -> pure cfg
    Left err -> dieIn subcmdName ("could not read " <> path <> ": " <> show err)

-- | Read @[runtime].url@ from the surrounding @katari.toml@ if any.
tryLoadProjectUrl :: IO (Maybe Text)
tryLoadProjectUrl = fmap (.runtimeSection.runtimeUrl) <$> tryLoadProjectConfig

-- | Look up a project by name on the runtime, bailing with a helpful
-- message if it's not found or ambiguous.
resolveProjectId :: Text -> Api.ApiClient -> Text -> IO Text
resolveProjectId subcmdName client name = do
  ps <- Api.listProjects client
  case [p.id | p <- ps, p.name == name] of
    [pid] -> pure pid
    [] ->
      dieIn
        subcmdName
        ( "project '"
            <> Text.unpack name
            <> "' not found on the runtime — try `katari apply` first"
        )
    _ ->
      dieIn
        subcmdName
        ("multiple projects named '" <> Text.unpack name <> "' on the runtime")

-- | The on-the-wire schema-bundle JSON shape that both `katari apply`
-- and `katari build` produce. Shared here so the two output paths
-- can't drift apart (= snapshot upload uses this shape; build emits
-- it nested under "schemaBundle" in the local IR-bundle file).
schemaBundleJson :: Maybe [SchemaEntry] -> Aeson.Value
schemaBundleJson mEntries =
  Aeson.object
    [ "schemaVersion" .= (1 :: Int),
      "agents" .= maybe ([] :: [Aeson.Value]) (map schemaEntryToAgent) mEntries
    ]

-- | Single 'SchemaEntry' → wire-format agent definition. Surface
-- shape used by both CLI commands and consumed by AI tool-calling
-- consumers via the api-server's /agent endpoints.
schemaEntryToAgent :: SchemaEntry -> Aeson.Value
schemaEntryToAgent e =
  Aeson.object
    [ "qualifiedName" .= e.name,
      "parameters" .= e.input,
      "returns" .= e.output,
      "description" .= e.description
    ]

-- | Standard CLI bail: print to stderr with the subcommand prefix and
-- exit with code 2 (setup / usage error).
dieIn :: Text -> String -> IO a
dieIn subcmdName msg = do
  hPutStrLn stderr ("katari " <> Text.unpack subcmdName <> ": " <> msg)
  exitWith (ExitFailure 2)

-- | Run @action@; catch any 'Api.ApiError' it raises and re-emit as a
-- 'dieIn' message with the subcommand prefix. Without this wrapper, a
-- 404 / 500 from the runtime crashes the CLI with a Haskell stack
-- trace instead of a friendly @katari <cmd>:@ line.
runWithApiErrors :: Text -> IO a -> IO a
runWithApiErrors subcmdName action =
  action `catch` \err -> dieIn subcmdName (renderApiError err)
  where
    renderApiError = \case
      Api.ApiNetworkError msg -> "network error: " <> msg
      Api.ApiHttpError status body ->
        "runtime returned HTTP "
          <> show status
          <> ": "
          <> Text.unpack body
      Api.ApiDecodeError msg -> "could not decode runtime response: " <> msg
