-- | @katari run [AGENT]@ — start an agent and (by default) stay with it until it finishes.
--
-- The command's two personalities:
--
--   * /Deterministic/: @katari run main.main --arg '{"x":1}'@ starts the run, waits, and prints the
--     result JSON alone on stdout. Exit 0 on @done@, 1 on @error@ / @cancelled@.
--   * /Interactive/: omit the agent to pick one from a menu; omit @--arg@ to be interviewed through
--     the agent's input schema. After the interview the equivalent deterministic command is echoed,
--     so the interactive session teaches the scriptable form.
--
-- While waiting, the run's own open escalations surface here: on a terminal they are answered
-- inline (the human-in-the-loop core case closes inside one @katari run@); non-interactively a
-- human-answerable escalation would block forever, so the wait fails fast (exit 2) and names the
-- @katari answer@ command that resolves it. Ctrl-C detaches — the run keeps going server-side — and
-- exits 130 after printing how to pick it back up.
module Katari.Cli.Command.Run
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (AsyncException (..), catch, throwIO)
import Control.Monad (foldM, when)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Katari.Cli.Api
  ( AgentView (..),
    AgentsResponse (..),
    EscalationPresentation (..),
    EscalationView (..),
    RunEventView (..),
    RunEventsResponse (..),
    RunView (..),
    StartRunRequest (..),
    answerEscalation,
    emptyRunEventsQuery,
    getAgent,
    getRun,
    listAgents,
    listEscalations,
    listRunEvents,
    oauthTargetDescription,
    startRun,
  )
import Katari.Cli.Common (RuntimeContext (..), dieIn, dieProgram, exitInterrupted, withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (OutputContext (..), compactTime, hint, printJson, printText, progress, traceLine)
import Katari.Cli.Prompt (compactJson, promptFromSchema, select)
import Katari.Data.JSONSchema (JSONSchema (..), ObjectSchema (..))
import Options.Applicative

data Options = Options
  { global :: GlobalOptions,
    projectName :: Maybe Text,
    agent :: Maybe Text,
    argumentJson :: Maybe Text,
    label :: Maybe Text,
    snapshotId :: Maybe Text,
    detach :: Bool,
    includePrimitives :: Bool
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
              <> help "Project to run under (default: the surrounding katari.toml's [package].name)"
          )
      )
    <*> optional (strArgument (metavar "AGENT" <> help "Qualified agent name, e.g. main.main (omit to pick interactively)"))
    <*> optional
      ( strOption
          ( long "arg"
              <> short 'a'
              <> metavar "JSON"
              <> help "The argument record as JSON, e.g. '{\"x\":1}' (omit to be prompted per parameter)"
          )
      )
    <*> optional (strOption (long "name" <> metavar "NAME" <> help "A human label for the run record (default: the agent name)"))
    <*> optional (strOption (long "snapshot" <> short 's' <> metavar "ID" <> help "Pin the run to a snapshot id (default: the project head)"))
    <*> switch (long "detach" <> help "Start the run and print its id instead of waiting for the result")
    <*> switch (long "all" <> help "Include prelude.* callables in the interactive agent picker")

run :: Options -> IO ()
run options = do
  context <- withRuntimeContext "run" options.global options.projectName
  (qualifiedName, runArgument) <- resolveAgentAndArgument context options
  runId <-
    startRun
      context.client
      context.projectId
      StartRunRequest
        { qualifiedName = qualifiedName,
          name = options.label,
          snapshotId = options.snapshotId,
          argument = runArgument
        }
  if options.detach
    then do
      progress context.output ("Started run " <> runId)
      hint context.output ("katari status " <> Text.take 8 runId)
      printText runId
    else do
      progress context.output ("Started run " <> runId <> " (Ctrl-C detaches; the run keeps going)")
      waitForRun context runId `catch` \case
        UserInterrupt -> do
          progress context.output ""
          progress context.output ("Detached. Still running: katari status " <> Text.take 8 runId <> " | katari cancel " <> Text.take 8 runId)
          exitInterrupted
        other -> throwIO (other :: AsyncException)

-- ===========================================================================
-- Agent + argument resolution
-- ===========================================================================

-- | Settle which agent runs and with what argument, prompting only for the parts that are missing
-- (and only on a terminal). After any prompting, echo the deterministic equivalent.
resolveAgentAndArgument :: RuntimeContext -> Options -> IO (Text, Maybe Value)
resolveAgentAndArgument context options = do
  (qualifiedName, inputSchema, picked) <- resolveAgent context options
  case options.argumentJson of
    Just argumentText -> do
      parsed <- parseArgument argumentText
      pure (qualifiedName, Just parsed)
    Nothing -> do
      schema <- decodeInputSchema inputSchema
      (chosenArgument, prompted) <- argumentForSchema context qualifiedName schema
      -- Echo the scriptable form only when something was actually answered interactively (an
      -- auto-filled empty record is not an interaction worth teaching).
      when (picked || prompted) $
        hint context.output $
          "katari run " <> qualifiedName <> maybe "" (\chosen -> " --arg '" <> compactJson chosen <> "'") chosenArgument
      pure (qualifiedName, chosenArgument)

-- | The chosen agent's name and input schema; the 'Bool' notes whether a picker ran (for the echo).
-- With an explicit name the schema is fetched only when it will be needed (no @--arg@).
resolveAgent :: RuntimeContext -> Options -> IO (Text, Value, Bool)
resolveAgent context options = case options.agent of
  Just qualifiedName
    | Just _ <- options.argumentJson ->
        -- Fully specified: no schema fetch, no prompting, no extra round trip.
        pure (qualifiedName, Aeson.object [], False)
    | otherwise -> do
        agentView <- getAgent context.client context.projectId qualifiedName options.snapshotId
        pure (qualifiedName, agentView.input, False)
  Nothing
    | context.output.interactive -> do
        (_, response) <- listAgents context.client context.projectId options.snapshotId
        let candidates = filter visible response.agents
        case candidates of
          [] -> dieIn "run" "this snapshot exposes no runnable agents"
          _ -> do
            chosen <- select context.output "Run which agent?" [(view.qualifiedName, view) | view <- candidates]
            case chosen of
              Just view -> pure (view.qualifiedName, view.input, True)
              Nothing -> dieIn "run" "cancelled"
    | otherwise -> dieIn "run" "no agent given (pass AGENT, or run interactively)"
  where
    visible view = options.includePrimitives || not ("prelude." `Text.isPrefixOf` view.qualifiedName)

-- | Decide the argument from the input schema alone (no @--arg@ was given): an agent whose
-- parameters are all optional runs on its defaults; required parameters start the interview on a
-- terminal and are a hard error off one. The 'Bool' says whether an interview actually ran.
argumentForSchema :: RuntimeContext -> Text -> JSONSchema -> IO (Maybe Value, Bool)
argumentForSchema context qualifiedName schema = case schema of
  SchemaObject objectSchema
    | null objectSchema.required ->
        -- All parameters have defaults; an explicit empty record lets the runtime fill them.
        pure (Just (Object KeyMap.empty), False)
  _
    | context.output.interactive -> do
        answered <- promptFromSchema context.output ["arg"] schema
        case answered of
          Just answeredArgument -> pure (Just answeredArgument, True)
          Nothing -> dieIn "run" "cancelled"
    | otherwise ->
        dieIn "run" (qualifiedName <> " has required parameters; pass --arg '<json>'")

parseArgument :: Text -> IO Value
parseArgument text = case Aeson.eitherDecodeStrict' (TextEncoding.encodeUtf8 text) of
  Left decodeError -> dieIn "run" ("--arg is not valid JSON: " <> Text.pack decodeError)
  Right decoded -> pure decoded

-- | An agent's input schema arrives as the raw wire document; decode it into the typed schema the
-- interview walks. This is our own compiler's output, so a mismatch means version skew, not user error.
decodeInputSchema :: Value -> IO JSONSchema
decodeInputSchema document = case Aeson.fromJSON document of
  Aeson.Success schema -> pure schema
  Aeson.Error message -> dieIn "run" ("could not read the agent's input schema (CLI/runtime version skew?): " <> Text.pack message)

-- ===========================================================================
-- Waiting on the run
-- ===========================================================================

-- | Poll until the run reaches a terminal state, tailing its execution trace (each external event the
-- engine journals prints as a dim one-line summary on stderr) and surfacing its open escalations along
-- the way. The interval backs off to a 2s ceiling; there is no overall timeout — a long-running
-- orchestration is normal, and Ctrl-C detaches.
waitForRun :: RuntimeContext -> Text -> IO ()
waitForRun context runId = loop initialDelayMicroseconds Set.empty 0
  where
    initialDelayMicroseconds = 100000
    ceilingMicroseconds = 2000000

    loop delay notified lastSeq = do
      -- One events poll serves both needs: the new trace lines AND the run's lifecycle state — read from
      -- the same response, so the terminal turn's final events always print before the exit path runs.
      (state, seqNow) <- drainTrace lastSeq
      case state of
        "done" -> do
          view <- getRun context.client context.projectId runId
          printJson (fromMaybe Null view.result)
        "error" -> do
          view <- getRun context.client context.projectId runId
          dieProgram "run" ("run failed: " <> fromMaybe "(no message)" view.errorMessage)
        "cancelled" -> dieProgram "run" "run was cancelled"
        _ -> do
          (_, escalations) <- listEscalations context.client context.projectId
          let mine = filter (\escalation -> escalation.runId == runId) escalations
          notifiedNow <- foldM (surfaceEscalation context) notified mine
          threadDelay delay
          loop (min (delay * 2) ceilingMicroseconds) notifiedNow seqNow

    -- Print every trace event past `lastSeq`, following full pages until the tail is drained (the
    -- endpoint returns one server-capped page per call), and return the run's state as of the last page
    -- with the new tail cursor.
    drainTrace lastSeq = do
      -- The live tail is unfiltered: it streams every event as it lands.
      (_, trace) <- listRunEvents context.client context.projectId runId emptyRunEventsQuery lastSeq
      mapM_ (printEvent context.output) trace.events
      case trace.events of
        [] -> pure (trace.state, lastSeq)
        events -> drainTrace (maximum (map (.seq) events))

-- | One trace event as a dim stderr line: @HH:MM:SS@ + the server-rendered summary.
printEvent :: OutputContext -> RunEventView -> IO ()
printEvent output event = traceLine output (compactTime event.createdAt <> " " <> event.summary)

-- | Bring one open escalation to the user, dispatching on its presentation so the two kinds surface in
-- their own way (never on the request name).
surfaceEscalation :: RuntimeContext -> Set Text -> EscalationView -> IO (Set Text)
surfaceEscalation context notified escalation
  | Set.member escalation.id notified = pure notified
  | otherwise = case escalation.presentation of
      PresentationForm rawAnswerSchema -> surfaceForm context notified escalation rawAnswerSchema
      PresentationOauth {url, name} -> surfaceOauth context notified escalation url name

-- | A form escalation surfaced mid-run: answer it inline on a terminal (the human-in-the-loop core
-- case closes inside one @katari run@). Off a terminal there is no one to answer it in this session and
-- the run cannot progress without an answer, so rather than poll forever the wait fails fast (exit 2)
-- naming the command that resolves it elsewhere.
surfaceForm :: RuntimeContext -> Set Text -> EscalationView -> Maybe Value -> IO (Set Text)
surfaceForm context notified escalation rawAnswerSchema
  | context.output.interactive = do
      progress context.output ""
      progress context.output ("The run is asking " <> escalation.request <> maybe "" (\question -> ": " <> compactJson question) escalation.argument)
      answered <- promptAnswer context rawAnswerSchema
      case answered of
        Just answerValue -> do
          answerEscalation context.client context.projectId escalation.id answerValue
          -- The answer is already submitted, so no scriptable hint is echoed here: it would only
          -- leak the just-entered value (potentially a secret) into the terminal scrollback.
          progress context.output "Answered; waiting on the run again..."
        Nothing ->
          progress context.output ("Left unanswered — pick it up later: katari answer " <> Text.take 8 escalation.id)
      pure (Set.insert escalation.id notified)
  | otherwise =
      dieIn
        "run"
        ( "the run is waiting on "
            <> escalation.request
            <> " and needs a human answer; answer it from another session with `katari answer "
            <> Text.take 8 escalation.id
            <> "`, or re-run with --detach and answer it later"
        )

-- | An oauth escalation surfaced mid-run: point at @katari answer@ rather than driving the flow here.
-- The browser round-trip and its poll loop would freeze this run's live trace tail, so authorization
-- belongs in a separate process; the wait keeps tailing and resumes automatically once it completes.
-- Off a terminal there is likewise no one to authorize in this session, so it fails fast the same way.
surfaceOauth :: RuntimeContext -> Set Text -> EscalationView -> Maybe Text -> Text -> IO (Set Text)
surfaceOauth context notified escalation serverUrl credentialName
  | context.output.interactive = do
      progress context.output ""
      progress context.output ("The run needs OAuth authorization for " <> oauthTargetDescription serverUrl credentialName <> "; authorize it from another session with `katari answer " <> Text.take 8 escalation.id <> "` — the run resumes automatically")
      pure (Set.insert escalation.id notified)
  | otherwise =
      dieIn
        "run"
        ( "the run needs OAuth authorization for "
            <> oauthTargetDescription serverUrl credentialName
            <> "; authorize it from another session with `katari answer "
            <> Text.take 8 escalation.id
            <> "`, or re-run with --detach and authorize it later"
        )

-- | Interview for the answer using the runtime-derived schema, degrading to raw JSON input when no
-- schema came through (an undecodable or missing entry).
promptAnswer :: RuntimeContext -> Maybe Value -> IO (Maybe Value)
promptAnswer context rawAnswerSchema = promptFromSchema context.output ["answer"] answerSchema
  where
    answerSchema = case rawAnswerSchema of
      Nothing -> SchemaAny
      Just raw -> case Aeson.fromJSON raw of
        Aeson.Success schema -> schema
        Aeson.Error _ -> SchemaAny
