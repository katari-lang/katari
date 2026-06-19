-- | Project-local cache at @\<projectRoot>/.katari/@.
--
-- Layout (v0.1):
--
-- @
-- .katari/
-- ├── packages/      -- downloaded dependency sources
-- └── snapshots/     -- mirrored registry snapshot files
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
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

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
      packages = cacheRoot </> "packages",
      snapshots = cacheRoot </> "snapshots"
    }
  where
    cacheRoot = projectRoot </> ".katari"

-- | Create every cache directory on demand. Safe to call repeatedly. @createDirectoryIfMissing True@
-- also makes @.katari/@ itself, so the three calls together cover the whole tree.
ensureCacheDirs :: CachePaths -> IO ()
ensureCacheDirs paths = do
  createDirectoryIfMissing True paths.root
  createDirectoryIfMissing True paths.packages
  createDirectoryIfMissing True paths.snapshots

-- | Package source directory: @\<packages>/\<name>-\<sha256>@. The @name@ is the dependency name and
-- @sha@ the hex content hash that uniquely identifies the source tree.
packageDir :: CachePaths -> Text -> Text -> FilePath
packageDir paths name sha = paths.packages </> Text.unpack (name <> "-" <> sha)
