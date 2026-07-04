-- | @katari build@ — compile the project to IR and write it to disk.
--
-- Resolution is offline (disk + cache only): the dependency closure must already be locked, which
-- @katari apply@ does. The output is one JSON object mapping each module name to its lowered IR — the
-- same per-module 'IRModule' shape the runtime stores — so the artifact can be inspected or fed to a
-- runtime out of band. Default output is @\<root>\/.katari\/dist\/ir.json@.
module Katari.Cli.Command.Build
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Katari.Cli.Common (assembleSourcesOrExit, compileSourcesOrExit, dieIn, resolveProjectRoot, writeOrExit)
import Katari.Cli.Options (GlobalOptions, directoryOption, globalOptionsParser)
import Katari.Cli.Output (newOutputContext, progress)
import Katari.Data.ModuleName (renderModuleName)
import Katari.Project.Discovery (emptyOverlay)
import Katari.Project.Error (renderProjectError)
import Katari.Project.Resolve (loadProjectOffline)
import Options.Applicative
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))

data Options = Options
  { global :: GlobalOptions,
    projectRoot :: Maybe FilePath,
    output :: Maybe FilePath
  }
  deriving stock (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> globalOptionsParser
    <*> directoryOption
    <*> optional
      ( strOption
          ( long "out"
              <> short 'o'
              <> metavar "FILE"
              <> help "Output path for the IR JSON (default: <root>/.katari/dist/ir.json)"
          )
      )

run :: Options -> IO ()
run options = do
  context <- newOutputContext options.global
  root <- resolveProjectRoot "build" options.projectRoot
  resolved <-
    loadProjectOffline emptyOverlay root >>= \case
      Left projectError -> dieIn "build" (renderProjectError projectError)
      Right loaded -> pure loaded
  sources <- assembleSourcesOrExit "build" resolved
  loweredModules <- compileSourcesOrExit sources
  -- Module names carry no 'ToJSONKey', so re-key by their rendered text to form the JSON object.
  let irByName = Map.mapKeys renderModuleName loweredModules
      outputPath = case options.output of
        Just path -> path
        Nothing -> root </> ".katari" </> "dist" </> "ir.json"
  writeOrExit "build" "could not write IR output" $ do
    createDirectoryIfMissing True (takeDirectory outputPath)
    LazyByteString.writeFile outputPath (encodePretty irByName)
  progress context ("Wrote " <> Text.pack (show (Map.size loweredModules)) <> " module(s) to " <> Text.pack outputPath)
