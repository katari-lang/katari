-- | @textDocument/references@ handler: every occurrence of the symbol at the cursor, across the
-- whole workspace, via the 'Query.OccurrenceIndex' cached on the compile artifacts. The defining
-- occurrence is included (it is a resolved reference like any use).
module Katari.LSP.Handlers.References
  ( referencesHandler,
  )
where

import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (mapMaybe)
import Katari.LSP.Convert (lspPositionToKatari, spanToLocation)
import Katari.LSP.State (CompileArtifacts (..), FileContext (..), ServerState, lookupFileContext)
import Katari.Query qualified as Query
import Language.LSP.Protocol.Lens qualified as L
import Language.LSP.Protocol.Message qualified as LSP
import Language.LSP.Protocol.Types qualified as LSP
import Language.LSP.Server qualified as LSP

referencesHandler :: ServerState -> LSP.Handlers (LSP.LspM ())
referencesHandler state =
  LSP.requestHandler LSP.SMethod_TextDocumentReferences $ \message responder -> do
    let uri = message ^. L.params . L.textDocument . L.uri
        position = message ^. L.params . L.position
    case LSP.uriToFilePath uri of
      Nothing -> responder (Right (LSP.InR LSP.Null))
      Just path -> do
        maybeContext <- liftIO (lookupFileContext state path)
        case maybeContext of
          Nothing -> responder (Right (LSP.InR LSP.Null))
          Just context -> do
            let katariPosition = lspPositionToKatari context.lineVector position
                occurrence =
                  Query.occurrenceAt context.artifacts.snapshot context.moduleName katariPosition
            case occurrence of
              Nothing -> responder (Right (LSP.InR LSP.Null))
              Just found -> do
                let spans = Query.findReferences context.artifacts.occurrenceIndex found.target
                    locations = mapMaybe (spanToLocation context.artifacts.spanContext) spans
                responder (Right (LSP.InL locations))
