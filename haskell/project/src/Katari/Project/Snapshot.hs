-- | Registry snapshot files — the curated @(url, rev, sha256)@ pins for each package in a set.
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
-- Downstream ('Katari.Project.Resolve') looks up each dep, fetches the tarball at the pinned
-- @(url, rev)@ via 'Katari.Project.Fetch', and verifies the download against the @sha256@ pin.
module Katari.Project.Snapshot
  ( Snapshot (..),
    SnapshotPackage (..),
    parseSnapshot,
    loadSnapshotFromUrl,
  )
where

import Control.Exception (IOException, SomeException, try)
import Data.ByteString.Lazy qualified as ByteStringLazy
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Katari.Project.Error
  ( FileErrorInfo (..),
    HttpErrorInfo (..),
    ParseErrorInfo (..),
    ProjectError (..),
    UrlInfo (..),
  )
import Network.HTTP.Client (Manager, httpLbs, parseRequest, responseBody, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import TOML
  ( DecodeTOML (..),
    decodeWith,
    getField,
    getFieldOpt,
    renderTOMLError,
  )

data Snapshot = Snapshot
  { compilerVersion :: Maybe Text,
    packages :: Map Text SnapshotPackage
  }
  deriving (Show, Eq)

-- | One pinned package. Field vocabulary ('url', 'rev', 'sha') is shared with the git override and
-- the lockfile; here 'rev' is the curated tag/ref and 'sha' the verified tarball content hash.
data SnapshotPackage = SnapshotPackage
  { url :: Text,
    rev :: Text,
    sha :: Text
  }
  deriving (Show, Eq)

-- | The decode target, with @sha256@ named as the TOML spells it; 'parseSnapshot' renames it to the
-- 'sha' vocabulary shared with the lockfile and git override.
data RawSnapshot = RawSnapshot
  { compiler :: Maybe Text,
    packages :: Map Text RawSnapshotPackage
  }

data RawSnapshotPackage = RawSnapshotPackage
  { url :: Text,
    rev :: Text,
    sha256 :: Text
  }

instance DecodeTOML RawSnapshot where
  tomlDecoder =
    RawSnapshot
      <$> getFieldOpt "compiler"
      <*> (fromMaybe Map.empty <$> getFieldOpt "packages")

instance DecodeTOML RawSnapshotPackage where
  tomlDecoder =
    RawSnapshotPackage
      <$> getField "url"
      <*> getField "rev"
      <*> getField "sha256"

-- | Parse the textual contents of a snapshot file.
parseSnapshot :: FilePath -> Text -> Either ProjectError Snapshot
parseSnapshot path text = case decodeWith tomlDecoder text of
  Left tomlError ->
    Left (SnapshotParseError ParseErrorInfo {path = path, position = Nothing, message = renderTOMLError tomlError})
  Right (raw :: RawSnapshot) ->
    Right
      Snapshot
        { compilerVersion = raw.compiler,
          packages = Map.map toSnapshotPackage raw.packages
        }
  where
    toSnapshotPackage rawPackage =
      SnapshotPackage {url = rawPackage.url, rev = rawPackage.rev, sha = rawPackage.sha256}

-- | Load a snapshot from a registry URL. The @Maybe Text@ is the @snapshot@ version, used to build
-- the @\<root>/package-sets/\<version>.toml@ path when the URL is a registry root rather than a
-- direct @.toml@ file.
loadSnapshotFromUrl :: Manager -> Text -> Maybe Text -> IO (Either ProjectError Snapshot)
loadSnapshotFromUrl manager baseUrl maybeVersion = case snapshotUrl of
  Left projectError -> pure (Left projectError)
  Right url
    | "file://" `Text.isPrefixOf` url -> loadFromFile (Text.unpack (Text.drop (Text.length "file://") url))
    | "https://" `Text.isPrefixOf` url -> loadFromHttps url
    | otherwise -> pure (Left (SnapshotUnsupportedUrl UrlInfo {url = url}))
  where
    -- A direct @.toml@ URL is used as-is; a registry root is extended by the package-sets convention,
    -- which requires the snapshot version.
    snapshotUrl :: Either ProjectError Text
    snapshotUrl =
      let trimmed = Text.dropWhileEnd (== '/') baseUrl
       in if ".toml" `Text.isSuffixOf` trimmed
            then Right trimmed
            else case maybeVersion of
              Just version -> Right (trimmed <> "/package-sets/" <> version <> ".toml")
              Nothing ->
                Left
                  ( SnapshotParseError
                      ParseErrorInfo
                        { path = Text.unpack baseUrl,
                          position = Nothing,
                          message = "registry URL is a directory but no snapshot version was given"
                        }
                  )

    loadFromFile :: FilePath -> IO (Either ProjectError Snapshot)
    loadFromFile path = do
      contents <- try (TextIO.readFile path)
      pure $ case contents of
        Left readError -> Left (SnapshotIOError FileErrorInfo {path = path, message = Text.pack (show (readError :: IOException))})
        Right text -> parseSnapshot path text

    loadFromHttps :: Text -> IO (Either ProjectError Snapshot)
    loadFromHttps url = do
      result <- try $ do
        request <- parseRequest (Text.unpack url)
        httpLbs request manager
      pure $ case result of
        Left exception ->
          Left (SnapshotHttpError HttpErrorInfo {url = url, message = Text.pack (show (exception :: SomeException))})
        Right response ->
          let status = statusCode (responseStatus response)
           in if status == 200
                then parseSnapshot (Text.unpack url) (decodeBody (responseBody response))
                else Left (SnapshotHttpError HttpErrorInfo {url = url, message = "HTTP status " <> Text.pack (show status)})

    decodeBody = TextEncoding.decodeUtf8Lenient . ByteStringLazy.toStrict
