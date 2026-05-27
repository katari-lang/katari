-- | @katari escalation@ — list and answer user-facing escalations.
--
-- Sub-commands:
--
--   * @katari escalation list@   — show open / answered / cancelled rows
--   * @katari escalation answer ID --value JSON@ — supply the answer
--     value to a pending escalation.
module Katari.Cli.Escalation
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Api.Client qualified as Api
import Katari.Api.Types qualified as Api
import Katari.Cli.Common qualified as Common
import Options.Applicative

data Options
  = List ListOptions
  | Answer AnswerOptions
  deriving (Show)

data ListOptions = ListOptions
  { listProject :: Maybe Text,
    listSnapshot :: Maybe Text,
    listState :: Maybe Api.EscalationState,
    listApiUrl :: Maybe Text
  }
  deriving (Show)

data AnswerOptions = AnswerOptions
  { ansId :: Text,
    ansValue :: Text,
    ansApiUrl :: Maybe Text
  }
  deriving (Show)

optionsParser :: Parser Options
optionsParser =
  hsubparser
    ( command
        "list"
        ( info
            (List <$> listOptionsParser)
            (progDesc "List escalations")
        )
        <> command
          "answer"
          ( info
              (Answer <$> answerOptionsParser)
              (progDesc "Answer a pending escalation")
          )
    )

listOptionsParser :: Parser ListOptions
listOptionsParser =
  ListOptions
    <$> optional (strOption (long "project" <> short 'p' <> metavar "NAME"))
    <*> optional (strOption (long "snapshot" <> short 's' <> metavar "ID"))
    <*> optional
      ( option
          readState
          ( long "state" <> metavar "STATE" <> help "open | answered | cancelled"
          )
      )
    <*> optional (strOption (long "api-url" <> metavar "URL"))
  where
    readState =
      eitherReader $ \case
        "open" -> Right Api.EscalationOpen
        "answered" -> Right Api.EscalationAnswered
        "cancelled" -> Right Api.EscalationCancelled
        other -> Left ("unknown state '" <> other <> "'")

answerOptionsParser :: Parser AnswerOptions
answerOptionsParser =
  AnswerOptions
    <$> argument str (metavar "ESCALATION_ID")
    <*> strOption (long "value" <> metavar "JSON" <> help "Answer value, as JSON")
    <*> optional (strOption (long "api-url" <> metavar "URL"))

run :: Options -> IO ()
run = \case
  List o -> runList o
  Answer o -> runAnswer o

runList :: ListOptions -> IO ()
runList o = do
  client <- Common.resolveApiClient "escalation" o.listApiUrl
  pid <- case o.listProject of
    Just name -> resolveProjectId client name
    Nothing -> die "katari escalation list: --project NAME required"
  rows <- Api.listEscalations client pid o.listSnapshot o.listState
  mapM_ printRow rows

runAnswer :: AnswerOptions -> IO ()
runAnswer o = do
  client <- Common.resolveApiClient "escalation" o.ansApiUrl
  val <- case Common.decodeJsonText o.ansValue of
    Right v -> pure v
    Left err -> die ("--value is not valid JSON: " <> err)
  ok <- Api.answerEscalation client o.ansId val
  if ok
    then putStrLn ("Answered " <> Text.unpack o.ansId)
    else die "runtime refused the answer"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

die :: String -> IO a
die = Common.dieIn "escalation"

resolveProjectId :: Api.ApiClient -> Text -> IO Text
resolveProjectId = Common.resolveProjectId "escalation"

printRow :: Api.EscalationRow -> IO ()
printRow r =
  putStrLn
    ( Text.unpack r.escalationId
        <> "  "
        <> show r.state
        <> "  ("
        <> Text.unpack r.createdAt
        <> ")"
    )
