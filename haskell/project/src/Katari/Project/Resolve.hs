-- | Multi-package project resolution.
--
-- Given a project root, walk the @[dependencies]@ graph, load every reachable package, and assemble
-- a single source map the compiler can consume (@Katari.Compile.CompileInput.sources@).
--
-- Module-name convention (validated, never rewritten): a dependency declared under key @P@ must
-- have @[package].name = "P"@ and lay its sources out so every module is @P@ or @P.\<sub>@. The
-- consumer's bare @import P@ then resolves to the package's same-named top module. The resolver
-- checks this layout; it does not prefix or transform module names. It also rejects a dependency
-- whose name is reserved by the compiler (the @primitive@ / stdlib namespace), so the failure is
-- reported here rather than as a K2008 against the dependency's own source.
--
-- Two entry points, by who is calling:
--
--   * 'loadProjectOffline' — pure disk + cache, never the network. The lockfile must exist and every
--     non-path dependency it pins must already be in the cache; a missing one is
--     'Katari.Project.Error.ResolvePackageNotCached'. This is what the LSP and @katari build@ use, so
--     neither blocks an editor keystroke or an offline build on a network round-trip. It takes a
--     'SourceOverlay' that feeds the LSP's unsaved buffers into the root package.
--
--   * 'resolveProject' — network-capable, run by @katari apply@ / @katari resolve@. Fresh mode
--     resolves non-override deps through the registry snapshot and fetches their tarballs; the caller
--     owns the 'Manager'. The resulting 'ResolvedProject' records each dependency's provenance, so
--     'lockfileFromResolved' is a total projection.
module Katari.Project.Resolve
  ( ResolvedProject (..),
    ResolvedPackage (..),
    ProjectAssembly (..),
    loadProjectOffline,
    resolveProject,
    assembleProject,
    lockfileFromResolved,
    compileInputSources,
  )
where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Katari.Data.ModuleName (ModuleName)
import Katari.Project.Config (ProjectConfig)
import Katari.Project.Discovery (SourceEntry, SourceOverlay)
import Katari.Project.Error (ProjectError)
import Katari.Project.Lockfile (LockedSource, Lockfile)
import Network.HTTP.Client (Manager)

-- | One loaded package: its config and on-disk module sources, plus how it was sourced ('Nothing'
-- for the root package, which is the project itself). 'provenance' is the lockfile's 'LockedSource',
-- reused directly so there is no parallel "resolved source" type.
data ResolvedPackage = ResolvedPackage
  { -- | Absolute canonical path of the directory containing this package's @katari.toml@.
    root :: FilePath,
    config :: ProjectConfig,
    -- | Module name → source, with names as written in the package's own source tree.
    sources :: Map ModuleName SourceEntry,
    provenance :: Maybe LockedSource
  }
  deriving (Show)

-- | The full transitive closure starting from the root @katari.toml@. 'depPackages' is keyed by the
-- dependency name (the @import@ name) and excludes the root.
data ResolvedProject = ResolvedProject
  { rootPackage :: ResolvedPackage,
    depPackages :: Map Text ResolvedPackage
  }
  deriving (Show)

-- | A flattened, namespace-validated, collision-free view of a 'ResolvedProject', ready for the
-- compiler.
newtype ProjectAssembly = ProjectAssembly
  { sources :: Map ModuleName SourceEntry
  }
  deriving (Show)

-- | Load a project rooted at @rootDir@ from disk and cache only, using @katari.lock@; never touches
-- the network. The 'SourceOverlay' applies to the root package (the LSP's unsaved buffers).
loadProjectOffline :: SourceOverlay -> FilePath -> IO (Either ProjectError ResolvedProject)
loadProjectOffline = error "TODO: Katari.Project.Resolve.loadProjectOffline"

-- | Load a project rooted at @rootDir@ and recursively resolve every dependency (path overrides,
-- git overrides, and registry-snapshot pins), fetching as needed over @manager@. Used by
-- @katari apply@ / @katari resolve@ to (re)generate the lockfile.
resolveProject :: Manager -> FilePath -> IO (Either ProjectError ResolvedProject)
resolveProject = error "TODO: Katari.Project.Resolve.resolveProject"

-- | Flatten a 'ResolvedProject': validate that each package's dep key agrees with its
-- @[package].name@, that its name is not compiler-reserved, and that every module is inside the
-- package's namespace, reject cross-package module collisions, then union the source maps.
assembleProject :: ResolvedProject -> Either ProjectError ProjectAssembly
assembleProject = error "TODO: Katari.Project.Resolve.assembleProject"

-- | Project a 'ResolvedProject' into its 'Lockfile'. Total: every dependency already carries its
-- 'LockedSource' provenance.
lockfileFromResolved :: ResolvedProject -> Lockfile
lockfileFromResolved = error "TODO: Katari.Project.Resolve.lockfileFromResolved"

-- | The exact map @Katari.Compile.CompileInput@ keys on: module name → source text.
compileInputSources :: ProjectAssembly -> Map ModuleName Text
compileInputSources = error "TODO: Katari.Project.Resolve.compileInputSources"
