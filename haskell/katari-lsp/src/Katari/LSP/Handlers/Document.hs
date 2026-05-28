-- | Document lifecycle handlers: @didOpen@ / @didChange@ / @didClose@.
--
-- Each one updates the merged virtual file map, schedules a debounced
-- recompile (150 ms), and republishes diagnostics for the changed
-- workspace.
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
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Compile qualified as Compile
import Katari.Diagnostic (Diagnostic (..), Severity (..))
import Katari.LSP.Convert (katariSpanToLspRange)
import Katari.LSP.State
  ( RecompileTarget (..),
    ServerState (..),
    WorkspaceState (..),
    findProjectRootCached,
    snapshotWorkspaceSources,
    textToLineVector,
    wsFileTexts,
  )
import Katari.Project.Config qualified as Project
import Katari.Project.Discovery qualified as Project
import Katari.Project.Resolve qualified as Project
import Katari.Query (buildOccurrenceIndex)
import Katari.Query qualified as Query
import Katari.SourceSpan (SourceSpan (..))
import Language.LSP.Protocol.Lens qualified as L
import Language.LSP.Protocol.Message qualified as LSP
import Language.LSP.Protocol.Types qualified as LSP
import Language.LSP.Server qualified as LSP
import Language.LSP.VFS qualified as VFS
import System.FilePath (dropExtension, takeDirectory, takeFileName, (</>))
import System.IO qualified

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

documentHandlers :: ServerState -> LSP.Handlers (LSP.LspM ())
documentHandlers st =
  mconcat
    [ LSP.notificationHandler LSP.SMethod_TextDocumentDidOpen $ \msg -> do
        let uri = msg ^. L.params . L.textDocument . L.uri
            txt = msg ^. L.params . L.textDocument . L.text
        case LSP.uriToFilePath uri of
          Nothing -> pure ()
          Just path -> liftIO (onOpen st path txt) >> scheduleRecompile st path,
      LSP.notificationHandler LSP.SMethod_TextDocumentDidChange $ \msg -> do
        let uri = msg ^. L.params . L.textDocument . L.uri
        mvfs <- LSP.getVirtualFile (LSP.toNormalizedUri uri)
        case (LSP.uriToFilePath uri, mvfs) of
          (Just path, Just vfs) -> do
            let txt = VFS.virtualFileText vfs
            liftIO (onChange st path txt) >> scheduleRecompile st path
          _ -> pure (),
      LSP.notificationHandler LSP.SMethod_TextDocumentDidClose $ \msg -> do
        let uri = msg ^. L.params . L.textDocument . L.uri
        case LSP.uriToFilePath uri of
          Nothing -> pure ()
          Just path -> liftIO (onClose st path) >> scheduleRecompile st path
    ]

-- ---------------------------------------------------------------------------
-- State updates
-- ---------------------------------------------------------------------------

-- | Locate the workspace for @path@, attaching it to the server state if
-- this is the first time we've seen its project root. If @path@ is
-- outside any project, fall through to the orphan-files bucket.
onOpen :: ServerState -> FilePath -> Text -> IO ()
onOpen st path txt = do
  mRoot <- findProjectRootCached st path
  case mRoot of
    Nothing ->
      atomically $ modifyTVar' st.orphanFiles (Map.insert path txt)
    Just root -> do
      ensureWorkspaceLoaded st root
      atomically $ modifyTVar' st.workspaces $ \wsMap ->
        Map.adjust
          ( \ws ->
              ws
                { wsFiles = Map.insert path txt ws.wsFiles,
                  wsLineCache = Map.insert path (textToLineVector txt) ws.wsLineCache,
                  wsOpenFiles = Set.insert path ws.wsOpenFiles
                }
          )
          root
          wsMap

onChange :: ServerState -> FilePath -> Text -> IO ()
onChange st path txt = do
  mRoot <- findProjectRootCached st path
  case mRoot of
    Nothing ->
      atomically $ modifyTVar' st.orphanFiles (Map.insert path txt)
    Just root ->
      atomically $ modifyTVar' st.workspaces $ \wsMap ->
        Map.adjust
          ( \ws ->
              ws
                { wsFiles = Map.insert path txt ws.wsFiles,
                  wsLineCache = Map.insert path (textToLineVector txt) ws.wsLineCache
                }
          )
          root
          wsMap

onClose :: ServerState -> FilePath -> IO ()
onClose st path = do
  mRoot <- findProjectRootCached st path
  case mRoot of
    Nothing ->
      atomically $ modifyTVar' st.orphanFiles (Map.delete path)
    Just root -> do
      -- Drop the open-files marker AND the in-memory buffer so the
      -- next recompile falls back to the on-disk content rather than
      -- serving stale editor text.
      atomically $ modifyTVar' st.workspaces $ \wsMap ->
        Map.adjust
          ( \ws ->
              ws
                { wsOpenFiles = Set.delete path ws.wsOpenFiles,
                  wsFiles = Map.delete path ws.wsFiles,
                  wsLineCache = Map.delete path ws.wsLineCache
                }
          )
          root
          wsMap

-- | Workspace-load failures (broken katari.toml, bad dep paths)
-- previously dropped silently — the user would just see "no
-- intellisense" with no signal. Surface them via stderr so the
-- VSCode "Output > Katari Language Server" panel shows the cause.
warn :: String -> IO ()
warn = System.IO.hPutStrLn System.IO.stderr . ("katari-lsp warning: " <>)

-- | Load the workspace at @root@ if not already present. Parses
-- @katari.toml@, resolves the transitive path-dep graph, and reads
-- every package's @.ktr@ files in one go.
ensureWorkspaceLoaded :: ServerState -> FilePath -> IO ()
ensureWorkspaceLoaded st root = do
  existing <- readTVarIO st.workspaces
  case Map.lookup root existing of
    Just _ -> pure ()
    Nothing -> do
      cfgRes <- Project.loadKatariToml (root </> Project.configFilename)
      case cfgRes of
        Left e -> warn ("katari.toml at " <> root <> ": " <> show e)
        Right cfg -> do
          resolveRes <- Project.loadResolvedProject root
          case resolveRes of
            Left e ->
              warn ("katari-lsp: resolve failed at " <> root <> ": " <> Text.unpack (Project.renderResolveError e))
            Right resolved -> case Project.assembleProject resolved of
              Left e ->
                warn ("katari-lsp: assemble failed at " <> root <> ": " <> Text.unpack (Project.renderResolveError e))
              Right assembly -> do
                let moduleByPath =
                      Map.fromList
                        [ (entry.sourcePath, modName)
                          | (modName, entry) <- Map.toList assembly.sources
                        ]
                    ws =
                      WorkspaceState
                        { wsRoot = root,
                          wsConfig = cfg,
                          wsAssembly = assembly,
                          wsModuleByPath = moduleByPath,
                          wsFiles = Map.empty,
                          wsLineCache = Map.empty,
                          wsOpenFiles = Set.empty,
                          wsLastResult = Nothing,
                          wsOccIndex = Nothing,
                          wsCompileCache = Map.empty
                        }
                atomically $ modifyTVar' st.workspaces (Map.insert root ws)

-- ---------------------------------------------------------------------------
-- Debounced recompile
-- ---------------------------------------------------------------------------

-- Debounce interval in microseconds (150 ms).
debounceUs :: Int
debounceUs = 150_000

scheduleRecompile :: ServerState -> FilePath -> LSP.LspM () ()
scheduleRecompile st path = do
  mRoot <- liftIO (findProjectRootCached st path)
  -- Workspace files share the workspace's root as the debounce key so
  -- a flurry of edits across the same project collapses into one
  -- recompile. Orphan files use the file path itself; otherwise two
  -- orphans being edited alternately would steal the timer from each
  -- other and one would never get a recompile to fire.
  let target = case mRoot of
        Just root -> RecompileWorkspace root
        Nothing -> RecompileOrphan path
  env <- LSP.getLspEnv
  liftIO $ do
    prevTimer <- atomically $ do
      timers <- readTVar st.debounceTimers
      pure (Map.lookup target timers)
    case prevTimer of
      Just tid -> killThread tid
      Nothing -> pure ()
    newTid <- forkIO $ do
      threadDelay debounceUs
      LSP.runLspT env (recompileNow st target)
    atomically $ modifyTVar' st.debounceTimers (Map.insert target newTid)

-- | Compile the requested target and publish diagnostics. Dispatch is
-- exhaustive at the type level (= 'RecompileTarget' has two
-- constructors), unlike the previous stringly-typed prefix-match shape.
recompileNow :: ServerState -> RecompileTarget -> LSP.LspM () ()
recompileNow st = \case
  RecompileWorkspace root -> recompileWorkspace st root
  RecompileOrphan path -> recompileOrphan st path

recompileWorkspace :: ServerState -> FilePath -> LSP.LspM () ()
recompileWorkspace st root = do
  mWs <- liftIO (atomically (Map.lookup root <$> readTVar st.workspaces))
  case mWs of
    Nothing -> pure ()
    Just ws -> do
      let input = snapshotWorkspaceSources ws
      result <- liftIO $ Compile.compile (\_ -> pure ()) input
      let
          fileTexts = wsFileTexts ws
      liftIO $
        atomically $
          modifyTVar' st.workspaces $
            Map.adjust
              ( \w ->
                  w
                    { wsLastResult = Just result,
                      wsOccIndex =
                        Just (buildOccurrenceIndex (Query.buildQuerySnapshot result.identifierResult result.zonkResult)),
                      wsCompileCache = result.updatedCache
                    }
              )
              root
      publishWorkspaceDiagnostics fileTexts result.diagnostics

recompileOrphan :: ServerState -> FilePath -> LSP.LspM () ()
recompileOrphan st path = do
  files <- liftIO (readTVarIO st.orphanFiles)
  case Map.lookup path files of
    Just txt -> compileOneOrphan st path txt
    Nothing -> pure ()

compileOneOrphan :: ServerState -> FilePath -> Text -> LSP.LspM () ()
compileOneOrphan _st path txt = do
  let entry = Compile.SourceEntry {Compile.filePath = path, Compile.sourceText = txt}
      sources = Map.singleton (singletonModuleName path) entry
  result <- liftIO $ Compile.compile (\_ -> pure ()) (Compile.CompileInput {Compile.sources = sources, Compile.cache = Map.empty})
  publishWorkspaceDiagnostics (Map.singleton path txt) result.diagnostics
  where
    -- Strip the trailing @.ktr@ extension and treat the basename as the
    -- module name. The orphan bucket cannot use directory-based module
    -- naming because there's no project root to relativise against.
    singletonModuleName :: FilePath -> Text
    singletonModuleName = Text.pack . dropExtension . takeFileName

-- ---------------------------------------------------------------------------
-- Diagnostics publishing
-- ---------------------------------------------------------------------------

publishWorkspaceDiagnostics :: Map FilePath Text -> [Diagnostic] -> LSP.LspM () ()
publishWorkspaceDiagnostics fileTexts diags = do
  let grouped =
        Map.fromListWith
          (<>)
          [(d.span.filePath, [d]) | d <- diags, d.severity /= SeverityHint]
      -- Always emit an entry for every file we know about so the editor
      -- clears stale diagnostics when problems disappear.
      allFiles = Map.union grouped (Map.map (const []) fileTexts)
  mapM_ (uncurry (publishForFile fileTexts)) (Map.toList allFiles)

publishForFile :: Map FilePath Text -> FilePath -> [Diagnostic] -> LSP.LspM () ()
publishForFile fileTexts path ds = do
  let lsps = map (diagnosticToLsp fileTexts) ds
      uri = LSP.filePathToUri path
  LSP.sendNotification LSP.SMethod_TextDocumentPublishDiagnostics $
    LSP.PublishDiagnosticsParams uri Nothing lsps

diagnosticToLsp :: Map FilePath Text -> Diagnostic -> LSP.Diagnostic
diagnosticToLsp fileTexts d =
  LSP.Diagnostic
    { LSP._range = katariSpanToLspRange fileTexts d.span,
      LSP._severity = Just (mapSeverity d.severity),
      LSP._code = Just (LSP.InR d.code),
      LSP._codeDescription = Nothing,
      LSP._source = Just "katari",
      LSP._message = d.message,
      LSP._tags = Nothing,
      LSP._relatedInformation = Nothing,
      LSP._data_ = Nothing
    }

mapSeverity :: Severity -> LSP.DiagnosticSeverity
mapSeverity = \case
  SeverityError -> LSP.DiagnosticSeverity_Error
  SeverityWarning -> LSP.DiagnosticSeverity_Warning
  SeverityInfo -> LSP.DiagnosticSeverity_Information
  SeverityHint -> LSP.DiagnosticSeverity_Hint

-- ---------------------------------------------------------------------------
-- Watched-files (= disk-side .ktr create / delete / external rename)
-- ---------------------------------------------------------------------------

-- | Handle @workspace/didChangeWatchedFiles@. The dynamic-watch
-- registration (set in 'Katari.LSP.Server' once the client confirms
-- support) targets @**/*.ktr@; here we react to disk changes the user
-- made outside the editor.
--
-- The minimum we need is: when a @.ktr@ file is deleted on disk,
-- clear any diagnostics still pinned to it in the editor (otherwise
-- the marker hangs around until restart) and schedule a workspace
-- recompile so the in-memory assembly drops the gone module. Create /
-- change events also trigger a recompile so a freshly written file
-- shows up without the user having to open it.
watchedFilesHandler ::
  ServerState ->
  LSP.TNotificationMessage LSP.Method_WorkspaceDidChangeWatchedFiles ->
  LSP.LspM () ()
watchedFilesHandler st msg = do
  let changes = msg ^. L.params . L.changes
  mapM_ (handleOne st) changes

handleOne ::
  ServerState ->
  LSP.FileEvent ->
  LSP.LspM () ()
handleOne st (LSP.FileEvent uri changeType) =
  case LSP.uriToFilePath uri of
    Nothing -> pure ()
    Just path
      -- When katari.toml is created, changed, or deleted, evict the
      -- workspace entry so that 'ensureWorkspaceLoaded' re-reads it
      -- on the next operation. Also invalidate the project-root cache
      -- so files previously classified as "orphan" (or belonging to
      -- the old workspace shape) get a fresh lookup.
      | takeFileName path == Project.configFilename -> do
          let root = takeDirectory path
          liftIO $ atomically $ do
            modifyTVar' st.workspaces (Map.delete root)
            modifyTVar' st.projectRootCache (Map.delete root)
          -- Re-load the workspace eagerly (if the toml still exists)
          -- and trigger a full recompile so diagnostics update.
          case changeType of
            LSP.FileChangeType_Deleted -> do
              LSP.sendNotification LSP.SMethod_TextDocumentPublishDiagnostics $
                LSP.PublishDiagnosticsParams uri Nothing []
            _ -> liftIO $ ensureWorkspaceLoaded st root
          -- Pick an arbitrary .ktr path inside this workspace so
          -- scheduleRecompile routes to RecompileWorkspace root.
          -- If no .ktr files are tracked yet, use the toml path
          -- itself (scheduleRecompile will classify it as orphan,
          -- which is harmless — the real recompile comes from open
          -- files triggering ensureWorkspaceLoaded later).
          scheduleRecompile st path
      | otherwise -> case changeType of
          LSP.FileChangeType_Deleted -> do
            -- Clear the published diagnostics for this file so the editor
            -- drops its markers; then recompile the enclosing workspace
            -- so the next compile picks up the now-missing module.
            LSP.sendNotification LSP.SMethod_TextDocumentPublishDiagnostics $
              LSP.PublishDiagnosticsParams uri Nothing []
            scheduleRecompile st path
          LSP.FileChangeType_Created -> scheduleRecompile st path
          LSP.FileChangeType_Changed -> scheduleRecompile st path
