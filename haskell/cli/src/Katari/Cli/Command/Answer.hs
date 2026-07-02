-- | @katari answer [ESCALATION]@ — answer a question a run escalated to its operator.
--
-- The escalation may be a unique id prefix; omitted on a terminal, a picker over the open
-- escalations opens. The answer comes from @--value@ (deterministic) or, interactively, from an
-- interview over the request's answer schema — the runtime derives it from the run's snapshot IR, so
-- the prompt destructures exactly the record the program expects back.
module Katari.Cli.Command.Answer
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Katari.Cli.Api (EscalationView (..), answerEscalation)
import Katari.Cli.Common (RuntimeContext (..), dieIn, withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (OutputContext (..), hint, printText, progress)
import Katari.Cli.Pick (resolveEscalation)
import Katari.Cli.Prompt (compactJson, promptFromSchema)
import Katari.Data.JSONSchema (JSONSchema (..))
import Options.Applicative

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
    <*> optional (strOption (long "value" <> metavar "JSON" <> help "The answer as JSON (omit to be prompted through the answer schema)"))

run :: Options -> IO ()
run options = do
  context <- withRuntimeContext "answer" options.global options.projectName
  escalation <- resolveEscalation "answer" context options.escalationId
  answerValue <- resolveValue context escalation options.valueJson
  answerEscalation context.client context.projectId escalation.id answerValue
  progress context.output ("Answered " <> escalation.id)
  hint context.output ("katari answer " <> escalation.id <> " --value '" <> compactJson answerValue <> "'")
  printText escalation.id

-- | The answer value: parsed from @--value@ when given; otherwise an interactive interview over the
-- runtime-derived answer schema (raw JSON input when no schema came through).
resolveValue :: RuntimeContext -> EscalationView -> Maybe Text -> IO Value
resolveValue context escalation valueJson = case valueJson of
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
    answerSchema = case escalation.answerSchema of
      Nothing -> SchemaAny
      Just raw -> case Aeson.fromJSON raw of
        Aeson.Success schema -> schema
        Aeson.Error _ -> SchemaAny
