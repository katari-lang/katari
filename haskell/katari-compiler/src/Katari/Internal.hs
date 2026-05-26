-- | Helpers for compiler-invariant violations ('K9999' diagnostics).
module Katari.Internal
  ( internalError,
    internalErrorNoSpan,
  )
where

import Data.Text (Text)
import Katari.Diagnostic (Diagnostic, diagnosticInternalError)
import Katari.SourceSpan (Position (..), SourceSpan (..))

-- | Build a 'K9999' 'Diagnostic' describing an invariant violation at a
-- known span. Use when the call site has a 'SourceSpan' to attach
-- (typically: a node currently being processed).
internalError :: SourceSpan -> Text -> Diagnostic
internalError = diagnosticInternalError

-- | Build a 'K9999' 'Diagnostic' when the call site has no useful span.
-- The diagnostic gets a placeholder span (line 0:0 of the empty file
-- path) which downstream renderers should treat as "no location".
internalErrorNoSpan :: Text -> Diagnostic
internalErrorNoSpan = diagnosticInternalError placeholderSpan

placeholderSpan :: SourceSpan
placeholderSpan =
  SrcSpan
    { filePath = "",
      start = Position {line = 0, column = 0},
      end = Position {line = 0, column = 0}
    }
