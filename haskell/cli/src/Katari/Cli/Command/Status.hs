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

import Control.Monad (forM_, unless, when)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Cli.Api (EscalationView (..), RunDetail (..), RunEventView (..), RunEventsQuery (..), getRunDetail, listAllRunEvents, listEscalations)
import Katari.Cli.Common (RuntimeContext (..), withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (compactTime, compactTimestamp, printJson, printText)
import Katari.Cli.Pick (resolveRunId)
import Katari.Cli.Prompt (compactJson)
import Options.Applicative

data Options = Options
  { global :: GlobalOptions,
    projectName :: Maybe Text,
    runId :: Maybe Text,
    json :: Bool,
    search :: Maybe Text,
    kind :: Maybe Text
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
    <*> optional
      ( strOption
          ( long "search"
              <> metavar "TEXT"
              <> help "Show only trace events matching TEXT (a case-insensitive substring over each event — its ids, targets, request names, and public payload text)"
          )
      )
    <*> optional
      ( strOption
          ( long "kind"
              <> metavar "KIND"
              <> help "Show only trace events of KIND (delegate | delegateAck | escalate | escalateAck | terminate | terminateAck)"
          )
      )

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
      renderTrace context target (RunEventsQuery {search = options.search, kind = options.kind})

-- | The run's execution trace (its journaled external events), the "what actually happened" half of
-- the status screen. Unfiltered it shows only the newest tail (the full trace is one `GET .../events`
-- away); with a @--search@ / @--kind@ filter it shows *every* match, oldest first — a focused debugger
-- view where truncating to a tail would hide the events you searched for.
renderTrace :: RuntimeContext -> Text -> RunEventsQuery -> IO ()
renderTrace context target query = do
  (_, events) <- listAllRunEvents context.client context.projectId target query
  let filtering = isJust query.search || isJust query.kind
  if filtering
    then do
      printText ""
      printText ("Trace matches (" <> Text.pack (show (length events)) <> "):")
      if null events
        then printText "  (no events match)"
        else forM_ events $ \event ->
          printText ("  " <> compactTime event.createdAt <> "  " <> event.summary)
    else unless (null events) $ do
      let shown = drop (length events - traceTailLength) events
          earlierCount = length events - length shown
      printText ""
      printText "Trace:"
      when (earlierCount > 0) $
        printText ("  (… " <> Text.pack (show earlierCount) <> " earlier events)")
      forM_ shown $ \event ->
        printText ("  " <> compactTime event.createdAt <> "  " <> event.summary)

-- | How many trace events `status` shows — enough to see how a run ended without flooding the screen.
traceTailLength :: Int
traceTailLength = 20

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
