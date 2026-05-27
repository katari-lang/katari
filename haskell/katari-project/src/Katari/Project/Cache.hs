-- | Project-local cache at @\<projectRoot>/.katari/@.
--
-- Layout:
--
-- @
-- .katari/
-- ├── cache/         -- compile cache (per-module .json)
-- ├── dist/          -- build output (bundle.json)
-- ├── packages/      -- downloaded dependency sources
-- └── snapshots/     -- mirrored registry snapshot files
-- @
--
-- The entire @.katari/@ directory is gitignored by default
-- (@katari init@ includes it in the generated @.gitignore@).
module Katari.Project.Cache
  ( CachePaths (..),
    projectCachePaths,
    ensureCacheDirs,
    packageDir,
  )
where

import Data.Text (Text)
import qualified Data.Text as Text
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

-- | Resolved on-disk paths rooted at the project's @.katari/@ directory.
data CachePaths = CachePaths
  { cacheRoot :: FilePath,
    cacheSnapshots :: FilePath,
    cachePackages :: FilePath,
    cacheDist :: FilePath,
    cacheCompile :: FilePath
  }
  deriving (Show, Eq)

-- | Build 'CachePaths' for a given project root directory.
projectCachePaths :: FilePath -> CachePaths
projectCachePaths projectRoot =
  let root = projectRoot </> ".katari"
   in CachePaths
        { cacheRoot = root,
          cacheSnapshots = root </> "snapshots",
          cachePackages = root </> "packages",
          cacheDist = root </> "dist",
          cacheCompile = root </> "cache"
        }

-- | Create every cache directory on demand. Safe to call repeatedly.
ensureCacheDirs :: CachePaths -> IO ()
ensureCacheDirs p = do
  createDirectoryIfMissing True p.cacheRoot
  createDirectoryIfMissing True p.cacheSnapshots
  createDirectoryIfMissing True p.cachePackages
  createDirectoryIfMissing True p.cacheDist
  createDirectoryIfMissing True p.cacheCompile

-- | Package source directory:
-- @cachePackages \</> \<name>-\<sha256>@
packageDir :: CachePaths -> Text -> Text -> FilePath
packageDir p name sha = p.cachePackages </> Text.unpack (name <> "-" <> sha)
