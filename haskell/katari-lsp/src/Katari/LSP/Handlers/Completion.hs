-- | @textDocument/completion@ handler.
--
-- Three dispatch modes (all driven by inspecting the current line text
-- up to the cursor):
--
--   1. Text immediately before cursor matches @<ident>.@: try member
--      completion. If @<ident>@ resolves to a module alias, list the
--      aliased module's exports.
--   2. Cursor sits inside a not-yet-closed @(@ paren whose preceding
--      token is a callable identifier: list that callable's parameter
--      labels (excluding labels already used in the current call).
--   3. Otherwise: fall through to the general expression completion
--      (locals + module-visible top-level callables).
--
-- The LSP client applies the prefix filter on the returned items, so
-- the server returns the full candidate set for each mode.
module Katari.LSP.Handlers.Completion
  ( completionHandler,
  )
where

import Control.Lens ((^.))
import Control.Monad.IO.Class (liftIO)
import Data.Char (isAlphaNum)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Vector (Vector)
import qualified Data.Vector as Vector
import Katari.Compile (CompileResult (..))
import Katari.LSP.Convert (lspPositionToKatari)
import Katari.LSP.State (ServerState, lookupCompileResult)
import qualified Katari.Query.Completion as Comp
import qualified Katari.SourceSpan as K
import qualified Language.LSP.Protocol.Lens as L
import qualified Language.LSP.Protocol.Message as LSP
import qualified Language.LSP.Protocol.Types as LSP
import qualified Language.LSP.Server as LSP

completionHandler :: ServerState -> LSP.Handlers (LSP.LspM ())
completionHandler st =
  LSP.requestHandler LSP.SMethod_TextDocumentCompletion $ \msg responder -> do
    let uri = msg ^. L.params . L.textDocument . L.uri
        pos = msg ^. L.params . L.position
    case LSP.uriToFilePath uri of
      Nothing -> responder (Right (LSP.InR (LSP.InR LSP.Null)))
      Just path -> do
        mResult <- liftIO (lookupCompileResult st path)
        case mResult of
          Nothing -> responder (Right (LSP.InR (LSP.InR LSP.Null)))
          Just (txt, lineVec, result) -> do
            let kPos = lspPositionToKatari txt pos
                lineText = currentLine lineVec pos
                prefix = Text.take (fromIntegral (pos ^. L.character)) lineText
                items = dispatch result path kPos prefix
                lspItems = map toLspItem items
            responder (Right (LSP.InL lspItems))

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

-- | Pick the right completion source for the cursor's textual context.
dispatch ::
  CompileResult ->
  FilePath ->
  K.Position ->
  Text ->
  [Comp.CompletionItem]
dispatch result path kPos prefix = fromMaybe fallback specialised
  where
    fallback =
      Comp.completionsAt
        result.identifierResult
        result.zonkResult
        path
        kPos

    specialised = memberCompletion <> labelCompletion

    memberCompletion = do
      lhsPath <- detectMemberPrefix prefix
      anchor <-
        Comp.resolveDottedPath
          result.identifierResult
          result.zonkResult
          path
          kPos
          lhsPath
      Just $ case anchor of
        Comp.AnchorModule mid ->
          Comp.completionsOfModule
            result.identifierResult
            result.zonkResult
            mid
        Comp.AnchorTyped ty ->
          Comp.completionsOfFields
            result.identifierResult
            result.zonkResult
            ty

    labelCompletion = do
      (callablePath, usedLabels) <- detectLabelContext prefix
      anchor <-
        Comp.resolveDottedPath
          result.identifierResult
          result.zonkResult
          path
          kPos
          callablePath
      case anchor of
        Comp.AnchorTyped ty ->
          Just (Comp.completionsOfCallLabels ty usedLabels)
        Comp.AnchorModule _ -> Nothing

-- | If the text ends with a @.@, return the dotted path of identifiers
-- immediately preceding it. Supports nested paths like
-- @foo.bar.baz.@ (returns @\"foo.bar.baz\"@). Returns 'Nothing' when
-- the character before the @.@ is not part of an identifier (so we
-- don't accidentally trigger on @"abc".@ or @42.@).
detectMemberPrefix :: Text -> Maybe Text
detectMemberPrefix t = case Text.unsnoc t of
  Just (rest, '.') ->
    let pathPart = Text.takeWhileEnd isPathChar rest
     in if Text.null pathPart || Text.last pathPart == '.'
          then Nothing
          else Just pathPart
  _ -> Nothing
  where
    isPathChar c = isIdentChar c || c == '.'

-- | If the cursor sits inside an open @(@ whose preceding token is an
-- identifier, return that identifier and the set of labels already
-- used in the current call.
--
-- Strategy: scan @t@ from the end, tracking paren depth. The first
-- unmatched @(@ marks the call's argument region. Everything between
-- the @(@ and the cursor is the partial argument list; lift labels
-- of the form @<ident>\s*=@ out of it.
detectLabelContext :: Text -> Maybe (Text, Set.Set Text)
detectLabelContext t = do
  (openIx, _) <- findOuterOpenParen t
  let beforeParen = Text.take openIx t
      inside = Text.drop (openIx + 1) t
      -- Allow dotted callables like @mod.func(@ — take the whole
      -- path of identifier characters + dots, then drop a stray
      -- trailing dot (= a callable name can't end with @.@).
      raw = Text.takeWhileEnd isPathChar (Text.stripEnd beforeParen)
      callable = dropTrailingDot raw
  if Text.null callable
    then Nothing
    else Just (callable, collectUsedLabels inside)
  where
    isPathChar c = isIdentChar c || c == '.'
    dropTrailingDot s = case Text.unsnoc s of
      Just (rest, '.') -> rest
      _ -> s

-- | Walk @t@ from the end and find the first @(@ that has no matching
-- @)@ to its right within @t@. Returns its byte index in @t@.
findOuterOpenParen :: Text -> Maybe (Int, Char)
findOuterOpenParen t =
  let chars = Text.unpack t
      indexed = zip [0 ..] chars
      go [] _depth = Nothing
      go ((i, c) : rest) depth
        | c == ')' = go rest (depth + 1)
        | c == '(' && depth == 0 = Just (i, c)
        | c == '(' = go rest (depth - 1)
        | otherwise = go rest depth
   in go (reverse indexed) 0

collectUsedLabels :: Text -> Set.Set Text
collectUsedLabels inside =
  -- Split by commas at depth 0, then for each segment look for
  -- @<ident>\s*=@.
  Set.fromList (concatMap labelOfSegment (splitTopLevel inside ','))
  where
    labelOfSegment seg =
      case Text.breakOn "=" seg of
        (_, eqAndRest) | Text.null eqAndRest -> []
        (lhs, _) ->
          let trimmed = Text.strip lhs
              ident = Text.takeWhile isIdentChar trimmed
           in if Text.null ident || ident /= trimmed then [] else [ident]

-- | Split @t@ on @sep@ at outer-level (= ignore commas inside nested
-- parens / brackets). Used to safely tokenise a partial argument
-- list.
splitTopLevel :: Text -> Char -> [Text]
splitTopLevel t sep = go (Text.unpack t) [] [] (0 :: Int)
  where
    go [] cur acc _ = reverse (Text.pack (reverse cur) : map Text.pack (reverse acc))
    go (c : rest) cur acc depth
      | c == sep && depth == 0 = go rest [] (reverse cur : acc) depth
      | c == '(' || c == '[' || c == '{' = go rest (c : cur) acc (depth + 1)
      | c == ')' || c == ']' || c == '}' = go rest (c : cur) acc (max 0 (depth - 1))
      | otherwise = go rest (c : cur) acc depth

isIdentChar :: Char -> Bool
isIdentChar c = isAlphaNum c || c == '_'

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | The line text at the given LSP position, using the pre-split line
-- vector for O(1) indexing. LSP positions are 0-indexed.
currentLine :: Vector Text -> LSP.Position -> Text
currentLine lineVec (LSP.Position lineLsp _) =
  let ix = fromIntegral lineLsp
   in case lineVec Vector.!? ix of
        Just line -> line
        Nothing -> ""

-- ---------------------------------------------------------------------------
-- LSP item construction
-- ---------------------------------------------------------------------------

toLspItem :: Comp.CompletionItem -> LSP.CompletionItem
toLspItem ci =
  LSP.CompletionItem
    { LSP._label = ci.ciLabel,
      LSP._labelDetails = Nothing,
      LSP._kind = Just (mapKind ci.ciKind),
      LSP._tags = Nothing,
      LSP._detail = ci.ciDetail,
      LSP._documentation = fmap (LSP.InL :: Text -> Text LSP.|? LSP.MarkupContent) ci.ciDoc,
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

mapKind :: Comp.CompletionKind -> LSP.CompletionItemKind
mapKind = \case
  Comp.CKLocalVariable -> LSP.CompletionItemKind_Variable
  Comp.CKAgent -> LSP.CompletionItemKind_Function
  Comp.CKRequest -> LSP.CompletionItemKind_Event
  Comp.CKConstructor -> LSP.CompletionItemKind_Constructor
  Comp.CKTypeName -> LSP.CompletionItemKind_Class
  Comp.CKModule -> LSP.CompletionItemKind_Module
