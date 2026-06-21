-- | @katari build@ — compile the project to IR and write it to disk.
--
-- Resolution is offline (disk + cache only): the dependency closure must already be locked, which
-- @katari apply@ does. The output is one JSON object mapping each module name to its lowered IR — the
-- same per-module 'IRModule' shape the runtime stores — so the artifact can be inspected or fed to a
-- runtime out of band. Default output is @\<root>\/.katari\/dist\/ir.json@.
module Katari.Cli.Build
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict qualified as Map
import Katari.Cli.Common (assembleSourcesOrExit, compileSourcesOrExit, dieIn, resolveProjectRoot, writeOrExit)
import Katari.Data.ModuleName (renderModuleName)
import Katari.Project.Discovery (emptyOverlay)
import Katari.Project.Error (renderProjectError)
import Katari.Project.Resolve (loadProjectOffline)
import Options.Applicative
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))

data Options = Options
  { projectRoot :: Maybe FilePath,
    output :: Maybe FilePath
  }
  deriving stock (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> optional
      ( strOption
          ( long "project"
              <> short 'p'
              <> metavar "DIR"
              <> help "Project root (the directory containing katari.toml). Defaults to walking up from the current directory."
          )
      )
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
  root <- resolveProjectRoot "build" options.projectRoot
  resolved <-
    loadProjectOffline emptyOverlay root >>= \case
      Left projectError -> dieIn "build" (renderProjectError projectError)
      Right resolved -> pure resolved
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
  putStrLn ("Wrote " <> show (Map.size loweredModules) <> " module(s) to " <> outputPath)
