-- | @textDocument/references@ handler. Uses the cached
-- 'Katari.Query.OccurrenceIndex' stored on the workspace state.
module Katari.LSP.Handlers.References
  ( referencesHandler,
  )
where

import Control.Concurrent.STM (readTVarIO)
import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map
import Katari.Compile (CompileResult (..))
import Katari.LSP.Convert (katariSpanToLspLocation, lspPositionToKatari)
import Katari.LSP.State (ServerState (..), WorkspaceState (..), lookupCompileResult)
import qualified Katari.Project.Discovery as Project
import qualified Katari.Query as Query
import qualified Language.LSP.Protocol.Lens as L
import qualified Language.LSP.Protocol.Message as LSP
import qualified Language.LSP.Protocol.Types as LSP
import qualified Language.LSP.Server as LSP

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
          (Just (txt, result), Just occ) -> do
            let kPos = lspPositionToKatari txt pos
                mRef =
                  Query.identifyAtPosition
                    result.identifierResult
                    result.zonkResult
                    path
                    kPos
            case mRef of
              Nothing -> responder (Right (LSP.InR LSP.Null))
              Just ref -> do
                let spans = Query.findReferences occ ref
                    locs = map (katariSpanToLspLocation (Map.singleton path txt)) spans
                responder (Right (LSP.InL locs))
          _ -> responder (Right (LSP.InR LSP.Null))

lookupOccIndex :: ServerState -> FilePath -> IO (Maybe Query.OccurrenceIndex)
lookupOccIndex st path = do
  mRoot <- Project.findProjectRoot path
  case mRoot of
    Just root -> do
      wsMap <- readTVarIO st.workspaces
      pure $ do
        ws <- Map.lookup root wsMap
        ws.wsOccIndex
    Nothing -> pure Nothing
