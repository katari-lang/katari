module Katari.Lexer
  ( TokKind (..)
  , FStrPart (..)
  , Token (..)
  , LexError (..)
  , lexFile
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Char (isAlpha, isAlphaNum, isDigit)

-- ---------------------------------------------------------------------------
-- Template literal fragments
-- ---------------------------------------------------------------------------

data FStrPart
  = FStrLit  Text
  | FStrExpr [Token]
  deriving (Show, Eq, Ord)

-- ---------------------------------------------------------------------------
-- Token kinds
-- ---------------------------------------------------------------------------

data TokKind
  -- Literals
  = TKInt    Integer
  | TKNum    Double
  | TKStr    Text
  | TKBool   Bool
  | TKNull
  | TKFStr   [FStrPart]
  -- Keywords
  | TKVal    | TKLet    | TKTask    | TKIf   | TKElse  | TKMatch
  | TKCase   | TKReturn | TKReply   | TKNext | TKBreak
  | TKRequest| TKType   | TKImport  | TKAs
  | TKWith   | TKFrom   | TKFor     | TKFinally | TKOf  | TKVar
  | TKHandle | TKExternal | TKPar
  -- Identifier
  | TKIdent  Text
  -- Multi-char operators (longest match first in lexer)
  | TKEqEq | TKNeq | TKLe | TKGe | TKAmpAmp | TKPipePipe | TKPlusPlus | TKArrow | TKFatArrow
  -- Single-char operators
  | TKPlus  | TKMinus | TKStar | TKSlash
  | TKLt    | TKGt
  | TKBang  | TKEq   | TKColon | TKDot | TKComma | TKSemi | TKAt | TKQuestion
  | TKPipe  | TKAmp
  -- Delimiters
  | TKLParen | TKRParen | TKLBrace | TKRBrace | TKLBracket | TKRBracket
  | TKEof
  deriving (Show, Eq, Ord)

-- ---------------------------------------------------------------------------
-- Token
-- ---------------------------------------------------------------------------

data Token = Token
  { tokKind :: TokKind
  , tokLine :: Int
  , tokCol  :: Int
  } deriving (Show, Eq)

instance Ord Token where
  compare t1 t2 = compare (tokKind t1) (tokKind t2)

-- ---------------------------------------------------------------------------
-- Error
-- ---------------------------------------------------------------------------

newtype LexError = LexError { lexErrMsg :: String }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

lexFile :: FilePath -> Text -> Either LexError [Token]
lexFile fp src = do
  raw <- lexRaw fp (T.unpack src) 1 1 []
  return (insertSemicolons (reverse raw))

-- ---------------------------------------------------------------------------
-- Raw lexer (builds reversed token list)
-- ---------------------------------------------------------------------------

lexRaw :: FilePath -> String -> Int -> Int -> [Token] -> Either LexError [Token]
lexRaw _fp [] ln _col acc = Right (Token TKEof ln 0 : acc)

-- Newlines (tracked but whitespace)
lexRaw fp ('\r':'\n':cs) ln _col acc = lexRaw fp cs (ln+1) 1 acc
lexRaw fp ('\r':cs)      ln _col acc = lexRaw fp cs (ln+1) 1 acc
lexRaw fp ('\n':cs)      ln _col acc = lexRaw fp cs (ln+1) 1 acc
lexRaw fp (' ':cs)       ln col acc  = lexRaw fp cs ln (col+1) acc
lexRaw fp ('\t':cs)      ln col acc  = lexRaw fp cs ln (col+4) acc

-- Line comments
lexRaw fp ('/':'/':cs) ln col acc =
  let rest = dropWhile (/= '\n') cs
  in lexRaw fp rest ln (col + 2 + length (takeWhile (/= '\n') cs)) acc

-- Block comments
lexRaw fp ('/':'*':cs) ln col acc =
  case skipBlockComment cs ln (col+2) of
    Left e          -> Left e
    Right (r,l',c') -> lexRaw fp r l' c' acc

-- Multiline string
lexRaw fp ('"':'"':'"':cs) ln col acc =
  case lexMultiStr fp cs ln (col+3) of
    Left e               -> Left e
    Right (s,r,l',c')    -> lexRaw fp r l' c' (Token (TKStr s) ln col : acc)

-- Template literal (multiline)
lexRaw fp ('f':'"':'"':'"':cs) ln col acc =
  case lexFStrMulti fp cs ln (col+4) of
    Left e            -> Left e
    Right (ps,r,l',c') -> lexRaw fp r l' c' (Token (TKFStr ps) ln col : acc)

-- Template literal (single line)
lexRaw fp ('f':'"':cs) ln col acc =
  case lexFStr fp cs ln (col+2) False of
    Left e            -> Left e
    Right (ps,r,l',c') -> lexRaw fp r l' c' (Token (TKFStr ps) ln col : acc)

-- Regular string
lexRaw fp ('"':cs) ln col acc =
  case lexStr fp cs ln (col+1) [] of
    Left e            -> Left e
    Right (s,r,c')    -> lexRaw fp r ln c' (Token (TKStr s) ln col : acc)

-- Identifiers and keywords
lexRaw fp (c:cs) ln col acc | isAlpha c || c == '_' =
  let (rest0, after) = span (\x -> isAlphaNum x || x == '_') cs
      word = c : rest0
      len  = length word
  in lexRaw fp after ln (col+len) (Token (keywordOrIdent word) ln col : acc)

-- Number literals (check float before int)
lexRaw fp (c:cs) ln col acc | isDigit c =
  let (digits, after) = span isDigit cs
      allDigits = c : digits
  in case after of
       ('.':d:after2) | isDigit d ->
         let (frac, after3) = span isDigit after2
             numStr = allDigits ++ "." ++ (d:frac)
             n      = read numStr :: Double
         in lexRaw fp after3 ln (col + length numStr) (Token (TKNum n) ln col : acc)
       _ ->
         lexRaw fp after ln (col + length allDigits)
                (Token (TKInt (read allDigits)) ln col : acc)

-- Multi-char operators
lexRaw fp ('=':'>':cs) ln col acc = lexRaw fp cs ln (col+2) (Token TKFatArrow ln col : acc)
lexRaw fp ('=':'=':cs) ln col acc = lexRaw fp cs ln (col+2) (Token TKEqEq ln col : acc)
lexRaw fp ('!':'=':cs) ln col acc = lexRaw fp cs ln (col+2) (Token TKNeq  ln col : acc)
lexRaw fp ('<':'=':cs) ln col acc = lexRaw fp cs ln (col+2) (Token TKLe   ln col : acc)
lexRaw fp ('>':'=':cs) ln col acc = lexRaw fp cs ln (col+2) (Token TKGe   ln col : acc)
lexRaw fp ('&':'&':cs) ln col acc = lexRaw fp cs ln (col+2) (Token TKAmpAmp    ln col : acc)
lexRaw fp ('|':'|':cs) ln col acc = lexRaw fp cs ln (col+2) (Token TKPipePipe  ln col : acc)
lexRaw fp ('+':'+':cs) ln col acc = lexRaw fp cs ln (col+2) (Token TKPlusPlus  ln col : acc)
lexRaw fp ('-':'>':cs) ln col acc = lexRaw fp cs ln (col+2) (Token TKArrow     ln col : acc)

-- Single-char operators
lexRaw fp ('+':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKPlus     ln col : acc)
lexRaw fp ('-':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKMinus    ln col : acc)
lexRaw fp ('*':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKStar     ln col : acc)
lexRaw fp ('/':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKSlash    ln col : acc)
lexRaw fp ('<':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKLt       ln col : acc)
lexRaw fp ('>':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKGt       ln col : acc)
lexRaw fp ('!':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKBang     ln col : acc)
lexRaw fp ('=':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKEq       ln col : acc)
lexRaw fp (':':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKColon    ln col : acc)
lexRaw fp ('.':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKDot      ln col : acc)
lexRaw fp (',':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKComma    ln col : acc)
lexRaw fp (';':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKSemi     ln col : acc)
lexRaw fp ('@':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKAt       ln col : acc)
lexRaw fp ('?':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKQuestion ln col : acc)
lexRaw fp ('|':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKPipe     ln col : acc)
lexRaw fp ('&':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKAmp      ln col : acc)
lexRaw fp ('(':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKLParen   ln col : acc)
lexRaw fp (')':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKRParen   ln col : acc)
lexRaw fp ('{':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKLBrace   ln col : acc)
lexRaw fp ('}':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKRBrace   ln col : acc)
lexRaw fp ('[':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKLBracket ln col : acc)
lexRaw fp (']':cs) ln col acc = lexRaw fp cs ln (col+1) (Token TKRBracket ln col : acc)

lexRaw _fp (c:_) ln col _ =
  Left (LexError ("Unexpected character " ++ show c ++ " at " ++ show ln ++ ":" ++ show col))

-- ---------------------------------------------------------------------------
-- String helpers
-- ---------------------------------------------------------------------------

skipBlockComment :: String -> Int -> Int -> Either LexError (String, Int, Int)
skipBlockComment [] ln _col = Left (LexError ("Unterminated block comment at line " ++ show ln))
skipBlockComment ('*':'/':cs) ln col = Right (cs, ln, col+2)
skipBlockComment ('/':'*':cs) ln col =
  case skipBlockComment cs ln (col+2) of
    Left e             -> Left e
    Right (r, l', c') -> skipBlockComment r l' c'
skipBlockComment ('\n':cs) ln _col = skipBlockComment cs (ln+1) 1
skipBlockComment (_:cs)    ln col  = skipBlockComment cs ln (col+1)

lexStr :: FilePath -> String -> Int -> Int -> [Char] -> Either LexError (Text, String, Int)
lexStr fp [] ln _col _ = Left (LexError ("Unterminated string at line " ++ show ln))
lexStr _fp ('"':cs) _ln col acc = Right (T.pack (reverse acc), cs, col+1)
lexStr fp ('\\':c:cs) ln col acc =
  let ec = decodeEscape c
  in lexStr fp cs ln (col+2) (ec:acc)
lexStr fp (c:cs) ln col acc = lexStr fp cs ln (col+1) (c:acc)

decodeEscape :: Char -> Char
decodeEscape 'n'  = '\n'
decodeEscape 't'  = '\t'
decodeEscape 'r'  = '\r'
decodeEscape '\\' = '\\'
decodeEscape '"'  = '"'
decodeEscape '$'  = '$'
decodeEscape c    = c

-- Multiline string: after opening """
-- spec: first and last newline not included
lexMultiStr :: FilePath -> String -> Int -> Int -> Either LexError (Text, String, Int, Int)
lexMultiStr fp ('\n':cs) ln _col = goMLS fp cs (ln+1) 1 []
lexMultiStr fp ('\r':'\n':cs) ln _col = goMLS fp cs (ln+1) 1 []
lexMultiStr fp _ ln col = Left (LexError ("Multiline string must start with newline at " ++ show ln ++ ":" ++ show col))

goMLS :: FilePath -> String -> Int -> Int -> [Char] -> Either LexError (Text, String, Int, Int)
goMLS fp [] ln _col _ = Left (LexError ("Unterminated multiline string at line " ++ show ln))
goMLS _fp ('\n':'"':'"':'"':cs) ln col acc = Right (T.pack (reverse acc), cs, ln+1, 4)
goMLS _fp ('"':'"':'"':cs) ln col acc = Right (T.pack (reverse acc), cs, ln, col+3)
goMLS fp ('\n':cs) ln _col acc = goMLS fp cs (ln+1) 1 ('\n':acc)
goMLS fp (c:cs)    ln col  acc = goMLS fp cs ln (col+1) (c:acc)

-- ---------------------------------------------------------------------------
-- Template literal (single-line)
-- isMulti=False means single-line (can't contain raw newlines)
-- ---------------------------------------------------------------------------

lexFStr :: FilePath -> String -> Int -> Int -> Bool
        -> Either LexError ([FStrPart], String, Int, Int)
lexFStr fp cs ln col isMulti = goFStr fp cs ln col isMulti [] []

goFStr :: FilePath -> String -> Int -> Int -> Bool -> [Char] -> [FStrPart]
       -> Either LexError ([FStrPart], String, Int, Int)
goFStr fp [] ln _col _ _ _ = Left (LexError ("Unterminated template literal at line " ++ show ln))
goFStr _fp ('"':cs) ln col False litAcc partsAcc =
  let parts = finalParts (reverse litAcc) partsAcc
  in Right (parts, cs, ln, col+1)
-- Triple-quote end
goFStr _fp ('"':'"':'"':cs) ln col True litAcc partsAcc =
  let parts = finalParts (reverse litAcc) partsAcc
  in Right (parts, cs, ln, col+3)
goFStr fp ('$':'{':cs) ln col isMulti litAcc partsAcc = do
  (exprToks, r, l', c') <- collectBraced fp cs ln (col+2)
  let litPart = reverse litAcc
      acc' = if null litPart then partsAcc else FStrLit (T.pack litPart) : partsAcc
  goFStr fp r l' c' isMulti [] (FStrExpr exprToks : acc')
goFStr fp ('\\':ec:cs) ln col isMulti litAcc partsAcc =
  goFStr fp cs ln (col+2) isMulti (decodeEscape ec : litAcc) partsAcc
goFStr fp ('\n':cs) ln _col True litAcc partsAcc =
  goFStr fp cs (ln+1) 1 True ('\n':litAcc) partsAcc
goFStr fp ('\n':_) ln _col False _ _ =
  Left (LexError ("Newline in single-line template literal at line " ++ show ln))
goFStr fp (c:cs) ln col isMulti litAcc partsAcc =
  goFStr fp cs ln (col+1) isMulti (c:litAcc) partsAcc

-- Template literal (multiline): after opening f"""
lexFStrMulti :: FilePath -> String -> Int -> Int
             -> Either LexError ([FStrPart], String, Int, Int)
lexFStrMulti fp ('\n':cs) ln _col = goFStr fp cs (ln+1) 1 True [] []
lexFStrMulti fp ('\r':'\n':cs) ln _col = goFStr fp cs (ln+1) 1 True [] []
lexFStrMulti fp _ ln col = Left (LexError ("Multiline template must start with newline at " ++ show ln ++ ":" ++ show col))

finalParts :: String -> [FStrPart] -> [FStrPart]
finalParts litStr acc =
  let acc' = if null litStr then acc else FStrLit (T.pack litStr) : acc
  in reverse acc'

-- Collect tokens inside ${...}
collectBraced :: FilePath -> String -> Int -> Int
              -> Either LexError ([Token], String, Int, Int)
collectBraced fp cs ln col = do
  (inner, rest, l', c') <- goBraced fp cs ln col 0 []
  toks <- lexRaw fp inner ln col []
  let toks' = filter ((/= TKEof) . tokKind) (reverse toks)
  return (toks', rest, l', c')

goBraced :: FilePath -> String -> Int -> Int -> Int -> [Char]
         -> Either LexError (String, String, Int, Int)
goBraced _fp [] ln _col _ _ = Left (LexError ("Unterminated ${} at line " ++ show ln))
goBraced _fp ('}':cs) ln col 0 acc = Right (reverse acc, cs, ln, col+1)
goBraced fp ('{':cs) ln col depth acc = goBraced fp cs ln (col+1) (depth+1) ('{':acc)
goBraced fp ('}':cs) ln col depth acc = goBraced fp cs ln (col+1) (depth-1) ('}':acc)
goBraced fp ('\n':cs) ln _col depth acc = goBraced fp cs (ln+1) 1 depth ('\n':acc)
goBraced fp (c:cs)   ln col  depth acc = goBraced fp cs ln (col+1) depth (c:acc)

-- ---------------------------------------------------------------------------
-- Keyword table
-- ---------------------------------------------------------------------------

keywordOrIdent :: String -> TokKind
keywordOrIdent "val"      = TKVal
keywordOrIdent "let"      = TKLet
keywordOrIdent "task"     = TKTask
keywordOrIdent "if"       = TKIf
keywordOrIdent "else"     = TKElse
keywordOrIdent "match"    = TKMatch
keywordOrIdent "case"     = TKCase
keywordOrIdent "return"   = TKReturn
keywordOrIdent "reply"    = TKReply
keywordOrIdent "next"     = TKNext
keywordOrIdent "break"    = TKBreak
keywordOrIdent "request"  = TKRequest
keywordOrIdent "type"     = TKType
keywordOrIdent "import"   = TKImport
keywordOrIdent "as"       = TKAs
keywordOrIdent "with"     = TKWith
keywordOrIdent "from"     = TKFrom
keywordOrIdent "for"      = TKFor
keywordOrIdent "finally"  = TKFinally
keywordOrIdent "of"       = TKOf
keywordOrIdent "var"      = TKVar
keywordOrIdent "handle"   = TKHandle
keywordOrIdent "external" = TKExternal
keywordOrIdent "par"      = TKPar
keywordOrIdent "null"     = TKNull
keywordOrIdent "true"     = TKBool True
keywordOrIdent "false"    = TKBool False
keywordOrIdent s          = TKIdent (T.pack s)

-- ---------------------------------------------------------------------------
-- Semicolon auto-insertion
-- ---------------------------------------------------------------------------

-- Tokens that suppress semicolon when at end of line
noSemiAfter :: TokKind -> Bool
noSemiAfter tk = tk `elem`
  [ TKLBrace, TKLParen, TKLBracket
  , TKComma
  , TKPlus, TKMinus, TKStar, TKSlash
  , TKEqEq, TKNeq, TKLt, TKGt, TKLe, TKGe
  , TKAmpAmp, TKPipePipe, TKPlusPlus
  , TKEq, TKArrow, TKFatArrow, TKColon, TKWith, TKOf, TKAt, TKDot
  ]

-- Tokens that suppress semicolon when at start of next line
noSemiBefore :: TokKind -> Bool
noSemiBefore tk = tk `elem`
  [ TKDot, TKRParen, TKRBracket, TKRBrace, TKCase
  , TKPipe, TKAmp  -- allow multi-line type unions/intersections
  ]

insertSemicolons :: [Token] -> [Token]
insertSemicolons []  = []
insertSemicolons [t] = [t]
insertSemicolons (t1:t2:ts)
  | tokLine t2 > tokLine t1
  , not (noSemiAfter  (tokKind t1))
  , not (noSemiBefore (tokKind t2))
  = t1 : Token TKSemi (tokLine t1) (tokCol t1 + 1) : insertSemicolons (t2:ts)
  | otherwise
  = t1 : insertSemicolons (t2:ts)
