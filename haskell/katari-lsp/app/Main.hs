module Main (main) where

import Katari.LSP.Server (runServer)
import System.Exit (exitWith, ExitCode (..))

main :: IO ()
main = do
  code <- runServer
  exitWith (if code == 0 then ExitSuccess else ExitFailure code)
