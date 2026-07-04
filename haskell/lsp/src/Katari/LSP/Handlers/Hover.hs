-- | @textDocument/hover@ handler.
--
-- Delegates to 'Query.hoverAt' and formats the result as a Markdown block: a code-fenced
-- @snippet : type@ line (the snippet is the source slice of what the user is hovering on), followed
-- by the qualified name on a second line when the position sits on a top-level reference.
module Katari.LSP.Handlers.Hover
  ( hoverHandler,
  )
where

import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector (Vector)
import Katari.LSP.Convert (lspPositionToKatari, sliceSpan)
import Katari.LSP.State (CompileArtifacts (..), FileContext (..), ServerState, lookupFileContext)
import Katari.Query qualified as Query
import Language.LSP.Protocol.Lens qualified as L
import Language.LSP.Protocol.Message qualified as LSP
import Language.LSP.Protocol.Types qualified as LSP
import Language.LSP.Server qualified as LSP

hoverHandler :: ServerState -> LSP.Handlers (LSP.LspM ())
hoverHandler state =
  LSP.requestHandler LSP.SMethod_TextDocumentHover $ \message responder -> do
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
                info = Query.hoverAt context.artifacts.snapshot context.moduleName katariPosition
            case info of
              Nothing -> responder (Right (LSP.InR LSP.Null))
              Just hover -> responder (Right (LSP.InL (makeHover context.lineVector hover)))

makeHover :: Vector Text -> Query.HoverInfo -> LSP.Hover
makeHover lineVector hover =
  LSP.Hover
    { LSP._contents = LSP.InL (LSP.MarkupContent LSP.MarkupKind_Markdown (renderHover lineVector hover)),
      LSP._range = Nothing
    }

renderHover :: Vector Text -> Query.HoverInfo -> Text
renderHover lineVector hover =
  let snippet = sliceSpan lineVector hover.nameSpan
      typeText = maybe "" Query.renderHoverType hover.semanticType
      headerLine
        | Text.null typeText = snippet
        | otherwise = snippet <> " : " <> typeText
      block
        | Text.null headerLine = ""
        | otherwise = "```katari\n" <> headerLine <> "\n```"
      qualifiedNameLine = case hover.qualifiedName of
        Nothing -> ""
        Just qualifiedName -> "\n**" <> qualifiedName <> "**"
   in Text.strip (block <> qualifiedNameLine)
