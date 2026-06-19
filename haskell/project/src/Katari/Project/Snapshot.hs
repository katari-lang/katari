-- | Registry snapshot files — the curated @(url, rev, sha256)@ pins for each package in a set.
--
-- Two concerns:
--
--   1. Parse a snapshot TOML file (one @package-sets/\<version>.toml@):
--
--      @
--      # compiler = "0.1.0"   # optional
--      [packages.list_utils]
--      url    = "https://github.com/katari-lang/list_utils"
--      rev    = "v0.2.1"
--      sha256 = "abc..."
--      @
--
--   2. Resolve a URL (from @[dependencies].registry@ + @[dependencies].snapshot@) into the snapshot
--      bytes, supporting @file://@ and @https://@ plus the "URL points at the registry root, the
--      version is the filename" convention (@\<root>/package-sets/\<version>.toml@).
--
-- Downstream ('Katari.Project.Resolve') looks up each dep, fetches the tarball at the pinned
-- @(url, rev)@ via 'Katari.Project.Fetch', and verifies the download against the @sha256@ pin.
module Katari.Project.Snapshot
  ( Snapshot (..),
    SnapshotPackage (..),
    parseSnapshot,
    loadSnapshotFromUrl,
  )
where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Katari.Project.Error (ProjectError)
import Network.HTTP.Client (Manager)

data Snapshot = Snapshot
  { compilerVersion :: Maybe Text,
    packages :: Map Text SnapshotPackage
  }
  deriving (Show, Eq)

-- | One pinned package. Field vocabulary ('url', 'rev', 'sha') is shared with the git override and
-- the lockfile; here 'rev' is the curated tag/ref and 'sha' the verified tarball content hash.
data SnapshotPackage = SnapshotPackage
  { url :: Text,
    rev :: Text,
    sha :: Text
  }
  deriving (Show, Eq)

-- | Parse the textual contents of a snapshot file.
parseSnapshot :: FilePath -> Text -> Either ProjectError Snapshot
parseSnapshot = error "TODO: Katari.Project.Snapshot.parseSnapshot"

-- | Load a snapshot from a registry URL. The @Maybe Text@ is the @snapshot@ version, used to build
-- the @\<root>/package-sets/\<version>.toml@ path when the URL is a registry root rather than a
-- direct @.toml@ file.
loadSnapshotFromUrl :: Manager -> Text -> Maybe Text -> IO (Either ProjectError Snapshot)
loadSnapshotFromUrl = error "TODO: Katari.Project.Snapshot.loadSnapshotFromUrl"
