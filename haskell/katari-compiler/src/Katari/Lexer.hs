module Katari.Lexer
  ( TokKind (..),
    FStrPart (..),
    Token (..),
    LexError (..),
    lexFile,
  )
where

import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

-- ---------------------------------------------------------------------------
-- Template literal fragments
-- ---------------------------------------------------------------------------

data FStrPart
  = FStrLit Text
  | FStrExpr [Token]
  deriving (Show, Eq, Ord)

-- ---------------------------------------------------------------------------
-- Token kinds
-- ---------------------------------------------------------------------------

data TokKind
  = -- Literals
    TKInt Integer
  | TKNum Double
  | TKStr Text
  | TKBool Bool
  | TKNull
  | TKFStr [FStrPart]
  | -- Keywords
    TKVal
  | TKLet
  | TKAgent
  | TKIf
  | TKElse
  | TKMatch
  | TKCase
  | TKReturn
  | TKContinue
  | TKBreak
  | TKRequest
  | TKType
  | TKImport
  | TKAs
  | TKWith
  | TKFrom
  | TKFor
  | TKThen
  | TKOf
  | TKVar
  | TKHandle
  | TKExternal
  | TKPar
  | -- Identifier
    TKIdent Text
  | -- Multi-char operators (longest match first in lexer)
    TKEqEq
  | TKNeq
  | TKLe
  | TKGe
  | TKAmpAmp
  | TKPipePipe
  | TKPlusPlus
  | TKArrow
  | TKFatArrow
  | -- Single-char operators
    TKPlus
  | TKMinus
  | TKStar
  | TKSlash
  | TKLt
  | TKGt
  | TKBang
  | TKEq
  | TKColon
  | TKDot
  | TKComma
  | TKSemi
  | TKAt
  | TKQuestion
  | TKPipe
  | TKAmp
  | -- Delimiters
    TKLParen
  | TKRParen
  | TKLBrace
  | TKRBrace
  | TKLBracket
  | TKRBracket
  | TKEof
  deriving (Show, Eq, Ord)

-- ---------------------------------------------------------------------------
-- Token
-- ---------------------------------------------------------------------------

data Token = Token
  { tokKind :: TokKind,
    tokLine :: Int,
    tokCol :: Int
  }
  deriving (Show, Eq)

instance Ord Token where
  compare t1 t2 = compare (tokKind t1) (tokKind t2)

-- ---------------------------------------------------------------------------
-- Error
-- ---------------------------------------------------------------------------

newtype LexError = LexError {lexErrMsg :: String}
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
lexRaw fp src ln col acc = case src of
  [] -> Right (Token TKEof ln 0 : acc)
  -- Whitespace / newlines
  '\r' : '\n' : cs -> lexRaw fp cs (ln + 1) 1 acc
  '\r' : cs -> lexRaw fp cs (ln + 1) 1 acc
  '\n' : cs -> lexRaw fp cs (ln + 1) 1 acc
  ' ' : cs -> lexRaw fp cs ln (col + 1) acc
  '\t' : cs -> lexRaw fp cs ln (col + 4) acc
  -- Line comments
  '/' : '/' : cs ->
    let (comment, rest) = span (/= '\n') cs
     in lexRaw fp rest ln (col + 2 + length comment) acc
  -- Block comments
  '/' : '*' : cs -> do
    (r, l', c') <- skipBlockComment cs ln (col + 2)
    lexRaw fp r l' c' acc
  -- Multiline string
  '"' : '"' : '"' : cs -> do
    (s, r, l', c') <- lexMultiStr fp cs ln (col + 3)
    lexRaw fp r l' c' (Token (TKStr s) ln col : acc)
  -- Template literal (multiline)
  'f' : '"' : '"' : '"' : cs -> do
    (ps, r, l', c') <- lexFStrMulti fp cs ln (col + 4)
    lexRaw fp r l' c' (Token (TKFStr ps) ln col : acc)
  -- Template literal (single line)
  'f' : '"' : cs -> do
    (ps, r, l', c') <- lexFStr fp cs ln (col + 2) False
    lexRaw fp r l' c' (Token (TKFStr ps) ln col : acc)
  -- Regular string
  '"' : cs -> do
    (s, r, c') <- lexStr fp cs ln (col + 1) []
    lexRaw fp r ln c' (Token (TKStr s) ln col : acc)
  -- Multi-char operators
  '=' : '>' : cs -> lexRaw fp cs ln (col + 2) (Token TKFatArrow ln col : acc)
  '=' : '=' : cs -> lexRaw fp cs ln (col + 2) (Token TKEqEq ln col : acc)
  '!' : '=' : cs -> lexRaw fp cs ln (col + 2) (Token TKNeq ln col : acc)
  '<' : '=' : cs -> lexRaw fp cs ln (col + 2) (Token TKLe ln col : acc)
  '>' : '=' : cs -> lexRaw fp cs ln (col + 2) (Token TKGe ln col : acc)
  '&' : '&' : cs -> lexRaw fp cs ln (col + 2) (Token TKAmpAmp ln col : acc)
  '|' : '|' : cs -> lexRaw fp cs ln (col + 2) (Token TKPipePipe ln col : acc)
  '+' : '+' : cs -> lexRaw fp cs ln (col + 2) (Token TKPlusPlus ln col : acc)
  '-' : '>' : cs -> lexRaw fp cs ln (col + 2) (Token TKArrow ln col : acc)
  c : cs
    -- Identifiers and keywords
    | isAlpha c || c == '_' ->
        let (rest0, after) = span (\x -> isAlphaNum x || x == '_') cs
            word = c : rest0
         in lexRaw fp after ln (col + length word) (Token (keywordOrIdent word) ln col : acc)
    -- Number literals
    | isDigit c ->
        let (digits, after) = span isDigit cs
            allDigits = c : digits
         in case after of
              '.' : d : after2
                | isDigit d ->
                    let (frac, after3) = span isDigit after2
                        numStr = allDigits ++ "." ++ (d : frac)
                     in lexRaw fp after3 ln (col + length numStr) (Token (TKNum (read numStr)) ln col : acc)
              _ ->
                lexRaw fp after ln (col + length allDigits) (Token (TKInt (read allDigits)) ln col : acc)
    -- Single-char operators / delimiters
    | otherwise -> case singleCharTok c of
        Just tk -> lexRaw fp cs ln (col + 1) (Token tk ln col : acc)
        Nothing ->
          Left (LexError ("Unexpected character " ++ show c ++ " at " ++ show ln ++ ":" ++ show col))

singleCharTok :: Char -> Maybe TokKind
singleCharTok = \case
  '+' -> Just TKPlus
  '-' -> Just TKMinus
  '*' -> Just TKStar
  '/' -> Just TKSlash
  '<' -> Just TKLt
  '>' -> Just TKGt
  '!' -> Just TKBang
  '=' -> Just TKEq
  ':' -> Just TKColon
  '.' -> Just TKDot
  ',' -> Just TKComma
  ';' -> Just TKSemi
  '@' -> Just TKAt
  '?' -> Just TKQuestion
  '|' -> Just TKPipe
  '&' -> Just TKAmp
  '(' -> Just TKLParen
  ')' -> Just TKRParen
  '{' -> Just TKLBrace
  '}' -> Just TKRBrace
  '[' -> Just TKLBracket
  ']' -> Just TKRBracket
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- String helpers
-- ---------------------------------------------------------------------------

skipBlockComment :: String -> Int -> Int -> Either LexError (String, Int, Int)
skipBlockComment src ln col = case src of
  [] -> Left (LexError ("Unterminated block comment at line " ++ show ln))
  '*' : '/' : cs -> Right (cs, ln, col + 2)
  '/' : '*' : cs -> case skipBlockComment cs ln (col + 2) of
    Left e -> Left e
    Right (r, l', c') -> skipBlockComment r l' c'
  '\n' : cs -> skipBlockComment cs (ln + 1) 1
  _ : cs -> skipBlockComment cs ln (col + 1)

lexStr :: FilePath -> String -> Int -> Int -> [Char] -> Either LexError (Text, String, Int)
lexStr fp src ln col acc = case src of
  [] -> Left (LexError ("Unterminated string at line " ++ show ln))
  '"' : cs -> Right (T.pack (reverse acc), cs, col + 1)
  '\\' : c : cs -> lexStr fp cs ln (col + 2) (decodeEscape c : acc)
  c : cs -> lexStr fp cs ln (col + 1) (c : acc)

decodeEscape :: Char -> Char
decodeEscape = \case
  'n' -> '\n'
  't' -> '\t'
  'r' -> '\r'
  '\\' -> '\\'
  '"' -> '"'
  '$' -> '$'
  c -> c

-- Multiline string: after opening """
-- spec: first and last newline not included
lexMultiStr :: FilePath -> String -> Int -> Int -> Either LexError (Text, String, Int, Int)
lexMultiStr fp src ln col = case src of
  '\n' : cs -> goMLS fp cs (ln + 1) 1 []
  '\r' : '\n' : cs -> goMLS fp cs (ln + 1) 1 []
  _ -> Left (LexError ("Multiline string must start with newline at " ++ show ln ++ ":" ++ show col))

goMLS :: FilePath -> String -> Int -> Int -> [Char] -> Either LexError (Text, String, Int, Int)
goMLS fp src ln col acc = case src of
  [] -> Left (LexError ("Unterminated multiline string at line " ++ show ln))
  '\n' : '"' : '"' : '"' : cs -> Right (T.pack (reverse acc), cs, ln + 1, 4)
  '"' : '"' : '"' : cs -> Right (T.pack (reverse acc), cs, ln, col + 3)
  '\n' : cs -> goMLS fp cs (ln + 1) 1 ('\n' : acc)
  c : cs -> goMLS fp cs ln (col + 1) (c : acc)

-- ---------------------------------------------------------------------------
-- Template literal (single-line)
-- isMulti=False means single-line (can't contain raw newlines)
-- ---------------------------------------------------------------------------

lexFStr ::
  FilePath ->
  String ->
  Int ->
  Int ->
  Bool ->
  Either LexError ([FStrPart], String, Int, Int)
lexFStr fp cs ln col isMulti = goFStr fp cs ln col isMulti [] []

goFStr ::
  FilePath ->
  String ->
  Int ->
  Int ->
  Bool ->
  [Char] ->
  [FStrPart] ->
  Either LexError ([FStrPart], String, Int, Int)
goFStr fp src ln col isMulti litAcc partsAcc = case src of
  [] -> Left (LexError ("Unterminated template literal at line " ++ show ln))
  '"' : '"' : '"' : cs
    | isMulti ->
        let parts = finalParts (reverse litAcc) partsAcc
         in Right (parts, cs, ln, col + 3)
  '"' : cs
    | not isMulti ->
        let parts = finalParts (reverse litAcc) partsAcc
         in Right (parts, cs, ln, col + 1)
  '$' : '{' : cs -> do
    (exprToks, r, l', c') <- collectBraced fp cs ln (col + 2)
    let litPart = reverse litAcc
        acc' = if null litPart then partsAcc else FStrLit (T.pack litPart) : partsAcc
    goFStr fp r l' c' isMulti [] (FStrExpr exprToks : acc')
  '\\' : ec : cs ->
    goFStr fp cs ln (col + 2) isMulti (decodeEscape ec : litAcc) partsAcc
  '\n' : cs
    | isMulti -> goFStr fp cs (ln + 1) 1 True ('\n' : litAcc) partsAcc
    | otherwise -> Left (LexError ("Newline in single-line template literal at line " ++ show ln))
  c : cs -> goFStr fp cs ln (col + 1) isMulti (c : litAcc) partsAcc

-- Template literal (multiline): after opening f"""
lexFStrMulti ::
  FilePath ->
  String ->
  Int ->
  Int ->
  Either LexError ([FStrPart], String, Int, Int)
lexFStrMulti fp src ln col = case src of
  '\n' : cs -> goFStr fp cs (ln + 1) 1 True [] []
  '\r' : '\n' : cs -> goFStr fp cs (ln + 1) 1 True [] []
  _ -> Left (LexError ("Multiline template must start with newline at " ++ show ln ++ ":" ++ show col))

finalParts :: String -> [FStrPart] -> [FStrPart]
finalParts litStr acc =
  let acc' = if null litStr then acc else FStrLit (T.pack litStr) : acc
   in reverse acc'

-- Collect tokens inside ${...}
collectBraced ::
  FilePath ->
  String ->
  Int ->
  Int ->
  Either LexError ([Token], String, Int, Int)
collectBraced fp cs ln col = do
  (inner, rest, l', c') <- goBraced fp cs ln col 0 []
  toks <- lexRaw fp inner ln col []
  let toks' = reverse (filter ((/= TKEof) . tokKind) toks)
  return (toks', rest, l', c')

goBraced ::
  FilePath ->
  String ->
  Int ->
  Int ->
  Int ->
  [Char] ->
  Either LexError (String, String, Int, Int)
goBraced fp src ln col depth acc = case src of
  [] -> Left (LexError ("Unterminated ${} at line " ++ show ln))
  '}' : cs
    | depth == 0 -> Right (reverse acc, cs, ln, col + 1)
    | otherwise -> goBraced fp cs ln (col + 1) (depth - 1) ('}' : acc)
  '{' : cs -> goBraced fp cs ln (col + 1) (depth + 1) ('{' : acc)
  '\n' : cs -> goBraced fp cs (ln + 1) 1 depth ('\n' : acc)
  c : cs -> goBraced fp cs ln (col + 1) depth (c : acc)

-- ---------------------------------------------------------------------------
-- Keyword table
-- ---------------------------------------------------------------------------

keywordOrIdent :: String -> TokKind
keywordOrIdent = \case
  "val" -> TKVal
  "let" -> TKLet
  "agent" -> TKAgent
  "if" -> TKIf
  "else" -> TKElse
  "match" -> TKMatch
  "case" -> TKCase
  "return" -> TKReturn
  "continue" -> TKContinue
  "break" -> TKBreak
  "request" -> TKRequest
  "type" -> TKType
  "import" -> TKImport
  "as" -> TKAs
  "with" -> TKWith
  "from" -> TKFrom
  "for" -> TKFor
  "then" -> TKThen
  "of" -> TKOf
  "var" -> TKVar
  "handle" -> TKHandle
  "external" -> TKExternal
  "par" -> TKPar
  "null" -> TKNull
  "true" -> TKBool True
  "false" -> TKBool False
  s -> TKIdent (T.pack s)

-- ---------------------------------------------------------------------------
-- Semicolon auto-insertion
-- ---------------------------------------------------------------------------

-- Tokens that suppress semicolon when at end of line
noSemiAfter :: TokKind -> Bool
noSemiAfter = (`Set.member` noSemiAfterSet)

noSemiAfterSet :: Set TokKind
noSemiAfterSet =
  Set.fromList
    [ TKLBrace, TKLParen, TKLBracket, TKComma,
      TKPlus, TKMinus, TKStar, TKSlash,
      TKEqEq, TKNeq, TKLt, TKGt, TKLe, TKGe,
      TKAmpAmp, TKPipePipe, TKPlusPlus,
      TKEq, TKArrow, TKFatArrow,
      TKColon, TKWith, TKOf, TKAt, TKDot
    ]

-- Tokens that suppress semicolon when at start of next line
noSemiBefore :: TokKind -> Bool
noSemiBefore = (`Set.member` noSemiBeforeSet)

noSemiBeforeSet :: Set TokKind
noSemiBeforeSet =
  Set.fromList
    [ TKDot, TKRParen, TKRBracket, TKRBrace,
      TKCase, TKElse, TKThen, TKOf,
      TKPipe, TKAmp
    ]

insertSemicolons :: [Token] -> [Token]
insertSemicolons = \case
  [] -> []
  [t] -> [t]
  t1 : t2 : ts
    | tokLine t2 > tokLine t1,
      not (noSemiAfter (tokKind t1)),
      not (noSemiBefore (tokKind t2)) ->
        t1 : Token TKSemi (tokLine t1) (tokCol t1 + 1) : insertSemicolons (t2 : ts)
    | otherwise ->
        t1 : insertSemicolons (t2 : ts)
