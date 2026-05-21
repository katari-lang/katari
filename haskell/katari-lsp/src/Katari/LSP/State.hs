-- | Shared server state across LSP requests.
--
-- The state is intentionally minimal in v1:
--
--   * One 'WorkspaceState' per discovered @katari.toml@ root.
--   * A loose bucket of files opened outside any project (single-file
--     compilation).
--   * Per-workspace debounce timer so didChange storms collapse into
--     one recompile.
--
-- Mutation goes through STM 'TVar's so handlers can read / update
-- without explicit locking.
module Katari.LSP.State
  ( ServerState (..),
    WorkspaceState (..),
    newServerState,
    snapshotWorkspaceSources,
    lookupCompileResult,
    workspaceFileTexts,
    findProjectRootCached,
    RecompileTarget (..),
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (ThreadId)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)
import Katari.Compile (CompileInput (..), CompileResult, SourceEntry (..))
import qualified Katari.Project.Config as Project
import qualified Katari.Project.Discovery as Project
import qualified Katari.Project.Resolve as Project
import Katari.Query (OccurrenceIndex)

data WorkspaceState = WorkspaceState
  { wsRoot :: FilePath,
    wsConfig :: Project.ProjectConfig,
    -- | Resolved project graph (root + transitive path deps) as last
    -- loaded from disk. Module-name-keyed source map + owner / alias
    -- maps come straight from 'Project.assembleProject'.
    wsAssembly :: Project.ProjectAssembly,
    -- | Inverse index of the assembly: file path → module name. Lets
    -- @didChange@ rewrite the buffer without having to walk back
    -- through 'Project.assembleProject'.
    wsModuleByPath :: Map FilePath Text,
    -- | Editor buffer override: file path → unsaved text. Wins over
    -- the disk content captured in 'wsAssembly' when present.
    wsFiles :: Map FilePath Text,
    -- | File paths currently open in the editor.
    wsOpenFiles :: Set FilePath,
    wsLastResult :: Maybe CompileResult,
    wsOccIndex :: Maybe OccurrenceIndex
  }

-- | What 'scheduleRecompile' will compile when its debounce fires.
-- Lifted out of a stringly-typed key (= the old @"ws:" <> root@ /
-- @"orphan:" <> path@ scheme) so the dispatch in 'recompileNow' is
-- exhaustive at the type level.
data RecompileTarget
  = RecompileWorkspace FilePath  -- ^ Workspace root containing katari.toml.
  | RecompileOrphan FilePath     -- ^ Single .ktr file outside any project.
  deriving (Eq, Ord, Show)

data ServerState = ServerState
  { workspaces :: TVar (Map FilePath WorkspaceState),
    -- | Files opened from outside any project (no enclosing
    -- @katari.toml@). They compile in isolation.
    orphanFiles :: TVar (Map FilePath Text),
    -- | Debounce timers keyed by 'RecompileTarget' — workspace edits
    -- collapse on the workspace root, orphan edits collapse per-file.
    debounceTimers :: TVar (Map RecompileTarget ThreadId),
    -- | Cache of @file path → enclosing workspace root@ resolved by
    -- 'Project.findProjectRoot'. Each lookup canonicalises the path
    -- and walks parents to find @katari.toml@; without this cache a
    -- fast typist triggers dozens of those walks per second.
    -- Populated lazily on first lookup; a value of 'Nothing' records
    -- "no enclosing project" so we don't re-walk for known orphans.
    projectRootCache :: TVar (Map FilePath (Maybe FilePath))
  }

newServerState :: IO ServerState
newServerState = do
  ws <- newTVarIO Map.empty
  orph <- newTVarIO Map.empty
  timers <- newTVarIO Map.empty
  prc <- newTVarIO Map.empty
  pure
    ServerState
      { workspaces = ws,
        orphanFiles = orph,
        debounceTimers = timers,
        projectRootCache = prc
      }

-- | Build the 'CompileInput' that the compiler consumes. The assembly
-- already carries the canonical (convention-qualified) module-name
-- keys; this just overlays the editor buffer on top of the
-- disk-loaded contents for any file currently open with unsaved
-- changes.
snapshotWorkspaceSources :: WorkspaceState -> CompileInput
snapshotWorkspaceSources ws =
  CompileInput {sources = Map.map applyBuffer ws.wsAssembly.sources}
  where
    applyBuffer entry =
      case Map.lookup entry.sourcePath ws.wsFiles of
        Just buffered ->
          SourceEntry
            { filePath = entry.sourcePath,
              sourceText = buffered
            }
        Nothing ->
          SourceEntry
            { filePath = entry.sourcePath,
              sourceText = entry.sourceText
            }

-- | Resolve @path@ to its enclosing workspace root via the cache.
-- 'Project.findProjectRoot' canonicalises and walks parents; that's
-- expensive enough to feel under fast typing, so we memoise the
-- result for every path we've ever seen. Cache entries are conservative:
-- adding or removing a katari.toml between the cached lookup and the
-- next workspace recompile won't invalidate this map automatically;
-- in practice that only matters for `katari init` ↔ editor races and
-- is acceptable for v0.1.0.
findProjectRootCached :: ServerState -> FilePath -> IO (Maybe FilePath)
findProjectRootCached st path = do
  cache <- readTVarIO st.projectRootCache
  case Map.lookup path cache of
    Just cached -> pure cached
    Nothing -> do
      result <- Project.findProjectRoot path
      atomically $
        modifyTVar' st.projectRootCache (Map.insert path result)
      pure result

-- | Most recent successful compile result for the file at @path@. Looks
-- up the enclosing workspace; returns 'Nothing' for orphan files (the
-- v1 server does not cache per-file orphan compiles).
lookupCompileResult :: ServerState -> FilePath -> IO (Maybe (Text, CompileResult))
lookupCompileResult st path = do
  mRoot <- findProjectRootCached st path
  case mRoot of
    Just root -> do
      wsMap <- readTVarIO st.workspaces
      pure $ do
        ws <- Map.lookup root wsMap
        r <- ws.wsLastResult
        -- The text comes from the buffer overlay if present, otherwise
        -- from the disk-loaded assembly.
        let buffered = Map.lookup path ws.wsFiles
            disk = do
              modName <- Map.lookup path ws.wsModuleByPath
              entry <- Map.lookup modName ws.wsAssembly.sources
              Just entry.sourceText
        txt <- buffered <|> disk
        Just (txt, r)
    Nothing -> pure Nothing

-- | Map @path → text@ for every file in the enclosing workspace, with
-- the editor buffer overlay applied. Handlers that follow cross-file
-- references (find-definition, find-references) need the full map so
-- 'katariSpanToLspLocation' can do UTF-16 conversion on a span that
-- lives in a sibling module, not just the request's own file.
workspaceFileTexts :: ServerState -> FilePath -> IO (Map FilePath Text)
workspaceFileTexts st path = do
  mRoot <- findProjectRootCached st path
  case mRoot of
    Nothing -> pure Map.empty
    Just root -> do
      wsMap <- readTVarIO st.workspaces
      case Map.lookup root wsMap of
        Nothing -> pure Map.empty
        Just ws ->
          let diskTexts =
                Map.fromList
                  [ (entry.sourcePath, entry.sourceText)
                    | entry <- Map.elems ws.wsAssembly.sources
                  ]
           in -- Buffer overlay wins per-file, so unsaved edits show up
              -- in any UTF-16 conversion downstream.
              pure (Map.union ws.wsFiles diskTexts)
