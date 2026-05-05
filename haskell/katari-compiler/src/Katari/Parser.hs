module Katari.Parser
  ( ParseError (..),
    ParseErrorReason (..),
    toDiagnostic,
    parse,
  )
where

import Control.Monad (void, when)
import Control.Monad.Combinators.Expr (makeExprParser)
import Control.Monad.Combinators.Expr qualified as Expr
import Control.Monad.Reader (Reader, asks, local, runReader)
import Control.Monad.State.Strict (StateT, get, modify', runStateT)
import Data.Foldable (foldl')
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void, absurd)
import Katari.AST
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.Lexer
  ( KatariToken (..),
    KatariTokenStream (..),
    Keyword (..),
    Operator (..),
    Punctuation (..),
    WithSourceSpan (..),
    showKeyword,
    showOperator,
    showPunctuation,
    showToken,
  )
import Katari.SourceSpan (HasSourceSpan (..), Position (..), SourceSpan (..))
import Text.Megaparsec hiding (ParseError, parse)
import Text.Megaparsec qualified as MP

-- ===========================================================================
-- Types
-- ===========================================================================

-- | Structured parse error. Mirrors the design of 'IdentifierError': rich
-- variants, no embedded text — rendering belongs to 'Katari.Diagnostics'.
--
-- 'ParseErrorLex' wraps a lexer-level failure so callers see a single
-- merged error stream out of 'parseModule'.
data ParseError where
  -- | Declaration-level recovery point. The span covers the skipped tokens
  -- between the failure and the next sync point.
  ParseErrorAtDeclaration :: SourceSpan -> ParseErrorReason -> ParseError
  -- | Statement-level recovery point inside a block.
  ParseErrorAtStatement :: SourceSpan -> ParseErrorReason -> ParseError

deriving instance Eq ParseError

deriving instance Show ParseError

instance HasSourceSpan ParseError where
  sourceSpanOf = \case
    ParseErrorAtDeclaration sourceSpan _ -> sourceSpan
    ParseErrorAtStatement sourceSpan _ -> sourceSpan

-- | Convert a 'ParseError' to a unified 'Diagnostic'. Codes K0020-K0099
-- are reserved for the parser; lexer errors are surfaced via
-- 'Lexer.toDiagnostic'.
toDiagnostic :: ParseError -> Diagnostic
toDiagnostic = \case
  ParseErrorAtDeclaration sourceSpan reason ->
    diagnosticError "K0020" (renderReason "declaration" reason) sourceSpan
  ParseErrorAtStatement sourceSpan reason ->
    diagnosticError "K0021" (renderReason "statement" reason) sourceSpan
  where
    renderReason :: Text -> ParseErrorReason -> Text
    renderReason context reason =
      let unexpectedPart = case reason.unexpected of
            Just token_ -> "unexpected " <> token_
            Nothing -> "unexpected end of input"
          expectedPart = case reason.expected of
            [] -> ""
            xs -> "; expected " <> T.intercalate ", " xs
       in "parse error in " <> context <> ": " <> unexpectedPart <> expectedPart

-- | Reason for a parser-level failure, projected from megaparsec's internal
-- 'MP.ParseError'. Keeps the structured @expected@ Kataritoken set and (when
-- available) what was actually found, so consumers can render or analyse
-- without re-parsing strings.
data ParseErrorReason = ParseErrorReason
  { expected :: [Text],
    unexpected :: Maybe Text
  }
  deriving (Eq, Show)

-- | Parser context: determines which break/next statements are valid.
data BreakContext where
  -- | Top-level / agent body: break and next are both forbidden.
  BreakContextTop :: BreakContext
  -- | For body: ForNext / ForBreak only.
  BreakContextFor :: BreakContext
  -- | Req handler body: Next / Break only.
  BreakContextHandler :: BreakContext

-- | Immutable parser environment threaded through ReaderT.
data ParserEnv = ParserEnv
  { filePath :: FilePath,
    breakContext :: BreakContext
  }

-- | Mutable parser state. Holds the end position of the last consumed token
-- (for accurate span ends) and the error accumulator (built up by recovery).
-- Errors are stored in reverse order and reversed once at the end.
data ParserState = ParserState
  { previousEndPosition :: Maybe Position,
    parseErrors :: [ParseError]
  }

type Parser = ParsecT Void KatariTokenStream (StateT ParserState (Reader ParserEnv))

parseFilePath :: Parser FilePath
parseFilePath = asks (.filePath)

parseBreakContext :: Parser BreakContext
parseBreakContext = asks (.breakContext)

parseWithBreakContext :: BreakContext -> Parser a -> Parser a
parseWithBreakContext context = local (\env -> env {breakContext = context})

-- | Build a @SourceSpan@ using the current file path held in the environment.
parseMakeSpan :: Position -> Position -> Parser SourceSpan
parseMakeSpan startPosition endPosition = do
  currentFilePath <- parseFilePath
  pure (SrcSpan currentFilePath startPosition endPosition)

-- ===========================================================================
-- Public API
-- ===========================================================================

parse :: FilePath -> KatariTokenStream -> (Module Parsed, [ParseError])
parse filePath stream =
  let env = ParserEnv {filePath = filePath, breakContext = BreakContextTop}
      initialState =
        ParserState
          { previousEndPosition = Nothing,
            parseErrors = []
          }
      action = runParserT (parseModuleBody <* eof) filePath stream
      (parseResult, finalState) = runReader (runStateT action initialState) env
   in case parseResult of
        Left _ ->
          let fallbackSpan = SrcSpan {filePath = filePath, start = Position 1 1, end = Position 1 1}
           in (Module {declarations = [], sourceSpan = fallbackSpan}, finalState.parseErrors)
        Right parsedModule ->
          (parsedModule, reverse finalState.parseErrors)

-- ===========================================================================
-- KatariToken primitives
-- ===========================================================================

-- | Consume any Kataritoken matching a predicate, returning the unwrapped value.
-- Also records the end position of the consumed Kataritoken in parser state so that
-- 'parsePreviousEndPosition' can recover the end of the most recently consumed
-- Kataritoken (which is what we want for closing source spans).
parseKatariTokenWith :: (KatariToken -> Maybe value) -> Parser value
parseKatariTokenWith predicate = do
  (result, endPos) <- MP.token testKatariToken Set.empty
  modify' (\s -> s {previousEndPosition = Just endPos})
  pure result
  where
    testKatariToken (WithSourceSpan span_ inputKatariToken) = do
      result <- predicate inputKatariToken
      Just (result, span_.end)

-- | Consume an exact Kataritoken (using equality on the KatariToken type).
parseExactKatariToken :: KatariToken -> Parser ()
parseExactKatariToken expected = parseKatariTokenWith (\actual -> if actual == expected then Just () else Nothing)

parseKeyword :: Keyword -> Parser ()
parseKeyword keyword = label ("'" <> showKeyword keyword <> "'") $ parseExactKatariToken (KatariTokenKeyword keyword)

parsePunctuation :: Punctuation -> Parser ()
parsePunctuation punctuation =
  label ("'" <> showPunctuation punctuation <> "'") $ parseExactKatariToken (KatariTokenPunctuation punctuation)

parseOperator :: Operator -> Parser ()
parseOperator operator = label ("'" <> showOperator operator <> "'") $ parseExactKatariToken (KatariTokenOperator operator)

-- | Consume any semicolon (explicit or virtual).
parseSemicolon :: Parser ()
parseSemicolon = label "';' or newline" $ parseKatariTokenWith $ \case
  KatariTokenSemicolonExplicit -> Just ()
  KatariTokenSemicolonVirtual -> Just ()
  _ -> Nothing

-- | Consume only an explicit ';' (user-written). Virtual semicolons inserted
-- by the lexer at line ends are NOT accepted.
parseExplicitSemicolon :: Parser ()
parseExplicitSemicolon = label "';'" $ parseKatariTokenWith $ \case
  KatariTokenSemicolonExplicit -> Just ()
  _ -> Nothing

-- | Consume only a virtual semicolon (lexer-inserted at a line end).
parseVirtualSemicolon :: Parser ()
parseVirtualSemicolon = parseKatariTokenWith $ \case
  KatariTokenSemicolonVirtual -> Just ()
  _ -> Nothing

parseComma :: Parser ()
parseComma = parsePunctuation PunctuationComma

-- | Identifier Kataritoken (bare `_` is a separate token, not KatariTokenIdentifier).
parseIdentifier :: Parser Text
parseIdentifier = label "identifier" $ parseKatariTokenWith $ \case
  KatariTokenIdentifier text -> Just text
  _ -> Nothing

-- | Bare underscore — only consumed when explicitly requested (wildcard pattern).
parseUnderscore :: Parser ()
parseUnderscore = parseExactKatariToken KatariTokenUnderscore

parseIntegerLiteral :: Parser Integer
parseIntegerLiteral = label "integer literal" $ parseKatariTokenWith $ \case
  KatariTokenIntegerLiteral integer -> Just integer
  _ -> Nothing

parseFloatLiteral :: Parser Double
parseFloatLiteral = label "float literal" $ parseKatariTokenWith $ \case
  KatariTokenFloatLiteral double -> Just double
  _ -> Nothing

parseStringLiteral :: Parser Text
parseStringLiteral = label "string literal" $ parseKatariTokenWith $ \case
  KatariTokenStringLiteral text -> Just text
  _ -> Nothing

-- ===========================================================================
-- Source position helpers
-- ===========================================================================

-- | Position the parser is currently looking at (start of next unconsumed token).
parseCurrentPosition :: Parser Position
parseCurrentPosition = do
  sourcePos <- getSourcePos
  pure Position {line = unPos (sourceLine sourcePos), column = unPos (sourceColumn sourcePos)}

-- | End position of the most recently consumed token. Falls back to
-- parseCurrentPosition when no Kataritoken has been consumed yet in this parse.
parsePreviousEndPosition :: Parser Position
parsePreviousEndPosition = do
  state_ <- get
  maybe parseCurrentPosition pure state_.previousEndPosition

-- | Run @body@ and pass it the source span covering everything @body@ consumed.
-- Removes the @startPosition <- parseCurrentPosition / endPosition <- ... /
-- parseMakeSpan@ boilerplate at every parser entry point.
parseWithSpan :: Parser (SourceSpan -> a) -> Parser a
parseWithSpan body = do
  startPosition <- parseCurrentPosition
  build <- body
  endPosition <- parsePreviousEndPosition
  build <$> parseMakeSpan startPosition endPosition

-- ===========================================================================
-- Error recovery helpers
-- ===========================================================================

parseRecordError :: ParseError -> Parser ()
parseRecordError err = modify' (\s -> s {parseErrors = err : s.parseErrors})

-- | Project a megaparsec parse error into our structured 'ParseErrorReason'.
-- Used inside 'withRecovery' handlers at the declaration and statement levels.
extractReason :: MP.ParseError KatariTokenStream Void -> ParseErrorReason
extractReason = \case
  MP.TrivialError _ maybeUnexpected expectedSet ->
    ParseErrorReason
      { unexpected = fmap itemToText maybeUnexpected,
        expected = map itemToText (Set.toList expectedSet)
      }
  MP.FancyError _ fancySet ->
    ParseErrorReason
      { unexpected = Just (T.intercalate "; " (map fancyToText (Set.toList fancySet))),
        expected = []
      }
  where
    itemToText = \case
      MP.Tokens tokens_ ->
        T.intercalate ", " (NE.toList (fmap (T.pack . showToken . (.value)) tokens_))
      MP.Label chars -> T.pack (NE.toList chars)
      MP.EndOfInput -> "end of input"
    fancyToText = \case
      MP.ErrorFail message -> T.pack message
      MP.ErrorIndentation {} -> "incorrect indentation"
      MP.ErrorCustom void_ -> absurd void_

-- | Wrap @p@ with error recovery. On failure, consume one token, run
-- @skipSync@, then record the error and return the sentinel value.
parseWithErrorRecoveryAt ::
  (SourceSpan -> ParseErrorReason -> ParseError) ->
  (SourceSpan -> a) ->
  Parser () ->
  Parser a ->
  Parser a
parseWithErrorRecoveryAt buildError buildSentinel skipSync innerParser = do
  startPosition <- parseCurrentPosition
  withRecovery
    ( \mpError -> do
        let reason = extractReason mpError
        failPosition <- parseCurrentPosition
        parseConsumeOneKatariToken
        failEndPosition <- parsePreviousEndPosition
        errorSpan <- parseMakeSpan failPosition failEndPosition
        skipSync
        recoveryEndPosition <- parsePreviousEndPosition
        sentinelSpan <- parseMakeSpan startPosition recoveryEndPosition
        parseRecordError (buildError errorSpan reason)
        pure (buildSentinel sentinelSpan)
    )
    innerParser

-- ===========================================================================
-- List combinator helpers
-- ===========================================================================

parseParenthesizedList :: Parser a -> Parser [a]
parseParenthesizedList p =
  between
    (parsePunctuation PunctuationLeftParenthesis)
    (parsePunctuation PunctuationRightParenthesis)
    (p `sepEndBy` parseComma)

parseBracedList :: Parser a -> Parser [a]
parseBracedList p =
  between
    (parsePunctuation PunctuationLeftBrace)
    (parsePunctuation PunctuationRightBrace)
    (p `sepEndBy` parseComma)

parseBracketedList :: Parser a -> Parser [a]
parseBracketedList p =
  between
    (parsePunctuation PunctuationLeftBracket)
    (parsePunctuation PunctuationRightBracket)
    (p `sepEndBy` parseComma)

-- | Peek at the next Kataritoken without consuming it or updating parser state.
parsePeekNextKatariToken :: Parser (Maybe KatariToken)
parsePeekNextKatariToken = optional (MP.lookAhead (MP.token (\(WithSourceSpan _ tok) -> Just tok) Set.empty))

-- | Consume one token, recording its end position. No-op at EOF.
parseConsumeOneKatariToken :: Parser ()
parseConsumeOneKatariToken = void (optional (parseKatariTokenWith Just))

-- | Skip tokens until the next declaration-level sync point or EOF.
-- Sync tokens: declaration-start keywords and '@'.
parseSkipUntilDeclarationSync :: Parser ()
parseSkipUntilDeclarationSync = do
  next <- parsePeekNextKatariToken
  case next of
    Nothing -> pure ()
    Just tok ->
      if isDeclarationSyncKatariToken tok
        then pure ()
        else parseConsumeOneKatariToken *> parseSkipUntilDeclarationSync
  where
    isDeclarationSyncKatariToken = \case
      KatariTokenKeyword KeywordImport -> True
      KatariTokenKeyword KeywordType -> True
      KatariTokenKeyword KeywordAgent -> True
      KatariTokenKeyword KeywordReq -> True
      KatariTokenKeyword KeywordExt -> True
      KatariTokenKeyword KeywordData -> True
      KatariTokenPunctuation PunctuationAt -> True
      _ -> False

-- | Skip tokens until the next statement-level sync point, respecting brace
-- depth so we don't escape the enclosing block.
-- Sync tokens (at depth 0): @;@, @}@, statement-start keywords.
parseSkipUntilStatementSync :: Parser ()
parseSkipUntilStatementSync = go (0 :: Int)
  where
    go depth = do
      next <- parsePeekNextKatariToken
      case next of
        Nothing -> pure ()
        Just tok ->
          if isSyncKatariToken tok depth
            then pure ()
            else do
              parseConsumeOneKatariToken
              let newDepth = case tok of
                    KatariTokenPunctuation PunctuationLeftBrace -> depth + 1
                    KatariTokenPunctuation PunctuationRightBrace | depth > 0 -> depth - 1
                    _ -> depth
              go newDepth
    isSyncKatariToken tok depth = case tok of
      KatariTokenSemicolonExplicit -> True
      KatariTokenSemicolonVirtual -> True
      KatariTokenPunctuation PunctuationRightBrace | depth == 0 -> True
      KatariTokenKeyword keyword | depth == 0 -> isStatementStartKeyword keyword
      _ -> False
    isStatementStartKeyword = \case
      KeywordLet -> True
      KeywordAgent -> True
      KeywordReturn -> True
      KeywordBreak -> True
      KeywordNext -> True
      _ -> False

-- ===========================================================================
-- NameRef helpers
-- ===========================================================================

-- | Parse an identifier and wrap it into a @NameRef Parsed symbol@.
-- The symbol is determined by the type at the call site.
parseNameRef :: Parser (NameRef Parsed symbol)
parseNameRef = parseWithSpan $ do
  text <- parseIdentifier
  pure $ \sourceSpan -> NameRef {text = text, sourceSpan = sourceSpan, resolution = ()}

-- | Internal: replace the 'NameRefKind' tag of a parsed 'NameRef'. Safe at
-- the 'Parsed' phase because @NameRefResolution Parsed s = ()@ for every symbol
-- kind, so re-tagging never has to invent payload. Exposed only through
-- the directional helpers above so that call sites document intent.
retagParsedNameRef :: NameRef Parsed source -> NameRef Parsed target
retagParsedNameRef nameRef =
  NameRef {text = nameRef.text, sourceSpan = nameRef.sourceSpan, resolution = ()}

-- ===========================================================================
-- Module
-- ===========================================================================

parseModuleBody :: Parser (Module Parsed)
parseModuleBody = parseWithSpan $ do
  declarations <- parseDeclarationsWithRecovery
  pure $ \sourceSpan -> Module {declarations = declarations, sourceSpan = sourceSpan}

parseDeclarationsWithRecovery :: Parser [Declaration Parsed]
parseDeclarationsWithRecovery = loop []
  where
    loop reversedDeclarations = do
      skipMany parseSemicolon
      atEof <- True <$ MP.lookAhead eof <|> pure False
      if atEof
        then pure (reverse reversedDeclarations)
        else do
          declaration <-
            parseWithErrorRecoveryAt
              ParseErrorAtDeclaration
              DeclarationError
              parseSkipUntilDeclarationSync
              parseDeclaration
          loop (declaration : reversedDeclarations)

-- | Top-level declaration. Split into two helpers to make the difference
-- between annotation-bearing and annotation-free declarations explicit:
--
--   * 'parseImport' and 'parseTypeSynonym' do **not** accept @\@\"...\"@
--     annotations and start from their own keyword (@import@ / @type@), so they
--     are tried first.
--   * 'parseAnnotatedDeclaration' first consumes an optional @\@\"...\"@ then
--     dispatches to the function-shaped declarations (agent / req / ext-agent
--     / data) which all may carry an annotation.
parseDeclaration :: Parser (Declaration Parsed)
parseDeclaration =
  label "declaration" $
    choice
      [ DeclarationImport <$> parseImport,
        DeclarationTypeSynonym <$> parseTypeSynonym,
        parseAnnotatedDeclaration
      ]

-- | Parse a declaration that can carry an optional @\@\"...\"@ annotation.
-- The annotation is consumed once and then threaded into each candidate
-- parser.
parseAnnotatedDeclaration :: Parser (Declaration Parsed)
parseAnnotatedDeclaration = do
  annotation <- parseAnnotation
  choice
    [ DeclarationExternalAgent <$> parseExternalAgentDeclaration annotation,
      DeclarationAgent <$> parseAgentDeclaration annotation,
      DeclarationRequest <$> parseRequestDeclaration annotation,
      DeclarationData <$> parseDataDeclaration annotation
    ]

parseAnnotation :: Parser (Maybe Text)
parseAnnotation = optional $ do
  _ <- parsePunctuation PunctuationAt
  text <- parseStringLiteral
  _ <- optional parseVirtualSemicolon
  pure text

-- ---------------------------------------------------------------------------
-- Agent
-- ---------------------------------------------------------------------------

parseAgentDeclaration :: Maybe Text -> Parser (AgentDeclaration Parsed)
parseAgentDeclaration annotation = parseWithSpan $ do
  parseKeyword KeywordAgent
  name <- parseNameRef
  parameters <- parseParameterList
  returnType <- optional (parsePunctuation PunctuationArrow *> parseType)
  requests <- optional (parseKeyword KeywordWith *> parseRequests)
  body <- parseWithBreakContext BreakContextTop parseBlock
  pure $ \sourceSpan ->
    AgentDeclaration
      { annotation = annotation,
        name = name,
        parameters = parameters,
        returnType = returnType,
        withRequests = requests,
        body = body,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Request
-- ---------------------------------------------------------------------------

parseRequestDeclaration :: Maybe Text -> Parser (RequestDeclaration Parsed)
parseRequestDeclaration annotation = parseWithSpan $ do
  parseKeyword KeywordReq
  name <- parseNameRef
  parameters <- parseParameterList
  parsePunctuation PunctuationArrow
  returnType <- parseType
  pure $ \sourceSpan ->
    RequestDeclaration
      { annotation = annotation,
        name = name,
        requestName = retagParsedNameRef name,
        parameters = parameters,
        returnType = returnType,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- External Agent
-- ---------------------------------------------------------------------------

parseExternalAgentDeclaration :: Maybe Text -> Parser (ExternalAgentDeclaration Parsed)
parseExternalAgentDeclaration annotation = parseWithSpan $ do
  parseKeyword KeywordExt
  parseKeyword KeywordAgent
  name <- parseNameRef
  parameters <- parseParameterList
  parsePunctuation PunctuationArrow
  returnType <- parseType
  parseKeyword KeywordWith
  requests <- parseRequests
  pure $ \sourceSpan ->
    ExternalAgentDeclaration
      { annotation = annotation,
        name = name,
        parameters = parameters,
        returnType = returnType,
        withRequests = requests,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Data declaration
-- ---------------------------------------------------------------------------

-- | @data ctor_name(name: type, ...)@. Parens are **required**, even for
-- zero-argument constructors (@data foo()@). Each declaration introduces
-- exactly one constructor, and the same identifier is bound in both the
-- value namespace (the constructor function) and the type namespace (the
-- data type). The Identifier pass populates both slots.
parseDataDeclaration :: Maybe Text -> Parser (DataDeclaration Parsed)
parseDataDeclaration annotation = parseWithSpan $ do
  parseKeyword KeywordData
  name <- parseNameRef
  parameters <- parseParenthesizedList parseDataDeclarationParameter
  pure $ \sourceSpan ->
    DataDeclaration
      { annotation = annotation,
        name = name,
        typeName = retagParsedNameRef name,
        constructorName = retagParsedNameRef name,
        parameters = parameters,
        sourceSpan = sourceSpan
      }

parseDataDeclarationParameter :: Parser (DataParameter Parsed)
parseDataDeclarationParameter = parseWithSpan $ do
  annotation <- parseAnnotation
  name <- parseIdentifier
  parsePunctuation PunctuationColon
  parameterType <- parseType
  pure $ \sourceSpan ->
    DataParameter
      { annotation = annotation,
        name = name,
        parameterType = parameterType,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Type synonym
-- ---------------------------------------------------------------------------

-- | @type T = ...@. No @\@\"...\"@ annotation. Top-level only.
parseTypeSynonym :: Parser (TypeSynonymDeclaration Parsed)
parseTypeSynonym = parseWithSpan $ do
  parseKeyword KeywordType
  name <- parseNameRef
  parsePunctuation PunctuationEquals
  rhs <- parseType
  pure $ \sourceSpan ->
    TypeSynonymDeclaration
      { name = name,
        rhs = rhs,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Import
-- ---------------------------------------------------------------------------

parseImport :: Parser (ImportDeclaration Parsed)
parseImport = parseWithSpan $ do
  parseKeyword KeywordImport
  importKind <-
    choice
      [ do
          items <- parseBracedList parseImportItem
          parseKeyword KeywordFrom
          moduleName <- parseModulePath
          pure ImportNames {items = items, moduleName = moduleName},
        do
          moduleName <- parseModulePath
          alias <- optional (parseKeyword KeywordAs *> parseIdentifier)
          pure ImportModule {moduleName = moduleName, alias = alias}
      ]
  pure $ \sourceSpan -> ImportDeclaration {kind = importKind, sourceSpan = sourceSpan}

-- | One import name, optionally tagged with a @type@ prefix to bring the
-- name into the type namespace.
parseImportItem :: Parser ImportItem
parseImportItem = do
  isType <- option False (True <$ parseKeyword KeywordType)
  name <- parseIdentifier
  pure
    ImportItem
      { kind = if isType then ImportItemType else ImportItemValue,
        name = name
      }

parseModulePath :: Parser Text
parseModulePath = do
  parts <- (:) <$> parseIdentifier <*> many (parsePunctuation PunctuationDot *> parseIdentifier)
  pure (T.intercalate "." parts)

-- ===========================================================================
-- Statements
-- ===========================================================================

parseBlock :: Parser (Block Parsed)
parseBlock = label "block" $ parseWithSpan $ do
  parsePunctuation PunctuationLeftBrace
  skipMany parseSemicolon
  (statements, returnExpression) <- parseBlockBodyWithRecovery
  parsePunctuation PunctuationRightBrace
  parseDetectSameLineKeywordViolation
  pure $ \sourceSpan ->
    Block
      { statements = statements,
        returnExpression = returnExpression,
        sourceSpan = sourceSpan
      }

-- | After consuming a closing @}@, detect the pattern
-- @KatariTokenSemicolonVirtual + (else|then|where)@ — a virtual semi sits there only
-- if the user put a newline between @}@ and the keyword. CLAUDE.md requires
-- these keywords to be on the same line as the preceding @}@.
--
-- The lookahead does NOT consume input; the keyword name is reported in a
-- specific error so users get a clear message.
parseDetectSameLineKeywordViolation :: Parser ()
parseDetectSameLineKeywordViolation = do
  violation <- MP.lookAhead . optional . try $ do
    parseKatariTokenWith $ \case
      KatariTokenSemicolonVirtual -> Just ()
      _ -> Nothing
    parseKatariTokenWith $ \case
      KatariTokenKeyword KeywordElse -> Just "else"
      KatariTokenKeyword KeywordThen -> Just "then"
      _ -> Nothing
  case violation of
    Just keyword -> fail $ "'" <> keyword <> "' must be on the same line as the preceding '}'"
    Nothing -> pure ()

data BlockStep where
  BlockStepStatement :: Statement Parsed -> BlockStep
  BlockStepReturn :: Maybe (Expression Parsed) -> BlockStep

-- | One-pass block body with statement-level error recovery. On parse failure
-- inside a step, up to the next sync Kataritoken is skipped and a 'StatementError'
-- sentinel is inserted in place of the bad statement.
parseBlockBodyWithRecovery :: Parser ([Statement Parsed], Maybe (Expression Parsed))
parseBlockBodyWithRecovery = loop []
  where
    loop reversedStatements = do
      step <-
        parseWithErrorRecoveryAt
          ParseErrorAtStatement
          (BlockStepStatement . StatementError)
          parseSkipUntilStatementSync
          parseOneStep
      case step of
        BlockStepReturn maybeExpression -> pure (reverse reversedStatements, maybeExpression)
        BlockStepStatement statement -> loop (statement : reversedStatements)
    parseOneStep = do
      skipMany parseSemicolon
      choice
        [ BlockStepReturn Nothing
            <$ MP.lookAhead (parsePunctuation PunctuationRightBrace),
          BlockStepReturn Nothing
            <$ MP.lookAhead eof,
          BlockStepStatement <$> parseNonExpressionStatement,
          -- Koka-style handle: captures the rest of this block as its body.
          parseHandleStep False,
          -- par handle: also captures the rest.
          try $ do
            _ <- MP.lookAhead (parseKeyword KeywordPar *> parseKeyword KeywordHandle)
            parseHandleStep True,
          do
            expression <- parseExpression
            -- Distinguish: an explicit ';' makes the expression a statement.
            -- A bare lexer-inserted virtual ';' immediately followed by '}'
            -- (block end) is treated as the block's return expression — the
            -- "trailing newline before close-brace" UX. Any other ';' (incl.
            -- virtual followed by another statement) makes it a statement.
            choice
              [ -- explicit ';' → statement; consume all subsequent ';'.
                BlockStepStatement (StatementExpression expression)
                  <$ (parseExplicitSemicolon *> skipMany parseSemicolon),
                -- virtual ';' then '}' → return expression.
                BlockStepReturn (Just expression)
                  <$ MP.try
                    ( parseVirtualSemicolon
                        *> MP.lookAhead (parsePunctuation PunctuationRightBrace)
                    ),
                -- virtual ';' followed by anything else → statement.
                BlockStepStatement (StatementExpression expression)
                  <$ (parseVirtualSemicolon *> skipMany parseSemicolon),
                -- no ';' at all → return expression.
                pure (BlockStepReturn (Just expression))
              ]
        ]
    -- Parse a handle expression that captures the rest of this block as body.
    parseHandleStep parallel = do
      handleExpr <- parseHandleExpression parallel
      pure (BlockStepReturn (Just handleExpr))

parseNonExpressionStatement :: Parser (Statement Parsed)
parseNonExpressionStatement =
  choice
    [ StatementLet <$> parseLet <* void (some parseSemicolon),
      StatementAgent <$> parseAgentStatement <* void (some parseSemicolon),
      StatementReturn <$> parseReturn <* void (some parseSemicolon),
      parseBreakOrNextStatement <* void (some parseSemicolon)
    ]

-- | Koka-style handle expression. Parses the handle clause and then
-- captures the remaining block contents as the body (continuation).
--
-- @
-- (par) handle (var s = init, ...) {
--   req name(params) -> T { body }
--   ...
-- } then (pat) { ... }
-- continuation_statements; trailing_expr
-- @
--
-- Called from 'parseBlockBodyWithRecovery' when @handle@ or @par handle@
-- is encountered at statement position.
parseHandleExpression :: Bool -> Parser (Expression Parsed)
parseHandleExpression parallel = parseWithSpan $ do
  when parallel (void $ parseKeyword KeywordPar)
  parseKeyword KeywordHandle
  stateVariables <- option [] . try $ parseParenthesizedList parseStateVariable
  parsePunctuation PunctuationLeftBrace
  skipMany parseSemicolon
  handlers <- many (parseRequestHandler <* skipMany parseSemicolon)
  parsePunctuation PunctuationRightBrace
  parseDetectSameLineKeywordViolation
  thenClause <- optional parseThenClause
  -- Consume optional semicolons between handle clause and continuation.
  skipMany parseSemicolon
  -- Continuation: the rest of the enclosing block becomes the handle body.
  bodyStart <- parseCurrentPosition
  (bodyStatements, bodyReturn) <- parseBlockBodyWithRecovery
  bodyEnd <- parsePreviousEndPosition
  bodySpan <- parseMakeSpan bodyStart bodyEnd
  let body =
        Block
          { statements = bodyStatements,
            returnExpression = bodyReturn,
            sourceSpan = bodySpan
          }
  pure $ \sourceSpan ->
    ExpressionHandle
      HandleExpression
        { parallel = parallel,
          stateVariables = stateVariables,
          handlers = handlers,
          thenClause = thenClause,
          body = body,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

-- | Parse a @then@ clause: @then@ keyword, optional pattern in parens, then a
-- block. Used as the optional finalizer of a handle or for clause.
parseThenClause :: Parser (Maybe (Pattern Parsed), Block Parsed)
parseThenClause = do
  parseKeyword KeywordThen
  parsedPattern <-
    optional $
      between
        (parsePunctuation PunctuationLeftParenthesis)
        (parsePunctuation PunctuationRightParenthesis)
        parsePattern
  body <- parseBlock
  pure (parsedPattern, body)

parseStateVariable :: Parser (StateVariableBinding Parsed)
parseStateVariable = parseWithSpan $ do
  parseKeyword KeywordVar
  name <- parseNameRef
  typeAnnotation <- optional (parsePunctuation PunctuationColon *> parseType)
  parsePunctuation PunctuationEquals
  expression <- parseExpression
  pure $ \sourceSpan ->
    StateVariableBinding
      { name = name,
        typeAnnotation = typeAnnotation,
        initial = expression,
        sourceSpan = sourceSpan
      }

-- | req handler は @with@ 節を持たない。handler 内で発火する request は handler
-- ではなく囲む agent に bind されるため、handler 自身に request 注釈を付けるのは
-- 意味論的に invalid。Lexer / parser とも @with@ を受け付けない。
parseRequestHandler :: Parser (RequestHandler Parsed)
parseRequestHandler = parseWithSpan $ do
  parseKeyword KeywordReq
  -- Either @req name(...)@ or @req module.name(...)@: if a @.@ follows the
  -- first identifier, treat it as a qualified handler; otherwise bare.
  -- The handler's @name@ field is a RequestRef' (resolution will require it
  -- to name a @req@ declaration); we re-tag the parsed identifier here.
  first <- parseNameRef
  (moduleQualifier, name) <-
    optional (parsePunctuation PunctuationDot *> parseNameRef) >>= \case
      Just second -> pure (Just (retagParsedNameRef first), retagParsedNameRef second)
      Nothing -> pure (Nothing, retagParsedNameRef first)
  parameters <- parseParameterList
  returnType <- optional (parsePunctuation PunctuationArrow *> parseType)
  body <- parseWithBreakContext BreakContextHandler parseBlock
  pure $ \sourceSpan ->
    RequestHandler
      { moduleQualifier = moduleQualifier,
        name = name,
        parameters = parameters,
        returnType = returnType,
        body = body,
        sourceSpan = sourceSpan
      }

parseAgentStatement :: Parser (AgentStatement Parsed)
parseAgentStatement = parseWithSpan $ do
  parseKeyword KeywordAgent
  name <- parseNameRef
  parameters <- parseParameterList
  returnType <- optional (parsePunctuation PunctuationArrow *> parseType)
  requests <- optional (parseKeyword KeywordWith *> parseRequests)
  body <- parseWithBreakContext BreakContextTop parseBlock
  pure $ \sourceSpan ->
    AgentStatement
      { name = name,
        parameters = parameters,
        returnType = returnType,
        withRequests = requests,
        body = body,
        sourceSpan = sourceSpan
      }

parseBreakOrNextStatement :: Parser (Statement Parsed)
parseBreakOrNextStatement = do
  context <- parseBreakContext
  case context of
    BreakContextTop -> do
      -- If break/next is actually there, consume it and fail with a clear
      -- message. Otherwise fall through without consuming so the outer
      -- choice can try the next alternative.
      matchedKeyword <- optional (KeywordBreak <$ parseKeyword KeywordBreak <|> KeywordNext <$ parseKeyword KeywordNext)
      case matchedKeyword of
        Just KeywordBreak -> fail "'break' is only allowed inside a 'for' loop or 'req' handler"
        Just KeywordNext -> fail "'next' is only allowed inside a 'for' loop or 'req' handler"
        _ -> empty
    BreakContextFor ->
      choice
        [ try $ StatementForNext <$> parseForNext,
          StatementForBreak <$> parseForBreak
        ]
    BreakContextHandler ->
      choice
        [ try $ StatementNext <$> parseNext,
          StatementBreak <$> parseBreak
        ]

parseForBreak :: Parser (ForBreakStatement Parsed)
parseForBreak = parseWithSpan $ do
  parseKeyword KeywordBreak
  expression <- parseOptionalExitValue
  pure $ \sourceSpan -> ForBreakStatement {value = expression, sourceSpan = sourceSpan}

parseLet :: Parser (LetStatement Parsed)
parseLet = parseWithSpan $ do
  parseKeyword KeywordLet
  parsedPattern <- parsePattern
  parsePunctuation PunctuationEquals
  expression <- parseExpression
  pure $ \sourceSpan ->
    LetStatement
      { pattern = parsedPattern,
        value = expression,
        sourceSpan = sourceSpan
      }

parseReturn :: Parser (ReturnStatement Parsed)
parseReturn = parseWithSpan $ do
  parseKeyword KeywordReturn
  expression <- parseOptionalExitValue
  pure $ \sourceSpan -> ReturnStatement {value = expression, sourceSpan = sourceSpan}

parseNext :: Parser (NextStatement Parsed)
parseNext = parseWithSpan $ do
  parseKeyword KeywordNext
  expression <- parseOptionalExitValue
  modifiers <- option [] (parseKeyword KeywordWith *> parseModifiers)
  pure $ \sourceSpan ->
    NextStatement
      { value = expression,
        modifiers = modifiers,
        sourceSpan = sourceSpan
      }

parseForNext :: Parser (ForNextStatement Parsed)
parseForNext = parseWithSpan $ do
  parseKeyword KeywordNext
  modifiers <- option [] (parseKeyword KeywordWith *> parseModifiers)
  pure $ \sourceSpan -> ForNextStatement {modifiers = modifiers, sourceSpan = sourceSpan}

parseBreak :: Parser (BreakStatement Parsed)
parseBreak = parseWithSpan $ do
  parseKeyword KeywordBreak
  expression <- parseOptionalExitValue
  pure $ \sourceSpan -> BreakStatement {value = expression, sourceSpan = sourceSpan}

-- | Parse an optional exit value for @break@ / @return@ / @next@. If the
-- next token is a statement separator or block close (i.e. there is no
-- expression to consume), default the value to a synthesized @null@
-- literal (with a zero-width span at the current position).
--
-- @break@ alone is shorthand for @break null@; same for @return@ and
-- @next@. The synthesized null carries an empty span — diagnostics that
-- refer to the value will point at the keyword's span instead via the
-- enclosing statement.
parseOptionalExitValue :: Parser (Expression Parsed)
parseOptionalExitValue = do
  pos <- parseCurrentPosition
  span_ <- parseMakeSpan pos pos
  let nullExpr =
        ExpressionLiteral
          LiteralExpression
            { value = LiteralValueNull,
              sourceSpan = span_,
              typeOf = ()
            }
  -- If the lookahead is anything that terminates this statement we yield
  -- the null literal without consuming. Otherwise an expression must be
  -- present and we parse it normally.
  option nullExpr (try parseExpression)

parseModifiers :: Parser [Modifier Parsed]
parseModifiers = parseBracedList parseModifier

parseModifier :: Parser (Modifier Parsed)
parseModifier = parseWithSpan $ do
  name <- parseNameRef
  parsePunctuation PunctuationEquals
  expression <- parseExpression
  pure $ \sourceSpan ->
    Modifier
      { name = name,
        value = expression,
        sourceSpan = sourceSpan
      }

-- ===========================================================================
-- Expressions
-- ===========================================================================

parseExpression :: Parser (Expression Parsed)
parseExpression = label "expression" $ makeExprParser parsePostfixExpression expressionOperatorTable

expressionOperatorTable :: [[Expr.Operator Parser (Expression Parsed)]]
expressionOperatorTable =
  [ [ parsePrefixOperator (parseOperator OperatorSubtract) UnaryOperatorNegate,
      parsePrefixOperator (parseOperator OperatorNot) UnaryOperatorNot
    ],
    [ parseLeftAssociativeBinaryOperator (parseOperator OperatorMultiply) BinaryOperatorMultiply,
      parseLeftAssociativeBinaryOperator (parseOperator OperatorDivide) BinaryOperatorDivide
    ],
    [ parseLeftAssociativeBinaryOperator (parseOperator OperatorAdd) BinaryOperatorAdd,
      parseLeftAssociativeBinaryOperator (parseOperator OperatorSubtract) BinaryOperatorSubtract
    ],
    [parseLeftAssociativeBinaryOperator (parseOperator OperatorConcat) BinaryOperatorConcat],
    [ parseNonAssociativeBinaryOperator (parseOperator OperatorLessOrEqual) BinaryOperatorLessOrEqual,
      parseNonAssociativeBinaryOperator (parseOperator OperatorGreaterOrEqual) BinaryOperatorGreaterOrEqual,
      parseNonAssociativeBinaryOperator (parseOperator OperatorLessThan) BinaryOperatorLessThan,
      parseNonAssociativeBinaryOperator (parseOperator OperatorGreaterThan) BinaryOperatorGreaterThan
    ],
    [ parseNonAssociativeBinaryOperator (parseOperator OperatorEqual) BinaryOperatorEqual,
      parseNonAssociativeBinaryOperator (parseOperator OperatorNotEqual) BinaryOperatorNotEqual
    ],
    [parseLeftAssociativeBinaryOperator (parseOperator OperatorAnd) BinaryOperatorAnd],
    [parseLeftAssociativeBinaryOperator (parseOperator OperatorOr) BinaryOperatorOr]
  ]

makeBinaryOperatorExpression :: FilePath -> BinaryOperator -> Expression Parsed -> Expression Parsed -> Expression Parsed
makeBinaryOperatorExpression currentFilePath binaryOperator left right =
  ExpressionBinaryOperator
    BinaryOperatorExpression
      { operator = binaryOperator,
        left = left,
        right = right,
        sourceSpan = SrcSpan currentFilePath (sourceSpanOf left).start (sourceSpanOf right).end,
        typeOf = ()
      }

parseLeftAssociativeBinaryOperator :: Parser () -> BinaryOperator -> Expr.Operator Parser (Expression Parsed)
parseLeftAssociativeBinaryOperator parserAction binaryOperator = Expr.InfixL $ do
  parserAction
  currentFilePath <- parseFilePath
  pure (makeBinaryOperatorExpression currentFilePath binaryOperator)

parseNonAssociativeBinaryOperator :: Parser () -> BinaryOperator -> Expr.Operator Parser (Expression Parsed)
parseNonAssociativeBinaryOperator parserAction binaryOperator = Expr.InfixN $ do
  parserAction
  currentFilePath <- parseFilePath
  pure (makeBinaryOperatorExpression currentFilePath binaryOperator)

parsePrefixOperator :: Parser () -> UnaryOperator -> Expr.Operator Parser (Expression Parsed)
parsePrefixOperator parserAction unaryOperator = Expr.Prefix $ do
  startPosition <- parseCurrentPosition
  parserAction
  currentFilePath <- parseFilePath
  pure $ \operand ->
    ExpressionUnaryOperator
      UnaryOperatorExpression
        { operator = unaryOperator,
          operand = operand,
          sourceSpan = SrcSpan currentFilePath startPosition (sourceSpanOf operand).end,
          typeOf = ()
        }

-- ---------------------------------------------------------------------------
-- Postfix expressions
-- ---------------------------------------------------------------------------

-- | A single postfix operator (call, field access, or index) with its own
-- source span covering just the operator syntax. Final node spans are built by
-- 'applyPostfixOperation' as @primary.start ↦ postfix.end@.
data Postfix where
  PostfixCall :: [CallArgument Parsed] -> SourceSpan -> Postfix
  PostfixField :: NameRef Parsed LabelRef -> SourceSpan -> Postfix
  PostfixIndex :: Expression Parsed -> SourceSpan -> Postfix

parsePostfixExpression :: Parser (Expression Parsed)
parsePostfixExpression = do
  primary <- parsePrimaryExpression
  postfixOperations <- many parsePostfix
  pure (foldl' applyPostfixOperation primary postfixOperations)

parsePostfix :: Parser Postfix
parsePostfix =
  choice
    [ parseCallPostfix,
      parseFieldPostfix,
      parseIndexPostfix
    ]

parseCallPostfix :: Parser Postfix
parseCallPostfix = parseWithSpan $ do
  arguments <- parseParenthesizedList parseCallArgument
  pure (PostfixCall arguments)

parseFieldPostfix :: Parser Postfix
parseFieldPostfix = parseWithSpan $ do
  parsePunctuation PunctuationDot
  PostfixField <$> parseNameRef

parseIndexPostfix :: Parser Postfix
parseIndexPostfix = parseWithSpan $ do
  parsePunctuation PunctuationLeftBracket
  indexExpression <- parseExpression
  parsePunctuation PunctuationRightBracket
  pure (PostfixIndex indexExpression)

applyPostfixOperation :: Expression Parsed -> Postfix -> Expression Parsed
applyPostfixOperation expression = \case
  PostfixCall arguments postfixSpan ->
    ExpressionCall
      CallExpression
        { callee = expression,
          arguments = arguments,
          sourceSpan = mergePostfixSpan expression postfixSpan,
          typeOf = ()
        }
  PostfixField fieldName postfixSpan ->
    ExpressionFieldAccess
      FieldAccessExpression
        { object = expression,
          fieldName = fieldName,
          sourceSpan = mergePostfixSpan expression postfixSpan,
          typeOf = ()
        }
  PostfixIndex indexExpression postfixSpan ->
    ExpressionIndexAccess
      IndexAccessExpression
        { array = expression,
          index = indexExpression,
          sourceSpan = mergePostfixSpan expression postfixSpan,
          typeOf = ()
        }
  where
    mergePostfixSpan expr postfix =
      let exprSpan = sourceSpanOf expr
       in SrcSpan
            { filePath = exprSpan.filePath,
              start = exprSpan.start,
              end = postfix.end
            }

parseCallArgument :: Parser (CallArgument Parsed)
parseCallArgument = labeledArgument <|> sugarArgument
  where
    labeledArgument = parseWithSpan . try $ do
      argumentLabel <- parseNameRef
      parsePunctuation PunctuationEquals
      expression <- parseExpression
      pure $ \sourceSpan ->
        CallArgument
          { label = argumentLabel,
            value = expression,
            sourceSpan = sourceSpan
          }
    sugarArgument = parseWithSpan $ do
      name <- parseNameRef
      pure $ \sourceSpan ->
        CallArgument
          { label = retagParsedNameRef name,
            value =
              ExpressionVariable
                VariableExpression
                  { name = name,
                    sourceSpan = sourceSpan,
                    typeOf = ()
                  },
            sourceSpan = sourceSpan
          }

-- ---------------------------------------------------------------------------
-- Primary expressions
-- ---------------------------------------------------------------------------

parsePrimaryExpression :: Parser (Expression Parsed)
parsePrimaryExpression =
  label "expression" $
    choice
      [ parseIfExpression,
        parseMatchExpression,
        parseForExpression False,
        parseParExpression,
        parseTemplateLiteral,
        parseLiteralExpression,
        parseArrayExpression,
        parseTupleOrGroupedExpression,
        parseBlockExpression,
        parseVariableExpression
      ]

-- | @par for (...)@ / @par (e, e)@ / @par [e, e]@ — parallel modifier.
-- Dispatches based on the token following @par@.
parseParExpression :: Parser (Expression Parsed)
parseParExpression = do
  _ <- MP.lookAhead (parseKeyword KeywordPar)
  choice
    [ -- par for (...) { ... }
      parseForExpression True,
      -- par (e1, e2, ...) — parallel tuple
      parseParTupleExpression,
      -- par [e1, e2, ...] — parallel array
      parseParArrayExpression
    ]

-- | @par (e1, e2, ...)@ — parallel tuple construction.
parseParTupleExpression :: Parser (Expression Parsed)
parseParTupleExpression = parseWithSpan $ do
  parseKeyword KeywordPar
  parsePunctuation PunctuationLeftParenthesis
  elements <- parseExpression `sepBy1` parsePunctuation PunctuationComma
  parsePunctuation PunctuationRightParenthesis
  pure $ \sourceSpan ->
    ExpressionParTuple
      ParTupleExpression
        { elements = elements,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

-- | @par [e1, e2, ...]@ — parallel array construction.
parseParArrayExpression :: Parser (Expression Parsed)
parseParArrayExpression = parseWithSpan $ do
  parseKeyword KeywordPar
  parsePunctuation PunctuationLeftBracket
  elements <- parseExpression `sepBy` parsePunctuation PunctuationComma
  _ <- optional (parsePunctuation PunctuationComma)
  parsePunctuation PunctuationRightBracket
  pure $ \sourceSpan ->
    ExpressionParArray
      ParArrayExpression
        { elements = elements,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

parseLiteralExpression :: Parser (Expression Parsed)
parseLiteralExpression = parseWithSpan $ do
  literal <- parseLiteralValue
  pure $ \sourceSpan ->
    ExpressionLiteral
      LiteralExpression
        { value = literal,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

parseLiteralValue :: Parser LiteralValue
parseLiteralValue =
  choice
    [ LiteralValueNull <$ parseKeyword KeywordNull,
      LiteralValueBoolean True <$ parseKeyword KeywordTrue,
      LiteralValueBoolean False <$ parseKeyword KeywordFalse,
      LiteralValueNumber <$> parseFloatLiteral,
      LiteralValueInteger <$> parseIntegerLiteral,
      LiteralValueString <$> parseStringLiteral
    ]

parseVariableExpression :: Parser (Expression Parsed)
parseVariableExpression = parseWithSpan $ do
  name <- parseNameRef
  pure $ \sourceSpan ->
    ExpressionVariable
      VariableExpression
        { name = name,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

parseArrayExpression :: Parser (Expression Parsed)
parseArrayExpression = parseWithSpan $ do
  elements <- parseBracketedList parseExpression
  pure $ \sourceSpan ->
    ExpressionArray
      ArrayExpression
        { elements = elements,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

-- | @(e)@ collapses to @e@ (grouped expression). @(e1, e2, ...)@ is a tuple.
-- A grouped expression keeps its inner span, so we cannot use 'parseWithSpan' here.
parseTupleOrGroupedExpression :: Parser (Expression Parsed)
parseTupleOrGroupedExpression = parseWithSpan $ do
  parsePunctuation PunctuationLeftParenthesis
  expressions <- parseExpression `sepEndBy` parseComma
  parsePunctuation PunctuationRightParenthesis
  pure $ \sourceSpan -> case expressions of
    [onlyExpression] -> onlyExpression
    _ ->
      ExpressionTuple
        TupleExpression
          { elements = expressions,
            sourceSpan = sourceSpan,
            typeOf = ()
          }

parseBlockExpression :: Parser (Expression Parsed)
parseBlockExpression = parseWithSpan $ do
  block <- parseBlock
  pure $ \sourceSpan ->
    ExpressionBlock
      BlockExpression
        { block = block,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

parseIfExpression :: Parser (Expression Parsed)
parseIfExpression = parseWithSpan $ do
  parseKeyword KeywordIf
  condition <-
    between
      (parsePunctuation PunctuationLeftParenthesis)
      (parsePunctuation PunctuationRightParenthesis)
      parseExpression
  thenBlock <- parseBlock
  elseBlock <- optional (parseKeyword KeywordElse *> parseBlock)
  pure $ \sourceSpan ->
    ExpressionIf
      IfExpression
        { condition = condition,
          thenBlock = thenBlock,
          elseBlock = elseBlock,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

parseMatchExpression :: Parser (Expression Parsed)
parseMatchExpression = parseWithSpan $ do
  parseKeyword KeywordMatch
  subject <-
    between
      (parsePunctuation PunctuationLeftParenthesis)
      (parsePunctuation PunctuationRightParenthesis)
      parseExpression
  cases <-
    between
      (parsePunctuation PunctuationLeftBrace)
      (parsePunctuation PunctuationRightBrace)
      (skipMany parseSemicolon *> many (parseCaseArm <* skipMany parseSemicolon))
  pure $ \sourceSpan ->
    ExpressionMatch
      MatchExpression
        { subject = subject,
          cases = cases,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

parseCaseArm :: Parser (CaseArm Parsed)
parseCaseArm = parseWithSpan $ do
  parseKeyword KeywordCase
  parsedPattern <- parsePattern
  parsePunctuation PunctuationFatArrow
  body <- parseBlock
  pure $ \sourceSpan ->
    CaseArm
      { pattern = parsedPattern,
        body = body,
        sourceSpan = sourceSpan
      }

parseForExpression :: Bool -> Parser (Expression Parsed)
parseForExpression parallel = parseWithSpan $ do
  when parallel (void $ parseKeyword KeywordPar)
  parseKeyword KeywordFor
  (inBindings, varBindings) <-
    between
      (parsePunctuation PunctuationLeftParenthesis)
      (parsePunctuation PunctuationRightParenthesis)
      parseForBindings
  body <- parseWithBreakContext BreakContextFor parseBlock
  thenBlock <- optional (parseKeyword KeywordThen *> parseBlock)
  pure $ \sourceSpan ->
    ExpressionFor
      ForExpression
        { parallel = parallel,
          inBindings = inBindings,
          varBindings = varBindings,
          body = body,
          thenBlock = thenBlock,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

-- | For-binding list: all `pattern in expr` bindings come first, then all
-- `var name = expr` bindings. Mixing is rejected with a clear message.
parseForBindings :: Parser ([ForInBinding Parsed], [ForVarBinding Parsed])
parseForBindings = do
  inBindings <- parseForInBinding `sepEndBy` parseComma
  varBindings <- parseForVarBinding `sepEndBy` parseComma
  -- After all vars, if a `pattern in ...` still follows, it's an order violation.
  violation <-
    MP.lookAhead . optional . try $ do
      _ <- parsePattern
      parseKeyword KeywordIn
  case violation of
    Just () -> fail "'in' binding cannot follow 'var' binding in 'for'"
    Nothing -> pure (inBindings, varBindings)

parseForInBinding :: Parser (ForInBinding Parsed)
parseForInBinding = parseWithSpan $ do
  -- Decide-and-commit: try the "pattern in" prefix, then commit to the RHS.
  parsedPattern <- try $ do
    parsedPattern <- parsePattern
    parseKeyword KeywordIn
    pure parsedPattern
  expression <- parseExpression
  pure $ \sourceSpan ->
    ForInBinding
      { pattern = parsedPattern,
        source = expression,
        sourceSpan = sourceSpan
      }

parseForVarBinding :: Parser (ForVarBinding Parsed)
parseForVarBinding = parseWithSpan $ do
  parseKeyword KeywordVar
  name <- parseNameRef
  typeAnnotation <- optional (parsePunctuation PunctuationColon *> parseType)
  parsePunctuation PunctuationEquals
  expression <- parseExpression
  pure $ \sourceSpan ->
    ForVarBinding
      { name = name,
        typeAnnotation = typeAnnotation,
        initial = expression,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Template literals
-- ---------------------------------------------------------------------------

parseTemplateLiteral :: Parser (Expression Parsed)
parseTemplateLiteral = parseWithSpan $ do
  parseExactKatariToken KatariTokenTemplateOpen
  parts <- many parseTemplateElement
  parseExactKatariToken KatariTokenTemplateClose
  pure $ \sourceSpan ->
    ExpressionTemplate
      TemplateExpression
        { elements = parts,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

parseTemplateElement :: Parser (TemplateElement Parsed)
parseTemplateElement =
  choice
    [ parseWithSpan $ do
        text <- parseTemplateStringKatariToken
        pure $ \sourceSpan ->
          TemplateElementString
            TemplateStringElement
              { value = text,
                sourceSpan = sourceSpan
              },
      parseWithSpan $ do
        parseExactKatariToken KatariTokenTemplateExpressionOpen
        expression <- parseExpression
        parseExactKatariToken KatariTokenTemplateExpressionClose
        pure $ \sourceSpan ->
          TemplateElementExpression
            TemplateExpressionElement
              { value = expression,
                sourceSpan = sourceSpan
              }
    ]
  where
    parseTemplateStringKatariToken = parseKatariTokenWith $ \case
      KatariTokenTemplateString text -> Just text
      _ -> Nothing

-- ===========================================================================
-- Patterns
-- ===========================================================================

-- | Pattern dispatch. Constructor patterns are syntactically distinguished
-- by being qualified (@enum.ctor(...)@ or @module.enum.ctor(...)@). Bare
-- identifiers are always variable patterns.
parsePattern :: Parser (Pattern Parsed)
parsePattern =
  label "pattern" $
    choice
      [ try parseQualifiedConstructorPattern,
        parseVariablePattern,
        parseWildcardPattern,
        parseTupleOrGroupedPattern,
        parseLiteralPattern
      ]

-- | @ctor(...)@ or @module.ctor(...)@. Use @try@ to peek the prefix
-- (@Ident [.Ident]?@) plus the opening paren before committing; that way a
-- bare @ident@ without parens falls through to 'parseVariablePattern'.
parseQualifiedConstructorPattern :: Parser (Pattern Parsed)
parseQualifiedConstructorPattern = parseWithSpan $ do
  (maybeModule, constructorName) <- try $ do
    -- Parse the leading identifier as a variable; it may later be retagged as
    -- a module qualifier if a @.@ follows.
    first <- parseNameRef :: Parser (NameRef Parsed VariableRef)
    second <- optional (parsePunctuation PunctuationDot *> parseNameRef)
    -- Only commit to a constructor pattern once we see the opening paren.
    void $ MP.lookAhead (parsePunctuation PunctuationLeftParenthesis)
    -- The constructor name is a ConstructorRef'; resolution will require it
    -- to name a @data@ declaration.
    pure $ case second of
      Nothing -> (Nothing, retagParsedNameRef first)
      Just secondNameRef ->
        (Just (retagParsedNameRef first), retagParsedNameRef secondNameRef)
  parsePunctuation PunctuationLeftParenthesis
  fields <- parsePatternField `sepEndBy` parseComma
  parsePunctuation PunctuationRightParenthesis
  pure $ \sourceSpan ->
    PatternQualifiedConstructor
      QualifiedConstructorPattern
        { moduleQualifier = maybeModule,
          constructorName = constructorName,
          parameters = fields,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

parseWildcardPattern :: Parser (Pattern Parsed)
parseWildcardPattern = parseWithSpan $ do
  parseUnderscore
  typeAnnotation <- optional (parsePunctuation PunctuationColon *> parseType)
  pure $ \sourceSpan ->
    PatternWildcard
      WildcardPattern
        { typeAnnotation = typeAnnotation,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

parseVariablePattern :: Parser (Pattern Parsed)
parseVariablePattern = parseWithSpan $ do
  name <- parseNameRef
  typeAnnotation <- optional (parsePunctuation PunctuationColon *> parseType)
  pure $ \sourceSpan ->
    PatternVariable
      VariablePattern
        { name = name,
          typeAnnotation = typeAnnotation,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

parsePatternField :: Parser (NameRef Parsed LabelRef, Pattern Parsed)
parsePatternField = labeled <|> sugar
  where
    labeled = try $ do
      fieldLabel <- parseNameRef
      parsePunctuation PunctuationEquals
      parsedPattern <- parsePattern
      pure (fieldLabel, parsedPattern)
    sugar = parseWithSpan $ do
      name <- parseNameRef
      typeAnnotation <- optional (parsePunctuation PunctuationColon *> parseType)
      pure $ \sourceSpan ->
        ( retagParsedNameRef name,
          PatternVariable
            VariablePattern
              { name = name,
                typeAnnotation = typeAnnotation,
                sourceSpan = sourceSpan,
                typeOf = ()
              }
        )

-- | @(p)@ collapses to @p@ (grouped pattern). @(p, q, ...)@ is a tuple.
-- A grouped pattern keeps its inner span, so we cannot use 'parseWithSpan' here.
parseTupleOrGroupedPattern :: Parser (Pattern Parsed)
parseTupleOrGroupedPattern = parseWithSpan $ do
  parsePunctuation PunctuationLeftParenthesis
  patterns <- parsePattern `sepEndBy` parseComma
  parsePunctuation PunctuationRightParenthesis
  pure $ \sourceSpan -> case patterns of
    [onlyPattern] -> onlyPattern
    _ ->
      PatternTuple
        TuplePattern
          { elements = patterns,
            sourceSpan = sourceSpan,
            typeOf = ()
          }

parseLiteralPattern :: Parser (Pattern Parsed)
parseLiteralPattern = parseWithSpan $ do
  literal <- parseLiteralValue
  pure $ \sourceSpan ->
    PatternLiteral
      LiteralPattern
        { value = literal,
          sourceSpan = sourceSpan,
          typeOf = ()
        }

-- ===========================================================================
-- Types
-- ===========================================================================

-- | Top-level entry point for a type expression. Unions live at the outermost
-- layer so they have the lowest precedence.
parseType :: Parser (SyntacticType Parsed)
parseType = label "type" parseUnionType

-- | Read @T1 | T2 | ...@ as a sequence of atomic types separated by @|@.
-- If there is only one branch, return the atomic type as-is; otherwise wrap
-- the branches in a 'TypeUnion'. Leading pipes (@| T@) are not accepted
-- (because @parseAtomicType@ does not consume @|@ — the input fails
-- naturally). A single trailing pipe (@T |@) is allowed for convenience in
-- multi-line declarations.
--
-- A single-branch union returns the inner atomic type unchanged (preserving
-- its own span), so 'parseWithSpan' is not used here.
parseUnionType :: Parser (SyntacticType Parsed)
parseUnionType = parseWithSpan $ do
  first <- parseAtomicType
  rest <- many (try (parsePunctuation PunctuationPipe *> parseAtomicType))
  -- Allow a trailing pipe: a stray @|@ after the last branch is consumed if
  -- present. No type-position follower is @|@, so this never consumes
  -- something it shouldn't.
  _ <- optional (try (parsePunctuation PunctuationPipe))
  pure $ \sourceSpan -> case rest of
    [] -> first
    _ -> TypeUnion TypeUnionNode {branches = first : rest, sourceSpan = sourceSpan}

-- | The branches of a union (i.e. everything that was previously @parseType@).
parseAtomicType :: Parser (SyntacticType Parsed)
parseAtomicType =
  choice
    [ parsePrimitiveType PrimitiveTypeKindNull KeywordNull,
      parsePrimitiveType PrimitiveTypeKindInteger KeywordInteger,
      parsePrimitiveType PrimitiveTypeKindNumber KeywordNumber,
      parsePrimitiveType PrimitiveTypeKindString KeywordString,
      parsePrimitiveType PrimitiveTypeKindBoolean KeywordBoolean,
      parseNeverType,
      parseUnknownType,
      parseLiteralType,
      try parseArrayType,
      try parseFunctionType,
      parseTupleOrGroupedType,
      parseNamedOrQualifiedType
    ]

-- | @never@ — lattice の bottom 型。
parseNeverType :: Parser (SyntacticType Parsed)
parseNeverType = parseWithSpan $ do
  parseKeyword KeywordNever
  pure $ \sourceSpan -> TypeNever NeverTypeNode {sourceSpan = sourceSpan}

-- | @unknown@ — lattice の top 型。
parseUnknownType :: Parser (SyntacticType Parsed)
parseUnknownType = parseWithSpan $ do
  parseKeyword KeywordUnknown
  pure $ \sourceSpan -> TypeUnknown UnknownTypeNode {sourceSpan = sourceSpan}

-- | Literal type: @"a"@, @42@, @true@, or @false@.
-- @null@ is intentionally omitted: 'parsePrimitiveType' already handles the
-- @null@ keyword as 'PrimitiveTypeKindNull', and the semantics are equivalent.
parseLiteralType :: Parser (SyntacticType Parsed)
parseLiteralType = parseWithSpan $ do
  value <-
    choice
      [ LiteralValueString <$> parseStringLiteral,
        LiteralValueInteger <$> parseIntegerLiteral,
        LiteralValueBoolean True <$ parseKeyword KeywordTrue,
        LiteralValueBoolean False <$ parseKeyword KeywordFalse
      ]
  pure $ \sourceSpan -> TypeLiteral TypeLiteralNode {value = value, sourceSpan = sourceSpan}

parsePrimitiveType :: PrimitiveTypeKind -> Keyword -> Parser (SyntacticType Parsed)
parsePrimitiveType primitiveKind keyword = parseWithSpan $ do
  parseKeyword keyword
  pure $ \sourceSpan ->
    TypePrimitive
      PrimitiveTypeNode
        { kind = primitiveKind,
          sourceSpan = sourceSpan
        }

-- | @Name@ or @module.TypeName@. The leading identifier is tentatively
-- parsed as a VariableRef' (the polymorphic 'parseNameRef' can produce any
-- symbol kind, but fixing it here gives the case branches a single source
-- type to retag from).
parseNamedOrQualifiedType :: Parser (SyntacticType Parsed)
parseNamedOrQualifiedType = parseWithSpan $ do
  first <- parseNameRef :: Parser (NameRef Parsed VariableRef)
  maybeSecond <- optional (parsePunctuation PunctuationDot *> parseNameRef)
  pure $ \sourceSpan -> case maybeSecond of
    Nothing ->
      TypeName
        TypeNameNode
          { name = retagParsedNameRef first,
            sourceSpan = sourceSpan
          }
    Just second ->
      TypeQualified
        QualifiedTypeNode
          { qualifier = retagParsedNameRef first,
            target = second,
            sourceSpan = sourceSpan
          }

parseFunctionType :: Parser (SyntacticType Parsed)
parseFunctionType = parseWithSpan $ do
  parameterTypes <- parseParenthesizedList parseFunctionTypeParameter
  parsePunctuation PunctuationArrow
  returnType <- parseType
  requests <- option [] (parseKeyword KeywordWith *> parseRequests)
  pure $ \sourceSpan ->
    TypeFunction
      FunctionTypeNode
        { parameterTypes = parameterTypes,
          returnType = returnType,
          withRequests = requests,
          sourceSpan = sourceSpan
        }

parseFunctionTypeParameter :: Parser (Text, SyntacticType Parsed)
parseFunctionTypeParameter = do
  name <- parseIdentifier
  parsePunctuation PunctuationColon
  typeAnnotation <- parseType
  pure (name, typeAnnotation)

-- | @array[T]@. The Kataritoken @array@ is a regular identifier, not a keyword,
-- so we match it by string and rely on the surrounding @[...]@ to confirm.
parseArrayType :: Parser (SyntacticType Parsed)
parseArrayType = parseWithSpan $ do
  void $ parseKatariTokenWith $ \case
    KatariTokenIdentifier "array" -> Just ()
    _ -> Nothing
  parsePunctuation PunctuationLeftBracket
  elementType <- parseType
  parsePunctuation PunctuationRightBracket
  pure $ \sourceSpan ->
    TypeArray
      ArrayTypeNode
        { elementType = elementType,
          sourceSpan = sourceSpan
        }

-- | @(T)@ collapses to @T@ (grouped type). @(A, B, ...)@ is a tuple.
-- @()@ is the empty tuple type. A single-element grouping keeps its inner
-- span, so we cannot use 'parseWithSpan' here.
parseTupleOrGroupedType :: Parser (SyntacticType Parsed)
parseTupleOrGroupedType = parseWithSpan $ do
  parsePunctuation PunctuationLeftParenthesis
  types <- parseType `sepEndBy` parseComma
  parsePunctuation PunctuationRightParenthesis
  pure $ \sourceSpan -> case types of
    [onlyType] -> onlyType
    _ ->
      TypeTuple
        TupleTypeNode
          { elementTypes = types,
            sourceSpan = sourceSpan
          }

-- ===========================================================================
-- Requests / parameters
-- ===========================================================================

parseRequests :: Parser [SyntacticRequest Parsed]
parseRequests = parseRequest `sepBy1` parseComma

parseRequest :: Parser (SyntacticRequest Parsed)
parseRequest = parseWithSpan $ do
  name <- parseNameRef
  pure $ \sourceSpan -> SyntacticRequest {name = name, sourceSpan = sourceSpan}

parseParameterList :: Parser [ParameterBinding Parsed]
parseParameterList =
  label "parameter list" $ parseParenthesizedList parseParameterBinding

parseParameterBinding :: Parser (ParameterBinding Parsed)
parseParameterBinding = parseWithSpan $ do
  annotation <- parseAnnotation
  (parameterLabel, parsedPattern) <- labeledParameter <|> sugarParameter
  pure $ \sourceSpan ->
    ParameterBinding
      { annotation = annotation,
        label = parameterLabel,
        pattern = parsedPattern,
        sourceSpan = sourceSpan
      }
  where
    labeledParameter = try $ do
      parameterLabel <- parseIdentifier
      parsePunctuation PunctuationEquals
      parsedPattern <- parsePattern
      pure (parameterLabel, parsedPattern)
    sugarParameter = parseWithSpan $ do
      name <- parseNameRef
      typeAnnotation <- optional (parsePunctuation PunctuationColon *> parseType)
      pure $ \patternSpan ->
        ( name.text,
          PatternVariable
            VariablePattern
              { name = name,
                typeAnnotation = typeAnnotation,
                sourceSpan = patternSpan,
                typeOf = ()
              }
        )
