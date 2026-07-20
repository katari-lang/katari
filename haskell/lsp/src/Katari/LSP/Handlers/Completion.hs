-- | @textDocument/completion@ handler.
--
-- Three dispatch modes, all driven by inspecting the source text around the cursor (see
-- "Katari.LSP.CompletionContext" for why text, not the AST):
--
--   1. Text before the cursor matches @<path>.@ or @<path>.<partial>@: member completion. The
--      dotted path resolves to a module (list its exports and submodules) or to a typed value
--      (list its object fields).
--   2. The cursor sits inside a not-yet-closed @(@ of the enclosing declaration's text — calls
--      span lines routinely — whose preceding token is an identifier: list that callable's
--      parameter labels, excluding labels already used in the current call. Accepting one inserts
--      @label = @.
--   3. Otherwise: general expression completion — everything visible in scope at the position.
--
-- The LSP client applies the prefix filter on the returned items, so the server returns the full
-- candidate set for each mode.
module Katari.LSP.Handlers.Completion
  ( completionHandler,
  )
where

import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import GHC.List (List)
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.SourceSpan qualified as K
import Katari.LSP.CompletionContext (declarationPrefix, detectLabelContext, detectMemberPrefix)
import Katari.LSP.Convert (lspPositionToKatari)
import Katari.LSP.State (CompileArtifacts (..), FileContext (..), ServerState, lookupFileContext)
import Katari.Query qualified as Query
import Katari.Query.Completion qualified as Completion
import Language.LSP.Protocol.Lens qualified as L
import Language.LSP.Protocol.Message qualified as LSP
import Language.LSP.Protocol.Types qualified as LSP
import Language.LSP.Server qualified as LSP

completionHandler :: ServerState -> LSP.Handlers (LSP.LspM ())
completionHandler state =
  LSP.requestHandler LSP.SMethod_TextDocumentCompletion $ \message responder -> do
    let uri = message ^. L.params . L.textDocument . L.uri
        position = message ^. L.params . L.position
    case LSP.uriToFilePath uri of
      Nothing -> responder (Right (LSP.InR (LSP.InR LSP.Null)))
      Just path -> do
        maybeContext <- liftIO (lookupFileContext state path)
        case maybeContext of
          Nothing -> responder (Right (LSP.InR (LSP.InR LSP.Null)))
          Just context -> do
            let katariPosition = lspPositionToKatari context.lineVector position
                linePrefix = currentLinePrefix context.lineVector position
                callPrefix =
                  declarationPrefix
                    context.lineVector
                    (fromIntegral (position ^. L.line))
                    (fromIntegral (position ^. L.character))
                items = dispatch context.artifacts.snapshot context.moduleName katariPosition linePrefix callPrefix
            responder (Right (LSP.InL (toLspItem <$> items)))

---------------------------------------------------------------------------------------------------
-- Dispatch
---------------------------------------------------------------------------------------------------

-- | @linePrefix@ is the current line up to the cursor (a member path never spans lines);
-- @callPrefix@ is the enclosing declaration's text up to the cursor (a call's open paren often
-- sits lines above).
dispatch :: Query.QuerySnapshot -> ModuleName -> K.Position -> Text -> Text -> List Completion.CompletionItem
dispatch snapshot moduleName position linePrefix callPrefix = fromMaybe fallback specialised
  where
    fallback = Completion.completionsAt snapshot moduleName position

    specialised = memberCompletion <> labelCompletion

    memberCompletion = do
      dottedPath <- detectMemberPrefix linePrefix
      anchor <- Completion.resolveDottedPath snapshot moduleName position dottedPath
      Just $ case anchor of
        Completion.AnchorModule referencedModule -> Completion.completionsOfModule snapshot referencedModule
        Completion.AnchorTyped semanticType -> Completion.completionsOfFields semanticType

    labelCompletion = do
      (callablePath, usedLabels) <- detectLabelContext callPrefix
      anchor <- Completion.resolveDottedPath snapshot moduleName position callablePath
      case anchor of
        Completion.AnchorTyped semanticType ->
          Just (Completion.completionsOfCallLabels semanticType usedLabels)
        Completion.AnchorModule _ -> Nothing

-- | The line text at an LSP position, up to the cursor column.
currentLinePrefix :: Vector Text -> LSP.Position -> Text
currentLinePrefix lineVector (LSP.Position lspLine lspCharacter) =
  Text.take (fromIntegral lspCharacter) (fromMaybe "" (lineVector Vector.!? fromIntegral lspLine))

---------------------------------------------------------------------------------------------------
-- LSP item construction
---------------------------------------------------------------------------------------------------

toLspItem :: Completion.CompletionItem -> LSP.CompletionItem
toLspItem item =
  LSP.CompletionItem
    { LSP._label = item.label,
      LSP._labelDetails = Nothing,
      LSP._kind = Just (mapKind item.kind),
      LSP._tags = Nothing,
      LSP._detail = item.detail,
      LSP._documentation = fmap (LSP.InL :: Text -> Text LSP.|? LSP.MarkupContent) item.documentation,
      LSP._deprecated = Nothing,
      LSP._preselect = Nothing,
      LSP._sortText = Nothing,
      LSP._filterText = Nothing,
      LSP._insertText = item.insertText,
      LSP._insertTextFormat = Nothing,
      LSP._insertTextMode = Nothing,
      LSP._textEdit = Nothing,
      LSP._textEditText = Nothing,
      LSP._additionalTextEdits = Nothing,
      LSP._commitCharacters = Nothing,
      LSP._command = Nothing,
      LSP._data_ = Nothing
    }

mapKind :: Completion.CompletionKind -> LSP.CompletionItemKind
mapKind = \case
  Completion.CompletionKindLocalVariable -> LSP.CompletionItemKind_Variable
  Completion.CompletionKindAgent -> LSP.CompletionItemKind_Function
  Completion.CompletionKindRequest -> LSP.CompletionItemKind_Event
  Completion.CompletionKindConstructor -> LSP.CompletionItemKind_Constructor
  Completion.CompletionKindTypeName -> LSP.CompletionItemKind_Class
  Completion.CompletionKindModule -> LSP.CompletionItemKind_Module
  Completion.CompletionKindField -> LSP.CompletionItemKind_Field
