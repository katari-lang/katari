-- | @textDocument/definition@ handler: the defining occurrence of the symbol at the cursor, via
-- 'Query.definitionAt'. Cross-module definitions convert through the compile's span context, which
-- maps every compiled module (including dependency packages) back to its real file.
module Katari.LSP.Handlers.Definition
  ( definitionHandler,
  )
where

import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import Katari.LSP.Convert (lspPositionToKatari, spanToLocation)
import Katari.LSP.State (CompileArtifacts (..), FileContext (..), ServerState, lookupFileContext)
import Katari.Query qualified as Query
import Language.LSP.Protocol.Lens qualified as L
import Language.LSP.Protocol.Message qualified as LSP
import Language.LSP.Protocol.Types qualified as LSP
import Language.LSP.Server qualified as LSP

definitionHandler :: ServerState -> LSP.Handlers (LSP.LspM ())
definitionHandler state =
  LSP.requestHandler LSP.SMethod_TextDocumentDefinition $ \message responder -> do
    let uri = message ^. L.params . L.textDocument . L.uri
        position = message ^. L.params . L.position
        none = responder (Right (LSP.InR (LSP.InR LSP.Null)))
    case LSP.uriToFilePath uri of
      Nothing -> none
      Just path -> do
        maybeContext <- liftIO (lookupFileContext state path)
        case maybeContext of
          Nothing -> none
          Just context -> do
            let katariPosition = lspPositionToKatari context.lineVector position
                location = do
                  definitionSpan <-
                    Query.definitionAt context.artifacts.snapshot context.moduleName katariPosition
                  spanToLocation context.artifacts.spanContext definitionSpan
            case location of
              Nothing -> none
              Just found -> responder (Right (LSP.InL (LSP.Definition (LSP.InL found))))
