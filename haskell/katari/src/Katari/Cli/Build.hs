-- | @katari build@ — compile and emit a JSON bundle (@ir.json@).
--
-- Same source-loading path as @check@; on success writes
-- @{ irModule, schemaBundle }@ to the output path (default
-- @dist\/bundle.json@ under the project root). The shape mirrors the
-- legacy @katari-compiler@ binary so the TypeScript runtime can read
-- the artefact unchanged.
module Katari.Cli.Build
  ( Options (..),
    optionsParser,
    run,
  )
where

import qualified Data.Aeson as Aeson
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy as LBS
import qualified Katari.Cli.Check as Check
import qualified Katari.Cli.Common as Common
import qualified Katari.Cli.CompileCache as CompileCache
import qualified Katari.Compile as Compile
import Katari.Diagnostic (hasErrors)
import Katari.IR (IRModule)
import Katari.Project.Cache qualified as Cache
import Katari.Schema (SchemaEntry (..))
import Options.Applicative
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeDirectory)

data Options = Options
  { optProjectRoot :: Maybe FilePath,
    optOut :: Maybe FilePath
  }
  deriving (Show)

optionsParser :: Parser Options
optionsParser =
  Options
    <$> optional
      ( strOption
          ( long "project"
              <> short 'p'
              <> metavar "DIR"
              <> help "Project root (the directory containing katari.toml)"
          )
      )
    <*> optional
      ( strOption
          ( long "out"
              <> short 'o'
              <> metavar "FILE"
              <> help "Output path for the JSON bundle (default: .katari/dist/bundle.json)"
          )
      )

run :: Options -> IO ()
run opts = do
  (root, input, fileTexts) <- Check.loadProject (Check.Options {optProjectRoot = opts.optProjectRoot})
  let result = Compile.compile input
      outputPath = case opts.optOut of
        Just p -> p
        Nothing -> root <> "/.katari/dist/bundle.json"
  Cache.ensureCacheDirs (Cache.projectCachePaths root)
  CompileCache.saveDiskCache root (CompileCache.toDiskCache result.updatedCache)
  Check.emitDiagnostics fileTexts result.diagnostics
  if hasErrors result.diagnostics
    then exitWith (ExitFailure 1)
    else do
      createDirectoryIfMissing True (takeDirectory outputPath)
      LBS.writeFile outputPath (encodePretty (buildBundleJson result.irModule result.schemaEntries))
      putStrLn ("Wrote " <> outputPath)

buildBundleJson :: Maybe IRModule -> Maybe [SchemaEntry] -> Value
buildBundleJson mIr mEntries =
  object
    [ "irModule" .= maybe Null Aeson.toJSON mIr,
      "schemaBundle" .= Common.schemaBundleJson mEntries
    ]
