-- | Every failure mode of project loading, dependency resolution, and lockfile/snapshot handling,
-- flattened into a single sum type. The whole package returns @'Either' 'ProjectError' a@, and the
-- CLI renders any failure through the one 'renderProjectError'. This replaces the per-module error
-- types of the prototype (each wrapping the others), which forced callers to thread several render
-- functions and left some variants rendered via 'show'.
module Katari.Project.Error
  ( ProjectError (..),
    renderProjectError,
  )
where

import Data.Text (Text)
import GHC.List (List)

data ProjectError
  = -- Config (katari.toml) ----------------------------------------------------------------------

    -- | The file could not be read. Args: path, message.
    ConfigIOError FilePath Text
  | -- | TOML syntax / decode failure. Args: path, message.
    ConfigParseError FilePath Text
  | -- | The decoded config violated a semantic rule. Args: path, message.
    ConfigValidationError FilePath Text
  | -- Discovery ---------------------------------------------------------------------------------

    -- | Two source files collapse to the same module name. Args: module name, both file paths.
    DuplicateModule Text FilePath FilePath
  | -- Lockfile (katari.lock) --------------------------------------------------------------------
    LockfileIOError FilePath Text
  | LockfileParseError FilePath Text
  | LockfileValidationError FilePath Text
  | -- Snapshot (registry package set) -----------------------------------------------------------
    SnapshotIOError Text Text
  | SnapshotHttpError Text Text
  | SnapshotParseError FilePath Text
  | SnapshotValidationError FilePath Text
  | -- | The registry URL scheme is unsupported (only @file://@ and @https://@ are allowed).
    SnapshotUnsupportedUrl Text
  | -- Fetch (git tarball) -----------------------------------------------------------------------
    FetchHttpError Text Text
  | FetchTarballError Text
  | -- | The git URL is not a supported host (only GitHub archive URLs in v0.1).
    FetchInvalidHost Text
  | -- Resolve (dependency graph) ----------------------------------------------------------------

    -- | The dependency chain contains a cycle; the list is the cycle path.
    ResolveCycle (List Text)
  | -- | A path dependency points at a directory with no @katari.toml@. Args: dep name, path.
    ResolveMissingConfig Text FilePath
  | -- | The same dep name resolved to two different package roots. Args: dep name, both roots.
    ResolveAmbiguousDep Text FilePath FilePath
  | -- | A package name is not a valid Katari identifier.
    ResolveInvalidPackageName Text
  | -- | Two reachable packages contribute the same module key.
    ResolveModuleCollision Text
  | -- | A package contributes a module outside its namespace. Args: package name, module name.
    ResolveOutOfNamespace Text Text
  | -- | A dep's @[package].name@ disagrees with the key it is declared under. Args: key, actual.
    ResolveDepNameMismatch Text Text
  | -- | A dep is in @[dependencies].packages@ but has neither an override nor a snapshot pin.
    ResolveUnresolvedDependency Text
  | -- | A dep is in @katari.toml@ but missing from @katari.lock@; the lock must be refreshed.
    ResolveLockfileOutOfDate Text
  | -- | A fetched tarball's sha256 disagreed with its pin. Args: dep name, expected, actual.
    ResolveShaMismatch Text Text Text
  deriving (Show, Eq)

-- | Render a 'ProjectError' as a single user-facing line (or a short block for sha mismatches).
renderProjectError :: ProjectError -> Text
renderProjectError = error "TODO: Katari.Project.Error.renderProjectError"
