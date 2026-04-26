module Katari.Parser (Parsed (..), parseModule) where

import Control.Monad (void)
import Control.Monad.Combinators.Expr (makeExprParser)
import Control.Monad.Combinators.Expr qualified as Expr
import Control.Monad.Reader (ReaderT, asks, local, runReaderT)
import Control.Monad.State.Strict (StateT, evalStateT, get, put)
import Control.Monad.Trans (lift)
import Data.Foldable (foldl')
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Katari.AST
import Katari.Lexer
  ( Keyword (..),
    Operator (..),
    Punctuation (..),
    Token (..),
    TokenStream (..),
    WithSourceSpan (..),
    insertVirtualSemicolons,
    runLexer,
  )
import Text.Megaparsec hiding (Token, Tokens)
import Text.Megaparsec qualified as MP
import Katari.Prelude

-- ===========================================================================
-- Types
-- ===========================================================================

-- | Metadata marker for the freshly parsed AST phase. Carries no semantic
-- information yet; later compiler phases replace this with richer markers
-- (e.g. @Identified@, @Typed@) that live in their own modules.
data Parsed (symbol :: SymbolKind) = Parsed
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

-- | The inner StateT holds the end position of the most recently consumed
-- token, so span-end can be recovered accurately (getSourcePos only sees the
-- start of the next unconsumed token).
type Parser = ReaderT ParserEnv (StateT (Maybe Position) (Parsec Void TokenStream))

askFilePath :: Parser FilePath
askFilePath = asks (.filePath)

askBreakContext :: Parser BreakContext
askBreakContext = asks (.breakContext)

withBreakContext :: BreakContext -> Parser a -> Parser a
withBreakContext context = local (\env -> env {breakContext = context})

-- | Build a @SourceSpan@ using the current file path held in the environment.
makeSpan :: Position -> Position -> Parser SourceSpan
makeSpan startPosition endPosition = do
  fp <- askFilePath
  pure (SrcSpan fp startPosition endPosition)

-- ===========================================================================
-- Public API
-- ===========================================================================

parseModule :: FilePath -> Text -> Either String (Module Parsed)
parseModule filePath input = case runLexer filePath input of
  Left err -> Left (errorBundlePretty err)
  Right rawTokens ->
    let stream = TokenStream input (insertVirtualSemicolons rawTokens)
        env = ParserEnv {filePath = filePath, breakContext = BreakContextTop}
        action = evalStateT (runReaderT (parseModuleBody <* eof) env) Nothing
     in case runParser action filePath stream of
          Left err -> Left (errorBundlePretty err)
          Right parsed -> Right parsed

-- ===========================================================================
-- Token primitives
-- ===========================================================================

-- | Consume any token matching a predicate, returning the unwrapped value.
-- Also records the end position of the consumed token in parser state so that
-- 'parsePreviousEndPosition' can recover the end of the most recently consumed
-- token (which is what we want for closing source spans).
parseTokenWith :: (Token -> Maybe value) -> Parser value
parseTokenWith predicate = do
  (result, endPos) <- MP.token testToken Set.empty
  lift (put (Just endPos))
  pure result
  where
    testToken (WithSourceSpan span_ inputToken) = do
      result <- predicate inputToken
      Just (result, span_.end)

-- | Consume an exact token (using equality on the Token type).
parseExactToken :: Token -> Parser ()
parseExactToken expected = void $ parseTokenWith (\actual -> if actual == expected then Just () else Nothing)

parseKeyword :: Keyword -> Parser ()
parseKeyword keyword = parseExactToken (TokenKeyword keyword)

parsePunctuation :: Punctuation -> Parser ()
parsePunctuation punctuation = parseExactToken (TokenPunctuation punctuation)

parseOperator :: Operator -> Parser ()
parseOperator operator = parseExactToken (TokenOperator operator)

-- | Consume any semicolon (explicit or virtual).
parseSemicolon :: Parser ()
parseSemicolon = parseTokenWith $ \case
  TokenSemicolonExplicit -> Just ()
  TokenSemicolonVirtual -> Just ()
  _ -> Nothing

parseComma :: Parser ()
parseComma = parsePunctuation PunctuationComma

-- | Identifier token (bare `_` is a separate token, not TokenIdentifier).
parseIdentifier :: Parser Text
parseIdentifier = parseTokenWith $ \case
  TokenIdentifier text -> Just text
  _ -> Nothing

-- | Bare underscore — only consumed when explicitly requested (wildcard pattern).
parseUnderscore :: Parser ()
parseUnderscore = parseExactToken TokenUnderscore

parseIntegerLiteral :: Parser Integer
parseIntegerLiteral = parseTokenWith $ \case
  TokenIntegerLiteral integer -> Just integer
  _ -> Nothing

parseFloatLiteral :: Parser Double
parseFloatLiteral = parseTokenWith $ \case
  TokenFloatLiteral double -> Just double
  _ -> Nothing

parseStringLiteral :: Parser Text
parseStringLiteral = parseTokenWith $ \case
  TokenStringLiteral text -> Just text
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
-- parseCurrentPosition when no token has been consumed yet in this parse.
parsePreviousEndPosition :: Parser Position
parsePreviousEndPosition = do
  maybeLastEndPosition <- lift get
  maybe parseCurrentPosition pure maybeLastEndPosition

-- | Parse an identifier and wrap it into a @NameRef Parsed symbol@.
-- The symbol is determined by the type at the call site.
parseNameRef :: Parser (NameRef Parsed symbol)
parseNameRef = do
  startPosition <- parseCurrentPosition
  text <- parseIdentifier
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure NameRef {text = text, sourceSpan = sourceSpan, metadata = Parsed}

-- | Repurpose a parsed @NameRef@ under a different symbol. Used at sugar
-- desugaring sites (e.g. @foo(x)@ → @foo(x = x)@) where the same identifier
-- plays two roles (label + variable).
coerceNameRefSymbol :: NameRef Parsed anySymbol -> NameRef Parsed otherSymbol
coerceNameRefSymbol nameRef =
  NameRef {text = nameRef.text, sourceSpan = nameRef.sourceSpan, metadata = Parsed}

-- ===========================================================================
-- Module
-- ===========================================================================

parseModuleBody :: Parser (Module Parsed)
parseModuleBody = do
  startPosition <- parseCurrentPosition
  skipMany parseSemicolon
  declarations <- parseDeclaration `sepEndBy` some parseSemicolon
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    Module
      { declarations = declarations,
        sourceSpan = sourceSpan
      }

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
    [ DeclarationExternalAgent <$> parseExternalAgent annotation,
      DeclarationAgent <$> parseAgent annotation,
      DeclarationRequest <$> parseRequest annotation,
      DeclarationData <$> parseData annotation
    ]

parseAnnotation :: Parser (Maybe Text)
parseAnnotation = optional $ parsePunctuation PunctuationAt *> parseStringLiteral

-- ---------------------------------------------------------------------------
-- Agent
-- ---------------------------------------------------------------------------

parseAgent :: Maybe Text -> Parser (AgentDeclaration Parsed)
parseAgent annotation = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordAgent
  name <- parseNameRef
  parameters <- parseParameterList
  returnType <- optional (parsePunctuation PunctuationArrow *> parseType)
  effects <- optional (parseKeyword KeywordWith *> parseEffects)
  body <- withBreakContext BreakContextTop parseBlock
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    AgentDeclaration
      { annotation = annotation,
        name = name,
        parameters = parameters,
        returnType = returnType,
        withEffects = effects,
        body = body,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Request
-- ---------------------------------------------------------------------------

parseRequest :: Maybe Text -> Parser (RequestDeclaration Parsed)
parseRequest annotation = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordReq
  name <- parseNameRef
  parameters <- parseParameterList
  parsePunctuation PunctuationArrow
  returnType <- parseType
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    RequestDeclaration
      { annotation = annotation,
        name = name,
        parameters = parameters,
        returnType = returnType,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- External Agent
-- ---------------------------------------------------------------------------

parseExternalAgent :: Maybe Text -> Parser (ExternalAgentDeclaration Parsed)
parseExternalAgent annotation = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordExt
  parseKeyword KeywordAgent
  name <- parseNameRef
  parameters <- parseParameterList
  parsePunctuation PunctuationArrow
  returnType <- parseType
  parseKeyword KeywordWith
  effects <- parseEffects
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    ExternalAgentDeclaration
      { annotation = annotation,
        name = name,
        parameters = parameters,
        returnType = returnType,
        withEffects = effects,
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
parseData :: Maybe Text -> Parser (DataDeclaration Parsed)
parseData annotation = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordData
  name <- parseNameRef
  parameters <-
    between
      (parsePunctuation PunctuationLeftParenthesis)
      (parsePunctuation PunctuationRightParenthesis)
      (parseDataParameter `sepEndBy` parseComma)
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    DataDeclaration
      { annotation = annotation,
        name = name,
        parameters = parameters,
        sourceSpan = sourceSpan
      }

parseDataParameter :: Parser (DataParameter Parsed)
parseDataParameter = do
  startPosition <- parseCurrentPosition
  annotation <- parseAnnotation
  name <- parseIdentifier
  parsePunctuation PunctuationColon
  parameterType <- parseType
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
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
parseTypeSynonym = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordType
  name <- parseNameRef
  parsePunctuation PunctuationEquals
  rhs <- parseType
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    TypeSynonymDeclaration
      { name = name,
        rhs = rhs,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Import
-- ---------------------------------------------------------------------------

parseImport :: Parser (ImportDeclaration Parsed)
parseImport = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordImport
  importKind <-
    choice
      [ do
          items <-
            between
              (parsePunctuation PunctuationLeftBrace)
              (parsePunctuation PunctuationRightBrace)
              (parseImportItem `sepEndBy` parseComma)
          parseKeyword KeywordFrom
          moduleName <- parseModulePath
          pure ImportNames {items = items, moduleName = moduleName},
        do
          moduleName <- parseModulePath
          alias <- optional (parseKeyword KeywordAs *> parseIdentifier)
          pure ImportModule {moduleName = moduleName, alias = alias}
      ]
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    ImportDeclaration
      { kind = importKind,
        sourceSpan = sourceSpan
      }

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
parseBlock = do
  startPosition <- parseCurrentPosition
  parsePunctuation PunctuationLeftBrace
  skipMany parseSemicolon
  (statements, returnExpression) <- parseBlockBody
  parsePunctuation PunctuationRightBrace
  detectSameLineKeywordViolation
  whereBlock <- optional parseWhereBlock
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    Block
      { statements = statements,
        returnExpression = returnExpression,
        whereBlock = whereBlock,
        sourceSpan = sourceSpan
      }

-- | After consuming a closing @}@, detect the pattern
-- @TokenSemicolonVirtual + (else|then|where)@ — a virtual semi sits there only
-- if the user put a newline between @}@ and the keyword. CLAUDE.md requires
-- these keywords to be on the same line as the preceding @}@.
--
-- The lookahead does NOT consume input; the keyword name is reported in a
-- specific error so users get a clear message.
detectSameLineKeywordViolation :: Parser ()
detectSameLineKeywordViolation = do
  violation <- MP.lookAhead . optional . try $ do
    parseTokenWith $ \case
      TokenSemicolonVirtual -> Just ()
      _ -> Nothing
    parseTokenWith $ \case
      TokenKeyword KeywordElse -> Just "else"
      TokenKeyword KeywordThen -> Just "then"
      TokenKeyword KeywordWhere -> Just "where"
      _ -> Nothing
  case violation of
    Just keyword -> fail $ "'" <> keyword <> "' must be on the same line as the preceding '}'"
    Nothing -> pure ()

-- | One-pass block body: parse statements in order; the last expression
-- without a trailing `;` becomes the return expression.
parseBlockBody :: Parser ([Statement Parsed], Maybe (Expression Parsed))
parseBlockBody = loop []
  where
    loop reversedStatements = do
      -- First try non-expression statements (let/agent/return/break/next).
      maybeNonExpression <- optional parseNonExpressionStatement
      case maybeNonExpression of
        Just statement -> loop (statement : reversedStatements)
        Nothing -> do
          -- Then try an expression; if followed by `;` it's a statement,
          -- otherwise it's the trailing return expression.
          maybeExpression <- optional parseExpression
          case maybeExpression of
            Nothing -> pure (reverse reversedStatements, Nothing)
            Just expression -> do
              hasSemicolon <- optional (some parseSemicolon)
              case hasSemicolon of
                Just _ -> loop (StatementExpression expression : reversedStatements)
                Nothing -> pure (reverse reversedStatements, Just expression)

parseNonExpressionStatement :: Parser (Statement Parsed)
parseNonExpressionStatement =
  choice
    [ StatementLet <$> parseLet <* trailingSemicolons,
      StatementAgent <$> parseAgentStatement <* trailingSemicolons,
      StatementReturn <$> parseReturn <* trailingSemicolons,
      parseBreakOrNextStatement <* trailingSemicolons
    ]
  where
    trailingSemicolons = void (some parseSemicolon)

parseWhereBlock :: Parser (WhereBlock Parsed)
parseWhereBlock = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordWhere
  stateVariables <-
    option [] . try $
      between
        (parsePunctuation PunctuationLeftParenthesis)
        (parsePunctuation PunctuationRightParenthesis)
        (parseStateVariable `sepEndBy` parseComma)
  parsePunctuation PunctuationLeftBrace
  skipMany parseSemicolon
  handlers <- many (parseRequestHandler <* skipMany parseSemicolon)
  parsePunctuation PunctuationRightBrace
  detectSameLineKeywordViolation
  thenClause <- optional parseThenClause
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    WhereBlock
      { stateVariables = stateVariables,
        handlers = handlers,
        thenClause = thenClause,
        sourceSpan = sourceSpan
      }

parseStateVariable :: Parser (StateVariableBinding Parsed)
parseStateVariable = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordVar
  name <- parseNameRef
  typeAnnotation <- optional (parsePunctuation PunctuationColon *> parseType)
  parsePunctuation PunctuationEquals
  expression <- parseExpression
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    StateVariableBinding
      { name = name,
        typeAnnotation = typeAnnotation,
        initial = expression,
        sourceSpan = sourceSpan
      }

-- | @then@ 節:
--
--   * @then(pat) { ... }@ → @(Just pat, block)@
--   * @then       { ... }@ → @(Nothing,  block)@
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

parseRequestHandler :: Parser (RequestHandler Parsed)
parseRequestHandler = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordReq
  -- Either @req name(...)@ or @req module.name(...)@: if a @.@ follows the
  -- first identifier, treat it as a qualified handler; otherwise bare.
  first <- parseNameRef
  (moduleQualifier, name) <-
    optional (parsePunctuation PunctuationDot *> parseNameRef) >>= \case
      Just second -> pure (Just (coerceNameRefSymbol first), second)
      Nothing -> pure (Nothing, first)
  parameters <- parseParameterList
  returnType <- optional (parsePunctuation PunctuationArrow *> parseType)
  effects <- optional (parseKeyword KeywordWith *> parseEffects)
  body <- withBreakContext BreakContextHandler parseBlock
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    RequestHandler
      { moduleQualifier = moduleQualifier,
        name = name,
        parameters = parameters,
        returnType = returnType,
        withEffects = effects,
        body = body,
        sourceSpan = sourceSpan
      }

parseAgentStatement :: Parser (AgentStatement Parsed)
parseAgentStatement = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordAgent
  name <- parseNameRef
  parameters <- parseParameterList
  returnType <- optional (parsePunctuation PunctuationArrow *> parseType)
  effects <- optional (parseKeyword KeywordWith *> parseEffects)
  body <- withBreakContext BreakContextTop parseBlock
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    AgentStatement
      { name = name,
        parameters = parameters,
        returnType = returnType,
        withEffects = effects,
        body = body,
        sourceSpan = sourceSpan
      }

parseBreakOrNextStatement :: Parser (Statement Parsed)
parseBreakOrNextStatement = do
  context <- askBreakContext
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
parseForBreak = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordBreak
  expression <- parseExpression
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    ForBreakStatement
      { value = expression,
        sourceSpan = sourceSpan
      }

parseLet :: Parser (LetStatement Parsed)
parseLet = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordLet
  parsedPattern <- parsePattern
  parsePunctuation PunctuationEquals
  expression <- parseExpression
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    LetStatement
      { pattern = parsedPattern,
        value = expression,
        sourceSpan = sourceSpan
      }

parseReturn :: Parser (ReturnStatement Parsed)
parseReturn = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordReturn
  expression <- parseExpression
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    ReturnStatement
      { value = expression,
        sourceSpan = sourceSpan
      }

parseNext :: Parser (NextStatement Parsed)
parseNext = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordNext
  expression <- parseExpression
  modifiers <- option [] (parseKeyword KeywordWith *> parseModifiers)
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    NextStatement
      { value = expression,
        modifiers = modifiers,
        sourceSpan = sourceSpan
      }

parseForNext :: Parser (ForNextStatement Parsed)
parseForNext = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordNext
  modifiers <- option [] (parseKeyword KeywordWith *> parseModifiers)
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    ForNextStatement
      { modifiers = modifiers,
        sourceSpan = sourceSpan
      }

parseBreak :: Parser (BreakStatement Parsed)
parseBreak = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordBreak
  expression <- parseExpression
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    BreakStatement
      { value = expression,
        sourceSpan = sourceSpan
      }

parseModifiers :: Parser [Modifier Parsed]
parseModifiers =
  between
    (parsePunctuation PunctuationLeftBrace)
    (parsePunctuation PunctuationRightBrace)
    (parseModifier `sepEndBy` parseComma)

parseModifier :: Parser (Modifier Parsed)
parseModifier = do
  startPosition <- parseCurrentPosition
  name <- parseNameRef
  parsePunctuation PunctuationEquals
  expression <- parseExpression
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    Modifier
      { name = name,
        value = expression,
        sourceSpan = sourceSpan
      }

-- ===========================================================================
-- Expressions
-- ===========================================================================

parseExpression :: Parser (Expression Parsed)
parseExpression = makeExprParser parsePostfixExpression expressionOperatorTable

expressionOperatorTable :: [[Expr.Operator Parser (Expression Parsed)]]
expressionOperatorTable =
  [ [ prefixOperator (parseOperator OperatorSubtract) UnaryOperatorNegate,
      prefixOperator (parseOperator OperatorNot) UnaryOperatorNot
    ],
    [ leftAssociativeBinaryOperator (parseOperator OperatorMultiply) BinaryOperatorMultiply,
      leftAssociativeBinaryOperator (parseOperator OperatorDivide) BinaryOperatorDivide
    ],
    [ leftAssociativeBinaryOperator (parseOperator OperatorAdd) BinaryOperatorAdd,
      leftAssociativeBinaryOperator (parseOperator OperatorSubtract) BinaryOperatorSubtract
    ],
    [leftAssociativeBinaryOperator (parseOperator OperatorConcat) BinaryOperatorConcat],
    [ nonAssociativeBinaryOperator (parseOperator OperatorLessOrEqual) BinaryOperatorLessOrEqual,
      nonAssociativeBinaryOperator (parseOperator OperatorGreaterOrEqual) BinaryOperatorGreaterOrEqual,
      nonAssociativeBinaryOperator (parseOperator OperatorLessThan) BinaryOperatorLessThan,
      nonAssociativeBinaryOperator (parseOperator OperatorGreaterThan) BinaryOperatorGreaterThan
    ],
    [ nonAssociativeBinaryOperator (parseOperator OperatorEqual) BinaryOperatorEqual,
      nonAssociativeBinaryOperator (parseOperator OperatorNotEqual) BinaryOperatorNotEqual
    ],
    [leftAssociativeBinaryOperator (parseOperator OperatorAnd) BinaryOperatorAnd],
    [leftAssociativeBinaryOperator (parseOperator OperatorOr) BinaryOperatorOr]
  ]

makeBinaryOperatorExpression :: FilePath -> BinaryOperator -> Expression Parsed -> Expression Parsed -> Expression Parsed
makeBinaryOperatorExpression fp binaryOperator left right =
  ExpressionBinaryOperator
    BinaryOperatorExpression
      { operator = binaryOperator,
        left = left,
        right = right,
        sourceSpan = SrcSpan fp (sourceSpanOf left).start (sourceSpanOf right).end,
        metadata = Parsed
      }

leftAssociativeBinaryOperator :: Parser () -> BinaryOperator -> Expr.Operator Parser (Expression Parsed)
leftAssociativeBinaryOperator parserAction binaryOperator = Expr.InfixL $ do
  parserAction
  fp <- askFilePath
  pure (makeBinaryOperatorExpression fp binaryOperator)

nonAssociativeBinaryOperator :: Parser () -> BinaryOperator -> Expr.Operator Parser (Expression Parsed)
nonAssociativeBinaryOperator parserAction binaryOperator = Expr.InfixN $ do
  parserAction
  fp <- askFilePath
  pure (makeBinaryOperatorExpression fp binaryOperator)

prefixOperator :: Parser () -> UnaryOperator -> Expr.Operator Parser (Expression Parsed)
prefixOperator parserAction unaryOperator = Expr.Prefix $ do
  startPosition <- parseCurrentPosition
  parserAction
  fp <- askFilePath
  pure $ \operand ->
    ExpressionUnaryOperator
      UnaryOperatorExpression
        { operator = unaryOperator,
          operand = operand,
          sourceSpan = SrcSpan fp startPosition (sourceSpanOf operand).end,
          metadata = Parsed
        }

-- ---------------------------------------------------------------------------
-- Postfix expressions
-- ---------------------------------------------------------------------------

data Postfix where
  PostfixCall :: [CallArgument Parsed] -> Position -> Postfix
  PostfixField :: NameRef Parsed 'LabelRef -> Position -> Postfix
  PostfixIndex :: Expression Parsed -> Position -> Postfix

parsePostfixExpression :: Parser (Expression Parsed)
parsePostfixExpression = do
  fp <- askFilePath
  primary <- parsePrimaryExpression
  postfixOperations <- many parsePostfix
  pure (foldl' (applyPostfixOperation fp) primary postfixOperations)

parsePostfix :: Parser Postfix
parsePostfix =
  choice
    [ parseCallPostfix,
      parseFieldPostfix,
      parseIndexPostfix
    ]

parseCallPostfix :: Parser Postfix
parseCallPostfix = do
  arguments <-
    between
      (parsePunctuation PunctuationLeftParenthesis)
      (parsePunctuation PunctuationRightParenthesis)
      (parseCallArgument `sepEndBy` parseComma)
  PostfixCall arguments <$> parsePreviousEndPosition

parseFieldPostfix :: Parser Postfix
parseFieldPostfix = do
  parsePunctuation PunctuationDot
  name <- parseNameRef
  PostfixField name <$> parsePreviousEndPosition

parseIndexPostfix :: Parser Postfix
parseIndexPostfix = do
  parsePunctuation PunctuationLeftBracket
  indexExpression <- parseExpression
  parsePunctuation PunctuationRightBracket
  PostfixIndex indexExpression <$> parsePreviousEndPosition

applyPostfixOperation :: FilePath -> Expression Parsed -> Postfix -> Expression Parsed
applyPostfixOperation fp expression = \case
  PostfixCall arguments endPosition ->
    ExpressionCall
      CallExpression
        { callee = expression,
          arguments = arguments,
          sourceSpan = SrcSpan fp (sourceSpanOf expression).start endPosition,
          metadata = Parsed
        }
  PostfixField fieldName endPosition ->
    ExpressionFieldAccess
      FieldAccessExpression
        { object = expression,
          fieldName = fieldName,
          sourceSpan = SrcSpan fp (sourceSpanOf expression).start endPosition,
          metadata = Parsed
        }
  PostfixIndex indexExpression endPosition ->
    ExpressionIndexAccess
      IndexAccessExpression
        { array = expression,
          index = indexExpression,
          sourceSpan = SrcSpan fp (sourceSpanOf expression).start endPosition,
          metadata = Parsed
        }

parseCallArgument :: Parser (CallArgument Parsed)
parseCallArgument = labeledArgument <|> sugarArgument
  where
    labeledArgument = try $ do
      startPosition <- parseCurrentPosition
      argumentLabel <- parseNameRef
      parsePunctuation PunctuationEquals
      expression <- parseExpression
      endPosition <- parsePreviousEndPosition
      sourceSpan <- makeSpan startPosition endPosition
      pure
        CallArgument
          { label = argumentLabel,
            value = expression,
            sourceSpan = sourceSpan
          }
    sugarArgument = do
      startPosition <- parseCurrentPosition
      name <- parseNameRef
      endPosition <- parsePreviousEndPosition
      sourceSpan <- makeSpan startPosition endPosition
      pure
        CallArgument
          { label = coerceNameRefSymbol name,
            value =
              ExpressionVariable
                VariableExpression
                  { name = name,
                    sourceSpan = sourceSpan,
                    metadata = Parsed
                  },
            sourceSpan = sourceSpan
          }

-- ---------------------------------------------------------------------------
-- Primary expressions
-- ---------------------------------------------------------------------------

parsePrimaryExpression :: Parser (Expression Parsed)
parsePrimaryExpression =
  choice
    [ parseIfExpression,
      parseMatchExpression,
      parseForExpression,
      parseTemplateLiteral,
      parseLiteralExpression,
      parseArrayExpression,
      parseTupleOrGroupedExpression,
      parseBlockExpression,
      parseVariableExpression
    ]

parseLiteralExpression :: Parser (Expression Parsed)
parseLiteralExpression = do
  startPosition <- parseCurrentPosition
  literal <- parseLiteralValue
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    ExpressionLiteral
      LiteralExpression
        { value = literal,
          sourceSpan = sourceSpan,
          metadata = Parsed
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
parseVariableExpression = do
  startPosition <- parseCurrentPosition
  name <- parseNameRef
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    ExpressionVariable
      VariableExpression
        { name = name,
          sourceSpan = sourceSpan,
          metadata = Parsed
        }

parseArrayExpression :: Parser (Expression Parsed)
parseArrayExpression = do
  startPosition <- parseCurrentPosition
  elements <-
    between
      (parsePunctuation PunctuationLeftBracket)
      (parsePunctuation PunctuationRightBracket)
      (parseExpression `sepEndBy` parseComma)
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    ExpressionArray
      ArrayExpression
        { elements = elements,
          sourceSpan = sourceSpan,
          metadata = Parsed
        }

parseTupleOrGroupedExpression :: Parser (Expression Parsed)
parseTupleOrGroupedExpression = do
  startPosition <- parseCurrentPosition
  parsePunctuation PunctuationLeftParenthesis
  expressions <- parseExpression `sepEndBy` parseComma
  parsePunctuation PunctuationRightParenthesis
  endPosition <- parsePreviousEndPosition
  case expressions of
    [onlyExpression] -> pure onlyExpression
    _ -> do
      sourceSpan <- makeSpan startPosition endPosition
      pure $
        ExpressionTuple
          TupleExpression
            { elements = expressions,
              sourceSpan = sourceSpan,
              metadata = Parsed
            }

parseBlockExpression :: Parser (Expression Parsed)
parseBlockExpression = do
  startPosition <- parseCurrentPosition
  block <- parseBlock
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    ExpressionBlock
      BlockExpression
        { block = block,
          sourceSpan = sourceSpan,
          metadata = Parsed
        }

parseIfExpression :: Parser (Expression Parsed)
parseIfExpression = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordIf
  condition <-
    between
      (parsePunctuation PunctuationLeftParenthesis)
      (parsePunctuation PunctuationRightParenthesis)
      parseExpression
  thenBlock <- parseBlock
  elseBlock <- optional (parseKeyword KeywordElse *> parseBlock)
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    ExpressionIf
      IfExpression
        { condition = condition,
          thenBlock = thenBlock,
          elseBlock = elseBlock,
          sourceSpan = sourceSpan,
          metadata = Parsed
        }

parseMatchExpression :: Parser (Expression Parsed)
parseMatchExpression = do
  startPosition <- parseCurrentPosition
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
      (many parseCaseArm)
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    ExpressionMatch
      MatchExpression
        { subject = subject,
          cases = cases,
          sourceSpan = sourceSpan,
          metadata = Parsed
        }

parseCaseArm :: Parser (CaseArm Parsed)
parseCaseArm = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordCase
  parsedPattern <- parsePattern
  parsePunctuation PunctuationFatArrow
  body <- parseBlock
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    CaseArm
      { pattern = parsedPattern,
        body = body,
        sourceSpan = sourceSpan
      }

parseForExpression :: Parser (Expression Parsed)
parseForExpression = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordFor
  (inBindings, varBindings) <-
    between
      (parsePunctuation PunctuationLeftParenthesis)
      (parsePunctuation PunctuationRightParenthesis)
      parseForBindings
  body <- withBreakContext BreakContextFor parseBlock
  thenBlock <- optional (parseKeyword KeywordThen *> parseBlock)
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    ExpressionFor
      ForExpression
        { inBindings = inBindings,
          varBindings = varBindings,
          body = body,
          thenBlock = thenBlock,
          sourceSpan = sourceSpan,
          metadata = Parsed
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
parseForInBinding = do
  startPosition <- parseCurrentPosition
  -- Decide-and-commit: try the "pattern in" prefix, then commit to the RHS.
  parsedPattern <- try $ do
    pat <- parsePattern
    parseKeyword KeywordIn
    pure pat
  expression <- parseExpression
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    ForInBinding
      { pattern = parsedPattern,
        source = expression,
        sourceSpan = sourceSpan
      }

parseForVarBinding :: Parser (ForVarBinding Parsed)
parseForVarBinding = do
  startPosition <- parseCurrentPosition
  parseKeyword KeywordVar
  name <- parseNameRef
  typeAnnotation <- optional (parsePunctuation PunctuationColon *> parseType)
  parsePunctuation PunctuationEquals
  expression <- parseExpression
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
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
parseTemplateLiteral = do
  startPosition <- parseCurrentPosition
  parseExactToken TokenTemplateOpen
  parts <- many parseTemplateElement
  parseExactToken TokenTemplateClose
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    ExpressionTemplate
      TemplateExpression
        { elements = parts,
          sourceSpan = sourceSpan,
          metadata = Parsed
        }

parseTemplateElement :: Parser (TemplateElement Parsed)
parseTemplateElement =
  choice
    [ do
        startPosition <- parseCurrentPosition
        text <- parseTemplateStringToken
        endPosition <- parsePreviousEndPosition
        sourceSpan <- makeSpan startPosition endPosition
        pure $
          TemplateElementString
            TemplateStringElement
              { value = text,
                sourceSpan = sourceSpan
              },
      do
        startPosition <- parseCurrentPosition
        parseExactToken TokenTemplateExpressionOpen
        expression <- parseExpression
        parseExactToken TokenTemplateExpressionClose
        endPosition <- parsePreviousEndPosition
        sourceSpan <- makeSpan startPosition endPosition
        pure $
          TemplateElementExpression
            TemplateExpressionElement
              { value = expression,
                sourceSpan = sourceSpan
              }
    ]
  where
    parseTemplateStringToken = parseTokenWith $ \case
      TokenTemplateString text -> Just text
      _ -> Nothing

-- ===========================================================================
-- Patterns
-- ===========================================================================

-- | Pattern dispatch. Constructor patterns are syntactically distinguished
-- by being qualified (@enum.ctor(...)@ or @module.enum.ctor(...)@). Bare
-- identifiers are always variable patterns.
parsePattern :: Parser (Pattern Parsed)
parsePattern =
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
parseQualifiedConstructorPattern = do
  startPosition <- parseCurrentPosition
  (mModule, ctorName) <- try $ do
    first <- parseNameRef
    second <- optional (parsePunctuation PunctuationDot *> parseNameRef)
    -- Only commit to a constructor pattern once we see the opening paren.
    void $ MP.lookAhead (parsePunctuation PunctuationLeftParenthesis)
    pure $ case second of
      Nothing -> (Nothing, coerceNameRefSymbol first)
      Just s -> (Just (coerceNameRefSymbol first), coerceNameRefSymbol s)
  parsePunctuation PunctuationLeftParenthesis
  fields <- parsePatternField `sepEndBy` parseComma
  parsePunctuation PunctuationRightParenthesis
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    PatternQualifiedConstructor
      QualifiedConstructorPattern
        { moduleQualifier = mModule,
          constructorName = ctorName,
          parameters = fields,
          sourceSpan = sourceSpan,
          metadata = Parsed
        }

parseWildcardPattern :: Parser (Pattern Parsed)
parseWildcardPattern = do
  startPosition <- parseCurrentPosition
  parseUnderscore
  typeAnnotation <- optional (parsePunctuation PunctuationColon *> parseType)
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    PatternWildcard
      WildcardPattern
        { typeAnnotation = typeAnnotation,
          sourceSpan = sourceSpan,
          metadata = Parsed
        }

parseVariablePattern :: Parser (Pattern Parsed)
parseVariablePattern = do
  startPosition <- parseCurrentPosition
  name <- parseNameRef
  typeAnnotation <- optional (parsePunctuation PunctuationColon *> parseType)
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    PatternVariable
      VariablePattern
        { name = name,
          typeAnnotation = typeAnnotation,
          sourceSpan = sourceSpan,
          metadata = Parsed
        }

parsePatternField :: Parser (NameRef Parsed 'LabelRef, Pattern Parsed)
parsePatternField = labeled <|> sugar
  where
    labeled = try $ do
      fieldLabel <- parseNameRef
      parsePunctuation PunctuationEquals
      parsedPattern <- parsePattern
      pure (fieldLabel, parsedPattern)
    sugar = do
      startPosition <- parseCurrentPosition
      name <- parseNameRef
      typeAnnotation <- optional (parsePunctuation PunctuationColon *> parseType)
      endPosition <- parsePreviousEndPosition
      sourceSpan <- makeSpan startPosition endPosition
      pure
        ( coerceNameRefSymbol name,
          PatternVariable
            VariablePattern
              { name = name,
                typeAnnotation = typeAnnotation,
                sourceSpan = sourceSpan,
                metadata = Parsed
              }
        )

-- | @(p)@ collapses to @p@ (grouped pattern). @(p, q, ...)@ is a tuple.
parseTupleOrGroupedPattern :: Parser (Pattern Parsed)
parseTupleOrGroupedPattern = do
  startPosition <- parseCurrentPosition
  parsePunctuation PunctuationLeftParenthesis
  patterns <- parsePattern `sepEndBy` parseComma
  parsePunctuation PunctuationRightParenthesis
  endPosition <- parsePreviousEndPosition
  case patterns of
    [onlyPattern] -> pure onlyPattern
    _ -> do
      sourceSpan <- makeSpan startPosition endPosition
      pure $
        PatternTuple
          TuplePattern
            { elements = patterns,
              sourceSpan = sourceSpan,
              metadata = Parsed
            }

parseLiteralPattern :: Parser (Pattern Parsed)
parseLiteralPattern = do
  startPosition <- parseCurrentPosition
  literal <- parseLiteralValue
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    PatternLiteral
      LiteralPattern
        { value = literal,
          sourceSpan = sourceSpan,
          metadata = Parsed
        }

-- ===========================================================================
-- Types
-- ===========================================================================

-- | Top-level entry point for a type expression. Unions live at the outermost
-- layer so they have the lowest precedence.
parseType :: Parser (SyntacticType Parsed)
parseType = parseUnionType

-- | Read @T1 | T2 | ...@ as a sequence of atomic types separated by @|@.
-- If there is only one branch, return the atomic type as-is; otherwise wrap
-- the branches in a 'TypeUnion'. Leading pipes (@| T@) are not accepted
-- (because @parseAtomicType@ does not consume @|@ — the input fails
-- naturally). A single trailing pipe (@T |@) is allowed for convenience in
-- multi-line declarations.
parseUnionType :: Parser (SyntacticType Parsed)
parseUnionType = do
  startPosition <- parseCurrentPosition
  first <- parseAtomicType
  rest <- many (try (parsePunctuation PunctuationPipe *> parseAtomicType))
  -- Allow a trailing pipe: a stray @|@ after the last branch is consumed if
  -- present. No type-position follower is @|@, so this never consumes
  -- something it shouldn't.
  _ <- optional (try (parsePunctuation PunctuationPipe))
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  case rest of
    [] -> pure first
    _ -> pure (TypeUnion TypeUnionNode {branches = first : rest, sourceSpan = sourceSpan})

-- | The branches of a union (i.e. everything that was previously @parseType@).
parseAtomicType :: Parser (SyntacticType Parsed)
parseAtomicType =
  choice
    [ parsePrimitiveType PrimitiveTypeKindNull KeywordNull,
      parsePrimitiveType PrimitiveTypeKindInteger KeywordInteger,
      parsePrimitiveType PrimitiveTypeKindNumber KeywordNumber,
      parsePrimitiveType PrimitiveTypeKindString KeywordString,
      parsePrimitiveType PrimitiveTypeKindBoolean KeywordBoolean,
      parseLiteralType,
      try parseArrayType,
      try parseFunctionType,
      parseTupleOrGroupedType,
      parseNamedOrQualifiedType
    ]

-- | Literal type: @"a"@, @42@, @true@, or @false@.
-- @null@ is intentionally omitted: 'parsePrimitiveType' already handles the
-- @null@ keyword as 'PrimitiveTypeKindNull', and the semantics are equivalent.
parseLiteralType :: Parser (SyntacticType Parsed)
parseLiteralType = do
  startPosition <- parseCurrentPosition
  value <-
    choice
      [ LiteralValueString <$> parseStringLiteral,
        LiteralValueInteger <$> parseIntegerLiteral,
        LiteralValueBoolean True <$ parseKeyword KeywordTrue,
        LiteralValueBoolean False <$ parseKeyword KeywordFalse
      ]
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure (TypeLiteral TypeLiteralNode {value = value, sourceSpan = sourceSpan})

parsePrimitiveType :: PrimitiveTypeKind -> Keyword -> Parser (SyntacticType Parsed)
parsePrimitiveType primitiveKind keyword = do
  startPosition <- parseCurrentPosition
  parseKeyword keyword
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    TypePrimitive
      PrimitiveTypeNode
        { kind = primitiveKind,
          sourceSpan = sourceSpan
        }

-- | @Name@ or @module.TypeName@.
parseNamedOrQualifiedType :: Parser (SyntacticType Parsed)
parseNamedOrQualifiedType = do
  startPosition <- parseCurrentPosition
  first <- parseNameRef -- tentative: either a type-ref (bare) or a module-ref (qualified)
  maybeSecond <- optional (parsePunctuation PunctuationDot *> parseNameRef)
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  case maybeSecond of
    Nothing ->
      pure $
        TypeName
          TypeNameNode
            { name = coerceNameRefSymbol first,
              sourceSpan = sourceSpan
            }
    Just second ->
      pure $
        TypeQualified
          QualifiedTypeNode
            { qualifier = first,
              target = coerceNameRefSymbol second,
              sourceSpan = sourceSpan
            }

parseFunctionType :: Parser (SyntacticType Parsed)
parseFunctionType = do
  startPosition <- parseCurrentPosition
  parameterTypes <-
    between
      (parsePunctuation PunctuationLeftParenthesis)
      (parsePunctuation PunctuationRightParenthesis)
      (parseFunctionTypeParameter `sepEndBy` parseComma)
  parsePunctuation PunctuationArrow
  returnType <- parseType
  effects <- option [] (parseKeyword KeywordWith *> parseEffects)
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    TypeFunction
      FunctionTypeNode
        { parameterTypes = parameterTypes,
          returnType = returnType,
          withEffects = effects,
          sourceSpan = sourceSpan
        }

parseFunctionTypeParameter :: Parser (Text, SyntacticType Parsed)
parseFunctionTypeParameter = do
  name <- parseIdentifier
  parsePunctuation PunctuationColon
  typeAnnotation <- parseType
  pure (name, typeAnnotation)

-- | @array[T]@. The token @array@ is a regular identifier, not a keyword,
-- so we match it by string and rely on the surrounding @[...]@ to confirm.
parseArrayType :: Parser (SyntacticType Parsed)
parseArrayType = do
  startPosition <- parseCurrentPosition
  void $ parseTokenWith $ \case
    TokenIdentifier "array" -> Just ()
    _ -> Nothing
  parsePunctuation PunctuationLeftBracket
  elementType <- parseType
  parsePunctuation PunctuationRightBracket
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure $
    TypeArray
      ArrayTypeNode
        { elementType = elementType,
          sourceSpan = sourceSpan
        }

-- | @(T)@ collapses to @T@ (grouped type). @(A, B, ...)@ is a tuple.
-- @()@ is the empty tuple type.
parseTupleOrGroupedType :: Parser (SyntacticType Parsed)
parseTupleOrGroupedType = do
  startPosition <- parseCurrentPosition
  parsePunctuation PunctuationLeftParenthesis
  types <- parseType `sepEndBy` parseComma
  parsePunctuation PunctuationRightParenthesis
  endPosition <- parsePreviousEndPosition
  case types of
    [onlyType] -> pure onlyType
    _ -> do
      sourceSpan <- makeSpan startPosition endPosition
      pure $
        TypeTuple
          TupleTypeNode
            { elementTypes = types,
              sourceSpan = sourceSpan
            }

-- ===========================================================================
-- Effects / parameters
-- ===========================================================================

parseEffects :: Parser [SyntacticRequest Parsed]
parseEffects = parseEffect `sepBy1` parseComma

parseEffect :: Parser (SyntacticRequest Parsed)
parseEffect = do
  startPosition <- parseCurrentPosition
  name <- parseNameRef
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
    SyntacticRequest
      { name = name,
        sourceSpan = sourceSpan
      }

parseParameterList :: Parser [ParameterBinding Parsed]
parseParameterList =
  between
    (parsePunctuation PunctuationLeftParenthesis)
    (parsePunctuation PunctuationRightParenthesis)
    (parseParameterBinding `sepEndBy` parseComma)

parseParameterBinding :: Parser (ParameterBinding Parsed)
parseParameterBinding = do
  startPosition <- parseCurrentPosition
  annotation <- parseAnnotation
  (parameterLabel, parsedPattern) <- labeledParameter <|> sugarParameter
  endPosition <- parsePreviousEndPosition
  sourceSpan <- makeSpan startPosition endPosition
  pure
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
    sugarParameter = do
      sugarStartPosition <- parseCurrentPosition
      name <- parseNameRef
      typeAnnotation <- optional (parsePunctuation PunctuationColon *> parseType)
      sugarEndPosition <- parsePreviousEndPosition
      sugarSpan <- makeSpan sugarStartPosition sugarEndPosition
      pure
        ( name.text,
          PatternVariable
            VariablePattern
              { name = name,
                typeAnnotation = typeAnnotation,
                sourceSpan = sugarSpan,
                metadata = Parsed
              }
        )
