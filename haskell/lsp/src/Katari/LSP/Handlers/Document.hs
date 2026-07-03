-- | Document lifecycle handlers: @didOpen@ / @didChange@ / @didClose@, the debounced recompile
-- pipeline, diagnostics publishing, and disk-side watched-file events.
--
-- Every editor event updates the buffer overlay and schedules a debounced (150 ms) recompile of its
-- target. A workspace recompile re-loads the project from disk with the buffers overlaid
-- ('Project.loadProjectOffline'), so file creation / deletion and dependency edits are picked up by
-- construction — there is no assembly cache to invalidate.
module Katari.LSP.Handlers.Document
  ( documentHandlers,
    recompileNow,
    watchedFilesHandler,
  )
where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.STM (atomically, modifyTVar', readTVar, readTVarIO)
import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import Data.Foldable (for_)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Compile qualified as Compile
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.SourceSpan (Located (..), SourceSpan (..))
import Katari.Diagnostics (Diagnostics, finalizeDiagnostics)
import Katari.Error (CompilerError, Severity (..), compilerErrorCode, renderCompilerError, severityOf)
import Katari.LSP.Convert (SpanContext (..), spanToRange, textToLineVector)
import Katari.LSP.State
  ( CompileArtifacts (..),
    RecompileTarget (..),
    ServerState (..),
    WorkspaceState (..),
    canonicalFilePath,
    findProjectRootCached,
    moduleKeyOf,
  )
import Katari.Project.Discovery qualified as Project
import Katari.Project.Error qualified as Project
import Katari.Project.Resolve qualified as Project
import Katari.Query qualified as Query
import Language.LSP.Protocol.Lens qualified as L
import Language.LSP.Protocol.Message qualified as LSP
import Language.LSP.Protocol.Types qualified as LSP
import Language.LSP.Server qualified as LSP
import Language.LSP.VFS qualified as VFS
import System.FilePath (dropExtension, takeDirectory, takeFileName)
import System.IO qualified

---------------------------------------------------------------------------------------------------
-- Handlers
---------------------------------------------------------------------------------------------------

documentHandlers :: ServerState -> LSP.Handlers (LSP.LspM ())
documentHandlers state =
  mconcat
    [ LSP.notificationHandler LSP.SMethod_TextDocumentDidOpen $ \message -> do
        let uri = message ^. L.params . L.textDocument . L.uri
            text = message ^. L.params . L.textDocument . L.text
        for_ (LSP.uriToFilePath uri) $ \path -> do
          liftIO (onOpen state path text)
          scheduleRecompile state path,
      LSP.notificationHandler LSP.SMethod_TextDocumentDidChange $ \message -> do
        let uri = message ^. L.params . L.textDocument . L.uri
        virtualFile <- LSP.getVirtualFile (LSP.toNormalizedUri uri)
        case (LSP.uriToFilePath uri, virtualFile) of
          (Just path, Just file) -> do
            liftIO (onChange state path (VFS.virtualFileText file))
            scheduleRecompile state path
          _ -> pure (),
      LSP.notificationHandler LSP.SMethod_TextDocumentDidClose $ \message -> do
        let uri = message ^. L.params . L.textDocument . L.uri
        for_ (LSP.uriToFilePath uri) $ \path -> do
          wasOrphan <- liftIO (onClose state path)
          -- A closed orphan has no recompile to clear its markers; drop them here.
          if wasOrphan
            then publishFor uri []
            else scheduleRecompile state path
    ]

---------------------------------------------------------------------------------------------------
-- State updates
---------------------------------------------------------------------------------------------------

onOpen :: ServerState -> FilePath -> Text -> IO ()
onOpen state path text = do
  canonicalPath <- canonicalFilePath path
  maybeRoot <- findProjectRootCached state canonicalPath
  case maybeRoot of
    Nothing -> atomically $ modifyTVar' state.orphanFiles (Map.insert canonicalPath text)
    Just root -> atomically $ modifyTVar' state.workspaces (Map.alter (attach root canonicalPath) root)
  where
    attach root canonicalPath existing =
      let workspace =
            fromMaybe
              WorkspaceState
                { root = root,
                  buffers = Map.empty,
                  openFiles = Set.empty,
                  lastCompile = Nothing
                }
              existing
       in Just
            workspace
              { buffers = Map.insert canonicalPath text workspace.buffers,
                openFiles = Set.insert canonicalPath workspace.openFiles
              }

onChange :: ServerState -> FilePath -> Text -> IO ()
onChange state path text = do
  canonicalPath <- canonicalFilePath path
  maybeRoot <- findProjectRootCached state canonicalPath
  case maybeRoot of
    Nothing -> atomically $ modifyTVar' state.orphanFiles (Map.insert canonicalPath text)
    Just root ->
      atomically $
        modifyTVar'
          state.workspaces
          (Map.adjust (\workspace -> workspace {buffers = Map.insert canonicalPath text workspace.buffers}) root)

-- | Returns whether the closed file was an orphan (so the caller clears its diagnostics instead of
-- scheduling a recompile). Both the open marker and the buffer are dropped so the next compile
-- falls back to the on-disk content rather than serving stale editor text.
onClose :: ServerState -> FilePath -> IO Bool
onClose state path = do
  canonicalPath <- canonicalFilePath path
  maybeRoot <- findProjectRootCached state canonicalPath
  case maybeRoot of
    Nothing -> do
      atomically $ modifyTVar' state.orphanFiles (Map.delete canonicalPath)
      pure True
    Just root -> do
      atomically $
        modifyTVar'
          state.workspaces
          ( Map.adjust
              ( \workspace ->
                  workspace
                    { buffers = Map.delete canonicalPath workspace.buffers,
                      openFiles = Set.delete canonicalPath workspace.openFiles
                    }
              )
              root
          )
      pure False

-- | Load / compile failures previously would drop silently — the user would just see "no
-- intellisense" with no signal. Surface them via stderr so the editor's output panel shows the
-- cause.
warn :: String -> IO ()
warn = System.IO.hPutStrLn System.IO.stderr . ("katari-lsp warning: " <>)

---------------------------------------------------------------------------------------------------
-- Debounced recompile
---------------------------------------------------------------------------------------------------

-- | Debounce interval in microseconds (150 ms): long enough to collapse a typing burst, short
-- enough that diagnostics feel immediate.
debounceMicroseconds :: Int
debounceMicroseconds = 150_000

scheduleRecompile :: ServerState -> FilePath -> LSP.LspM () ()
scheduleRecompile state path = do
  canonicalPath <- liftIO (canonicalFilePath path)
  maybeRoot <- liftIO (findProjectRootCached state canonicalPath)
  let target = case maybeRoot of
        Just root -> RecompileWorkspace root
        Nothing -> RecompileOrphan canonicalPath
  environment <- LSP.getLspEnv
  liftIO $ do
    previousTimer <- atomically $ do
      timers <- readTVar state.debounceTimers
      pure (Map.lookup target timers)
    for_ previousTimer killThread
    newTimer <- forkIO $ do
      threadDelay debounceMicroseconds
      LSP.runLspT environment (recompileNow state target)
    atomically $ modifyTVar' state.debounceTimers (Map.insert target newTimer)

recompileNow :: ServerState -> RecompileTarget -> LSP.LspM () ()
recompileNow state = \case
  RecompileWorkspace root -> recompileWorkspace state root
  RecompileOrphan path -> recompileOrphan state path

recompileWorkspace :: ServerState -> FilePath -> LSP.LspM () ()
recompileWorkspace state root = do
  maybeWorkspace <- liftIO (Map.lookup root <$> readTVarIO state.workspaces)
  for_ maybeWorkspace $ \workspace -> do
    loaded <- liftIO (Project.loadProjectOffline (Project.SourceOverlay workspace.buffers) root)
    case loaded of
      Left projectError ->
        liftIO (warn ("load failed at " <> root <> ": " <> Text.unpack (Project.renderProjectError projectError)))
      Right resolved -> case Project.assembleProject resolved of
        Left projectError ->
          liftIO (warn ("assemble failed at " <> root <> ": " <> Text.unpack (Project.renderProjectError projectError)))
        Right assembly -> do
          let sourceEntries = assembly.sources
              result = Compile.compile Compile.CompileInput {Compile.sources = Project.compileInputSources assembly}
              texts =
                Map.fromList
                  [(moduleKeyOf moduleName, entry.text) | (moduleName, entry) <- Map.toList sourceEntries]
              spanContext =
                SpanContext
                  { textsByModule = texts,
                    linesByModule = textToLineVector <$> texts,
                    pathsByModule =
                      Map.fromList
                        [(moduleKeyOf moduleName, entry.path) | (moduleName, entry) <- Map.toList sourceEntries]
                  }
              snapshot = Query.buildQuerySnapshot result
              artifacts =
                CompileArtifacts
                  { snapshot = snapshot,
                    occurrenceIndex = Query.buildOccurrenceIndex snapshot,
                    spanContext = spanContext,
                    moduleByPath =
                      Map.fromList
                        [(entry.path, moduleName) | (moduleName, entry) <- Map.toList sourceEntries]
                  }
          liftIO $
            atomically $
              modifyTVar'
                state.workspaces
                (Map.adjust (\current -> current {lastCompile = Just artifacts}) root)
          publishDiagnostics spanContext result.diagnostics

recompileOrphan :: ServerState -> FilePath -> LSP.LspM () ()
recompileOrphan state path = do
  files <- liftIO (readTVarIO state.orphanFiles)
  for_ (Map.lookup path files) $ \text -> do
    -- The orphan bucket cannot use directory-based module naming (there is no source root to
    -- relativise against), so the file's basename is its module name.
    let moduleName = ModuleName (Text.pack (dropExtension (takeFileName path)))
        result = Compile.compile Compile.CompileInput {Compile.sources = Map.singleton moduleName text}
        spanContext =
          SpanContext
            { textsByModule = Map.singleton (moduleKeyOf moduleName) text,
              linesByModule = Map.singleton (moduleKeyOf moduleName) (textToLineVector text),
              pathsByModule = Map.singleton (moduleKeyOf moduleName) path
            }
    publishDiagnostics spanContext result.diagnostics

---------------------------------------------------------------------------------------------------
-- Diagnostics publishing
---------------------------------------------------------------------------------------------------

publishDiagnostics :: SpanContext -> Diagnostics -> LSP.LspM () ()
publishDiagnostics spanContext diagnostics = do
  let grouped =
        Map.fromListWith
          (flip (<>))
          [(located.sourceSpan.filePath, [located]) | located <- finalizeDiagnostics diagnostics]
      -- Always emit an entry for every module of the compile so the editor clears stale markers
      -- when problems disappear.
      byModule = Map.union grouped (Map.map (const []) spanContext.textsByModule)
  for_ (Map.toList byModule) $ \(moduleKey, locatedErrors) ->
    -- A module without a real path (the embedded stdlib) has no document to attach markers to.
    for_ (Map.lookup moduleKey spanContext.pathsByModule) $ \realPath ->
      publishFor (LSP.filePathToUri realPath) (diagnosticToLsp spanContext <$> locatedErrors)

publishFor :: LSP.Uri -> List LSP.Diagnostic -> LSP.LspM () ()
publishFor uri diagnostics =
  LSP.sendNotification LSP.SMethod_TextDocumentPublishDiagnostics $
    LSP.PublishDiagnosticsParams uri Nothing diagnostics

diagnosticToLsp :: SpanContext -> Located CompilerError -> LSP.Diagnostic
diagnosticToLsp spanContext located =
  LSP.Diagnostic
    { LSP._range = spanToRange spanContext located.sourceSpan,
      LSP._severity = Just (mapSeverity (severityOf located.value)),
      LSP._code = Just (LSP.InR (compilerErrorCode located.value)),
      LSP._codeDescription = Nothing,
      LSP._source = Just "katari",
      LSP._message = renderCompilerError located.value,
      LSP._tags = Nothing,
      LSP._relatedInformation = Nothing,
      LSP._data_ = Nothing
    }

mapSeverity :: Severity -> LSP.DiagnosticSeverity
mapSeverity = \case
  SeverityError -> LSP.DiagnosticSeverity_Error
  SeverityWarning -> LSP.DiagnosticSeverity_Warning

---------------------------------------------------------------------------------------------------
-- Watched files (disk-side .ktr / katari.toml create / change / delete)
---------------------------------------------------------------------------------------------------

-- | React to disk changes made outside the editor. Because a workspace recompile re-scans the
-- project from disk, most events only need to schedule one; the extra work here is cache hygiene
-- (@katari.toml@ appearing / disappearing changes which project a file belongs to) and clearing
-- markers pinned to deleted files.
watchedFilesHandler ::
  ServerState ->
  LSP.TNotificationMessage LSP.Method_WorkspaceDidChangeWatchedFiles ->
  LSP.LspM () ()
watchedFilesHandler state message = do
  let changes = message ^. L.params . L.changes
  mapM_ (handleOne state) changes

handleOne :: ServerState -> LSP.FileEvent -> LSP.LspM () ()
handleOne state (LSP.FileEvent uri changeType) =
  for_ (LSP.uriToFilePath uri) $ \path ->
    if takeFileName path == Project.configFilename
      then do
        -- Which project every known file belongs to may have changed wholesale; the cache is small
        -- and this event is rare, so drop all of it rather than track affected subtrees.
        let root = takeDirectory path
        liftIO $ atomically $ do
          modifyTVar' state.projectRootCache (const Map.empty)
          case changeType of
            LSP.FileChangeType_Deleted -> modifyTVar' state.workspaces (Map.delete root)
            _ -> pure ()
        scheduleRecompile state path
      else case changeType of
        LSP.FileChangeType_Deleted -> do
          -- Clear the markers pinned to the deleted file, then let the fresh scan drop its module.
          publishFor uri []
          scheduleRecompile state path
        LSP.FileChangeType_Created -> scheduleRecompile state path
        LSP.FileChangeType_Changed -> scheduleRecompile state path
