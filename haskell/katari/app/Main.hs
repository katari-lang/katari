-- | Entry point for the @katari@ binary.
module Main (main) where

import qualified Katari.Cli.Apply as Apply
import qualified Katari.Cli.Build as Build
import qualified Katari.Cli.Cancel as Cancel
import qualified Katari.Cli.Check as Check
import qualified Katari.Cli.Escalation as Escalation
import qualified Katari.Cli.Init as Init
import qualified Katari.Cli.Ls as Ls
import qualified Katari.Cli.Run as Run
import qualified Katari.Cli.Status as Status
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

main :: IO ()
main = do
  cmd <- execParser (info (cmdParser <**> helper) (progDesc "Katari CLI"))
  case cmd of
    Init opts -> Init.run opts
    Check opts -> Check.run opts
    Build opts -> Build.run opts
    Apply opts -> Apply.run opts
    Run opts -> Run.run opts
    Cancel opts -> Cancel.run opts
    Ls opts -> Ls.run opts
    Status opts -> Status.run opts
    Escalation opts -> Escalation.run opts
