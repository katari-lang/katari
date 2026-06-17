-- | Locate @katari.toml@ and load all @.ktr@ files belonging to one package.
--
-- The compiler, LSP, and CLI share this logic so they agree on what counts as "the package's
-- sources". Module names are the compiler's 'ModuleName', built from each file's path relative to
-- the source root (subdirectories become dot segments: @src/foo/bar.ktr@ → module @foo.bar@), so the
-- result drops straight into @Katari.Compile.CompileInput@.
module Katari.Project.Discovery
  ( SourceEntry (..),
    configFilename,
    findProjectRoot,
    scanSources,
    scanSourcesFromDir,
    collectKtrFiles,
  )
where

import Data.Map.Strict (Map)
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

-- | Walk upward from @start@ looking for @katari.toml@; return the directory containing it (the
-- project root), or 'Nothing' if none is found up to the filesystem root.
findProjectRoot :: FilePath -> IO (Maybe FilePath)
findProjectRoot = error "TODO: Katari.Project.Discovery.findProjectRoot"

-- | Load every @.ktr@ file under the package's source directory (@[package].src@, relative to the
-- project root), keyed by module name.
scanSources :: FilePath -> ProjectConfig -> IO (Either ProjectError (Map ModuleName SourceEntry))
scanSources = error "TODO: Katari.Project.Discovery.scanSources"

-- | Load every @.ktr@ file under @srcDir@ (recursive), keyed by the module name derived from each
-- file's path relative to @srcDir@. Two files mapping to one module name is a 'DuplicateModule'
-- error rather than a silent last-write-wins.
scanSourcesFromDir :: FilePath -> IO (Either ProjectError (Map ModuleName SourceEntry))
scanSourcesFromDir = error "TODO: Katari.Project.Discovery.scanSourcesFromDir"

-- | Recursively collect every @.ktr@ file under @dir@, guarding against symlink cycles by tracking
-- canonicalised paths already visited.
collectKtrFiles :: FilePath -> IO (List FilePath)
collectKtrFiles = error "TODO: Katari.Project.Discovery.collectKtrFiles"
