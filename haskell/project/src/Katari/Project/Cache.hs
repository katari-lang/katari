-- | Project-local cache at @\<projectRoot>/.katari/@.
--
-- Layout (v0.1):
--
-- @
-- .katari/
-- ├── packages/
-- │   ├── \<name>-\<sha256>/        -- an extracted dependency source tree
-- │   └── \<name>-\<sha256>.sha256  -- the sentinel saying katari extracted it (see 'cachedPackageDir')
-- └── snapshots/                  -- mirrored registry snapshot files
-- @
--
-- v0.1 has /no build cache/. The compiler runs fast enough to rebuild every module from source each
-- time, and per-module upload does not need one: build everything, hash each module's IR, and
-- upload only the modules whose hash differs from what the runtime already holds (see
-- 'Katari.Project.Upload'). So the cache stores only what is expensive to re-acquire — dependency
-- source trees fetched over the network.
--
-- The whole @.katari/@ directory is gitignored by default (@katari init@ writes the entry).
module Katari.Project.Cache
  ( CachePaths (..),
    projectCachePaths,
    ensureCacheDirs,
    packageDir,
    cachedPackageDir,
    markPackageVerified,
    forgetPackageVerification,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeFile)
import System.FilePath ((<.>), (</>))

-- | The cache root, relative to the project root, and its two subdirectories.
cacheDirName, packagesDirName, snapshotsDirName :: FilePath
cacheDirName = ".katari"
packagesDirName = "packages"
snapshotsDirName = "snapshots"

-- | Extension of the sentinel written beside an extracted package (see 'markPackageVerified').
sentinelExtension :: FilePath
sentinelExtension = "sha256"

-- | Resolved on-disk paths rooted at the project's @.katari/@ directory.
data CachePaths = CachePaths
  { root :: FilePath,
    packages :: FilePath,
    snapshots :: FilePath
  }
  deriving (Show, Eq)

-- | Build 'CachePaths' for a given project root directory.
projectCachePaths :: FilePath -> CachePaths
projectCachePaths projectRoot =
  CachePaths
    { root = cacheRoot,
      packages = cacheRoot </> packagesDirName,
      snapshots = cacheRoot </> snapshotsDirName
    }
  where
    cacheRoot = projectRoot </> cacheDirName

-- | Create every cache directory on demand. @createDirectoryIfMissing True@ creates parents, so each
-- subdirectory is made even on a first run with no @.katari/@ yet. Safe to call repeatedly.
ensureCacheDirs :: CachePaths -> IO ()
ensureCacheDirs paths = do
  createDirectoryIfMissing True paths.packages
  createDirectoryIfMissing True paths.snapshots

-- | Package source directory: @\<packages>/\<name>-\<sha256>@. The @name@ is the dependency name and
-- @sha@ the hex content hash that uniquely identifies the source tree.
packageDir :: CachePaths -> Text -> Text -> FilePath
packageDir paths name sha = paths.packages </> Text.unpack (name <> "-" <> sha)

-- | The sentinel recording that 'packageDir' holds the tree this project extracted for @sha@:
-- @\<packages>/\<name>-\<sha256>.sha256@, a one-line file holding that same @sha@.
--
-- It is a sibling rather than a file inside the package so the extracted tree stays byte-identical to
-- the archive it came from; the naming mirrors the @.unpack@ staging directory
-- ("Katari.Project.Fetch") so everything the cache owns beside a package is named after it.
packageSentinel :: CachePaths -> Text -> Text -> FilePath
packageSentinel paths name sha = packageDir paths name sha <.> sentinelExtension

-- | The cached source directory for @(name, sha)@, or 'Nothing' when the cache does not genuinely hold
-- it — the caller then fetches (or, offline, reports it as not cached).
--
-- Directory existence alone is not evidence: @.katari/@ is gitignored by the @katari init@ template but
-- nothing enforces that, so a hostile repository can ship a @\<name>-\<legitimate sha>/@ directory whose
-- contents were never hashed. Requiring the sentinel means such a directory is re-fetched over rather
-- than compiled and deployed. It is a marker of provenance, not a proof of content: the recorded hash is
-- of the /compressed tarball/, which cannot be recomputed from the extracted tree, so an attacker who
-- knows this format can plant the sentinel too. What it does buy — cheaply — is that a directory katari
-- did not extract, or one left half-extracted by an interrupted run, is never mistaken for verified
-- content.
cachedPackageDir :: CachePaths -> Text -> Text -> IO (Maybe FilePath)
cachedPackageDir paths name sha = do
  let directory = packageDir paths name sha
  hasDirectory <- doesDirectoryExist directory
  if not hasDirectory
    then pure Nothing
    else do
      recorded <- readSentinel (packageSentinel paths name sha)
      pure (if recorded == Just sha then Just directory else Nothing)

-- | Record that the tree now at 'packageDir' was extracted from a tarball whose hash was verified to be
-- @sha@. Called only after the extraction has completed, so an interrupted run leaves an uncertified
-- directory (a miss that heals on the next fetch) rather than a certified partial one.
markPackageVerified :: CachePaths -> Text -> Text -> IO ()
markPackageVerified paths name sha = TextIO.writeFile (packageSentinel paths name sha) (sha <> "\n")

-- | Drop the sentinel for @(name, sha)@, so an entry whose directory is about to be replaced is not
-- certified while the replacement is in flight. Absent file: nothing to do.
forgetPackageVerification :: CachePaths -> Text -> Text -> IO ()
forgetPackageVerification paths name sha = do
  let sentinel = packageSentinel paths name sha
  exists <- doesFileExist sentinel
  when exists (removeFile sentinel)

-- | The sha a sentinel records, or 'Nothing' when it is absent or unreadable. An unreadable sentinel is
-- treated as a cache miss for the same reason an absent one is: the point is to re-fetch, and failing
-- the whole command over a stray file in a directory the user may freely delete would be worse than the
-- download it avoids.
readSentinel :: FilePath -> IO (Maybe Text)
readSentinel path = do
  result <- try (TextIO.readFile path)
  pure $ case result of
    Left (_ :: IOException) -> Nothing
    Right contents -> Just (Text.strip contents)
