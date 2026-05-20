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
-- The lockfile is generated/refreshed by 'Katari.Cli.Resolve' (= the
-- internal resolver run by @build@ / @apply@ / @add@) and is meant to
-- be committed to git so every consumer of the project gets the same
-- byte-for-byte resolution.
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
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Katari.Project.Config
  ( TomlBucket (..),
    TomlTable (..),
    TomlValue (..),
    lookupTable,
    lookupTableScalar,
    parseTomlText,
  )

-- | Conventional filename, sibling to @katari.toml@.
lockfileFilename :: FilePath
lockfileFilename = "katari.lock"

data Lockfile = Lockfile
  { -- | Current schema version (1 for now). Bumped if the on-disk
    -- shape needs to evolve incompatibly.
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
  = -- | Pulled from the registry snapshot at the recorded
    -- @(repo, ref, sha256)@ triple. The @sha256@ is the integrity
    -- digest of the upstream tarball as recorded in the snapshot
    -- file; mismatches mean the upstream archive has been tampered
    -- with or the lockfile has gone out of sync.
    LockedSnapshot
      { snapshotRepo :: Text,
        snapshotRef :: Text,
        snapshotSha :: Text
      }
  | -- | Local path override. The path is interpreted relative to the
    -- @katari.toml@ that declared it. No integrity check is possible
    -- here — path deps are inherently mutable.
    LockedPath {pathLocation :: FilePath}
  | -- | Git override. @gitRev@ is the resolved full commit SHA
    -- (not a branch/tag), so the contents are reproducible. @gitSha@
    -- is the integrity digest of the archived tarball that was
    -- pulled into the cache.
    LockedGit
      { gitRepoUrl :: Text,
        gitRev :: Text,
        gitSha :: Text
      }
  deriving (Show, Eq)

data LockfileError
  = LockIOError FilePath Text
  | LockParseError FilePath Int Text
  | LockValidationError FilePath Text
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------

-- | Read + parse @katari.lock@ from disk. Returns 'Left' on I/O,
-- parse, or validation errors.
loadLockfile :: FilePath -> IO (Either LockfileError Lockfile)
loadLockfile path = do
  readResult <- try (TextIO.readFile path) :: IO (Either IOException Text)
  case readResult of
    Left e -> pure (Left (LockIOError path (Text.pack (show e))))
    Right raw -> pure (parseLockfile path raw)

-- | Parse the textual contents of a @katari.lock@.
parseLockfile :: FilePath -> Text -> Either LockfileError Lockfile
parseLockfile path raw = do
  table <- mapLeft (uncurry (LockParseError path)) (parseTomlText raw)
  validate path table

validate :: FilePath -> TomlTable -> Either LockfileError Lockfile
validate path table = do
  let lockTable = lookupTable "lock" table
  ver <- case lookupTableScalar "version" lockTable of
    Just (TomlInt n) -> Right (fromInteger n :: Int)
    _ -> Left (LockValidationError path "[lock].version must be an integer")
  let snapshot = case lookupTableScalar "snapshot" lockTable of
        Just (TomlString s) | not (Text.null s) -> Just s
        _ -> Nothing
  pkgs <- parseEachPackage path table
  Right Lockfile {lockVersion = ver, lockSnapshot = snapshot, lockPackages = pkgs}

parseEachPackage :: FilePath -> TomlTable -> Either LockfileError (Map Text LockedPackage)
parseEachPackage path (TomlTable buckets) =
  Map.fromList <$> traverse step packageEntries
  where
    packageEntries =
      [ (Text.drop (Text.length prefix) sec, body)
        | (sec, body) <- Map.toList buckets,
          prefix `Text.isPrefixOf` sec
      ]
    prefix = "packages."
    step (name, BucketTable t) = do
      lp <- parseLockedPackage path name t
      Right (name, lp)
    step (name, _) =
      Left
        ( LockValidationError
            path
            ("[packages." <> name <> "] must be a table")
        )

parseLockedPackage ::
  FilePath -> Text -> Map Text TomlValue -> Either LockfileError LockedPackage
parseLockedPackage path name t = do
  src <- case Map.lookup "source" t of
    Just (TomlString s) -> Right s
    _ -> Left (LockValidationError path ("[packages." <> name <> "].source missing"))
  body <- case src of
    "snapshot" -> do
      repo <- requireString path name "repo" t
      ref <- requireString path name "ref" t
      sha <- requireString path name "sha256" t
      Right
        LockedSnapshot
          { snapshotRepo = repo,
            snapshotRef = ref,
            snapshotSha = sha
          }
    "path" -> do
      p <- requireString path name "path" t
      Right (LockedPath (Text.unpack p))
    "git" -> do
      repo <- requireString path name "repo" t
      rev <- requireString path name "rev" t
      sha <- requireString path name "sha256" t
      Right
        LockedGit
          { gitRepoUrl = repo,
            gitRev = rev,
            gitSha = sha
          }
    other ->
      Left
        ( LockValidationError
            path
            ( "[packages."
                <> name
                <> "].source: unknown '"
                <> other
                <> "' (expected snapshot|path|git)"
            )
        )
  Right (LockedPackage {lockedName = name, lockedSource = body})

requireString :: FilePath -> Text -> Text -> Map Text TomlValue -> Either LockfileError Text
requireString path name key m = case Map.lookup key m of
  Just (TomlString s) | not (Text.null s) -> Right s
  _ ->
    Left
      ( LockValidationError
          path
          ("[packages." <> name <> "]." <> key <> " missing or empty")
      )

-- ---------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------

-- | Render a 'Lockfile' to a deterministic, byte-stable TOML string.
-- Packages are emitted in lexicographic order so two locks generated
-- from the same inputs compare equal byte-for-byte.
renderLockfile :: Lockfile -> Text
renderLockfile l =
  Text.unlines $
    [ "# katari.lock — auto-generated by `katari resolve`; commit to git.",
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

quote :: Text -> Text
quote s = "\"" <> s <> "\""

-- | Write a 'Lockfile' to @path@, overwriting any existing file.
writeLockfile :: FilePath -> Lockfile -> IO ()
writeLockfile path l = TextIO.writeFile path (renderLockfile l)

mapLeft :: (a -> c) -> Either a b -> Either c b
mapLeft f = either (Left . f) Right
