-- | Translation between LSP's wire model and the compiler's source model. Two independent gaps are
-- bridged here so the handlers stay free of bookkeeping noise:
--
--   * Columns: the LSP protocol pins line/column offsets to UTF-16 code units; the compiler counts
--     Unicode code points. Conversions are O(line length).
--   * Files: a compiler 'K.SourceSpan' carries the /rendered module name/ in its @filePath@ field
--     (the parser stamps spans with the module name — the compiler makes no assumption about real
--     files). A 'SpanContext' carries the module-name → source-text and module-name → real-path maps
--     of the compile that produced the spans, so a span can be rendered as an LSP range or location.
module Katari.LSP.Convert
  ( SpanContext (..),
    emptySpanContext,
    lspPositionToKatari,
    spanToRange,
    spanToLocation,
    textToLineVector,
    sliceSpan,
  )
where

import Data.Char (ord)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Katari.Data.SourceSpan qualified as K
import Language.LSP.Protocol.Types qualified as LSP

-- | The file surface of one compile: everything needed to turn its spans back into editor
-- coordinates. Keys are rendered module names (what a span's @filePath@ holds); only modules that
-- came from a real file appear in 'pathsByModule' (the embedded stdlib has no navigable path).
data SpanContext = SpanContext
  { textsByModule :: Map FilePath Text,
    linesByModule :: Map FilePath (Vector Text),
    pathsByModule :: Map FilePath FilePath
  }

emptySpanContext :: SpanContext
emptySpanContext =
  SpanContext {textsByModule = Map.empty, linesByModule = Map.empty, pathsByModule = Map.empty}

-- | Convert an LSP @Position@ (0-indexed line, UTF-16 column) into a compiler 'K.Position'
-- (1-indexed line, code-point column), against the file's pre-split lines.
lspPositionToKatari :: Vector Text -> LSP.Position -> K.Position
lspPositionToKatari lineVector (LSP.Position lspLine lspColumn) =
  let lineIndex = fromIntegral lspLine
      lineText = fromMaybe "" (lineVector Vector.!? lineIndex)
      codePointColumn = utf16ColumnToCodePoint (fromIntegral lspColumn) lineText
   in K.Position {K.line = lineIndex + 1, K.column = codePointColumn + 1}

-- | Code-point column → UTF-16 column, for reporting a span back as an LSP range.
utf16ColumnFor :: Int -> Text -> Int
utf16ColumnFor codePointColumn lineText =
  Text.foldl' (\accumulated character -> accumulated + utf16Width character) 0 (Text.take codePointColumn lineText)

-- | UTF-16 column → code-point column. Walks until the accumulated UTF-16 units reach the requested
-- column; out-of-range columns clamp to the line's code-point length.
utf16ColumnToCodePoint :: Int -> Text -> Int
utf16ColumnToCodePoint target lineText = walk 0 0 (Text.unpack lineText)
  where
    walk codePoints utf16Units characters
      | utf16Units >= target = codePoints
      | otherwise = case characters of
          [] -> codePoints
          (character : rest) -> walk (codePoints + 1) (utf16Units + utf16Width character) rest

utf16Width :: Char -> Int
utf16Width character = if ord character >= 0x10000 then 2 else 1

-- | A compiler span as an LSP range, against the span's own module lines from the context.
spanToRange :: SpanContext -> K.SourceSpan -> LSP.Range
spanToRange context sourceSpan =
  let lineVector = fromMaybe Vector.empty (Map.lookup sourceSpan.filePath context.linesByModule)
      toLsp position =
        LSP.Position
          (fromIntegral (max 0 (position.line - 1)))
          ( fromIntegral
              ( utf16ColumnFor
                  (max 0 (position.column - 1))
                  (fromMaybe "" (lineVector Vector.!? (position.line - 1)))
              )
          )
   in LSP.Range (toLsp sourceSpan.start) (toLsp sourceSpan.end)

-- | A compiler span as an LSP location. 'Nothing' when the span's module has no real file (the
-- embedded stdlib) — there is nowhere to navigate to.
spanToLocation :: SpanContext -> K.SourceSpan -> Maybe LSP.Location
spanToLocation context sourceSpan = do
  realPath <- Map.lookup sourceSpan.filePath context.pathsByModule
  pure (LSP.Location (LSP.filePathToUri realPath) (spanToRange context sourceSpan))

-- | Split file text into a 'Vector' of lines for O(1) indexing.
textToLineVector :: Text -> Vector Text
textToLineVector = Vector.fromList . Text.lines

-- | The source text between a span's endpoints (inclusive), from the pre-split line vector.
-- Multi-line snippets are joined with @\\n@.
sliceSpan :: Vector Text -> K.SourceSpan -> Text
sliceSpan lineVector sourceSpan =
  let startLine = sourceSpan.start.line - 1
      endLine = sourceSpan.end.line - 1
      startColumn = sourceSpan.start.column - 1
      endColumn = sourceSpan.end.column - 1
   in case (lineVector Vector.!? startLine, lineVector Vector.!? endLine) of
        (Just firstText, Just lastText)
          | startLine == endLine ->
              Text.take (endColumn - startColumn) (Text.drop startColumn firstText)
          | otherwise ->
              let middle = Vector.toList (Vector.slice (startLine + 1) (endLine - startLine - 1) lineVector)
                  firstLine = Text.drop startColumn firstText
                  lastLine = Text.take endColumn lastText
               in Text.intercalate "\n" (firstLine : middle <> [lastLine])
        _ -> ""
