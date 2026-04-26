module Katari.Lexer
  ( Token (..),
    Keyword (..),
    Punctuation (..),
    Operator (..),
    WithSourceSpan (..),
    TokenStream (..),
    runLexer,
    insertVirtualSemicolons,
  )
where

import Control.Monad (void)
import Control.Monad.State.Strict
import Data.Char (chr)
import Data.List.NonEmpty qualified as NE
import Data.Proxy (Proxy (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Katari.AST (Position (..), SourceSpan (..))
import Numeric (readHex, showHex)
import Text.Megaparsec hiding (Token, Tokens)
import Text.Megaparsec qualified as MP
import Katari.Prelude
import Text.Megaparsec.Char
import Text.Megaparsec.Char.Lexer qualified as L

-- ===========================================================================
-- Token types
-- ===========================================================================

data Token where
  TokenIdentifier :: Text -> Token
  -- | Bare underscore; distinct from TokenIdentifier so the parser can treat
  -- wildcards without string comparison.
  TokenUnderscore :: Token
  TokenKeyword :: Keyword -> Token
  TokenIntegerLiteral :: Integer -> Token
  TokenFloatLiteral :: Double -> Token
  TokenStringLiteral :: Text -> Token
  -- | f" or f"""
  TokenTemplateOpen :: Token
  -- | " or """ (closes the template started by TokenTemplateOpen)
  TokenTemplateClose :: Token
  -- | String part of a template literal.
  TokenTemplateString :: Text -> Token
  -- | \${
  TokenTemplateExpressionOpen :: Token
  -- | } matching ${
  TokenTemplateExpressionClose :: Token
  TokenPunctuation :: Punctuation -> Token
  TokenOperator :: Operator -> Token
  -- | Explicit @;@ in source.
  TokenSemicolonExplicit :: Token
  -- | Virtual semicolon inserted by 'insertVirtualSemicolons'.
  TokenSemicolonVirtual :: Token
  -- | Raw \n — intermediate token, eliminated by insertVirtualSemicolons.
  TokenNewline :: Token
  deriving (Eq, Ord, Show)

data Keyword where
  KeywordLet :: Keyword
  KeywordAgent :: Keyword
  KeywordIf :: Keyword
  KeywordElse :: Keyword
  KeywordMatch :: Keyword
  KeywordCase :: Keyword
  KeywordReturn :: Keyword
  KeywordNext :: Keyword
  KeywordBreak :: Keyword
  KeywordReq :: Keyword
  KeywordImport :: Keyword
  KeywordAs :: Keyword
  KeywordWith :: Keyword
  KeywordFrom :: Keyword
  KeywordFor :: Keyword
  KeywordThen :: Keyword
  KeywordVar :: Keyword
  KeywordWhere :: Keyword
  KeywordExt :: Keyword
  KeywordNull :: Keyword
  KeywordTrue :: Keyword
  KeywordFalse :: Keyword
  KeywordData :: Keyword
  KeywordIn :: Keyword
  KeywordInteger :: Keyword
  KeywordBoolean :: Keyword
  KeywordNumber :: Keyword
  KeywordString :: Keyword
  KeywordType :: Keyword
  deriving (Eq, Ord, Show)

data Punctuation where
  PunctuationLeftParenthesis :: Punctuation
  PunctuationRightParenthesis :: Punctuation
  PunctuationLeftBracket :: Punctuation
  PunctuationRightBracket :: Punctuation
  PunctuationLeftBrace :: Punctuation
  PunctuationRightBrace :: Punctuation
  PunctuationComma :: Punctuation
  PunctuationColon :: Punctuation
  PunctuationDot :: Punctuation
  PunctuationAt :: Punctuation
  PunctuationEquals :: Punctuation
  PunctuationArrow :: Punctuation
  PunctuationFatArrow :: Punctuation
  PunctuationPipe :: Punctuation
  deriving (Eq, Ord, Show)

data Operator where
  OperatorAdd :: Operator
  OperatorSubtract :: Operator
  OperatorMultiply :: Operator
  OperatorDivide :: Operator
  OperatorEqual :: Operator
  OperatorNotEqual :: Operator
  OperatorLessThan :: Operator
  OperatorLessOrEqual :: Operator
  OperatorGreaterThan :: Operator
  OperatorGreaterOrEqual :: Operator
  OperatorAnd :: Operator
  OperatorOr :: Operator
  OperatorConcat :: Operator
  OperatorNot :: Operator
  deriving (Eq, Ord, Show)

-- | Token wrapped with the @SourceSpan@ that covers it. Replaces the older
-- (sourcePosition + tokenLength) representation, which produced incorrect
-- end positions for multi-line tokens (template/string literals).
data WithSourceSpan wrapped = WithSourceSpan
  { sourceSpan :: SourceSpan,
    value :: wrapped
  }
  deriving (Eq, Ord, Show)

-- ===========================================================================
-- Lexer
-- ===========================================================================

-- | Lexer mode that overrides default tokenization. Plain top-level code is
-- represented by an empty context stack, so this type only enumerates the
-- mode-altering states.
data LexerContext where
  -- | Inside single-line template string part (f"...").
  LexerContextTemplate :: LexerContext
  -- | Inside multi-line template string part (f"""...""").
  LexerContextTemplateMultiLine :: LexerContext
  -- | Inside ${...} of a template; Int is current brace nesting depth.
  LexerContextTemplateExpression :: !Int -> LexerContext
  deriving (Eq, Show)

-- | Lexer monad : Parsec with a stack of LexerContext for mode-sensitive
-- lexing. Empty stack = top-level (normal code).
type Lexer = StateT [LexerContext] (Parsec Void Text)

-- | Topmost context, or @Nothing@ if the stack is empty (= top-level code).
getTopContext :: Lexer (Maybe LexerContext)
getTopContext = do
  contexts <- get
  pure $ case contexts of
    topmost : _ -> Just topmost
    [] -> Nothing

pushContext :: LexerContext -> Lexer ()
pushContext context = modify (context :)

popContext :: Lexer ()
popContext = modify $ \case
  (_ : remaining) -> remaining
  -- Pop without matching push is a bug. Fail loudly.
  [] -> error "Katari.Lexer.popContext: empty context stack"

-- | Run the lexer on input. Returns raw tokens (with TokenNewline; no virtual
-- semis yet). The input is normalized by replacing @\\r\\n@ with @\\n@ first
-- (CRLF support). The context stack starts empty, representing top-level code.
runLexer :: FilePath -> Text -> Either (ParseErrorBundle Text Void) [WithSourceSpan Token]
runLexer fp = runParser (evalStateT (lexAllTokens fp) []) fp . normalizeNewlines
  where
    normalizeNewlines = T.replace "\r\n" "\n"

lexAllTokens :: FilePath -> Lexer [WithSourceSpan Token]
lexAllTokens fp = do
  skipInterTokenSpace
  loop
  where
    loop = do
      done <- lift atEnd
      if done
        then return []
        else do
          nextToken <- lexToken fp
          skipInterTokenSpace
          (nextToken :) <$> loop

-- | Skip whitespace and comments between tokens — but only at top-level or in
-- a template-expression context. Inside template string contexts (single- or
-- multi-line) we don't skip, because every character is string content.
-- Newlines are NOT skipped here: they emerge as TokenNewline tokens in
-- lexNormalToken.
skipInterTokenSpace :: Lexer ()
skipInterTokenSpace = do
  context <- getTopContext
  case context of
    Just LexerContextTemplate -> return ()
    Just LexerContextTemplateMultiLine -> return ()
    _ -> lift skipHorizontal
  where
    skipHorizontal =
      L.space
        (void (some (oneOf [' ', '\t', '\r'])))
        (L.skipLineComment "//")
        (L.skipBlockCommentNested "/*" "*/")

-- ---------------------------------------------------------------------------
-- Token dispatch
-- ---------------------------------------------------------------------------

-- | Build a @SourceSpan@ from a megaparsec @SourcePos@ pair.
makeSourceSpan :: FilePath -> SourcePos -> SourcePos -> SourceSpan
makeSourceSpan fp startPos endPos =
  SrcSpan
    { filePath = fp,
      start = positionFromSourcePos startPos,
      end = positionFromSourcePos endPos
    }

positionFromSourcePos :: SourcePos -> Position
positionFromSourcePos sp =
  Position
    { line = unPos (sourceLine sp),
      column = unPos (sourceColumn sp)
    }

lexToken :: FilePath -> Lexer (WithSourceSpan Token)
lexToken fp = do
  startSourcePos <- lift getSourcePos
  context <- getTopContext
  parsedToken <- case context of
    Just LexerContextTemplate -> lexTemplateBodyToken False
    Just LexerContextTemplateMultiLine -> lexTemplateBodyToken True
    _ -> lexNormalToken
  endSourcePos <- lift getSourcePos
  return
    WithSourceSpan
      { sourceSpan = makeSourceSpan fp startSourcePos endSourcePos,
        value = parsedToken
      }

-- ---------------------------------------------------------------------------
-- Normal (top-level / inside ${...}) token parsing
-- ---------------------------------------------------------------------------

lexNormalToken :: Lexer Token
lexNormalToken =
  choice
    [ lexNewline,
      lexBrace,
      lexTemplateStart,
      TokenStringLiteral <$> lift (try lexMultilineStringLiteral),
      TokenStringLiteral <$> lift lexStringLiteral,
      lexNumber,
      lexIdentifierOrKeyword,
      lexPunctuationOrOperator
    ]

-- | Emit TokenNewline and consume the \n. Doesn't apply inside template strings
-- (those are handled by lexTemplateBodyToken).
lexNewline :: Lexer Token
lexNewline = TokenNewline <$ lift (char '\n')

-- | Unified handling of `{` and `}` in the normal-token context.
--
-- Behavior depends on the topmost lexer context:
--
--   * LexerContextTemplateExpression 0 + `}` : closes the template expression,
--     pops the context, and emits TokenTemplateExpressionClose.
--   * LexerContextTemplateExpression d + `{` : push depth d+1, emit
--     TokenPunctuation PunctuationLeftBrace.
--   * LexerContextTemplateExpression d + `}` (d > 0): pop depth to d-1,
--     emit TokenPunctuation PunctuationRightBrace.
--   * Any other ctx : plain `{` / `}` → PunctuationLeftBrace / PunctuationRightBrace.
lexBrace :: Lexer Token
lexBrace = do
  context <- getTopContext
  lexLeftBrace context <|> lexRightBrace context
  where
    lexLeftBrace context = do
      _ <- lift (char '{')
      case context of
        Just (LexerContextTemplateExpression depth) -> do
          modifyTopContext (\_ -> LexerContextTemplateExpression (depth + 1))
          pure (TokenPunctuation PunctuationLeftBrace)
        _ -> pure (TokenPunctuation PunctuationLeftBrace)
    lexRightBrace context = do
      _ <- lift (char '}')
      case context of
        Just (LexerContextTemplateExpression 0) ->
          popContext >> pure TokenTemplateExpressionClose
        Just (LexerContextTemplateExpression depth) -> do
          modifyTopContext (\_ -> LexerContextTemplateExpression (depth - 1))
          pure (TokenPunctuation PunctuationRightBrace)
        _ -> pure (TokenPunctuation PunctuationRightBrace)

-- | Replace the topmost context. Errors if the stack is empty (= top-level)
-- because callers only invoke this from within a known mode.
modifyTopContext :: (LexerContext -> LexerContext) -> Lexer ()
modifyTopContext modifier = modify $ \case
  (topmost : remaining) -> modifier topmost : remaining
  [] -> error "Katari.Lexer.modifyTopContext: empty context stack"

-- | Start of a template literal: `f"""` or `f"`.
lexTemplateStart :: Lexer Token
lexTemplateStart = do
  isMultiLine <- lift $ try ((True <$ string "f\"\"\"") <* char '\n') <|> (False <$ string "f\"")
  pushContext (if isMultiLine then LexerContextTemplateMultiLine else LexerContextTemplate)
  return TokenTemplateOpen

-- | Numeric literal: prefer float if `.` or `e/E` is present, else integer.
lexNumber :: Lexer Token
lexNumber =
  lift $
    try (TokenFloatLiteral <$> L.float)
      <|> (TokenIntegerLiteral <$> L.decimal)

-- | Identifier, keyword, or bare underscore. Bare `_` gets its own token so
-- the parser can distinguish wildcard patterns without string comparison.
lexIdentifierOrKeyword :: Lexer Token
lexIdentifierOrKeyword = lift $ do
  firstChar <- letterChar <|> char '_'
  remainingChars <- many (alphaNumChar <|> char '_')
  let text = T.pack (firstChar : remainingChars)
  pure $ case (text, keywordOf text) of
    ("_", _) -> TokenUnderscore
    (_, Just keyword) -> TokenKeyword keyword
    (_, Nothing) -> TokenIdentifier text

keywordOf :: Text -> Maybe Keyword
keywordOf = \case
  "let" -> Just KeywordLet
  "agent" -> Just KeywordAgent
  "if" -> Just KeywordIf
  "else" -> Just KeywordElse
  "match" -> Just KeywordMatch
  "case" -> Just KeywordCase
  "return" -> Just KeywordReturn
  "next" -> Just KeywordNext
  "break" -> Just KeywordBreak
  "req" -> Just KeywordReq
  "import" -> Just KeywordImport
  "as" -> Just KeywordAs
  "with" -> Just KeywordWith
  "from" -> Just KeywordFrom
  "for" -> Just KeywordFor
  "then" -> Just KeywordThen
  "var" -> Just KeywordVar
  "where" -> Just KeywordWhere
  "ext" -> Just KeywordExt
  "null" -> Just KeywordNull
  "true" -> Just KeywordTrue
  "false" -> Just KeywordFalse
  "data" -> Just KeywordData
  "in" -> Just KeywordIn
  "integer" -> Just KeywordInteger
  "boolean" -> Just KeywordBoolean
  "number" -> Just KeywordNumber
  "string" -> Just KeywordString
  "type" -> Just KeywordType
  _ -> Nothing

-- | Punctuation or operator (excluding `{` and `}` which are handled in
-- lexBrace). Multi-char tokens are tried before their shorter prefixes.
lexPunctuationOrOperator :: Lexer Token
lexPunctuationOrOperator =
  lift $
    choice
      [ TokenPunctuation PunctuationArrow <$ string "->",
        TokenPunctuation PunctuationFatArrow <$ string "=>",
        TokenOperator OperatorEqual <$ string "==",
        TokenOperator OperatorNotEqual <$ string "!=",
        TokenOperator OperatorLessOrEqual <$ string "<=",
        TokenOperator OperatorGreaterOrEqual <$ string ">=",
        TokenOperator OperatorAnd <$ string "&&",
        TokenOperator OperatorOr <$ string "||",
        TokenOperator OperatorConcat <$ string "++",
        TokenPunctuation PunctuationLeftParenthesis <$ char '(',
        TokenPunctuation PunctuationRightParenthesis <$ char ')',
        TokenPunctuation PunctuationLeftBracket <$ char '[',
        TokenPunctuation PunctuationRightBracket <$ char ']',
        TokenPunctuation PunctuationComma <$ char ',',
        TokenPunctuation PunctuationColon <$ char ':',
        TokenPunctuation PunctuationDot <$ char '.',
        TokenPunctuation PunctuationAt <$ char '@',
        TokenPunctuation PunctuationEquals <$ char '=',
        TokenPunctuation PunctuationPipe <$ char '|',
        TokenSemicolonExplicit <$ char ';',
        TokenOperator OperatorAdd <$ char '+',
        TokenOperator OperatorSubtract <$ char '-',
        TokenOperator OperatorMultiply <$ char '*',
        TokenOperator OperatorDivide <$ char '/',
        TokenOperator OperatorLessThan <$ char '<',
        TokenOperator OperatorGreaterThan <$ char '>',
        TokenOperator OperatorNot <$ char '!'
      ]

-- ---------------------------------------------------------------------------
-- Template body tokens (inside f"..." or f"""...""")
-- ---------------------------------------------------------------------------

-- | Parse one token within a template string context.
-- We emit either:
--   - TokenTemplateExpressionOpen on ${ (and push LexerContextTemplateExpression 0)
--   - TokenTemplateClose on the closing quote (and pop)
--   - TokenTemplateString Text for a run of string content
lexTemplateBodyToken :: Bool -> Lexer Token
lexTemplateBodyToken isMultiLine =
  choice
    [ lexExpressionOpen,
      lexClose,
      lexStringRun
    ]
  where
    lexExpressionOpen = do
      _ <- lift (string "${")
      pushContext (LexerContextTemplateExpression 0)
      return TokenTemplateExpressionOpen

    lexClose
      | isMultiLine = do
          _ <- lift (try (string "\n\"\"\""))
          popContext
          return TokenTemplateClose
      | otherwise = do
          _ <- lift (char '"')
          popContext
          return TokenTemplateClose

    lexStringRun = do
      chars <- lift (some stringChar)
      return (TokenTemplateString (T.pack chars))

    stringChar
      | isMultiLine = templateStringCharacterMulti
      | otherwise = templateStringCharacterSingle

-- | One character of a single-line template string (no literal newlines).
-- Stops if it sees `${` or `"` (those are separate tokens).
templateStringCharacterSingle :: Parsec Void Text Char
templateStringCharacterSingle =
  notFollowedBy (string "${" <|> string "\"") *> (escapeCharacter <|> noneOf ['\n', '\r'])

-- | One character of a multiline template string (literal newlines allowed).
-- Stops at `${` or the `\n"""` terminator.
templateStringCharacterMulti :: Parsec Void Text Char
templateStringCharacterMulti =
  notFollowedBy (string "${" <|> try (string "\n\"\"\"")) *> (escapeCharacter <|> anySingle)

-- ---------------------------------------------------------------------------
-- String literals
-- ---------------------------------------------------------------------------

lexStringLiteral :: Parsec Void Text Text
lexStringLiteral = do
  _ <- char '"'
  content <- many stringChar
  _ <- char '"'
  return (T.pack content)
  where
    stringChar = escapeCharacter <|> noneOf ['"', '\\', '\n', '\r']

lexMultilineStringLiteral :: Parsec Void Text Text
lexMultilineStringLiteral = do
  _ <- string "\"\"\""
  _ <- char '\n'
  content <- manyTill anySingle (try (char '\n' *> string "\"\"\""))
  return (T.pack content)

-- | JSON-compatible escape sequences plus `\$` for template interpolation.
--
-- Supported: \" \\ \/ \b \f \n \r \t \$ \uXXXX (with surrogate-pair synthesis)
escapeCharacter :: Parsec Void Text Char
escapeCharacter =
  char '\\'
    *> choice
      [ '"' <$ char '"',
        '\\' <$ char '\\',
        '/' <$ char '/',
        '\b' <$ char 'b',
        '\f' <$ char 'f',
        '\n' <$ char 'n',
        '\r' <$ char 'r',
        '\t' <$ char 't',
        '$' <$ char '$',
        unicodeEscape
      ]
  where
    -- \| JSON-style \\uXXXX with surrogate-pair synthesis:
    --
    --   * BMP code point (outside surrogate range) → that Char directly.
    --   * High surrogate (U+D800..U+DBFF) → MUST be immediately followed by
    --     \\uXXXX low surrogate (U+DC00..U+DFFF); combines to U+10000..U+10FFFF.
    --   * Unpaired surrogates are rejected.
    unicodeEscape = do
      _ <- char 'u'
      cp1 <- readFourHex
      case classifySurrogate cp1 of
        SurrogateNone -> pure (chr cp1)
        SurrogateHigh -> do
          _ <- char '\\'
          _ <- char 'u'
          cp2 <- readFourHex
          case classifySurrogate cp2 of
            SurrogateLow ->
              pure (chr (0x10000 + ((cp1 - 0xD800) * 0x400) + (cp2 - 0xDC00)))
            _ -> fail $
              "invalid \\u escape: high surrogate U+" <> showHex cp1 "" <>
              " must be followed by low surrogate U+DC00..U+DFFF, got U+" <> showHex cp2 ""
        SurrogateLow -> fail $
          "invalid \\u escape: unpaired low surrogate U+" <> showHex cp1 ""

    readFourHex = do
      hex1 <- hexDigitChar
      hex2 <- hexDigitChar
      hex3 <- hexDigitChar
      hex4 <- hexDigitChar
      case readHex [hex1, hex2, hex3, hex4] of
        [(codePoint, "")] -> pure codePoint
        _ -> fail "invalid \\u escape"

data SurrogateClass = SurrogateNone | SurrogateHigh | SurrogateLow

classifySurrogate :: Int -> SurrogateClass
classifySurrogate codePoint
  | codePoint >= 0xD800 && codePoint <= 0xDBFF = SurrogateHigh
  | codePoint >= 0xDC00 && codePoint <= 0xDFFF = SurrogateLow
  | otherwise = SurrogateNone

-- ===========================================================================
-- Virtual Semicolon Insertion
-- ===========================================================================

-- | Expression を終端しうるトークン。これらの後に改行があった場合、
-- 'insertVirtualSemicolons' が改行を仮想セミコロンに変換する。
--
-- 採用基準: 「ここで expression の構文要素が完結しているとみなして良い」トークン。
-- 識別子・各種リテラル・閉じ括弧・特定キーワード (break / return / next /
-- null / true / false / 型名キーワード) が該当する。
--
-- TokenUnderscore は意図的に除外: 式位置で `_` 単独はエラー (式にならない)、
-- かつ `_: integer` 型注釈の頭になり得る。よって行末に来た場合に挿入しても
-- 良いケースがほぼ無い。
semicolonInsertingTokens :: Set.Set Token
semicolonInsertingTokens =
  Set.fromList
    [ TokenTemplateClose,
      TokenKeyword KeywordBreak,
      TokenKeyword KeywordReturn,
      TokenKeyword KeywordNext,
      TokenKeyword KeywordNull,
      TokenKeyword KeywordTrue,
      TokenKeyword KeywordFalse,
      TokenKeyword KeywordInteger,
      TokenKeyword KeywordBoolean,
      TokenKeyword KeywordNumber,
      TokenKeyword KeywordString,
      TokenPunctuation PunctuationRightParenthesis,
      TokenPunctuation PunctuationRightBracket,
      TokenPunctuation PunctuationRightBrace
    ]

-- | Transform a raw token list (with TokenNewline tokens) into a token list
-- with TokenSemicolonVirtual inserted at appropriate newlines and TokenNewline
-- tokens removed.
insertVirtualSemicolons :: [WithSourceSpan Token] -> [WithSourceSpan Token]
insertVirtualSemicolons = go Nothing
  where
    go _ [] = []
    go previous (current@(WithSourceSpan _ currentToken) : remaining)
      | currentToken == TokenNewline =
          if canInsertAfter previous
            then virtualSemicolon previous : go Nothing remaining
            else go Nothing remaining
      | otherwise = current : go (Just current) remaining

    virtualSemicolon :: Maybe (WithSourceSpan Token) -> WithSourceSpan Token
    virtualSemicolon (Just (WithSourceSpan span_ _)) = WithSourceSpan span_ TokenSemicolonVirtual
    virtualSemicolon Nothing = error "insertVirtualSemicolons: canInsertAfter Nothing should be False"

    canInsertAfter :: Maybe (WithSourceSpan Token) -> Bool
    canInsertAfter Nothing = False
    canInsertAfter (Just (WithSourceSpan _ previousToken)) = case previousToken of
      TokenIdentifier _ -> True
      TokenIntegerLiteral _ -> True
      TokenFloatLiteral _ -> True
      TokenStringLiteral _ -> True
      _ -> Set.member previousToken semicolonInsertingTokens

-- ===========================================================================
-- Custom megaparsec Stream instance
-- ===========================================================================

data TokenStream = TokenStream
  { input :: Text,
    tokens :: [WithSourceSpan Token]
  }
  deriving (Eq, Show)

instance MP.Stream TokenStream where
  type Token TokenStream = WithSourceSpan Token
  type Tokens TokenStream = [WithSourceSpan Token]

  tokensToChunk Proxy = id
  chunkToTokens Proxy = id
  chunkLength Proxy = length
  chunkEmpty Proxy = null

  take1_ (TokenStream _ []) = Nothing
  take1_ (TokenStream sourceText (firstToken : remainingTokens)) =
    Just (firstToken, TokenStream sourceText remainingTokens)

  takeN_ requestedCount stream@(TokenStream sourceText allTokens)
    | requestedCount <= 0 = Just ([], stream)
    | null allTokens = Nothing
    | otherwise =
        let (taken, remaining) = splitAt requestedCount allTokens
         in Just (taken, TokenStream sourceText remaining)

  takeWhile_ predicate (TokenStream sourceText allTokens) =
    let (taken, remaining) = span predicate allTokens
     in (taken, TokenStream sourceText remaining)

instance VisualStream TokenStream where
  showTokens Proxy =
    concat
      . NE.toList
      . NE.intersperse " "
      . fmap (\(WithSourceSpan _ wrappedToken) -> showToken wrappedToken)
    where
      showToken = \case
        TokenIdentifier text -> T.unpack text
        TokenUnderscore -> "_"
        TokenKeyword keyword -> showKeyword keyword
        TokenIntegerLiteral integer -> show integer
        TokenFloatLiteral double -> show double
        TokenStringLiteral text -> show text
        TokenTemplateOpen -> "f\""
        TokenTemplateClose -> "\""
        TokenTemplateString text -> T.unpack text
        TokenTemplateExpressionOpen -> "${"
        TokenTemplateExpressionClose -> "}"
        TokenPunctuation punctuation -> showPunctuation punctuation
        TokenOperator operator -> showOperator operator
        TokenSemicolonExplicit -> ";"
        TokenSemicolonVirtual -> ";"
        TokenNewline -> "\\n"

  tokensLength Proxy = sum . fmap tokenLengthFromSpan . NE.toList
    where
      tokenLengthFromSpan (WithSourceSpan span_ _) =
        if span_.start.line == span_.end.line
          then max 1 (span_.end.column - span_.start.column)
          else 1

instance TraversableStream TokenStream where
  reachOffset targetOffset PosState {..} =
    let allTokens = pstateInput.tokens
        sourceText = pstateInput.input
        remaining = drop (targetOffset - pstateOffset) allTokens
        newSourcePos = case remaining of
          (WithSourceSpan span_ _ : _) ->
            mkSourcePos span_.filePath span_.start
          [] -> case reverse allTokens of
            (WithSourceSpan span_ _ : _) ->
              mkSourcePos span_.filePath span_.end
            [] -> pstateSourcePos
        linePrefix = linePrefixFor sourceText newSourcePos
        remainingInput = TokenStream sourceText remaining
     in ( Just (T.unpack linePrefix),
          PosState
            { pstateInput = remainingInput,
              pstateOffset = max pstateOffset targetOffset,
              pstateSourcePos = newSourcePos,
              pstateTabWidth = pstateTabWidth,
              pstateLinePrefix = pstateLinePrefix <> T.unpack linePrefix
            }
        )

mkSourcePos :: FilePath -> Position -> SourcePos
mkSourcePos fp p = SourcePos fp (mkPos p.line) (mkPos p.column)

-- | Extract the source line prefix up to (but not including) the column of
-- the given SourcePos. Used to feed megaparsec's error message formatter so
-- it can draw the caret under the offending token.
linePrefixFor :: Text -> SourcePos -> Text
linePrefixFor sourceText sourcePos =
  let lineIndex = unPos (sourceLine sourcePos) - 1
      columnIndex = unPos (sourceColumn sourcePos) - 1
      sourceLines = T.lines sourceText
   in case drop lineIndex sourceLines of
        (lineText : _) -> T.take columnIndex lineText
        [] -> T.empty

showKeyword :: Keyword -> String
showKeyword = \case
  KeywordLet -> "let"
  KeywordAgent -> "agent"
  KeywordIf -> "if"
  KeywordElse -> "else"
  KeywordMatch -> "match"
  KeywordCase -> "case"
  KeywordReturn -> "return"
  KeywordNext -> "next"
  KeywordBreak -> "break"
  KeywordReq -> "req"
  KeywordImport -> "import"
  KeywordAs -> "as"
  KeywordWith -> "with"
  KeywordFrom -> "from"
  KeywordFor -> "for"
  KeywordThen -> "then"
  KeywordVar -> "var"
  KeywordWhere -> "where"
  KeywordExt -> "ext"
  KeywordNull -> "null"
  KeywordTrue -> "true"
  KeywordFalse -> "false"
  KeywordData -> "data"
  KeywordIn -> "in"
  KeywordInteger -> "integer"
  KeywordBoolean -> "boolean"
  KeywordNumber -> "number"
  KeywordString -> "string"
  KeywordType -> "type"

showPunctuation :: Punctuation -> String
showPunctuation = \case
  PunctuationLeftParenthesis -> "("
  PunctuationRightParenthesis -> ")"
  PunctuationLeftBracket -> "["
  PunctuationRightBracket -> "]"
  PunctuationLeftBrace -> "{"
  PunctuationRightBrace -> "}"
  PunctuationComma -> ","
  PunctuationColon -> ":"
  PunctuationDot -> "."
  PunctuationAt -> "@"
  PunctuationEquals -> "="
  PunctuationArrow -> "->"
  PunctuationFatArrow -> "=>"
  PunctuationPipe -> "|"

showOperator :: Operator -> String
showOperator = \case
  OperatorAdd -> "+"
  OperatorSubtract -> "-"
  OperatorMultiply -> "*"
  OperatorDivide -> "/"
  OperatorEqual -> "=="
  OperatorNotEqual -> "!="
  OperatorLessThan -> "<"
  OperatorLessOrEqual -> "<="
  OperatorGreaterThan -> ">"
  OperatorGreaterOrEqual -> ">="
  OperatorAnd -> "&&"
  OperatorOr -> "||"
  OperatorConcat -> "++"
  OperatorNot -> "!"
