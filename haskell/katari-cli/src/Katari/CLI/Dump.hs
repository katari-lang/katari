module Katari.CLI.Dump
  ( runDump,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text.IO qualified as TIO
import Katari.CLI.Compiler (buildOrDie)
import Katari.CLI.Project (loadProjectOrDie)
import Katari.CLI.Types (DumpOpts (..))
import Katari.IRPrint (printIRModule)

runDump :: DumpOpts -> IO ()
runDump DumpOpts {..} = do
  let path = fromMaybe "." dpPath
  modules <- loadProjectOrDie path
  irModule <- buildOrDie modules
  TIO.putStrLn (printIRModule irModule)
