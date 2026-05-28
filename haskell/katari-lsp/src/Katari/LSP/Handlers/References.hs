-- | @textDocument/references@ handler. Uses the cached
-- 'Katari.Query.OccurrenceIndex' stored on the workspace state.
module Katari.LSP.Handlers.References
  ( referencesHandler,
  )
where

import Control.Concurrent.STM (readTVarIO)
import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import Data.Map.Strict qualified as Map
import Katari.Compile (CompileResult (..))
import Katari.LSP.Convert (katariSpanToLspLocation, lspPositionToKatari)
import Katari.LSP.State
  ( ServerState (..),
    WorkspaceState (..),
    findProjectRootCached,
    lookupCompileResult,
    workspaceFileTexts,
  )
import Katari.Query qualified as Query
import Language.LSP.Protocol.Lens qualified as L
import Language.LSP.Protocol.Message qualified as LSP
import Language.LSP.Protocol.Types qualified as LSP
import Language.LSP.Server qualified as LSP

referencesHandler :: ServerState -> LSP.Handlers (LSP.LspM ())
referencesHandler st =
  LSP.requestHandler LSP.SMethod_TextDocumentReferences $ \msg responder -> do
    let uri = msg ^. L.params . L.textDocument . L.uri
        pos = msg ^. L.params . L.position
    case LSP.uriToFilePath uri of
      Nothing -> responder (Right (LSP.InR LSP.Null))
      Just path -> do
        mResult <- liftIO (lookupCompileResult st path)
        mWsOcc <- liftIO (lookupOccIndex st path)
        case (mResult, mWsOcc) of
          (Just (txt, _lineVec, result), Just occ) -> do
            let kPos = lspPositionToKatari txt pos
                mRef = Query.identifyAtPosition result.querySnapshot path kPos
            case mRef of
              Nothing -> responder (Right (LSP.InR LSP.Null))
              Just ref -> do
                -- references can span the whole workspace (cross-file
                -- imports, dep packages). Feed the full text map so
                -- UTF-16 conversion works for sibling-file spans.
                fileTexts <- liftIO (workspaceFileTexts st path)
                let spans = Query.findReferences occ ref
                    locs = map (katariSpanToLspLocation fileTexts) spans
                responder (Right (LSP.InL locs))
          _ -> responder (Right (LSP.InR LSP.Null))

lookupOccIndex :: ServerState -> FilePath -> IO (Maybe Query.OccurrenceIndex)
lookupOccIndex st path = do
  mRoot <- findProjectRootCached st path
  case mRoot of
    Just root -> do
      wsMap <- readTVarIO st.workspaces
      pure $ do
        ws <- Map.lookup root wsMap
        ws.wsOccIndex
    Nothing -> pure Nothing
