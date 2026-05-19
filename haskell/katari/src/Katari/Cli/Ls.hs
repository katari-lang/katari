-- | @katari ls [target]@ — read-only listing.
--
-- Targets:
--
--   * @projects@      — every project registered with the runtime
--   * @snapshots@     — snapshots under @--project NAME@
--   * @agents@        — agent runs (optionally narrowed by project / snapshot)
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
import qualified Katari.Project.Config as Project
import qualified Katari.Project.Discovery as Project
import Options.Applicative
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

data Target
  = TProjects
  | TSnapshots
  | TAgents
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
    <$> argument readTarget (metavar "TARGET" <> help "projects | snapshots | agents | agent-defs")
    <*> optional
      ( strOption
          ( long "project"
              <> short 'p'
              <> metavar "NAME"
              <> help "Restrict to this project (required for snapshots / agent-defs)"
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
        "agents" -> Right TAgents
        "agent-defs" -> Right TAgentDefs
        other -> Left ("unknown target '" <> other <> "' (try projects | snapshots | agents | agent-defs)")

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
    TAgents -> do
      pid <- traverse (resolveProjectId client) opts.optProject
      ags <- Api.listAgents client pid opts.optSnapshot
      if opts.optJson then emitJson ags else mapM_ printAgent ags
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
die msg = do
  hPutStrLn stderr ("katari ls: " <> msg)
  exitWith (ExitFailure 2)

mkClient :: Options -> IO Api.ApiClient
mkClient opts = do
  url <- case opts.optApiUrl of
    Just u -> pure u
    Nothing -> do
      mUrl <- tryLoadApiUrl
      maybe (die "no --api-url and no surrounding katari.toml found") pure mUrl
  Api.newApiClient url Nothing

tryLoadApiUrl :: IO (Maybe Text)
tryLoadApiUrl = do
  cwd <- getCurrentDirectory
  mRoot <- Project.findProjectRoot cwd
  case mRoot of
    Nothing -> pure Nothing
    Just root -> do
      r <- Project.loadKatariToml (root </> Project.configFilename)
      pure $ case r of
        Right cfg -> Just cfg.apiSection.apiUrl
        Left _ -> Nothing

requireProjectId :: Api.ApiClient -> Options -> IO Text
requireProjectId c opts = case opts.optProject of
  Just name -> resolveProjectId c name
  Nothing -> die "this target requires --project NAME"

resolveProjectId :: Api.ApiClient -> Text -> IO Text
resolveProjectId c name = do
  ps <- Api.listProjects c
  case [p.id | p <- ps, p.name == name] of
    [pid] -> pure pid
    [] -> die ("project '" <> Text.unpack name <> "' not found")
    multi -> die ("multiple projects named '" <> Text.unpack name <> "': " <> show multi)

emitJson :: Aeson.ToJSON a => a -> IO ()
emitJson = LC8.putStrLn . Pretty.encodePretty

printProject :: Api.Project -> IO ()
printProject p =
  putStrLn (Text.unpack p.id <> "  " <> Text.unpack p.name <> "  (" <> Text.unpack p.createdAt <> ")")

printSnap :: Api.SnapshotSummary -> IO ()
printSnap s =
  putStrLn (Text.unpack s.id <> "  (" <> Text.unpack s.createdAt <> ")")

printAgent :: Api.AgentRow -> IO ()
printAgent a =
  putStrLn
    ( Text.unpack a.id
        <> "  "
        <> show a.state
        <> "  "
        <> Text.unpack a.qualifiedName
        <> "  ("
        <> Text.unpack a.updatedAt
        <> ")"
    )

printDef :: Api.AgentDefinition -> IO ()
printDef d =
  putStrLn
    ( Text.unpack d.qualifiedName
        <> maybe "" (\desc -> "  — " <> Text.unpack desc) d.description
    )
