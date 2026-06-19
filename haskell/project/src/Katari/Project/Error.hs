-- | Every failure mode of project loading, dependency resolution, and lockfile/snapshot handling,
-- flattened into a single sum type. The whole package returns @'Either' 'ProjectError' a@, and the
-- CLI renders any failure through the one 'renderProjectError'. This replaces the per-module error
-- types of the prototype (each wrapping the others), which forced callers to thread several render
-- functions and left some variants rendered via 'show'.
--
-- Two design points the consumers (CLI + LSP) depend on:
--
--   * /Record per variant./ Following the compiler's "Katari.Error", each constructor carries one
--     named @*Info@ record rather than inlining fields, since record syntax and @|@ sum syntax mix
--     badly. Shapes that recur (a file + message, a parse position, an http failure) share one
--     record; the constructor name carries the "which file / phase" distinction.
--
--   * /Source positions for the LSP./ Parse and validation failures of @katari.toml@ / @katari.lock@
--     carry a @'Maybe' 'Position'@, so the LSP can turn them into an inline diagnostic at the
--     offending line instead of a whole-file squiggle. 'Position' is reused verbatim from the
--     compiler ("Katari.Data.SourceSpan") so both layers speak the same coordinate system.
module Katari.Project.Error
  ( ProjectError (..),

    -- * Shared payload records
    FileErrorInfo (..),
    ParseErrorInfo (..),
    ValidationErrorInfo (..),
    HttpErrorInfo (..),
    UrlInfo (..),
    DependencyInfo (..),
    PackageNameInfo (..),

    -- * Specific payload records
    DuplicateModuleInfo (..),
    ModuleCollisionInfo (..),
    OutOfNamespaceInfo (..),
    DependencyNameMismatchInfo (..),
    MissingConfigInfo (..),
    AmbiguousDependencyInfo (..),
    ShaMismatchInfo (..),
    DependencyCycleInfo (..),
    NotCachedInfo (..),
    TarballErrorInfo (..),

    -- * Rendering
    renderProjectError,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Data.ModuleName (ModuleName, renderModuleName)
import Katari.Data.SourceSpan (Position (..))

-- ===========================================================================
-- The root sum
-- ===========================================================================

data ProjectError
  = -- Config (katari.toml) ----------------------------------------------------------------------
    ConfigIOError FileErrorInfo
  | ConfigParseError ParseErrorInfo
  | ConfigValidationError ValidationErrorInfo
  | -- Discovery ---------------------------------------------------------------------------------
    DuplicateModule DuplicateModuleInfo
  | -- Lockfile (katari.lock) --------------------------------------------------------------------
    LockfileIOError FileErrorInfo
  | LockfileParseError ParseErrorInfo
  | LockfileValidationError ValidationErrorInfo
  | -- Snapshot (registry package set) -----------------------------------------------------------
    SnapshotIOError FileErrorInfo
  | SnapshotHttpError HttpErrorInfo
  | SnapshotParseError ParseErrorInfo
  | SnapshotValidationError ValidationErrorInfo
  | -- | The registry URL scheme is unsupported (only @file://@ and @https://@ are allowed).
    SnapshotUnsupportedUrl UrlInfo
  | -- Fetch (git tarball) -----------------------------------------------------------------------
    FetchHttpError HttpErrorInfo
  | FetchTarballError TarballErrorInfo
  | -- | The git URL is not a supported host (only GitHub archive URLs in v0.1).
    FetchInvalidHost UrlInfo
  | -- Resolve (dependency graph) ----------------------------------------------------------------
    ResolveCycle DependencyCycleInfo
  | -- | A path dependency points at a directory with no @katari.toml@.
    ResolveMissingConfig MissingConfigInfo
  | -- | The same dep name resolved to two different package roots.
    ResolveAmbiguousDependency AmbiguousDependencyInfo
  | -- | A package name is not a valid Katari identifier.
    ResolveInvalidPackageName PackageNameInfo
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
  | -- | A dep is in @[dependencies].packages@ but has neither an override nor a snapshot pin.
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

-- | A file could not be read or written.
data FileErrorInfo = FileErrorInfo
  { path :: FilePath,
    message :: Text
  }
  deriving (Show, Eq)

-- | A TOML decode failure. 'position' is filled when the parser pinpoints a location (the LSP
-- underlines it); 'Nothing' when the failure is document-wide.
data ParseErrorInfo = ParseErrorInfo
  { path :: FilePath,
    position :: Maybe Position,
    message :: Text
  }
  deriving (Show, Eq)

-- | A decoded document violated a cross-field / semantic rule (e.g. path XOR git on an override).
data ValidationErrorInfo = ValidationErrorInfo
  { path :: FilePath,
    position :: Maybe Position,
    message :: Text
  }
  deriving (Show, Eq)

-- | A network request failed. 'url' is the request target.
data HttpErrorInfo = HttpErrorInfo
  { url :: Text,
    message :: Text
  }
  deriving (Show, Eq)

-- | An error that is fully described by the offending URL (unsupported scheme, unsupported host).
newtype UrlInfo = UrlInfo
  { url :: Text
  }
  deriving (Show, Eq)

-- | An error keyed by the dependency name it concerns.
newtype DependencyInfo = DependencyInfo
  { dependency :: Text
  }
  deriving (Show, Eq)

-- | An error about a package name (invalid identifier, or reserved by the compiler).
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

-- | One dependency name resolved to two distinct package roots.
data AmbiguousDependencyInfo = AmbiguousDependencyInfo
  { dependency :: Text,
    firstRoot :: FilePath,
    secondRoot :: FilePath
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

-- | A downloaded tarball could not be extracted. 'url' is where it came from.
data TarballErrorInfo = TarballErrorInfo
  { url :: Text,
    message :: Text
  }
  deriving (Show, Eq)

-- ===========================================================================
-- Rendering
-- ===========================================================================

-- | Render a 'ProjectError' as a single user-facing line (or a short block for sha mismatches).
renderProjectError :: ProjectError -> Text
renderProjectError projectError = case projectError of
  -- Config (katari.toml) --------------------------------------------------------------------------
  ConfigIOError info -> "Cannot read katari.toml: " <> renderFileError info
  ConfigParseError info -> "Invalid katari.toml: " <> renderParseError info
  ConfigValidationError info -> "Invalid katari.toml: " <> renderValidationError info
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
  LockfileParseError info -> "Invalid katari.lock: " <> renderParseError info
  LockfileValidationError info -> "Invalid katari.lock: " <> renderValidationError info
  -- Snapshot (registry package set) ---------------------------------------------------------------
  SnapshotIOError info -> "Cannot read registry snapshot: " <> renderFileError info
  SnapshotHttpError info -> "Cannot download registry snapshot: " <> renderHttpError info
  SnapshotParseError info -> "Invalid registry snapshot: " <> renderParseError info
  SnapshotValidationError info -> "Invalid registry snapshot: " <> renderValidationError info
  SnapshotUnsupportedUrl info ->
    "Unsupported registry URL scheme (only file:// and https:// are allowed): " <> info.url
  -- Fetch (git tarball) ---------------------------------------------------------------------------
  FetchHttpError info -> "Cannot download dependency: " <> renderHttpError info
  FetchTarballError info ->
    "Cannot extract dependency tarball from " <> info.url <> ": " <> info.message
  FetchInvalidHost info ->
    "Unsupported dependency host (only GitHub archive URLs are supported): " <> info.url
  -- Resolve (dependency graph) --------------------------------------------------------------------
  ResolveCycle info ->
    "Dependency cycle: " <> Text.intercalate " -> " info.cycle
  ResolveMissingConfig info ->
    "Path dependency "
      <> info.dependency
      <> " has no katari.toml at "
      <> Text.pack info.path
  ResolveAmbiguousDependency info ->
    "Dependency "
      <> info.dependency
      <> " resolves to two different packages: "
      <> Text.pack info.firstRoot
      <> " and "
      <> Text.pack info.secondRoot
  ResolveInvalidPackageName info ->
    "Package name "
      <> info.name
      <> " is not a valid Katari identifier ([A-Za-z_][A-Za-z0-9_]*)"
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
    "Dependency declared as "
      <> info.declaredKey
      <> " but its [package].name is "
      <> info.actualName
  ResolveUnresolvedDependency info ->
    "Dependency "
      <> info.dependency
      <> " has no override and no registry snapshot pin"
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

-- | @path@, optionally suffixed with @:line:column@ when a 'Position' is known.
renderLocation :: FilePath -> Maybe Position -> Text
renderLocation path maybePosition = case maybePosition of
  Nothing -> Text.pack path
  Just position ->
    Text.pack path
      <> ":"
      <> Text.pack (show position.line)
      <> ":"
      <> Text.pack (show position.column)

renderFileError :: FileErrorInfo -> Text
renderFileError info = Text.pack info.path <> ": " <> info.message

renderParseError :: ParseErrorInfo -> Text
renderParseError info = renderLocation info.path info.position <> ": " <> info.message

renderValidationError :: ValidationErrorInfo -> Text
renderValidationError info = renderLocation info.path info.position <> ": " <> info.message

renderHttpError :: HttpErrorInfo -> Text
renderHttpError info = info.url <> ": " <> info.message
