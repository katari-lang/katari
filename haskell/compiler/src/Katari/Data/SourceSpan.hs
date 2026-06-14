module Katari.Data.SourceSpan where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)

-- | A point in a source file, 1-indexed. Columns count Unicode code
-- points (not bytes, not UTF-16 code units).
data Position = Position
  { line :: Int,
    column :: Int
  }
  deriving (Eq, Ord, Show, Generic)

instance ToJSON Position

instance FromJSON Position

data SourceSpan = SourceSpan
  { filePath :: FilePath,
    start :: Position,
    end :: Position
  }
  deriving (Eq, Ord, Show, Generic)

instance ToJSON SourceSpan

instance FromJSON SourceSpan

class HasSourceSpan node where
  sourceSpanOf :: node -> SourceSpan

-- | A value paired with the source span it originates from. A phase carries source spans on its
-- AST nodes, but values produced downstream (errors, semantic types) have lost them; the producer
-- that still holds the originating node re-attaches one with 'Located'.
data Located value = Located
  { value :: value,
    sourceSpan :: SourceSpan
  }
  deriving stock (Eq, Ord, Show, Functor)

instance HasSourceSpan (Located value) where
  sourceSpanOf located = located.sourceSpan

-- | @path:line:column@ of a span's start, for diagnostics.
renderSourceSpan :: SourceSpan -> Text
renderSourceSpan sourceSpan =
  Text.pack sourceSpan.filePath
    <> ":"
    <> Text.pack (show sourceSpan.start.line)
    <> ":"
    <> Text.pack (show sourceSpan.start.column)

spanContains :: SourceSpan -> Position -> Bool
spanContains sourceSpan position =
  ( sourceSpan.start.line < position.line
      || sourceSpan.start.line == position.line && sourceSpan.start.column <= position.column
  )
    && ( position.line < sourceSpan.end.line
           || position.line == sourceSpan.end.line && position.column <= sourceSpan.end.column
       )
