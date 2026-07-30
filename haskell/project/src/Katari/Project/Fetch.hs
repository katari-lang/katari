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
-- The hash is checked BEFORE anything is written: a tarball is hostile input until its pin says
-- otherwise, and 'Tar.unpack' on a decompression bomb costs the disk long before the mismatch would
-- have been noticed by a caller checking afterwards. See 'ExpectedSha' for the two things a caller can
-- know about the hash, only one of which is a pin.
--
-- GitHub wraps the tree in an outer @REPO-\<short>@ directory; that wrapper is unwrapped so the
-- cache layout is always @\<name>-\<sha256>/{katari.toml, src/, ...}@.
module Katari.Project.Fetch
  ( GitRef (..),
    ExpectedSha (..),
    fetchGitTarball,
    checkPinnedSha,
  )
where

import Codec.Archive.Tar qualified as Tar
import Codec.Compression.GZip qualified as GZip
import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.ByteString.Lazy qualified as ByteStringLazy
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Project.Cache
  ( CachePaths,
    cachedPackageDir,
    forgetPackageVerification,
    markPackageVerified,
    packageDir,
  )
import Katari.Project.Error
  ( ProjectError (..),
    ShaMismatchInfo (..),
    UrlErrorInfo (..),
    UrlInfo (..),
    formatException,
  )
import Katari.Project.Hash (sha256Hex)
import Katari.Project.Http (httpGetBytes)
import Network.HTTP.Client (Manager)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    listDirectory,
    removeDirectoryRecursive,
    renameDirectory,
  )
import System.FilePath ((</>))

-- | The git information the caller supplied. 'url' is the canonical repo URL (e.g.
-- @https://github.com/user/repo@); 'rev' is the ref to fetch — a full commit SHA for a git override
-- (enforced at config decode), or a snapshot pin's ref (which may be a tag, since a snapshot also
-- carries the @sha256@ that pins reproducibility).
data GitRef = GitRef
  { url :: Text,
    rev :: Text
  }
  deriving (Show, Eq)

-- | What the caller knows about the tarball's content hash before it is fetched.
--
-- The two cases differ in /authority/, not just in whether a value is present, which is why this is a
-- sum rather than a @Maybe Text@: a snapshot's @sha256@ is a promise the download must keep, while a
-- prior lockfile entry is only a record of what a @(url, rev)@ resolved to last time. Both name a cache
-- directory; only the pin may reject content.
data ExpectedSha
  = -- | A registry snapshot pin. The download is rejected unless it hashes to this, and the same value
    -- names the cache entry that lets the download be skipped entirely.
    PinnedSha Text
  | -- | No pin — a git override, whose content hash is unknowable until it has been fetched, so it is
    -- trusted on first use. The optional hash is a prior lockfile entry for the same @(url, rev)@,
    -- carried only to short-circuit the download.
    UnpinnedSha (Maybe Text)
  deriving (Show, Eq)

-- | Only GitHub archive URLs are supported in v0.1.
githubPrefix, archiveInfix, tarballSuffix, stagingSuffix :: Text
githubPrefix = "https://github.com/"
archiveInfix = "/archive/"
tarballSuffix = ".tar.gz"
stagingSuffix = ".unpack"

-- | Resolve a git dep into a local extracted source tree. Returns the absolute path of the extracted
-- directory AND the hex SHA-256 of the downloaded tarball (recorded in the lockfile).
fetchGitTarball :: Manager -> CachePaths -> Text -> GitRef -> ExpectedSha -> IO (Either ProjectError (FilePath, Text))
fetchGitTarball manager cache name gitReference expectedSha
  | not (githubPrefix `Text.isPrefixOf` gitReference.url) =
      pure (Left (FetchInvalidHost UrlInfo {url = gitReference.url}))
  | otherwise = do
      hit <- cacheHit
      case hit of
        Just result -> pure (Right result)
        Nothing -> downloadAndExtract
  where
    archiveUrl = Text.dropWhileEnd (== '/') gitReference.url <> archiveInfix <> gitReference.rev <> tarballSuffix

    -- The hash the caller can name this tree by, whether or not it has the authority to reject content.
    knownSha :: Maybe Text
    knownSha = case expectedSha of
      PinnedSha sha -> Just sha
      UnpinnedSha maybeSha -> maybeSha

    -- The hash the download MUST have, for 'checkPinnedSha'. Only a snapshot pin qualifies.
    requiredSha :: Maybe Text
    requiredSha = case expectedSha of
      PinnedSha sha -> Just sha
      UnpinnedSha _ -> Nothing

    -- A known sha names a unique source tree, so an entry the cache vouches for needs no network at all.
    cacheHit :: IO (Maybe (FilePath, Text))
    cacheHit = case knownSha of
      Nothing -> pure Nothing
      Just sha -> fmap (,sha) <$> cachedPackageDir cache name sha

    downloadAndExtract :: IO (Either ProjectError (FilePath, Text))
    downloadAndExtract = do
      downloadResult <- httpGetBytes manager archiveUrl FetchHttpError
      case downloadResult of
        Left projectError -> pure (Left projectError)
        Right body -> do
          let sha = sha256Hex body
          -- Before the disk is touched: 'Tar.unpack' on unverified bytes is how a correct pin still
          -- ends with a filled disk, since the mismatch would only be seen once the damage was done.
          case checkPinnedSha name requiredSha sha of
            Left projectError -> pure (Left projectError)
            Right () -> extractVerified body sha

    -- Place a tarball whose hash has been accepted. The content may already be extracted (a hint-less
    -- fetch of cached content); anything the cache does NOT vouch for is extracted over, so a planted
    -- or half-written directory heals here rather than being adopted.
    extractVerified :: ByteStringLazy.ByteString -> Text -> IO (Either ProjectError (FilePath, Text))
    extractVerified body sha = do
      cached <- cachedPackageDir cache name sha
      case cached of
        Just directory -> pure (Right (directory, sha))
        Nothing -> do
          let destination = packageDir cache name sha
          -- Uncertify first: between here and the sentinel below the directory is in flux, and a run
          -- interrupted in that window must leave a miss, not a lie.
          forgetPackageVerification cache name sha
          extractResult <- extractTarball archiveUrl body destination
          case extractResult of
            Left projectError -> pure (Left projectError)
            Right () -> do
              markPackageVerified cache name sha
              pure (Right (destination, sha))

-- | Verify a fetched tarball's content hash against the pin that required it (a registry snapshot's
-- @sha256@). 'Nothing' means no pin to check against (a git override, trusted on first use). Pure, so
-- this supply-chain guard is testable without performing a real fetch.
checkPinnedSha :: Text -> Maybe Text -> Text -> Either ProjectError ()
checkPinnedSha name requiredSha actualSha = case requiredSha of
  Just expected
    | actualSha /= expected ->
        Left (ResolveShaMismatch ShaMismatchInfo {dependency = name, expected = expected, actual = actualSha})
  _ -> Right ()

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
        -- The destination may already hold an untrusted tree (see 'extractVerified'); 'renameDirectory'
        -- will not replace a non-empty directory, so clear it rather than fail the fetch.
        destinationExists <- doesDirectoryExist destination
        when destinationExists (removeDirectoryRecursive destination)
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
