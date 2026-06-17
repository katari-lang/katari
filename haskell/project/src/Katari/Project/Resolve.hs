-- | Multi-package project resolution.
--
-- Given a project root, walk the @[dependencies]@ graph, load every reachable package, and assemble
-- a single source map the compiler can consume (@Katari.Compile.CompileInput.sources@).
--
-- Module-name convention (validated, never rewritten): a dependency declared under key @P@ must
-- have @[package].name = "P"@ and lay its sources out so every module is @P@ or @P.\<sub>@. The
-- consumer's bare @import P@ then resolves to the package's same-named top module. The resolver
-- checks this layout; it does not prefix or transform module names.
--
-- Resolution mode is decided once: if @katari.lock@ exists we run /locked/ (every non-override dep
-- must be pinned by the lock); otherwise /fresh/ (non-override deps resolve through the registry
-- snapshot). Each resolved dependency records its 'ResolvedSource' provenance, so generating the
-- lockfile from a 'ResolvedProject' is a total projection — there is no synthetic snapshot and no
-- "this can't happen" failure path.
module Katari.Project.Resolve
  ( ResolvedProject (..),
    ResolvedPackage (..),
    ResolvedSource (..),
    ProjectAssembly (..),
    loadResolvedProject,
    assembleProject,
    lockfileFromResolved,
    compileInputSources,
  )
where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Katari.Data.ModuleName (ModuleName)
import Katari.Project.Config (ProjectConfig)
import Katari.Project.Discovery (SourceEntry)
import Katari.Project.Error (ProjectError)
import Katari.Project.Lockfile (Lockfile)

-- | How a resolved dependency was sourced — recorded so lockfile generation is a total projection.
data ResolvedSource
  = -- | Path override; the path is stored verbatim as written for the lockfile.
    FromPath FilePath
  | -- | Git override; 'sha' is the resolved tarball hash.
    FromGit {url :: Text, rev :: Text, sha :: Text}
  | -- | Snapshot pin; 'sha' is the verified tarball hash.
    FromSnapshot {repo :: Text, ref :: Text, sha :: Text}
  deriving (Show, Eq)

-- | One loaded package: its config and on-disk module sources, plus how it was sourced ('Nothing'
-- for the root package, which is the project itself).
data ResolvedPackage = ResolvedPackage
  { -- | Absolute canonical path of the directory containing this package's @katari.toml@.
    root :: FilePath,
    config :: ProjectConfig,
    -- | Module name → source, with names as written in the package's own source tree.
    sources :: Map ModuleName SourceEntry,
    provenance :: Maybe ResolvedSource
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

-- | Load a project rooted at @rootDir@ and recursively resolve every dependency (path overrides,
-- git overrides, and registry-snapshot pins), choosing locked vs. fresh mode by the presence of
-- @katari.lock@.
loadResolvedProject :: FilePath -> IO (Either ProjectError ResolvedProject)
loadResolvedProject = error "TODO: Katari.Project.Resolve.loadResolvedProject"

-- | Flatten a 'ResolvedProject': validate that each package's dep key agrees with its
-- @[package].name@ and that every module is inside the package's namespace, reject cross-package
-- module collisions, then union the source maps.
assembleProject :: ResolvedProject -> Either ProjectError ProjectAssembly
assembleProject = error "TODO: Katari.Project.Resolve.assembleProject"

-- | Project a 'ResolvedProject' into its 'Lockfile'. Total: every dependency already carries its
-- 'ResolvedSource' provenance.
lockfileFromResolved :: ResolvedProject -> Lockfile
lockfileFromResolved = error "TODO: Katari.Project.Resolve.lockfileFromResolved"

-- | The exact map @Katari.Compile.CompileInput@ keys on: module name → source text.
compileInputSources :: ProjectAssembly -> Map ModuleName Text
compileInputSources = error "TODO: Katari.Project.Resolve.compileInputSources"
