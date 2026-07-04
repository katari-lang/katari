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

-- | The extension (including the dot) of a Katari source file.
ktrExtension :: FilePath
ktrExtension = ".ktr"

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
  -- 'collectKtrFiles' returns canonical paths, so the overlay (keyed by canonical path) can shadow a
  -- disk file directly, and overlay-only files are exactly the overlay keys not already discovered.
  diskFiles <- if dirExists then collectKtrFiles canonicalSrc else pure []
  let discovered = Set.fromList diskFiles
      overlayOnlyPaths =
        [ path
          | path <- Map.keys overlay.files,
            takeExtension path == ktrExtension,
            isUnder canonicalSrc path,
            not (Set.member path discovered)
        ]
  diskEntries <- forM diskFiles $ \path -> do
    text <- maybe (TextIO.readFile path) pure (Map.lookup path overlay.files)
    pure (moduleNameForFile canonicalSrc path, SourceEntry {path = path, text = text})
  let overlayEntries =
        [ (moduleNameForFile canonicalSrc path, SourceEntry {path = path, text = Map.findWithDefault "" path overlay.files})
          | path <- overlayOnlyPaths
        ]
  pure (buildModuleMap (diskEntries <> overlayEntries))

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

-- | Recursively collect every @.ktr@ file under @dir@, guarding against symlink cycles (tracking the
-- canonical directories already visited) and against symlinks that escape @dir@ (a directory or file
-- is kept only when its /canonical/ path stays under the root). This is what makes 'validateSourceDir'
-- a real guarantee: a @src/@ symlink pointing at @/etc@ cannot pull foreign @.ktr@ files into the
-- package. Returns canonical paths, sorted for deterministic ordering, so overlay shadowing in
-- 'scanSourcesFromDir' needs no further canonicalisation.
collectKtrFiles :: FilePath -> IO (List FilePath)
collectKtrFiles dir = do
  exists <- doesDirectoryExist dir
  if not exists
    then pure []
    else do
      root <- canonicalizePath dir
      sort . snd <$> walk root (Set.singleton root) root
  where
    walk root visited current = do
      names <- listDirectory current
      foldM (step root current) (visited, []) names
    step root current (visited, accumulated) name = do
      let fullPath = current </> name
      isDirectory <- doesDirectoryExist fullPath
      if isDirectory
        then do
          canonical <- canonicalizePath fullPath
          -- Skip a directory already visited (symlink cycle) or one whose real location escapes the
          -- root (a symlink out of the tree).
          if Set.member canonical visited || not (isUnder root canonical)
            then pure (visited, accumulated)
            else do
              (visited', nested) <- walk root (Set.insert canonical visited) canonical
              pure (visited', nested <> accumulated)
        else
          if takeExtension fullPath == ktrExtension
            then do
              -- Resolve the file too, so a symlinked @.ktr@ pointing outside the root is dropped
              -- rather than read.
              canonical <- canonicalizePath fullPath
              if isUnder root canonical
                then pure (visited, canonical : accumulated)
                else pure (visited, accumulated)
            else pure (visited, accumulated)
