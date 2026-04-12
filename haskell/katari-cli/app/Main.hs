module Main where

import Katari.CLI.Apply (runApply)
import Katari.CLI.Build (runBuild)
import Katari.CLI.Dump (runDump)
import Katari.CLI.Parser (cliParser)
import Katari.CLI.Result (runResult)
import Katari.CLI.Run (runRun)
import Katari.CLI.Status (runStatus)
import Katari.CLI.Stop (runStop)
import Katari.CLI.Types (Command (..))
import Options.Applicative (execParser, fullDesc, helper, info, progDesc, (<**>))

main :: IO ()
main = do
  cmd <- execParser (info (cliParser <**> helper) (fullDesc <> progDesc "Katari CLI"))
  case cmd of
    CmdBuild opts -> runBuild opts
    CmdApply opts -> runApply opts
    CmdRun opts -> runRun opts
    CmdStop opts -> runStop opts
    CmdStatus opts -> runStatus opts
    CmdResult opts -> runResult opts
    CmdDump opts -> runDump opts
