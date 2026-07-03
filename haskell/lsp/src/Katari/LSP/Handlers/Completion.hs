-- | @textDocument/completion@ handler.
--
-- Three dispatch modes, all driven by inspecting the current line's text up to the cursor:
--
--   1. Text immediately before the cursor matches @<ident>.@: member completion. The dotted path
--      resolves to a module alias (list its exports) or to a typed value (list its object fields).
--   2. The cursor sits inside a not-yet-closed @(@ whose preceding token is an identifier: list
--      that callable's parameter labels, excluding labels already used in the current call.
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
import Data.Char (isAlphaNum)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import GHC.List (List)
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.SourceSpan qualified as K
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
                lineText = currentLine context.lineVector position
                prefix = Text.take (fromIntegral (position ^. L.character)) lineText
                items = dispatch context.artifacts.snapshot context.moduleName katariPosition prefix
            responder (Right (LSP.InL (toLspItem <$> items)))

---------------------------------------------------------------------------------------------------
-- Dispatch
---------------------------------------------------------------------------------------------------

dispatch :: Query.QuerySnapshot -> ModuleName -> K.Position -> Text -> List Completion.CompletionItem
dispatch snapshot moduleName position prefix = fromMaybe fallback specialised
  where
    fallback = Completion.completionsAt snapshot moduleName position

    specialised = memberCompletion <> labelCompletion

    memberCompletion = do
      dottedPath <- detectMemberPrefix prefix
      anchor <- Completion.resolveDottedPath snapshot moduleName position dottedPath
      Just $ case anchor of
        Completion.AnchorModule referencedModule -> Completion.completionsOfModule snapshot referencedModule
        Completion.AnchorTyped semanticType -> Completion.completionsOfFields semanticType

    labelCompletion = do
      (callablePath, usedLabels) <- detectLabelContext prefix
      anchor <- Completion.resolveDottedPath snapshot moduleName position callablePath
      case anchor of
        Completion.AnchorTyped semanticType ->
          Just (Completion.completionsOfCallLabels semanticType usedLabels)
        Completion.AnchorModule _ -> Nothing

---------------------------------------------------------------------------------------------------
-- Line-text context detection
---------------------------------------------------------------------------------------------------

-- | If the text ends with a @.@, the dotted path of identifiers immediately preceding it (supports
-- nested paths like @foo.bar.baz.@). 'Nothing' when the character before the @.@ is not part of an
-- identifier, so @"abc".@ or @42.@ do not trigger member completion.
detectMemberPrefix :: Text -> Maybe Text
detectMemberPrefix text = case Text.unsnoc text of
  Just (rest, '.') ->
    let pathPart = Text.takeWhileEnd isPathCharacter rest
     in if Text.null pathPart || Text.last pathPart == '.'
          then Nothing
          else Just pathPart
  _ -> Nothing
  where
    isPathCharacter character = isIdentifierCharacter character || character == '.'

-- | If the cursor sits inside an open @(@ whose preceding token is an identifier (dotted callables
-- like @mod.func(@ included), that callable path and the set of labels already used in the current
-- call. The scan walks backwards tracking paren depth; the first unmatched @(@ marks the call.
detectLabelContext :: Text -> Maybe (Text, Set Text)
detectLabelContext text = do
  openIndex <- findOuterOpenParen text
  let beforeParen = Text.take openIndex text
      inside = Text.drop (openIndex + 1) text
      raw = Text.takeWhileEnd isPathCharacter (Text.stripEnd beforeParen)
      callable = dropTrailingDot raw
  if Text.null callable
    then Nothing
    else Just (callable, collectUsedLabels inside)
  where
    isPathCharacter character = isIdentifierCharacter character || character == '.'
    dropTrailingDot segment = case Text.unsnoc segment of
      Just (rest, '.') -> rest
      _ -> segment

-- | The index (in code points) of the first @(@ scanning right-to-left that has no matching @)@ to
-- its right within the text.
findOuterOpenParen :: Text -> Maybe Int
findOuterOpenParen text = walk (reverse (zip [0 ..] (Text.unpack text))) 0
  where
    walk :: List (Int, Char) -> Int -> Maybe Int
    walk [] _ = Nothing
    walk ((index, character) : rest) depth
      | character == ')' = walk rest (depth + 1)
      | character == '(' && depth == 0 = Just index
      | character == '(' = walk rest (depth - 1)
      | otherwise = walk rest depth

-- | The @<ident> =@ labels already written in a partial argument list (split on top-level commas,
-- ignoring commas nested in parens / brackets / braces).
collectUsedLabels :: Text -> Set Text
collectUsedLabels inside =
  Set.fromList (concatMap labelOfSegment (splitTopLevel inside ','))
  where
    labelOfSegment segment =
      case Text.breakOn "=" segment of
        (_, equalsAndRest) | Text.null equalsAndRest -> []
        (leftHandSide, _) ->
          let trimmed = Text.strip leftHandSide
              identifier = Text.takeWhile isIdentifierCharacter trimmed
           in ([identifier | not (Text.null identifier || identifier /= trimmed)])

splitTopLevel :: Text -> Char -> List Text
splitTopLevel text separator = walk (Text.unpack text) [] [] (0 :: Int)
  where
    walk [] current accumulated _ =
      reverse (Text.pack (reverse current) : map Text.pack (reverse accumulated))
    walk (character : rest) current accumulated depth
      | character == separator && depth == 0 = walk rest [] (reverse current : accumulated) depth
      | character == '(' || character == '[' || character == '{' =
          walk rest (character : current) accumulated (depth + 1)
      | character == ')' || character == ']' || character == '}' =
          walk rest (character : current) accumulated (max 0 (depth - 1))
      | otherwise = walk rest (character : current) accumulated depth

isIdentifierCharacter :: Char -> Bool
isIdentifierCharacter character = isAlphaNum character || character == '_'

-- | The line text at an LSP position (0-indexed line), from the pre-split line vector.
currentLine :: Vector Text -> LSP.Position -> Text
currentLine lineVector (LSP.Position lspLine _) =
  fromMaybe "" (lineVector Vector.!? fromIntegral lspLine)

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
      LSP._insertText = Nothing,
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
