-- | @katari status [RUN]@ — one run's full management view, plus anything it is waiting on.
--
-- The run may be named by a unique id prefix; omitted on a terminal, a picker over recent runs
-- opens. Open escalations raised by this run render beneath the detail with the @katari answer@
-- command that resolves each — the "why is my run stuck" question answered in one screen.
module Katari.Cli.Command.Status
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Monad (forM_, unless)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Cli.Api (EscalationView (..), RunDetail (..), getRunDetail, listEscalations)
import Katari.Cli.Common (RuntimeContext (..), withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (compactTimestamp, printJson, printText, progress)
import Katari.Cli.Pick (resolveRunId)
import Katari.Cli.Prompt (compactJson)
import Options.Applicative

data Options = Options
  { global :: GlobalOptions,
    projectName :: Maybe Text,
    runId :: Maybe Text,
    json :: Bool
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
              <> help "Project the run belongs to (default: the surrounding katari.toml's [package].name)"
          )
      )
    <*> optional (strArgument (metavar "RUN" <> help "Run id, or a unique prefix of one (omit to pick interactively)"))
    <*> switch (long "json" <> help "Print the raw run JSON instead of the readable view")

run :: Options -> IO ()
run options = do
  context <- withRuntimeContext "status" options.global options.projectName
  target <- resolveRunId "status" context options.runId Nothing
  (raw, detail) <- getRunDetail context.client context.projectId target
  if options.json
    then printJson raw
    else do
      renderDetail detail
      (_, escalations) <- listEscalations context.client context.projectId
      let waiting = filter (\escalation -> escalation.runId == target) escalations
      unless (null waiting) $ do
        printText ""
        printText "Waiting on:"
        forM_ waiting $ \escalation ->
          printText
            ( "  "
                <> escalation.request
                <> maybe "" (\question -> " " <> compactJson question) escalation.argument
                <> "  — answer with: katari answer "
                <> Text.take 8 escalation.id
            )
      progress context.output ""

renderDetail :: RunDetail -> IO ()
renderDetail detail = do
  field "Run" detail.id
  field "Name" detail.name
  field "Agent" detail.qualifiedName
  field "State" detail.state
  field "Snapshot" (fromMaybe "(head at start)" detail.snapshotId)
  field "Argument" (maybe "(none)" compactJson detail.argument)
  field "Result" (maybe "(none)" compactJson detail.result)
  field "Error" (fromMaybe "(none)" detail.errorMessage)
  field "Cancel reason" (fromMaybe "(none)" detail.cancelReason)
  field "Created" (compactTimestamp detail.createdAt)
  field "Completed" (maybe "(not yet)" compactTimestamp detail.completedAt)
  where
    field label content = printText (Text.justifyLeft 14 ' ' label <> content)
