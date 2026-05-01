-- | Unified diagnostic type for the Katari compiler.
--
-- Each compiler phase (lexer / parser / identifier / constraint-gen / solver
-- / zonker / lowering) historically produced its own error type. This module
-- defines a single 'Diagnostic' carrier that downstream consumers (LSP /
-- katari-project / playground) can render uniformly. Per-phase errors are
-- still produced internally for debugging, and converted to 'Diagnostic'
-- via @toDiagnostic@ functions in the phase modules.
--
-- Wire format: 'Diagnostic' has a JSON schema (via Aeson 'ToJSON' /
-- 'FromJSON') so the LSP can transmit them directly.
--
-- Stable codes: every diagnostic carries a 4-digit @"K####"@ code that
-- downstream tools may pin to. The numbering scheme:
--
--   * K0001-K0099 — lexer / parser
--   * K0100-K0199 — identifier
--   * K0200-K0299 — constraint generator / solver / zonker
--   * K0300-K0399 — lowering
--   * K0400-K0499 — schema / emit
--
-- The full registry lives in CHANGELOG.md (Phase 14); a code is added the
-- moment a per-phase converter starts emitting it.
module Katari.Diagnostic
  ( Severity (..),
    Diagnostic (..),
    DiagnosticNote (..),
    diagnosticError,
    diagnosticWarning,
    hasErrors,
    filterAtLeast,
    sortBySpan,
    groupByFilePath,
  )
where

import Data.Aeson
  ( FromJSON (..),
    Options (..),
    SumEncoding (..),
    ToJSON (..),
    defaultOptions,
    genericParseJSON,
    genericToJSON,
  )
import Data.Char (toLower)
import Data.List (sortBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (comparing)
import Data.Text (Text)
import GHC.Generics (Generic)
import Katari.SourceSpan (Position (..), SourceSpan (..))

-- | Severity of a diagnostic. Ordered so 'Error' is the most severe;
-- the 'Ord' instance is exploited by 'hasErrors'.
data Severity where
  SeverityHint :: Severity
  SeverityInfo :: Severity
  SeverityWarning :: Severity
  SeverityError :: Severity
  deriving (Eq, Ord, Show, Generic)

instance ToJSON Severity where
  toJSON = genericToJSON severityOptions

instance FromJSON Severity where
  parseJSON = genericParseJSON severityOptions

-- | Severity is JSON-encoded as a bare lowercase string ("hint" / "info" /
-- "warning" / "error"). The full constructor name (e.g. "SeverityHint")
-- carries the type-name prefix per CLAUDE.md naming conventions; the
-- prefix is stripped at the JSON boundary so consumers see the
-- conventional unadorned form.
severityOptions :: Options
severityOptions =
  defaultOptions
    { sumEncoding = UntaggedValue,
      constructorTagModifier = map toLower . drop (length ("Severity" :: String)),
      allNullaryToStringTag = True
    }

-- | A single diagnostic message.
--
--   * 'severity' — drives whether the build proceeds. 'Error' diagnostics
--     prevent IR / schema emission downstream.
--   * 'code' — stable identifier (@"K0123"@) for tooling to pin against.
--   * 'message' — one-line summary suitable for inline display.
--   * 'span' — primary source location.
--   * 'notes' — additional related spans + explanations (e.g. "first
--     defined here") for richer error UX.
--   * 'hints' — actionable suggestions (free-form text).
data Diagnostic = Diagnostic
  { severity :: !Severity,
    code :: !Text,
    message :: !Text,
    span :: !SourceSpan,
    notes :: ![DiagnosticNote],
    hints :: ![Text]
  }
  deriving (Eq, Show, Generic)

-- | Secondary location attached to a primary 'Diagnostic'. Used to point
-- to the conflicting prior definition / declaration, or any other spot
-- the reader should also look at.
data DiagnosticNote = DiagnosticNote
  { span :: !SourceSpan,
    message :: !Text
  }
  deriving (Eq, Show, Generic)

-- 'SourceSpan' / 'Position' instances live in 'Katari.AST' next to the
-- types themselves.

instance ToJSON Diagnostic where
  toJSON = genericToJSON defaultOptions {omitNothingFields = True}

instance FromJSON Diagnostic where
  parseJSON = genericParseJSON defaultOptions

instance ToJSON DiagnosticNote where
  toJSON = genericToJSON defaultOptions

instance FromJSON DiagnosticNote where
  parseJSON = genericParseJSON defaultOptions

-- | Convenience constructor for an error-severity diagnostic with no
-- notes / hints. Per-phase converters typically start from this and add
-- detail.
diagnosticError :: Text -> Text -> SourceSpan -> Diagnostic
diagnosticError code_ message_ span_ =
  Diagnostic
    { severity = SeverityError,
      code = code_,
      message = message_,
      span = span_,
      notes = [],
      hints = []
    }

-- | Convenience constructor for a warning-severity diagnostic.
diagnosticWarning :: Text -> Text -> SourceSpan -> Diagnostic
diagnosticWarning code_ message_ span_ =
  Diagnostic
    { severity = SeverityWarning,
      code = code_,
      message = message_,
      span = span_,
      notes = [],
      hints = []
    }

-- | True if any of the diagnostics in the list has 'Error' severity.
-- Used by orchestrators (e.g. 'Katari.Compile') to decide whether to skip
-- IR / schema emission.
hasErrors :: [Diagnostic] -> Bool
hasErrors = any ((== SeverityError) . (.severity))

-- | Keep only diagnostics whose severity is at least as severe as the given
-- threshold (using the 'Ord' instance: 'SeverityError' > 'SeverityWarning' > ...).
filterAtLeast :: Severity -> [Diagnostic] -> [Diagnostic]
filterAtLeast threshold = filter ((>= threshold) . (.severity))

-- | Sort diagnostics by source span: file path first, then start line,
-- then start column.
sortBySpan :: [Diagnostic] -> [Diagnostic]
sortBySpan =
  sortBy
    ( comparing
        ( \d ->
            ( d.span.filePath,
              d.span.start.line,
              d.span.start.column
            )
        )
    )

-- | Group diagnostics by the 'filePath' of their source span.
groupByFilePath :: [Diagnostic] -> Map FilePath [Diagnostic]
groupByFilePath =
  foldr
    (\d acc -> Map.insertWith (<>) d.span.filePath [d] acc)
    Map.empty
