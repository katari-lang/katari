-- | @textDocument/definition@ handler.
--
-- Returns the source span of the definition for the symbol at the
-- cursor, via 'Katari.Query.findDefinition'.
module Katari.LSP.Handlers.Definition
  ( definitionHandler,
  )
where

import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import Katari.Compile (CompileResult (..))
import Katari.LSP.Convert (katariSpanToLspLocation, lspPositionToKatari)
import Katari.LSP.State (ServerState, lookupCompileResult, workspaceFileTexts)
import Katari.Query qualified as Query
import Language.LSP.Protocol.Lens qualified as L
import Language.LSP.Protocol.Message qualified as LSP
import Language.LSP.Protocol.Types qualified as LSP
import Language.LSP.Server qualified as LSP

definitionHandler :: ServerState -> LSP.Handlers (LSP.LspM ())
definitionHandler st =
  LSP.requestHandler LSP.SMethod_TextDocumentDefinition $ \msg responder -> do
    let uri = msg ^. L.params . L.textDocument . L.uri
        pos = msg ^. L.params . L.position
    case LSP.uriToFilePath uri of
      Nothing -> responder (Right (LSP.InR (LSP.InR LSP.Null)))
      Just path -> do
        mResult <- liftIO (lookupCompileResult st path)
        case mResult of
          Nothing -> responder (Right (LSP.InR (LSP.InR LSP.Null)))
          Just (txt, _lineVec, result) -> do
            let kPos = lspPositionToKatari txt pos
                snap = Query.buildQuerySnapshot result.identifierResult result.zonkResult
                mSpan = Query.findDefinition snap path kPos
            case mSpan of
              Nothing -> responder (Right (LSP.InR (LSP.InR LSP.Null)))
              Just span_ -> do
                -- definitions may land in other files (cross-module
                -- imports), so feed the converter the whole workspace
                -- text map rather than just the request's own file.
                fileTexts <- liftIO (workspaceFileTexts st path)
                let loc = katariSpanToLspLocation fileTexts span_
                -- Use the single-location Definition variant.
                responder
                  ( Right
                      (LSP.InL (LSP.Definition (LSP.InL loc)))
                  )
