-- | @katari run@ — start an agent on the runtime and report its outcome.
--
-- A light command: it reads only the root @katari.toml@ (for the project name + runtime URL — no
-- dependency resolution or compile), starts the named agent against the project's head snapshot, then
-- polls the run until it reaches a terminal state and prints the result (or the failure).
module Katari.Cli.Run
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Katari.Cli.Api
  ( ProjectRow (..),
    RunView (..),
    RuntimeClient,
    StartRunRequest (..),
    getRun,
    listProjects,
    newRuntimeClient,
    runtimeAuthFromEnvironment,
    startRun,
  )
import Katari.Cli.Common (dieIn, resolveProjectRoot, resolveRuntimeUrl)
import Katari.Project.Config (PackageSection (..), ProjectConfig (..), RuntimeSection (..), loadKatariToml)
import Katari.Project.Discovery (configFilename)
import Katari.Project.Error (renderProjectError)
import Network.HTTP.Client.TLS (newTlsManager)
import Options.Applicative
import System.FilePath ((</>))

data Options = Options
  { projectRoot :: Maybe FilePath,
    runtimeUrl :: Maybe Text,
    agent :: Text,
    argumentJson :: Maybe Text,
    name :: Maybe Text
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
          ( long "url"
              <> metavar "URL"
              <> help "Runtime URL. Overrides KATARI_API_URL and [runtime].url from katari.toml."
          )
      )
    <*> strArgument (metavar "AGENT" <> help "The qualified name of the agent to run (e.g. main).")
    <*> optional
      ( strOption
          ( long "arg"
              <> short 'a'
              <> metavar "JSON"
              <> help "The run argument, as a JSON value (default: null)."
          )
      )
    <*> optional
      ( strOption
          ( long "name"
              <> metavar "NAME"
              <> help "A human label for the run record (default: the agent name)."
          )
      )

run :: Options -> IO ()
run options = do
  root <- resolveProjectRoot "run" options.projectRoot
  config <-
    loadKatariToml (root </> configFilename) >>= \case
      Left projectError -> dieIn "run" (renderProjectError projectError)
      Right config -> pure config
  runArgument <- parseArgument options.argumentJson

  manager <- newTlsManager
  url <- resolveRuntimeUrl options.runtimeUrl config.runtime.url
  token <- runtimeAuthFromEnvironment
  let client = newRuntimeClient manager url token
      projectName = config.package.name
  projects <- listProjects client
  projectId <- case filter (\project -> project.name == projectName) projects of
    (existing : _) -> pure existing.id
    [] -> dieIn "run" ("project " <> projectName <> " is not deployed; run `katari apply` first")

  runId <-
    startRun
      client
      projectId
      StartRunRequest
        { qualifiedName = options.agent,
          name = options.name,
          snapshotId = Nothing,
          argument = runArgument
        }
  TextIO.putStrLn ("Started run " <> runId)
  view <- pollUntilTerminal client projectId runId
  reportOutcome view

-- | Parse the @--arg@ JSON into a value (or 'Nothing' when omitted — the runtime defaults it to null).
parseArgument :: Maybe Text -> IO (Maybe Value)
parseArgument Nothing = pure Nothing
parseArgument (Just text) = case Aeson.eitherDecodeStrict' (TextEncoding.encodeUtf8 text) of
  Left decodeError -> dieIn "run" ("--arg is not valid JSON: " <> Text.pack decodeError)
  Right decoded -> pure (Just decoded)

-- | Poll the run until it reaches a terminal state (done / cancelled / error), giving up after a bound so a
-- stuck run does not hang the CLI forever.
pollUntilTerminal :: RuntimeClient -> Text -> Text -> IO RunView
pollUntilTerminal client projectId runId = go (0 :: Int)
  where
    go attempt
      | attempt >= maxAttempts = dieIn "run" "run did not finish within the timeout"
      | otherwise = do
          view <- getRun client projectId runId
          if view.state `elem` ["done", "cancelled", "error"]
            then pure view
            else do
              threadDelay pollIntervalMicros
              go (attempt + 1)
    maxAttempts = 600 :: Int -- ~5 minutes at 500ms
    pollIntervalMicros = 500000

-- | Print the run's result, or exit non-zero on a failed / cancelled run.
reportOutcome :: RunView -> IO ()
reportOutcome view = case view.state of
  "done" -> TextIO.putStrLn ("Result: " <> renderValue view.result)
  "error" -> dieIn "run" ("run failed: " <> fromMaybe "(no message)" view.errorMessage)
  "cancelled" -> dieIn "run" "run was cancelled"
  other -> dieIn "run" ("run ended in an unexpected state: " <> other)

-- | Render a run result value as compact JSON for display.
renderValue :: Maybe Value -> Text
renderValue Nothing = "null"
renderValue (Just json) = TextEncoding.decodeUtf8 (LazyByteString.toStrict (Aeson.encode json))
