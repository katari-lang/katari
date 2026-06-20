-- | Helpers shared by the CLI subcommands: locating the project root, the compile step, and the
-- exit-code convention.
--
-- Exit codes follow the usual split so wrappers / CI can tell failure modes apart:
--
--   * @1@ — the program had compile errors (a normal, expected outcome).
--   * @2@ — a setup / usage problem (no @katari.toml@, bad config, unreachable runtime).
--   * @70@ — an internal invariant was violated (@EX_SOFTWARE@); a bug in @katari@ itself.
module Katari.Cli.Common
  ( dieIn,
    dieInternal,
    resolveProjectRoot,
    assembleSourcesOrExit,
    compileSourcesOrExit,
  )
where

import Control.Monad (unless, when)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Katari.Compile qualified as Compile
import Katari.Data.IR (IRModule)
import Katari.Data.ModuleName (ModuleName)
import Katari.Diagnostics (hasErrors, renderDiagnostics)
import Katari.Project.Discovery (findProjectRoot)
import Katari.Project.Error (renderProjectError)
import Katari.Project.Resolve (ResolvedProject, assembleProject, compileInputSources)
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr)

-- | Standard CLI bail: print @katari \<subcommand>: \<message>@ to stderr and exit with code 2
-- (setup / usage error).
dieIn :: Text -> Text -> IO a
dieIn subcommand message = do
  TextIO.hPutStrLn stderr ("katari " <> subcommand <> ": " <> message)
  exitWith (ExitFailure 2)

-- | Bail on a broken internal invariant: exit 70 (@EX_SOFTWARE@), distinct from a user error so a
-- wrapper can tell "the user did something wrong" from "@katari@ is buggy".
dieInternal :: Text -> Text -> IO a
dieInternal subcommand message = do
  TextIO.hPutStrLn stderr ("katari " <> subcommand <> ": internal error: " <> message)
  exitWith (ExitFailure 70)

-- | Resolve the project root: the explicit @--project@ override if given, otherwise the nearest
-- ancestor of the current directory that holds a @katari.toml@. Exits with code 2 when none is found.
resolveProjectRoot :: Text -> Maybe FilePath -> IO FilePath
resolveProjectRoot subcommand override = do
  start <- maybe getCurrentDirectory pure override
  found <- findProjectRoot start
  case found of
    Just root -> pure root
    Nothing -> dieIn subcommand "no katari.toml found in this or any parent directory"

-- | Flatten a resolved project into the compiler's @module name -> source@ map, exiting with code 2
-- on any assembly error (a cross-package module collision, an out-of-namespace module, …).
assembleSourcesOrExit :: Text -> ResolvedProject -> IO (Map ModuleName Text)
assembleSourcesOrExit subcommand resolved = case assembleProject resolved of
  Left projectError -> dieIn subcommand (renderProjectError projectError)
  Right assembly -> pure (compileInputSources assembly)

-- | Compile the assembled sources, print any diagnostics to stderr, and either exit with code 1 (on
-- an error-severity diagnostic) or return the lowered IR per module. Warnings are printed but do not
-- block.
compileSourcesOrExit :: Map ModuleName Text -> IO (Map ModuleName IRModule)
compileSourcesOrExit sources = do
  let result = Compile.compile Compile.CompileInput {Compile.sources = sources}
      rendered = renderDiagnostics result.diagnostics
  unless (Text.null rendered) $ TextIO.hPutStrLn stderr rendered
  when (hasErrors result.diagnostics) $ exitWith (ExitFailure 1)
  pure result.loweredModules
