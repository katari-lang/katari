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
import qualified Data.Text as Text
import Data.Text (Text)
import Katari.Compile (CompileResult (..))
import Katari.Id (QualifiedName (..))
import Katari.LSP.Convert (lspPositionToKatari)
import Katari.LSP.State (ServerState, lookupCompileResult)
import qualified Katari.Query as Query
import Katari.SemanticType.Render (renderSemanticType)
import Katari.SourceSpan (Position (..), SourceSpan (..))
import Katari.Typechecker.Identifier (IdentifierResult (..), RequestData (..), TypeData (..))
import qualified Language.LSP.Protocol.Lens as L
import qualified Language.LSP.Protocol.Message as LSP
import qualified Language.LSP.Protocol.Types as LSP
import qualified Language.LSP.Server as LSP

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
          Just (txt, result) -> do
            let kPos = lspPositionToKatari txt pos
                info = Query.lookupAtPosition result.identifierResult result.zonkResult path kPos
            case info of
              Nothing -> responder (Right (LSP.InR LSP.Null))
              Just h -> responder (Right (LSP.InL (mkHover result.identifierResult txt h)))

mkHover :: IdentifierResult -> Text -> Query.HoverInfo -> LSP.Hover
mkHover idResult fileText h =
  LSP.Hover
    { LSP._contents = LSP.InL (markup (renderHover idResult fileText h)),
      LSP._range = Nothing
    }
  where
    markup t = LSP.MarkupContent LSP.MarkupKind_Markdown t

-- | Render a hover as a fenced @katari@ Markdown block of the form
-- @snippet : type@, followed by the qualified name (when present) on a
-- second line. The @snippet@ is the source-text slice for the
-- @hoverNameSpan@ — i.e. exactly what the user is hovering on
-- (variable name, parameter, literal, or whole expression).
renderHover :: IdentifierResult -> Text -> Query.HoverInfo -> Text
renderHover idResult fileText h =
  let snippet = sliceSpan fileText h.hoverNameSpan
      typeText = case h.hoverType of
        Nothing -> ""
        Just t ->
          let typeNames = fmap (.typeQualifiedName.name) idResult.identifiedTypes
              reqNames = fmap (.requestQualifiedName.name) idResult.identifiedRequests
           in renderSemanticType typeNames reqNames t
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
-- whole-file content. Positions are 1-indexed (line, column) and
-- inclusive on both ends. Multi-line snippets are joined with @\\n@.
sliceSpan :: Text -> SourceSpan -> Text
sliceSpan fileText span_ =
  let ls = Text.lines fileText
      startL = span_.start.line - 1
      endL = span_.end.line - 1
      startC = span_.start.column - 1
      endC = span_.end.column - 1
   in case (atIndex startL ls, atIndex endL ls) of
        (Just s, Just e)
          | startL == endL ->
              Text.take (endC - startC) (Text.drop startC s)
          | otherwise ->
              let middle = drop (startL + 1) (take endL ls)
                  firstLine = Text.drop startC s
                  lastLine = Text.take endC e
               in Text.intercalate "\n" (firstLine : middle <> [lastLine])
        _ -> ""

atIndex :: Int -> [a] -> Maybe a
atIndex n _ | n < 0 = Nothing
atIndex 0 (x : _) = Just x
atIndex n (_ : xs) = atIndex (n - 1) xs
atIndex _ [] = Nothing
