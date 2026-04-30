module Katari.Lexer
  ( Token (..),
    Keyword (..),
    Punctuation (..),
    Operator (..),
    WithSourceSpan (..),
    TokenStream (..),
    LexerError (..),
    toDiagnostic,
    runLexer,
    insertVirtualSemicolons,
    showKeyword,
    showPunctuation,
    showOperator,
    showToken,
  )
where

import Control.Monad (void, when)
import Control.Monad.State.Strict
import Data.Char (chr)
import Data.List.NonEmpty qualified as NE
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Katari.AST (HasSourceSpan (..), Position (..), SourceSpan (..))
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Numeric (readHex, showHex)
import Text.Megaparsec hiding (State, Token, Tokens)
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
  KeywordNever :: Keyword
  KeywordUnknown :: Keyword
  deriving (Eq, Ord, Show, Bounded, Enum)

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

-- | Structured lexer error. The compiler core emits these without rendering
-- to text; rendering belongs to 'Katari.Diagnostics'. Each variant is rich
-- enough that LSP can offer code actions or i18n alternative wordings without
-- re-parsing strings.
data LexerError where
  -- | An @f"..."@ or @f"""...\"\"\"@ literal hit EOF before the closing
  -- quote / triple-quote was seen. The span covers the start of the literal
  -- (or the recovery point) to the synthesized close.
  LexerErrorUnterminatedTemplate :: SourceSpan -> LexerError
  -- | A normal @"..."@ literal was not closed before EOF or an embedded
  -- newline. Recovery synthesizes a close at the discovery point.
  LexerErrorUnterminatedString :: SourceSpan -> LexerError
  -- | A @\\uXXXX@ escape (or a high/low surrogate pair) was malformed. The
  -- 'Text' is the offending raw fragment for diagnostics; recovery substitutes
  -- the Unicode replacement character (U+FFFD).
  LexerErrorInvalidUnicodeEscape :: SourceSpan -> Text -> LexerError
  -- | A character that doesn't start any known token. Recovery skips the
  -- single character and continues.
  LexerErrorUnrecognizedCharacter :: SourceSpan -> Char -> LexerError

deriving instance Eq LexerError

deriving instance Show LexerError

instance HasSourceSpan LexerError where
  sourceSpanOf = \case
    LexerErrorUnterminatedTemplate sp -> sp
    LexerErrorUnterminatedString sp -> sp
    LexerErrorInvalidUnicodeEscape sp _ -> sp
    LexerErrorUnrecognizedCharacter sp _ -> sp

-- | Convert a 'LexerError' to a unified 'Diagnostic'. Codes K0001-K0019
-- are reserved for the lexer.
toDiagnostic :: LexerError -> Diagnostic
toDiagnostic = \case
  LexerErrorUnterminatedTemplate sp ->
    diagnosticError "K0001" "unterminated template literal" sp
  LexerErrorUnterminatedString sp ->
    diagnosticError "K0002" "unterminated string literal" sp
  LexerErrorInvalidUnicodeEscape sp raw ->
    diagnosticError
      "K0003"
      ("invalid unicode escape sequence: " <> raw)
      sp
  LexerErrorUnrecognizedCharacter sp ch ->
    diagnosticError
      "K0004"
      ("unrecognized character: " <> T.singleton ch)
      sp

-- | Mutable lexer state: the template-context stack plus an accumulator of
-- errors discovered through @withRecovery@. Errors are kept in reverse order
-- of discovery and reversed once at the end.
data LexerState = LexerState
  { contextStack :: [LexerContext],
    accumulatedErrors :: [LexerError]
  }

initialLexerState :: LexerState
initialLexerState = LexerState {contextStack = [], accumulatedErrors = []}

-- | Lexer monad : ParsecT layered over a State monad carrying the
-- mode-sensitive context stack and the rolling list of recovered errors.
-- Idiomatic megaparsec ordering (ParsecT outermost) so character primitives
-- and 'withRecovery' are usable without explicit lifts.
type Lexer = ParsecT Void Text (State LexerState)

-- | Topmost context, or @Nothing@ if the stack is empty (= top-level code).
getTopContext :: Lexer (Maybe LexerContext)
getTopContext = do
  state_ <- get
  pure $ case state_.contextStack of
    topmost : _ -> Just topmost
    [] -> Nothing

pushContext :: LexerContext -> Lexer ()
pushContext context = modify' $ \LexerState {..} ->
  LexerState {contextStack = context : contextStack, ..}

-- | Pop the topmost context. Empty-stack pops are *silently ignored* rather
-- than panicking — they only happen when recovery synthesizes a close for an
-- already-popped (or never-pushed) context, and treating that as a hard error
-- would defeat the point of recovery. The resulting incoherence is bounded:
-- subsequent token lexing simply runs in @Nothing@ context (= top-level).
popContext :: Lexer ()
popContext = modify' $ \state_ -> case state_.contextStack of
  (_ : remaining) -> state_ {contextStack = remaining}
  [] -> state_

-- | Append a recovered error to the accumulator (kept in reverse order).
recordLexerError :: LexerError -> Lexer ()
recordLexerError err = modify' $ \LexerState {..} ->
  LexerState {accumulatedErrors = err : accumulatedErrors, ..}

-- | Run the lexer on input. Returns the (possibly partial) token list and
-- any errors recovered via @withRecovery@.
--
-- The lexer no longer hard-fails on malformed input: unterminated literals
-- get synthesized closing tokens, invalid escape sequences become U+FFFD,
-- and unrecognized characters are skipped one-at-a-time. The input is
-- normalized by replacing @\\r\\n@ with @\\n@ first (CRLF support).
--
-- The 'Either' from megaparsec's @runParser@ is collapsed: a hard failure
-- (which the recovery design tries hard to avoid) yields an empty token
-- list. Any errors accumulated up to that point are still returned.
runLexer :: FilePath -> Text -> ([WithSourceSpan Token], [LexerError])
runLexer filePath input =
  let normalized = T.replace "\r\n" "\n" input
      (eRes, finalState) =
        runState
          (runParserT (lexAllTokens filePath) filePath normalized)
          initialLexerState
   in case eRes of
        Right tokens_ -> (tokens_, reverse finalState.accumulatedErrors)
        Left _ -> ([], reverse finalState.accumulatedErrors)

lexAllTokens :: FilePath -> Lexer [WithSourceSpan Token]
lexAllTokens filePath = do
  skipInterTokenSpace
  loop
  where
    loop = do
      done <- atEnd
      if done
        then return []
        else do
          maybeToken <- lexToken filePath
          skipInterTokenSpace
          case maybeToken of
            Nothing -> loop
            Just tok -> (tok :) <$> loop

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
    _ -> skipHorizontal
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
makeSourceSpan filePath startPos endPos =
  SrcSpan
    { filePath = filePath,
      start = positionFromSourcePos startPos,
      end = positionFromSourcePos endPos
    }

positionFromSourcePos :: SourcePos -> Position
positionFromSourcePos sourcePos =
  Position
    { line = unPos (sourceLine sourcePos),
      column = unPos (sourceColumn sourcePos)
    }

-- | Lex a single token. Returns 'Nothing' when recovery skipped a malformed
-- character without producing any token (the outer loop in 'lexAllTokens'
-- continues from there).
lexToken :: FilePath -> Lexer (Maybe (WithSourceSpan Token))
lexToken filePath = do
  startSourcePos <- getSourcePos
  context <- getTopContext
  parsedToken <- case context of
    Just LexerContextTemplate -> Just <$> lexTemplateBodyToken False
    Just LexerContextTemplateMultiLine -> Just <$> lexTemplateBodyToken True
    _ -> lexNormalToken filePath startSourcePos
  endSourcePos <- getSourcePos
  pure $
    fmap
      ( \tok ->
          WithSourceSpan
            { sourceSpan = makeSourceSpan filePath startSourcePos endSourcePos,
              value = tok
            }
      )
      parsedToken

-- ---------------------------------------------------------------------------
-- Normal (top-level / inside ${...}) token parsing
-- ---------------------------------------------------------------------------

-- | Try every recognised top-level token producer; if none match, fall back
-- to 'lexUnrecognizedCharacter' which records an error and returns
-- 'Nothing'. This guarantees forward progress: the outer loop never spins
-- on a malformed character.
lexNormalToken :: FilePath -> SourcePos -> Lexer (Maybe Token)
lexNormalToken filePath startSourcePos =
  choice
    [ Just <$> lexNewline,
      Just <$> lexBrace,
      Just <$> lexTemplateStart,
      Just . TokenStringLiteral <$> try lexMultilineStringLiteral,
      Just . TokenStringLiteral <$> recoverableStringLiteral filePath startSourcePos,
      Just <$> lexNumber,
      Just <$> lexIdentifierOrKeyword,
      Just <$> lexPunctuationOrOperator,
      lexUnrecognizedCharacter filePath startSourcePos
    ]

-- | Emit TokenNewline and consume the \n. Doesn't apply inside template strings
-- (those are handled by lexTemplateBodyToken).
lexNewline :: Lexer Token
lexNewline = TokenNewline <$ char '\n'

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
      _ <- char '{'
      case context of
        Just (LexerContextTemplateExpression depth) -> do
          modifyTopContext (\_ -> LexerContextTemplateExpression (depth + 1))
          pure (TokenPunctuation PunctuationLeftBrace)
        _ -> pure (TokenPunctuation PunctuationLeftBrace)
    lexRightBrace context = do
      _ <- char '}'
      case context of
        Just (LexerContextTemplateExpression 0) ->
          popContext >> pure TokenTemplateExpressionClose
        Just (LexerContextTemplateExpression depth) -> do
          modifyTopContext (\_ -> LexerContextTemplateExpression (depth - 1))
          pure (TokenPunctuation PunctuationRightBrace)
        _ -> pure (TokenPunctuation PunctuationRightBrace)

-- | Replace the topmost context. Empty-stack updates are silently ignored
-- (the only caller paths reach this from a known mode; if recovery removed
-- the context already we'd rather no-op than panic).
modifyTopContext :: (LexerContext -> LexerContext) -> Lexer ()
modifyTopContext modifier = modify' $ \state_ -> case state_.contextStack of
  (topmost : remaining) -> state_ {contextStack = modifier topmost : remaining}
  [] -> state_

-- | Start of a template literal: `f"""` or `f"`.
--
-- For multi-line `f"""`, a newline must immediately follow. Missing newline
-- is recovered by recording a 'LexerErrorUnterminatedTemplate' and pushing
-- the context anyway — body lexing then proceeds as if the newline had
-- been there.
lexTemplateStart :: Lexer Token
lexTemplateStart = do
  startSourcePos <- getSourcePos
  isMultiLine <-
    choice
      [ True <$ try (string "f\"\"\""),
        False <$ string "f\""
      ]
  when isMultiLine $ do
    consumed <- optional (char '\n')
    case consumed of
      Just _ -> pure ()
      Nothing -> do
        endSourcePos <- getSourcePos
        recordLexerError
          (LexerErrorUnterminatedTemplate (spanBetween startSourcePos endSourcePos))
  pushContext (if isMultiLine then LexerContextTemplateMultiLine else LexerContextTemplate)
  pure TokenTemplateOpen

-- | Fallback for 'lexNormalToken': if no other producer matched, consume one
-- character, record a 'LexerErrorUnrecognizedCharacter', and return
-- 'Nothing' so the outer loop continues without emitting a token.
lexUnrecognizedCharacter :: FilePath -> SourcePos -> Lexer (Maybe Token)
lexUnrecognizedCharacter _filePath startSourcePos = do
  c <- anySingle
  endSourcePos <- getSourcePos
  recordLexerError
    (LexerErrorUnrecognizedCharacter (spanBetween startSourcePos endSourcePos) c)
  pure Nothing

-- | Numeric literal: prefer float if `.` or `e/E` is present, else integer.
lexNumber :: Lexer Token
lexNumber =
  label
    "numeric literal"
    (try (TokenFloatLiteral <$> L.float) <|> TokenIntegerLiteral <$> L.decimal)

-- | Identifier, keyword, or bare underscore. Bare `_` gets its own token so
-- the parser can distinguish wildcard patterns without string comparison.
lexIdentifierOrKeyword :: Lexer Token
lexIdentifierOrKeyword = label "identifier or keyword" $ do
  firstChar <- letterChar <|> char '_'
  remainingChars <- many (alphaNumChar <|> char '_')
  let text = T.pack (firstChar : remainingChars)
  pure $ case (text, keywordOf text) of
    ("_", _) -> TokenUnderscore
    (_, Just keyword) -> TokenKeyword keyword
    (_, Nothing) -> TokenIdentifier text

-- | Surface text of every keyword. Single source of truth shared by the
-- lexer's identifier-or-keyword classifier ('keywordOf') and the diagnostic
-- pretty-printer ('showKeyword').
keywordText :: Keyword -> Text
keywordText = \case
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
  KeywordNever -> "never"
  KeywordUnknown -> "unknown"

-- | Reverse lookup: surface text → 'Keyword'. Built from 'keywordText' so
-- adding a new keyword only requires extending the single table above.
keywordOf :: Text -> Maybe Keyword
keywordOf name = lookup name [(keywordText kw, kw) | kw <- [minBound .. maxBound]]

-- | Punctuation or operator (excluding `{` and `}` which are handled in
-- lexBrace). Multi-char tokens are tried before their shorter prefixes.
lexPunctuationOrOperator :: Lexer Token
lexPunctuationOrOperator =
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
--
-- Recovery: if none of the three branches match (the only realistic case is
-- EOF before the closing quote was seen), record an
-- 'LexerErrorUnterminatedTemplate' and synthesise a 'TokenTemplateClose' so
-- the outer parse keeps a coherent template-token sequence. The popped
-- context lets subsequent tokens lex as normal code.
lexTemplateBodyToken :: Bool -> Lexer Token
lexTemplateBodyToken isMultiLine = do
  startSourcePos <- getSourcePos
  withRecovery (handler startSourcePos) $
    choice
      [ lexExpressionOpen,
        lexClose,
        lexStringRun
      ]
  where
    lexExpressionOpen = do
      _ <- string "${"
      pushContext (LexerContextTemplateExpression 0)
      pure TokenTemplateExpressionOpen

    lexClose
      | isMultiLine = do
          _ <- try (string "\n\"\"\"")
          popContext
          pure TokenTemplateClose
      | otherwise = do
          _ <- char '"'
          popContext
          pure TokenTemplateClose

    lexStringRun = do
      chars <- some stringChar
      pure (TokenTemplateString (T.pack chars))

    stringChar
      | isMultiLine = templateStringCharacterMulti
      | otherwise = templateStringCharacterSingle

    handler startSourcePos _err = do
      endSourcePos <- getSourcePos
      recordLexerError
        (LexerErrorUnterminatedTemplate (spanBetween startSourcePos endSourcePos))
      popContext
      pure TokenTemplateClose

-- | One character of a single-line template string (no literal newlines).
-- Stops if it sees `${` or `"` (those are separate tokens).
templateStringCharacterSingle :: Lexer Char
templateStringCharacterSingle =
  notFollowedBy (string "${" <|> string "\"")
    *> (escapeCharacter <|> noneOf ['\n', '\r'])

-- | One character of a multiline template string (literal newlines allowed).
-- Stops at `${` or the `\n"""` terminator.
templateStringCharacterMulti :: Lexer Char
templateStringCharacterMulti =
  notFollowedBy (string "${" <|> try (string "\n\"\"\""))
    *> (escapeCharacter <|> anySingle)

-- ---------------------------------------------------------------------------
-- String literals (Lexer monadic so escape recovery can record errors)
-- ---------------------------------------------------------------------------

-- | Helper: build a 'SourceSpan' from two megaparsec source positions. The
-- file path is recovered from 'sourceName' so we don't have to thread
-- 'FilePath' through every internal helper.
spanBetween :: SourcePos -> SourcePos -> SourceSpan
spanBetween start_ end_ =
  SrcSpan
    { filePath = sourceName start_,
      start = positionFromSourcePos start_,
      end = positionFromSourcePos end_
    }

-- | Recoverable string literal parser.
--
-- The opening @"@ must be consumed BEFORE @withRecovery@ engages — otherwise
-- the recovery handler would succeed on any input that doesn't start with a
-- quote, returning an empty string without consuming anything. That breaks
-- forward progress in 'lexNormalToken'\'s 'choice'. So we commit to the
-- string-literal path first, then wrap only the body+closing-quote in
-- recovery.
recoverableStringLiteral :: FilePath -> SourcePos -> Lexer Text
recoverableStringLiteral _filePath startSourcePos = do
  _ <- char '"'
  withRecovery handler stringBody
  where
    stringBody = do
      content <- many stringChar
      _ <- char '"'
      pure (T.pack content)
    stringChar = escapeCharacter <|> noneOf ['"', '\\', '\n', '\r']
    handler _ = do
      endSourcePos <- getSourcePos
      recordLexerError
        (LexerErrorUnterminatedString (spanBetween startSourcePos endSourcePos))
      pure T.empty

-- | Recoverable multi-line string literal (@"""...\n...\n"""@).
--
-- The opener (@"""@ + @\n@) is consumed BEFORE @withRecovery@ engages, for
-- the same reason as 'recoverableStringLiteral': a recovery handler that
-- runs without first consuming a unique prefix would let any input pretend
-- to be an empty multi-line string and break forward progress in
-- 'lexNormalToken''s 'choice'. The caller's outer @try@ handles the case
-- where the opener doesn't match (e.g. the input was actually a single-line
-- @"..."@ string).
lexMultilineStringLiteral :: Lexer Text
lexMultilineStringLiteral = do
  startSourcePos <- getSourcePos
  _ <- string "\"\"\""
  _ <- char '\n'
  withRecovery (handler startSourcePos) body
  where
    body = do
      content <- manyTill anySingle (try (char '\n' *> string "\"\"\""))
      pure (T.pack content)
    handler startSourcePos _ = do
      endSourcePos <- getSourcePos
      recordLexerError
        (LexerErrorUnterminatedString (spanBetween startSourcePos endSourcePos))
      pure T.empty

-- | JSON-compatible escape sequences plus `\$` for template interpolation.
--
-- Supported: \" \\ \/ \b \f \n \r \t \$ \uXXXX (with surrogate-pair synthesis)
--
-- This lives in 'Lexer' (rather than pure 'Parsec') so invalid escape paths
-- can record a 'LexerErrorInvalidUnicodeEscape' and recover with U+FFFD
-- instead of failing the surrounding string parse.
escapeCharacter :: Lexer Char
escapeCharacter = do
  _ <- char '\\'
  choice
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
    --   * Unpaired surrogates are rejected — recovery records the error and
    --     substitutes the Unicode replacement character (U+FFFD).
    unicodeEscape = do
      startSourcePos <- getSourcePos
      _ <- char 'u'
      firstCodePoint <- readFourHex startSourcePos
      case classifySurrogate firstCodePoint of
        SurrogateClassNone -> pure (chr firstCodePoint)
        SurrogateClassHigh -> do
          followedByLow <-
            optional . try $ do
              _ <- char '\\'
              _ <- char 'u'
              hex1 <- hexDigitChar
              hex2 <- hexDigitChar
              hex3 <- hexDigitChar
              hex4 <- hexDigitChar
              case readHex [hex1, hex2, hex3, hex4] of
                [(codePoint, "")] -> pure codePoint
                _ -> empty
          endSourcePos <- getSourcePos
          case followedByLow of
            Just secondCodePoint
              | SurrogateClassLow <- classifySurrogate secondCodePoint ->
                  pure
                    ( chr
                        ( 0x10000
                            + (firstCodePoint - 0xD800) * 0x400
                            + (secondCodePoint - 0xDC00)
                        )
                    )
            _ -> do
              recordLexerError
                ( LexerErrorInvalidUnicodeEscape
                    (spanBetween startSourcePos endSourcePos)
                    (T.pack ("\\u" <> showHex firstCodePoint ""))
                )
              pure '\xFFFD'
        SurrogateClassLow -> do
          endSourcePos <- getSourcePos
          recordLexerError
            ( LexerErrorInvalidUnicodeEscape
                (spanBetween startSourcePos endSourcePos)
                (T.pack ("\\u" <> showHex firstCodePoint ""))
            )
          pure '\xFFFD'

    readFourHex startSourcePos = do
      maybeHex <-
        optional . try $ do
          hex1 <- hexDigitChar
          hex2 <- hexDigitChar
          hex3 <- hexDigitChar
          hex4 <- hexDigitChar
          pure [hex1, hex2, hex3, hex4]
      case maybeHex of
        Just hex
          | [(codePoint, "")] <- readHex hex -> pure codePoint
        _ -> do
          endSourcePos <- getSourcePos
          recordLexerError
            ( LexerErrorInvalidUnicodeEscape
                (spanBetween startSourcePos endSourcePos)
                (T.pack "\\u????")
            )
          pure 0xFFFD

data SurrogateClass where
  SurrogateClassNone :: SurrogateClass
  SurrogateClassHigh :: SurrogateClass
  SurrogateClassLow :: SurrogateClass

classifySurrogate :: Int -> SurrogateClass
classifySurrogate codePoint
  | codePoint >= 0xD800 && codePoint <= 0xDBFF = SurrogateClassHigh
  | codePoint >= 0xDC00 && codePoint <= 0xDFFF = SurrogateClassLow
  | otherwise = SurrogateClassNone

-- ===========================================================================
-- Virtual Semicolon Insertion
-- ===========================================================================

-- | Transform a raw token list (with TokenNewline tokens) into a token list
-- with TokenSemicolonVirtual inserted at appropriate newlines and TokenNewline
-- tokens removed.
--
-- 採用基準: 「ここで expression の構文要素が完結しているとみなして良い」トークン
-- の直後の改行のみ仮想セミコロンに変換する。識別子・各種リテラル・閉じ括弧・
-- 特定キーワード (break / return / next / null / true / false / 型名キーワード)
-- が該当。
--
-- TokenUnderscore は意図的に除外: 式位置で `_` 単独はエラー (式にならない)、
-- かつ `_: integer` 型注釈の頭になり得る。よって行末に来た場合に挿入しても
-- 良いケースがほぼ無い。
insertVirtualSemicolons :: [WithSourceSpan Token] -> [WithSourceSpan Token]
insertVirtualSemicolons = go Nothing
  where
    go _ [] = []
    go previous (current@(WithSourceSpan _ currentToken) : remaining)
      | currentToken == TokenNewline = case previous of
          Just (WithSourceSpan span_ previousToken)
            | canInsertAfter previousToken ->
                WithSourceSpan span_ TokenSemicolonVirtual : go Nothing remaining
          _ -> go Nothing remaining
      | otherwise = current : go (Just current) remaining

    canInsertAfter :: Token -> Bool
    canInsertAfter = \case
      TokenIdentifier _ -> True
      TokenIntegerLiteral _ -> True
      TokenFloatLiteral _ -> True
      TokenStringLiteral _ -> True
      TokenTemplateClose -> True
      TokenKeyword KeywordBreak -> True
      TokenKeyword KeywordReturn -> True
      TokenKeyword KeywordNext -> True
      TokenKeyword KeywordNull -> True
      TokenKeyword KeywordTrue -> True
      TokenKeyword KeywordFalse -> True
      TokenKeyword KeywordInteger -> True
      TokenKeyword KeywordBoolean -> True
      TokenKeyword KeywordNumber -> True
      TokenKeyword KeywordString -> True
      TokenPunctuation PunctuationRightParenthesis -> True
      TokenPunctuation PunctuationRightBracket -> True
      TokenPunctuation PunctuationRightBrace -> True
      _ -> False

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

  tokensLength Proxy = sum . fmap tokenLengthFromSpan . NE.toList
    where
      tokenLengthFromSpan (WithSourceSpan span_ _) =
        if span_.start.line == span_.end.line
          then max 1 (span_.end.column - span_.start.column)
          else 1

instance TraversableStream TokenStream where
  reachOffset targetOffset PosState {..} =
    ( Just finalPrefix,
      PosState
        { pstateInput = TokenStream sourceText remainingTokens,
          pstateOffset = max pstateOffset targetOffset,
          pstateSourcePos = newSourcePos,
          pstateTabWidth = pstateTabWidth,
          pstateLinePrefix = finalPrefix
        }
    )
    where
      sourceText = pstateInput.input
      remainingTokens = drop (targetOffset - pstateOffset) pstateInput.tokens
      newSourcePos = nextSourcePos remainingTokens pstateInput.tokens pstateSourcePos
      newLinePrefix = T.unpack (linePrefixFor sourceText newSourcePos)
      -- megaparsec's standard rule: when staying on the same line, append the
      -- prefix to the previously accumulated prefix; when moving to a new line,
      -- reset to just the new line's prefix. The previous implementation always
      -- appended, which inflated error caret positions across reachOffset calls.
      finalPrefix
        | sourceLine newSourcePos == sourceLine pstateSourcePos =
            pstateLinePrefix <> newLinePrefix
        | otherwise = newLinePrefix

-- | Pick the source position to advance to. Prefer the head of the remaining
-- token stream; if the offset has run past the last token, anchor to the end
-- of the last consumed token; if the input was empty to begin with, keep the
-- current position.
nextSourcePos :: [WithSourceSpan Token] -> [WithSourceSpan Token] -> SourcePos -> SourcePos
nextSourcePos remainingTokens allTokens fallback = case remainingTokens of
  WithSourceSpan span_ _ : _ -> mkSourcePos span_.filePath span_.start
  [] -> case allTokens of
    [] -> fallback
    _ -> let WithSourceSpan span_ _ = last allTokens in mkSourcePos span_.filePath span_.end

mkSourcePos :: FilePath -> Position -> SourcePos
mkSourcePos filePath position = SourcePos filePath (mkPos position.line) (mkPos position.column)

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
showKeyword = T.unpack . keywordText

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

-- | Render a 'Token' for diagnostics. Reused by the Parser to format
-- "expected X, got Y" error messages without redefining its own table.
showToken :: Token -> String
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
