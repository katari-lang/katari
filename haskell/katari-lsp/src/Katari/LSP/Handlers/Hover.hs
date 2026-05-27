-- | @textDocument/hover@ handler.
--
-- Delegates the heavy lifting to 'Katari.Query.lookupAtPosition' and
-- formats the resulting 'HoverInfo' as a Markdown @MarkupContent@
-- block: a code-fenced rendering of the inferred type, followed by
-- the qualified name on a second line when present.
module Katari.LSP.Handlers.Hover
  ( hoverHandler,
  )
where

import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Katari.Compile (CompileResult (..))
import Katari.LSP.Convert (lspPositionToKatari)
import Katari.LSP.State (ServerState, lookupCompileResult)
import Katari.Query qualified as Query
import Katari.SemanticType.Render (renderSemanticType)
import Katari.SourceSpan (Position (..), SourceSpan (..))
import Language.LSP.Protocol.Lens qualified as L
import Language.LSP.Protocol.Message qualified as LSP
import Language.LSP.Protocol.Types qualified as LSP
import Language.LSP.Server qualified as LSP

hoverHandler :: ServerState -> LSP.Handlers (LSP.LspM ())
hoverHandler st =
  LSP.requestHandler LSP.SMethod_TextDocumentHover $ \msg responder -> do
    let uri = msg ^. L.params . L.textDocument . L.uri
        pos = msg ^. L.params . L.position
    case LSP.uriToFilePath uri of
      Nothing -> responder (Right (LSP.InR LSP.Null))
      Just path -> do
        mResult <- liftIO (lookupCompileResult st path)
        case mResult of
          Nothing -> responder (Right (LSP.InR LSP.Null))
          Just (txt, lineVec, result) -> do
            let kPos = lspPositionToKatari txt pos
                info = Query.lookupAtPosition result.identifierResult result.zonkResult path kPos
            case info of
              Nothing -> responder (Right (LSP.InR LSP.Null))
              Just h -> responder (Right (LSP.InL (mkHover lineVec h)))

mkHover :: Vector Text -> Query.HoverInfo -> LSP.Hover
mkHover lineVec h =
  LSP.Hover
    { LSP._contents = LSP.InL (markup (renderHover lineVec h)),
      LSP._range = Nothing
    }
  where
    markup t = LSP.MarkupContent LSP.MarkupKind_Markdown t

-- | Render a hover as a fenced @katari@ Markdown block of the form
-- @snippet : type@, followed by the qualified name (when present) on a
-- second line. The @snippet@ is the source-text slice for the
-- @hoverNameSpan@ — i.e. exactly what the user is hovering on
-- (variable name, parameter, literal, or whole expression).
renderHover :: Vector Text -> Query.HoverInfo -> Text
renderHover lineVec h =
  let snippet = sliceSpan lineVec h.hoverNameSpan
      typeText = case h.hoverType of
        Nothing -> ""
        Just t -> renderSemanticType t
      headerLine =
        if Text.null typeText
          then snippet
          else snippet <> " : " <> typeText
      block =
        if Text.null headerLine
          then ""
          else "```katari\n" <> headerLine <> "\n```"
      qnameLine = case h.hoverQualifiedName of
        Nothing -> ""
        Just qn -> "\n**" <> qn <> "**"
   in Text.strip (block <> qnameLine)

-- | Extract the text between @span.start@ and @span.end@ from the
-- pre-split line vector. Positions are 1-indexed (line, column) and
-- inclusive on both ends. Multi-line snippets are joined with @\\n@.
-- Uses 'Vector' indexing so each line lookup is O(1).
sliceSpan :: Vector Text -> SourceSpan -> Text
sliceSpan lineVec span_ =
  let ls = lineVec
      startL = span_.start.line - 1
      endL = span_.end.line - 1
      startC = span_.start.column - 1
      endC = span_.end.column - 1
   in case (ls Vector.!? startL, ls Vector.!? endL) of
        (Just s, Just e)
          | startL == endL ->
              Text.take (endC - startC) (Text.drop startC s)
          | otherwise ->
              let middle = Vector.toList (Vector.slice (startL + 1) (endL - startL - 1) ls)
                  firstLine = Text.drop startC s
                  lastLine = Text.take endC e
               in Text.intercalate "\n" (firstLine : middle <> [lastLine])
        _ -> ""
