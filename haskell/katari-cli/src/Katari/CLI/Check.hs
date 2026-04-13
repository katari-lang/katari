module Katari.CLI.Check
  ( runCheck,
  )
where

import Data.Maybe (fromMaybe)
import Katari.CLI.Compiler (buildGeOrDie)
import Katari.CLI.Project (loadProjectOrDie)
import Katari.CLI.Types (CheckOpts (..))

runCheck :: CheckOpts -> IO ()
runCheck CheckOpts {..} = do
  let path = fromMaybe "." chPath
  modules <- loadProjectOrDie path
  _ <- buildGeOrDie modules
  putStrLn "Type check passed"
