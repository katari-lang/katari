-- | Entry point for the @katari@ binary.
module Main (main) where

import Control.Exception (catch)
import Katari.Cli.Api (RuntimeError, renderRuntimeError)
import Katari.Cli.Apply qualified as Apply
import Katari.Cli.Build qualified as Build
import Katari.Cli.Common (dieIn)
import Katari.Cli.Run qualified as Run
import Options.Applicative

data Command
  = Build Build.Options
  | Apply Apply.Options
  | Run Run.Options

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "build" (info (Build <$> Build.optionsParser) (progDesc "Compile the project to IR JSON"))
        <> command "apply" (info (Apply <$> Apply.optionsParser) (progDesc "Compile and deploy the project to the runtime as a new snapshot"))
        <> command "run" (info (Run <$> Run.optionsParser) (progDesc "Start an agent on the runtime and print its result"))
    )

versionOption :: Parser (a -> a)
versionOption =
  infoOption
    "katari 0.1.0.0"
    (long "version" <> short 'v' <> help "Show the katari version and exit" <> hidden)

main :: IO ()
main = do
  command' <-
    execParser
      ( info
          (commandParser <**> versionOption <**> helper)
          ( fullDesc
              <> header "katari — orchestration logic for AI agents"
              <> progDesc "Use `katari <command> --help` for per-command options."
          )
      )
  case command' of
    Build options -> Build.run options
    -- A runtime failure (network / HTTP / decode) surfaces as a 'RuntimeError'; turn it into a
    -- friendly `katari <cmd>:` line with exit 2 instead of an uncaught-exception stack trace.
    Apply options ->
      Apply.run options
        `catch` \(runtimeError :: RuntimeError) -> dieIn "apply" (renderRuntimeError runtimeError)
    Run options ->
      Run.run options
        `catch` \(runtimeError :: RuntimeError) -> dieIn "run" (renderRuntimeError runtimeError)
