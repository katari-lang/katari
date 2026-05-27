-- | Fetch a git dependency into the on-disk cache.
--
-- For v1 we only support GitHub-style tarball URLs: given a base repo
-- URL @https:\/\/github.com\/USER\/REPO@ and a full-SHA @rev@, we hit
-- @\<base>\/archive\/\<rev>.tar.gz@, write the tarball to a temp file,
-- compute its SHA-256, and extract it to
-- @\<cache>\/packages\/\<name>-\<sha256>\/@.
--
-- The extracted tree's outer wrapper directory (= GitHub's
-- @REPO-\<short>@ convention) is unwrapped so the cache layout is
-- always @\<name>-\<sha256>\/{katari.toml, src\/, ...}@.
--
-- If the @\<name>-\<sha256>@ directory already exists we skip the
-- network round-trip — the SHA already identifies a unique source
-- tree.
module Katari.Project.Fetch
  ( FetchError (..),
    GitRef (..),
    fetchGitTarball,
  )
where

import Codec.Archive.Tar qualified as Tar
import Codec.Archive.Tar.Check qualified as Tar
import Codec.Compression.GZip qualified as GZip
import Control.Exception (Exception, IOException, SomeException, try)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Katari.Project.Cache (CachePaths, packageDir)
import Network.HTTP.Client
  ( HttpException,
    Manager,
    httpLbs,
    parseRequest,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Status (statusCode)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    listDirectory,
    renameDirectory,
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

-- | The git information the user supplied. @url@ is the canonical
-- repo URL (e.g. @https://github.com/user/repo@); @rev@ must be a
-- full 40-char commit SHA for reproducibility.
data GitRef = GitRef
  { gitUrl :: Text,
    gitRev :: Text
  }
  deriving (Show, Eq)

data FetchError
  = FetchHttpError Text Text
  | FetchTarballError Text
  | FetchInvalidHost Text
  deriving (Show, Eq)

-- | Resolve a git dep into a local extracted source tree. Returns the
-- absolute path of the extracted dir AND the hex SHA-256 of the
-- downloaded tarball (suitable for storing in the lockfile).
fetchGitTarball ::
  Manager ->
  CachePaths ->
  Text ->
  GitRef ->
  IO (Either FetchError (FilePath, Text))
fetchGitTarball manager cache name ref =
  case archiveUrl ref of
    Left err -> pure (Left err)
    Right url -> doFetch manager cache name url

archiveUrl :: GitRef -> Either FetchError Text
archiveUrl GitRef {gitUrl, gitRev} =
  let stripped = stripTrailingSlash (stripDotGit gitUrl)
   in if "https://github.com/" `Text.isPrefixOf` stripped
        then Right (stripped <> "/archive/" <> gitRev <> ".tar.gz")
        else Left (FetchInvalidHost gitUrl)
  where
    stripDotGit u = fromMaybe u (Text.stripSuffix ".git" u)
    stripTrailingSlash u = fromMaybe u (Text.stripSuffix "/" u)

doFetch :: Manager -> CachePaths -> Text -> Text -> IO (Either FetchError (FilePath, Text))
doFetch manager cache name url = do
  reqRes <- try (parseRequest (Text.unpack url)) :: IO (Either IOException HTTP.Request)
  case reqRes of
    Left err -> pure (Left (FetchHttpError url (Text.pack (show err))))
    Right req -> do
      respRes <- try (httpLbs req manager) :: IO (Either HttpException (HTTP.Response LBS.ByteString))
      case respRes of
        Left err -> pure (Left (FetchHttpError url (Text.pack (show err))))
        Right resp ->
          let status = statusCode (responseStatus resp)
              body = LBS.toStrict (responseBody resp)
              digest = hash body :: Digest SHA256
              shaHex = TE.decodeUtf8 (convertToBase Base16 digest)
              target = packageDir cache name shaHex
           in if status >= 400
                then
                  pure
                    ( Left
                        ( FetchHttpError
                            url
                            ("HTTP " <> Text.pack (show status))
                        )
                    )
                else do
                  exists <- doesDirectoryExist target
                  if exists
                    then pure (Right (target, shaHex))
                    else do
                      extractRes <- extractInto target body
                      case extractRes of
                        Left err -> pure (Left err)
                        Right () -> pure (Right (target, shaHex))

-- | Extract a gzipped tarball ('ByteString') into @target@. We unwrap
-- GitHub's outer @REPO-\<short>@ directory so the cache layout starts
-- at the package root (= @target\/katari.toml@ is directly visible).
--
-- Path-traversal safety is enforced by 'Tar.checkSecurity', which
-- rejects entries whose names are absolute, contain @..@ components,
-- or are symlinks/hardlinks pointing outside the destination tree.
-- A malicious tarball cannot escape @stagingDir@.
extractInto :: FilePath -> ByteString -> IO (Either FetchError ())
extractInto target body = withSystemTempDirectory "katari-fetch" $ \tmp -> do
  let stagingDir = tmp </> "stage"
  createDirectoryIfMissing True stagingDir
  -- Decompress in memory, validate every entry, then unpack. Tar.unpack
  -- itself only writes regular files / dirs / safe symlinks, never
  -- followed by chmod / chown, so a hostile entry can't widen perms.
  let entries =
        rewrapErrors
          . Tar.checkSecurity
          . Tar.read
          . GZip.decompress
          $ LBS.fromStrict body
  res <- try (Tar.unpack stagingDir entries) :: IO (Either SomeException ())
  case res of
    Left err ->
      pure (Left (FetchTarballError (Text.pack (show err))))
    Right () -> do
      directoryEntries <- listDirectory stagingDir
      case directoryEntries of
        [single] -> do
          -- GitHub archives wrap everything in a top-level
          -- @REPO-\<short>@ directory; flatten it.
          createDirectoryIfMissing True (takeParent target)
          renameDirectory (stagingDir </> single) target
          pure (Right ())
        _ -> do
          -- No outer wrapper (= unusual but valid). Move the whole
          -- staging directory into place.
          createDirectoryIfMissing True (takeParent target)
          renameDirectory stagingDir target
          pure (Right ())
  where
    -- Avoid pulling in System.FilePath.takeDirectory just for this
    -- one call site — the inline reverse-split is cheap and clear.
    takeParent p = reverse (drop 1 (dropWhile (/= '/') (reverse p)))

-- | Wrap @tar@'s sum-of-error-types in a single Exception so 'Tar.unpack'
-- can surface them through 'try'.
newtype TarUnpackError = TarUnpackError String deriving stock (Show)

instance Exception TarUnpackError

rewrapErrors ::
  Tar.Entries (Either Tar.FormatError Tar.FileNameError) ->
  Tar.Entries TarUnpackError
rewrapErrors =
  Tar.foldEntries
    Tar.Next
    Tar.Done
    (Tar.Fail . TarUnpackError . either show show)
