-- | Project-local cache at @\<projectRoot>/.katari/@.
--
-- Layout:
--
-- @
-- .katari/
-- ├── cache/         -- compile cache
-- ├── dist/          -- build output (bundle.json)
-- ├── packages/      -- downloaded dependency sources
-- └── snapshots/     -- mirrored registry snapshot files
-- @
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

-- | Resolved on-disk paths rooted at the project's @.katari/@ directory.
data CachePaths = CachePaths
  { root :: FilePath,
    snapshots :: FilePath,
    packages :: FilePath,
    dist :: FilePath,
    compile :: FilePath
  }
  deriving (Show, Eq)

-- | Build 'CachePaths' for a given project root directory.
projectCachePaths :: FilePath -> CachePaths
projectCachePaths = error "TODO: Katari.Project.Cache.projectCachePaths"

-- | Create every cache directory on demand. Safe to call repeatedly.
ensureCacheDirs :: CachePaths -> IO ()
ensureCacheDirs = error "TODO: Katari.Project.Cache.ensureCacheDirs"

-- | Package source directory: @\<packages>/\<name>-\<sha256>@.
packageDir :: CachePaths -> Text -> Text -> FilePath
packageDir = error "TODO: Katari.Project.Cache.packageDir"
