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
-- Downstream ("Katari.Project.Resolve") looks up each dep, fetches the tarball at the pinned
-- @(repo, ref)@ via "Katari.Project.Fetch", and verifies the download against the @sha256@ pin.
module Katari.Project.Snapshot
  ( Snapshot (..),
    parseSnapshot,
    loadSnapshotFromUrl,
  )
where

import Data.ByteString.Lazy qualified as ByteStringLazy
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Katari.Project.Config (requireValidPackageName)
import Katari.Project.Error
  ( ProjectError (..),
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
    packages :: Map Text GitSource
  }
  deriving (Show, Eq)

-- | URL scheme prefixes and the registry-root path convention.
schemeFile, schemeHttps, packageSetsDir, snapshotsDir, stagingName, tomlSuffix :: Text
schemeFile = "file://"
schemeHttps = "https://"
packageSetsDir = "package-sets"
snapshotsDir = "snapshots"
stagingName = "staging"
tomlSuffix = ".toml"

-- ===========================================================================
-- Parsing
-- ===========================================================================

-- | The decode target, with fields named as the registry spells them; 'parseSnapshot' maps them to
-- the 'GitSource' the rest of the package speaks. Keys the registry writes but resolution does not
-- need (@version@, @published_time@) are simply not decoded — toml-reader ignores unknown keys.
data RawSnapshot = RawSnapshot
  { katariCompiler :: Maybe Text,
    packages :: Map Text RawGitSource
  }

data RawGitSource = RawGitSource
  { repo :: Text,
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
      <$> getField "repo"
      <*> getField "ref"
      <*> getField "sha256"

-- | Parse the textual contents of a snapshot file.
parseSnapshot :: FilePath -> Text -> Either ProjectError Snapshot
parseSnapshot path text = case decodeWith tomlDecoder text of
  Left tomlError -> validationError SnapshotParseError path (renderTOMLError tomlError)
  Right (raw :: RawSnapshot) -> do
    validatedPackages <- traverse (validateSnapshotPackage path) (Map.toList raw.packages)
    pure Snapshot {compilerVersion = raw.katariCompiler, packages = Map.fromList validatedPackages}

-- | Map one decoded snapshot entry to a 'GitSource', rejecting a name that is not a valid identifier
-- (it becomes a cache-directory path) or a malformed @sha256@ (it keys the content-addressed cache and
-- is the only thing pinning a snapshot's reproducibility, since the @rev@ may be a tag). The @sha256@
-- is normalised to lowercase so it compares equal to the hash 'Katari.Project.Fetch' computes.
validateSnapshotPackage :: FilePath -> (Text, RawGitSource) -> Either ProjectError (Text, GitSource)
validateSnapshotPackage path (name, rawSource) = do
  requireValidPackageName SnapshotValidationError path name
  sha <- requireSha256Hex SnapshotValidationError path name rawSource.sha256
  Right (name, GitSource {url = rawSource.repo, rev = rawSource.ref, sha = sha})

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
  Right url
    | Just localPath <- localFilePath url -> loadFromFile localPath
    | schemeHttps `Text.isPrefixOf` url -> loadFromHttps url
    | otherwise -> pure (Left (SnapshotUnsupportedUrl UrlInfo {url = url}))
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

    loadFromFile :: FilePath -> IO (Either ProjectError Snapshot)
    loadFromFile = loadAndParse SnapshotIOError parseSnapshot

    loadFromHttps :: Text -> IO (Either ProjectError Snapshot)
    loadFromHttps url = do
      result <- httpGetBytes manager url SnapshotHttpError
      pure (result >>= \body -> parseSnapshot (Text.unpack url) (decodeBody body))

    decodeBody = TextEncoding.decodeUtf8Lenient . ByteStringLazy.toStrict

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
