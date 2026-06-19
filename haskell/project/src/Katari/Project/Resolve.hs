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

import Control.Monad (foldM, forM, forM_, unless, when)
import Control.Monad.Except (ExceptT (..), MonadError (throwError), runExceptT)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (StateT, get, modify', runStateT)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.ModuleName (ModuleName (..), covers)
import Katari.Project.Cache (CachePaths, ensureCacheDirs, packageDir, projectCachePaths)
import Katari.Project.Config
  ( DependenciesSection (..),
    GitOverride (..),
    OverrideSource (..),
    PackageSection (..),
    PathOverride (..),
    ProjectConfig (..),
    isValidPackageName,
    loadKatariToml,
  )
import Katari.Project.Discovery
  ( SourceEntry (..),
    SourceOverlay,
    configFilename,
    emptyOverlay,
    scanSources,
  )
import Katari.Project.Error
  ( DependencyCycleInfo (..),
    DependencyInfo (..),
    DependencyNameMismatchInfo (..),
    MissingConfigInfo (..),
    ModuleCollisionInfo (..),
    NotCachedInfo (..),
    OutOfNamespaceInfo (..),
    PackageNameInfo (..),
    ProjectError (..),
    ShaMismatchInfo (..),
  )
import Katari.Project.Fetch (GitRef (..), fetchGitTarball)
import Katari.Project.Lockfile
  ( GitLock (..),
    LockedPackage (..),
    LockedSource (..),
    Lockfile (..),
    PathLock (..),
    SnapshotLock (..),
    loadLockfile,
    lockfileFilename,
  )
import Katari.Project.Snapshot (Snapshot (..), SnapshotPackage (..), loadSnapshotFromUrl)
import Katari.Stdlib (isReservedModuleName)
import Network.HTTP.Client (Manager)
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist)
import System.FilePath (isAbsolute, (</>))

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

-- ===========================================================================
-- Offline load (disk + cache only)
-- ===========================================================================

-- | Load a project rooted at @rootDir@ from disk and cache only, using @katari.lock@; never touches
-- the network. The 'SourceOverlay' applies to the root package (the LSP's unsaved buffers).
--
-- The lockfile is the source of truth offline: its packages are the full (already flattened)
-- dependency closure, so this neither re-walks the graph nor needs the registry. A direct dependency
-- present in @katari.toml@ but absent from the lock is a 'ResolveLockfileOutOfDate'; a locked package
-- whose source tree is not on disk / in the cache is a 'ResolvePackageNotCached'.
loadProjectOffline :: SourceOverlay -> FilePath -> IO (Either ProjectError ResolvedProject)
loadProjectOffline overlay rootDir = runExceptT $ do
  canonicalRoot <- liftIO (canonicalizePath rootDir)
  rootConfig <- ExceptT (loadKatariToml (canonicalRoot </> configFilename))
  rootSources <- ExceptT (scanSources overlay canonicalRoot rootConfig)
  let cache = projectCachePaths canonicalRoot
  lockfile <- loadLockfileOrEmpty (canonicalRoot </> lockfileFilename)
  forM_ rootConfig.dependencies.packages $ \name ->
    unless (Map.member name lockfile.packages) $
      throwError (ResolveLockfileOutOfDate (DependencyInfo {dependency = name}))
  dependencyPackages <- forM (Map.toList lockfile.packages) $ \(name, lockedPackage) ->
    (name,) <$> loadLockedPackage canonicalRoot cache name lockedPackage
  pure
    ResolvedProject
      { rootPackage =
          ResolvedPackage
            { root = canonicalRoot,
              config = rootConfig,
              sources = rootSources,
              provenance = Nothing
            },
        depPackages = Map.fromList dependencyPackages
      }

-- | Read @katari.lock@, or an empty lockfile when the file is absent (a project with no
-- dependencies needs no lock; the per-dependency check above turns a real omission into
-- 'ResolveLockfileOutOfDate').
loadLockfileOrEmpty :: FilePath -> ExceptT ProjectError IO Lockfile
loadLockfileOrEmpty path = do
  exists <- liftIO (doesFileExist path)
  if exists
    then ExceptT (loadLockfile path)
    else pure Lockfile {version = 1, snapshot = Nothing, packages = Map.empty}

-- | Load one locked dependency's package from where its 'LockedSource' says it lives.
loadLockedPackage :: FilePath -> CachePaths -> Text -> LockedPackage -> ExceptT ProjectError IO ResolvedPackage
loadLockedPackage rootDir cache name lockedPackage = case lockedPackage.source of
  LockedPath lock -> do
    let candidate = if isAbsolute lock.location then lock.location else rootDir </> lock.location
    canonical <- liftIO (canonicalizePath candidate)
    hasConfig <- liftIO (doesFileExist (canonical </> configFilename))
    unless hasConfig $
      throwError (ResolveMissingConfig (MissingConfigInfo {dependency = name, path = lock.location}))
    loadPackageFrom canonical lockedPackage.source
  LockedGit lock -> loadCachedPackage cache name lock.sha lockedPackage.source
  LockedSnapshot lock -> loadCachedPackage cache name lock.sha lockedPackage.source

-- | Load a content-addressed dependency from @\<cache>/packages/\<name>-\<sha>@, failing with
-- 'ResolvePackageNotCached' when that directory is not present.
loadCachedPackage :: CachePaths -> Text -> Text -> LockedSource -> ExceptT ProjectError IO ResolvedPackage
loadCachedPackage cache name sha source = do
  let directory = packageDir cache name sha
  exists <- liftIO (doesDirectoryExist directory)
  unless exists $
    throwError (ResolvePackageNotCached (NotCachedInfo {dependency = name, expectedPath = directory}))
  loadPackageFrom directory source

-- | Load a package's config + sources from an on-disk directory, tagging it with its provenance.
loadPackageFrom :: FilePath -> LockedSource -> ExceptT ProjectError IO ResolvedPackage
loadPackageFrom directory source = do
  config <- ExceptT (loadKatariToml (directory </> configFilename))
  sources <- ExceptT (scanSources emptyOverlay directory config)
  pure ResolvedPackage {root = directory, config = config, sources = sources, provenance = Just source}

-- ===========================================================================
-- Network resolution
-- ===========================================================================

-- | The constant inputs of one resolution run: where the project is, its config (the single source
-- of overrides + registry/snapshot for the /whole/ closure), the HTTP manager, and the cache.
data ResolveContext = ResolveContext
  { rootDir :: FilePath,
    rootConfig :: ProjectConfig,
    manager :: Manager,
    cache :: CachePaths
  }

-- | Mutable resolution state: the flattened set of packages resolved so far (memoising diamonds), and
-- the registry snapshot once it has been loaded (loaded at most once, lazily on first need).
data ResolveState = ResolveState
  { resolved :: Map Text ResolvedPackage,
    snapshotCache :: Maybe Snapshot
  }

type ResolveM = ExceptT ProjectError (StateT ResolveState IO)

-- | Load a project rooted at @rootDir@ and recursively resolve every dependency (path overrides,
-- git overrides, and registry-snapshot pins), fetching as needed over @manager@. Used by
-- @katari apply@ / @katari resolve@ to (re)generate the lockfile.
resolveProject :: Manager -> FilePath -> IO (Either ProjectError ResolvedProject)
resolveProject manager rootDir = do
  (result, _) <- runStateT (runExceptT (resolveProjectM manager rootDir)) initialState
  pure result
  where
    initialState = ResolveState {resolved = Map.empty, snapshotCache = Nothing}

resolveProjectM :: Manager -> FilePath -> ResolveM ResolvedProject
resolveProjectM manager rootDir = do
  canonicalRoot <- liftIO (canonicalizePath rootDir)
  rootConfig <- liftE (loadKatariToml (canonicalRoot </> configFilename))
  rootSources <- liftE (scanSources emptyOverlay canonicalRoot rootConfig)
  let cache = projectCachePaths canonicalRoot
  liftIO (ensureCacheDirs cache)
  let context = ResolveContext {rootDir = canonicalRoot, rootConfig = rootConfig, manager = manager, cache = cache}
  forM_ rootConfig.dependencies.packages (resolveDependency context [])
  finalState <- get
  pure
    ResolvedProject
      { rootPackage =
          ResolvedPackage
            { root = canonicalRoot,
              config = rootConfig,
              sources = rootSources,
              provenance = Nothing
            },
        depPackages = finalState.resolved
      }

-- | Resolve one dependency name (and, transitively, its own dependencies) into resolution state.
-- @chain@ is the path of names currently being resolved, used for cycle detection; a name already in
-- 'resolved' is a diamond and returns immediately.
resolveDependency :: ResolveContext -> List Text -> Text -> ResolveM ()
resolveDependency context chain name = do
  when (name `elem` chain) $
    throwError (ResolveCycle (DependencyCycleInfo {cycle = reverse (name : chain)}))
  state <- get
  case Map.lookup name state.resolved of
    Just _ -> pure ()
    Nothing -> do
      package <- locateDependency context name
      modify' (\current -> current {resolved = Map.insert name package current.resolved})
      -- A dependency's own dependencies resolve against the SAME root context (root overrides + the
      -- one registry snapshot), so the whole closure shares a single, consistent resolution.
      forM_ package.config.dependencies.packages (resolveDependency context (name : chain))

-- | Decide where a single dependency comes from: a root path override, a root git override, or the
-- registry snapshot pin.
locateDependency :: ResolveContext -> Text -> ResolveM ResolvedPackage
locateDependency context name = case Map.lookup name context.rootConfig.overrides of
  Just (OverridePath override) -> resolvePathDependency context name override
  Just (OverrideGit override) -> resolveGitDependency context name override
  Nothing -> resolveSnapshotDependency context name

resolvePathDependency :: ResolveContext -> Text -> PathOverride -> ResolveM ResolvedPackage
resolvePathDependency context name override = do
  let candidate = if isAbsolute override.path then override.path else context.rootDir </> override.path
  canonical <- liftIO (canonicalizePath candidate)
  hasConfig <- liftIO (doesFileExist (canonical </> configFilename))
  unless hasConfig $
    throwError (ResolveMissingConfig (MissingConfigInfo {dependency = name, path = override.path}))
  config <- liftE (loadKatariToml (canonical </> configFilename))
  sources <- liftE (scanSources emptyOverlay canonical config)
  -- The path is stored verbatim (as written, usually relative) so the lockfile stays portable.
  pure
    ResolvedPackage
      { root = canonical,
        config = config,
        sources = sources,
        provenance = Just (LockedPath PathLock {location = override.path})
      }

resolveGitDependency :: ResolveContext -> Text -> GitOverride -> ResolveM ResolvedPackage
resolveGitDependency context name override = do
  (directory, sha) <-
    liftE (fetchGitTarball context.manager context.cache name GitRef {url = override.url, rev = override.rev})
  config <- liftE (loadKatariToml (directory </> configFilename))
  sources <- liftE (scanSources emptyOverlay directory config)
  pure
    ResolvedPackage
      { root = directory,
        config = config,
        sources = sources,
        provenance = Just (LockedGit GitLock {url = override.url, rev = override.rev, sha = sha})
      }

resolveSnapshotDependency :: ResolveContext -> Text -> ResolveM ResolvedPackage
resolveSnapshotDependency context name = do
  snapshot <- requireSnapshot context name
  case Map.lookup name snapshot.packages of
    Nothing -> throwError (ResolveUnresolvedDependency (DependencyInfo {dependency = name}))
    Just pin -> do
      let cachedDir = packageDir context.cache name pin.sha
      cached <- liftIO (doesDirectoryExist cachedDir)
      directory <-
        if cached
          then pure cachedDir
          else do
            (fetchedDir, fetchedSha) <-
              liftE (fetchGitTarball context.manager context.cache name GitRef {url = pin.url, rev = pin.rev})
            when (fetchedSha /= pin.sha) $
              throwError (ResolveShaMismatch (ShaMismatchInfo {dependency = name, expected = pin.sha, actual = fetchedSha}))
            pure fetchedDir
      config <- liftE (loadKatariToml (directory </> configFilename))
      sources <- liftE (scanSources emptyOverlay directory config)
      pure
        ResolvedPackage
          { root = directory,
            config = config,
            sources = sources,
            provenance = Just (LockedSnapshot SnapshotLock {url = pin.url, rev = pin.rev, sha = pin.sha})
          }

-- | The registry snapshot, loaded at most once. A dependency that needs the snapshot but has no
-- @[dependencies].registry@ to load it from is simply unresolvable.
requireSnapshot :: ResolveContext -> Text -> ResolveM Snapshot
requireSnapshot context name = do
  state <- get
  case state.snapshotCache of
    Just snapshot -> pure snapshot
    Nothing -> case context.rootConfig.dependencies.registry of
      Nothing -> throwError (ResolveUnresolvedDependency (DependencyInfo {dependency = name}))
      Just registry -> do
        snapshot <- liftE (loadSnapshotFromUrl context.manager registry context.rootConfig.dependencies.snapshot)
        modify' (\current -> current {snapshotCache = Just snapshot})
        pure snapshot

-- | Run an @IO (Either ProjectError a)@ action inside 'ResolveM', short-circuiting on a 'Left'.
liftE :: IO (Either ProjectError a) -> ResolveM a
liftE action = liftIO action >>= either throwError pure

-- ===========================================================================
-- Assembly / projection
-- ===========================================================================

-- | Flatten a 'ResolvedProject': validate that each package's dep key agrees with its
-- @[package].name@, that its name is not compiler-reserved, and that every module is inside the
-- package's namespace, reject cross-package module collisions, then union the source maps.
--
-- The root package is exempt from the namespace check — it is the top program, free to name its
-- modules anything — but it still participates in collision detection against the dependencies.
assembleProject :: ResolvedProject -> Either ProjectError ProjectAssembly
assembleProject project = do
  let rootOwner = project.rootPackage.config.package.name
      rootEntries = [(moduleName, (rootOwner, entry)) | (moduleName, entry) <- Map.toList project.rootPackage.sources]
  dependencyEntryGroups <- traverse validateDependencyPackage (Map.toList project.depPackages)
  merged <- foldM mergeEntry Map.empty (rootEntries <> concat dependencyEntryGroups)
  pure (ProjectAssembly {sources = Map.map snd merged})

-- | Validate one dependency package and return its (module, (owner, entry)) contributions.
validateDependencyPackage :: (Text, ResolvedPackage) -> Either ProjectError (List (ModuleName, (Text, SourceEntry)))
validateDependencyPackage (name, package) = do
  unless (isValidPackageName name) $
    Left (ResolveInvalidPackageName (PackageNameInfo {name = name}))
  when (isReservedModuleName (ModuleName name)) $
    Left (ResolveReservedPackageName (PackageNameInfo {name = name}))
  unless (package.config.package.name == name) $
    Left
      ( ResolveDependencyNameMismatch
          DependencyNameMismatchInfo {declaredKey = name, actualName = package.config.package.name}
      )
  let namespaceRoot = ModuleName name
  forM_ (Map.keys package.sources) $ \moduleName ->
    unless (namespaceRoot `covers` moduleName) $
      Left (ResolveOutOfNamespace (OutOfNamespaceInfo {package = name, moduleName = moduleName}))
  pure [(moduleName, (name, entry)) | (moduleName, entry) <- Map.toList package.sources]

-- | Insert one owned entry into the merged map, failing on a cross-package module-name collision.
mergeEntry ::
  Map ModuleName (Text, SourceEntry) ->
  (ModuleName, (Text, SourceEntry)) ->
  Either ProjectError (Map ModuleName (Text, SourceEntry))
mergeEntry accumulated (moduleName, owned@(owner, _)) = case Map.lookup moduleName accumulated of
  Just (existingOwner, _) ->
    Left
      ( ResolveModuleCollision
          ModuleCollisionInfo {moduleName = moduleName, firstPackage = existingOwner, secondPackage = owner}
      )
  Nothing -> Right (Map.insert moduleName owned accumulated)

-- | Project a 'ResolvedProject' into its 'Lockfile'. Total: every dependency already carries its
-- 'LockedSource' provenance (the root, the only package with 'Nothing', is not a dependency).
lockfileFromResolved :: ResolvedProject -> Lockfile
lockfileFromResolved project =
  Lockfile
    { version = 1,
      snapshot = project.rootPackage.config.dependencies.snapshot,
      packages = Map.mapMaybeWithKey toLockedPackage project.depPackages
    }
  where
    toLockedPackage name package =
      fmap (\source -> LockedPackage {name = name, source = source}) package.provenance

-- | The exact map @Katari.Compile.CompileInput@ keys on: module name → source text.
compileInputSources :: ProjectAssembly -> Map ModuleName Text
compileInputSources assembly = Map.map (\entry -> entry.text) assembly.sources
