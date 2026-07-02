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
-- inline (the human-in-the-loop core case closes inside one @katari run@); non-interactively each is
-- announced once with the @katari answer@ command that resolves it. Ctrl-C detaches — the run keeps
-- going server-side — and exits 130 after printing how to pick it back up.
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
    EscalationView (..),
    RunView (..),
    StartRunRequest (..),
    answerEscalation,
    getAgent,
    getRun,
    listAgents,
    listEscalations,
    startRun,
  )
import Katari.Cli.Common (RuntimeContext (..), dieIn, dieProgram, exitInterrupted, withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (OutputContext (..), hint, printJson, printText, progress)
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
    <*> switch (long "all" <> help "Include primitive.* callables in the interactive agent picker")

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
    visible view = options.includePrimitives || not ("primitive." `Text.isPrefixOf` view.qualifiedName)

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

-- | Poll until the run reaches a terminal state, surfacing its open escalations along the way. The
-- interval backs off to a 2s ceiling; there is no overall timeout — a long-running orchestration is
-- normal, and Ctrl-C detaches.
waitForRun :: RuntimeContext -> Text -> IO ()
waitForRun context runId = loop initialDelayMicroseconds Set.empty
  where
    initialDelayMicroseconds = 100000
    ceilingMicroseconds = 2000000

    loop delay notified = do
      view <- getRun context.client context.projectId runId
      case view.state of
        "done" -> printJson (fromMaybe Null view.result)
        "error" -> dieProgram "run" ("run failed: " <> fromMaybe "(no message)" view.errorMessage)
        "cancelled" -> dieProgram "run" "run was cancelled"
        _ -> do
          (_, escalations) <- listEscalations context.client context.projectId
          let mine = filter (\escalation -> escalation.runId == runId) escalations
          notifiedNow <- foldM (surfaceEscalation context) notified mine
          threadDelay delay
          loop (min (delay * 2) ceilingMicroseconds) notifiedNow

-- | Bring one open escalation to the user: answer it inline on a terminal, otherwise announce it
-- once (the set remembers which ids have been announced or declined).
surfaceEscalation :: RuntimeContext -> Set Text -> EscalationView -> IO (Set Text)
surfaceEscalation context notified escalation
  | Set.member escalation.id notified = pure notified
  | context.output.interactive = do
      progress context.output ""
      progress context.output ("The run is asking " <> escalation.request <> maybe "" (\question -> ": " <> compactJson question) escalation.argument)
      answered <- promptAnswer context escalation
      case answered of
        Just answerValue -> do
          answerEscalation context.client context.projectId escalation.id answerValue
          progress context.output "Answered; waiting on the run again..."
          hint context.output ("katari answer " <> escalation.id <> " --value '" <> compactJson answerValue <> "'")
        Nothing ->
          progress context.output ("Left unanswered — pick it up later: katari answer " <> Text.take 8 escalation.id)
      pure (Set.insert escalation.id notified)
  | otherwise = do
      progress context.output ("Run is waiting on " <> escalation.request <> " — answer with: katari answer " <> Text.take 8 escalation.id)
      pure (Set.insert escalation.id notified)

-- | Interview for the answer using the runtime-derived schema, degrading to raw JSON input when no
-- schema came through (an undecodable or missing entry).
promptAnswer :: RuntimeContext -> EscalationView -> IO (Maybe Value)
promptAnswer context escalation = promptFromSchema context.output ["answer"] answerSchema
  where
    answerSchema = case escalation.answerSchema of
      Nothing -> SchemaAny
      Just raw -> case Aeson.fromJSON raw of
        Aeson.Success schema -> schema
        Aeson.Error _ -> SchemaAny
