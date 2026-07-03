-- | Shared server state across LSP requests.
--
--   * One 'WorkspaceState' per discovered @katari.toml@ root: the editor's unsaved buffers and the
--     artifacts of the most recent compile. The project itself (config, dependency graph, source
--     scan) is re-loaded from disk on every debounced recompile with the buffers overlaid — the
--     offline load is cheap, and reloading makes file creation / deletion and config edits correct
--     by construction instead of by invalidation bookkeeping.
--   * A loose bucket of files opened outside any project (diagnostics-only single-file compiles).
--   * Per-target debounce timers so didChange storms collapse into one recompile.
--
-- Mutation goes through STM 'TVar's so handlers can read / update without explicit locking.
module Katari.LSP.State
  ( ServerState (..),
    WorkspaceState (..),
    CompileArtifacts (..),
    RecompileTarget (..),
    FileContext (..),
    newServerState,
    findProjectRootCached,
    canonicalFilePath,
    lookupFileContext,
    moduleKeyOf,
  )
where

import Control.Concurrent (ThreadId)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector (Vector)
import Katari.Data.ModuleName (ModuleName, renderModuleName)
import Katari.LSP.Convert (SpanContext (..))
import Katari.Project.Discovery qualified as Project
import Katari.Query qualified as Query
import System.Directory (canonicalizePath)

-- | Everything a feature handler needs from the most recent compile of a workspace.
data CompileArtifacts = CompileArtifacts
  { snapshot :: Query.QuerySnapshot,
    occurrenceIndex :: Query.OccurrenceIndex,
    -- | Module-name-keyed texts / lines / real paths of the compiled sources (buffer overlay
    -- applied), for span ↔ editor-coordinate conversion.
    spanContext :: SpanContext,
    -- | Canonical real path → compiler module name, the inverse of the span context's path map.
    moduleByPath :: Map FilePath ModuleName
  }

data WorkspaceState = WorkspaceState
  { root :: FilePath,
    -- | Editor buffer overrides, keyed by canonical absolute path. Fed into the project load as a
    -- 'Project.SourceOverlay', so unsaved edits (and never-saved new files) reach the compiler.
    buffers :: Map FilePath Text,
    openFiles :: Set FilePath,
    lastCompile :: Maybe CompileArtifacts
  }

-- | What a debounce timer will compile when it fires. Workspace edits collapse on the workspace
-- root; orphan edits collapse per file (two orphans edited alternately must not steal each other's
-- timer).
data RecompileTarget
  = RecompileWorkspace FilePath
  | RecompileOrphan FilePath
  deriving stock (Eq, Ord, Show)

data ServerState = ServerState
  { workspaces :: TVar (Map FilePath WorkspaceState),
    -- | Files opened from outside any project (no enclosing @katari.toml@); they compile in
    -- isolation, diagnostics only.
    orphanFiles :: TVar (Map FilePath Text),
    debounceTimers :: TVar (Map RecompileTarget ThreadId),
    -- | @file path → enclosing workspace root@ memo over 'Project.findProjectRoot' (which
    -- canonicalises and walks parents — expensive enough to feel under fast typing). 'Nothing'
    -- records "no enclosing project" so known orphans are not re-walked. Entries are dropped when a
    -- @katari.toml@ appears or disappears (see the watched-files handler).
    projectRootCache :: TVar (Map FilePath (Maybe FilePath))
  }

newServerState :: IO ServerState
newServerState = do
  workspaces <- newTVarIO Map.empty
  orphanFiles <- newTVarIO Map.empty
  debounceTimers <- newTVarIO Map.empty
  projectRootCache <- newTVarIO Map.empty
  pure
    ServerState
      { workspaces = workspaces,
        orphanFiles = orphanFiles,
        debounceTimers = debounceTimers,
        projectRootCache = projectRootCache
      }

-- | Resolve a file to its enclosing workspace root via the cache.
findProjectRootCached :: ServerState -> FilePath -> IO (Maybe FilePath)
findProjectRootCached state path = do
  cache <- readTVarIO state.projectRootCache
  case Map.lookup path cache of
    Just cached -> pure cached
    Nothing -> do
      result <- Project.findProjectRoot path
      atomically $ modifyTVar' state.projectRootCache (Map.insert path result)
      pure result

-- | Canonicalise an editor path so it matches the keys the project scan produces (the source
-- discovery canonicalises the paths it hands out; editor URIs may spell the same file differently).
canonicalFilePath :: FilePath -> IO FilePath
canonicalFilePath = canonicalizePath

-- | One open file resolved against its workspace's most recent compile: its module name and
-- pre-split source lines (for position conversion and snippet slicing), plus the compile artifacts.
-- 'Nothing' for orphan files (diagnostics-only), for files not yet part of a compiled assembly, and
-- before the first compile lands.
data FileContext = FileContext
  { moduleName :: ModuleName,
    lineVector :: Vector Text,
    artifacts :: CompileArtifacts
  }

lookupFileContext :: ServerState -> FilePath -> IO (Maybe FileContext)
lookupFileContext state path = do
  canonicalPath <- canonicalFilePath path
  maybeRoot <- findProjectRootCached state canonicalPath
  case maybeRoot of
    Nothing -> pure Nothing
    Just root -> do
      workspaceMap <- readTVarIO state.workspaces
      pure $ do
        workspace <- Map.lookup root workspaceMap
        artifacts <- workspace.lastCompile
        moduleName <- Map.lookup canonicalPath artifacts.moduleByPath
        lineVector <- Map.lookup (moduleKeyOf moduleName) artifacts.spanContext.linesByModule
        Just FileContext {moduleName = moduleName, lineVector = lineVector, artifacts = artifacts}

-- | The 'SpanContext' key of a module: the rendered module name, as the parser stamps it into every
-- span's @filePath@ field. The single home of that convention on the LSP side.
moduleKeyOf :: ModuleName -> FilePath
moduleKeyOf = Text.unpack . renderModuleName
