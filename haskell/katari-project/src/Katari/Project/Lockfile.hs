-- | @katari.lock@ — pinned resolution of every reachable dependency.
--
-- Schema overview:
--
-- @
-- [lock]
-- version  = 1                    -- lockfile format version
-- snapshot = "2026-05-01"         -- mirrored from katari.toml
--
-- [packages.list_utils]
-- source = "snapshot"
-- repo   = "https://github.com/.../list_utils"
-- ref    = "v0.2.1"
-- sha256 = "abc..."
--
-- [packages.local_fork]
-- source = "path"
-- path   = "../local_fork"        -- no sha256: path deps are mutable on purpose
--
-- [packages.bleeding_edge]
-- source = "git"
-- repo   = "https://github.com/foo/bar"
-- rev    = "abc1234..."           -- resolved full SHA
-- sha256 = "def..."
-- @
--
-- The lockfile is generated/refreshed by 'Katari.Cli.Apply' (or
-- @katari resolve@) and is meant to be committed to git so every
-- consumer of the project gets the same byte-for-byte resolution.
module Katari.Project.Lockfile
  ( Lockfile (..),
    LockedPackage (..),
    LockedSource (..),
    LockfileError (..),
    parseLockfile,
    renderLockfile,
    loadLockfile,
    writeLockfile,
    lockfileFilename,
  )
where

import Control.Exception (IOException, try)
import Data.Bifunctor (first)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Katari.Project.Toml (extractNestedTables)
import qualified Toml
import Toml (TomlCodec, (.=))
import qualified Validation

-- | Conventional filename, sibling to @katari.toml@.
lockfileFilename :: FilePath
lockfileFilename = "katari.lock"

data Lockfile = Lockfile
  { -- | Current schema version (1 for now).
    lockVersion :: Int,
    -- | The snapshot id that was in effect when this lock was
    -- generated. 'Nothing' when the project hasn't pinned a snapshot
    -- (= path/git deps only).
    lockSnapshot :: Maybe Text,
    -- | Resolved entries keyed by the dep name (= the import name).
    -- Order is irrelevant for correctness; we serialise alphabetically
    -- for deterministic file contents.
    lockPackages :: Map Text LockedPackage
  }
  deriving (Show, Eq)

data LockedPackage = LockedPackage
  { lockedName :: Text,
    lockedSource :: LockedSource
  }
  deriving (Show, Eq)

data LockedSource
  = LockedSnapshot
      { snapshotRepo :: Text,
        snapshotRef :: Text,
        snapshotSha :: Text
      }
  | LockedPath {pathLocation :: FilePath}
  | LockedGit
      { gitRepoUrl :: Text,
        gitRev :: Text,
        gitSha :: Text
      }
  deriving (Show, Eq)

data LockfileError
  = LockIOError FilePath Text
  | LockParseError FilePath Text
  | LockValidationError FilePath Text
  deriving (Show, Eq)

-- ===========================================================================
-- Raw codec (mirror TOML 1:1, validated to LockedSource after parse)
-- ===========================================================================

data RawLockfile = RawLockfile
  { rawLockMeta :: RawLockMeta,
    rawLockPackages :: Map Text RawLockedPackage
  }

data RawLockMeta = RawLockMeta
  { rawLockVersion :: Int,
    rawLockSnapshot :: Maybe Text
  }

data RawLockedPackage = RawLockedPackage
  { rawSource :: Text,
    rawRepo :: Maybe Text,
    rawRef :: Maybe Text,
    rawRev :: Maybe Text,
    rawSha :: Maybe Text,
    rawPath :: Maybe FilePath
  }

-- | Codec for the @[lock]@ block only. @[packages.X]@ entries are
-- extracted via 'extractLockedPackages'.
-- See 'Katari.Project.Toml' for details on the tomland workaround.
rawLockfileCodec :: TomlCodec RawLockfile
rawLockfileCodec =
  RawLockfile
    <$> Toml.table rawLockMetaCodec "lock" .= (.rawLockMeta)
    -- Packages are stitched in after AST-level extraction.
    <*> pure Map.empty .= (.rawLockPackages)

rawLockMetaCodec :: TomlCodec RawLockMeta
rawLockMetaCodec =
  RawLockMeta
    <$> Toml.int "version" .= (.rawLockVersion)
    <*> Toml.dioptional (Toml.text "snapshot") .= (.rawLockSnapshot)

rawLockedPackageCodec :: TomlCodec RawLockedPackage
rawLockedPackageCodec =
  RawLockedPackage
    <$> Toml.text "source" .= (.rawSource)
    <*> Toml.dioptional (Toml.text "repo") .= (.rawRepo)
    <*> Toml.dioptional (Toml.text "ref") .= (.rawRef)
    <*> Toml.dioptional (Toml.text "rev") .= (.rawRev)
    <*> Toml.dioptional (Toml.text "sha256") .= (.rawSha)
    <*> Toml.dioptional (Toml.string "path") .= (.rawPath)

-- ===========================================================================
-- Loading
-- ===========================================================================

loadLockfile :: FilePath -> IO (Either LockfileError Lockfile)
loadLockfile path = do
  readResult <- try (TextIO.readFile path) :: IO (Either IOException Text)
  case readResult of
    Left e -> pure (Left (LockIOError path (Text.pack (show e))))
    Right raw -> pure (parseLockfile path raw)

parseLockfile :: FilePath -> Text -> Either LockfileError Lockfile
parseLockfile path raw = do
  toml <-
    first
      (LockParseError path . Text.pack . show)
      (Toml.parse raw)
  rawLock <-
    first
      (LockParseError path . Toml.prettyTomlDecodeErrors)
      (Validation.validationToEither (Toml.runTomlCodec rawLockfileCodec toml))
  pkgs <- extractLockedPackages path toml
  validate path (rawLock {rawLockPackages = pkgs})

extractLockedPackages ::
  FilePath -> Toml.TOML -> Either LockfileError (Map Text RawLockedPackage)
extractLockedPackages path toml =
  extractNestedTables "packages" (decodeLockedPackage path) toml

decodeLockedPackage ::
  FilePath -> Text -> Toml.TOML -> Either LockfileError RawLockedPackage
decodeLockedPackage path name sub =
  case Validation.validationToEither (Toml.runTomlCodec rawLockedPackageCodec sub) of
    Left errs ->
      Left
        ( LockValidationError
            path
            ("[packages." <> name <> "]: " <> Toml.prettyTomlDecodeErrors errs)
        )
    Right lp -> Right lp

validate :: FilePath -> RawLockfile -> Either LockfileError Lockfile
validate path RawLockfile {..} = do
  pkgs <- traverse (validateLockedPackage path) rawLockPackages
  let named = Map.mapWithKey (\name lp -> LockedPackage {lockedName = name, lockedSource = lp}) pkgs
  Right
    Lockfile
      { lockVersion = rawLockMeta.rawLockVersion,
        lockSnapshot = rawLockMeta.rawLockSnapshot,
        lockPackages = named
      }

validateLockedPackage :: FilePath -> RawLockedPackage -> Either LockfileError LockedSource
validateLockedPackage path RawLockedPackage {..} =
  case rawSource of
    "snapshot" -> do
      repo <- need "repo" rawRepo
      ref' <- need "ref" rawRef
      sha <- need "sha256" rawSha
      Right LockedSnapshot {snapshotRepo = repo, snapshotRef = ref', snapshotSha = sha}
    "path" -> do
      p <- need "path" (fmap Text.pack rawPath)
      Right (LockedPath (Text.unpack p))
    "git" -> do
      repo <- need "repo" rawRepo
      rev <- need "rev" rawRev
      sha <- need "sha256" rawSha
      Right LockedGit {gitRepoUrl = repo, gitRev = rev, gitSha = sha}
    other ->
      Left
        ( LockValidationError
            path
            ("unknown source '" <> other <> "' (expected snapshot|path|git)")
        )
  where
    need :: Text -> Maybe Text -> Either LockfileError Text
    need fieldName m = case m of
      Just v | not (Text.null v) -> Right v
      _ ->
        Left
          ( LockValidationError
              path
              ("[packages.X]." <> fieldName <> " missing or empty for source '" <> rawSource <> "'")
          )

-- ===========================================================================
-- Writing
-- ===========================================================================

-- | Render a 'Lockfile' to a deterministic, byte-stable TOML string.
renderLockfile :: Lockfile -> Text
renderLockfile l =
  Text.unlines $
    [ "# katari.lock — auto-generated by `katari apply`; commit to git.",
      "",
      "[lock]",
      "version = " <> Text.pack (show l.lockVersion)
    ]
      <> maybe [] (\s -> ["snapshot = " <> quote s]) l.lockSnapshot
      <> concatMap renderPackage (Map.toAscList l.lockPackages)

renderPackage :: (Text, LockedPackage) -> [Text]
renderPackage (name, lp) =
  ["", "[packages." <> name <> "]"] <> renderSource lp.lockedSource

renderSource :: LockedSource -> [Text]
renderSource = \case
  LockedSnapshot {snapshotRepo, snapshotRef, snapshotSha} ->
    [ "source = \"snapshot\"",
      "repo = " <> quote snapshotRepo,
      "ref = " <> quote snapshotRef,
      "sha256 = " <> quote snapshotSha
    ]
  LockedPath {pathLocation} ->
    [ "source = \"path\"",
      "path = " <> quote (Text.pack pathLocation)
    ]
  LockedGit {gitRepoUrl, gitRev, gitSha} ->
    [ "source = \"git\"",
      "repo = " <> quote gitRepoUrl,
      "rev = " <> quote gitRev,
      "sha256 = " <> quote gitSha
    ]

-- | TOML basic-string literal. Backslashes and double-quotes must be
-- escaped per the TOML spec. Without this, an OverridePath containing
-- @"@ or @\\@ would emit malformed TOML the next loader would reject.
quote :: Text -> Text
quote s = "\"" <> Text.concatMap escapeChar s <> "\""
  where
    escapeChar '\\' = "\\\\"
    escapeChar '"' = "\\\""
    escapeChar '\n' = "\\n"
    escapeChar '\t' = "\\t"
    escapeChar '\r' = "\\r"
    escapeChar c = Text.singleton c

-- | Write a 'Lockfile' to @path@, overwriting any existing file.
writeLockfile :: FilePath -> Lockfile -> IO ()
writeLockfile path l = TextIO.writeFile path (renderLockfile l)
