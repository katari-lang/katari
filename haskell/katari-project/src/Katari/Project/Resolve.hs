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
  )
where

import qualified Katari.Project.Cache as Cache
import qualified Katari.Project.Fetch as Fetch
import qualified Katari.Project.Lockfile as Lock
import qualified Katari.Project.Snapshot as Snapshot

import Control.Monad (foldM)
import Data.Char (isAlphaNum)
import Data.Maybe (isJust)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Katari.Project.Config
  ( ConfigError (..),
    OverrideSource (..),
    PackageSection (..),
    ProjectConfig (..),
    SnapshotSection (..),
    loadKatariToml,
  )
import qualified Data.Text as Text
import Katari.Project.Discovery (SourceEntry (..), configFilename, scanSources)
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
  | -- | A name in @[snapshot].dependencies@ has neither a matching
    -- @[overrides.\<name>]@ block nor a matching entry in the
    -- snapshot file. Args: dependency name.
    ResolveUnresolvedDependency Text
  | -- | The snapshot file failed to load (network, parse, etc.).
    ResolveSnapshotError Snapshot.SnapshotError
  | -- | A dep's snapshot pin lists an expected sha256, but the actual
    -- download hashed to a different value. Args: dep name, expected,
    -- actual.
    ResolveSnapshotShaMismatch Text Text Text
  deriving (Show)

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
  canonicalRoot <- canonicalizePath rootDir
  rootRes <- loadOnePackage canonicalRoot
  case rootRes of
    Left err -> pure (Left err)
    Right rootPkg -> do
      -- Lazily load the snapshot file iff the project has a snapshot
      -- pin AND at least one dep that isn't covered by an override.
      let snap = rootPkg.packageConfig.snapshotSection
          needsSnapshot =
            any
              (\n -> not (Map.member n rootPkg.packageConfig.overrides))
              snap.snapshotDependencies
      mSnap <-
        if needsSnapshot
          then case snap.snapshotUrl of
            Nothing ->
              -- No URL = caller will see ResolveUnresolvedDependency
              -- on the first non-override dep.
              pure (Right Nothing)
            Just url -> do
              r <- Snapshot.loadSnapshotFromUrl url snap.snapshotVersion
              pure (fmap Just r)
          else pure (Right Nothing)
      case mSnap of
        Left e -> pure (Left (ResolveSnapshotError e))
        Right msnap -> walkDeps msnap rootPkg

-- | The merged dep source the walker actually consumes. Combines
-- @[overrides]@ entries with snapshot lookups.
data DepSource
  = DSPath FilePath
  | DSGit Text Text -- url, rev (= user override; no expected sha)
  | DSSnapshotGit Text Text (Maybe Text)
  -- ^ url, rev, expected sha256 (= sha is the registry's pin; verified
  -- against the actual download).
  deriving (Show)

walkDeps ::
  Maybe Snapshot.Snapshot ->
  ResolvedPackage ->
  IO (Either ResolveError ResolvedProject)
walkDeps mSnap rootPkg =
  case depEntries mSnap rootPkg of
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
            DSGit url rev -> resolveGit depName url rev Nothing visited accDeps rest
            DSSnapshotGit url rev expectedSha ->
              resolveGit depName url rev expectedSha visited accDeps rest
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
                          inner <- depEntriesIO mSnap pkg
                          case inner of
                            Left err -> pure (Left err)
                            Right innerEntries ->
                              let visited' = Set.insert depName visited
                                  accDeps' = Map.insert depName pkg accDeps
                                  transitive = initialQueue innerEntries pkg.packageRoot
                               in go visited' accDeps' (transitive <> rest)

    resolveGit depName url rev expectedSha visited accDeps rest = do
      cache <- Cache.defaultCachePaths
      Cache.ensureCacheDirs cache
      fetchRes <- Fetch.fetchGitTarball cache depName (Fetch.GitRef url rev)
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
                inner <- depEntriesIO mSnap pkg
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
                     in go visited' accDeps' (transitive <> rest)

-- | Resolve a package's @[snapshot].dependencies@ list into concrete
-- 'DepSource' values, merging @[overrides]@ first and falling back to
-- the snapshot file when no override is present.
depEntries ::
  Maybe Snapshot.Snapshot ->
  ResolvedPackage ->
  Either ResolveError [(Text, DepSource)]
depEntries mSnap pkg =
  traverse one pkg.packageConfig.snapshotSection.snapshotDependencies
  where
    one name = case Map.lookup name pkg.packageConfig.overrides of
      Just (OverridePath p) -> Right (name, DSPath p)
      Just (OverrideGit url rev) -> Right (name, DSGit url rev)
      Nothing -> case mSnap of
        Just snap | Just sp <- Map.lookup name snap.snapshotPackages ->
          Right (name, DSSnapshotGit sp.spRepo sp.spRef sp.spSha)
        _ -> Left (ResolveUnresolvedDependency name)

-- | IO-flavoured wrapper around 'depEntries' — same logic, but lifted
-- into 'IO' for the walker's monadic context.
depEntriesIO ::
  Maybe Snapshot.Snapshot ->
  ResolvedPackage ->
  IO (Either ResolveError [(Text, DepSource)])
depEntriesIO mSnap pkg = pure (depEntries mSnap pkg)

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
  | Text.null name = Just (ResolveInvalidPackageName name)
  | Text.all validChar name && validHead (Text.head name) = Nothing
  | otherwise = Just (ResolveInvalidPackageName name)
  where
    validChar c = isAlphaNum c || c == '_'
    validHead c = not (c >= '0' && c <= '9')

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
lockfileFromResolved :: ResolvedProject -> Lock.Lockfile
lockfileFromResolved rp =
  Lock.Lockfile
    { Lock.lockVersion = 1,
      Lock.lockSnapshot = rp.rootPackage.packageConfig.snapshotSection.snapshotVersion,
      Lock.lockPackages =
        Map.fromList
          [ ( depName,
              Lock.LockedPackage
                { Lock.lockedName = depName,
                  Lock.lockedSource = lockedSourceFor depName rp pkg
                }
            )
            | (depName, pkg) <- Map.toList rp.depPackages
          ]
    }

-- | Translate a resolved dep into a 'Lock.LockedSource'. The walker
-- has already populated 'packageSha' for any fetch (= git override or
-- snapshot resolution), so the lockfile only needs to dispatch on the
-- override shape (or fall through to a snapshot entry when no
-- override exists for the name).
lockedSourceFor :: Text -> ResolvedProject -> ResolvedPackage -> Lock.LockedSource
lockedSourceFor depName rp pkg =
  case Map.lookup depName rp.rootPackage.packageConfig.overrides of
    Just (OverridePath p) -> Lock.LockedPath {Lock.pathLocation = p}
    Just (OverrideGit url rev) ->
      Lock.LockedGit
        { Lock.gitRepoUrl = url,
          Lock.gitRev = rev,
          Lock.gitSha = maybe "" id pkg.packageSha
        }
    Nothing ->
      -- Snapshot-resolved dep: record (repo, ref, sha) tuple that
      -- 'walkDeps' threaded onto the package via 'packageSnapshotPin'.
      case pkg.packageSnapshotPin of
        Just (repo, ref) ->
          Lock.LockedSnapshot
            { Lock.snapshotRepo = repo,
              Lock.snapshotRef = ref,
              Lock.snapshotSha = maybe "" id pkg.packageSha
            }
        Nothing ->
          -- Should be unreachable (= every snapshot-resolved dep
          -- gets a pin), but emit an empty entry rather than
          -- crashing if state ever drifts.
          Lock.LockedSnapshot
            { Lock.snapshotRepo = "",
              Lock.snapshotRef = "",
              Lock.snapshotSha = ""
            }

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
