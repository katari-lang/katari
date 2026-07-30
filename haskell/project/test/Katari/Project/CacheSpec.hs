module Katari.Project.CacheSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Katari.Project.Cache
  ( CachePaths (..),
    cachedPackageDir,
    ensureCacheDirs,
    forgetPackageVerification,
    markPackageVerified,
    packageDir,
    projectCachePaths,
  )
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((<.>), (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- | A plausible content hash; only its shape matters, since nothing here recomputes it.
pinnedSha :: Text
pinnedSha = Text.replicate 64 "a"

-- | Run an action against a fresh project cache.
withCache :: (CachePaths -> IO a) -> IO a
withCache action = withSystemTempDirectory "katari-cache" $ \root -> do
  let cache = projectCachePaths root
  ensureCacheDirs cache
  action cache

-- | Put a source tree at the cache path for @(name, sha)@ without saying anything about where it came
-- from — exactly what a repository can commit into a checked-in @.katari\/@.
plantPackageDir :: CachePaths -> Text -> Text -> IO FilePath
plantPackageDir cache name sha = do
  let directory = packageDir cache name sha
  createDirectoryIfMissing True directory
  TextIO.writeFile (directory </> "katari.toml") "[package]\nname = \"lib\"\n"
  pure directory

spec :: Spec
spec =
  describe "cachedPackageDir" $ do
    -- The whole point of the sentinel: @.katari/@ is gitignored by the init template but nothing
    -- enforces that, so "the directory is there" is a claim the repository under review can make about
    -- itself. A cache entry has to have been put there by a verified extraction to count.
    it "does not accept a directory that katari never extracted" $ withCache $ \cache -> do
      _ <- plantPackageDir cache "lib" pinnedSha
      cachedPackageDir cache "lib" pinnedSha `shouldReturn` Nothing

    it "accepts a directory once its extraction has been recorded" $ withCache $ \cache -> do
      directory <- plantPackageDir cache "lib" pinnedSha
      markPackageVerified cache "lib" pinnedSha
      cachedPackageDir cache "lib" pinnedSha `shouldReturn` Just directory

    -- A sentinel is a statement about one sha, not a blanket "this was extracted": copying it onto a
    -- neighbouring entry must not certify that entry too.
    it "does not accept a sentinel recording a different sha" $ withCache $ \cache -> do
      _ <- plantPackageDir cache "lib" pinnedSha
      TextIO.writeFile (packageDir cache "lib" pinnedSha <.> "sha256") (Text.replicate 64 "b")
      cachedPackageDir cache "lib" pinnedSha `shouldReturn` Nothing

    -- The sentinel is written after the extraction completes, so a sentinel with no tree beside it can
    -- only be a leftover; the answer is still "not cached", never the missing directory.
    it "does not accept a sentinel with no extracted tree beside it" $ withCache $ \cache -> do
      markPackageVerified cache "lib" pinnedSha
      cachedPackageDir cache "lib" pinnedSha `shouldReturn` Nothing

    -- The window an interrupted re-extraction leaves behind: uncertified first, replace after.
    it "stops accepting an entry whose verification has been withdrawn" $ withCache $ \cache -> do
      _ <- plantPackageDir cache "lib" pinnedSha
      markPackageVerified cache "lib" pinnedSha
      forgetPackageVerification cache "lib" pinnedSha
      cachedPackageDir cache "lib" pinnedSha `shouldReturn` Nothing

    it "withdraws a verification that was never recorded without failing" $ withCache $ \cache ->
      forgetPackageVerification cache "lib" pinnedSha `shouldReturn` ()
