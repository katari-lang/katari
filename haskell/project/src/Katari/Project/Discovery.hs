-- | Locate @katari.toml@ and load all @.ktr@ files belonging to one package.
--
-- The compiler, LSP, and CLI share this logic so they agree on what counts as "the package's
-- sources". Module names are the compiler's 'ModuleName', built from each file's path relative to
-- the source root (subdirectories become dot segments: @src/foo/bar.ktr@ → module @foo.bar@), so the
-- result drops straight into @Katari.Compile.CompileInput@.
--
-- A 'SourceOverlay' lets the LSP feed unsaved editor buffers in: where the overlay has an entry for
-- a file's path it wins over the on-disk bytes, and overlay-only entries (a new, never-saved file)
-- are included too. The CLI passes 'emptyOverlay' and gets pure on-disk behaviour.
module Katari.Project.Discovery
  ( SourceEntry (..),
    SourceOverlay (..),
    emptyOverlay,
    configFilename,
    findProjectRoot,
    scanSources,
    scanSourcesFromDir,
    collectKtrFiles,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.ModuleName (ModuleName)
import Katari.Project.Config (ProjectConfig)
import Katari.Project.Error (ProjectError)

-- | The file a Katari package lives under.
configFilename :: FilePath
configFilename = "katari.toml"

-- | One loaded source file. 'path' is the on-disk path (for diagnostics); 'text' is its contents.
data SourceEntry = SourceEntry
  { path :: FilePath,
    text :: Text
  }
  deriving (Show, Eq)

-- | In-memory overrides for source files, keyed by canonical absolute path. Authoritative for the
-- paths it holds: an entry shadows the file on disk, and an entry for a not-yet-saved file is still
-- discovered. This is how the LSP keeps completions / diagnostics in sync with the editor before a
-- save reaches disk.
newtype SourceOverlay = SourceOverlay
  { files :: Map FilePath Text
  }
  deriving (Show, Eq)

emptyOverlay :: SourceOverlay
emptyOverlay = SourceOverlay Map.empty

-- | Walk upward from @start@ looking for @katari.toml@; return the directory containing it (the
-- project root), or 'Nothing' if none is found up to the filesystem root.
findProjectRoot :: FilePath -> IO (Maybe FilePath)
findProjectRoot = error "TODO: Katari.Project.Discovery.findProjectRoot"

-- | Load every @.ktr@ file under the package's source directory (@[package].src@, relative to the
-- project root), keyed by module name, applying the overlay.
scanSources :: SourceOverlay -> FilePath -> ProjectConfig -> IO (Either ProjectError (Map ModuleName SourceEntry))
scanSources = error "TODO: Katari.Project.Discovery.scanSources"

-- | Load every @.ktr@ file under @srcDir@ (recursive), keyed by the module name derived from each
-- file's path relative to @srcDir@, applying the overlay. Two files mapping to one module name is a
-- 'Katari.Project.Error.DuplicateModule' error rather than a silent last-write-wins.
scanSourcesFromDir :: SourceOverlay -> FilePath -> IO (Either ProjectError (Map ModuleName SourceEntry))
scanSourcesFromDir = error "TODO: Katari.Project.Discovery.scanSourcesFromDir"

-- | Recursively collect every @.ktr@ file under @dir@, guarding against symlink cycles by tracking
-- canonicalised paths already visited.
collectKtrFiles :: FilePath -> IO (List FilePath)
collectKtrFiles = error "TODO: Katari.Project.Discovery.collectKtrFiles"
