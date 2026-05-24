-- | @katari run [qualifiedName]@ — start a run on the runtime.
--
-- Two modes:
--
--   * @--args JSON@ supplied (or all parameters are optional): runs
--     non-interactively.
--   * Otherwise: drops into the interactive prompt — pick the agent
--     def from a numbered menu, walk its JSON Schema asking for each
--     parameter, and confirm before POSTing.
module Katari.Cli.Run
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Applicative ((<|>))
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
import qualified Katari.Cli.Common as Common
import qualified Katari.Cli.Prompt as Prompt
import qualified Katari.Project.Config as Project
import qualified Katari.Cli.Status as Status
import Options.Applicative
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStr, hPutStrLn, stderr)

data Options = Options
  { optQualifiedName :: Maybe Text,
    optProject :: Maybe Text,
    optSnapshot :: Maybe Text,
    optName :: Maybe Text,
    optArgs :: Maybe Text,
    optWait :: Bool,
    optApiUrl :: Maybe Text
  }
  deriving (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> optional
      ( argument
          str
          ( metavar "QUALIFIED_NAME"
              <> help "Agent qualified name, e.g. 'hello.main' (omit to pick interactively)"
          )
      )
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
          ( long "as"
              <> metavar "NAME"
              <> help "Operator-supplied label for this run (shown in `katari ls runs` / admin UI)"
          )
      )
    <*> optional
      ( strOption
          ( long "args"
              <> metavar "JSON"
              <> help "Argument record as JSON, e.g. '{\"x\":1}' (default: {})"
          )
      )
    <*> switch (long "wait" <> help "Poll until the run finishes; print its result")
    <*> optional (strOption (long "api-url" <> metavar "URL" <> help "Override [runtime].url"))

run :: Options -> IO ()
run opts = do
  cfg <- Common.tryLoadProjectConfig
  client <- Common.resolveApiClient "run" opts.optApiUrl
  let nameFromCfg :: Project.ProjectConfig -> Text
      nameFromCfg c = c.packageSection.packageName
  projectName <- case opts.optProject <|> fmap nameFromCfg cfg of
    Just p -> pure p
    Nothing -> die "no --project and no surrounding katari.toml found"
  proj <- Common.resolveProjectId "run" client projectName

  -- Resolve qualified name (interactive picker if absent), and
  -- gather args (from --args JSON, otherwise walk the schema).
  (qname, args) <- resolveQualifiedNameAndArgs client proj opts

  runId <-
    Api.startRun
      client
      Api.StartRunRequest
        { Api.projectId = proj,
          Api.snapshotId = opts.optSnapshot,
          Api.qualifiedName = qname,
          Api.name = opts.optName,
          Api.args = args
        }
  hPutStrLn stderr ("Started " <> Text.unpack runId)
  if opts.optWait
    then pollUntilDone client runId
    else
      hPutStrLn
        stderr
        ("(re-run with --wait, or `katari status " <> Text.unpack runId <> "` to inspect)")

-- | Choose @(qualifiedName, args)@ via:
--
--   1. If @--args@ given AND @qualifiedName@ given, use both verbatim.
--   2. If @qualifiedName@ given but @--args@ missing, fetch its
--      definition and prompt the user through the schema.
--   3. If @qualifiedName@ missing, fetch every agent def, let the
--      user pick, then prompt for args (or use the supplied @--args@
--      if provided).
resolveQualifiedNameAndArgs ::
  Api.ApiClient ->
  Text ->
  Options ->
  IO (Text, Map Text Aeson.Value)
resolveQualifiedNameAndArgs client projectId opts = do
  case (opts.optQualifiedName, opts.optArgs) of
    (Just qn, Just argsJson) -> do
      args <- decodeArgsJson argsJson
      pure (qn, args)
    (Just qn, Nothing) -> do
      def <- findDefinition client projectId opts.optSnapshot qn
      args <- promptArgs def
      pure (qn, args)
    (Nothing, _) -> do
      (defs, _snapId) <-
        Api.listAgentDefinitions client projectId opts.optSnapshot
      case defs of
        [] -> die "no agent definitions on this snapshot (did you run `katari apply`?)"
        _ -> do
          mDef <- Prompt.pickFromList "Pick an agent:" defs renderDefLabel
          case mDef of
            Nothing -> die "nothing to pick"
            Just def -> do
              args <- case opts.optArgs of
                Just argsJson -> decodeArgsJson argsJson
                Nothing -> promptArgs def
              pure (def.qualifiedName, args)
  where
    renderDefLabel d = case d.description of
      Just desc -> d.qualifiedName <> "  — " <> desc
      Nothing -> d.qualifiedName

findDefinition ::
  Api.ApiClient ->
  Text ->
  Maybe Text ->
  Text ->
  IO Api.AgentDefinition
findDefinition client projectId snap qname = do
  (defs, _) <- Api.listAgentDefinitions client projectId snap
  case filter (\d -> d.qualifiedName == qname) defs of
    [d] -> pure d
    [] -> die ("agent '" <> Text.unpack qname <> "' not found in this snapshot")
    multi -> die ("multiple agent defs named '" <> Text.unpack qname <> "' (" <> show (length multi) <> ")")

-- | Walk the agent's @parameters@ JSON Schema to gather an args object,
-- then confirm. Aborts if the user declines.
promptArgs :: Api.AgentDefinition -> IO (Map Text Aeson.Value)
promptArgs def = do
  hPutStrLn stderr ("Agent: " <> Text.unpack def.qualifiedName)
  argsValue <- Prompt.promptForSchema [] def.parameters
  ok <- Prompt.confirmAndProceed argsValue
  if not ok
    then die "user cancelled"
    else case argsValue of
      Aeson.Object o ->
        pure (Map.fromList [(AesonKey.toText k, v) | (k, v) <- AesonKM.toList o])
      _ -> die "expected the schema's top-level shape to be an object"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

die :: String -> IO a
die = Common.dieIn "run"

decodeArgsJson :: Text -> IO (Map Text Aeson.Value)
decodeArgsJson s = case Aeson.eitherDecode (LC8.pack (Text.unpack s)) of
  Right (Aeson.Object o) ->
    pure (Map.fromList [(AesonKey.toText k, v) | (k, v) <- AesonKM.toList o])
  Right _ -> die "--args must be a JSON object"
  Left err -> die ("--args is not valid JSON: " <> err)

pollUntilDone :: Api.ApiClient -> Text -> IO ()
pollUntilDone client runId = loop (50_000 :: Int)
  where
    -- Exponential backoff capped at 2 s. We deliberately have no overall
    -- timeout: a `katari run` invocation blocks until the run finishes
    -- (or the user hits Ctrl-C). Earlier versions of this loop gave up
    -- after 20 s of polling, which surprised users running long runs.
    maxDelay = 2_000_000 :: Int
    loop delay = do
      row <- Api.getRun client runId
      case row.state of
        Api.RunRunning -> threadDelay delay >> loop (min maxDelay (delay * 2))
        Api.RunCancelling -> threadDelay delay >> loop (min maxDelay (delay * 2))
        -- Pretty block on stderr so a downstream `| jq` keeps working
        -- on the bare result on stdout.
        done -> do
          hPutStr stderr (Text.unpack (Status.renderRunDetailed row))
          case done of
            Api.RunSucceeded -> case row.result of
              Just v -> LC8.putStrLn (Aeson.encode v)
              Nothing -> pure ()
            Api.RunError -> exitWith (ExitFailure 1)
            _ -> pure ()
