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
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Katari.Project.Config (isValidPackageName)
import Katari.Project.Error
  ( FileErrorInfo (..),
    ProjectError (..),
    UrlInfo (..),
    readFileOrError,
  )
import Katari.Project.Http (httpGetBytes)
import Katari.Project.Lockfile (GitSource (..), isSha256Hex)
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
  Left tomlError ->
    Left (SnapshotParseError FileErrorInfo {path = path, message = renderTOMLError tomlError})
  Right (raw :: RawSnapshot) -> do
    validatedPackages <- traverse (validateSnapshotPackage path) (Map.toList raw.packages)
    pure Snapshot {compilerVersion = raw.compiler, packages = Map.fromList validatedPackages}

-- | Map one decoded snapshot entry to a 'GitSource', rejecting a name that is not a valid identifier
-- (it becomes a cache-directory path) or a malformed @sha256@ (it keys the content-addressed cache and
-- is the only thing pinning a snapshot's reproducibility, since the @rev@ may be a tag).
validateSnapshotPackage :: FilePath -> (Text, RawGitSource) -> Either ProjectError (Text, GitSource)
validateSnapshotPackage path (name, rawSource)
  | not (isValidPackageName name) =
      validationError ("package name " <> name <> " is not a valid identifier ([A-Za-z_][A-Za-z0-9_]*)")
  | not (isSha256Hex rawSource.sha256) =
      validationError ("package '" <> name <> "' has a malformed sha256 (expected 64 hex characters): " <> rawSource.sha256)
  | otherwise = Right (name, GitSource {url = rawSource.url, rev = rawSource.rev, sha = rawSource.sha256})
  where
    validationError message = Left (SnapshotValidationError FileErrorInfo {path = path, message = message})

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
              Just version -> Right (Text.intercalate "/" [trimmed, packageSetsDir, version <> tomlSuffix])
              Nothing ->
                Left
                  ( SnapshotValidationError
                      FileErrorInfo
                        { path = Text.unpack baseUrl,
                          message = "registry URL is a directory but no snapshot version was given"
                        }
                  )

    loadFromFile :: FilePath -> IO (Either ProjectError Snapshot)
    loadFromFile path = do
      contents <- readFileOrError SnapshotIOError path
      pure (contents >>= parseSnapshot path)

    loadFromHttps :: Text -> IO (Either ProjectError Snapshot)
    loadFromHttps url = do
      result <- httpGetBytes manager url SnapshotHttpError
      pure (result >>= \body -> parseSnapshot (Text.unpack url) (decodeBody body))

    decodeBody = TextEncoding.decodeUtf8Lenient . ByteStringLazy.toStrict

-- | The local filesystem path of a @file://@ URL, or 'Nothing' for a non-@file://@ URL. An empty or
-- @localhost@ authority is treated as local (@file:///abs@, @file://localhost/abs@, @file://./rel@);
-- a remote authority is not a local file and falls through to the unsupported-scheme path.
localFilePath :: Text -> Maybe FilePath
localFilePath url = do
  rest <- Text.stripPrefix schemeFile url
  if "/" `Text.isPrefixOf` rest || "." `Text.isPrefixOf` rest
    then Just (Text.unpack rest) -- empty authority: the path starts right after "file://"
    else case Text.breakOn "/" rest of
      (authority, path)
        | authority == "localhost" -> Just (Text.unpack path)
        | otherwise -> Nothing
