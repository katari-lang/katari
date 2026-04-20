module Katari.CLI.Parser
  ( cliParser,
  )
where

import Katari.CLI.Types
import Options.Applicative

cliParser :: Parser Command
cliParser =
  subparser
    ( command "build" (info (buildParser <**> helper) (progDesc "Compile a Katari project to dist/"))
        <> command "check" (info (checkParser <**> helper) (progDesc "Type check a Katari project without building"))
        <> command "apply" (info (applyParser <**> helper) (progDesc "Compile and deploy to a running runtime server"))
        <> command "run" (info (runParser <**> helper) (progDesc "Start a toplevel agent on the runtime"))
        <> command "stop" (info (stopParser <**> helper) (progDesc "Stop a running toplevel agent"))
        <> command "status" (info (statusParser <**> helper) (progDesc "List running toplevel agents"))
        <> command "result" (info (resultParser <**> helper) (progDesc "Show the result of a completed agent"))
        <> command "list" (info (listParser <**> helper) (progDesc "List agent definitions on the runtime"))
        <> command "dump" (info (dumpParser <**> helper) (progDesc "Dump IR of a Katari project as text"))
    )

buildParser :: Parser Command
buildParser =
  fmap CmdBuild $
    BuildOpts
      <$> optional (argument str (metavar "PATH" <> help "Project root or .ktr file (default: cwd)"))

applyParser :: Parser Command
applyParser =
  fmap CmdApply $
    ApplyOpts
      <$> optional (argument str (metavar "DIR" <> help "Project root directory (default: cwd)"))
      <*> runtimeUrlOption

runParser :: Parser Command
runParser =
  fmap CmdRun $
    RunOpts
      <$> optional (argument str (metavar "AGENT" <> help "Agent name (interactive if omitted)"))
      <*> optional (argument str (metavar "INPUT" <> help "Input JSON arguments"))
      <*> runtimeUrlOption

stopParser :: Parser Command
stopParser =
  fmap CmdStop $
    StopOpts
      <$> optional (argument str (metavar "AGENT_ID" <> help "Agent ID to stop (interactive if omitted)"))
      <*> runtimeUrlOption

statusParser :: Parser Command
statusParser =
  fmap CmdStatus $
    StatusOpts
      <$> runtimeUrlOption

resultParser :: Parser Command
resultParser =
  fmap CmdResult $
    ResultOpts
      <$> optional (argument str (metavar "AGENT_ID" <> help "Agent ID (interactive if omitted)"))
      <*> runtimeUrlOption

listParser :: Parser Command
listParser =
  fmap CmdList $
    ListOpts
      <$> runtimeUrlOption

checkParser :: Parser Command
checkParser =
  fmap CmdCheck $
    CheckOpts
      <$> optional (argument str (metavar "PATH" <> help "Project root or .ktr file (default: cwd)"))

dumpParser :: Parser Command
dumpParser =
  fmap CmdDump $
    DumpOpts
      <$> optional (argument str (metavar "PATH" <> help "Project root or .ktr file (default: cwd)"))

runtimeUrlOption :: Parser (Maybe String)
runtimeUrlOption =
  optional
    ( option
        str
        ( long "runtime"
            <> metavar "URL"
            <> help "Runtime server URL (overrides katari.toml)"
        )
    )
