-- | Entry point for the @katari@ binary.
module Main (main) where

import Katari.Cli.Apply qualified as Apply
import Katari.Cli.Build qualified as Build
import Katari.Cli.Cancel qualified as Cancel
import Katari.Cli.Check qualified as Check
import Katari.Cli.Common qualified as Common
import Katari.Cli.Escalation qualified as Escalation
import Katari.Cli.Init qualified as Init
import Katari.Cli.Ls qualified as Ls
import Katari.Cli.Run qualified as Run
import Katari.Cli.Status qualified as Status
import Katari.Version (katariVersion)
import Options.Applicative

data Cmd
  = Init Init.Options
  | Check Check.Options
  | Build Build.Options
  | Apply Apply.Options
  | Run Run.Options
  | Cancel Cancel.Options
  | Ls Ls.Options
  | Status Status.Options
  | Escalation Escalation.Options

cmdParser :: Parser Cmd
cmdParser =
  hsubparser
    ( commandGroup "Project:"
        <> command "init" (info (Init <$> Init.optionsParser) (progDesc "Scaffold a new Katari project"))
        <> command "check" (info (Check <$> Check.optionsParser) (progDesc "Type-check sources without uploading"))
        <> command "build" (info (Build <$> Build.optionsParser) (progDesc "Compile to IR JSON"))
    )
    <|> hsubparser
      ( commandGroup "Runtime:"
          <> command "apply" (info (Apply <$> Apply.optionsParser) (progDesc "Compile, bundle, and upload as a new snapshot"))
          <> command "run" (info (Run <$> Run.optionsParser) (progDesc "Start an agent on the runtime"))
          <> command "cancel" (info (Cancel <$> Cancel.optionsParser) (progDesc "Cancel a running agent"))
          <> command "ls" (info (Ls <$> Ls.optionsParser) (progDesc "List runtime resources"))
          <> command "status" (info (Status <$> Status.optionsParser) (progDesc "Show one agent's state + result"))
          <> command "escalation" (info (Escalation <$> Escalation.optionsParser) (progDesc "Manage escalations"))
      )

versionOption :: Parser (a -> a)
versionOption =
  infoOption
    ("katari v" <> katariVersion)
    ( long "version"
        <> short 'v'
        <> help "Show the katari CLI version and exit"
        <> hidden
    )

main :: IO ()
main = do
  cmd <-
    execParser
      ( info
          (cmdParser <**> versionOption <**> helper)
          ( fullDesc
              <> header ("katari v" <> katariVersion <> " — DSL for orchestrating AI agents")
              <> progDesc "Project + Runtime CLI. Use `katari <subcommand> --help` for details."
          )
      )
  -- Commands that talk to the runtime translate ApiError exceptions
  -- (HTTP 4xx/5xx, network failures, decode errors) into friendly
  -- `katari <cmd>:` messages with exit 2. Project-local commands
  -- (init/check/build) never touch the network, so they go through
  -- the bare entry.
  case cmd of
    Init opts -> Init.run opts
    Check opts -> Check.run opts
    Build opts -> Build.run opts
    Apply opts -> Common.runWithApiErrors "apply" (Apply.run opts)
    Run opts -> Common.runWithApiErrors "run" (Run.run opts)
    Cancel opts -> Common.runWithApiErrors "cancel" (Cancel.run opts)
    Ls opts -> Common.runWithApiErrors "ls" (Ls.run opts)
    Status opts -> Common.runWithApiErrors "status" (Status.run opts)
    Escalation opts -> Common.runWithApiErrors "escalation" (Escalation.run opts)
