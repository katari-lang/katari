-- | The Parse phase: source text to a 'Parsed' AST. This module is the entry point ('parseModule')
-- and the top-level declaration grammar; expressions / statements / types / patterns live in the
-- @Katari.Parser.*@ submodules. The lexer is internal (no separate phase): a scannerless megaparsec
-- parser with line- vs. multiline-aware space consumers, threaded through a reader (see
-- "Katari.Parser.Lexer").
--
-- Parsing recovers at the declaration boundary: a malformed declaration is reported, replaced by a
-- 'DeclarationError' sentinel, and parsing resumes at the next column-1 declaration keyword, so one
-- bad declaration does not lose the rest of the file.
module Katari.Parser where

import Control.Monad (guard, void)
import Control.Monad.Reader (runReaderT)
import Control.Monad.Writer.CPS (runWriter)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void (Void)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.ModuleName (ModuleName (..), moduleNameFromSegments, renderModuleName)
import Katari.Data.SourceSpan (HasSourceSpan (..), Located (..), SourceSpan (..))
import Katari.Diagnostics (Diagnostics, diagnosticAt, report)
import Katari.Error (CompilerError (..), ParseError (ParseErrorSyntax), SyntaxErrorInfo (..))
import Katari.Parser.Expression (agentDeclarationWith)
import Katari.Parser.Lexer
import Katari.Parser.Type (genericParameters, parameterSignature, typeExpression)
import Text.Megaparsec hiding (ParseError)
import Text.Megaparsec qualified as Megaparsec
import Text.Megaparsec.Char (char)

---------------------------------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------------------------------

-- | Parse one module's source into a 'Parsed' AST, with the parse diagnostics (K1xxx range). With
-- recovery the result is normally a (possibly partial) module whose diagnostics carry every error;
-- the 'Left' branch is a safety net for a failure no recovery handler caught.
parseModule :: ModuleName -> Text -> (Module Parsed, Diagnostics)
parseModule moduleName source =
  case runWriter (runReaderT (runParserT moduleParser fileName source) initialContext) of
    (Right module', diagnostics) -> (module', diagnostics)
    (Left bundle, diagnostics) -> (errorModule bundle, diagnostics <> bundleToDiagnostics bundle)
  where
    fileName = Text.unpack (renderModuleName moduleName)

moduleParser :: Parser (Module Parsed)
moduleParser = do
  startPosition <- getSourcePos
  multilineSpace
  declarations <- many recoverableDeclaration
  eof
  endPosition <- getSourcePos
  pure Module {declarations = declarations, sourceSpan = spanBetween startPosition endPosition}

---------------------------------------------------------------------------------------------------
-- Error recovery
---------------------------------------------------------------------------------------------------

-- | A declaration, or — on a syntax error — a 'DeclarationError' sentinel after reporting the error
-- and skipping to the next declaration. Stops (so @many@ terminates) at end of input.
recoverableDeclaration :: Parser (Declaration Parsed)
recoverableDeclaration = do
  notFollowedBy eof
  startPosition <- getSourcePos
  withRecovery (recoverDeclaration startPosition) declaration

recoverDeclaration :: SourcePos -> Megaparsec.ParseError Text Void -> Parser (Declaration Parsed)
recoverDeclaration startPosition syntaxError = do
  errorPosition <- getSourcePos
  report (syntaxDiagnostic errorPosition syntaxError)
  skipToDeclarationSync
  DeclarationError . spanBetween startPosition <$> getSourcePos

-- | A K1001 diagnostic from one megaparsec parse error, located at @position@.
syntaxDiagnostic :: SourcePos -> Megaparsec.ParseError Text Void -> Located CompilerError
syntaxDiagnostic position syntaxError =
  Located
    { value = CompilerErrorParse (ParseErrorSyntax SyntaxErrorInfo {message = Text.strip (Text.pack (parseErrorTextPretty syntaxError))}),
      sourceSpan = pointSpan position
    }

-- | Consume the rest of a broken declaration, up to (not including) the next column-1 declaration
-- keyword or end of input. The leading 'anySingle' guarantees progress.
skipToDeclarationSync :: Parser ()
skipToDeclarationSync = do
  _ <- anySingle
  skipManyTill anySingle (lookAhead (eof <|> declarationStart))

-- | A synchronisation point: a declaration keyword (or doc annotation) at the start of a line.
declarationStart :: Parser ()
declarationStart = do
  position <- getSourcePos
  guard (unPos (sourceColumn position) == 1)
  void (char '@') <|> void (choice (map keyword declarationKeywords))

declarationKeywords :: List Text
declarationKeywords = ["agent", "private", "request", "external", "primitive", "data", "type", "import"]

-- | A module standing in for a non-recovered parse failure: one 'DeclarationError' at the error.
errorModule :: ParseErrorBundle Text Void -> Module Parsed
errorModule bundle =
  let sourceSpan = firstErrorSpan bundle
   in Module {declarations = [DeclarationError sourceSpan], sourceSpan = sourceSpan}

-- | Turn megaparsec's error bundle into the compiler's K1001 syntax diagnostics, one per error.
bundleToDiagnostics :: ParseErrorBundle Text Void -> Diagnostics
bundleToDiagnostics bundle =
  let (errorsWithPosition, _) = attachSourcePos errorOffset (bundleErrors bundle) (bundlePosState bundle)
   in foldMap toDiagnostic errorsWithPosition
  where
    toDiagnostic (singleError, sourcePosition) =
      diagnosticAt
        (pointSpan sourcePosition)
        (CompilerErrorParse (ParseErrorSyntax SyntaxErrorInfo {message = Text.strip (Text.pack (parseErrorTextPretty singleError))}))

firstErrorSpan :: ParseErrorBundle Text Void -> SourceSpan
firstErrorSpan bundle =
  let (errorsWithPosition, _) = attachSourcePos errorOffset (bundleErrors bundle) (bundlePosState bundle)
   in pointSpan (snd (NonEmpty.head errorsWithPosition))

---------------------------------------------------------------------------------------------------
-- Declarations
---------------------------------------------------------------------------------------------------

-- | @import@ and @type@ (no doc annotation) bail without consuming on a mismatching keyword, so they
-- can be tried first; the documented declarations share one doc annotation and then commit to a
-- branch on their keyword (no 'try', so an error inside a declaration keeps its real location).
declaration :: Parser (Declaration Parsed)
declaration =
  label "declaration" $
    choice
      [ DeclarationImport <$> importDeclaration,
        DeclarationTypeSynonym <$> typeSynonymDeclaration,
        documentedDeclaration
      ]

documentedDeclaration :: Parser (Declaration Parsed)
documentedDeclaration = do
  annotation <- optional docAnnotation
  choice
    [ DeclarationAgent <$> agentDeclarationWith annotation,
      DeclarationRequest <$> requestDeclarationWith annotation,
      DeclarationExternalAgent <$> externalAgentDeclarationWith annotation,
      DeclarationPrimitiveAgent <$> primitiveAgentDeclarationWith annotation,
      DeclarationData <$> dataDeclarationWith annotation
    ]

-- | @request name[generics](label : T ?= default, ...) -> T@.
requestDeclarationWith :: Maybe (Located Text) -> Parser (RequestDeclaration Parsed)
requestDeclarationWith annotation = do
  requestSpan <- keyword "request"
  name <- identifier
  generics <- genericParameters
  parameters <- fst <$> parens (commaSeparated parameterSignature)
  _ <- symbol "->"
  returnType <- typeExpression
  pure
    RequestDeclaration
      { annotation = (.value) <$> annotation,
        name = name.value,
        variableReference = parsedReference name.sourceSpan,
        typeReference = parsedReference name.sourceSpan,
        genericParameters = generics,
        parameters = parameters,
        returnType = returnType,
        sourceSpan = mergeSpans (declarationStartSpan annotation requestSpan) (sourceSpanOf returnType)
      }

-- | @external agent name[generics](signatures) -> T [with E]@.
externalAgentDeclarationWith :: Maybe (Located Text) -> Parser (ExternalAgentDeclaration Parsed)
externalAgentDeclarationWith annotation = do
  externalSpan <- keyword "external"
  _ <- keyword "agent"
  name <- identifier
  generics <- genericParameters
  parameters <- fst <$> parens (commaSeparated parameterSignature)
  _ <- symbol "->"
  returnType <- typeExpression
  effects <- optional (keyword "with" *> typeExpression)
  let endSpan = maybe (sourceSpanOf returnType) sourceSpanOf effects
  pure
    ExternalAgentDeclaration
      { annotation = (.value) <$> annotation,
        name = name.value,
        variableReference = parsedReference name.sourceSpan,
        genericParameters = generics,
        parameters = parameters,
        returnType = returnType,
        effects = effects,
        sourceSpan = mergeSpans (declarationStartSpan annotation externalSpan) endSpan
      }

-- | @primitive agent name[generics](signatures) -> T [with E]@.
primitiveAgentDeclarationWith :: Maybe (Located Text) -> Parser (PrimitiveAgentDeclaration Parsed)
primitiveAgentDeclarationWith annotation = do
  primitiveSpan <- keyword "primitive"
  _ <- keyword "agent"
  name <- identifier
  generics <- genericParameters
  parameters <- fst <$> parens (commaSeparated parameterSignature)
  _ <- symbol "->"
  returnType <- typeExpression
  effects <- optional (keyword "with" *> typeExpression)
  let endSpan = maybe (sourceSpanOf returnType) sourceSpanOf effects
  pure
    PrimitiveAgentDeclaration
      { annotation = (.value) <$> annotation,
        name = name.value,
        variableReference = parsedReference name.sourceSpan,
        genericParameters = generics,
        parameters = parameters,
        returnType = returnType,
        effects = effects,
        sourceSpan = mergeSpans (declarationStartSpan annotation primitiveSpan) endSpan
      }

-- | @data name[generics](label : T ?= default, ...)@.
dataDeclarationWith :: Maybe (Located Text) -> Parser (DataDeclaration Parsed)
dataDeclarationWith annotation = do
  dataSpan <- keyword "data"
  name <- identifier
  generics <- genericParameters
  (parameters, parametersSpan) <- parens (commaSeparated parameterSignature)
  pure
    DataDeclaration
      { annotation = (.value) <$> annotation,
        name = name.value,
        variableReference = parsedReference name.sourceSpan,
        typeReference = parsedReference name.sourceSpan,
        genericParameters = generics,
        parameters = parameters,
        sourceSpan = mergeSpans (declarationStartSpan annotation dataSpan) parametersSpan
      }

-- | @type name[generics] = T@ (no doc annotation).
typeSynonymDeclaration :: Parser (TypeSynonymDeclaration Parsed)
typeSynonymDeclaration = do
  typeSpan <- keyword "type"
  name <- identifier
  generics <- genericParameters
  assignEquals
  definition <- typeExpression
  pure
    TypeSynonymDeclaration
      { name = name.value,
        typeReference = parsedReference name.sourceSpan,
        genericParameters = generics,
        definition = definition,
        sourceSpan = mergeSpans typeSpan (sourceSpanOf definition)
      }

-- | The declaration's start span: the doc annotation if present, otherwise the keyword.
declarationStartSpan :: Maybe (Located Text) -> SourceSpan -> SourceSpan
declarationStartSpan annotation keywordSpan = maybe keywordSpan (.sourceSpan) annotation

---------------------------------------------------------------------------------------------------
-- Imports
---------------------------------------------------------------------------------------------------

-- | @import { a, type B } from module.path@ / @import module.path [as alias]@.
importDeclaration :: Parser ImportDeclaration
importDeclaration = do
  importSpan <- keyword "import"
  (kind, endSpan) <- namesImport <|> moduleImport
  pure ImportDeclaration {kind = kind, sourceSpan = mergeSpans importSpan endSpan}

namesImport :: Parser (ImportKind, SourceSpan)
namesImport = do
  (items, _) <- bracesMultiline (commaSeparated importItem)
  _ <- keyword "from"
  (moduleName, moduleSpan) <- moduleNameReference
  pure (ImportNames NamesImport {items = items, moduleName = moduleName}, moduleSpan)

moduleImport :: Parser (ImportKind, SourceSpan)
moduleImport = do
  (moduleName, moduleSpan) <- moduleNameReference
  alias <- optional (keyword "as" *> identifier)
  let endSpan = maybe moduleSpan (.sourceSpan) alias
  pure (ImportModule ModuleImport {moduleName = moduleName, alias = (.value) <$> alias}, endSpan)

importItem :: Parser ImportItem
importItem = do
  kind <- option ImportItemValue (ImportItemType <$ keyword "type")
  name <- identifier
  pure ImportItem {kind = kind, name = name.value, sourceSpan = name.sourceSpan}

-- | A dotted module name @foo.bar.baz@, with the span of the whole reference.
moduleNameReference :: Parser (ModuleName, SourceSpan)
moduleNameReference = do
  first <- identifier
  rest <- many (symbol "." *> identifier)
  let segments = first : rest
  pure (moduleNameFromSegments (map (.value) segments), mergeSpans first.sourceSpan (lastSpanOr first.sourceSpan rest))
