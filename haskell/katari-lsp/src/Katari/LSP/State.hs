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
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (ThreadId)
import Control.Concurrent.STM (TVar, newTVarIO, readTVarIO)
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

data ServerState = ServerState
  { workspaces :: TVar (Map FilePath WorkspaceState),
    -- | Files opened from outside any project (no enclosing
    -- @katari.toml@). They compile in isolation.
    orphanFiles :: TVar (Map FilePath Text),
    -- | Per-workspace debounce timers (keyed by workspace root, plus
    -- an empty string for the orphan bucket).
    debounceTimers :: TVar (Map FilePath ThreadId)
  }

newServerState :: IO ServerState
newServerState = do
  ws <- newTVarIO Map.empty
  orph <- newTVarIO Map.empty
  timers <- newTVarIO Map.empty
  pure ServerState {workspaces = ws, orphanFiles = orph, debounceTimers = timers}

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

-- | Most recent successful compile result for the file at @path@. Looks
-- up the enclosing workspace; returns 'Nothing' for orphan files (the
-- v1 server does not cache per-file orphan compiles).
lookupCompileResult :: ServerState -> FilePath -> IO (Maybe (Text, CompileResult))
lookupCompileResult st path = do
  mRoot <- Project.findProjectRoot path
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
