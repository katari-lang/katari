-- | Locate @katari.toml@ and load all @.ktr@ files belonging to a project.
--
-- The compiler / LSP / future package manager all share this logic so they
-- agree on what counts as "the project's sources".
module Katari.Project.Discovery
  ( SourceEntry (..),
    findProjectRoot,
    scanSources,
    scanSourcesFromDir,
    collectKtrFiles,
    configFilename,
  )
where

import Control.Monad (filterM)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Katari.Project.Config (PackageSection (..), ProjectConfig (..))
import Katari.Project.ModuleName (moduleNameFromRelativePath)
import System.Directory
  ( canonicalizePath,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
  )
import System.FilePath (isAbsolute, makeRelative, takeDirectory, takeExtension, (</>))

-- | The file name our project lives under.
configFilename :: FilePath
configFilename = "katari.toml"

-- | One loaded source file. @sourcePath@ is the path on disk (used for
-- diagnostics + Query spans); @sourceText@ is its UTF-8 contents.
data SourceEntry = SourceEntry
  { sourcePath :: FilePath,
    sourceText :: Text
  }
  deriving (Show, Eq)

-- | Walk upward from @start@ looking for @katari.toml@. Returns the
-- directory containing it (= the project root), not the file itself.
findProjectRoot :: FilePath -> IO (Maybe FilePath)
findProjectRoot start = do
  absStart <- canonicalizePath start
  isDir <- doesDirectoryExist absStart
  let initial = if isDir then absStart else takeDirectory absStart
  go initial
  where
    go :: FilePath -> IO (Maybe FilePath)
    go dir = do
      let candidate = dir </> configFilename
      exists <- doesFileExist candidate
      if exists
        then pure (Just dir)
        else
          let parent = takeDirectory dir
           in if parent == dir
                then pure Nothing
                else go parent

-- | Load every @.ktr@ file under the project's source directory (as
-- specified by @[package].src@, relative to the project root). The
-- resulting map is keyed by module name.
scanSources :: FilePath -> ProjectConfig -> IO (Map Text SourceEntry)
scanSources rootDir config = do
  let rawSrc = config.packageSection.packageSrc
  let srcDir = if isAbsolute rawSrc then rawSrc else rootDir </> rawSrc
  scanSourcesFromDir srcDir

-- | Load every @.ktr@ file under @srcDir@ (recursive). Module names are
-- derived from the file's path relative to @srcDir@ (= subdirectories
-- become dot segments, e.g. @srcDir/foo/bar.ktr@ → module @foo.bar@).
--
-- Raises (via 'error') when two source files collapse to the same
-- module name (e.g. @foo.ktr@ and @foo/main.ktr@ both → @foo@ if
-- "main" weren't differentiated). The previous shape used Map.fromList
-- which silently kept the last entry, hiding the misconfiguration.
scanSourcesFromDir :: FilePath -> IO (Map Text SourceEntry)
scanSourcesFromDir srcDir = do
  files <- collectKtrFiles srcDir
  entries <- traverse readEntry files
  case foldr step (Right Map.empty) entries of
    Right m -> pure m
    Left (modName, (a, b)) ->
      error $
        "Katari.Project.Discovery: two source files map to the same module name '"
          <> Text.unpack modName
          <> "': "
          <> a
          <> " and "
          <> b
  where
    readEntry :: FilePath -> IO (Text, SourceEntry)
    readEntry p = do
      txt <- TextIO.readFile p
      let rel = makeRelative srcDir p
      pure
        ( moduleNameFromRelativePath rel,
          SourceEntry {sourcePath = p, sourceText = txt}
        )

    step (modName, entry) acc = do
      m <- acc
      case Map.lookup modName m of
        Just existing -> Left (modName, (existing.sourcePath, entry.sourcePath))
        Nothing -> Right (Map.insert modName entry m)

-- | Recursively collect every @.ktr@ file under @dir@. Returns paths
-- as-is (= relative or absolute depending on the input).
--
-- Symlink cycles are guarded against by tracking canonicalised paths:
-- a symlink whose target's canonical path has already been visited
-- is skipped. Without this, a cycle (= @src/a@ → @src/b@, @src/b@ →
-- @src/a@) would walk forever.
collectKtrFiles :: FilePath -> IO [FilePath]
collectKtrFiles dir = do
  go Set.empty dir
  where
    go visited path = do
      exists <- doesDirectoryExist path
      if not exists
        then pure []
        else do
          canonical <- canonicalizePath path
          if Set.member canonical visited
            then pure [] -- already walked through here; symlink cycle
            else do
              let visited' = Set.insert canonical visited
              entries <- listDirectory path
              let withDir = map (path </>) entries
              files <- filterM doesFileExist withDir
              let ktrFiles = filter ((== ".ktr") . takeExtension) files
              subdirs <- filterM doesDirectoryExist withDir
              rest <- concat <$> traverse (go visited') subdirs
              pure (ktrFiles <> rest)
