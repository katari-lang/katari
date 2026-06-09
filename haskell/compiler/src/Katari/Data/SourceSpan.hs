module Katari.Data.SourceSpan where

import Data.Aeson (FromJSON, ToJSON)
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

data SourceSpan = SrcSpan
  { filePath :: FilePath,
    start :: Position,
    end :: Position
  }
  deriving (Eq, Ord, Show, Generic)

instance ToJSON SourceSpan

instance FromJSON SourceSpan

class HasSourceSpan node where
  sourceSpanOf :: node -> SourceSpan

spanContains :: SourceSpan -> Position -> Bool
spanContains sourceSpan position =
  ( sourceSpan.start.line < position.line
      || sourceSpan.start.line == position.line && sourceSpan.start.column <= position.column
  )
    && ( position.line < sourceSpan.end.line
           || position.line == sourceSpan.end.line && position.column <= sourceSpan.end.column
       )
