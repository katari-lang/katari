-- | Parser for expressions, statements, blocks, handlers, the control constructs, and the (locally
-- declarable) agent declaration.
--
-- Two things here are more than plain recursive descent:
--
--   * Operator precedence is handled by 'makeExprParser'. Operands are terms (a primary expression
--     plus a postfix chain of calls @(...)@, generic applications @[...]@, and field accesses
--     @.f@). An operator consumes the newline after it, so an expression continues across lines only
--     when a line ends with an operator (the Go-style "virtual semicolon" rule); an operand at the
--     end of a line in line mode ends the statement.
--
--   * @use provider@ captures the /rest of the enclosing block/ as its continuation 'body'. The
--     block builder is therefore recursive: on reaching a @use@, everything after it becomes a
--     nested block.
--
-- @next@ / @break@ read the reader's loop context to choose the for-loop or request-handler node;
-- the context is reset when entering an agent body and set when entering a for / handler body.
module Katari.Parser.Expression where

import Control.Monad (void)
import Control.Monad.Combinators.Expr (Operator (..), makeExprParser)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text, pack)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.SourceSpan (HasSourceSpan (..), Located (..), SourceSpan (..))
import Katari.Parser.Lexer
import Katari.Parser.Pattern (parameterBinding, pattern')
import Katari.Parser.Type (genericParameters, typeExpression)
import Text.Megaparsec
import Text.Megaparsec.Char (char, eol, string)

type ExpressionP = Expression Parsed

---------------------------------------------------------------------------------------------------
-- Expressions: precedence, terms, postfix
---------------------------------------------------------------------------------------------------

expression :: Parser ExpressionP
expression = makeExprParser term operatorTable

operatorTable :: List (List (Operator Parser ExpressionP))
operatorTable =
  [ [prefixOperators],
    [binary BinaryOperatorMultiply "*", binary BinaryOperatorDivide "/", binary BinaryOperatorModulo "%"],
    [binary BinaryOperatorConcat "++", binaryNot BinaryOperatorAdd "+" '+', binary BinaryOperatorSubtract "-"],
    [ binary BinaryOperatorLessOrEqual "<=",
      binary BinaryOperatorGreaterOrEqual ">=",
      binaryNot BinaryOperatorLessThan "<" '=',
      binaryNot BinaryOperatorGreaterThan ">" '='
    ],
    [binary BinaryOperatorEqual "==", binary BinaryOperatorNotEqual "!="],
    [binary BinaryOperatorAnd "&&"],
    [binary BinaryOperatorOr "||"]
  ]

binary :: BinaryOperator -> Text -> Operator Parser ExpressionP
binary operator text = InfixL (makeBinary operator <$ operatorToken text)

binaryNot :: BinaryOperator -> Text -> Char -> Operator Parser ExpressionP
binaryNot operator text disallowed = InfixL (makeBinary operator <$ operatorTokenNot text disallowed)

-- | The unary-prefix precedence level. 'makeExprParser' applies at most one 'Prefix' per level, so a
-- stack of prefixes (@!!x@, @- -x@, @-!x@) is parsed here as a run and composed (outermost first).
prefixOperators :: Operator Parser ExpressionP
prefixOperators = Prefix (foldr (.) id <$> some singlePrefix)
  where
    singlePrefix =
      (makePrefix UnaryOperatorNot <$> operatorTokenSpanNot "!" '=')
        <|> (makePrefix UnaryOperatorNegate <$> operatorTokenSpan "-")

makeBinary :: BinaryOperator -> ExpressionP -> ExpressionP -> ExpressionP
makeBinary operator left right =
  ExpressionBinaryOperator
    BinaryOperatorExpression
      { operator = operator,
        left = left,
        right = right,
        sourceSpan = mergeSpans (sourceSpanOf left) (sourceSpanOf right),
        typeOf = ()
      }

makePrefix :: UnaryOperator -> SourceSpan -> ExpressionP -> ExpressionP
makePrefix operator operatorSpan operand =
  ExpressionUnaryOperator
    UnaryOperatorExpression
      { operator = operator,
        operand = operand,
        sourceSpan = mergeSpans operatorSpan (sourceSpanOf operand),
        typeOf = ()
      }

-- | An operator token consumes the newline after it (so a line ending in an operator continues onto
-- the next), independent of the surrounding line / multiline mode.
operatorToken :: Text -> Parser ()
operatorToken text = void (string text) <* multilineSpace

operatorTokenNot :: Text -> Char -> Parser ()
operatorTokenNot text disallowed = void (try (string text <* notFollowedBy (single disallowed))) <* multilineSpace

operatorTokenSpan :: Text -> Parser SourceSpan
operatorTokenSpan text = (snd <$> spanning (string text)) <* multilineSpace

operatorTokenSpanNot :: Text -> Char -> Parser SourceSpan
operatorTokenSpanNot text disallowed =
  (snd <$> spanning (try (string text <* notFollowedBy (single disallowed)))) <* multilineSpace

-- | A primary expression followed by a left-associative chain of postfix operations.
term :: Parser ExpressionP
term = do
  primary <- primaryExpression
  postfixes <- many postfixOperation
  pure (foldl (\expression' apply -> apply expression') primary postfixes)

-- | A postfix on an expression: a call @(args)@, a generic application @[types]@, or a field
-- access @.field@.
postfixOperation :: Parser (ExpressionP -> ExpressionP)
postfixOperation = choice [callPostfix, genericApplicationPostfix, fieldAccessPostfix]

callPostfix :: Parser (ExpressionP -> ExpressionP)
callPostfix = do
  (arguments, parenSpan) <- parens (commaSeparated callArgument)
  pure
    ( \callee ->
        ExpressionCall
          CallExpression
            { callee = callee,
              arguments = arguments,
              instantiation = (),
              sourceSpan = mergeSpans (sourceSpanOf callee) parenSpan,
              typeOf = ()
            }
    )

callArgument :: Parser (CallArgument Parsed)
callArgument = do
  name <- identifier
  assignEquals
  value <- callArgumentValue
  pure
    CallArgument
      { name = name.value,
        labelReference = parsedReference name.sourceSpan,
        value = value,
        sourceSpan = mergeSpans name.sourceSpan (sourceSpanOf value)
      }

-- | The payload of a call argument: a lone @_@ hole (partial application) or an ordinary
-- expression. The hole is recognized ONLY here — @_@ anywhere else in expression position still
-- parses as a variable named @_@ (and fails identification), so no other position changes meaning.
callArgumentValue :: Parser (CallArgumentValue Parsed)
callArgumentValue = argumentHole <|> (ArgumentExpression <$> expression)

-- | A lone @_@, with the same not-followed-by discipline as the pattern wildcard so an identifier
-- that merely starts with an underscore (@_x@) stays an ordinary expression.
argumentHole :: Parser (CallArgumentValue Parsed)
argumentHole = do
  holeSpan <- snd <$> lexeme (try (char '_' <* notFollowedBy identifierContinue))
  pure (ArgumentHole holeSpan)

genericApplicationPostfix :: Parser (ExpressionP -> ExpressionP)
genericApplicationPostfix = do
  (typeArguments, bracketSpan) <- try (brackets (commaSeparated1 typeExpression))
  pure
    ( \callee ->
        ExpressionTypeApplication
          TypeApplicationExpression
            { callee = callee,
              typeArguments = typeArguments,
              instantiation = (),
              sourceSpan = mergeSpans (sourceSpanOf callee) bracketSpan,
              typeOf = ()
            }
    )

fieldAccessPostfix :: Parser (ExpressionP -> ExpressionP)
fieldAccessPostfix = do
  _ <- symbol "."
  fieldName <- identifier
  pure
    ( \object ->
        ExpressionFieldAccess
          FieldAccessExpression
            { object = object,
              fieldName = fieldName.value,
              labelReference = parsedReference fieldName.sourceSpan,
              sourceSpan = mergeSpans (sourceSpanOf object) fieldName.sourceSpan,
              typeOf = ()
            }
    )

---------------------------------------------------------------------------------------------------
-- Primary expressions
---------------------------------------------------------------------------------------------------

primaryExpression :: Parser ExpressionP
primaryExpression =
  label "expression" $
    choice
      [ literalExpression,
        templateExpression,
        ifExpression,
        matchExpression,
        forExpression,
        foreverExpression,
        parallelExpression,
        handlerExpression,
        tupleExpression,
        parenExpression,
        braceExpression,
        variableExpression
      ]

literalExpression :: Parser ExpressionP
literalExpression = do
  value <- literalValue
  pure (ExpressionLiteral LiteralExpression {value = value.value, sourceSpan = value.sourceSpan, typeOf = ()})

variableExpression :: Parser ExpressionP
variableExpression = do
  name <- identifier
  pure
    ( ExpressionVariable
        VariableExpression
          { name = name.value,
            variableReference = parsedReference name.sourceSpan,
            sourceSpan = name.sourceSpan,
            typeOf = ()
          }
    )

-- | @(e)@ — grouping (tuples use @[...]@, so a parenthesised expression is just its content).
parenExpression :: Parser ExpressionP
parenExpression = fst <$> parens expression

-- | @[e1, e2, ...]@ — a sequential tuple.
tupleExpression :: Parser ExpressionP
tupleExpression = do
  (elements, sourceSpan) <- brackets (commaSeparated expression)
  pure (ExpressionTuple TupleExpression {parallel = False, elements = elements, sourceSpan = sourceSpan, typeOf = ()})

-- | @{ label = e, ... }@ record literal, or a standalone @{ ... }@ block.
braceExpression :: Parser ExpressionP
braceExpression = try recordLiteral <|> blockExpression

recordLiteral :: Parser ExpressionP
recordLiteral = do
  (entries, sourceSpan) <- bracesMultiline (commaSeparated recordEntry)
  pure (ExpressionRecord RecordExpression {entries = entries, sourceSpan = sourceSpan, typeOf = ()})

recordEntry :: Parser (RecordEntry Parsed)
recordEntry = do
  -- A key is a bare identifier (@label = e@) or a quoted string (@"Content-Type" = e@). The string form
  -- carries field names an identifier cannot spell (hyphens, etc.), e.g. for an http header record.
  name <- identifier <|> stringLiteral
  assignEquals
  value <- expression
  pure RecordEntry {name = name.value, value = value, sourceSpan = mergeSpans name.sourceSpan (sourceSpanOf value)}

blockExpression :: Parser ExpressionP
blockExpression = do
  body <- block
  pure (ExpressionBlock BlockExpression {block = body, sourceSpan = sourceSpanOf body, typeOf = ()})

-- | @if (condition) { ... } [else { ... } | else if ...]@.
ifExpression :: Parser ExpressionP
ifExpression = do
  ifSpan <- keyword "if"
  condition <- fst <$> parens expression
  thenBlock <- block
  elseBlock <- optional (keyword "else" *> elseBody)
  let endSpan = maybe (sourceSpanOf thenBlock) sourceSpanOf elseBlock
  pure
    ( ExpressionIf
        IfExpression
          { condition = condition,
            thenBlock = thenBlock,
            elseBlock = elseBlock,
            sourceSpan = mergeSpans ifSpan endSpan,
            typeOf = ()
          }
    )

-- | The @else@ branch: a block, or a chained @if@ (wrapped as a one-expression block).
elseBody :: Parser (Block Parsed)
elseBody = block <|> (wrapExpressionAsBlock <$> ifExpression)

wrapExpressionAsBlock :: ExpressionP -> Block Parsed
wrapExpressionAsBlock value =
  Block {statements = [], returnExpression = Just value, sourceSpan = sourceSpanOf value}

-- | @match (subject) { case pattern -> body ... }@.
matchExpression :: Parser ExpressionP
matchExpression = do
  matchSpan <- keyword "match"
  subject <- fst <$> parens expression
  (cases, casesSpan) <- bracesMultiline (many caseArm)
  pure
    ( ExpressionMatch
        MatchExpression
          { subject = subject,
            cases = cases,
            sourceSpan = mergeSpans matchSpan casesSpan,
            typeOf = ()
          }
    )

caseArm :: Parser (CaseArm Parsed)
caseArm = do
  caseSpan <- keyword "case"
  casePattern <- pattern'
  _ <- symbol "->"
  body <- blockOrExpressionBlock
  pure CaseArm {pattern = casePattern, body = body, sourceSpan = mergeSpans caseSpan (sourceSpanOf body)}

-- | A braced block, or a bare expression wrapped as a one-expression block. The former is tried
-- first but backtracks (a @{ label = e }@ is a record literal, not a block).
blockOrExpressionBlock :: Parser (Block Parsed)
blockOrExpressionBlock = try block <|> (wrapExpressionAsBlock <$> expression)

---------------------------------------------------------------------------------------------------
-- Templates (f-strings)
---------------------------------------------------------------------------------------------------

-- | @f"... ${expression} ..."@ — alternating literal chunks and interpolations.
templateExpression :: Parser ExpressionP
templateExpression = do
  (elements, sourceSpan) <- lexeme rawTemplate
  pure (ExpressionTemplate TemplateExpression {elements = elements, sourceSpan = sourceSpan, typeOf = ()})

rawTemplate :: Parser (List (TemplateElement Parsed))
rawTemplate = string "f\"" *> manyTill templateElement (char '"')

templateElement :: Parser (TemplateElement Parsed)
templateElement = templateInterpolation <|> templateStringChunk

templateInterpolation :: Parser (TemplateElement Parsed)
templateInterpolation = do
  -- Consume any space after @${@ before the expression: a primary only eats its /trailing/ space, so
  -- without this @${ expr }@ (with inner padding) would fail where @${expr}@ succeeds.
  (value, sourceSpan) <- spanning (string "${" *> multilineSpace *> multiline expression <* char '}')
  pure (TemplateElementExpression TemplateExpressionElement {value = value, sourceSpan = sourceSpan})

templateStringChunk :: Parser (TemplateElement Parsed)
templateStringChunk = do
  (characters, sourceSpan) <- spanning (some templateCharacter)
  pure (TemplateElementString TemplateStringElement {value = pack characters, sourceSpan = sourceSpan})

-- | One character of a template's literal chunk: an escape, a literal @$@ that does not begin an
-- interpolation, or any ordinary character.
templateCharacter :: Parser Char
templateCharacter =
  (char '\\' *> escapeSequence)
    <|> try (char '$' <* notFollowedBy (char '{'))
    <|> satisfy (\character -> character /= '"' && character /= '\\' && character /= '$')

---------------------------------------------------------------------------------------------------
-- for / parallel / handler
---------------------------------------------------------------------------------------------------

-- | @for (pattern in source [, var x = e]...) { body } [then (pattern) { ... }]@.
forExpression :: Parser ExpressionP
forExpression = do
  forSpan <- keyword "for"
  forBody False forSpan

-- | @forever { body }@ — repeat the block indefinitely (the expression types as @never@). `forever` is
-- deliberately NOT a reserved word (see 'reservedWords': the stdlib's `replay.forever` agent keeps its
-- name); it is recognised positionally, like the type-only words — only at an expression head with a `{`
-- directly after it. The `try` backtracks a call (`forever(...)`) or a bare reference into the ordinary
-- identifier expression. The body introduces no loop context of its own: `forever` has no jump target
-- (no built-in exit — escaping is composed with a surrounding handler's `break`), so `next` / `break`
-- inside the body keep meaning exactly what they mean outside it, as in a `match` arm.
foreverExpression :: Parser ExpressionP
foreverExpression = do
  foreverSpan <- try (keyword "forever" <* lookAhead (string "{"))
  body <- block
  pure (ExpressionForever ForeverExpression {body = body, sourceSpan = mergeSpans foreverSpan (sourceSpanOf body), typeOf = ()})

-- | @parallel [e, ...]@, @parallel for (...) {...}@, or @parallel handler ...@.
parallelExpression :: Parser ExpressionP
parallelExpression = do
  parallelSpan <- keyword "parallel"
  choice
    [ parallelTuple parallelSpan,
      keyword "for" *> forBody True parallelSpan,
      keyword "handler" *> handlerBody True parallelSpan
    ]

parallelTuple :: SourceSpan -> Parser ExpressionP
parallelTuple parallelSpan = do
  (elements, bracketSpan) <- brackets (commaSeparated expression)
  pure
    ( ExpressionTuple
        TupleExpression
          { parallel = True,
            elements = elements,
            sourceSpan = mergeSpans parallelSpan bracketSpan,
            typeOf = ()
          }
    )

-- | The body of a @for@, after the leading @for@ / @parallel@ keyword (whose span is @leadingSpan@).
forBody :: Bool -> SourceSpan -> Parser ExpressionP
forBody parallel leadingSpan = do
  (inBinding, varBindings) <- fst <$> parens forHeader
  body <- withLoopContext LoopContextFor block
  thenClause <- optional thenClause'
  let endSpan = maybe (sourceSpanOf body) (.sourceSpan) thenClause
  pure
    ( ExpressionFor
        ForExpression
          { parallel = parallel,
            inBinding = inBinding,
            varBindings = varBindings,
            body = body,
            thenClause = thenClause,
            sourceSpan = mergeSpans leadingSpan endSpan,
            typeOf = ()
          }
    )

forHeader :: Parser (ForInBinding Parsed, List (VariableBinding Parsed))
forHeader = do
  inBinding <- forInBinding
  varBindings <- many (symbol "," *> variableBinding)
  pure (inBinding, varBindings)

-- | @[let] pattern in source@ — the @let@ keyword is an optional readability marker.
forInBinding :: Parser (ForInBinding Parsed)
forInBinding = do
  _ <- optional (keyword "let")
  loopPattern <- pattern'
  _ <- keyword "in"
  source <- expression
  pure
    ForInBinding
      { pattern = loopPattern,
        source = source,
        sourceSpan = mergeSpans (sourceSpanOf loopPattern) (sourceSpanOf source)
      }

-- | @var name [: T] = initial@ — a mutable state binding of a @for@ / @handler@.
variableBinding :: Parser (VariableBinding Parsed)
variableBinding = do
  varSpan <- keyword "var"
  name <- identifier
  typeAnnotation <- optional (symbol ":" *> typeExpression)
  assignEquals
  initial <- expression
  pure
    VariableBinding
      { name = name.value,
        variableReference = parsedReference name.sourceSpan,
        typeAnnotation = typeAnnotation,
        initial = initial,
        sourceSpan = mergeSpans varSpan (sourceSpanOf initial)
      }

-- | @then [(pattern)] { body }@ of a @for@ / @handler@.
thenClause' :: Parser (ThenClause Parsed)
thenClause' = do
  thenSpan <- keyword "then"
  binder <- optional (fst <$> parens pattern')
  body <- block
  pure ThenClause {binder = binder, body = body, sourceSpan = mergeSpans thenSpan (sourceSpanOf body)}

-- | @[parallel] handler [generics] [(state vars)] { request handlers } [then ...]@ — a first-class
-- handler provider.
handlerExpression :: Parser ExpressionP
handlerExpression = do
  handlerSpan <- keyword "handler"
  handlerBody False handlerSpan

handlerBody :: Bool -> SourceSpan -> Parser ExpressionP
handlerBody parallel leadingSpan = do
  genericArguments <- option [] (fst <$> brackets (commaSeparated1 typeExpression))
  stateVariables <- option [] (fst <$> parens (commaSeparated variableBinding))
  (handlers, handlersSpan) <- bracesMultiline (many requestHandler)
  thenClause <- optional thenClause'
  let endSpan = maybe handlersSpan (.sourceSpan) thenClause
  pure
    ( ExpressionHandler
        HandlerExpression
          { parallel = parallel,
            genericArguments = genericArguments,
            instantiation = (),
            stateVariables = stateVariables,
            handlers = handlers,
            thenClause = thenClause,
            sourceSpan = mergeSpans leadingSpan endSpan,
            typeOf = ()
          }
    )

-- | @request [module.]name[generics](params) [-> T] { body }@ inside a handler.
requestHandler :: Parser (RequestHandler Parsed)
requestHandler = do
  requestSpan <- keyword "request"
  (moduleQualifier, member) <- qualifiedName
  genericArguments <- option [] (fst <$> brackets (commaSeparated1 typeExpression))
  parameters <- fst <$> parens (commaSeparated parameterBinding)
  returnType <- optional (symbol "->" *> typeExpression)
  body <- withLoopContext LoopContextHandler block
  pure
    RequestHandler
      { moduleQualifier = moduleQualifier,
        name = member.value,
        typeReference = parsedReference member.sourceSpan,
        genericArguments = genericArguments,
        instantiation = (),
        parameters = parameters,
        returnType = returnType,
        body = body,
        sourceSpan = mergeSpans requestSpan (sourceSpanOf body)
      }

---------------------------------------------------------------------------------------------------
-- Agent declaration (top-level and local)
---------------------------------------------------------------------------------------------------

-- | @[\@"doc"] [private] agent name[generics](params) [-> T] [with E] { body }@. Lives here (not in
-- "Katari.Parser") because a local agent is a statement, so the statement parser needs it.
agentDeclaration :: Parser (AgentDeclaration Parsed)
agentDeclaration = optional docAnnotation >>= agentDeclarationWith

-- | The agent declaration after its (already-parsed) doc annotation, so the top-level dispatcher can
-- consume the shared annotation once and commit to this branch on the @agent@ / @private@ keyword.
--
-- The signature is parsed in line mode so the body's @{@ must sit on the same line as the signature's
-- last token (generics / parameters still wrap freely inside their brackets). This rejects an Allman
-- @agent f() -> R \n { ... }@ uniformly — a top-level agent now behaves like a local one and like the
-- @if@ / @for@ / @match@ control constructs, whose brace is already same-line.
agentDeclarationWith :: Maybe (Located Text) -> Parser (AgentDeclaration Parsed)
agentDeclarationWith annotation = do
  -- Only the signature is line-scoped (so the body brace must be same-line — generics / parameters
  -- still wrap inside their brackets). The body 'block' runs in the ambient mode, so its closing @}@
  -- consumes the trailing newline the top-level dispatcher relies on to reach the next declaration.
  (privateSpan, agentSpan, name, generics, parameters, returnType, effects) <-
    lineScoped $ do
      privateSpan <- optional (keyword "private")
      agentSpan <- keyword "agent"
      name <- identifier
      generics <- genericParameters
      parameters <- fst <$> parens (commaSeparated parameterBinding)
      returnType <- optional (symbol "->" *> typeExpression)
      effects <- optional (keyword "with" *> typeExpression)
      pure (privateSpan, agentSpan, name, generics, parameters, returnType, effects)
  body <- withLoopContext LoopContextNone block
  let startSpan = maybe (fromMaybe agentSpan privateSpan) (.sourceSpan) annotation
  pure
    AgentDeclaration
      { annotation = (.value) <$> annotation,
        private = isJust privateSpan,
        name = name.value,
        variableReference = parsedReference name.sourceSpan,
        genericParameters = generics,
        parameters = parameters,
        returnType = returnType,
        effects = effects,
        body = body,
        typeOf = (),
        sourceSpan = mergeSpans startSpan (sourceSpanOf body)
      }

---------------------------------------------------------------------------------------------------
-- Blocks and statements
---------------------------------------------------------------------------------------------------

-- | @{ statement-or-expression separated by newlines / @;@ }@. The final bare expression (if any)
-- is the block's value.
block :: Parser (Block Parsed)
block = do
  openSpan <- rawSpan (string "{")
  multilineSpace
  (statements, returnExpression) <- lineScoped collectBlockItems
  closeSpan <- symbol "}"
  pure Block {statements = statements, returnExpression = returnExpression, sourceSpan = mergeSpans openSpan closeSpan}

-- | The body of a block: leading statements plus an optional trailing value. A @use@ swallows the
-- rest of the block as its continuation.
collectBlockItems :: Parser (List (Statement Parsed), Maybe ExpressionP)
collectBlockItems = optional blockElement >>= maybe (pure ([], Nothing)) finishElement

finishElement :: BlockElement -> Parser (List (Statement Parsed), Maybe ExpressionP)
finishElement = \case
  BlockElementUse makeUse -> do
    body <- continuationBlock
    pure ([StatementUse (makeUse body)], Nothing)
  BlockElementStatement statement -> do
    (statements, returnExpression) <- nextItems
    pure (statement : statements, returnExpression)
  -- A trailing expression with nothing after it is the block's value. A trailing separator yields an
  -- empty tail too, so @{ e; }@ keeps @e@ as the value (the language has no value-discarding @;@).
  BlockElementExpression value -> do
    rest <- nextItems
    pure $ case rest of
      ([], Nothing) -> ([], Just value)
      (statements, returnExpression) -> (StatementExpression value : statements, returnExpression)

-- | After an element: a separator introduces more items, otherwise the block ends here.
nextItems :: Parser (List (Statement Parsed), Maybe ExpressionP)
nextItems = (itemSeparator *> collectBlockItems) <|> pure ([], Nothing)

-- | The continuation of a @use@: the rest of the enclosing block, as a 'Block'.
continuationBlock :: Parser (Block Parsed)
continuationBlock = do
  startPosition <- getSourcePos
  (statements, returnExpression) <- nextItems
  pure
    Block
      { statements = statements,
        returnExpression = returnExpression,
        sourceSpan = continuationSpan startPosition statements returnExpression
      }

continuationSpan :: SourcePos -> List (Statement Parsed) -> Maybe ExpressionP -> SourceSpan
continuationSpan startPosition statements returnExpression =
  let startSpan = pointSpan startPosition
   in case returnExpression of
        Just value -> mergeSpans startSpan (sourceSpanOf value)
        Nothing -> lastSpanOr startSpan statements

-- | One or more newlines / semicolons separating block items, plus any interleaved blank space.
itemSeparator :: Parser ()
itemSeparator = void (some terminator) <?> "statement separator"
  where
    terminator = (void eol <|> void (char ';')) <* lineSpace

data BlockElement where
  BlockElementUse :: (Block Parsed -> UseStatement Parsed) -> BlockElement
  BlockElementStatement :: Statement Parsed -> BlockElement
  BlockElementExpression :: ExpressionP -> BlockElement

blockElement :: Parser BlockElement
blockElement =
  choice
    [ BlockElementUse <$> useProvider,
      BlockElementStatement <$> letStatement,
      BlockElementStatement . StatementAgent <$> agentDeclaration,
      BlockElementStatement <$> returnStatement,
      BlockElementStatement <$> nextStatement,
      BlockElementStatement <$> breakStatement,
      BlockElementStatement <$> finallyStatement,
      BlockElementExpression <$> expression
    ]

-- | @use provider@ or @let pattern = use provider@; returns the builder once the body is known.
useProvider :: Parser (Block Parsed -> UseStatement Parsed)
useProvider = bareUse <|> letBoundUse

bareUse :: Parser (Block Parsed -> UseStatement Parsed)
bareUse = do
  useSpan <- keyword "use"
  provider <- expression
  pure (\body -> UseStatement {binder = Nothing, provider = provider, body = body, sourceSpan = mergeSpans useSpan (sourceSpanOf body)})

letBoundUse :: Parser (Block Parsed -> UseStatement Parsed)
letBoundUse = try $ do
  letSpan <- keyword "let"
  binder <- pattern'
  assignEquals
  _ <- keyword "use"
  provider <- expression
  pure (\body -> UseStatement {binder = Just binder, provider = provider, body = body, sourceSpan = mergeSpans letSpan (sourceSpanOf body)})

letStatement :: Parser (Statement Parsed)
letStatement = do
  letSpan <- keyword "let"
  letPattern <- pattern'
  assignEquals
  value <- expression
  pure (StatementLet LetStatement {pattern = letPattern, value = value, sourceSpan = mergeSpans letSpan (sourceSpanOf value)})

returnStatement :: Parser (Statement Parsed)
returnStatement = do
  returnSpan <- keyword "return"
  value <- optional expression
  let valueExpression = fromMaybe (nullExpression returnSpan) value
  pure (StatementReturn ReturnStatement {value = valueExpression, sourceSpan = mergeSpans returnSpan (sourceSpanOf valueExpression)})

-- | @next [value] [with { ... }]@ — a for-loop or request-handler @next@, by loop context.
nextStatement :: Parser (Statement Parsed)
nextStatement = do
  nextSpan <- keyword "next"
  value <- optional expression
  modifiers <- option [] modifierClause
  context <- currentLoopContext
  let valueExpression = fromMaybe (nullExpression nextSpan) value
      sourceSpan = mergeSpans nextSpan (nextEndSpan nextSpan value modifiers)
  case context of
    LoopContextFor -> pure (StatementForNext ForNextStatement {value = valueExpression, modifiers = modifiers, sourceSpan = sourceSpan})
    LoopContextHandler -> pure (StatementNext NextStatement {value = valueExpression, modifiers = modifiers, sourceSpan = sourceSpan})
    LoopContextNone -> fail "`next` is only allowed inside a `for` loop or a request handler"

nextEndSpan :: SourceSpan -> Maybe ExpressionP -> List (Modifier Parsed) -> SourceSpan
nextEndSpan fallback value =
  lastSpanOr (maybe fallback sourceSpanOf value)

-- | @break [value]@ — a for-loop or request-handler @break@, by loop context.
breakStatement :: Parser (Statement Parsed)
breakStatement = do
  breakSpan <- keyword "break"
  value <- optional expression
  context <- currentLoopContext
  let valueExpression = fromMaybe (nullExpression breakSpan) value
      sourceSpan = mergeSpans breakSpan (sourceSpanOf valueExpression)
  case context of
    LoopContextFor -> pure (StatementForBreak ForBreakStatement {value = valueExpression, sourceSpan = sourceSpan})
    LoopContextHandler -> pure (StatementBreak BreakStatement {value = valueExpression, sourceSpan = sourceSpan})
    LoopContextNone -> fail "`break` is only allowed inside a `for` loop or a request handler"

-- | @finally { ... }@ — arm the braced block as a finalizer of the current agent instance.
finallyStatement :: Parser (Statement Parsed)
finallyStatement = do
  finallySpan <- keyword "finally"
  body <- block
  pure (StatementFinally FinallyStatement {body = body, sourceSpan = mergeSpans finallySpan (sourceSpanOf body)})

-- | @with { name = expression, ... }@ — the modifier list of a @next@.
modifierClause :: Parser (List (Modifier Parsed))
modifierClause = keyword "with" *> (fst <$> bracesMultiline (commaSeparated modifier))

modifier :: Parser (Modifier Parsed)
modifier = do
  name <- identifier
  assignEquals
  value <- expression
  pure
    Modifier
      { name = name.value,
        variableReference = parsedReference name.sourceSpan,
        value = value,
        sourceSpan = mergeSpans name.sourceSpan (sourceSpanOf value)
      }

nullExpression :: SourceSpan -> ExpressionP
nullExpression sourceSpan = ExpressionLiteral LiteralExpression {value = LiteralValueNull, sourceSpan = sourceSpan, typeOf = ()}
