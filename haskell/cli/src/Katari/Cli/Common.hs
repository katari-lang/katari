-- | Helpers shared by the CLI subcommands: locating the project root, the compile step, id-prefix
-- resolution, and the exit-code convention.
--
-- Exit codes follow the usual split so wrappers / CI can tell failure modes apart:
--
--   * @1@ — the program failed on its own terms (compile errors; a run that ended @error@ /
--     @cancelled@ under @run@'s wait).
--   * @2@ — a setup / usage problem (no @katari.toml@, bad config, unreachable runtime, missing
--     input in a non-interactive session).
--   * @70@ — an internal invariant was violated (@EX_SOFTWARE@); a bug in @katari@ itself.
--   * @130@ — interrupted by Ctrl-C (@128 + SIGINT@), e.g. while waiting on a run.
module Katari.Cli.Common
  ( dieIn,
    dieProgram,
    dieInternal,
    exitInterrupted,
    resolveProjectRoot,
    resolveRuntimeUrl,
    requireProjectId,
    resolveIdPrefix,
    PrefixError (..),
    renderPrefixError,
    assembleSourcesOrExit,
    compileSourcesOrExit,
    writeOrExit,
  )
where

import Control.Exception (IOException, catch)
import Control.Monad (unless, when)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import GHC.List (List)
import Katari.Cli.Api (ProjectRow (..), RuntimeClient, listProjects)
import Katari.Compile qualified as Compile
import Katari.Data.IR (IRModule)
import Katari.Data.ModuleName (ModuleName)
import Katari.Diagnostics (hasErrors, renderDiagnostics)
import Katari.Project.Discovery (findProjectRoot)
import Katari.Project.Error (renderProjectError)
import Katari.Project.Resolve (ResolvedProject, assembleProject, compileInputSources)
import System.Directory (getCurrentDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr)

-- | Standard CLI bail: print @katari \<subcommand>: \<message>@ to stderr and exit with code 2
-- (setup / usage error).
dieIn :: Text -> Text -> IO a
dieIn subcommand message = do
  TextIO.hPutStrLn stderr ("katari " <> subcommand <> ": " <> message)
  exitWith (ExitFailure 2)

-- | Bail with exit 1: the /program/ failed (a run ended in error, a cancellation), as opposed to the
-- invocation being wrong. Same rendering as 'dieIn', different code so scripts can tell them apart.
dieProgram :: Text -> Text -> IO a
dieProgram subcommand message = do
  TextIO.hPutStrLn stderr ("katari " <> subcommand <> ": " <> message)
  exitWith (ExitFailure 1)

-- | Bail on a broken internal invariant: exit 70 (@EX_SOFTWARE@), distinct from a user error so a
-- wrapper can tell "the user did something wrong" from "@katari@ is buggy".
dieInternal :: Text -> Text -> IO a
dieInternal subcommand message = do
  TextIO.hPutStrLn stderr ("katari " <> subcommand <> ": internal error: " <> message)
  exitWith (ExitFailure 70)

-- | Exit as an interrupted process (@128 + SIGINT@), after the caller has printed its parting hint.
exitInterrupted :: IO a
exitInterrupted = exitWith (ExitFailure 130)

-- | Resolve the project root: the explicit @--project@ override if given, otherwise the nearest
-- ancestor of the current directory that holds a @katari.toml@. Exits with code 2 when none is found.
resolveProjectRoot :: Text -> Maybe FilePath -> IO FilePath
resolveProjectRoot subcommand override = do
  start <- maybe getCurrentDirectory pure override
  found <- findProjectRoot start
  case found of
    Just root -> pure root
    Nothing -> dieIn subcommand "no katari.toml found in this or any parent directory"

-- | Resolve the runtime URL the CLI talks to: the @--url@ override, then @KATARI_API_URL@, then the
-- @[runtime].url@ from @katari.toml@. Shared by every command that reaches the runtime.
resolveRuntimeUrl :: Maybe Text -> Text -> IO Text
resolveRuntimeUrl override fallback = case override of
  Just url -> pure url
  Nothing -> do
    environmentUrl <- lookupEnv "KATARI_API_URL"
    pure $ case environmentUrl of
      Just environmentValue | not (null environmentValue) -> Text.pack environmentValue
      _ -> fallback

-- | Resolve a project name to its runtime id, exiting with code 2 (and an actionable hint) when the
-- project is not deployed. The runtime keys management routes by id while the CLI speaks names.
requireProjectId :: Text -> RuntimeClient -> Text -> IO Text
requireProjectId subcommand client projectName = do
  (_, projects) <- listProjects client
  case filter (\project -> project.name == projectName) projects of
    (existing : _) -> pure existing.id
    [] -> dieIn subcommand ("project " <> projectName <> " is not deployed; run `katari apply` first")

-- | Why an id prefix failed to resolve.
data PrefixError
  = PrefixNotFound
  | PrefixAmbiguous (List Text)
  deriving stock (Show, Eq)

renderPrefixError :: Text -> PrefixError -> Text
renderPrefixError prefix = \case
  PrefixNotFound -> "no id starts with '" <> prefix <> "'"
  PrefixAmbiguous candidates ->
    "'" <> prefix <> "' is ambiguous between: " <> Text.intercalate ", " candidates

-- | Resolve a (possibly shortened) id against the known ids: an exact match wins outright, otherwise
-- the prefix must select exactly one. Pure so the disambiguation rules are unit-testable; the caller
-- fetches the candidate list (generously, not page-sized) and acts on the returned full id.
resolveIdPrefix :: Text -> List Text -> Either PrefixError Text
resolveIdPrefix prefix identifiers
  | prefix `elem` identifiers = Right prefix
  | otherwise = case filter (prefix `Text.isPrefixOf`) identifiers of
      [only] -> Right only
      [] -> Left PrefixNotFound
      candidates -> Left (PrefixAmbiguous candidates)

-- | Flatten a resolved project into the compiler's @module name -> source@ map, exiting with code 2
-- on any assembly error (a cross-package module collision, an out-of-namespace module, …).
assembleSourcesOrExit :: Text -> ResolvedProject -> IO (Map ModuleName Text)
assembleSourcesOrExit subcommand resolved = case assembleProject resolved of
  Left projectError -> dieIn subcommand (renderProjectError projectError)
  Right assembly -> pure (compileInputSources assembly)

-- | Run a disk write, turning an 'IOException' (permission denied, read-only filesystem, disk full,
-- …) into a clean exit-2 (setup) error. Without this the failure escapes as an uncaught exception,
-- which exits with code 1 — the code reserved for compile errors — so a wrapper / CI would
-- misclassify a disk problem as "the program failed to compile".
writeOrExit :: Text -> Text -> IO () -> IO ()
writeOrExit subcommand description action =
  action `catch` \(ioException :: IOException) ->
    dieIn subcommand (description <> ": " <> Text.pack (show ioException))

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
