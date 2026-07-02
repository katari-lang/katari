-- | @katari ls [TARGET]@ — the read side of every resource, under one verb with uniform flags.
--
-- Targets: @runs@ (the default — the listing reached for most), @agents@, @snapshots@, @projects@,
-- @escalations@, @files@, @env@. Human output is an aligned table on stdout; @--json@ prints the
-- runtime's payload verbatim. Ids render shortened — every command that takes an id accepts a unique
-- prefix, so the 8-character form is directly usable.
module Katari.Cli.Command.Ls
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.Aeson qualified as Aeson
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Cli.Api
  ( AgentView (..),
    AgentsResponse (..),
    EnvEntry (..),
    EscalationView (..),
    FileRow (..),
    ProjectRow (..),
    RunDetail (..),
    RunListQuery (..),
    SnapshotRow (..),
    listAgents,
    listEnv,
    listEscalations,
    listFiles,
    listProjects,
    listRuns,
    listSnapshots,
  )
import Katari.Cli.Common (RuntimeContext (..), dieIn, makeRuntimeClient, tryLoadNearestConfig, withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (compactTimestamp, newOutputContext, printJson, printText, renderTable)
import Katari.Cli.Prompt (compactJson, renderSchemaBrief)
import Katari.Data.JSONSchema (JSONSchema)
import Options.Applicative

-- | What to list.
data Target
  = TargetRuns
  | TargetAgents
  | TargetSnapshots
  | TargetProjects
  | TargetEscalations
  | TargetFiles
  | TargetEnv
  deriving stock (Show, Eq)

data Options = Options
  { global :: GlobalOptions,
    projectName :: Maybe Text,
    target :: Maybe Text,
    json :: Bool,
    -- | @runs@ only: restrict to one lifecycle state.
    state :: Maybe Text,
    -- | @runs@ only: how many to show (newest first).
    limit :: Maybe Int,
    -- | @agents@ only: include the @primitive.*@ stdlib callables.
    includePrimitives :: Bool,
    -- | @agents@ only: read a pinned snapshot instead of the head.
    snapshotId :: Maybe Text
  }
  deriving stock (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> globalOptionsParser
    <*> optional
      ( strOption
          ( long "project"
              <> metavar "NAME"
              <> help "Project to list under (default: the surrounding katari.toml's [package].name)"
          )
      )
    <*> optional
      ( strArgument
          ( metavar "TARGET"
              <> help "One of: runs (default), agents, snapshots, projects, escalations, files, env"
          )
      )
    <*> switch (long "json" <> help "Print the runtime's JSON payload instead of a table")
    <*> optional (strOption (long "state" <> metavar "STATE" <> help "runs: only this state (running|cancelling|done|error|cancelled)"))
    <*> optional (option auto (long "limit" <> metavar "N" <> help "runs: show at most N, newest first (default 20)"))
    <*> switch (long "all" <> help "agents: include prelude.* callables")
    <*> optional (strOption (long "snapshot" <> short 's' <> metavar "ID" <> help "agents: read this snapshot instead of the head"))

run :: Options -> IO ()
run options = do
  target <- parseTarget (fromMaybe "runs" options.target)
  case target of
    -- Listing projects is the one target that must work before any project is deployed, so it wires
    -- its own client instead of resolving a project id.
    TargetProjects -> do
      output <- newOutputContext options.global
      config <- tryLoadNearestConfig "ls"
      client <- makeRuntimeClient "ls" options.global output config
      (raw, projects) <- listProjects client
      emit options raw $
        table
          ["ID", "NAME", "DESCRIPTION", "CREATED"]
          [[shortId project.id, project.name, fromMaybe "" project.description, compactTimestamp (fromMaybe "" project.createdAt)] | project <- projects]
    _ -> do
      context <- withRuntimeContext "ls" options.global options.projectName
      case target of
        TargetRuns -> do
          (raw, runs) <-
            listRuns context.client context.projectId RunListQuery {state = options.state, limit = Just (fromMaybe 20 options.limit)}
          emit options raw $
            table
              ["ID", "STATE", "AGENT", "NAME", "CREATED", "COMPLETED"]
              [ [shortId row.id, row.state, row.qualifiedName, row.name, compactTimestamp row.createdAt, maybe "" compactTimestamp row.completedAt]
                | row <- runs
              ]
        TargetAgents -> do
          (raw, response) <- listAgents context.client context.projectId options.snapshotId
          let visible view = options.includePrimitives || not ("prelude." `Text.isPrefixOf` view.qualifiedName)
          emit options raw $
            table
              ["AGENT", "INPUT", "OUTPUT"]
              [[view.qualifiedName, briefSchema view.input, briefSchema view.output] | view <- response.agents, visible view]
        TargetSnapshots -> do
          (raw, snapshots) <- listSnapshots context.client context.projectId
          emit options raw $
            table
              ["ID", "MESSAGE", "CREATED"]
              [[shortId row.id, fromMaybe "" row.message, compactTimestamp row.createdAt] | row <- snapshots]
        TargetEscalations -> do
          (raw, escalations) <- listEscalations context.client context.projectId
          emit options raw $
            table
              ["ID", "RUN", "REQUEST", "QUESTION", "CREATED"]
              [ [shortId row.id, shortId row.runId, row.request, maybe "" (preview . compactJson) row.argument, compactTimestamp row.createdAt]
                | row <- escalations
              ]
        TargetFiles -> do
          (raw, files) <- listFiles context.client context.projectId
          emit options raw $
            table
              ["ID", "SIZE", "CONTENT-TYPE", "KIND"]
              [[shortId row.id, Text.pack (show row.size), fromMaybe "" row.contentType, fromMaybe "" row.semanticKind] | row <- files]
        TargetEnv -> do
          (raw, entries) <- listEnv context.client context.projectId
          emit options raw $
            table
              ["KEY", "SECRET", "UPDATED"]
              [[entry.key, if entry.isSecret then "yes" else "", compactTimestamp (fromMaybe "" entry.updatedAt)] | entry <- entries]

parseTarget :: Text -> IO Target
parseTarget word = case word of
  "runs" -> pure TargetRuns
  "agents" -> pure TargetAgents
  "snapshots" -> pure TargetSnapshots
  "projects" -> pure TargetProjects
  "escalations" -> pure TargetEscalations
  "files" -> pure TargetFiles
  "env" -> pure TargetEnv
  other -> dieIn "ls" ("unknown target '" <> other <> "' (expected runs, agents, snapshots, projects, escalations, files or env)")

-- | Route to @--json@ (verbatim payload) or the rendered table.
emit :: Options -> Aeson.Value -> Text -> IO ()
emit options raw rendered
  | options.json = printJson raw
  | otherwise = printText rendered

table :: List Text -> List (List Text) -> Text
table = renderTable

shortId :: Text -> Text
shortId = Text.take 8

-- | One cell must not wreck the table: long JSON previews truncate.
preview :: Text -> Text
preview text
  | Text.length text > 40 = Text.take 37 text <> "..."
  | otherwise = text

-- | A schema cell: the decoded brief form, or a shrug when the document does not decode (version skew).
briefSchema :: Aeson.Value -> Text
briefSchema document = case Aeson.fromJSON document of
  Aeson.Success (schema :: JSONSchema) -> renderSchemaBrief schema
  Aeson.Error _ -> "(unreadable schema)"
