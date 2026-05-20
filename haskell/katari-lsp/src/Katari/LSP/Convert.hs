-- | Translation between LSP's UTF-16 column model and Katari's
-- code-point columns. The LSP wire protocol pins line/column offsets
-- to UTF-16 code units; the Katari compiler measures positions in
-- code points. Conversions are O(line length).
--
-- Source span / range translations live alongside the column helpers
-- so the LSP handlers can stay free of LSP-types vs Katari-types
-- bookkeeping noise.
module Katari.LSP.Convert
  ( lspPositionToKatari,
    katariSpanToLspRange,
    katariSpanToLspLocation,
  )
where

import Data.Char (ord)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Vector (Vector)
import qualified Data.Vector as Vector
import qualified Katari.SourceSpan as K
import qualified Language.LSP.Protocol.Types as LSP

-- | Convert an LSP @Position@ (UTF-16 column) into a Katari 'K.Position'
-- (code-point column). Needs the source text of the file so it can walk
-- the relevant line and translate UTF-16 units back to code points.
--
-- LSP lines are 0-indexed; Katari lines are 1-indexed.
lspPositionToKatari :: Text -> LSP.Position -> K.Position
lspPositionToKatari fileText (LSP.Position lineLsp colLsp) =
  let lineIx = fromIntegral lineLsp
      colUtf16 = fromIntegral colLsp
      lines_ = Vector.fromList (Text.lines fileText)
      lineText = fromMaybe "" (lines_ Vector.!? lineIx)
      codePointCol = utf16ColumnToCodePoint colUtf16 lineText
   in K.Position {K.line = lineIx + 1, K.column = codePointCol + 1}

-- | Code-point column → UTF-16 column. Used when reporting a Katari
-- span back as an LSP range (e.g. diagnostics).
utf16ColumnFor :: Int -> Text -> Int
utf16ColumnFor codePointCol lineText =
  Text.foldl' (\acc c -> acc + utf16Width c) 0 (Text.take codePointCol lineText)

-- | UTF-16 column → code-point column. Walks until accumulated UTF-16
-- units reach the requested column. Out-of-range columns are clamped
-- to the line's code-point length.
utf16ColumnToCodePoint :: Int -> Text -> Int
utf16ColumnToCodePoint target lineText = go 0 0 (Text.unpack lineText)
  where
    go cpAcc utf16Acc cs
      | utf16Acc >= target = cpAcc
      | otherwise = case cs of
          [] -> cpAcc
          (c : rest) -> go (cpAcc + 1) (utf16Acc + utf16Width c) rest

utf16Width :: Char -> Int
utf16Width c = if ord c >= 0x10000 then 2 else 1

-- | Katari 'K.SourceSpan' → LSP 'Range'. Needs the file text to
-- translate code-point columns back to UTF-16. Splits the file's
-- lines into a Vector and indexes both start and end positions
-- against it, so a single span only pays one Text.lines pass instead
-- of one per endpoint.
katariSpanToLspRange :: Map FilePath Text -> K.SourceSpan -> LSP.Range
katariSpanToLspRange fileTexts span_ =
  let txt = fromMaybe "" (Map.lookup span_.filePath fileTexts)
      ls = Vector.fromList (Text.lines txt)
   in spanToLspRange ls span_

-- | Katari 'K.SourceSpan' → LSP 'Location' (= a file-uri + range).
katariSpanToLspLocation :: Map FilePath Text -> K.SourceSpan -> LSP.Location
katariSpanToLspLocation fileTexts span_ =
  LSP.Location (LSP.filePathToUri span_.filePath) (katariSpanToLspRange fileTexts span_)

-- | Internal helper that takes the pre-split line vector. Callers that
-- convert many spans on the same file should split once and call this
-- directly to amortise the O(N) Text.lines cost.
spanToLspRange :: Vector Text -> K.SourceSpan -> LSP.Range
spanToLspRange ls span_ =
  let toLsp p =
        LSP.Position
          (fromIntegral (max 0 (p.line - 1)))
          ( fromIntegral
              ( utf16ColumnFor
                  (max 0 (p.column - 1))
                  (fromMaybe "" (ls Vector.!? (p.line - 1)))
              )
          )
   in LSP.Range (toLsp span_.start) (toLsp span_.end)
