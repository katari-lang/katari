-- | Fetch a git dependency into the on-disk cache.
--
-- For v0.1 we support GitHub-style tarball URLs: given a base repo URL
-- @https://github.com/USER/REPO@ and a full-SHA @rev@, hit @\<base>/archive/\<rev>.tar.gz@, write
-- the tarball to a temp file, compute its SHA-256, and extract it to
-- @\<cache>/packages/\<name>-\<sha256>/@.
--
-- The cache is content-addressed by the tarball's sha. When the caller already knows that sha — a
-- registry-snapshot pin, or a prior lockfile entry whose @(url, rev)@ still matches — it passes it
-- as the cache hint and an existing directory short-circuits the whole network round-trip. Without a
-- hint (a fresh git override, whose content hash is unknown until downloaded) the tarball is
-- downloaded and only the /extraction/ is skipped when its content already sits in the cache.
--
-- GitHub wraps the tree in an outer @REPO-\<short>@ directory; that wrapper is unwrapped so the
-- cache layout is always @\<name>-\<sha256>/{katari.toml, src/, ...}@.
module Katari.Project.Fetch
  ( GitRef (..),
    fetchGitTarball,
  )
where

import Codec.Archive.Tar qualified as Tar
import Codec.Compression.GZip qualified as GZip
import Control.Exception (SomeException, try)
import Control.Monad (when)
import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as ByteStringLazy
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Katari.Project.Cache (CachePaths, packageDir)
import Katari.Project.Error
  ( ProjectError (..),
    UrlErrorInfo (..),
    UrlInfo (..),
    formatException,
  )
import Network.HTTP.Client (Manager, httpLbs, parseRequest, responseBody, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    listDirectory,
    removeDirectoryRecursive,
    renameDirectory,
  )
import System.FilePath ((</>))

-- | The git information the caller supplied. 'url' is the canonical repo URL (e.g.
-- @https://github.com/user/repo@); 'rev' must be a full 40-char commit SHA for reproducibility.
data GitRef = GitRef
  { url :: Text,
    rev :: Text
  }
  deriving (Show, Eq)

-- | Only GitHub archive URLs are supported in v0.1.
githubPrefix, archiveInfix, tarballSuffix, stagingSuffix :: Text
githubPrefix = "https://github.com/"
archiveInfix = "/archive/"
tarballSuffix = ".tar.gz"
stagingSuffix = ".unpack"

-- | Resolve a git dep into a local extracted source tree. Returns the absolute path of the extracted
-- directory AND the hex SHA-256 of the downloaded tarball (recorded in the lockfile). @maybeCacheSha@
-- is the expected content hash, when known, used to skip the download on a cache hit.
fetchGitTarball :: Manager -> CachePaths -> Text -> GitRef -> Maybe Text -> IO (Either ProjectError (FilePath, Text))
fetchGitTarball manager cache name gitReference maybeCacheSha
  | not (githubPrefix `Text.isPrefixOf` gitReference.url) =
      pure (Left (FetchInvalidHost UrlInfo {url = gitReference.url}))
  | otherwise = do
      hit <- cacheHit
      case hit of
        Just result -> pure (Right result)
        Nothing -> downloadAndExtract
  where
    archiveUrl = Text.dropWhileEnd (== '/') gitReference.url <> archiveInfix <> gitReference.rev <> tarballSuffix

    -- A known sha names a unique source tree, so an existing directory needs no network at all.
    cacheHit :: IO (Maybe (FilePath, Text))
    cacheHit = case maybeCacheSha of
      Nothing -> pure Nothing
      Just sha -> do
        let directory = packageDir cache name sha
        exists <- doesDirectoryExist directory
        pure (if exists then Just (directory, sha) else Nothing)

    downloadAndExtract :: IO (Either ProjectError (FilePath, Text))
    downloadAndExtract = do
      downloadResult <- try $ do
        request <- parseRequest (Text.unpack archiveUrl)
        httpLbs request manager
      case downloadResult of
        Left exception ->
          pure (Left (FetchHttpError UrlErrorInfo {url = archiveUrl, message = formatException (exception :: SomeException)}))
        Right response
          | statusCode (responseStatus response) /= 200 ->
              pure
                ( Left
                    ( FetchHttpError
                        UrlErrorInfo
                          { url = archiveUrl,
                            message = "HTTP status " <> Text.pack (show (statusCode (responseStatus response)))
                          }
                    )
                )
          | otherwise -> do
              let body = responseBody response
                  sha = sha256Hex body
                  destination = packageDir cache name sha
              -- The downloaded content may already be extracted (a hint-less fetch of cached content).
              alreadyExtracted <- doesDirectoryExist destination
              if alreadyExtracted
                then pure (Right (destination, sha))
                else do
                  extractResult <- extractTarball archiveUrl body destination
                  pure (fmap (const (destination, sha)) extractResult)

-- | Decompress and unpack a GitHub archive into @destination@. GitHub wraps the tree in a single
-- @REPO-\<ref>/@ directory; that wrapper is unwrapped by extracting into a sibling staging directory
-- and promoting its sole child to @destination@.
extractTarball :: Text -> ByteStringLazy.ByteString -> FilePath -> IO (Either ProjectError ())
extractTarball archiveUrl body destination = do
  result <- try $ do
    stagingExists <- doesDirectoryExist staging
    when stagingExists (removeDirectoryRecursive staging)
    createDirectoryIfMissing True staging
    Tar.unpack staging (Tar.read (GZip.decompress body))
    children <- listDirectory staging
    case children of
      [single] -> do
        renameDirectory (staging </> single) destination
        removeDirectoryRecursive staging
      _ -> ioError (userError "archive did not contain a single top-level directory")
  case result of
    Left exception -> do
      -- Best-effort cleanup so a half-extracted staging directory does not poison a retry.
      leftover <- doesDirectoryExist staging
      when leftover (removeDirectoryRecursive staging)
      pure (Left (FetchTarballError UrlErrorInfo {url = archiveUrl, message = formatException (exception :: SomeException)}))
    Right () -> pure (Right ())
  where
    staging = destination <> Text.unpack stagingSuffix

-- | Hex SHA-256 of a lazy byte string, matching the encoding used for module hashes
-- ("Katari.Project.Upload".@hashModule@).
sha256Hex :: ByteStringLazy.ByteString -> Text
sha256Hex lazyBytes =
  let digest = hashlazy lazyBytes :: Digest SHA256
      hex = convertToBase Base16 digest :: ByteString
   in TextEncoding.decodeUtf8 hex
