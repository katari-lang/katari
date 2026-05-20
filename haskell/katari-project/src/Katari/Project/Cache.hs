-- | The on-disk cache for downloaded dependencies.
--
-- Layout (planned in full when registry / git fetching land):
--
-- @
-- ~/.katari/cache/
-- \\── snapshots/
-- \\│   \\── 2026-05-01.toml         -- mirrored registry snapshot file
-- \\── packages/
--     \\── \<name>-\<sha256>/        -- extracted source tree (snapshot + git deps)
-- @
--
-- In v1 only the directory scaffolding is in place — path deps don't
-- touch the cache, and snapshot / git resolution lives behind PM-3.5
-- / PM-4. The functions here let callers know where things /will/
-- live so wiring lockfile reads + apply / build paths can land
-- without depending on the network code being ready.
module Katari.Project.Cache
  ( CachePaths (..),
    defaultCachePaths,
    ensureCacheDirs,
    packageDir,
  )
where

import qualified Data.Text as Text
import Data.Text (Text)
import System.Directory (XdgDirectory (..), createDirectoryIfMissing, getXdgDirectory)
import System.FilePath ((</>))

-- | Resolved on-disk paths for the cache. Construct with
-- 'defaultCachePaths' (= follows the XDG data dir, falling back to
-- @~/.katari@) or hand-craft for tests.
data CachePaths = CachePaths
  { -- | Top-level cache root (= the @~/.katari/cache@ dir).
    cacheRoot :: FilePath,
    -- | Where downloaded snapshot @\<date>.toml@ files live.
    cacheSnapshots :: FilePath,
    -- | Where extracted dep tarballs live, keyed by @\<name>-\<sha256>@.
    cachePackages :: FilePath
  }
  deriving (Show, Eq)

-- | Default install: respect @XDG_DATA_HOME@, otherwise fall back to
-- @~/.katari@. (We deliberately don't read @XDG_CACHE_HOME@ because
-- snapshot + lockfile-pinned deps are reproducible artefacts, not
-- throw-away caches — @data@ is the more accurate XDG bucket.)
defaultCachePaths :: IO CachePaths
defaultCachePaths = do
  base <- getXdgDirectory XdgData "katari"
  let root = base </> "cache"
  pure
    CachePaths
      { cacheRoot = root,
        cacheSnapshots = root </> "snapshots",
        cachePackages = root </> "packages"
      }

-- | Create every cache directory on demand. Safe to call repeatedly
-- (idempotent). Run this once per @katari@ invocation, before the
-- first cache lookup.
ensureCacheDirs :: CachePaths -> IO ()
ensureCacheDirs p = do
  createDirectoryIfMissing True p.cacheRoot
  createDirectoryIfMissing True p.cacheSnapshots
  createDirectoryIfMissing True p.cachePackages

-- | Convention: snapshot / git deps live at
-- @cachePackages \</> \<name>-\<sha256>@. The sha256 prefix doubles as
-- an integrity tag (= corrupted extractions get a fresh dir on
-- re-resolve).
packageDir :: CachePaths -> Text -> Text -> FilePath
packageDir p name sha = p.cachePackages </> Text.unpack (name <> "-" <> sha)
