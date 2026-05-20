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
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.IO as TextIO
import qualified Katari.Compile as Compile
import Katari.Diagnostic (Diagnostic, Severity (..), filterAtLeast, hasErrors)
import Katari.Diagnostic.Render (renderDiagnostic)
import qualified Data.Text as Text
import qualified Katari.Project.Discovery as Project
import qualified Katari.Project.Lockfile as Lock
import qualified Katari.Project.Resolve as Project
import Options.Applicative
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

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
  (input, fileTexts) <- loadProject opts
  let result = Compile.compile input
  emitDiagnostics fileTexts result.diagnostics
  if hasErrors result.diagnostics
    then exitWith (ExitFailure 1)
    else pure ()

-- ---------------------------------------------------------------------------
-- Helpers (shared with build)
-- ---------------------------------------------------------------------------

loadProject :: Options -> IO (Compile.CompileInput, Map FilePath Text)
loadProject opts = do
  start <- maybe getCurrentDirectory pure opts.optProjectRoot
  mRoot <- Project.findProjectRoot start
  case mRoot of
    Nothing -> do
      hPutStrLn stderr "katari check: no katari.toml found in this or any parent directory"
      exitWith (ExitFailure 2)
    Just root -> do
      rpRes <- Project.loadResolvedProject root
      case rpRes of
        Left err -> do
          hPutStrLn stderr ("katari check: " <> Text.unpack (Project.renderResolveError err))
          exitWith (ExitFailure 2)
        Right resolved -> case Project.assembleProject resolved of
          Left err -> do
            hPutStrLn stderr ("katari check: " <> Text.unpack (Project.renderResolveError err))
            exitWith (ExitFailure 2)
          Right assembly -> do
            -- Refresh katari.lock to mirror the resolved graph. This
            -- runs on every check/build/apply, so the lock stays in
            -- sync with katari.toml without an explicit `resolve`
            -- step. Path deps record their root path verbatim; once
            -- snapshot / git resolution land here, those branches
            -- will record sha256 digests too.
            Lock.writeLockfile
              (root </> Lock.lockfileFilename)
              (Project.lockfileFromResolved resolved)
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
            pure (Compile.CompileInput {Compile.sources = sources}, fileTexts)

emitDiagnostics :: Map FilePath Text -> [Diagnostic] -> IO ()
emitDiagnostics fileTexts ds =
  mapM_ (TextIO.hPutStrLn stderr . renderDiagnostic fileTexts) (filterAtLeast SeverityWarning ds)
