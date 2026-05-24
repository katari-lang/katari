-- | @katari ls [target]@ — read-only listing.
--
-- Targets:
--
--   * @projects@      — every project registered with the runtime
--   * @snapshots@     — snapshots under @--project NAME@
--   * @runs@          — operator-launched runs (optionally narrowed by project / snapshot)
--   * @agent-defs@    — schema bundle entries (qualified names + descriptions)
module Katari.Cli.Ls
  ( Options (..),
    optionsParser,
    run,
  )
where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Encode.Pretty as Pretty
import qualified Data.ByteString.Lazy.Char8 as LC8
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Katari.Api.Client as Api
import qualified Katari.Api.Types as Api
import qualified Katari.Cli.Common as Common
import qualified Katari.Cli.Status as Status
import Options.Applicative

data Target
  = TProjects
  | TSnapshots
  | TRuns
  | TAgentDefs
  deriving (Show)

data Options = Options
  { optTarget :: Target,
    optProject :: Maybe Text,
    optSnapshot :: Maybe Text,
    optApiUrl :: Maybe Text,
    optJson :: Bool
  }
  deriving (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> argument readTarget (metavar "TARGET" <> help "projects | snapshots | runs | agent-defs")
    <*> optional
      ( strOption
          ( long "project"
              <> short 'p'
              <> metavar "NAME"
              <> help "Restrict to this project (required for snapshots / runs / agent-defs)"
          )
      )
    <*> optional
      ( strOption
          ( long "snapshot"
              <> short 's'
              <> metavar "ID"
              <> help "Restrict to a specific snapshot ID"
          )
      )
    <*> optional
      ( strOption
          ( long "api-url"
              <> metavar "URL"
              <> help "Override [api].url (otherwise read from the surrounding katari.toml if present)"
          )
      )
    <*> switch (long "json" <> help "Emit raw JSON instead of a human table")
  where
    readTarget =
      eitherReader $ \case
        "projects" -> Right TProjects
        "snapshots" -> Right TSnapshots
        "runs" -> Right TRuns
        "agent-defs" -> Right TAgentDefs
        other -> Left ("unknown target '" <> other <> "' (try projects | snapshots | runs | agent-defs)")

run :: Options -> IO ()
run opts = do
  client <- mkClient opts
  case opts.optTarget of
    TProjects -> do
      ps <- Api.listProjects client
      if opts.optJson
        then emitJson ps
        else mapM_ printProject ps
    TSnapshots -> do
      pid <- requireProjectId client opts
      snaps <- Api.listSnapshots client pid
      if opts.optJson
        then emitJson snaps
        else mapM_ printSnap snaps
    TRuns -> do
      pid <- requireProjectId client opts
      runs <- Api.listRuns client pid opts.optSnapshot
      if opts.optJson then emitJson runs else mapM_ printRun runs
    TAgentDefs -> do
      pid <- requireProjectId client opts
      (defs, snapId) <- Api.listAgentDefinitions client pid opts.optSnapshot
      if opts.optJson
        then emitJson defs
        else do
          putStrLn ("(snapshot " <> Text.unpack snapId <> ")")
          mapM_ printDef defs

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

die :: String -> IO a
die = Common.dieIn "ls"

mkClient :: Options -> IO Api.ApiClient
mkClient opts = Common.resolveApiClient "ls" opts.optApiUrl

requireProjectId :: Api.ApiClient -> Options -> IO Text
requireProjectId c opts = case opts.optProject of
  Just name -> Common.resolveProjectId "ls" c name
  Nothing -> die "this target requires --project NAME"

emitJson :: Aeson.ToJSON a => a -> IO ()
emitJson = LC8.putStrLn . Pretty.encodePretty

printProject :: Api.Project -> IO ()
printProject p =
  putStrLn (Text.unpack p.id <> "  " <> Text.unpack p.name <> "  (" <> Text.unpack p.createdAt <> ")")

printSnap :: Api.SnapshotSummary -> IO ()
printSnap s =
  putStrLn
    ( Text.unpack s.id
        <> maybe "" (\m -> "  " <> Text.unpack m) s.message
        <> "  ("
        <> Text.unpack s.createdAt
        <> ")"
    )

printRun :: Api.RunRow -> IO ()
printRun r =
  putStrLn
    ( Text.unpack r.id
        <> "  "
        <> show r.state
        <> "  "
        <> Text.unpack r.qualifiedName
        <> maybe "" (\n -> "  [" <> Text.unpack n <> "]") r.name
        <> "  "
        <> Text.unpack (Status.renderResultPreview r.result)
        <> "  ("
        <> Text.unpack r.updatedAt
        <> ")"
    )

printDef :: Api.AgentDefinition -> IO ()
printDef d =
  putStrLn
    ( Text.unpack d.qualifiedName
        <> maybe "" (\desc -> "  — " <> Text.unpack desc) d.description
    )
