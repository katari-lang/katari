module Main (main) where

import Katari.LSP.Server (runServer)
import System.Exit (ExitCode (..), exitWith)

main :: IO ()
main = do
  code <- runServer
  exitWith (if code == 0 then ExitSuccess else ExitFailure code)
