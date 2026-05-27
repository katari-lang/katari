-- | @katari check@ — type-check the current project.
--
-- Walks up from the current directory to find @katari.toml@, resolves
-- the dependency graph, compiles, and prints diagnostics. Exits with
-- code 1 if any error-severity diagnostic surfaces, 2 on setup errors
-- (missing @katari.toml@, bad config), 0 on a clean check.
module Katari.Cli.Check
  ( Options (..),
    optionsParser,
    run,
    -- * Shared helpers (used by 'Katari.Cli.Build')
    loadProject,
    emitDiagnostics,
    findProjectRoot,
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.IO as TextIO
import qualified Katari.Cli.CompileCache as CompileCache
import qualified Katari.Compile as Compile
import Katari.Diagnostic (Diagnostic, Severity (..), filterAtLeast, hasErrors)
import Katari.Diagnostic.Render (renderDiagnostics, renderDiagnosticsAnsi)
import qualified Data.Text as Text
import Katari.Project.Cache qualified as Cache
import qualified Katari.Project.Discovery as Project
import qualified Katari.Project.Resolve as Project
import Options.Applicative
import System.Directory (getCurrentDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hIsTerminalDevice, hPutStrLn, stderr)

newtype Options = Options
  { -- | Project root override; defaults to walking up from @.@.
    optProjectRoot :: Maybe FilePath
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

run :: Options -> IO ()
run opts = do
  (root, input, fileTexts) <- loadProject opts
  let result = Compile.compile input
  Cache.ensureCacheDirs (Cache.projectCachePaths root)
  CompileCache.saveDiskCache root (CompileCache.toDiskCache result.updatedCache)
  emitDiagnostics fileTexts result.diagnostics
  if hasErrors result.diagnostics
    then exitWith (ExitFailure 1)
    else pure ()

-- ---------------------------------------------------------------------------
-- Helpers (shared with build)
-- ---------------------------------------------------------------------------

findProjectRoot :: Options -> IO FilePath
findProjectRoot opts = do
  start <- maybe getCurrentDirectory pure opts.optProjectRoot
  mRoot <- Project.findProjectRoot start
  case mRoot of
    Nothing -> do
      hPutStrLn stderr "katari: no katari.toml found in this or any parent directory"
      exitWith (ExitFailure 2)
    Just root -> pure root

loadProject :: Options -> IO (FilePath, Compile.CompileInput, Map FilePath Text)
loadProject opts = do
  root <- findProjectRoot opts
  rpRes <- Project.loadResolvedProject root
  case rpRes of
    Left err -> do
      hPutStrLn stderr ("katari: " <> Text.unpack (Project.renderResolveError err))
      exitWith (ExitFailure 2)
    Right resolved -> case Project.assembleProject resolved of
      Left err -> do
        hPutStrLn stderr ("katari: " <> Text.unpack (Project.renderResolveError err))
        exitWith (ExitFailure 2)
      Right assembly -> do
        diskCache <- CompileCache.loadDiskCache root
        let sources =
              Map.map
                ( \e ->
                    Compile.SourceEntry
                      { Compile.filePath = e.sourcePath,
                        Compile.sourceText = e.sourceText
                      }
                )
                assembly.sources
            fileTexts =
              Map.fromList
                [ (e.sourcePath, e.sourceText) | e <- Map.elems assembly.sources
                ]
            cache = CompileCache.applyDiskCache diskCache
        pure (root, Compile.CompileInput {Compile.sources = sources, Compile.cache = cache}, fileTexts)

emitDiagnostics :: Map FilePath Text -> [Diagnostic] -> IO ()
emitDiagnostics fileTexts ds = do
  -- Use ANSI colours on a TTY, fall back to plain text when stderr is
  -- a pipe / file (= an editor or CI buffer). Reading TERM=dumb opts
  -- out for users on dumb terminals that mishandle escape sequences.
  isTty <- hIsTerminalDevice stderr
  term <- lookupEnv "TERM"
  let useAnsi = isTty && term /= Just "dumb"
      filtered = filterAtLeast SeverityWarning ds
      rendered =
        if useAnsi
          then renderDiagnosticsAnsi fileTexts filtered
          else renderDiagnostics fileTexts filtered
  mapM_ (TextIO.hPutStrLn stderr) rendered
