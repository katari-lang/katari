-- | Multi-package project resolution.
--
-- Given a path inside a Katari project, walk the @[dependencies.*]@
-- graph (path deps only in v1), load every reachable package, and
-- assemble a single 'Compile.CompileInput' the compiler can consume.
--
-- Module-name layout:
--
--   * Root package's modules keep their bare relative-path name.
--     @src\/main.ktr@ → module @main@; @src\/foo\/bar.ktr@ → module
--     @foo.bar@.
--   * Dependency package @P@'s modules are prefixed: dep @list-utils@
--     with @src\/main.ktr@ becomes module @list-utils.main@.
--   * Package names must be valid Katari identifiers (alphanumeric +
--     underscore) so they round-trip through Katari source as module
--     references.
--
-- Sibling imports inside a dependency keep their natural form: the
-- consumers' bare @import P@ desugars via 'Compile.packageMainModules'
-- to @P.\<main_module>@; all other references are fully qualified.
module Katari.Project.Resolve
  ( ResolvedProject (..),
    ResolvedPackage (..),
    ResolveError (..),
    ProjectAssembly (..),
    loadResolvedProject,
    assembleProject,
    lockfileFromResolved,
    renderResolveError,
  )
where

import qualified Katari.Project.Cache as Cache
import qualified Katari.Project.Fetch as Fetch
import qualified Katari.Project.Lockfile as Lock
import qualified Katari.Project.Snapshot as Snapshot

import Control.Monad (foldM)
import Data.Maybe (isJust, mapMaybe)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Katari.Project.Config
  ( ConfigError (..),
    DependenciesSection (..),
    OverrideSource (..),
    PackageSection (..),
    ProjectConfig (..),
    isValidPackageName,
    loadKatariToml,
  )
import Katari.Project.Discovery (SourceEntry (..), configFilename, scanSources)
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (isAbsolute, (</>))

-- ===========================================================================
-- Data
-- ===========================================================================

-- | One loaded package (its config + its on-disk module sources).
data ResolvedPackage = ResolvedPackage
  { -- | Absolute canonical path of the directory containing this
    -- package's @katari.toml@.
    packageRoot :: FilePath,
    -- | The package's parsed config.
    packageConfig :: ProjectConfig,
    -- | Module name (as written in the package's own source tree, i.e.
    -- relative to its @[compile].src@) → 'SourceEntry'.
    packageSources :: Map Text SourceEntry,
    -- | For git-sourced packages, the resolved hex SHA-256 of the
    -- downloaded tarball. 'Nothing' for path sources.
    packageSha :: Maybe Text,
    -- | For snapshot-resolved packages, the @(repo, ref)@ tuple the
    -- registry pinned. Used by lockfile generation to record the
    -- snapshot resolution. 'Nothing' for path / pure-git override.
    packageSnapshotPin :: Maybe (Text, Text)
  }
  deriving (Show)

-- | The full transitive closure starting from the root @katari.toml@.
data ResolvedProject = ResolvedProject
  { rootPackage :: ResolvedPackage,
    -- | Every dependency reachable from the root, keyed by package
    -- name. The root package is NOT included here.
    depPackages :: Map Text ResolvedPackage
  }
  deriving (Show)

data ResolveError
  = -- | A @katari.toml@ along the dep chain failed to load or parse.
    -- The path identifies the offending file.
    ResolveConfigError ConfigError
  | -- | The dep chain contains a cycle. The list shows the cycle path
    -- starting and ending with the same package name.
    ResolveCycle [Text]
  | -- | A path dependency points at a directory that has no
    -- @katari.toml@.
    ResolveMissingConfig Text FilePath
  | -- | Same dep name resolved to two different package roots.
    -- @v1@ rejects this conservatively rather than picking a winner.
    ResolveAmbiguousDep Text FilePath FilePath
  | -- | A package name contains a character outside of @[A-Za-z0-9_]@
    -- (= cannot appear as a Katari identifier).
    ResolveInvalidPackageName Text
  | -- | Two reachable packages contribute the same module key. This is
    -- a setup error — one of them mis-named its sources.
    ResolveModuleCollision Text
  | -- | A package's @src\/@ contains a file whose module name does not
    -- start with the package's namespace. Args: package name, offending
    -- module name.
    ResolveOutOfNamespace Text Text
  | -- | A dependency's @[package].name@ disagrees with the key it is
    -- declared under. Args: declared key, actual package name.
    ResolveDepNameMismatch Text Text
  | -- | A @[dependencies].\<name> = \"*\"@ entry has no matching entry
    -- in the snapshot file (or no snapshot is configured at all).
    -- Args: dependency name.
    ResolveUnresolvedDependency Text
  | -- | @katari.lock@ doesn't contain an entry for a dep listed in
    -- @[dependencies].packages@. The user must regenerate the lock
    -- (= future @katari update@) to pick up the new dep. Args: dep name.
    ResolveLockfileOutOfDate Text
  | -- | The snapshot file failed to load (network, parse, etc.).
    ResolveSnapshotError Snapshot.SnapshotError
  | -- | A dep's snapshot pin lists an expected sha256, but the actual
    -- download hashed to a different value. Args: dep name, expected,
    -- actual.
    ResolveSnapshotShaMismatch Text Text Text
  | -- | @katari.lock@ exists but failed to parse.
    ResolveLockfileError Lock.LockfileError
  | -- | Internal invariant violation during lockfile generation. Should
    -- never be reached in normal operation; indicates a resolver bug.
    ResolveInternalError Text
  deriving (Show)

-- | Render a 'ResolveError' as a user-facing message. CLI commands
-- (= @katari check@, @katari apply@, ...) use this instead of 'show'
-- so users see e.g. /"cycle: a → b → a"/ rather than
-- /"ResolveCycle [\"a\",\"b\",\"a\"]"/.
renderResolveError :: ResolveError -> Text
renderResolveError = \case
  ResolveConfigError e ->
    "config: " <> renderConfigError e
  ResolveCycle chain ->
    "dependency cycle: " <> Text.intercalate " → " chain
  ResolveMissingConfig name path ->
    "dependency '" <> name <> "' at " <> Text.pack path
      <> " has no katari.toml"
  ResolveAmbiguousDep name a b ->
    "dependency '" <> name <> "' resolved to two different paths: "
      <> Text.pack a <> " vs " <> Text.pack b
  ResolveInvalidPackageName name ->
    "invalid package name '" <> name
      <> "' (must match [A-Za-z_][A-Za-z0-9_]*)"
  ResolveModuleCollision m ->
    "module '" <> m <> "' is contributed by two reachable packages"
  ResolveOutOfNamespace pkg m ->
    "package '" <> pkg <> "' contains a source file whose module name '"
      <> m <> "' is outside the package's namespace"
  ResolveDepNameMismatch declared actual ->
    "dependency declared as '" <> declared
      <> "' but [package].name in the dep's katari.toml is '"
      <> actual <> "'"
  ResolveUnresolvedDependency name ->
    "dependency '" <> name
      <> "' is not in the snapshot and has no [overrides] entry"
  ResolveLockfileOutOfDate name ->
    "dependency '" <> name
      <> "' is in katari.toml but not in katari.lock; run `katari update`"
      <> " (or delete katari.lock and re-run) to refresh the lockfile"
  ResolveSnapshotError e ->
    "snapshot: " <> Text.pack (show e)
  ResolveSnapshotShaMismatch name expected actual ->
    "dependency '" <> name <> "' download sha256 mismatch:\n"
      <> "  expected " <> expected <> "\n"
      <> "  actual   " <> actual
  ResolveLockfileError e ->
    "lockfile: " <> Text.pack (show e)
  ResolveInternalError msg ->
    "internal error: " <> msg

renderConfigError :: ConfigError -> Text
renderConfigError = \case
  ConfigIOError path msg -> Text.pack path <> ": " <> msg
  ConfigParseError path msg -> Text.pack path <> ": parse error: " <> msg
  ConfigValidationError path msg ->
    (if null path then "" else Text.pack path <> ": ") <> msg

-- ===========================================================================
-- Loading
-- ===========================================================================

-- | Load a project rooted at @rootDir@ (= the directory containing the
-- top-level @katari.toml@) and recursively follow every path dep.
--
-- The /dep key/ (= the @\<name>@ in @[dependencies.\<name>]@) must be
-- a valid Katari identifier because that is the literal text a
-- consumer types in @import \<name>@. A package's own
-- @[package].name@ is informational and may include hyphens.
loadResolvedProject :: FilePath -> IO (Either ResolveError ResolvedProject)
loadResolvedProject rootDir = do
  manager <- newTlsManager
  canonicalRoot <- canonicalizePath rootDir
  rootRes <- loadOnePackage canonicalRoot
  case rootRes of
    Left err -> pure (Left err)
    Right rootPkg -> do
      let cfg = rootPkg.packageConfig
          deps = cfg.dependenciesSection
          lockPath = canonicalRoot </> Lock.lockfileFilename
          needsSnapshot =
            any
              (\n -> not (Map.member n cfg.overrides))
              deps.dependenciesPackages
      lockExists <- doesFileExist lockPath
      mResolved <-
        if lockExists
          then do
            lockRes <- Lock.loadLockfile lockPath
            case lockRes of
              Left e -> pure (Left (ResolveLockfileError e))
              Right lock ->
                pure (Right (Just (lockfileToSnapshot lock), Just lock))
          else
            if needsSnapshot
              then case deps.dependenciesRegistry of
                Nothing -> pure (Right (Nothing, Nothing))
                Just url -> do
                  r <- Snapshot.loadSnapshotFromUrlWith manager url deps.dependenciesSnapshot
                  case r of
                    Left e -> pure (Left (ResolveSnapshotError e))
                    Right s -> pure (Right (Just s, Nothing))
              else pure (Right (Nothing, Nothing))
      case mResolved of
        Left e -> pure (Left e)
        Right (msnap, mlock) -> walkDeps manager msnap mlock rootPkg

-- | Project the @snapshot@-source entries of a 'Lock.Lockfile' into a
-- synthetic 'Snapshot.Snapshot'. Path / git overrides are ignored here
-- because they are sourced from @[overrides.X]@ (= the in-toml override
-- map), not from the lockfile's package list.
lockfileToSnapshot :: Lock.Lockfile -> Snapshot.Snapshot
lockfileToSnapshot lock =
  Snapshot.Snapshot
    { Snapshot.snapshotCompilerVersion = Nothing,
      Snapshot.snapshotPackages =
        Map.fromList (mapMaybe project (Map.toList lock.lockPackages))
    }
  where
    project (name, lp) = case lp.lockedSource of
      Lock.LockedSnapshot {snapshotRepo, snapshotRef, snapshotSha} ->
        Just
          ( name,
            Snapshot.SnapshotPackage
              { Snapshot.repo = snapshotRepo,
                Snapshot.ref = snapshotRef,
                Snapshot.sha = snapshotSha
              }
          )
      _ -> Nothing

-- | The merged dep source the walker actually consumes. Combines
-- @[overrides]@ entries with snapshot lookups.
data DepSource
  = DSPath FilePath
  | DSGit Text Text (Maybe Text)
  -- ^ url, rev, expected sha256 from the lockfile if known. The first
  -- resolution after writing a git override has no expected sha; the
  -- lockfile records it so subsequent resolutions verify the download.
  | DSSnapshotGit Text Text Text
  -- ^ url, rev, expected sha256 (= sha is the registry's pin; verified
  -- against the actual download).
  deriving (Show)

walkDeps ::
  Manager ->
  Maybe Snapshot.Snapshot ->
  Maybe Lock.Lockfile ->
  ResolvedPackage ->
  IO (Either ResolveError ResolvedProject)
walkDeps manager mSnap mLock rootPkg =
  case depEntries mSnap mLock rootPkg of
    Left err -> pure (Left err)
    Right entries -> go Set.empty Map.empty (initialQueue entries rootPkg.packageRoot)
  where
    initialQueue es parentRoot = [(n, s, parentRoot) | (n, s) <- es]

    go _ accDeps [] =
      pure (Right ResolvedProject {rootPackage = rootPkg, depPackages = accDeps})
    go visited accDeps ((depName, src, parentRoot) : rest) = case validatePackageName depName of
      Just err -> pure (Left err)
      Nothing
        | Set.member depName visited ->
            case (Map.lookup depName accDeps, src) of
              (Just existing, DSPath p) -> do
                expected <- canonicalizePath (resolveDepDir parentRoot p)
                if existing.packageRoot == expected
                  then go visited accDeps rest
                  else
                    pure
                      ( Left
                          ( ResolveAmbiguousDep
                              depName
                              existing.packageRoot
                              expected
                          )
                      )
              (Just _, _) -> go visited accDeps rest
              (Nothing, _) -> pure (Left (ResolveCycle [depName]))
        | otherwise -> case src of
            DSGit url rev mExpectedSha ->
              resolveGit depName url rev mExpectedSha visited accDeps rest
            DSSnapshotGit url rev expectedSha ->
              resolveGit depName url rev (Just expectedSha) visited accDeps rest
            DSPath p -> do
              let depDir = resolveDepDir parentRoot p
              canonical <- canonicalizePath depDir
              if canonical == rootPkg.packageRoot
                then pure (Left (ResolveCycle [depName, rootPkg.packageConfig.packageSection.packageName]))
                else do
                  cfgExists <- doesFileExist (canonical </> configFilename)
                  if not cfgExists
                    then pure (Left (ResolveMissingConfig depName canonical))
                    else do
                      pkgRes <- loadOnePackage canonical
                      case pkgRes of
                        Left err -> pure (Left err)
                        Right pkg -> do
                          inner <- depEntriesIO mSnap mLock pkg
                          case inner of
                            Left err -> pure (Left err)
                            Right innerEntries ->
                              let visited' = Set.insert depName visited
                                  accDeps' = Map.insert depName pkg accDeps
                                  transitive = initialQueue innerEntries pkg.packageRoot
                                  -- DFS: process transitive deps before remaining siblings
                               in go visited' accDeps' (transitive <> rest)

    resolveGit depName url rev expectedSha visited accDeps rest = do
      let cache = Cache.projectCachePaths rootPkg.packageRoot
      Cache.ensureCacheDirs cache
      fetchRes <- Fetch.fetchGitTarball manager cache depName (Fetch.GitRef url rev)
      case fetchRes of
        Left err ->
          pure
            ( Left
                ( ResolveConfigError
                    ( ConfigValidationError
                        ""
                        ( "git fetch failed for '"
                            <> depName
                            <> "': "
                            <> Text.pack (show err)
                        )
                    )
                )
            )
        Right (cachePath, sha) -> case expectedSha of
          Just e | e /= sha -> pure (Left (ResolveSnapshotShaMismatch depName e sha))
          _ -> do
            pkgRes <- loadOnePackage cachePath
            case pkgRes of
              Left err -> pure (Left err)
              Right pkg -> do
                inner <- depEntriesIO mSnap mLock pkg
                case inner of
                  Left e -> pure (Left e)
                  Right innerEntries ->
                    let pinned =
                          pkg
                            { packageSha = Just sha,
                              -- Snapshot deps record the (repo, ref)
                              -- that we resolved against. Pure git
                              -- overrides record neither because the
                              -- lockfile already shows them in the
                              -- 'OverrideGit' form.
                              packageSnapshotPin =
                                if isJust expectedSha
                                  then Just (url, rev)
                                  else Nothing
                            }
                        visited' = Set.insert depName visited
                        accDeps' = Map.insert depName pinned accDeps
                        transitive = initialQueue innerEntries pinned.packageRoot
                        -- DFS: process transitive deps before remaining siblings
                     in go visited' accDeps' (transitive <> rest)

-- | Resolve a package's @[dependencies].packages@ list into concrete
-- 'DepSource' values. Path / git overrides (from @[overrides.X]@) win
-- over snapshot pins. Names with neither resolution emit
-- 'ResolveUnresolvedDependency'.
depEntries ::
  Maybe Snapshot.Snapshot ->
  Maybe Lock.Lockfile ->
  ResolvedPackage ->
  Either ResolveError [(Text, DepSource)]
depEntries mSnap mLock pkg =
  traverse one pkg.packageConfig.dependenciesSection.dependenciesPackages
  where
    one name = case Map.lookup name pkg.packageConfig.overrides of
      Just (OverridePath p) -> Right (name, DSPath p)
      Just (OverrideGit url rev) -> Right (name, DSGit url rev (gitShaFromLock name))
      Nothing -> case mSnap of
        Just snap | Just sp <- Map.lookup name snap.snapshotPackages ->
          Right (name, DSSnapshotGit sp.repo sp.ref sp.sha)
        _ | isJust mLock -> Left (ResolveLockfileOutOfDate name)
        _ -> Left (ResolveUnresolvedDependency name)

    gitShaFromLock name = do
      lock <- mLock
      lp <- Map.lookup name lock.lockPackages
      case lp.lockedSource of
        Lock.LockedGit {gitSha} -> Just gitSha
        _ -> Nothing

-- | IO-flavoured wrapper around 'depEntries' — same logic, but lifted
-- into 'IO' for the walker's monadic context.
depEntriesIO ::
  Maybe Snapshot.Snapshot ->
  Maybe Lock.Lockfile ->
  ResolvedPackage ->
  IO (Either ResolveError [(Text, DepSource)])
depEntriesIO mSnap mLock pkg = pure (depEntries mSnap mLock pkg)

loadOnePackage :: FilePath -> IO (Either ResolveError ResolvedPackage)
loadOnePackage absRoot = do
  cfgRes <- loadKatariToml (absRoot </> configFilename)
  case cfgRes of
    Left err -> pure (Left (ResolveConfigError err))
    Right cfg -> do
      sources <- scanSources absRoot cfg
      pure
        ( Right
            ResolvedPackage
              { packageRoot = absRoot,
                packageConfig = cfg,
                packageSources = sources,
                packageSha = Nothing,
                packageSnapshotPin = Nothing
              }
        )

resolveDepDir :: FilePath -> FilePath -> FilePath
resolveDepDir parentRoot depPath
  | isAbsolute depPath = depPath
  | otherwise = parentRoot </> depPath

validatePackageName :: Text -> Maybe ResolveError
validatePackageName name
  | isValidPackageName name = Nothing
  | otherwise = Just (ResolveInvalidPackageName name)

-- ===========================================================================
-- Assembly
-- ===========================================================================

-- | A compiler-agnostic flattened view of a 'ResolvedProject'. Callers
-- convert this to whatever shape their compiler entry point expects.
--
-- @sources@ keys are module names verbatim — the convention is
-- enforced by 'assembleProject', so a package @P@ contributes keys
-- @P@, @P.foo@, @P.bar.baz@, etc., and never anything outside its
-- namespace.
newtype ProjectAssembly = ProjectAssembly
  { sources :: Map Text SourceEntry
  }
  deriving (Show)

-- | Flatten a 'ResolvedProject' into a 'ProjectAssembly'. Walks the
-- root + every dep, validates the source layout (each file's module
-- key starts with the package name), checks for cross-package
-- collisions, and concatenates the source maps.
--
-- Dep keys must agree with the dep's own @[package].name@ — the key
-- is what consumers type after @import@, so a mismatch would leave a
-- dep unreachable.
assembleProject :: ResolvedProject -> Either ResolveError ProjectAssembly
assembleProject rp = do
  let entries = rootEntry : Map.toList rp.depPackages
  validated <- traverse checkOne entries
  foldM mergeOne (ProjectAssembly Map.empty) validated
  where
    rootKey = rp.rootPackage.packageConfig.packageSection.packageName
    rootEntry = (rootKey, rp.rootPackage)

    checkOne :: (Text, ResolvedPackage) -> Either ResolveError (Text, ResolvedPackage)
    checkOne entry@(declaredKey, pkg) = do
      case validatePackageName declaredKey of
        Just err -> Left err
        Nothing -> Right ()
      let actualName = pkg.packageConfig.packageSection.packageName
      if declaredKey /= actualName
        then Left (ResolveDepNameMismatch declaredKey actualName)
        else case findOutOfNamespace declaredKey pkg.packageSources of
          Just bad -> Left (ResolveOutOfNamespace declaredKey bad)
          Nothing -> Right entry

    mergeOne :: ProjectAssembly -> (Text, ResolvedPackage) -> Either ResolveError ProjectAssembly
    mergeOne acc (_, pkg) =
      let new = pkg.packageSources
          collisions = Set.intersection (Map.keysSet acc.sources) (Map.keysSet new)
       in if not (Set.null collisions)
            then Left (ResolveModuleCollision (Set.findMin collisions))
            else Right (ProjectAssembly (Map.union acc.sources new))

-- ===========================================================================
-- Lockfile generation
-- ===========================================================================

-- | Project a 'ResolvedProject' into the 'Lock.Lockfile' shape. Each
-- dep contributes one 'Lock.LockedPackage':
--
--   * Path overrides: record the relative path verbatim.
--   * Git overrides: resolved tarball sha256.
--   * Snapshot-resolved deps: the snapshot's (repo, ref, sha256)
--     triple (sha taken from the actual download).
lockfileFromResolved :: ResolvedProject -> Either ResolveError Lock.Lockfile
lockfileFromResolved rp = do
  packages <-
    traverse
      ( \(depName, pkg) -> do
          source <- lockedSourceFor depName rp pkg
          pure
            ( depName,
              Lock.LockedPackage
                { Lock.lockedName = depName,
                  Lock.lockedSource = source
                }
            )
      )
      (Map.toList rp.depPackages)
  pure
    Lock.Lockfile
      { Lock.lockVersion = 1,
        Lock.lockSnapshot =
          rp.rootPackage.packageConfig.dependenciesSection.dependenciesSnapshot,
        Lock.lockPackages = Map.fromList packages
      }

-- | Translate a resolved dep into a 'Lock.LockedSource'. The walker
-- has already populated 'packageSha' for any fetch (= git override or
-- snapshot resolution), so the lockfile only needs to dispatch on the
-- override entry (if any) or fall through to the snapshot pin. Any
-- inconsistency (= missing sha on a fetch source, or missing snapshot
-- pin on a non-overridden dep) raises 'error': writing a corrupt
-- lockfile silently is strictly worse than crashing here, because the
-- bad lockfile would then be accepted as authoritative on the next run.
lockedSourceFor :: Text -> ResolvedProject -> ResolvedPackage -> Either ResolveError Lock.LockedSource
lockedSourceFor depName rp pkg =
  case Map.lookup depName rp.rootPackage.packageConfig.overrides of
    Just (OverridePath p) -> Right Lock.LockedPath {Lock.pathLocation = p}
    Just (OverrideGit url rev) -> case pkg.packageSha of
      Just sha ->
        Right Lock.LockedGit {Lock.gitRepoUrl = url, Lock.gitRev = rev, Lock.gitSha = sha}
      Nothing ->
        Left
          ( ResolveInternalError
              ( "lockedSourceFor: git override '"
                  <> depName
                  <> "' has no recorded sha — this is a resolver bug"
              )
          )
    Nothing -> case (pkg.packageSnapshotPin, pkg.packageSha) of
      (Just (repo, ref), Just sha) ->
        Right
          Lock.LockedSnapshot
            { Lock.snapshotRepo = repo,
              Lock.snapshotRef = ref,
              Lock.snapshotSha = sha
            }
      _ ->
        Left
          ( ResolveInternalError
              ( "lockedSourceFor: snapshot dep '"
                  <> depName
                  <> "' has no recorded (repo, ref, sha) — this is a resolver bug"
              )
          )

-- | Returns the first module key in @sources@ whose path is not under
-- the package's namespace (= not equal to @pkg@ and not prefixed by
-- @pkg.@), or 'Nothing' when every entry is in-namespace.
findOutOfNamespace :: Text -> Map Text a -> Maybe Text
findOutOfNamespace pkg sources =
  let prefix = pkg <> "."
      inNamespace k = k == pkg || prefix `Text.isPrefixOf` k
   in case filter (not . inNamespace) (Map.keys sources) of
        [] -> Nothing
        (bad : _) -> Just bad
