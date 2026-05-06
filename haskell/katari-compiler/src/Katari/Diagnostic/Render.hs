-- | Human-readable rendering of 'Diagnostic' values for CLI / LSP output.
--
-- Built on top of @prettyprinter@ so the same 'Doc' tree can be emitted
-- as plain text or as ANSI-coloured terminal output. Callers that have
-- the source map (e.g. @katari-cli@) can produce snippet-annotated
-- output; callers without it get the plain form.
--
-- 'Katari.Diagnostic' itself stays dependency-free (no source-text
-- dependency, no terminal-rendering dependency) — the heavy lifting
-- lives here.
module Katari.Diagnostic.Render
  ( -- * Plain rendering (no ANSI escapes)
    renderDiagnostic,
    renderDiagnosticPlain,

    -- * ANSI rendering (severity-coloured headers / underlines)
    renderDiagnosticAnsi,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Katari.Diagnostic (Diagnostic (..), DiagnosticNote (..), Severity (..))
import Katari.SourceSpan (Position (..), SourceSpan (..))
import Prettyprinter
  ( Doc,
    annotate,
    indent,
    pretty,
    vsep,
    (<+>),
  )
import Prettyprinter qualified as PP
import Prettyprinter.Render.Terminal (AnsiStyle, Color (..))
import Prettyprinter.Render.Terminal qualified as PPAnsi
import Prettyprinter.Render.Text qualified as PPText
import Safe (atMay)

-- ===========================================================================
-- Public API
-- ===========================================================================

-- | Render a diagnostic with an inline source snippet when the file is
-- available in the source map. Falls back to 'renderDiagnosticPlain'
-- shape if the file is absent. Plain text — no ANSI escapes.
--
-- @
-- import Data.Map.Strict qualified as Map
--
-- let sources = Map.singleton "main.ktr" src
-- putStrLn (Text.unpack (renderDiagnostic sources diag))
-- -- error[K0001]: unterminated string literal
-- --   --> main.ktr:1:5
-- --    1 | let x = "hello
-- --                ^
-- @
renderDiagnostic :: Map FilePath Text -> Diagnostic -> Text
renderDiagnostic sources diagnostic =
  renderPlainText (diagnosticDoc sources diagnostic)

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
  renderPlainText (diagnosticDoc Map.empty diagnostic)

-- | Render a diagnostic with severity-coloured headers / underlines and
-- (when available) an inline source snippet. Emits ANSI escape sequences
-- suitable for a 256-colour terminal.
renderDiagnosticAnsi :: Map FilePath Text -> Diagnostic -> Text
renderDiagnosticAnsi sources diagnostic =
  PPAnsi.renderStrict $
    PP.layoutPretty PP.defaultLayoutOptions (diagnosticDoc sources diagnostic)

-- ===========================================================================
-- Doc construction
-- ===========================================================================

-- | The shared 'Doc' for plain and ANSI rendering. Style annotations are
-- discarded by the plain renderer.
diagnosticDoc :: Map FilePath Text -> Diagnostic -> Doc AnsiStyle
diagnosticDoc sources diagnostic =
  vsep $
    headerLine
      : locationLine
      : maybe [] (\snip -> [snip]) (snippetDoc sources diagnostic.span)
        <> map noteDoc diagnostic.notes
        <> map hintDoc diagnostic.hints
  where
    headerLine =
      annotate (severityStyle diagnostic.severity) (severityWord diagnostic.severity)
        <> annotate (severityStyle diagnostic.severity) (PP.brackets (pretty diagnostic.code))
        <> ":"
        <+> pretty diagnostic.message
    locationLine =
      indent 2 $
        "-->"
          <+> pretty diagnostic.span.filePath
          <+> PP.parens (positionDoc diagnostic.span.start)

severityWord :: Severity -> Doc AnsiStyle
severityWord = \case
  SeverityError -> "error"
  SeverityWarning -> "warning"
  SeverityInfo -> "info"
  SeverityHint -> "hint"

severityStyle :: Severity -> AnsiStyle
severityStyle = \case
  SeverityError -> PPAnsi.color Red <> PPAnsi.bold
  SeverityWarning -> PPAnsi.color Yellow <> PPAnsi.bold
  SeverityInfo -> PPAnsi.color Blue <> PPAnsi.bold
  SeverityHint -> PPAnsi.colorDull Cyan

positionDoc :: Position -> Doc AnsiStyle
positionDoc position =
  pretty position.line <> ":" <> pretty position.column

noteDoc :: DiagnosticNote -> Doc AnsiStyle
noteDoc note =
  indent 2 $
    annotate (PPAnsi.colorDull Blue <> PPAnsi.bold) "note:"
      <+> pretty note.message
      <+> PP.parens
        ( pretty note.span.filePath
            <+> positionDoc note.span.start
        )

hintDoc :: Text -> Doc AnsiStyle
hintDoc hint =
  indent 2 $
    annotate (PPAnsi.colorDull Cyan <> PPAnsi.bold) "hint:" <+> pretty hint

-- | Build the snippet block for the span's primary line, with an
-- underline marking the affected columns. Returns 'Nothing' if the
-- file is absent from the source map.
snippetDoc :: Map FilePath Text -> SourceSpan -> Maybe (Doc AnsiStyle)
snippetDoc sources sourceSpan = do
  source <- Map.lookup sourceSpan.filePath sources
  let sourceLines = Text.lines source
      lineIndex = sourceSpan.start.line - 1
      line = fromMaybe "" (sourceLines `atMay` lineIndex)
      lineNumberText = Text.pack (show sourceSpan.start.line)
      gutterPad = Text.replicate (Text.length lineNumberText) " "
      startCol = sourceSpan.start.column - 1
      endCol =
        if sourceSpan.end.line == sourceSpan.start.line
          then sourceSpan.end.column - 1
          else Text.length line
      underlineLen = max 1 (endCol - startCol)
      underlineText =
        Text.replicate startCol " " <> Text.replicate underlineLen "^"
  pure $
    vsep
      [ pretty gutterPad <+> "|",
        pretty lineNumberText <+> "|" <+> pretty line,
        pretty gutterPad <+> "|" <+> annotate snippetUnderlineStyle (pretty underlineText)
      ]

snippetUnderlineStyle :: AnsiStyle
snippetUnderlineStyle = PPAnsi.color Red <> PPAnsi.bold

-- | Render the document to plain 'Text', stripping all ANSI annotations.
renderPlainText :: Doc AnsiStyle -> Text
renderPlainText doc =
  PPText.renderStrict (PP.layoutPretty PP.defaultLayoutOptions (PP.unAnnotate doc))
