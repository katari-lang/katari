-- | Registry snapshot files — the curated @(url, rev, sha256)@ pins for each package in a set.
--
-- A snapshot is an enumeration of pinned git sources, so its entries are 'GitSource' values (the
-- same type the lockfile records); the snapshot file is just their wire format.
--
-- Two concerns:
--
--   1. Parse a snapshot TOML file (one @package-sets/\<version>.toml@):
--
--      @
--      # compiler = "0.1.0"   # optional
--      [packages.list_utils]
--      url    = "https://github.com/katari-lang/list_utils"
--      rev    = "v0.2.1"
--      sha256 = "abc..."
--      @
--
--   2. Resolve a URL (from @[dependencies].registry@ + @[dependencies].snapshot@) into the snapshot
--      bytes, supporting @file://@ and @https://@ plus the "URL points at the registry root, the
--      version is the filename" convention (@\<root>/package-sets/\<version>.toml@).
--
-- Downstream ("Katari.Project.Resolve") looks up each dep, fetches the tarball at the pinned
-- @(url, rev)@ via "Katari.Project.Fetch", and verifies the download against the @sha256@ pin.
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
schemeFile, schemeHttps, packageSetsDir, tomlSuffix :: Text
schemeFile = "file://"
schemeHttps = "https://"
packageSetsDir = "package-sets"
tomlSuffix = ".toml"

-- ===========================================================================
-- Parsing
-- ===========================================================================

-- | The decode target, with @sha256@ named as the TOML spells it; 'parseSnapshot' maps it to the
-- 'GitSource' the rest of the package speaks.
data RawSnapshot = RawSnapshot
  { compiler :: Maybe Text,
    packages :: Map Text RawGitSource
  }

data RawGitSource = RawGitSource
  { url :: Text,
    rev :: Text,
    sha256 :: Text
  }

instance DecodeTOML RawSnapshot where
  tomlDecoder =
    RawSnapshot
      <$> getFieldOpt "compiler"
      <*> (fromMaybe Map.empty <$> getFieldOpt "packages")

instance DecodeTOML RawGitSource where
  tomlDecoder =
    RawGitSource
      <$> getField "url"
      <*> getField "rev"
      <*> getField "sha256"

-- | Parse the textual contents of a snapshot file.
parseSnapshot :: FilePath -> Text -> Either ProjectError Snapshot
parseSnapshot path text = case decodeWith tomlDecoder text of
  Left tomlError -> validationError SnapshotParseError path (renderTOMLError tomlError)
  Right (raw :: RawSnapshot) -> do
    validatedPackages <- traverse (validateSnapshotPackage path) (Map.toList raw.packages)
    pure Snapshot {compilerVersion = raw.compiler, packages = Map.fromList validatedPackages}

-- | Map one decoded snapshot entry to a 'GitSource', rejecting a name that is not a valid identifier
-- (it becomes a cache-directory path) or a malformed @sha256@ (it keys the content-addressed cache and
-- is the only thing pinning a snapshot's reproducibility, since the @rev@ may be a tag). The @sha256@
-- is normalised to lowercase so it compares equal to the hash 'Katari.Project.Fetch' computes.
validateSnapshotPackage :: FilePath -> (Text, RawGitSource) -> Either ProjectError (Text, GitSource)
validateSnapshotPackage path (name, rawSource) = do
  requireValidPackageName SnapshotValidationError path name
  sha <- requireSha256Hex SnapshotValidationError path name rawSource.sha256
  Right (name, GitSource {url = rawSource.url, rev = rawSource.rev, sha = sha})

-- ===========================================================================
-- Loading
-- ===========================================================================

-- | Load a snapshot from a registry URL. The @Maybe Text@ is the @snapshot@ version, used to build
-- the @\<root>/package-sets/\<version>.toml@ path when the URL is a registry root rather than a
-- direct @.toml@ file.
loadSnapshotFromUrl :: Manager -> Text -> Maybe Text -> IO (Either ProjectError Snapshot)
loadSnapshotFromUrl manager baseUrl maybeVersion = case snapshotUrl of
  Left projectError -> pure (Left projectError)
  Right url
    | Just localPath <- localFilePath url -> loadFromFile localPath
    | schemeHttps `Text.isPrefixOf` url -> loadFromHttps url
    | otherwise -> pure (Left (SnapshotUnsupportedUrl UrlInfo {url = url}))
  where
    -- A direct @.toml@ URL is used as-is; a registry root is extended by the package-sets
    -- convention, which requires the snapshot version.
    snapshotUrl :: Either ProjectError Text
    snapshotUrl =
      let trimmed = Text.dropWhileEnd (== '/') baseUrl
       in if tomlSuffix `Text.isSuffixOf` trimmed
            then Right trimmed
            else case maybeVersion of
              -- The version becomes a path segment of the registry URL, so it must not smuggle in a
              -- separator: '..' or '/' here would escape the registry root (a traversal read for a
              -- file:// registry, a different URL for an https one).
              Just version
                | isSafeSnapshotVersion version ->
                    Right (Text.intercalate "/" [trimmed, packageSetsDir, version <> tomlSuffix])
                | otherwise ->
                    invalid ("snapshot version '" <> version <> "' must contain only [A-Za-z0-9._-] (no path separators)")
              Nothing -> invalid "registry URL is a directory but no snapshot version was given"

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
