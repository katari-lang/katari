-- | Registry snapshot files — the curated @(repo, ref, sha256)@ pins for each package in a set.
--
-- The wire format is owned by the @katari-registry@ repository (its README is the source of truth);
-- this module conforms to it. A snapshot is an enumeration of pinned git sources, so its entries
-- decode to 'GitSource' values (the same type the lockfile records).
--
-- Two concerns:
--
--   1. Parse a snapshot TOML file:
--
--      @
--      katari_compiler = "0.1.0"   # optional
--      [packages.list_utils]
--      version = "1.0.0"           # informational; ignored here
--      repo    = "https://github.com/katari-lang/list_utils"
--      ref     = "v0.2.1"
--      sha256  = "abc..."
--      @
--
--   2. Resolve a URL (from @[dependencies].registry@ + @[dependencies].snapshot@) into the snapshot
--      bytes, supporting @file://@ and @https://@ plus the registry's layout convention: the mutable
--      candidate set lives at @\<root>/package-sets/staging.toml@, every immutable cut lives under
--      @\<root>/package-sets/snapshots/\<name>.toml@.
--
--   3. Read the registry's /index/ at @\<root>/package-sets/index.toml@ — the list of every cut and
--      when it was made. The CLI reaches a registry through a plain raw-file base URL, which has no
--      directory listing, so "which snapshots exist" has to be published as a file; and the answer
--      cannot be recovered from the filenames, whose @\<8-hex>@ tail is a content hash with no order
--      (@a7cc1e51@ sorts before @bcc95cb3@ yet is the newer cut). The index therefore carries each
--      cut's timestamp as data, and 'newestSnapshot' orders on that.
--
-- Downstream ("Katari.Project.Resolve") looks up each dep, fetches the tarball at the pinned
-- @(repo, ref)@ via "Katari.Project.Fetch", and verifies the download against the @sha256@ pin.
module Katari.Project.Snapshot
  ( Snapshot (..),
    SnapshotEntry (..),
    parseSnapshot,
    loadSnapshotFromUrl,
    SnapshotIndex (..),
    SnapshotIndexEntry (..),
    snapshotIndexFormatVersion,
    parseSnapshotIndex,
    loadSnapshotIndexFromUrl,
    newestSnapshot,
  )
where

import Control.Monad (unless)
import Data.ByteString.Lazy qualified as ByteStringLazy
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.List (List)
import Katari.Project.Config (requireValidPackageName)
import Katari.Project.Error
  ( FileErrorInfo,
    ProjectError (..),
    UrlErrorInfo,
    UrlInfo (..),
    loadAndParse,
    validationError,
  )
import Katari.Project.Http (httpGetBytes)
import Katari.Project.Lockfile (GitSource (..), requireSha256Hex)
import Network.HTTP.Client (Manager)
import TOML
  ( DecodeTOML (..),
    decodeWith,
    getField,
    getFieldOpt,
    renderTOMLError,
  )

data Snapshot = Snapshot
  { compilerVersion :: Maybe Text,
    packages :: Map Text SnapshotEntry
  }
  deriving (Show, Eq)

-- | One package in a snapshot: the pinned source resolution fetches, and the version label the
-- registry publishes alongside it.
--
-- The version is carried but never resolved on: the @(repo, ref, sha256)@ pin is what a snapshot
-- MEANS, and the label is what a human recognises the package by ("web 0.2.0" against its README).
-- It is optional because the pin is the only field a snapshot is required to carry — an entry written
-- without a label still resolves, it just lists without one.
data SnapshotEntry = SnapshotEntry
  { version :: Maybe Text,
    source :: GitSource
  }
  deriving (Show, Eq)

-- | URL scheme prefixes and the registry-root path convention.
schemeFile, schemeHttps, packageSetsDir, snapshotsDir, stagingName, indexName, tomlSuffix :: Text
schemeFile = "file://"
schemeHttps = "https://"
packageSetsDir = "package-sets"
snapshotsDir = "snapshots"
stagingName = "staging"
indexName = "index"
tomlSuffix = ".toml"

-- ===========================================================================
-- Parsing
-- ===========================================================================

-- | The decode target, with fields named as the registry spells them; 'parseSnapshot' maps them to
-- the 'SnapshotEntry' the rest of the package speaks. Keys the registry writes that nothing here
-- reads (@published_time@) are simply not decoded — toml-reader ignores unknown keys.
data RawSnapshot = RawSnapshot
  { katariCompiler :: Maybe Text,
    packages :: Map Text RawGitSource
  }

data RawGitSource = RawGitSource
  { version :: Maybe Text,
    repo :: Text,
    ref :: Text,
    sha256 :: Text
  }

instance DecodeTOML RawSnapshot where
  tomlDecoder =
    RawSnapshot
      <$> getFieldOpt "katari_compiler"
      <*> (fromMaybe Map.empty <$> getFieldOpt "packages")

instance DecodeTOML RawGitSource where
  tomlDecoder =
    RawGitSource
      <$> getFieldOpt "version"
      <*> getField "repo"
      <*> getField "ref"
      <*> getField "sha256"

-- | Parse the textual contents of a snapshot file.
parseSnapshot :: FilePath -> Text -> Either ProjectError Snapshot
parseSnapshot path text = case decodeWith tomlDecoder text of
  Left tomlError -> validationError SnapshotParseError path (renderTOMLError tomlError)
  Right (raw :: RawSnapshot) -> do
    validatedPackages <- traverse (validateSnapshotPackage path) (Map.toList raw.packages)
    pure Snapshot {compilerVersion = raw.katariCompiler, packages = Map.fromList validatedPackages}

-- | Map one decoded snapshot entry to a 'SnapshotEntry', rejecting a name that is not a valid
-- identifier (it becomes a cache-directory path) or a malformed @sha256@ (it keys the
-- content-addressed cache and is the only thing pinning a snapshot's reproducibility, since the
-- @rev@ may be a tag). The @sha256@ is normalised to lowercase so it compares equal to the hash
-- 'Katari.Project.Fetch' computes.
validateSnapshotPackage :: FilePath -> (Text, RawGitSource) -> Either ProjectError (Text, SnapshotEntry)
validateSnapshotPackage path (name, rawSource) = do
  requireValidPackageName SnapshotValidationError path name
  sha <- requireSha256Hex SnapshotValidationError path name rawSource.sha256
  Right
    ( name,
      SnapshotEntry
        { version = rawSource.version,
          source = GitSource {url = rawSource.repo, rev = rawSource.ref, sha = sha}
        }
    )

-- ===========================================================================
-- Loading
-- ===========================================================================

-- | Load a snapshot from a registry URL. The @Maybe Text@ is the @snapshot@ name, used to build the
-- registry-layout path when the URL is a registry root rather than a direct @.toml@ file: the mutable
-- @staging@ set lives at @package-sets/staging.toml@, every immutable cut under
-- @package-sets/snapshots/\<name>.toml@.
loadSnapshotFromUrl :: Manager -> Text -> Maybe Text -> IO (Either ProjectError Snapshot)
loadSnapshotFromUrl manager baseUrl maybeVersion = case snapshotUrl of
  Left projectError -> pure (Left projectError)
  Right url -> loadRegistryFile manager SnapshotIOError SnapshotHttpError parseSnapshot url
  where
    -- A direct @.toml@ URL is used as-is; a registry root is extended by the registry's layout
    -- convention, which requires the snapshot name.
    snapshotUrl :: Either ProjectError Text
    snapshotUrl =
      let trimmed = Text.dropWhileEnd (== '/') baseUrl
       in if tomlSuffix `Text.isSuffixOf` trimmed
            then Right trimmed
            else case maybeVersion of
              -- The name becomes a path segment of the registry URL, so it must not smuggle in a
              -- separator: '..' or '/' here would escape the registry root (a traversal read for a
              -- file:// registry, a different URL for an https one).
              Just version
                | isSafeSnapshotVersion version ->
                    Right (Text.intercalate "/" (trimmed : snapshotPathSegments version))
                | otherwise ->
                    invalid ("snapshot version '" <> version <> "' must contain only [A-Za-z0-9._-] (no path separators)")
              Nothing -> invalid "registry URL is a directory but no snapshot version was given"

    snapshotPathSegments version
      | version == stagingName = [packageSetsDir, version <> tomlSuffix]
      | otherwise = [packageSetsDir, snapshotsDir, version <> tomlSuffix]

    invalid = validationError SnapshotValidationError (Text.unpack baseUrl)

-- | Read one registry file, whichever transport its URL names. The scheme dispatch is shared by the
-- snapshot and index loaders so a registry stays reachable the same way for both, and each caller
-- supplies the error constructors that say which file failed.
loadRegistryFile ::
  Manager ->
  (FileErrorInfo -> ProjectError) ->
  (UrlErrorInfo -> ProjectError) ->
  (FilePath -> Text -> Either ProjectError a) ->
  Text ->
  IO (Either ProjectError a)
loadRegistryFile manager toIOError toHttpError parse url
  | Just localPath <- localFilePath url = loadAndParse toIOError parse localPath
  | schemeHttps `Text.isPrefixOf` url = do
      result <- httpGetBytes manager url toHttpError
      pure (result >>= \body -> parse (Text.unpack url) (decodeBody body))
  | otherwise = pure (Left (SnapshotUnsupportedUrl UrlInfo {url = url}))
  where
    decodeBody = TextEncoding.decodeUtf8Lenient . ByteStringLazy.toStrict

-- ===========================================================================
-- The snapshot index
-- ===========================================================================

-- | The registry's list of immutable cuts, newest identifiable by 'newestSnapshot'.
data SnapshotIndex = SnapshotIndex
  { formatVersion :: Int,
    snapshots :: List SnapshotIndexEntry
  }
  deriving (Show, Eq)

-- | One cut: its name (the value that goes in @[dependencies].snapshot@), when it was cut, and the
-- compiler that set targets.
data SnapshotIndexEntry = SnapshotIndexEntry
  { name :: Text,
    cutTime :: Text,
    compilerVersion :: Text
  }
  deriving (Show, Eq)

-- | Current index schema version. Bumped only when the on-disk format changes incompatibly.
snapshotIndexFormatVersion :: Int
snapshotIndexFormatVersion = 1

data RawSnapshotIndex = RawSnapshotIndex
  { version :: Int,
    snapshots :: List RawIndexEntry
  }

data RawIndexEntry = RawIndexEntry
  { name :: Text,
    cutTime :: Text,
    katariCompiler :: Text
  }

instance DecodeTOML RawSnapshotIndex where
  tomlDecoder =
    RawSnapshotIndex
      <$> getField "version"
      <*> (fromMaybe [] <$> getFieldOpt "snapshots")

instance DecodeTOML RawIndexEntry where
  tomlDecoder =
    RawIndexEntry
      <$> getField "name"
      <*> getField "cut_time"
      <*> getField "katari_compiler"

-- | Parse the textual contents of @package-sets/index.toml@.
parseSnapshotIndex :: FilePath -> Text -> Either ProjectError SnapshotIndex
parseSnapshotIndex path text = case decodeWith tomlDecoder text of
  Left tomlError -> validationError IndexParseError path (renderTOMLError tomlError)
  Right (raw :: RawSnapshotIndex) -> do
    -- An unrecognised version must fail loudly rather than be misread as v1, which would silently
    -- ignore whatever a newer registry added.
    unless (raw.version == snapshotIndexFormatVersion) $
      validationError
        IndexValidationError
        path
        ( "unsupported index version "
            <> Text.pack (show raw.version)
            <> " (this tool understands version "
            <> Text.pack (show snapshotIndexFormatVersion)
            <> "); upgrade katari"
        )
    entries <- traverse (validateIndexEntry path) raw.snapshots
    pure SnapshotIndex {formatVersion = raw.version, snapshots = entries}

-- | Validate one entry: the name must be splice-safe (it becomes a path segment when the snapshot is
-- fetched) and the timestamp must be the index's exact shape, since ordering compares those strings.
validateIndexEntry :: FilePath -> RawIndexEntry -> Either ProjectError SnapshotIndexEntry
validateIndexEntry path raw
  | not (isSafeSnapshotVersion raw.name) =
      validationError IndexValidationError path ("snapshot name '" <> raw.name <> "' must contain only [A-Za-z0-9._-]")
  | not (isCutTime raw.cutTime) =
      validationError
        IndexValidationError
        path
        ("snapshot '" <> raw.name <> "' has a cut_time that is not YYYY-MM-DDTHH:MM:SSZ: " <> raw.cutTime)
  | otherwise =
      Right SnapshotIndexEntry {name = raw.name, cutTime = raw.cutTime, compilerVersion = raw.katariCompiler}

-- | The most recently cut snapshot, or 'Nothing' for an empty index.
--
-- Ordering is by 'cutTime' and never by name: the name's @\<8-hex>@ tail is a hash of the staging
-- file, so sorting names would order cuts by content and quietly hand back an older set. Comparing
-- the timestamps as text is sound precisely because 'isCutTime' has already pinned them to one
-- fixed-width UTC shape, where lexicographic order is chronological order.
newestSnapshot :: SnapshotIndex -> Maybe SnapshotIndexEntry
newestSnapshot index = foldl' pickNewer Nothing index.snapshots
  where
    pickNewer best entry = case best of
      Just current | current.cutTime >= entry.cutTime -> best
      _ -> Just entry

-- | Load the registry's index. The base URL must be a registry root: a URL naming a single snapshot
-- file says nothing about which other cuts exist, so there is no index to read beside it.
loadSnapshotIndexFromUrl :: Manager -> Text -> IO (Either ProjectError SnapshotIndex)
loadSnapshotIndexFromUrl manager baseUrl =
  let trimmed = Text.dropWhileEnd (== '/') baseUrl
   in if tomlSuffix `Text.isSuffixOf` trimmed
        then
          pure
            ( validationError
                IndexValidationError
                (Text.unpack baseUrl)
                "the registry URL names a single snapshot file, so it has no snapshot index; point [dependencies].registry at the registry root"
            )
        else
          loadRegistryFile
            manager
            IndexIOError
            IndexHttpError
            parseSnapshotIndex
            (Text.intercalate "/" [trimmed, packageSetsDir, indexName <> tomlSuffix])

-- | The one timestamp shape the index speaks: @YYYY-MM-DDTHH:MM:SSZ@, UTC, no fractional seconds.
-- Fixed width is the point — it is what makes a text comparison a chronological one, so an entry
-- that strays from it is rejected rather than silently misordering the set.
isCutTime :: Text -> Bool
isCutTime value =
  length characters == length shape && and (zipWith matches characters shape)
  where
    characters = Text.unpack value
    -- A '0' stands for "any digit"; every other character must appear verbatim.
    shape :: List Char
    shape = "0000-00-00T00:00:00Z"
    matches character expected = if expected == '0' then isDigit character else character == expected

-- | A snapshot version is safe to splice into the registry path when it is a plain version token:
-- non-empty and built only from @[A-Za-z0-9._-]@. Forbidding @/@ (and any other separator) is what
-- stops a crafted @snapshot = "../.."@ from escaping the registry root.
isSafeSnapshotVersion :: Text -> Bool
isSafeSnapshotVersion version =
  not (Text.null version) && Text.all isVersionChar version
  where
    isVersionChar character =
      isAsciiLower character || isAsciiUpper character || isDigit character || character `elem` ['.', '_', '-']

-- | The local filesystem path of a @file://@ URL, or 'Nothing' for a non-@file://@ URL. An empty or
-- @localhost@ authority is treated as local (@file:///abs@, @file://localhost/abs@, @file://./rel@);
-- any other authority (including @file://..@) is not a local file and falls through to the
-- unsupported-scheme path.
localFilePath :: Text -> Maybe FilePath
localFilePath url = do
  rest <- Text.stripPrefix schemeFile url
  -- An empty authority leaves the path right after "file://": absolute "/abs", or the explicit
  -- relative form "./rel". A bare "." authority is the only relative spelling accepted; "../" is not,
  -- so it is read as an authority and rejected below.
  if "/" `Text.isPrefixOf` rest || "./" `Text.isPrefixOf` rest
    then Just (Text.unpack rest)
    else case Text.breakOn "/" rest of
      (authority, path)
        | authority == "localhost" -> Just (Text.unpack path)
        | otherwise -> Nothing
