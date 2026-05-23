-- | Katari source-text lexer.
--
-- Turns raw source 'Text' into a 'KatariTokenStream' that the Megaparsec-based
-- parser consumes. Whitespace and comments are stripped; raw @\\n@ characters
-- are preserved as 'KatariTokenNewline' and later filtered by
-- 'insertVirtualSemicolons' into either 'KatariTokenSemicolonVirtual' (when
-- they end a statement) or nothing (when they fall inside parens / brackets,
-- or after an operator). Template literals (@f\"...\"@ / @f\"\"\"...\"\"\"@)
-- are tokenised with a small mode stack that alternates between string and
-- expression contexts.
--
-- The lexer is intentionally tolerant: it emits 'LexerError' values
-- (convertible to K0001-K0009 'Diagnostic's via 'toDiagnostic') for
-- malformed escapes / unterminated literals but always returns a usable
-- token stream so the parser can keep going.
module Katari.Lexer
  ( -- * Tokens
    KatariToken (..),
    Keyword (..),
    Punctuation (..),
    Operator (..),
    WithSourceSpan (..),
    KatariTokenStream (..),

    -- * Errors
    LexerError (..),
    toDiagnostic,

    -- * Entry point
    lex,

    -- * Pretty printers (used by 'Katari.Parser' for error messages)
    showKeyword,
    showPunctuation,
    showOperator,
    showToken,
  )
where

import Control.Monad (void, when)
import Control.Monad.State.Strict
  ( MonadState (get),
    State,
    modify',
    runState,
  )
import Data.Char (chr)
import Data.List.NonEmpty qualified as NE
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.SourceSpan (HasSourceSpan (..), Position (..), SourceSpan (..))
import Numeric (readHex, showHex)
import Safe (headMay)
import Text.Megaparsec
  ( MonadParsec (..),
    ParsecT,
    PosState (..),
    SourcePos (..),
    Stream (..),
    TraversableStream (reachOffset),
    VisualStream (..),
    anySingle,
    atEnd,
    choice,
    getSourcePos,
    many,
    manyTill,
    mkPos,
    noneOf,
    oneOf,
    optional,
    runParserT,
    some,
    unPos,
    (<|>),
  )
import Text.Megaparsec qualified as MP
import Text.Megaparsec.Char
  ( alphaNumChar,
    char,
    hexDigitChar,
    letterChar,
    string,
  )
import Text.Megaparsec.Char.Lexer qualified as L
import Prelude hiding (lex)

-- ===========================================================================
-- KatariToken types
-- ===========================================================================

-- | One lexical token. The lexer pairs each value with a 'SourceSpan'
-- via 'WithSourceSpan' before feeding it to the parser. Identifiers and
-- numeric / string literals carry their decoded payload directly;
-- keywords / punctuation / operators are tagged with their respective
-- enum. The semicolon variants and 'KatariTokenNewline' are bookkeeping
-- artifacts of the virtual-semicolon insertion pipeline.
data KatariToken where
  KatariTokenIdentifier :: Text -> KatariToken
  -- | Bare underscore; distinct from KatariTokenIdentifier so the parser can treat
  -- wildcards without string comparison.
  KatariTokenUnderscore :: KatariToken
  KatariTokenKeyword :: Keyword -> KatariToken
  KatariTokenIntegerLiteral :: Integer -> KatariToken
  KatariTokenFloatLiteral :: Double -> KatariToken
  KatariTokenStringLiteral :: Text -> KatariToken
  -- | f" or f"""
  KatariTokenTemplateOpen :: KatariToken
  -- | " or """ (closes the template started by KatariTokenTemplateOpen)
  KatariTokenTemplateClose :: KatariToken
  -- | String part of a template literal.
  KatariTokenTemplateString :: Text -> KatariToken
  -- | \${
  KatariTokenTemplateExpressionOpen :: KatariToken
  -- | } matching ${
  KatariTokenTemplateExpressionClose :: KatariToken
  KatariTokenPunctuation :: Punctuation -> KatariToken
  KatariTokenOperator :: Operator -> KatariToken
  -- | Explicit @;@ in source.
  KatariTokenSemicolonExplicit :: KatariToken
  -- | Virtual semicolon inserted by 'insertVirtualSemicolons'.
  KatariTokenSemicolonVirtual :: KatariToken
  -- | Raw \n — intermediate KatariToken, eliminated by insertVirtualSemicolons.
  KatariTokenNewline :: KatariToken
  deriving (Eq, Ord, Show)

-- | The fixed set of reserved words in the Katari surface language.
-- The lexer matches each one as a complete identifier (no prefix /
-- substring matching) and emits 'KatariTokenKeyword' instead of
-- 'KatariTokenIdentifier'. Adding a new keyword here also requires a
-- corresponding case in 'lexIdentifierOrKeyword' and 'showKeyword'.
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
  KeywordHandle :: Keyword
  KeywordPar :: Keyword
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
  KeywordSecret :: Keyword
  KeywordType :: Keyword
  KeywordNever :: Keyword
  KeywordUnknown :: Keyword
  KeywordFunction :: Keyword
  KeywordPrim :: Keyword
  KeywordUsing :: Keyword
  deriving (Eq, Ord, Show, Bounded, Enum)

-- | Single- or two-character punctuation tokens distinct from
-- 'Operator' (= no arithmetic / comparison semantics). Bracketing
-- punctuation (@(@, @[@, @{@ and their closers) doubles as the lexer's
-- depth tracker for virtual-semicolon suppression.
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

-- | Binary / unary operators recognised at the lexical level. The
-- parser later decides arity (e.g. @-@ as 'OperatorSubtract' may bind
-- as unary negation). Operators that span two characters
-- (@==@, @\<=@, @&&@, ...) are lexed atomically — there is no @=@ +
-- @=@ tokenisation in source.
data Operator where
  OperatorAdd :: Operator
  OperatorSubtract :: Operator
  OperatorMultiply :: Operator
  OperatorDivide :: Operator
  OperatorModulo :: Operator
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

-- | KatariToken wrapped with the @SourceSpan@ that covers it. Replaces the older
-- (sourcePosition + KatariTokenLength) representation, which produced incorrect
-- end positions for multi-line KatariTokens (template/string literals).
data WithSourceSpan wrapped = WithSourceSpan
  { sourceSpan :: SourceSpan,
    value :: wrapped
  }
  deriving (Eq, Ord, Show)

-- ===========================================================================
-- Lexer
-- ===========================================================================

-- | Lexer mode that overrides default KatariTokenization. Plain top-level code is
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
  -- | A character that doesn't start any known KatariToken. Recovery skips the
  -- single character and continues.
  LexerErrorUnrecognizedCharacter :: SourceSpan -> Char -> LexerError

deriving instance Eq LexerError

deriving instance Show LexerError

instance HasSourceSpan LexerError where
  sourceSpanOf = \case
    LexerErrorUnterminatedTemplate sourceSpan -> sourceSpan
    LexerErrorUnterminatedString sourceSpan -> sourceSpan
    LexerErrorInvalidUnicodeEscape sourceSpan _ -> sourceSpan
    LexerErrorUnrecognizedCharacter sourceSpan _ -> sourceSpan

-- | Convert a 'LexerError' to a unified 'Diagnostic'. Codes K0001-K0019
-- are reserved for the lexer.
toDiagnostic :: LexerError -> Diagnostic
toDiagnostic = \case
  LexerErrorUnterminatedTemplate sourceSpan ->
    diagnosticError "K0001" "unterminated template literal" sourceSpan
  LexerErrorUnterminatedString sourceSpan ->
    diagnosticError "K0002" "unterminated string literal" sourceSpan
  LexerErrorInvalidUnicodeEscape sourceSpan raw ->
    diagnosticError
      "K0003"
      ("invalid unicode escape sequence: " <> raw)
      sourceSpan
  LexerErrorUnrecognizedCharacter sourceSpan ch ->
    diagnosticError
      "K0004"
      ("unrecognized character: " <> T.singleton ch)
      sourceSpan

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
lexGetTopContext :: Lexer (Maybe LexerContext)
lexGetTopContext = do
  state <- get
  pure $ headMay state.contextStack

lexPushContext :: LexerContext -> Lexer ()
lexPushContext context = modify' $ \LexerState {contextStack, accumulatedErrors} ->
  LexerState
    { contextStack = context : contextStack,
      accumulatedErrors
    }

-- | Replace the topmost context. Empty-stack updates are silently ignored
-- (the only caller paths reach this from a known mode; if recovery removed
-- the context already we'd rather no-op than panic).
lexModifyTopContext :: (LexerContext -> LexerContext) -> Lexer ()
lexModifyTopContext modifier = modify' $ \state -> case state.contextStack of
  (topmost : remaining) -> state {contextStack = modifier topmost : remaining}
  [] -> state

-- | Pop the topmost context. Empty-stack pops are *silently ignored* rather
-- than panicking — they only happen when recovery synthesizes a close for an
-- already-popped (or never-pushed) context, and treating that as a hard error
-- would defeat the point of recovery. The resulting incoherence is bounded:
-- subsequent KatariToken lexing simply runs in @Nothing@ context (= top-level).
lexPopContext :: Lexer ()
lexPopContext = modify' $ \state -> case state.contextStack of
  (_ : remaining) -> state {contextStack = remaining}
  [] -> state

-- | Append a recovered error to the accumulator (kept in reverse order).
lexRecordError :: LexerError -> Lexer ()
lexRecordError lexerError = modify' $ \LexerState {contextStack, accumulatedErrors} ->
  LexerState
    { accumulatedErrors = lexerError : accumulatedErrors,
      contextStack = contextStack
    }

-- | Top-level entry to the lexer. Normalises CRLF to LF, runs the
-- token recogniser, threads virtual-semicolon insertion, and returns a
-- 'KatariTokenStream' (consumed by 'Katari.Parser.parse') plus any
-- recovered 'LexerError's.
--
-- The lexer no longer hard-fails on malformed input: unterminated literals
-- get synthesized closing KatariTokens, invalid escape sequences become U+FFFD,
-- and unrecognized characters are skipped one-at-a-time. The input is
-- normalized by replacing @\\r\\n@ with @\\n@ first (CRLF support).
--
-- The 'Either' from megaparsec's @runParser@ is collapsed: a hard failure
-- (which the recovery design tries hard to avoid) yields an empty KatariToken
-- list. Any errors accumulated up to that point are still returned.
lex :: FilePath -> Text -> (KatariTokenStream, [LexerError])
lex filePath input =
  let normalized = T.replace "\r\n" "\n" input
      (lexResult, finalState) =
        runState
          (runParserT (lexAllTokens filePath) filePath normalized)
          initialLexerState
   in case lexResult of
        Right tokens_ ->
          let stream = KatariTokenStream {input = normalized, tokens = insertVirtualSemicolons tokens_}
           in (stream, reverse finalState.accumulatedErrors)
        Left _ ->
          let stream = KatariTokenStream {input = normalized, tokens = []}
           in (stream, reverse finalState.accumulatedErrors)

lexAllTokens :: FilePath -> Lexer [WithSourceSpan KatariToken]
lexAllTokens filePath = do
  lexSkipInterTokenSpace
  loop
  where
    loop = do
      done <- atEnd
      if done
        then return []
        else do
          maybeToken <- lexToken filePath
          lexSkipInterTokenSpace
          case maybeToken of
            Nothing -> loop
            Just token_ -> (token_ :) <$> loop

-- | Skip whitespace and comments between KatariTokens — but only at top-level or in
-- a template-expression context. Inside template string contexts (single- or
-- multi-line) we don't skip, because every character is string content.
-- Newlines are NOT skipped here: they emerge as KatariTokenNewline KatariTokens in
-- lexNormalToken.
lexSkipInterTokenSpace :: Lexer ()
lexSkipInterTokenSpace = do
  context <- lexGetTopContext
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
-- KatariToken dispatch
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

-- | Lex a single KatariToken. Returns 'Nothing' when recovery skipped a malformed
-- character without producing any KatariToken (the outer loop in 'lexAllTokens'
-- continues from there).
lexToken :: FilePath -> Lexer (Maybe (WithSourceSpan KatariToken))
lexToken filePath = do
  startSourcePos <- getSourcePos
  context <- lexGetTopContext
  parsedToken <- case context of
    Just LexerContextTemplate -> Just <$> lexTemplateBodyToken False
    Just LexerContextTemplateMultiLine -> Just <$> lexTemplateBodyToken True
    _ -> lexNormalToken filePath startSourcePos
  endSourcePos <- getSourcePos
  pure $
    fmap
      ( \lexedToken ->
          WithSourceSpan
            { sourceSpan = makeSourceSpan filePath startSourcePos endSourcePos,
              value = lexedToken
            }
      )
      parsedToken

-- ---------------------------------------------------------------------------
-- Normal (top-level / inside ${...}) KatariToken parsing
-- ---------------------------------------------------------------------------

-- | Try every recognised top-level KatariToken producer; if none match, fall back
-- to 'lexUnrecognizedCharacter' which records an error and returns
-- 'Nothing'. This guarantees forward progress: the outer loop never spins
-- on a malformed character.
lexNormalToken :: FilePath -> SourcePos -> Lexer (Maybe KatariToken)
lexNormalToken filePath startSourcePos =
  choice
    [ Just <$> lexNewline,
      Just <$> lexBrace,
      Just <$> lexTemplateStart,
      Just . KatariTokenStringLiteral <$> try lexMultilineStringLiteral,
      Just . KatariTokenStringLiteral <$> lexStringLiteral filePath startSourcePos,
      Just <$> lexNumber,
      Just <$> lexIdentifierOrKeyword,
      Just <$> lexPunctuationOrOperator,
      lexUnrecognizedCharacter filePath startSourcePos
    ]

-- | Emit KatariTokenNewline and consume the \n. Doesn't apply inside template strings
-- (those are handled by lexTemplateBodyToken).
lexNewline :: Lexer KatariToken
lexNewline = KatariTokenNewline <$ char '\n'

-- | Unified handling of `{` and `}` in the normal-token context.
--
-- Behavior depends on the topmost lexer context:
--
--   * LexerContextTemplateExpression 0 + `}` : closes the template expression,
--     pops the context, and emits KatariTokenTemplateExpressionClose.
--   * LexerContextTemplateExpression d + `{` : push depth d+1, emit
--     KatariTokenPunctuation PunctuationLeftBrace.
--   * LexerContextTemplateExpression d + `}` (d > 0): pop depth to d-1,
--     emit KatariTokenPunctuation PunctuationRightBrace.
--   * Any other context : plain `{` / `}` → PunctuationLeftBrace / PunctuationRightBrace.
lexBrace :: Lexer KatariToken
lexBrace = do
  context <- lexGetTopContext
  lexLeftBrace context <|> lexRightBrace context
  where
    lexLeftBrace context = do
      _ <- char '{'
      case context of
        Just (LexerContextTemplateExpression depth) -> do
          lexModifyTopContext (\_ -> LexerContextTemplateExpression (depth + 1))
          pure (KatariTokenPunctuation PunctuationLeftBrace)
        _ -> pure (KatariTokenPunctuation PunctuationLeftBrace)
    lexRightBrace context = do
      _ <- char '}'
      case context of
        Just (LexerContextTemplateExpression 0) ->
          lexPopContext >> pure KatariTokenTemplateExpressionClose
        Just (LexerContextTemplateExpression depth) -> do
          lexModifyTopContext (\_ -> LexerContextTemplateExpression (depth - 1))
          pure (KatariTokenPunctuation PunctuationRightBrace)
        _ -> pure (KatariTokenPunctuation PunctuationRightBrace)

-- | Start of a template literal: `f"""` or `f"`.
--
-- For multi-line `f"""`, a newline must immediately follow. Missing newline
-- is recovered by recording a 'LexerErrorUnterminatedTemplate' and pushing
-- the context anyway — body lexing then proceeds as if the newline had
-- been there.
lexTemplateStart :: Lexer KatariToken
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
        lexRecordError
          (LexerErrorUnterminatedTemplate (spanBetween startSourcePos endSourcePos))
  lexPushContext (if isMultiLine then LexerContextTemplateMultiLine else LexerContextTemplate)
  pure KatariTokenTemplateOpen

-- | Fallback for 'lexNormalToken': if no other producer matched, consume one
-- character, record a 'LexerErrorUnrecognizedCharacter', and return
-- 'Nothing' so the outer loop continues without emitting a KatariToken.
lexUnrecognizedCharacter :: FilePath -> SourcePos -> Lexer (Maybe KatariToken)
lexUnrecognizedCharacter _filePath startSourcePos = do
  character <- anySingle
  endSourcePos <- getSourcePos
  lexRecordError
    (LexerErrorUnrecognizedCharacter (spanBetween startSourcePos endSourcePos) character)
  pure Nothing

-- | Numeric literal: prefer float if `.` or `e/E` is present, else integer.
lexNumber :: Lexer KatariToken
lexNumber =
  label
    "numeric literal"
    (try (KatariTokenFloatLiteral <$> L.float) <|> KatariTokenIntegerLiteral <$> L.decimal)

-- | Identifier, keyword, or bare underscore. Bare `_` gets its own KatariToken so
-- the parser can distinguish wildcard patterns without string comparison.
lexIdentifierOrKeyword :: Lexer KatariToken
lexIdentifierOrKeyword = label "identifier or keyword" $ do
  firstChar <- letterChar <|> char '_'
  remainingChars <- many (alphaNumChar <|> char '_')
  let text = T.pack (firstChar : remainingChars)
  pure $ case (text, lexKeywordOf text) of
    ("_", _) -> KatariTokenUnderscore
    (_, Just keyword) -> KatariTokenKeyword keyword
    (_, Nothing) -> KatariTokenIdentifier text

-- | Surface text of every keyword. Single source of truth shared by the
-- lexer's identifier-or-keyword classifier ('lexKeywordOf') and the diagnostic
-- pretty-printer ('showKeyword').
lexKeywordText :: Keyword -> Text
lexKeywordText = \case
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
  KeywordHandle -> "handle"
  KeywordPar -> "par"
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
  KeywordSecret -> "secret"
  KeywordType -> "type"
  KeywordNever -> "never"
  KeywordUnknown -> "unknown"
  KeywordFunction -> "function"
  KeywordPrim -> "prim"
  KeywordUsing -> "using"

-- | Reverse lookup: surface text → 'Keyword'. Built from 'lexKeywordText' so
-- adding a new keyword only requires extending the single table above.
lexKeywordOf :: Text -> Maybe Keyword
lexKeywordOf name = lookup name [(lexKeywordText keyword, keyword) | keyword <- [minBound .. maxBound]]

-- | Punctuation or operator (excluding `{` and `}` which are handled in
-- lexBrace). Multi-char KatariTokens are tried before their shorter prefixes.
lexPunctuationOrOperator :: Lexer KatariToken
lexPunctuationOrOperator =
  choice
    [ KatariTokenPunctuation PunctuationArrow <$ string "->",
      KatariTokenPunctuation PunctuationFatArrow <$ string "=>",
      KatariTokenOperator OperatorEqual <$ string "==",
      KatariTokenOperator OperatorNotEqual <$ string "!=",
      KatariTokenOperator OperatorLessOrEqual <$ string "<=",
      KatariTokenOperator OperatorGreaterOrEqual <$ string ">=",
      KatariTokenOperator OperatorAnd <$ string "&&",
      KatariTokenOperator OperatorOr <$ string "||",
      KatariTokenOperator OperatorConcat <$ string "++",
      KatariTokenPunctuation PunctuationLeftParenthesis <$ char '(',
      KatariTokenPunctuation PunctuationRightParenthesis <$ char ')',
      KatariTokenPunctuation PunctuationLeftBracket <$ char '[',
      KatariTokenPunctuation PunctuationRightBracket <$ char ']',
      KatariTokenPunctuation PunctuationComma <$ char ',',
      KatariTokenPunctuation PunctuationColon <$ char ':',
      KatariTokenPunctuation PunctuationDot <$ char '.',
      KatariTokenPunctuation PunctuationAt <$ char '@',
      KatariTokenPunctuation PunctuationEquals <$ char '=',
      KatariTokenPunctuation PunctuationPipe <$ char '|',
      KatariTokenSemicolonExplicit <$ char ';',
      KatariTokenOperator OperatorAdd <$ char '+',
      KatariTokenOperator OperatorSubtract <$ char '-',
      KatariTokenOperator OperatorMultiply <$ char '*',
      KatariTokenOperator OperatorDivide <$ char '/',
      KatariTokenOperator OperatorModulo <$ char '%',
      KatariTokenOperator OperatorLessThan <$ char '<',
      KatariTokenOperator OperatorGreaterThan <$ char '>',
      KatariTokenOperator OperatorNot <$ char '!'
    ]

-- ---------------------------------------------------------------------------
-- Template body KatariTokens (inside f"..." or f"""...""")
-- ---------------------------------------------------------------------------

-- | Parse one KatariToken within a template string context.
--
-- Recovery: if none of the three branches match (the only realistic case is
-- EOF before the closing quote was seen), record an
-- 'LexerErrorUnterminatedTemplate' and synthesise a 'TokenTemplateClose' so
-- the outer parse keeps a coherent template-token sequence. The popped
-- context lets subsequent KatariTokens lex as normal code.
lexTemplateBodyToken :: Bool -> Lexer KatariToken
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
      lexPushContext (LexerContextTemplateExpression 0)
      pure KatariTokenTemplateExpressionOpen

    lexClose
      | isMultiLine = do
          _ <- try (string "\n\"\"\"")
          lexPopContext
          pure KatariTokenTemplateClose
      | otherwise = do
          _ <- char '"'
          lexPopContext
          pure KatariTokenTemplateClose

    lexStringRun = do
      chars <- some stringChar
      pure (KatariTokenTemplateString (T.pack chars))

    stringChar
      | isMultiLine = lexTemplateStringCharacterMulti
      | otherwise = lexTemplateStringCharacterSingle

    handler startSourcePos _err = do
      endSourcePos <- getSourcePos
      lexRecordError
        (LexerErrorUnterminatedTemplate (spanBetween startSourcePos endSourcePos))
      lexPopContext
      pure KatariTokenTemplateClose

-- | One character of a single-line template string (no literal newlines).
-- Stops if it sees `${` or `"` (those are separate KatariTokens).
lexTemplateStringCharacterSingle :: Lexer Char
lexTemplateStringCharacterSingle =
  notFollowedBy (string "${" <|> string "\"")
    *> (lexEscapeCharacter <|> noneOf ['\n', '\r'])

-- | One character of a multiline template string (literal newlines allowed).
-- Stops at `${` or the `\n"""` terminator.
lexTemplateStringCharacterMulti :: Lexer Char
lexTemplateStringCharacterMulti =
  notFollowedBy (string "${" <|> try (string "\n\"\"\""))
    *> (lexEscapeCharacter <|> anySingle)

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
lexStringLiteral :: FilePath -> SourcePos -> Lexer Text
lexStringLiteral _filePath startSourcePos = do
  _ <- char '"'
  withRecovery handler stringBody
  where
    stringBody = do
      content <- many stringChar
      _ <- char '"'
      pure (T.pack content)
    stringChar = lexEscapeCharacter <|> noneOf ['"', '\\', '\n', '\r']
    handler _ = do
      endSourcePos <- getSourcePos
      lexRecordError
        (LexerErrorUnterminatedString (spanBetween startSourcePos endSourcePos))
      pure T.empty

-- | Recoverable multi-line string literal (@"""...\n...\n"""@).
--
-- The opener (@"""@ + @\n@) is consumed BEFORE @withRecovery@ engages, for
-- the same reason as 'lexStringLiteral': a recovery handler that
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
      lexRecordError
        (LexerErrorUnterminatedString (spanBetween startSourcePos endSourcePos))
      pure T.empty

-- | JSON-compatible escape sequences plus `\$` for template interpolation.
--
-- Supported: \" \\ \/ \b \f \n \r \t \$ \uXXXX (with surrogate-pair synthesis)
--
-- This lives in 'Lexer' (rather than pure 'Parsec') so invalid escape paths
-- can record a 'LexerErrorInvalidUnicodeEscape' and recover with U+FFFD
-- instead of failing the surrounding string parse.
lexEscapeCharacter :: Lexer Char
lexEscapeCharacter = do
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
      case lexClassifySurrogate firstCodePoint of
        SurrogateClassNone -> pure (chr firstCodePoint)
        SurrogateClassHigh -> do
          maybeSecond <- optional . try $ char '\\' *> char 'u' *> fourHexRaw
          endSourcePos <- getSourcePos
          case maybeSecond of
            Just secondCodePoint
              | SurrogateClassLow <- lexClassifySurrogate secondCodePoint ->
                  pure
                    ( chr
                        ( 0x10000
                            + (firstCodePoint - 0xD800) * 0x400
                            + (secondCodePoint - 0xDC00)
                        )
                    )
            _ -> invalidSurrogate startSourcePos endSourcePos firstCodePoint
        SurrogateClassLow -> do
          endSourcePos <- getSourcePos
          invalidSurrogate startSourcePos endSourcePos firstCodePoint

    fourHexRaw = do
      hex1 <- hexDigitChar
      hex2 <- hexDigitChar
      hex3 <- hexDigitChar
      hex4 <- hexDigitChar
      -- 'hexDigitChar' has already validated each character, so 'readHex'
      -- always returns a non-empty list. The fallback to U+FFFD is
      -- unreachable in practice but keeps this monad pure (no panic).
      pure $ case readHex [hex1, hex2, hex3, hex4] of
        ((codePoint, _) : _) -> codePoint
        [] -> 0xFFFD

    readFourHex startSourcePos = do
      result <- optional (try fourHexRaw)
      case result of
        Just codePoint -> pure codePoint
        Nothing -> do
          endSourcePos <- getSourcePos
          lexRecordError
            ( LexerErrorInvalidUnicodeEscape
                (spanBetween startSourcePos endSourcePos)
                (T.pack "\\u????")
            )
          pure 0xFFFD

    invalidSurrogate startSourcePos endSourcePos codePoint = do
      lexRecordError
        ( LexerErrorInvalidUnicodeEscape
            (spanBetween startSourcePos endSourcePos)
            (T.pack ("\\u" <> showHex codePoint ""))
        )
      pure '\xFFFD'

data SurrogateClass where
  SurrogateClassNone :: SurrogateClass
  SurrogateClassHigh :: SurrogateClass
  SurrogateClassLow :: SurrogateClass

lexClassifySurrogate :: Int -> SurrogateClass
lexClassifySurrogate codePoint
  | codePoint >= 0xD800 && codePoint <= 0xDBFF = SurrogateClassHigh
  | codePoint >= 0xDC00 && codePoint <= 0xDFFF = SurrogateClassLow
  | otherwise = SurrogateClassNone

-- ===========================================================================
-- Virtual Semicolon Insertion
-- ===========================================================================

-- | Transform a raw KatariToken list (with KatariTokenNewline KatariTokens) into a KatariToken list
-- with KatariTokenSemicolonVirtual inserted at appropriate newlines and KatariTokenNewline
-- KatariTokens removed.
--
-- Selection rule: only newlines immediately following a token "that can be
-- considered to complete a syntactic element of an expression here" are
-- converted into virtual semicolons. Identifiers, various literals,
-- closing brackets, and certain keywords (break / return / next / null /
-- true / false / type-name keywords) qualify.
--
-- KatariTokenUnderscore is deliberately excluded: a bare `_` is invalid at
-- an expression position (it is not an expression), and it can start a
-- `_: integer` type annotation, so there are essentially no cases where
-- inserting at end of line is helpful.
--
-- Bracket-context suppression: virtual semicolons are not inserted inside
-- @(@ or @[@. This lets multi-line argument lists and array literals omit
-- trailing commas:
--
-- @
-- [
--   1,
--   2,
--   3
-- ]
-- @
--
-- @{ ... }@ is not suppressed because it also delimits blocks (inside a
-- block, newlines must still function as statement separators as before).
insertVirtualSemicolons :: [WithSourceSpan KatariToken] -> [WithSourceSpan KatariToken]
insertVirtualSemicolons = go (0 :: Int) Nothing
  where
    -- @bracketDepth@ counts the nesting of @(@ / @[@ only (NOT @{@).
    go _bracketDepth _ [] = []
    go bracketDepth previous (current@(WithSourceSpan _ currentToken) : remaining)
      | currentToken == KatariTokenNewline = case previous of
          Just (WithSourceSpan span_ previousToken)
            | bracketDepth == 0 && canInsertAfter previousToken ->
                WithSourceSpan span_ KatariTokenSemicolonVirtual : go bracketDepth Nothing remaining
          _ -> go bracketDepth Nothing remaining
      | otherwise =
          let nextDepth = case currentToken of
                KatariTokenPunctuation PunctuationLeftParenthesis -> bracketDepth + 1
                KatariTokenPunctuation PunctuationLeftBracket -> bracketDepth + 1
                KatariTokenPunctuation PunctuationRightParenthesis -> max 0 (bracketDepth - 1)
                KatariTokenPunctuation PunctuationRightBracket -> max 0 (bracketDepth - 1)
                _ -> bracketDepth
           in current : go nextDepth (Just current) remaining

    canInsertAfter :: KatariToken -> Bool
    canInsertAfter = \case
      KatariTokenIdentifier _ -> True
      KatariTokenIntegerLiteral _ -> True
      KatariTokenFloatLiteral _ -> True
      KatariTokenStringLiteral _ -> True
      KatariTokenTemplateClose -> True
      KatariTokenKeyword KeywordBreak -> True
      KatariTokenKeyword KeywordReturn -> True
      KatariTokenKeyword KeywordNext -> True
      KatariTokenKeyword KeywordNull -> True
      KatariTokenKeyword KeywordTrue -> True
      KatariTokenKeyword KeywordFalse -> True
      KatariTokenKeyword KeywordInteger -> True
      KatariTokenKeyword KeywordBoolean -> True
      KatariTokenKeyword KeywordNumber -> True
      KatariTokenKeyword KeywordString -> True
      KatariTokenKeyword KeywordNever -> True
      KatariTokenKeyword KeywordUnknown -> True
      KatariTokenKeyword KeywordFunction -> True
      KatariTokenPunctuation PunctuationRightParenthesis -> True
      KatariTokenPunctuation PunctuationRightBracket -> True
      KatariTokenPunctuation PunctuationRightBrace -> True
      _ -> False

-- ===========================================================================
-- Custom megaparsec Stream instance
-- ===========================================================================

-- | The token stream consumed by the parser. Pairs the post-newline-
-- normalised source 'input' (kept so the parser can echo source lines
-- in error messages via the 'Stream' instance's @reachOffset@) with
-- the recognised token list. Provides a Megaparsec 'Stream' instance.
data KatariTokenStream = KatariTokenStream
  { input :: Text,
    tokens :: [WithSourceSpan KatariToken]
  }
  deriving (Eq, Show)

instance MP.Stream KatariTokenStream where
  type Token KatariTokenStream = WithSourceSpan KatariToken
  type Tokens KatariTokenStream = [WithSourceSpan KatariToken]

  tokensToChunk Proxy = id
  chunkToTokens Proxy = id
  chunkLength Proxy = length
  chunkEmpty Proxy = null

  take1_ (KatariTokenStream _ []) = Nothing
  take1_ (KatariTokenStream sourceText (firstToken : remainingTokens)) =
    Just (firstToken, KatariTokenStream sourceText remainingTokens)

  takeN_ requestedCount stream@(KatariTokenStream sourceText allTokens)
    | requestedCount <= 0 = Just ([], stream)
    | null allTokens = Nothing
    | otherwise =
        let (taken, remaining) = splitAt requestedCount allTokens
         in Just (taken, KatariTokenStream sourceText remaining)

  takeWhile_ predicate (KatariTokenStream sourceText allTokens) =
    let (taken, remaining) = span predicate allTokens
     in (taken, KatariTokenStream sourceText remaining)

instance VisualStream KatariTokenStream where
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

instance TraversableStream KatariTokenStream where
  reachOffset targetOffset PosState {..} =
    ( Just finalPrefix,
      PosState
        { pstateInput = KatariTokenStream sourceText remainingTokens,
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
-- KatariToken stream; if the offset has run past the last KatariToken, anchor to the end
-- of the last consumed KatariToken; if the input was empty to begin with, keep the
-- current position.
nextSourcePos :: [WithSourceSpan KatariToken] -> [WithSourceSpan KatariToken] -> SourcePos -> SourcePos
nextSourcePos remainingTokens allTokens fallback = case remainingTokens of
  WithSourceSpan span_ _ : _ -> mkSourcePos span_.filePath span_.start
  [] -> case allTokens of
    [] -> fallback
    _ -> let WithSourceSpan span_ _ = last allTokens in mkSourcePos span_.filePath span_.end

mkSourcePos :: FilePath -> Position -> SourcePos
mkSourcePos filePath position = SourcePos {sourceName = filePath, sourceLine = mkPos position.line, sourceColumn = mkPos position.column}

-- | Extract the source line prefix up to (but not including) the column of
-- the given SourcePos. Used to feed megaparsec's error message formatter so
-- it can draw the caret under the offending KatariToken.
linePrefixFor :: Text -> SourcePos -> Text
linePrefixFor sourceText sourcePos =
  let lineIndex = unPos (sourceLine sourcePos) - 1
      columnIndex = unPos (sourceColumn sourcePos) - 1
      sourceLines = T.lines sourceText
   in case drop lineIndex sourceLines of
        (lineText : _) -> T.take columnIndex lineText
        [] -> T.empty

-- | Render a 'Keyword' back to its surface spelling (e.g.
-- @KeywordLet@ → @\"let\"@). Used by 'Katari.Parser' when constructing
-- \"expected ...\" portions of error messages.
showKeyword :: Keyword -> String
showKeyword = T.unpack . lexKeywordText

-- | Render a 'Punctuation' back to its surface spelling (e.g.
-- @PunctuationFatArrow@ → @\"=>\"@). Same use as 'showKeyword'.
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

-- | Render an 'Operator' back to its surface spelling (e.g.
-- @OperatorLessOrEqual@ → @\"\<=\"@). Same use as 'showKeyword'.
showOperator :: Operator -> String
showOperator = \case
  OperatorAdd -> "+"
  OperatorSubtract -> "-"
  OperatorMultiply -> "*"
  OperatorDivide -> "/"
  OperatorModulo -> "%"
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
showToken :: KatariToken -> String
showToken = \case
  KatariTokenIdentifier text -> T.unpack text
  KatariTokenUnderscore -> "_"
  KatariTokenKeyword keyword -> showKeyword keyword
  KatariTokenIntegerLiteral integer -> show integer
  KatariTokenFloatLiteral double -> show double
  KatariTokenStringLiteral text -> show text
  KatariTokenTemplateOpen -> "f\""
  KatariTokenTemplateClose -> "\""
  KatariTokenTemplateString text -> T.unpack text
  KatariTokenTemplateExpressionOpen -> "${"
  KatariTokenTemplateExpressionClose -> "}"
  KatariTokenPunctuation punctuation -> showPunctuation punctuation
  KatariTokenOperator operator -> showOperator operator
  KatariTokenSemicolonExplicit -> ";"
  KatariTokenSemicolonVirtual -> ";"
  KatariTokenNewline -> "\\n"
