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
-- Resolution is /root-authoritative/ (a package-set model, like Cargo @[patch]@ or npm @overrides@):
-- the root project's @[overrides]@ and its single registry snapshot resolve the /entire/ transitive
-- closure. A dependency's own @[overrides]@ / @[dependencies].registry@ are not consulted, so every
-- reachable package — transitive included — must be resolvable from the root's snapshot or a root
-- override; one that is not is a 'Katari.Project.Error.ResolveUnresolvedDependency'. This keeps the
-- whole build on one coherent, conflict-free dependency set.
--
-- Two entry points, mirroring @npm install@ vs @npm ci@:
--
--   * 'resolveProject' — network-capable, run by @katari apply@ / @katari resolve@. Re-resolves from
--     @katari.toml@ + the registry and writes a fresh lockfile (via 'lockfileFromResolved'); the
--     caller owns the 'Manager'. An existing @katari.lock@ is consulted only as a cache hint, so an
--     unchanged dependency is not re-downloaded.
--
--   * 'loadProjectOffline' — pure disk + cache, never the network. @katari.lock@ is authoritative:
--     its packages are the full, already-flattened closure, so this neither re-walks the graph nor
--     needs the registry. A declared dependency missing from the lock is
--     'Katari.Project.Error.ResolveLockfileOutOfDate'; a locked package whose source tree is absent
--     from the cache is 'Katari.Project.Error.ResolvePackageNotCached'. This is what the LSP and
--     @katari build@ use, so neither blocks on the network. It takes a 'SourceOverlay' that feeds the
--     LSP's unsaved buffers into the root package.
module Katari.Project.Resolve
  ( ResolvedProject (..),
    ResolvedPackage (..),
    ProjectAssembly (..),
    loadProjectOffline,
    resolveProject,
    assembleProject,
    lockfileFromResolved,
    compileInputSources,
    checkPinnedSha,
  )
where

import Control.Monad (foldM, forM, forM_, unless, when)
import Control.Monad.Except (ExceptT, runExceptT, throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (StateT, evalStateT, get, modify')
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
  ( GitSource (..),
    LockedSource (..),
    Lockfile (..),
    PathLock (..),
    loadLockfile,
    lockfileFilename,
    lockfileFormatVersion,
  )
import Katari.Project.Snapshot (Snapshot (..), loadSnapshotFromUrl)
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
-- Resolution monad and shared package loaders
-- ===========================================================================

-- | Mutable resolution state: the flattened set of packages resolved so far (memoising diamonds),
-- and the registry snapshot once it has been loaded (loaded at most once, lazily on first need).
data ResolveState = ResolveState
  { resolved :: Map Text ResolvedPackage,
    snapshotCache :: Maybe Snapshot
  }

type ResolveM = ExceptT ProjectError (StateT ResolveState IO)

runResolveM :: ResolveM a -> IO (Either ProjectError a)
runResolveM action = evalStateT (runExceptT action) ResolveState {resolved = Map.empty, snapshotCache = Nothing}

-- | Run an @IO (Either ProjectError a)@ action inside 'ResolveM', short-circuiting on a 'Left'.
liftE :: IO (Either ProjectError a) -> ResolveM a
liftE action = liftIO action >>= either throwError pure

-- | Load a dependency's config + sources from an on-disk directory, tagging it with its provenance.
-- Dependencies never carry the LSP overlay (that is only the root, in 'loadProjectOffline').
loadResolvedPackage :: FilePath -> LockedSource -> ResolveM ResolvedPackage
loadResolvedPackage directory provenance = do
  config <- liftE (loadKatariToml (directory </> configFilename))
  sources <- liftE (scanSources emptyOverlay directory config)
  pure ResolvedPackage {root = directory, config = config, sources = sources, provenance = Just provenance}

-- | Load a path dependency: canonicalise the (possibly relative) location, require a @katari.toml@,
-- and load it. The location is recorded verbatim so the lockfile stays portable.
loadPathPackage :: FilePath -> Text -> FilePath -> ResolveM ResolvedPackage
loadPathPackage baseDir name location = do
  let candidate = if isAbsolute location then location else baseDir </> location
  canonical <- liftIO (canonicalizePath candidate)
  hasConfig <- liftIO (doesFileExist (canonical </> configFilename))
  unless hasConfig $ throwError (ResolveMissingConfig MissingConfigInfo {dependency = name, path = location})
  loadResolvedPackage canonical (LockedPath PathLock {location = location})

-- | Fetch a git ref into the cache and load it. @cacheSha@ skips the download on a cache hit;
-- @requiredSha@ (a snapshot pin) is verified against the fetched content.
loadGitPackage :: ResolveContext -> Text -> GitRef -> Maybe Text -> Maybe Text -> ResolveM ResolvedPackage
loadGitPackage context name ref cacheSha requiredSha = do
  (directory, sha) <- liftE (fetchGitTarball context.manager context.cache name ref cacheSha)
  either throwError pure (checkPinnedSha name requiredSha sha)
  loadResolvedPackage directory (LockedGit GitSource {url = ref.url, rev = ref.rev, sha = sha})

-- | Verify a fetched tarball's content hash against the pin that required it (a registry snapshot's
-- @sha256@). 'Nothing' means no pin to check against (a git override, trusted on first use). Pure, so
-- this supply-chain guard is testable without performing a real fetch.
checkPinnedSha :: Text -> Maybe Text -> Text -> Either ProjectError ()
checkPinnedSha name requiredSha actualSha = case requiredSha of
  Just expected
    | actualSha /= expected ->
        Left (ResolveShaMismatch ShaMismatchInfo {dependency = name, expected = expected, actual = actualSha})
  _ -> Right ()

-- ===========================================================================
-- Network resolution (npm install)
-- ===========================================================================

-- | The constant inputs of one resolution run: where the project is, its config (the single source
-- of overrides + registry/snapshot for the /whole/ closure), the HTTP manager, the cache, and the
-- prior lockfile's pins (used purely as download-skipping cache hints).
data ResolveContext = ResolveContext
  { rootDir :: FilePath,
    rootConfig :: ProjectConfig,
    manager :: Manager,
    cache :: CachePaths,
    priorPins :: Map Text GitSource
  }

-- | Load a project rooted at @rootDir@ and recursively resolve every dependency, fetching as needed
-- over @manager@. Used by @katari apply@ / @katari resolve@ to (re)generate the lockfile.
resolveProject :: Manager -> FilePath -> IO (Either ProjectError ResolvedProject)
resolveProject manager rootDir = runResolveM (resolveProjectM manager rootDir)

resolveProjectM :: Manager -> FilePath -> ResolveM ResolvedProject
resolveProjectM manager rootDir = do
  canonicalRoot <- liftIO (canonicalizePath rootDir)
  rootConfig <- liftE (loadKatariToml (canonicalRoot </> configFilename))
  rootSources <- liftE (scanSources emptyOverlay canonicalRoot rootConfig)
  let cache = projectCachePaths canonicalRoot
  liftIO (ensureCacheDirs cache)
  priorPins <- liftIO (loadPriorPins (canonicalRoot </> lockfileFilename))
  let context =
        ResolveContext
          { rootDir = canonicalRoot,
            rootConfig = rootConfig,
            manager = manager,
            cache = cache,
            priorPins = priorPins
          }
  forM_ rootConfig.dependencies.packages (resolveDependency context [])
  finalState <- get
  pure
    ResolvedProject
      { rootPackage = ResolvedPackage {root = canonicalRoot, config = rootConfig, sources = rootSources, provenance = Nothing},
        depPackages = finalState.resolved
      }

-- | Resolve one dependency name (and, transitively, its own dependencies) into resolution state.
-- @chain@ is the path of names currently being resolved, used for cycle detection; a name already in
-- 'resolved' is a diamond and returns immediately.
resolveDependency :: ResolveContext -> List Text -> Text -> ResolveM ()
resolveDependency context chain name = do
  when (name `elem` chain) $
    throwError (ResolveCycle DependencyCycleInfo {cycle = reverse (name : chain)})
  state <- get
  case Map.lookup name state.resolved of
    Just _ -> pure ()
    Nothing -> do
      package <- locateDependency context name
      modify' (\current -> current {resolved = Map.insert name package current.resolved})
      -- A dependency's own dependencies resolve against the SAME root context (root-authoritative).
      forM_ package.config.dependencies.packages (resolveDependency context (name : chain))

-- | Decide where a single dependency comes from: a root path override, a root git override, or the
-- registry snapshot pin.
locateDependency :: ResolveContext -> Text -> ResolveM ResolvedPackage
locateDependency context name = case Map.lookup name context.rootConfig.overrides of
  Just (OverridePath override) -> loadPathPackage context.rootDir name override.path
  Just (OverrideGit override) ->
    let ref = GitRef {url = override.url, rev = override.rev}
     in loadGitPackage context name ref (cacheHint context name ref) Nothing
  Nothing -> resolveSnapshotDependency context name

-- | A git override's content hash is unknown until fetched, but if the prior lockfile pinned the
-- same @(url, rev)@ its sha lets the cache short-circuit the download.
cacheHint :: ResolveContext -> Text -> GitRef -> Maybe Text
cacheHint context name ref = case Map.lookup name context.priorPins of
  Just pin | pin.url == ref.url && pin.rev == ref.rev -> Just pin.sha
  _ -> Nothing

resolveSnapshotDependency :: ResolveContext -> Text -> ResolveM ResolvedPackage
resolveSnapshotDependency context name = do
  snapshot <- requireSnapshot context name
  case Map.lookup name snapshot.packages of
    Nothing -> throwError (ResolveUnresolvedDependency DependencyInfo {dependency = name})
    -- The pin's sha is both the cache hint (skip download if held) and the required hash (verify).
    Just pin -> loadGitPackage context name GitRef {url = pin.url, rev = pin.rev} (Just pin.sha) (Just pin.sha)

-- | The registry snapshot, loaded at most once. A dependency that needs the snapshot but has no
-- @[dependencies].registry@ to load it from is simply unresolvable.
requireSnapshot :: ResolveContext -> Text -> ResolveM Snapshot
requireSnapshot context name = do
  state <- get
  case state.snapshotCache of
    Just snapshot -> pure snapshot
    Nothing -> case context.rootConfig.dependencies.registry of
      Nothing -> throwError (ResolveUnresolvedDependency DependencyInfo {dependency = name})
      Just registry -> do
        snapshot <- liftE (loadSnapshotFromUrl context.manager registry context.rootConfig.dependencies.snapshot)
        modify' (\current -> current {snapshotCache = Just snapshot})
        pure snapshot

-- | The prior lockfile's git pins, keyed by dependency name, for cache reuse. Absent or unreadable
-- lock → no hints (a regenerating @apply@ must not be blocked by a stale lock).
loadPriorPins :: FilePath -> IO (Map Text GitSource)
loadPriorPins path = do
  exists <- doesFileExist path
  if not exists
    then pure Map.empty
    else do
      result <- loadLockfile path
      pure $ case result of
        Left _ -> Map.empty
        Right lockfile -> Map.mapMaybe gitSourceOf lockfile.packages
  where
    gitSourceOf lockedSource = case lockedSource of
      LockedGit gitSource -> Just gitSource
      LockedPath _ -> Nothing

-- ===========================================================================
-- Offline load (npm ci)
-- ===========================================================================

-- | Load a project rooted at @rootDir@ from disk and cache only, using @katari.lock@; never touches
-- the network. The 'SourceOverlay' applies to the root package (the LSP's unsaved buffers).
loadProjectOffline :: SourceOverlay -> FilePath -> IO (Either ProjectError ResolvedProject)
loadProjectOffline overlay rootDir = runResolveM (loadProjectOfflineM overlay rootDir)

loadProjectOfflineM :: SourceOverlay -> FilePath -> ResolveM ResolvedProject
loadProjectOfflineM overlay rootDir = do
  canonicalRoot <- liftIO (canonicalizePath rootDir)
  rootConfig <- liftE (loadKatariToml (canonicalRoot </> configFilename))
  rootSources <- liftE (scanSources overlay canonicalRoot rootConfig)
  let cache = projectCachePaths canonicalRoot
  lockfile <- loadLockfileOrEmpty (canonicalRoot </> lockfileFilename)
  -- A root-declared dependency missing from the lock means the lock is stale; check before loading so
  -- the remedy is reported against the lock rather than as a downstream cache miss.
  forM_ rootConfig.dependencies.packages (requireLocked lockfile)
  dependencyPackages <- forM (Map.toList lockfile.packages) $ \(name, lockedSource) ->
    (name,) <$> loadLockedPackage canonicalRoot cache name lockedSource
  -- The lock must be the full, already-flattened closure: any dependency a locked package itself
  -- declares must also be locked, or assembly would later see a dangling import for a silently
  -- dropped transitive package.
  forM_ dependencyPackages $ \(_, package) ->
    forM_ package.config.dependencies.packages (requireLocked lockfile)
  pure
    ResolvedProject
      { rootPackage = ResolvedPackage {root = canonicalRoot, config = rootConfig, sources = rootSources, provenance = Nothing},
        depPackages = Map.fromList dependencyPackages
      }
  where
    requireLocked lockfile name =
      unless (Map.member name lockfile.packages) $
        throwError (ResolveLockfileOutOfDate DependencyInfo {dependency = name})

-- | Read @katari.lock@, or an empty lockfile when the file is absent (a project with no dependencies
-- needs no lock; the per-dependency check above turns a real omission into 'ResolveLockfileOutOfDate').
loadLockfileOrEmpty :: FilePath -> ResolveM Lockfile
loadLockfileOrEmpty path = do
  exists <- liftIO (doesFileExist path)
  if exists
    then liftE (loadLockfile path)
    else pure Lockfile {version = lockfileFormatVersion, snapshot = Nothing, packages = Map.empty}

-- | Load one locked dependency from where its 'LockedSource' says it lives, all from disk/cache.
loadLockedPackage :: FilePath -> CachePaths -> Text -> LockedSource -> ResolveM ResolvedPackage
loadLockedPackage rootDir cache name lockedSource = case lockedSource of
  LockedPath lock -> loadPathPackage rootDir name lock.location
  LockedGit lock -> do
    let directory = packageDir cache name lock.sha
    exists <- liftIO (doesDirectoryExist directory)
    unless exists $ throwError (ResolvePackageNotCached NotCachedInfo {dependency = name, expectedPath = directory})
    loadResolvedPackage directory lockedSource

-- ===========================================================================
-- Assembly / projection
-- ===========================================================================

-- | Flatten a 'ResolvedProject': validate that each dependency package's key agrees with its
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
    Left (ResolveInvalidPackageName PackageNameInfo {name = name})
  when (isReservedModuleName (ModuleName name)) $
    Left (ResolveReservedPackageName PackageNameInfo {name = name})
  unless (package.config.package.name == name) $
    Left (ResolveDependencyNameMismatch DependencyNameMismatchInfo {declaredKey = name, actualName = package.config.package.name})
  let namespaceRoot = ModuleName name
  forM_ (Map.keys package.sources) $ \moduleName ->
    unless (namespaceRoot `covers` moduleName) $
      Left (ResolveOutOfNamespace OutOfNamespaceInfo {package = name, moduleName = moduleName})
  pure [(moduleName, (name, entry)) | (moduleName, entry) <- Map.toList package.sources]

-- | Insert one owned entry into the merged map, failing on a cross-package module-name collision.
mergeEntry ::
  Map ModuleName (Text, SourceEntry) ->
  (ModuleName, (Text, SourceEntry)) ->
  Either ProjectError (Map ModuleName (Text, SourceEntry))
mergeEntry accumulated (moduleName, owned@(owner, _)) = case Map.lookup moduleName accumulated of
  Just (existingOwner, _) ->
    Left (ResolveModuleCollision ModuleCollisionInfo {moduleName = moduleName, firstPackage = existingOwner, secondPackage = owner})
  Nothing -> Right (Map.insert moduleName owned accumulated)

-- | Project a 'ResolvedProject' into its 'Lockfile'. Total: every dependency carries its
-- 'LockedSource' provenance (the root, the only package with 'Nothing', is not a dependency).
lockfileFromResolved :: ResolvedProject -> Lockfile
lockfileFromResolved project =
  Lockfile
    { version = lockfileFormatVersion,
      snapshot = project.rootPackage.config.dependencies.snapshot,
      packages = Map.mapMaybe (\package -> package.provenance) project.depPackages
    }

-- | The exact map @Katari.Compile.CompileInput@ keys on: module name → source text.
compileInputSources :: ProjectAssembly -> Map ModuleName Text
compileInputSources assembly = Map.map (\entry -> entry.text) assembly.sources
