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

import Data.Text (Text)
import Katari.Project.Cache (CachePaths)
import Katari.Project.Error (ProjectError)
import Network.HTTP.Client (Manager)

-- | The git information the caller supplied. 'url' is the canonical repo URL (e.g.
-- @https://github.com/user/repo@); 'rev' must be a full 40-char commit SHA for reproducibility.
data GitRef = GitRef
  { url :: Text,
    rev :: Text
  }
  deriving (Show, Eq)

-- | Resolve a git dep into a local extracted source tree. Returns the absolute path of the extracted
-- directory AND the hex SHA-256 of the downloaded tarball (recorded in the lockfile).
fetchGitTarball :: Manager -> CachePaths -> Text -> GitRef -> IO (Either ProjectError (FilePath, Text))
fetchGitTarball = error "TODO: Katari.Project.Fetch.fetchGitTarball"
