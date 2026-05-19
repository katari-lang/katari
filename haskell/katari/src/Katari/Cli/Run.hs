-- | @katari run [qualifiedName]@ — start an agent on the runtime.
--
-- v1 is a non-interactive entry: the user passes @qualifiedName@ and
-- @--args JSON@; we POST and (optionally) poll until the agent
-- finishes. Interactive picker + schema-driven arg prompt are
-- planned for a later pass — see PM-6 follow-ups.
module Katari.Cli.Run
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Concurrent (threadDelay)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AesonKey
import qualified Data.Aeson.KeyMap as AesonKM
import qualified Data.ByteString.Lazy.Char8 as LC8
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Katari.Api.Client as Api
import qualified Katari.Api.Types as Api
import qualified Katari.Project.Config as Project
import qualified Katari.Project.Discovery as Project
import Options.Applicative
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

data Options = Options
  { optQualifiedName :: Text,
    optProject :: Maybe Text,
    optSnapshot :: Maybe Text,
    optArgs :: Maybe Text,
    optWait :: Bool,
    optApiUrl :: Maybe Text
  }
  deriving (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> argument str (metavar "QUALIFIED_NAME" <> help "Agent qualified name, e.g. 'hello.main'")
    <*> optional
      ( strOption
          ( long "project"
              <> short 'p'
              <> metavar "NAME"
              <> help "Project to invoke under (defaults to the surrounding katari.toml's [package].name)"
          )
      )
    <*> optional (strOption (long "snapshot" <> short 's' <> metavar "ID" <> help "Pin to a snapshot id (else use the latest)"))
    <*> optional
      ( strOption
          ( long "args"
              <> metavar "JSON"
              <> help "Argument record as JSON, e.g. '{\"x\":1}' (default: {})"
          )
      )
    <*> switch (long "wait" <> help "Poll until the agent finishes; print its result")
    <*> optional (strOption (long "api-url" <> metavar "URL" <> help "Override [api].url"))

run :: Options -> IO ()
run opts = do
  cfg <- tryLoadCfg
  let url = case opts.optApiUrl of
        Just u -> Just u
        Nothing -> fmap (.apiSection.apiUrl) cfg
      project = case opts.optProject of
        Just p -> Just p
        Nothing -> fmap (.packageSection.packageName) cfg
  urlOk <- maybe (die "no --api-url and no surrounding katari.toml found") pure url
  projectOk <- maybe (die "no --project and no surrounding katari.toml found") pure project
  args <- decodeArgs opts.optArgs
  client <- Api.newApiClient urlOk (cfg >>= (.apiSection.apiAuth))
  proj <- resolveProjectId client projectOk
  agentId <-
    Api.startAgent
      client
      Api.StartAgentRequest
        { Api.projectId = proj,
          Api.snapshotId = opts.optSnapshot,
          Api.qualifiedName = opts.optQualifiedName,
          Api.args = args
        }
  hPutStrLn stderr ("Started " <> Text.unpack agentId)
  if not opts.optWait
    then pure ()
    else pollUntilDone client agentId

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

die :: String -> IO a
die msg = do
  hPutStrLn stderr ("katari run: " <> msg)
  exitWith (ExitFailure 2)

tryLoadCfg :: IO (Maybe Project.ProjectConfig)
tryLoadCfg = do
  cwd <- getCurrentDirectory
  mRoot <- Project.findProjectRoot cwd
  case mRoot of
    Nothing -> pure Nothing
    Just root -> do
      r <- Project.loadKatariToml (root </> Project.configFilename)
      pure (either (const Nothing) Just r)

resolveProjectId :: Api.ApiClient -> Text -> IO Text
resolveProjectId c name = do
  ps <- Api.listProjects c
  case [p.id | p <- ps, p.name == name] of
    [pid] -> pure pid
    [] -> die ("project '" <> Text.unpack name <> "' not found on the runtime — `katari apply` first?")
    _ -> die ("multiple projects named '" <> Text.unpack name <> "'")

decodeArgs :: Maybe Text -> IO (Map Text Aeson.Value)
decodeArgs = \case
  Nothing -> pure Map.empty
  Just s -> case Aeson.eitherDecode (LC8.pack (Text.unpack s)) of
    Right (Aeson.Object o) ->
      pure (Map.fromList [(AesonKey.toText k, v) | (k, v) <- AesonKM.toList o])
    Right _ -> die "--args must be a JSON object"
    Left err -> die ("--args is not valid JSON: " <> err)

pollUntilDone :: Api.ApiClient -> Text -> IO ()
pollUntilDone client agentId = loop (0 :: Int)
  where
    loop n
      | n > 1000 = die ("agent " <> Text.unpack agentId <> " did not finish within poll budget")
      | otherwise = do
          row <- Api.getAgent client agentId
          case row.state of
            Api.AgentRunning -> threadDelay 20000 >> loop (n + 1)
            Api.AgentCancelling -> threadDelay 20000 >> loop (n + 1)
            done -> do
              -- Informational lines on stderr so stdout stays parseable.
              hPutStrLn stderr ("State: " <> show done)
              case done of
                Api.AgentSucceeded -> case row.result of
                  Just v -> LC8.putStrLn (Aeson.encode v)
                  Nothing -> hPutStrLn stderr "(succeeded with no result)"
                Api.AgentError -> do
                  case row.errorMessage of
                    Just msg -> hPutStrLn stderr ("error: " <> Text.unpack msg)
                    Nothing -> pure ()
                  exitWith (ExitFailure 1)
                _ -> pure ()
