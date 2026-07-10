-- | Entry point for the @katari@ binary: parse the command line, dispatch, and translate the two
-- cross-cutting failure shapes — a 'RuntimeError' becomes a friendly @katari <cmd>:@ line (exit 2),
-- and an uncaught Ctrl-C becomes a clean exit 130 — so no command ever surfaces a raw stack trace.
module Main (main) where

import Control.Exception (AsyncException (..), catch, throwIO)
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Cli.Api (RuntimeError, renderRuntimeError)
import Katari.Cli.Command.Add qualified as Add
import Katari.Cli.Command.Answer qualified as Answer
import Katari.Cli.Command.Apply qualified as Apply
import Katari.Cli.Command.Build qualified as Build
import Katari.Cli.Command.Cancel qualified as Cancel
import Katari.Cli.Command.Check qualified as Check
import Katari.Cli.Command.Env qualified as Env
import Katari.Cli.Command.File qualified as File
import Katari.Cli.Command.Init qualified as Init
import Katari.Cli.Command.Ls qualified as Ls
import Katari.Cli.Command.Mcp qualified as Mcp
import Katari.Cli.Command.Project qualified as Project
import Katari.Cli.Command.Run qualified as Run
import Katari.Cli.Command.Status qualified as Status
import Katari.Cli.Common (cliVersion, dieIn, exitInterrupted)
import Options.Applicative

data Command
  = CommandInit Init.Options
  | CommandCheck Check.Options
  | CommandBuild Build.Options
  | CommandApply Apply.Options
  | CommandAdd Add.Options
  | CommandRemove Add.Options
  | CommandRun Run.Options
  | CommandStatus Status.Options
  | CommandCancel Cancel.Options
  | CommandAnswer Answer.Options
  | CommandLs Ls.Options
  | CommandEnv Env.Options
  | CommandFile File.Options
  | CommandMcp Mcp.Options
  | CommandProject Project.Options

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "init" (info (CommandInit <$> Init.optionsParser) (progDesc "Scaffold a new Katari project"))
        <> command "check" (info (CommandCheck <$> Check.optionsParser) (progDesc "Compile the project and report diagnostics"))
        <> command "build" (info (CommandBuild <$> Build.optionsParser) (progDesc "Compile the project to IR JSON"))
        <> command "apply" (info (CommandApply <$> Apply.optionsParser) (progDesc "Compile and deploy the project to the runtime as a new snapshot"))
        <> command "add" (info (CommandAdd <$> Add.optionsParser) (progDesc "Add dependencies to katari.toml and refresh katari.lock"))
        <> command "remove" (info (CommandRemove <$> Add.optionsParser) (progDesc "Remove dependencies from katari.toml and refresh katari.lock"))
        <> command "run" (info (CommandRun <$> Run.optionsParser) (progDesc "Start an agent and wait for its result (Ctrl-C detaches)"))
        <> command "status" (info (CommandStatus <$> Status.optionsParser) (progDesc "Show one run's state, outcome and open questions"))
        <> command "cancel" (info (CommandCancel <$> Cancel.optionsParser) (progDesc "Cancel a running run"))
        <> command "answer" (info (CommandAnswer <$> Answer.optionsParser) (progDesc "Answer a question a run escalated"))
        <> command "ls" (info (CommandLs <$> Ls.optionsParser) (progDesc "List runs (default), agents, snapshots, projects, escalations, files or env"))
        <> command "env" (info (CommandEnv <$> Env.optionsParser) (progDesc "Manage the project's env entries (get / set / unset)"))
        <> command "file" (info (CommandFile <$> File.optionsParser) (progDesc "Upload / download project files"))
        <> command "mcp" (info (CommandMcp <$> Mcp.optionsParser) (progDesc "Manage MCP server credentials (login)"))
        <> command "project" (info (CommandProject <$> Project.optionsParser) (progDesc "Manage projects on the runtime (remove, rollback)"))
    )

versionOption :: Parser (a -> a)
versionOption =
  infoOption
    ("katari " <> Text.unpack cliVersion)
    (long "version" <> short 'v' <> help "Show the katari version and exit" <> hidden)

main :: IO ()
main = do
  command' <-
    customExecParser
      (prefs showHelpOnEmpty)
      ( info
          (commandParser <**> versionOption <**> helper)
          ( fullDesc
              <> header "katari — orchestration logic for AI agents"
              <> progDesc "Use `katari <command> --help` for per-command options."
          )
      )
  let (subcommand, runCommand) = dispatch command'
  runCommand
    -- A runtime failure (network / HTTP / decode) surfaces as a 'RuntimeError'; turn it into a
    -- friendly `katari <cmd>:` line with exit 2 instead of an uncaught-exception stack trace.
    `catch` (\(runtimeError :: RuntimeError) -> dieIn subcommand (renderRuntimeError runtimeError))
    -- A Ctrl-C anywhere a command did not handle itself (pickers, prompts) still exits as an
    -- interrupt, with the terminal already restored by the prompt's bracket.
    `catch` ( \(asyncException :: AsyncException) -> case asyncException of
                UserInterrupt -> exitInterrupted
                other -> throwIO other
            )

dispatch :: Command -> (Text, IO ())
dispatch = \case
  CommandInit options -> ("init", Init.run options)
  CommandCheck options -> ("check", Check.run options)
  CommandBuild options -> ("build", Build.run options)
  CommandApply options -> ("apply", Apply.run options)
  CommandAdd options -> ("add", Add.run Add.ModeAdd options)
  CommandRemove options -> ("remove", Add.run Add.ModeRemove options)
  CommandRun options -> ("run", Run.run options)
  CommandStatus options -> ("status", Status.run options)
  CommandCancel options -> ("cancel", Cancel.run options)
  CommandAnswer options -> ("answer", Answer.run options)
  CommandLs options -> ("ls", Ls.run options)
  CommandEnv options -> ("env", Env.run options)
  CommandFile options -> ("file", File.run options)
  CommandMcp options -> ("mcp", Mcp.run options)
  CommandProject options -> ("project", Project.run options)
