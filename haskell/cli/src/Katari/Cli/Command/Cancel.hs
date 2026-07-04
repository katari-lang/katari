-- | @katari cancel [RUN]@ — ask the runtime to wind a run down.
--
-- The run may be a unique id prefix; omitted on a terminal, a picker over the currently running runs
-- opens. Cancellation is asynchronous — the run transitions to @cancelling@ and terminates in its
-- own time — so this returns as soon as the request is accepted.
module Katari.Cli.Command.Cancel
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Cli.Api (cancelRun)
import Katari.Cli.Common (RuntimeContext (..), withRuntimeContext)
import Katari.Cli.Options (GlobalOptions, globalOptionsParser)
import Katari.Cli.Output (hint, printText, progress)
import Katari.Cli.Pick (resolveRunId)
import Options.Applicative

data Options = Options
  { global :: GlobalOptions,
    projectName :: Maybe Text,
    runId :: Maybe Text,
    reason :: Maybe Text
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
    <*> optional (strArgument (metavar "RUN" <> help "Run id, or a unique prefix of one (omit to pick from running runs)"))
    <*> optional (strOption (long "reason" <> metavar "TEXT" <> help "A note recorded on the run about why it was cancelled"))

run :: Options -> IO ()
run options = do
  context <- withRuntimeContext "cancel" options.global options.projectName
  target <- resolveRunId "cancel" context options.runId (Just "running")
  cancelRun context.client context.projectId target options.reason
  progress context.output ("Cancelling " <> target)
  hint context.output ("katari status " <> Text.take 8 target)
  printText target
