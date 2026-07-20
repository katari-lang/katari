-- | Entry point for the Katari LSP server. Constructs the 'ServerState' once at startup and
-- threads it through every per-method handler.
module Katari.LSP.Server
  ( runServer,
  )
where

import Control.Monad.IO.Class (liftIO)
import Katari.LSP.Handlers.Completion (completionHandler)
import Katari.LSP.Handlers.Definition (definitionHandler)
import Katari.LSP.Handlers.Document (documentHandlers, watchedFilesHandler)
import Katari.LSP.Handlers.Hover (hoverHandler)
import Katari.LSP.Handlers.References (referencesHandler)
import Katari.LSP.State (newServerState)
import Language.LSP.Protocol.Message qualified as LSP
import Language.LSP.Protocol.Types qualified as LSP
import Language.LSP.Server qualified as LSP

runServer :: IO Int
runServer = do
  state <- newServerState
  LSP.runServer $
    LSP.ServerDefinition
      { LSP.defaultConfig = (),
        LSP.parseConfig = \_ _ -> Right (),
        LSP.onConfigChange = \_ -> pure (),
        LSP.configSection = "katari",
        LSP.doInitialize = \environment _request -> pure (Right environment),
        LSP.staticHandlers = \_clientCapabilities ->
          mconcat
            [ documentHandlers state,
              hoverHandler state,
              definitionHandler state,
              referencesHandler state,
              completionHandler state,
              -- Silently absorb optional LSP lifecycle / trace notifications so the framework does
              -- not log them as "no handler". didSave needs no action of its own — didChange
              -- already schedules a debounced recompile on every keystroke.
              LSP.notificationHandler LSP.SMethod_Initialized $ \_ -> pure (),
              LSP.notificationHandler LSP.SMethod_SetTrace $ \_ -> pure (),
              LSP.notificationHandler LSP.SMethod_CancelRequest $ \_ -> pure (),
              LSP.notificationHandler LSP.SMethod_TextDocumentDidSave $ \_ -> pure (),
              LSP.notificationHandler LSP.SMethod_WorkspaceDidChangeWatchedFiles (watchedFilesHandler state)
            ],
        LSP.interpretHandler = \environment -> LSP.Iso (LSP.runLspT environment) liftIO,
        LSP.options =
          LSP.defaultOptions
            { LSP.optTextDocumentSync = Just textSyncOptions,
              -- Auto-trigger completion after `.` (member / field access), `(` (call-argument
              -- label) and `,` (the next argument's label); without these the client only requests
              -- completion on explicit invocation.
              LSP.optCompletionTriggerCharacters = Just ['.', '(', ',']
            }
      }
  where
    textSyncOptions :: LSP.TextDocumentSyncOptions
    textSyncOptions =
      LSP.TextDocumentSyncOptions
        { LSP._openClose = Just True,
          LSP._change = Just LSP.TextDocumentSyncKind_Incremental,
          LSP._willSave = Just False,
          LSP._willSaveWaitUntil = Just False,
          LSP._save = Just (LSP.InL True)
        }
