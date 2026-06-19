-- | Fetch a git dependency into the on-disk cache.
--
-- For v0.1 we support GitHub-style tarball URLs: given a base repo URL
-- @https://github.com/USER/REPO@ and a full-SHA @rev@, hit @\<base>/archive/\<rev>.tar.gz@, write
-- the tarball to a temp file, compute its SHA-256, and extract it to
-- @\<cache>/packages/\<name>-\<sha256>/@.
--
-- GitHub wraps the tree in an outer @REPO-\<short>@ directory; that wrapper is unwrapped so the
-- cache layout is always @\<name>-\<sha256>/{katari.toml, src/, ...}@. If that directory already
-- exists the network round-trip is skipped — the SHA already identifies a unique source tree.
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
  ( HttpErrorInfo (..),
    ProjectError (..),
    TarballErrorInfo (..),
    UrlInfo (..),
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
-- Same field vocabulary as 'Katari.Project.Config.GitOverride'.
data GitRef = GitRef
  { url :: Text,
    rev :: Text
  }
  deriving (Show, Eq)

-- | Resolve a git dep into a local extracted source tree. Returns the absolute path of the extracted
-- directory AND the hex SHA-256 of the downloaded tarball (recorded in the lockfile).
fetchGitTarball :: Manager -> CachePaths -> Text -> GitRef -> IO (Either ProjectError (FilePath, Text))
fetchGitTarball manager cache name gitReference
  | not ("https://github.com/" `Text.isPrefixOf` gitReference.url) =
      pure (Left (FetchInvalidHost UrlInfo {url = gitReference.url}))
  | otherwise = do
      downloadResult <- try $ do
        request <- parseRequest (Text.unpack archiveUrl)
        httpLbs request manager
      case downloadResult of
        Left exception ->
          pure (Left (FetchHttpError HttpErrorInfo {url = archiveUrl, message = Text.pack (show (exception :: SomeException))}))
        Right response ->
          let status = statusCode (responseStatus response)
           in if status /= 200
                then pure (Left (FetchHttpError HttpErrorInfo {url = archiveUrl, message = "HTTP status " <> Text.pack (show status)}))
                else do
                  let body = responseBody response
                      sha = sha256Hex body
                      destination = packageDir cache name sha
                  -- The SHA names a unique source tree, so an existing directory needs no re-extraction.
                  alreadyCached <- doesDirectoryExist destination
                  if alreadyCached
                    then pure (Right (destination, sha))
                    else do
                      extractResult <- extractTarball archiveUrl body destination
                      pure (fmap (const (destination, sha)) extractResult)
  where
    -- GitHub serves a repository tree as @\<repo>/archive/\<ref>.tar.gz@.
    archiveUrl = Text.dropWhileEnd (== '/') gitReference.url <> "/archive/" <> gitReference.rev <> ".tar.gz"

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
      pure (Left (FetchTarballError TarballErrorInfo {url = archiveUrl, message = Text.pack (show (exception :: SomeException))}))
    Right () -> pure (Right ())
  where
    staging = destination <> ".unpack"

-- | Hex SHA-256 of a lazy byte string, matching the encoding used for module hashes
-- ('Katari.Project.Upload.hashModule').
sha256Hex :: ByteStringLazy.ByteString -> Text
sha256Hex lazyBytes =
  let digest = hashlazy lazyBytes :: Digest SHA256
      hex = convertToBase Base16 digest :: ByteString
   in TextEncoding.decodeUtf8 hex
