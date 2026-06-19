-- | Every failure mode of project loading, dependency resolution, and lockfile/snapshot handling,
-- flattened into a single sum type. The whole package returns @'Either' 'ProjectError' a@, and the
-- CLI renders any failure through the one 'renderProjectError'.
--
-- Following the compiler's "Katari.Error", each constructor carries one named @*Info@ record rather
-- than inlining fields, since record syntax and @|@ sum syntax mix badly. Shapes that recur are
-- shared by one record, and the constructor name carries the "which file / phase" distinction:
--
--   * 'FileErrorInfo' (a path + a message) covers every read / parse / validation failure of
--     @katari.toml@ / @katari.lock@ / a snapshot file. Whether it was an IO, parse, or validation
--     failure is the constructor, not the payload.
--   * 'UrlErrorInfo' (a URL + a message) covers every network / archive failure.
--   * 'UrlInfo' (a URL alone) covers the failures fully described by the offending URL.
--
-- 'readFileOrError' and 'formatException' live here too, so the one convention for turning an IO
-- failure into a 'ProjectError' has a single home.
module Katari.Project.Error
  ( ProjectError (..),

    -- * Shared payload records
    FileErrorInfo (..),
    UrlErrorInfo (..),
    UrlInfo (..),
    DependencyInfo (..),
    PackageNameInfo (..),

    -- * Specific payload records
    DuplicateModuleInfo (..),
    ModuleCollisionInfo (..),
    OutOfNamespaceInfo (..),
    DependencyNameMismatchInfo (..),
    MissingConfigInfo (..),
    ShaMismatchInfo (..),
    DependencyCycleInfo (..),
    NotCachedInfo (..),

    -- * IO helpers
    readFileOrError,
    loadAndParse,
    formatException,

    -- * Validation
    validationError,

    -- * Rendering
    renderProjectError,
  )
where

import Control.Exception (Exception, IOException, displayException, try)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import GHC.List (List)
import Katari.Data.ModuleName (ModuleName, renderModuleName)

-- ===========================================================================
-- The root sum
-- ===========================================================================

data ProjectError
  = -- Config (katari.toml) ----------------------------------------------------------------------
    ConfigIOError FileErrorInfo
  | ConfigParseError FileErrorInfo
  | ConfigValidationError FileErrorInfo
  | -- Discovery ---------------------------------------------------------------------------------
    DuplicateModule DuplicateModuleInfo
  | -- Lockfile (katari.lock) --------------------------------------------------------------------
    LockfileIOError FileErrorInfo
  | LockfileParseError FileErrorInfo
  | LockfileValidationError FileErrorInfo
  | -- Snapshot (registry package set) -----------------------------------------------------------
    SnapshotIOError FileErrorInfo
  | SnapshotHttpError UrlErrorInfo
  | SnapshotParseError FileErrorInfo
  | SnapshotValidationError FileErrorInfo
  | -- | The registry URL scheme is unsupported (only @file://@ and @https://@ are allowed).
    SnapshotUnsupportedUrl UrlInfo
  | -- Fetch (git tarball) -----------------------------------------------------------------------
    FetchHttpError UrlErrorInfo
  | FetchTarballError UrlErrorInfo
  | -- | The git URL is not a supported host (only GitHub archive URLs in v0.1).
    FetchInvalidHost UrlInfo
  | -- Resolve (dependency graph) ----------------------------------------------------------------
    ResolveCycle DependencyCycleInfo
  | -- | A path dependency points at a directory with no @katari.toml@.
    ResolveMissingConfig MissingConfigInfo
  | -- | A package name collides with the compiler-reserved @primitive@ / stdlib namespace, so the
    -- compiler would reject its modules with K2008. Caught here, where the user can act on it,
    -- rather than surfacing as a confusing error against the dependency's own source.
    ResolveReservedPackageName PackageNameInfo
  | -- | Two reachable packages contribute the same module key.
    ResolveModuleCollision ModuleCollisionInfo
  | -- | A package contributes a module outside its namespace.
    ResolveOutOfNamespace OutOfNamespaceInfo
  | -- | A dep's @[package].name@ disagrees with the key it is declared under.
    ResolveDependencyNameMismatch DependencyNameMismatchInfo
  | -- | A dep is reachable but has neither an override nor a registry-snapshot pin. Since the root's
    -- snapshot is authoritative for the whole closure, this also fires when a /transitive/ dep is
    -- absent from that snapshot.
    ResolveUnresolvedDependency DependencyInfo
  | -- | A dep is in @katari.toml@ but missing from @katari.lock@; the lock must be refreshed.
    ResolveLockfileOutOfDate DependencyInfo
  | -- | Offline load: a locked dependency's source tree is not present in the cache, so it cannot be
    -- assembled without going to the network. The caller (CLI) should run @katari apply@.
    ResolvePackageNotCached NotCachedInfo
  | -- | A fetched tarball's sha256 disagreed with its pin.
    ResolveShaMismatch ShaMismatchInfo
  deriving (Show, Eq)

-- ===========================================================================
-- Shared payload records
-- ===========================================================================

-- | A failure that concerns one file: an IO error, a parse error, or a validation error. The
-- constructor wrapping it says which.
data FileErrorInfo = FileErrorInfo
  { path :: FilePath,
    message :: Text
  }
  deriving (Show, Eq)

-- | A network or archive failure, keyed by the URL it concerns.
data UrlErrorInfo = UrlErrorInfo
  { url :: Text,
    message :: Text
  }
  deriving (Show, Eq)

-- | A failure fully described by the offending URL (unsupported scheme, unsupported host).
newtype UrlInfo = UrlInfo
  { url :: Text
  }
  deriving (Show, Eq)

-- | A failure keyed by the dependency name it concerns.
newtype DependencyInfo = DependencyInfo
  { dependency :: Text
  }
  deriving (Show, Eq)

-- | A failure about a package name (invalid identifier, or reserved by the compiler).
newtype PackageNameInfo = PackageNameInfo
  { name :: Text
  }
  deriving (Show, Eq)

-- ===========================================================================
-- Specific payload records
-- ===========================================================================

-- | Two source files collapse to the same module name within one package.
data DuplicateModuleInfo = DuplicateModuleInfo
  { moduleName :: ModuleName,
    firstPath :: FilePath,
    secondPath :: FilePath
  }
  deriving (Show, Eq)

-- | Two reachable packages each contribute the same module key.
data ModuleCollisionInfo = ModuleCollisionInfo
  { moduleName :: ModuleName,
    firstPackage :: Text,
    secondPackage :: Text
  }
  deriving (Show, Eq)

-- | A package laid out a module outside its own @P@ / @P.\<sub>@ namespace.
data OutOfNamespaceInfo = OutOfNamespaceInfo
  { package :: Text,
    moduleName :: ModuleName
  }
  deriving (Show, Eq)

-- | A dependency's declared key disagrees with its @[package].name@.
data DependencyNameMismatchInfo = DependencyNameMismatchInfo
  { declaredKey :: Text,
    actualName :: Text
  }
  deriving (Show, Eq)

-- | A path dependency points at a directory with no @katari.toml@.
data MissingConfigInfo = MissingConfigInfo
  { dependency :: Text,
    path :: FilePath
  }
  deriving (Show, Eq)

-- | A fetched tarball's content hash disagreed with the pin recorded for it.
data ShaMismatchInfo = ShaMismatchInfo
  { dependency :: Text,
    expected :: Text,
    actual :: Text
  }
  deriving (Show, Eq)

-- | The dependency chain contains a cycle; 'cycle' is the path of dependency names that closes it.
newtype DependencyCycleInfo = DependencyCycleInfo
  { cycle :: List Text
  }
  deriving (Show, Eq)

-- | A locked dependency's source tree is absent from the cache during an offline load.
data NotCachedInfo = NotCachedInfo
  { dependency :: Text,
    expectedPath :: FilePath
  }
  deriving (Show, Eq)

-- ===========================================================================
-- IO helpers
-- ===========================================================================

-- | Read a UTF-8 text file, turning an IO failure into a 'ProjectError' via the caller's wrapper.
-- The single home of the "read a project file, or fail with a 'FileErrorInfo'" pattern shared by
-- the config, lockfile, and snapshot loaders.
readFileOrError :: (FileErrorInfo -> ProjectError) -> FilePath -> IO (Either ProjectError Text)
readFileOrError toError path = do
  result <- try (TextIO.readFile path)
  pure $ case result of
    Left ioException -> Left (toError FileErrorInfo {path = path, message = formatException (ioException :: IOException)})
    Right text -> Right text

-- | Read a project file and parse it, threading the failure of either step into a 'ProjectError'.
-- @toIOError@ names the read failure (e.g. 'ConfigIOError'); @parse@ does the rest. This is the one
-- home of the "load @katari.toml@ / @katari.lock@ / a snapshot from disk" pattern, so the config,
-- lockfile, and snapshot loaders share a single shape and cannot drift.
loadAndParse ::
  (FileErrorInfo -> ProjectError) ->
  (FilePath -> Text -> Either ProjectError a) ->
  FilePath ->
  IO (Either ProjectError a)
loadAndParse toIOError parse path = do
  contents <- readFileOrError toIOError path
  pure (contents >>= parse path)

-- | A human-readable one-line rendering of an exception, for an error message.
formatException :: (Exception e) => e -> Text
formatException = Text.pack . displayException

-- ===========================================================================
-- Validation
-- ===========================================================================

-- | Report a cross-field validation failure of a file, phrasing it as the caller's own
-- @*ValidationError@ (the same constructor-injection trick 'readFileOrError' uses). One home for the
-- "this file decoded but breaks a rule we enforce" shape shared by the config, lockfile, and snapshot
-- validators.
validationError :: (FileErrorInfo -> ProjectError) -> FilePath -> Text -> Either ProjectError a
validationError toError path message = Left (toError FileErrorInfo {path = path, message = message})

-- ===========================================================================
-- Rendering
-- ===========================================================================

-- | Render a 'ProjectError' as a single user-facing line (or a short block for sha mismatches).
renderProjectError :: ProjectError -> Text
renderProjectError projectError = case projectError of
  -- Config (katari.toml) --------------------------------------------------------------------------
  ConfigIOError info -> "Cannot read katari.toml: " <> renderFileError info
  ConfigParseError info -> "Invalid katari.toml: " <> renderFileError info
  ConfigValidationError info -> "Invalid katari.toml: " <> renderFileError info
  -- Discovery -------------------------------------------------------------------------------------
  DuplicateModule info ->
    "Module "
      <> renderModuleName info.moduleName
      <> " is defined by two files: "
      <> Text.pack info.firstPath
      <> " and "
      <> Text.pack info.secondPath
  -- Lockfile (katari.lock) ------------------------------------------------------------------------
  LockfileIOError info -> "Cannot read katari.lock: " <> renderFileError info
  LockfileParseError info -> "Invalid katari.lock: " <> renderFileError info
  LockfileValidationError info -> "Invalid katari.lock: " <> renderFileError info
  -- Snapshot (registry package set) ---------------------------------------------------------------
  SnapshotIOError info -> "Cannot read registry snapshot: " <> renderFileError info
  SnapshotHttpError info -> "Cannot download registry snapshot: " <> renderUrlError info
  SnapshotParseError info -> "Invalid registry snapshot: " <> renderFileError info
  SnapshotValidationError info -> "Invalid registry snapshot: " <> renderFileError info
  SnapshotUnsupportedUrl info ->
    "Unsupported registry URL scheme (only file:// and https:// are allowed): " <> info.url
  -- Fetch (git tarball) ---------------------------------------------------------------------------
  FetchHttpError info -> "Cannot download dependency: " <> renderUrlError info
  FetchTarballError info -> "Cannot extract dependency tarball: " <> renderUrlError info
  FetchInvalidHost info ->
    "Unsupported dependency host (only GitHub archive URLs are supported): " <> info.url
  -- Resolve (dependency graph) --------------------------------------------------------------------
  ResolveCycle info -> "Dependency cycle: " <> Text.intercalate " -> " info.cycle
  ResolveMissingConfig info ->
    "Path dependency " <> info.dependency <> " has no katari.toml at " <> Text.pack info.path
  ResolveReservedPackageName info ->
    "Package name " <> info.name <> " is reserved by the compiler (the primitive/stdlib namespace)"
  ResolveModuleCollision info ->
    "Module "
      <> renderModuleName info.moduleName
      <> " is provided by two packages: "
      <> info.firstPackage
      <> " and "
      <> info.secondPackage
  ResolveOutOfNamespace info ->
    "Package "
      <> info.package
      <> " provides module "
      <> renderModuleName info.moduleName
      <> ", which is outside its "
      <> info.package
      <> " namespace"
  ResolveDependencyNameMismatch info ->
    "Dependency declared as " <> info.declaredKey <> " but its [package].name is " <> info.actualName
  ResolveUnresolvedDependency info ->
    "Dependency " <> info.dependency <> " has no override and no registry snapshot pin"
  ResolveLockfileOutOfDate info ->
    "Dependency "
      <> info.dependency
      <> " is in katari.toml but missing from katari.lock; run `katari apply`"
  ResolvePackageNotCached info ->
    "Dependency "
      <> info.dependency
      <> " is not in the cache ("
      <> Text.pack info.expectedPath
      <> "); run `katari apply`"
  ResolveShaMismatch info ->
    "Dependency "
      <> info.dependency
      <> " failed its content-hash check:\n  expected "
      <> info.expected
      <> "\n  actual   "
      <> info.actual

renderFileError :: FileErrorInfo -> Text
renderFileError info = Text.pack info.path <> ": " <> info.message

renderUrlError :: UrlErrorInfo -> Text
renderUrlError info = info.url <> ": " <> info.message
