-- | The lexical foundation of the parser: the parser monad, its reader context, the two
-- space consumers (line-local vs. newline-eating), and the token / span / bracket helpers
-- everything else is built from.
--
-- Katari is brace-delimited and mostly free-form, but a newline acts as a statement separator
-- (the "virtual semicolon" the old compiler inserted at lex time). We realise that in a
-- scannerless parser with two space consumers selected by the reader context: at the statement
-- level the line-local 'lineSpace' stops at a newline, while everything bracketed switches to the
-- newline-eating 'multilineSpace'. Continuation points opt back into newline-eating so a construct
-- may still span lines: an operator forces it explicitly, and everything between brackets (where the
-- comma-separated lists live) is already in multiline mode.
module Katari.Parser.Lexer where

import Control.Monad (void, when)
import Control.Monad.Reader (ReaderT, asks, local)
import Control.Monad.Writer.CPS (Writer)
import Data.Char (isAlphaNum, isLetter)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void (Void)
import GHC.List (List)
import Katari.Data.AST (LiteralValue (..), ModuleQualifier (..), Reference (..))
import Katari.Data.AST qualified as AST
import Katari.Data.SourceSpan (HasSourceSpan (..), Located (..), Position (..), SourceSpan (..))
import Katari.Diagnostics (Diagnostics, reportAt)
import Katari.Error (CompilerError (..), ParseError (..), UnsafeIntegerLiteralInfo (..))
import Text.Megaparsec
import Text.Megaparsec.Char (char, space1, string)
import Text.Megaparsec.Char.Lexer qualified as Lexer

---------------------------------------------------------------------------------------------------
-- Parser monad + reader context
---------------------------------------------------------------------------------------------------

-- | Whether a newline currently separates tokens (line) or is plain whitespace (multiline).
data SpaceMode = SpaceModeLine | SpaceModeMultiline
  deriving stock (Eq, Show)

-- | The nearest enclosing control construct, so @next@ / @break@ resolve to the for-loop or the
-- request-handler form without re-deciding it downstream. Reset to 'LoopContextNone' when crossing
-- an agent boundary (a nested closure does not see the outer loop / handler).
data LoopContext = LoopContextNone | LoopContextFor | LoopContextHandler
  deriving stock (Eq, Show)

data ParseContext = ParseContext
  { loopContext :: LoopContext,
    spaceMode :: SpaceMode
  }
  deriving stock (Eq, Show)

initialContext :: ParseContext
initialContext = ParseContext {loopContext = LoopContextNone, spaceMode = SpaceModeMultiline}

-- | The parser: megaparsec over 'Text', with the immutable 'ParseContext' threaded by a reader so
-- the space mode and loop context flow down the tree (and back up via 'local'), over a 'Writer' that
-- accumulates 'Diagnostics' (the same 'MonadWriter' the rest of the compiler reports into, so the
-- shared 'Katari.Diagnostics.reportAt' works here too). Diagnostics are appended only in
-- 'withRecovery' handlers and in token warnings that are backtracking-safe by construction (a
-- consumed token is the same token in any successful parse, and duplicates are deduped on
-- finalization), so the no-rollback-on-backtrack caveat of a 'Writer' under 'ParsecT' does not bite.
type Parser = ParsecT Void Text (ReaderT ParseContext (Writer Diagnostics))

-- | Run @parser@ with the space mode forced to multiline for its extent (used inside brackets).
multiline :: Parser a -> Parser a
multiline = local (\context -> context {spaceMode = SpaceModeMultiline})

-- | Run @parser@ with the space mode forced to line-local (used for a block's statement list).
lineScoped :: Parser a -> Parser a
lineScoped = local (\context -> context {spaceMode = SpaceModeLine})

-- | Run @parser@ with the loop context set (used when entering a for / handler body).
withLoopContext :: LoopContext -> Parser a -> Parser a
withLoopContext context = local (\parseContext -> parseContext {loopContext = context})

currentLoopContext :: Parser LoopContext
currentLoopContext = asks (.loopContext)

---------------------------------------------------------------------------------------------------
-- Space consumers
---------------------------------------------------------------------------------------------------

-- | A line-local run of insignificant characters: spaces, tabs, and comments, but never a newline
-- (a newline is a statement separator in line mode; @\\r\\n@ is handled by 'eol' at separators).
lineSpace :: Parser ()
lineSpace = Lexer.space (void (takeWhile1P (Just "white space") isLineWhitespace)) lineComment blockComment
  where
    isLineWhitespace character = character == ' ' || character == '\t'

-- | As 'lineSpace', but newlines are also insignificant.
multilineSpace :: Parser ()
multilineSpace = Lexer.space space1 lineComment blockComment

lineComment :: Parser ()
lineComment = Lexer.skipLineComment "//"

blockComment :: Parser ()
blockComment = Lexer.skipBlockComment "/*" "*/"

-- | Consume insignificant characters according to the current space mode.
spaceConsumer :: Parser ()
spaceConsumer =
  asks (.spaceMode) >>= \case
    SpaceModeLine -> lineSpace
    SpaceModeMultiline -> multilineSpace

---------------------------------------------------------------------------------------------------
-- Source spans
---------------------------------------------------------------------------------------------------

positionOf :: SourcePos -> Position
positionOf sourcePosition = Position {line = unPos sourcePosition.sourceLine, column = unPos sourcePosition.sourceColumn}

spanBetween :: SourcePos -> SourcePos -> SourceSpan
spanBetween startPosition endPosition =
  SourceSpan
    { filePath = sourceName startPosition,
      start = positionOf startPosition,
      end = positionOf endPosition
    }

-- | A zero-width span at a single position (for an empty range or a single-spot error).
pointSpan :: SourcePos -> SourceSpan
pointSpan sourcePosition = spanBetween sourcePosition sourcePosition

-- | The span starting at @first@ and ending at @second@; child spans of a composite node are
-- merged with this (the leaves carry accurate spans, so the result excludes trailing whitespace).
mergeSpans :: SourceSpan -> SourceSpan -> SourceSpan
mergeSpans first second = first {end = second.end}

-- | The span of the last element of @elements@, or @fallback@ when empty. Lets a composite node
-- compute its end without the partial 'last' (CLAUDE.md forbids partial functions).
lastSpanOr :: (HasSourceSpan element) => SourceSpan -> List element -> SourceSpan
lastSpanOr = foldl (\_ element -> sourceSpanOf element)

-- | Run @raw@, returning it paired with the span of exactly the characters it consumed (before any
-- trailing whitespace). The token-level building block for accurate spans.
spanning :: Parser a -> Parser (a, SourceSpan)
spanning raw = do
  startPosition <- getSourcePos
  result <- raw
  endPosition <- getSourcePos
  pure (result, spanBetween startPosition endPosition)

-- | The span of @raw@'s consumed characters, discarding its result.
rawSpan :: Parser a -> Parser SourceSpan
rawSpan raw = snd <$> spanning raw

---------------------------------------------------------------------------------------------------
-- Tokens
---------------------------------------------------------------------------------------------------

-- | Run @raw@ as a token: capture its accurate span, then consume trailing whitespace.
lexeme :: Parser a -> Parser (a, SourceSpan)
lexeme raw = spanning raw <* spaceConsumer

-- | A fixed punctuation / operator token, returning its span.
symbol :: Text -> Parser SourceSpan
symbol text = snd <$> lexeme (void (string text))

-- | @=@ (not @==@ or @=>@), consuming the following newline so the right-hand side may begin on the
-- next line. The binding / assignment separator of @let@, @var@, call arguments, record entries, and
-- type synonyms.
assignEquals :: Parser ()
assignEquals = void (try (string "=" <* notFollowedBy (oneOf ['=', '>']))) <* multilineSpace

-- | A reserved word, matched only as a whole word (not as a prefix of an identifier).
keyword :: Text -> Parser SourceSpan
keyword text = snd <$> lexeme (try (string text <* notFollowedBy identifierContinue))

isIdentifierStart :: Char -> Bool
isIdentifierStart character = isLetter character || character == '_'

isIdentifierContinue :: Char -> Bool
isIdentifierContinue character = isAlphaNum character || character == '_'

identifierContinue :: Parser Char
identifierContinue = satisfy isIdentifierContinue

-- | A bare identifier: a word that is not a reserved keyword.
identifier :: Parser (Located Text)
identifier = toLocated <$> lexeme rawIdentifier
  where
    rawIdentifier = try $ do
      firstCharacter <- satisfy isIdentifierStart <?> "identifier"
      rest <- takeWhileP Nothing isIdentifierContinue
      let name = Text.cons firstCharacter rest
      when (Set.member name reservedWords) (fail ("keyword \"" <> Text.unpack name <> "\" cannot be used as an identifier"))
      pure name

toLocated :: (value, SourceSpan) -> Located value
toLocated (value, sourceSpan) = Located {value = value, sourceSpan = sourceSpan}

---------------------------------------------------------------------------------------------------
-- Literals
---------------------------------------------------------------------------------------------------

-- | An unsigned numeric literal: integer unless a fractional or exponent part is present.
numericLiteral :: Parser (Located LiteralValue)
numericLiteral = toLocated <$> lexeme (try float <|> integerLiteral Lexer.decimal)
  where
    float = LiteralValueNumber <$> Lexer.float

-- | A signed numeric literal — only where no surrounding operator could supply the sign (a
-- parameter default), so unary minus is unavailable there.
signedNumericLiteral :: Parser (Located LiteralValue)
signedNumericLiteral = toLocated <$> lexeme (try signedFloat <|> integerLiteral (Lexer.signed (pure ()) Lexer.decimal))
  where
    signedFloat = LiteralValueNumber <$> Lexer.signed (pure ()) Lexer.float

-- | Read an integer literal from @digits@, warning (but not failing) if its magnitude exceeds what a
-- runtime number represents exactly; the value is then narrowed to the machine-width 'Int' the AST
-- carries. Reporting the warning here is backtracking-safe for the reasons given on the 'Parser' type.
integerLiteral :: Parser Integer -> Parser LiteralValue
integerLiteral digits = do
  (value, sourceSpan) <- spanning digits
  when (abs value > maximumSafeInteger) $
    reportAt sourceSpan (CompilerErrorParse (ParseErrorUnsafeIntegerLiteral (UnsafeIntegerLiteralInfo {value = value})))
  pure (LiteralValueInteger (fromInteger value))
  where
    -- Number.MAX_SAFE_INTEGER: the largest integer a JS double represents exactly.
    maximumSafeInteger = 2 ^ (53 :: Int) - 1

-- | A double-quoted string with the usual escapes. Interpolation (@${...}@) belongs to f-strings
-- ('Katari.Parser.Expression'), so a plain string treats @$@ literally.
stringLiteral :: Parser (Located Text)
stringLiteral = toLocated <$> lexeme rawStringLiteral

rawStringLiteral :: Parser Text
rawStringLiteral = char '"' *> (Text.pack <$> manyTill stringCharacter (char '"'))

-- | One character of a string body: an escape sequence, or any character other than the closing
-- quote / backslash.
stringCharacter :: Parser Char
stringCharacter = (char '\\' *> escapeSequence) <|> satisfy (\character -> character /= '"' && character /= '\\')

escapeSequence :: Parser Char
escapeSequence =
  choice
    [ '\n' <$ char 'n',
      '\t' <$ char 't',
      '\r' <$ char 'r',
      '"' <$ char '"',
      '\\' <$ char '\\',
      '$' <$ char '$',
      '/' <$ char '/'
    ]

-- | Any literal value usable in an expression: numeric (unsigned), string, boolean, or null.
literalValue :: Parser (Located LiteralValue)
literalValue =
  choice
    [ numericLiteral,
      fmap LiteralValueString <$> stringLiteral,
      booleanLiteral,
      nullLiteral
    ]

-- | A literal that carries its own leading sign (parameter defaults and literal patterns), where no
-- unary-minus operator is in scope to supply it.
signedLiteralValue :: Parser (Located LiteralValue)
signedLiteralValue =
  choice
    [ signedNumericLiteral,
      fmap LiteralValueString <$> stringLiteral,
      booleanLiteral,
      nullLiteral
    ]

booleanLiteral :: Parser (Located LiteralValue)
booleanLiteral =
  toLocated
    <$> lexeme
      ( (LiteralValueBoolean True <$ wholeWord "true")
          <|> (LiteralValueBoolean False <$ wholeWord "false")
      )

nullLiteral :: Parser (Located LiteralValue)
nullLiteral = toLocated <$> lexeme (LiteralValueNull <$ wholeWord "null")

-- | Match @word@ as a whole word (for keyword-shaped literals), without consuming trailing space.
wholeWord :: Text -> Parser ()
wholeWord word = void (try (string word <* notFollowedBy identifierContinue))

-- | A documentation annotation @\@"..."@ attached to the following declaration / parameter.
docAnnotation :: Parser (Located Text)
docAnnotation = toLocated <$> lexeme (char '@' *> rawStringLiteral)

---------------------------------------------------------------------------------------------------
-- Brackets
---------------------------------------------------------------------------------------------------

-- | @open body close@ where newlines inside are insignificant: a leading newline after @open@ and a
-- trailing one before @close@ are eaten, and @body@ runs in multiline mode. The close token's own
-- trailing whitespace is consumed in the /outer/ mode, so a bracket at the end of a statement does
-- not swallow the statement separator that follows it. Returns @(body, openToCloseSpan)@.
enclosedMultiline :: Text -> Text -> Parser a -> Parser (a, SourceSpan)
enclosedMultiline openToken closeToken body = do
  openSpan <- rawSpan (string openToken)
  multilineSpace
  result <- multiline body
  closeSpan <- symbol closeToken
  pure (result, mergeSpans openSpan closeSpan)

parens :: Parser a -> Parser (a, SourceSpan)
parens = enclosedMultiline "(" ")"

brackets :: Parser a -> Parser (a, SourceSpan)
brackets = enclosedMultiline "[" "]"

bracesMultiline :: Parser a -> Parser (a, SourceSpan)
bracesMultiline = enclosedMultiline "{" "}"

-- | Zero or more @element@s separated by commas, with an optional trailing comma. Intended for use
-- inside a bracket (multiline) context.
commaSeparated :: Parser a -> Parser (List a)
commaSeparated element = sepEndBy element (symbol ",")

-- | One or more @element@s separated by commas, with an optional trailing comma.
commaSeparated1 :: Parser a -> Parser (List a)
commaSeparated1 element = sepEndBy1 element (symbol ",")

---------------------------------------------------------------------------------------------------
-- References
---------------------------------------------------------------------------------------------------

-- | A 'Parsed'-phase reference: name resolution has not run, so every resolution is @()@ (the
-- 'ReferenceResolution' type family reduces to @()@ for 'AST.Parsed' at every reference kind).
parsedReference :: SourceSpan -> Reference AST.Parsed nameReferenceKind
parsedReference sourceSpan = Reference {sourceSpan = sourceSpan, resolution = ()}

-- | @[module.]name@ — an optionally module-qualified reference (one qualifier segment). Returns the
-- optional @module.@ qualifier and the member name with its own span; the whole-reference span runs
-- from the qualifier (when present) through the member. Shared by the value-reference and type-name
-- parsers so the @module.@ shape lives in one place.
qualifiedName :: Parser (Maybe (ModuleQualifier AST.Parsed), Located Text)
qualifiedName = do
  first <- identifier
  member <- optional (symbol "." *> identifier)
  pure $ case member of
    Nothing -> (Nothing, first)
    Just second ->
      ( Just ModuleQualifier {name = first.value, moduleReference = parsedReference first.sourceSpan, sourceSpan = first.sourceSpan},
        second
      )

---------------------------------------------------------------------------------------------------
-- Reserved words
---------------------------------------------------------------------------------------------------

-- | Words that may never be a bare identifier because they introduce a statement, expression, or
-- declaration. Type-only words (@integer@, @array@, @record@, @never@, @unknown@, @all@, @pure@,
-- ...) are deliberately absent: they are recognised positionally by the type parser and remain
-- usable as expression identifiers / module names (e.g. @array.get@). @forever@ is likewise absent —
-- it is recognised positionally by the expression parser (only at an expression head directly before
-- a @{@), so the stdlib's @retry.forever@ agent keeps its name.
reservedWords :: Set Text
reservedWords =
  Set.fromList
    [ "agent",
      "request",
      "external",
      "primitive",
      "data",
      "type",
      "import",
      "from",
      "as",
      "use",
      "handler",
      "for",
      "parallel",
      "if",
      "else",
      "match",
      "case",
      "return",
      "next",
      "break",
      "var",
      "let",
      "finally",
      "then",
      "in",
      "with",
      "of",
      "true",
      "false",
      "null"
    ]
