module Katari.Lexer
  ( Token (..),
    Keyword (..),
    Punctuation (..),
    Operator (..),
    WithPosition (..),
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
import Numeric (readHex)
import Text.Megaparsec hiding (Token, Tokens)
import Text.Megaparsec qualified as MP
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
  -- | Explicit ; or virtual (from insertVirtualSemicolons).
  TokenSemicolon :: Token
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
  KeywordEnum :: Keyword
  KeywordIn :: Keyword
  KeywordInteger :: Keyword
  KeywordBoolean :: Keyword
  KeywordNumber :: Keyword
  KeywordString :: Keyword
  KeywordBy :: Keyword
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

data WithPosition wrapped = WithPosition
  { sourcePosition :: SourcePos,
    tokenLength :: Int,
    value :: wrapped
  }
  deriving (Eq, Ord, Show)

-- ===========================================================================
-- Lexer
-- ===========================================================================

-- | Context stack entry; top of stack selects tokenization mode.
data LexerContext where
  -- | Normal code.
  LexerContextTop :: LexerContext
  -- | Inside single-line template string part (f"...").
  LexerContextTemplate :: LexerContext
  -- | Inside multi-line template string part (f"""...""").
  LexerContextTemplateMultiLine :: LexerContext
  -- | Inside ${...} of a template; Int is current brace nesting depth.
  LexerContextTemplateExpression :: !Int -> LexerContext
  deriving (Eq, Show)

-- | Lexer monad : Parsec with a stack of LexerContext for mode-sensitive lexing.
type Lexer = StateT [LexerContext] (Parsec Void Text)

getTopContext :: Lexer LexerContext
getTopContext = do
  contexts <- get
  pure $ case contexts of
    topmost : _ -> topmost
    [] -> LexerContextTop

pushContext :: LexerContext -> Lexer ()
pushContext context = modify (context :)

popContext :: Lexer ()
popContext = modify (drop 1)

-- | Run the lexer on input. Returns raw tokens (with TokenNewline; no virtual semis yet).
runLexer :: FilePath -> Text -> Either (ParseErrorBundle Text Void) [WithPosition Token]
runLexer = runParser (evalStateT lexAllTokens [LexerContextTop])

lexAllTokens :: Lexer [WithPosition Token]
lexAllTokens = do
  skipInterTokenSpace
  loop
  where
    loop = do
      done <- lift atEnd
      if done
        then return []
        else do
          nextToken <- lexToken
          skipInterTokenSpace
          (nextToken :) <$> loop

-- | Skip whitespace and comments between tokens — but only in LexerContextTop /
-- LexerContextTemplateExpression. Inside template string contexts we don't skip
-- (everything is string content). Newlines are NOT skipped here: they emerge as
-- TokenNewline tokens in lexNormalToken.
skipInterTokenSpace :: Lexer ()
skipInterTokenSpace = do
  context <- getTopContext
  case context of
    LexerContextTemplate -> return ()
    LexerContextTemplateMultiLine -> return ()
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

lexToken :: Lexer (WithPosition Token)
lexToken = do
  startSourcePos <- lift getSourcePos
  startOffset <- lift getOffset
  context <- getTopContext
  parsedToken <- case context of
    LexerContextTemplate -> lexTemplateBodyToken False
    LexerContextTemplateMultiLine -> lexTemplateBodyToken True
    _ -> lexNormalToken
  endOffset <- lift getOffset
  return (WithPosition {sourcePosition = startSourcePos, tokenLength = endOffset - startOffset, value = parsedToken})

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
        LexerContextTemplateExpression depth -> do
          modifyTopContext (\_ -> LexerContextTemplateExpression (depth + 1))
          pure (TokenPunctuation PunctuationLeftBrace)
        _ -> pure (TokenPunctuation PunctuationLeftBrace)
    lexRightBrace context = do
      _ <- lift (char '}')
      case context of
        LexerContextTemplateExpression 0 ->
          popContext >> pure TokenTemplateExpressionClose
        LexerContextTemplateExpression depth -> do
          modifyTopContext (\_ -> LexerContextTemplateExpression (depth - 1))
          pure (TokenPunctuation PunctuationRightBrace)
        _ -> pure (TokenPunctuation PunctuationRightBrace)

modifyTopContext :: (LexerContext -> LexerContext) -> Lexer ()
modifyTopContext modifier = modify $ \case
  (topmost : remaining) -> modifier topmost : remaining
  -- runLexer initialises the context stack with [LexerContextTop], so this
  -- branch is unreachable. Error out rather than silently seed a fresh stack.
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
  "enum" -> Just KeywordEnum
  "in" -> Just KeywordIn
  "integer" -> Just KeywordInteger
  "boolean" -> Just KeywordBoolean
  "number" -> Just KeywordNumber
  "string" -> Just KeywordString
  "by" -> Just KeywordBy
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
        TokenSemicolon <$ char ';',
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
            _ -> fail "invalid \\u escape: expected low surrogate after high surrogate"
        SurrogateLow -> fail "invalid \\u escape: unpaired low surrogate"

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

-- | Token kinds after which a TokenNewline should be replaced with a virtual
-- TokenSemicolon. Go-style rule: insert after identifier / literal / ) / ] /
-- } / break / return / next / null / true / false / template-close / type keyword.
--
-- TokenUnderscore is intentionally excluded: a wildcard as the last token before
-- a newline is very rare and likely a type-annotation head (_: integer).
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
-- with TokenSemicolon inserted at appropriate newlines and TokenNewline tokens removed.
insertVirtualSemicolons :: [WithPosition Token] -> [WithPosition Token]
insertVirtualSemicolons = go Nothing
  where
    go _ [] = []
    go previous (current@(WithPosition _ _ currentToken) : remaining)
      | currentToken == TokenNewline =
          if canInsertAfter previous
            then virtualSemicolon previous : go Nothing remaining
            else go Nothing remaining
      | otherwise = current : go (Just current) remaining

    virtualSemicolon :: Maybe (WithPosition Token) -> WithPosition Token
    virtualSemicolon (Just (WithPosition sourcePos tokenLength _)) = WithPosition sourcePos tokenLength TokenSemicolon
    virtualSemicolon Nothing = error "insertVirtualSemicolons: canInsertAfter Nothing should be False"

    canInsertAfter :: Maybe (WithPosition Token) -> Bool
    canInsertAfter Nothing = False
    canInsertAfter (Just (WithPosition _ _ previousToken)) = case previousToken of
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
    tokens :: [WithPosition Token]
  }
  deriving (Eq, Show)

instance MP.Stream TokenStream where
  type Token TokenStream = WithPosition Token
  type Tokens TokenStream = [WithPosition Token]

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
      . fmap (\(WithPosition _ _ wrappedToken) -> showToken wrappedToken)
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
        TokenSemicolon -> ";"
        TokenNewline -> "\\n"

  tokensLength Proxy = sum . fmap (\(WithPosition _ tokenLength _) -> tokenLength) . NE.toList

instance TraversableStream TokenStream where
  reachOffset targetOffset PosState {..} =
    let allTokens = pstateInput.tokens
        sourceText = pstateInput.input
        remaining = drop (targetOffset - pstateOffset) allTokens
        newSourcePos = case remaining of
          (WithPosition sourcePos _ _ : _) -> sourcePos
          [] -> case reverse allTokens of
            (WithPosition sourcePos tokenLength _ : _) ->
              -- End of last token: move column forward by tokenLength.
              SourcePos (sourceName sourcePos) (sourceLine sourcePos) (mkPos (unPos (sourceColumn sourcePos) + tokenLength))
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
  KeywordEnum -> "enum"
  KeywordIn -> "in"
  KeywordInteger -> "integer"
  KeywordBoolean -> "boolean"
  KeywordNumber -> "number"
  KeywordString -> "string"
  KeywordBy -> "by"

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
