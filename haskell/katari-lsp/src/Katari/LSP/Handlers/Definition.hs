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
import qualified Data.Map.Strict as Map
import Katari.Compile (CompileResult (..))
import Katari.LSP.Convert (katariSpanToLspLocation, lspPositionToKatari)
import Katari.LSP.State (ServerState, lookupCompileResult)
import qualified Katari.Query as Query
import qualified Language.LSP.Protocol.Lens as L
import qualified Language.LSP.Protocol.Message as LSP
import qualified Language.LSP.Protocol.Types as LSP
import qualified Language.LSP.Server as LSP

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
          Just (txt, result) -> do
            let kPos = lspPositionToKatari txt pos
                mSpan =
                  Query.findDefinition
                    result.identifierResult
                    result.zonkResult
                    path
                    kPos
            case mSpan of
              Nothing -> responder (Right (LSP.InR (LSP.InR LSP.Null)))
              Just span_ -> do
                let loc = katariSpanToLspLocation (Map.singleton path txt) span_
                -- Use the single-location Definition variant.
                responder
                  ( Right
                      (LSP.InL (LSP.Definition (LSP.InL loc)))
                  )
