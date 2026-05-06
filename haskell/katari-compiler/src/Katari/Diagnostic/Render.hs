-- | Human-readable rendering of 'Diagnostic' values for CLI output.
--
-- This module lives outside 'Katari.Diagnostic' so that the core diagnostic
-- type stays dependency-free (no source-text dependency). Callers that have
-- the source map (e.g. @katari-cli@) can produce snippet-annotated output;
-- callers without it get the plain form.
module Katari.Diagnostic.Render
  ( renderDiagnostic,
    renderDiagnosticPlain,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Diagnostic (Diagnostic (..), DiagnosticNote (..), Severity (..))
import Katari.SourceSpan (Position (..), SourceSpan (..))
import Safe (atMay)

-- | Render a diagnostic with an inline source snippet when the file is
-- available in the source map. Falls back to 'renderDiagnosticPlain' if
-- the file is absent.
renderDiagnostic :: Map FilePath Text -> Diagnostic -> Text
renderDiagnostic sources diagnostic =
  let plain = renderDiagnosticPlain diagnostic
      snippet = renderSnippet sources diagnostic.span
   in case snippet of
        Nothing -> plain
        Just snip -> plain <> "\n" <> snip

-- | Render a diagnostic without source snippets. Suitable for contexts
-- where source text is unavailable.
--
-- Format:
-- @
-- error[K0123]: some message
--   --> module:main (1:5)
-- @
renderDiagnosticPlain :: Diagnostic -> Text
renderDiagnosticPlain diagnostic =
  severityPrefix diagnostic.severity
    <> "["
    <> diagnostic.code
    <> "]: "
    <> diagnostic.message
    <> "\n  --> "
    <> Text.pack diagnostic.span.filePath
    <> " ("
    <> renderPosition diagnostic.span.start
    <> ")"
    <> foldMap renderNote diagnostic.notes
    <> foldMap renderHint diagnostic.hints

-- ===========================================================================
-- Internal helpers
-- ===========================================================================

severityPrefix :: Severity -> Text
severityPrefix = \case
  SeverityError -> "error"
  SeverityWarning -> "warning"
  SeverityInfo -> "info"
  SeverityHint -> "hint"

renderPosition :: Position -> Text
renderPosition position =
  Text.pack (show position.line) <> ":" <> Text.pack (show position.column)

renderNote :: DiagnosticNote -> Text
renderNote note =
  "\n  note: "
    <> note.message
    <> " ("
    <> Text.pack note.span.filePath
    <> " "
    <> renderPosition note.span.start
    <> ")"

renderHint :: Text -> Text
renderHint hint = "\n  hint: " <> hint

-- | Extract the source lines covered by the span and underline the relevant
-- columns. Returns 'Nothing' if the file is absent from the map.
renderSnippet :: Map FilePath Text -> SourceSpan -> Maybe Text
renderSnippet sources sourceSpan = do
  source <- Map.lookup sourceSpan.filePath sources
  let sourceLines = Text.lines source
      lineIndex = sourceSpan.start.line - 1
      line = fromMaybe "" (sourceLines `atMay` lineIndex)
      lineNumberText = Text.pack (show sourceSpan.start.line)
      padding = Text.replicate (Text.length lineNumberText) " "
      startCol = sourceSpan.start.column - 1
      endCol =
        if sourceSpan.end.line == sourceSpan.start.line
          then sourceSpan.end.column - 1
          else Text.length line
      underlineLen = max 1 (endCol - startCol)
      underline = Text.replicate startCol " " <> Text.replicate underlineLen "^"
  pure $
    padding
      <> " |\n"
      <> lineNumberText
      <> " | "
      <> line
      <> "\n"
      <> padding
      <> " | "
      <> underline
