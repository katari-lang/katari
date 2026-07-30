-- | @katari check@ — compile the project and report diagnostics, writing nothing.
--
-- Resolution is offline (disk + cache only), like @build@: a diagnostics command must be
-- deterministic and never block on the network. That makes @katari.lock@ the thing being checked, so
-- the load refuses outright when the lock no longer matches @katari.toml@ — an "OK" earned against a
-- closure the manifest no longer asks for is a wrong answer, and the remedy (@katari lock@) comes
-- with the refusal.
module Katari.Cli.Command.Check
  ( Options (..),
    optionsParser,
    run,
  )
where

import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Katari.Cli.Common (WarningScope (..), assembleSourcesOrExit, compileResultOrExit, dieIn, ownedSourceFiles, resolveProjectRoot)
import Katari.Cli.Escalation (EntryPointScope (..), entryPointReports, renderEntryPointSection)
import Katari.Cli.Options (GlobalOptions, directoryOption, globalOptionsParser)
import Katari.Cli.Output (newOutputContext, progress)
import Katari.Compile (CompileResult (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Project.Config (PackageSection (..), ProjectConfig (..))
import Katari.Project.Discovery (emptyOverlay)
import Katari.Project.Error (renderProjectError)
import Katari.Project.Resolve (ResolvedPackage (..), ResolvedProject (..), loadProjectOffline)
import Options.Applicative

data Options = Options
  { global :: GlobalOptions,
    projectRoot :: Maybe FilePath,
    -- | List every entry point in the escalation report, pure helpers included.
    allEntryPoints :: Bool,
    -- | Print warnings from dependency packages too, not just the project's own.
    dependencyWarnings :: Bool
  }
  deriving stock (Show)

-- | The two switches are separate rather than one @--all@ because they widen independent things (a
-- diagnostics stream and a report's row set), and because the escalation report is diffed as a
-- capability baseline: a flag that grows a second meaning later would silently change the bytes of
-- every invocation pinned to it.
optionsParser :: Parser Options
optionsParser =
  Options
    <$> globalOptionsParser
    <*> directoryOption
    <*> switch (long "all-entry-points" <> help "List every entry point, including those that escalate nothing")
    <*> switch (long "dependency-warnings" <> help "Also report warnings from dependency packages (errors always report)")

run :: Options -> IO ()
run options = do
  context <- newOutputContext options.global
  root <- resolveProjectRoot "check" options.projectRoot
  resolved <-
    loadProjectOffline emptyOverlay root >>= \case
      Left projectError -> dieIn "check" (renderProjectError projectError)
      Right loaded -> pure loaded
  sources <- assembleSourcesOrExit "check" resolved
  let warningScope =
        if options.dependencyWarnings
          then WarningsEverywhere
          else WarningsOwnedBy (ownedSourceFiles resolved)
  compileResult <- compileResultOrExit warningScope sources
  progress context ("OK — " <> Text.pack (show (Map.size compileResult.loweredModules)) <> " module(s), no errors")
  -- The escalation report: for each entry point in the PROJECT's own modules, the requests that ride
  -- unhandled to the run root. Read straight off the checked agents' types (nothing is re-inferred),
  -- scoped to the root package's modules so dependency internals never leak into the contract.
  let reports = entryPointReports (projectModules resolved) compileResult.typedModules
      entryPointScope = if options.allEntryPoints then ScopeAll else ScopeEscalating
  progress context (renderEntryPointSection entryPointScope reports)
  where
    -- The project's own modules, root module first (where @main@ lives, "mostly where things are
    -- called directly"), then the submodules alphabetically. Dependency packages are excluded — their
    -- entry points are library internals, not this program's contract.
    projectModules resolved =
      let rootModule = ModuleName resolved.rootPackage.config.package.name
          projectModuleNames = sort (Map.keys resolved.rootPackage.sources)
       in filter (== rootModule) projectModuleNames <> filter (/= rootModule) projectModuleNames
