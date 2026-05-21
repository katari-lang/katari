-- | Source positions and spans used across the compiler pipeline.
--
-- 'Position' is line-and-column (1-indexed), 'SourceSpan' is a
-- @(start, end)@ pair attached to a 'FilePath'. The 'HasSourceSpan'
-- class exists so callers can ask any AST / IR node for its origin
-- without committing to a concrete type.
--
-- Both types are 'ToJSON' / 'FromJSON' so they can ride along in
-- 'Diagnostic' wire payloads.
module Katari.SourceSpan where

import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)

data Position = Position
  { line :: Int,
    column :: Int
  }
  deriving (Eq, Ord, Show, Generic)

instance ToJSON Position

instance FromJSON Position

data SourceSpan = SrcSpan
  { filePath :: FilePath,
    start :: Position,
    end :: Position
  }
  deriving (Eq, Ord, Show, Generic)

instance ToJSON SourceSpan

instance FromJSON SourceSpan

-- | Smart constructor that ensures start ≤ end. Swaps the two positions
-- if they are reversed, preventing negative-length underlines in the
-- diagnostic renderer.
mkSourceSpan :: FilePath -> Position -> Position -> SourceSpan
mkSourceSpan path p1 p2
  | p1 <= p2 = SrcSpan {filePath = path, start = p1, end = p2}
  | otherwise = SrcSpan {filePath = path, start = p2, end = p1}

-- | Generic accessor for nodes that carry a source span. Implemented
-- uniformly by record-shaped nodes and by GADT sum types.
class HasSourceSpan node where
  sourceSpanOf :: node -> SourceSpan

-- | True iff @position@ lies within @sourceSpan@.
--
-- Semantics: the lexer's 'end' column is the position one past the
-- last character of the token (= the "caret to the right of the last
-- char" position, see 'Katari.Lexer'). So @position.column ==
-- sourceSpan.end.column@ corresponds to the cursor sitting on the
-- character AFTER the token — we treat that as "in the span" to make
-- LSP hover on a cursor adjacent to an identifier behave naturally.
spanContains :: SourceSpan -> Position -> Bool
spanContains sourceSpan position =
  ( sourceSpan.start.line < position.line
      || sourceSpan.start.line == position.line && sourceSpan.start.column <= position.column
  )
    && ( position.line < sourceSpan.end.line
           || position.line == sourceSpan.end.line && position.column <= sourceSpan.end.column
       )
