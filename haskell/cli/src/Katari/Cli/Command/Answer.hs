-- | @katari answer [ESCALATION]@ — answer a question a run escalated to its operator.
--
-- The escalation may be a unique id prefix; omitted on a terminal, a picker over the open escalations
-- opens. What "answer" means is decided by the escalation's presentation — a sum the runtime folds at
-- its boundary — so the command dispatches on that once and never sniffs the request name:
--
--   * a @form@ escalation takes a value, from @--value@ (deterministic) or, interactively, from an
--     interview over the request's answer schema (the runtime derives it from the run's snapshot IR, so
--     the prompt destructures exactly the record the program expects back);
--   * an @oauth@ escalation takes no value at all: the CLI starts the runtime-hosted OAuth flow, opens
--     the authorization URL, and waits for the run to resume once the browser round-trip completes.
--     @--value@ is meaningless here and is ignored — the behaviour is one per kind.
module Katari.Cli.Command.Answer
  ( Options (..),
    optionsParser,
    run,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Katari.Cli.Api (EscalationPresentation (..), EscalationView (..), answerEscalation, listEscalations, oauthTargetDescription, startOauthEscalationFlow)
import Katari.Cli.Common (RuntimeContext (..), dieIn, dieProgram, withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (OutputContext (..), printText, progress)
import Katari.Cli.Pick (resolveEscalation)
import Katari.Cli.Prompt (compactJson, promptFromSchema)
import Katari.Data.JSONSchema (JSONSchema (..))
import Options.Applicative
import System.IO (Handle)
import System.Info (os)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, proc)

data Options = Options
  { global :: GlobalOptions,
    projectName :: Maybe Text,
    escalationId :: Maybe Text,
    valueJson :: Maybe Text
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
              <> help "Project the escalation belongs to (default: the surrounding katari.toml's [package].name)"
          )
      )
    <*> optional (strArgument (metavar "ESCALATION" <> help "Escalation id, or a unique prefix of one (omit to pick interactively)"))
    <*> optional (strOption (long "value" <> metavar "JSON" <> help "The answer as JSON (form escalations only; ignored for an OAuth authorization, omit to be prompted through the answer schema)"))

run :: Options -> IO ()
run options = do
  context <- withRuntimeContext "answer" options.global options.projectName
  escalation <- resolveEscalation "answer" context options.escalationId
  -- The presentation decides what answering means; branch on it once (never on the request name).
  case escalation.presentation of
    PresentationForm answerSchema -> answerForm context escalation answerSchema options.valueJson
    PresentationOauth {url, name} -> answerOauth context escalation url name

-- ===========================================================================
-- Form escalations
-- ===========================================================================

-- | Submit a value for a form escalation, then echo the id (a plain listing line for scripts). The
-- value comes from @--value@ when given, otherwise an interactive interview over the answer schema.
answerForm :: RuntimeContext -> EscalationView -> Maybe Value -> Maybe Text -> IO ()
answerForm context escalation rawAnswerSchema valueJson = do
  answerValue <- resolveFormValue context escalation rawAnswerSchema valueJson
  answerEscalation context.client context.projectId escalation.id answerValue
  -- No scriptable hint is echoed on success: the answer is already submitted, and re-printing it with
  -- @--value@ would leak the just-entered value (potentially a secret) into the terminal scrollback.
  progress context.output ("Answered " <> escalation.id)
  printText escalation.id

-- | The answer value: parsed from @--value@ when given; otherwise an interactive interview over the
-- runtime-derived answer schema (raw JSON input when no schema came through).
resolveFormValue :: RuntimeContext -> EscalationView -> Maybe Value -> Maybe Text -> IO Value
resolveFormValue context escalation rawAnswerSchema valueJson = case valueJson of
  Just text -> case Aeson.eitherDecodeStrict' (TextEncoding.encodeUtf8 text) of
    Left decodeError -> dieIn "answer" ("--value is not valid JSON: " <> Text.pack decodeError)
    Right decoded -> pure decoded
  Nothing
    | context.output.interactive -> do
        progress context.output ("Question (" <> escalation.request <> ")" <> maybe "" (\question -> ": " <> compactJson question) escalation.argument)
        answered <- promptFromSchema context.output ["answer"] answerSchema
        case answered of
          Just given -> pure given
          Nothing -> dieIn "answer" "cancelled"
    | otherwise -> dieIn "answer" "no --value given (pass one, or run interactively)"
  where
    answerSchema = case rawAnswerSchema of
      Nothing -> SchemaAny
      Just raw -> case Aeson.fromJSON raw of
        Aeson.Success schema -> schema
        Aeson.Error _ -> SchemaAny

-- ===========================================================================
-- OAuth escalations
-- ===========================================================================

-- | Drive the runtime-hosted OAuth flow to completion: start it for the authorization URL, print and
-- best-effort open that URL, then poll until the escalation disappears (the redirect callback answers
-- it) and dispatch on what the disappearance meant. No value is ever submitted, so @--value@ plays no
-- part here.
answerOauth :: RuntimeContext -> EscalationView -> Maybe Text -> Text -> IO ()
answerOauth context escalation serverUrl credentialName = do
  authorizationUrl <- startOauthEscalationFlow context.client context.projectId escalation.id
  progress context.output ("Authorize " <> oauthTargetDescription serverUrl credentialName <> " in your browser:")
  progress context.output ("  " <> authorizationUrl)
  openInBrowser authorizationUrl
  progress context.output "Waiting for authorization to complete (Ctrl-C stops waiting; the escalation stays open)..."
  outcome <- waitForAuthorization context escalation.id serverUrl credentialName
  case outcome of
    AuthorizationCompleted -> do
      progress context.output "Authorized — the run resumes."
      printText escalation.id
    AuthorizationReopened successorId ->
      dieProgram
        "answer"
        ( "the authorization did not take — the run asked again for "
            <> oauthTargetDescription serverUrl credentialName
            <> "; retry with `katari answer "
            <> Text.take 8 successorId
            <> "` (e.g. with a different account)"
        )

-- | What the vanished escalation row meant. The row disappears on any answer — including a callback
-- that deposited an unusable credential (the raiser re-reads the store and escalates afresh) and a
-- cancelled run — so "gone" alone is not success; the successor check below tells the cases apart.
data AuthorizationOutcome
  = -- | No successor escalation for the same server / credential: the authorization stuck.
    AuthorizationCompleted
  | -- | The raiser asked again for the same server / credential under a new escalation id: the
    -- deposited credential still did not work (wrong account, revoked grant, ...).
    AuthorizationReopened Text

-- | Best-effort open of the authorization URL in the user's browser: @open@ on macOS, @xdg-open@
-- elsewhere. The URL is already printed, so a headless box (no opener on PATH) or a spawn failure is
-- fine to swallow — it must not derail the wait. The opener's streams are discarded so it stays silent.
openInBrowser :: Text -> IO ()
openInBrowser targetUrl = do
  let opener = if os == "darwin" then "open" else "xdg-open"
      spawn = createProcess (proc opener [Text.unpack targetUrl]) {std_in = NoStream, std_out = NoStream, std_err = NoStream}
  _ <- (try spawn :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)))
  pure ()

-- | Poll the open escalations until this one is gone (answered by the OAuth redirect callback), then
-- list once more and dispatch on what is there: a new open oauth escalation for the same server /
-- credential means the raiser re-read the store after the ack and re-escalated, i.e. the authorization
-- did not take; none means it stuck. One rule — the successor check — covers every "gone but not
-- fixed" cause without special-casing them. A generous overall cap keeps a forgotten browser tab from
-- hanging the terminal forever; hitting it is not a failure of the run, so it exits with the
-- actionable "re-run once authorized" message.
waitForAuthorization :: RuntimeContext -> Text -> Maybe Text -> Text -> IO AuthorizationOutcome
waitForAuthorization context escalationId serverUrl credentialName = go oauthWaitAttempts
  where
    go remaining
      | remaining <= 0 =
          dieIn
            "answer"
            ( "timed out after 10 minutes waiting for authorization; the escalation is still open — re-run `katari answer "
                <> Text.take 8 escalationId
                <> "` once you have authorized in the browser"
            )
      | otherwise = do
          (_, escalations) <- listEscalations context.client context.projectId
          if any (\escalation -> escalation.id == escalationId) escalations
            then do
              threadDelay oauthPollIntervalMicroseconds
              go (remaining - 1)
            else do
              -- The row is gone; a fresh listing (not the one that noticed) gives the raiser's
              -- re-execution its best chance to have re-escalated before we judge the outcome.
              (_, afterAnswer) <- listEscalations context.client context.projectId
              case filter isSuccessor afterAnswer of
                (successor : _) -> pure (AuthorizationReopened successor.id)
                [] -> pure AuthorizationCompleted
    -- A successor is any open oauth escalation for the same server and credential name. Its id is
    -- necessarily new — the original row is already gone.
    isSuccessor escalation = case escalation.presentation of
      PresentationOauth {url, name} -> url == serverUrl && name == credentialName
      PresentationForm _ -> False

-- | How often 'waitForAuthorization' re-lists the open escalations (2 seconds).
oauthPollIntervalMicroseconds :: Int
oauthPollIntervalMicroseconds = 2 * 1000 * 1000

-- | How many polls 'waitForAuthorization' tolerates before giving up — 300 at 2s each is ~10 minutes.
oauthWaitAttempts :: Int
oauthWaitAttempts = 300
