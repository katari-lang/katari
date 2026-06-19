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

import Control.Monad (foldM, forM)
import Data.List (isPrefixOf, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import GHC.List (List)
import Katari.Data.ModuleName (ModuleName, moduleNameFromSegments)
import Katari.Project.Config (PackageSection (..), ProjectConfig (..))
import Katari.Project.Error (DuplicateModuleInfo (..), ProjectError (..))
import System.Directory
  ( canonicalizePath,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
  )
import System.FilePath
  ( dropExtension,
    makeRelative,
    splitDirectories,
    takeDirectory,
    takeExtension,
    (</>),
  )

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
-- project root), or 'Nothing' if none is found up to the filesystem root. @start@ may be a file or a
-- directory; a file's directory is the first candidate.
findProjectRoot :: FilePath -> IO (Maybe FilePath)
findProjectRoot start = do
  canonical <- canonicalizePath start
  isDirectory <- doesDirectoryExist canonical
  go (if isDirectory then canonical else takeDirectory canonical)
  where
    go directory = do
      hasConfig <- doesFileExist (directory </> configFilename)
      if hasConfig
        then pure (Just directory)
        else do
          let parent = takeDirectory directory
          -- 'takeDirectory' is a fixed point at the filesystem root ("/" -> "/"), so this terminates.
          if parent == directory then pure Nothing else go parent

-- | Load every @.ktr@ file under the package's source directory (@[package].src@, relative to the
-- project root), keyed by module name, applying the overlay.
scanSources :: SourceOverlay -> FilePath -> ProjectConfig -> IO (Either ProjectError (Map ModuleName SourceEntry))
scanSources overlay projectRoot config =
  scanSourcesFromDir overlay (projectRoot </> config.package.src)

-- | Load every @.ktr@ file under @srcDir@ (recursive), keyed by the module name derived from each
-- file's path relative to @srcDir@, applying the overlay. Two files mapping to one module name is a
-- 'Katari.Project.Error.DuplicateModule' error rather than a silent last-write-wins.
scanSourcesFromDir :: SourceOverlay -> FilePath -> IO (Either ProjectError (Map ModuleName SourceEntry))
scanSourcesFromDir overlay srcDir = do
  canonicalSrc <- canonicalizePath srcDir
  dirExists <- doesDirectoryExist canonicalSrc
  diskFiles <- if dirExists then collectKtrFiles canonicalSrc else pure []
  -- Pair each on-disk file with its canonical path so the overlay (keyed by canonical path) can
  -- shadow it, and so overlay-only files can be told apart from already-discovered ones.
  diskFilesWithCanonical <- forM diskFiles (\filePath -> (,filePath) <$> canonicalizePath filePath)
  let discoveredCanonical = Set.fromList (map fst diskFilesWithCanonical)
      overlayOnlyPaths =
        [ canonicalPath
          | canonicalPath <- Map.keys overlay.files,
            takeExtension canonicalPath == ".ktr",
            isUnder canonicalSrc canonicalPath,
            not (Set.member canonicalPath discoveredCanonical)
        ]
  diskEntries <- forM diskFilesWithCanonical $ \(canonicalPath, filePath) -> do
    text <- maybe (TextIO.readFile filePath) pure (Map.lookup canonicalPath overlay.files)
    pure (moduleNameForFile canonicalSrc filePath, SourceEntry {path = filePath, text = text})
  let overlayEntries =
        [ ( moduleNameForFile canonicalSrc canonicalPath,
            SourceEntry {path = canonicalPath, text = Map.findWithDefault "" canonicalPath overlay.files}
          )
          | canonicalPath <- overlayOnlyPaths
        ]
  pure (buildModuleMap (diskEntries ++ overlayEntries))

-- | The module name a file contributes: its path relative to the source root, extension dropped, with
-- directory separators becoming @.@ segments (@\<src>/foo/bar.ktr@ -> @foo.bar@).
moduleNameForFile :: FilePath -> FilePath -> ModuleName
moduleNameForFile srcRoot filePath =
  moduleNameFromSegments (map Text.pack (splitDirectories (dropExtension (makeRelative srcRoot filePath))))

-- | Whether @path@ lies strictly inside directory @base@ (a descendant, not @base@ itself).
isUnder :: FilePath -> FilePath -> Bool
isUnder base path =
  let baseSegments = splitDirectories base
      pathSegments = splitDirectories path
   in baseSegments `isPrefixOf` pathSegments && length pathSegments > length baseSegments

-- | Fold @(moduleName, entry)@ pairs into a map, rejecting two /different/ files that collapse to the
-- same module name. An overlay that shadows a disk file shares its path, so it is not a collision.
buildModuleMap :: List (ModuleName, SourceEntry) -> Either ProjectError (Map ModuleName SourceEntry)
buildModuleMap = foldM insertEntry Map.empty
  where
    insertEntry accumulated (moduleName, entry) = case Map.lookup moduleName accumulated of
      Just existing
        | existing.path /= entry.path ->
            Left
              ( DuplicateModule
                  DuplicateModuleInfo
                    { moduleName = moduleName,
                      firstPath = existing.path,
                      secondPath = entry.path
                    }
              )
      _ -> Right (Map.insert moduleName entry accumulated)

-- | Recursively collect every @.ktr@ file under @dir@, guarding against symlink cycles by tracking
-- canonicalised paths already visited. The result is sorted for deterministic ordering.
collectKtrFiles :: FilePath -> IO (List FilePath)
collectKtrFiles dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      canonical <- canonicalizePath dir
      sort . snd <$> walk (Set.singleton canonical) canonical
  where
    walk visited current = do
      names <- listDirectory current
      foldM (step current) (visited, []) names
    step current (visited, accumulated) name = do
      let fullPath = current </> name
      isDirectory <- doesDirectoryExist fullPath
      if isDirectory
        then do
          canonical <- canonicalizePath fullPath
          if Set.member canonical visited
            then pure (visited, accumulated)
            else do
              (visited', nested) <- walk (Set.insert canonical visited) fullPath
              pure (visited', accumulated <> nested)
        else
          if takeExtension fullPath == ".ktr"
            then pure (visited, fullPath : accumulated)
            else pure (visited, accumulated)
