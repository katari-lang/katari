-- | Parser for patterns and the @label => pattern@ parameter-binding form.
--
-- The tricky case is a head followed by parentheses: @Head(...)@ is a /constructor/ pattern when the
-- contents are @label => pattern@ fields (or empty), and a /type filter/ @Type(innerPattern)@ when
-- the contents are a single bare pattern. A head with no parentheses is a plain variable binding (so
-- @n@ and @n : T@ bind @n@). We parse the head once as a type expression and then decide.
module Katari.Parser.Pattern where

import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.SourceSpan (HasSourceSpan (..), Located (..), SourceSpan)
import Katari.Parser.Lexer
import Katari.Parser.Type (applicationType, parameterDefault, typeExpression)
import Text.Megaparsec
import Text.Megaparsec.Char (char)

type PatternP = Pattern Parsed

---------------------------------------------------------------------------------------------------
-- Patterns
---------------------------------------------------------------------------------------------------

pattern' :: Parser PatternP
pattern' =
  label "pattern" $
    choice
      [ wildcardPattern,
        recordPattern,
        tuplePattern,
        literalPattern,
        constructorFilterOrVariablePattern
      ]

-- | @_ [: T]@ — matches anything, optionally narrowing.
wildcardPattern :: Parser PatternP
wildcardPattern = do
  underscoreSpan <- snd <$> lexeme (try (char '_' <* notFollowedBy identifierContinue))
  annotation <- optional (symbol ":" *> typeExpression)
  pure
    ( PatternWildcard
        WildcardPattern
          { typeAnnotation = annotation,
            sourceSpan = maybe underscoreSpan (mergeSpans underscoreSpan . sourceSpanOf) annotation,
            typeOf = ()
          }
    )

-- | @42@ / @"foo"@ / @true@ / @null@ — a refutable literal (signed numerics allowed).
literalPattern :: Parser PatternP
literalPattern = do
  value <- signedLiteralValue
  pure (PatternLiteral LiteralPattern {value = value.value, sourceSpan = value.sourceSpan, typeOf = ()})

-- | @{ label => pattern, ... }@ — a subset match against a record value.
recordPattern :: Parser PatternP
recordPattern = do
  (fields, sourceSpan) <- bracesMultiline (commaSeparated recordField)
  pure (PatternRecord RecordPattern {fields = fields, sourceSpan = sourceSpan, typeOf = ()})

-- | @[p1, p2, ...]@ — a tuple pattern of any arity, including the empty @[]@ and the single @[p]@.
-- Tuples are bracketed (matching tuple values and types); a head's @(...)@ is constructor /
-- type-filter arguments, not a tuple.
tuplePattern :: Parser PatternP
tuplePattern = do
  (elements, sourceSpan) <- brackets (commaSeparated pattern')
  pure (PatternTuple TuplePattern {elements = elements, sourceSpan = sourceSpan, typeOf = ()})

-- | A record-pattern field: @label => pattern@, or the bare @label@ sugar, which binds the field's
-- value to a variable named after the label (@{ x }@ ~> @{ x => x }@). The bare form is offered only
-- in record patterns (@{...}@), where it is unambiguous; in a constructor's @T(...)@ parentheses a bare
-- inner pattern already means a type filter (@integer(n)@), so 'constructorField' there requires @=>@.
recordField :: Parser (FieldPattern Parsed)
recordField = do
  name <- identifier
  bindPattern <- (symbol "=>" *> pattern') <|> pure (bareFieldVariable name)
  pure (fieldPatternNode name bindPattern)

-- | A constructor-pattern field: @label => pattern@ (no bare sugar — see 'recordField').
constructorField :: Parser (FieldPattern Parsed)
constructorField = do
  name <- identifier
  bindPattern <- symbol "=>" *> pattern'
  pure (fieldPatternNode name bindPattern)

fieldPatternNode :: Located Text -> PatternP -> FieldPattern Parsed
fieldPatternNode name bindPattern =
  FieldPattern
    { name = name.value,
      labelReference = parsedReference name.sourceSpan,
      bindPattern = bindPattern,
      sourceSpan = mergeSpans name.sourceSpan (sourceSpanOf bindPattern)
    }

-- | The variable pattern a bare field @{ x }@ desugars to: bind the field value to @x@.
bareFieldVariable :: Located Text -> PatternP
bareFieldVariable name =
  PatternVariable
    VariablePattern
      { name = name.value,
        variableReference = parsedReference name.sourceSpan,
        typeAnnotation = Nothing,
        sourceSpan = name.sourceSpan,
        typeOf = ()
      }

-- | The contents between a head's parentheses: constructor fields (each @label => pattern@) or a
-- single bare inner pattern (a type filter).
data PatternArguments where
  ConstructorFields :: List (FieldPattern Parsed) -> PatternArguments
  FilterInner :: PatternP -> PatternArguments

patternArguments :: Parser PatternArguments
patternArguments =
  try (ConstructorFields <$> commaSeparated constructorField)
    <|> (FilterInner <$> pattern')

-- | A head (parsed as a type) optionally followed by parentheses. With fields it is a constructor
-- pattern, with a bare inner pattern a type filter, and with no parentheses a variable binding.
constructorFilterOrVariablePattern :: Parser PatternP
constructorFilterOrVariablePattern = do
  head' <- applicationType
  arguments <- optional (parens patternArguments)
  case arguments of
    Just (ConstructorFields fields, parenSpan) -> constructorPattern head' fields parenSpan
    Just (FilterInner inner, parenSpan) ->
      pure
        ( PatternTypeFilter
            TypeFilterPattern
              { matchedType = head',
                inner = inner,
                sourceSpan = mergeSpans (sourceSpanOf head') parenSpan,
                typeOf = ()
              }
        )
    Nothing -> variablePatternFromHead head'

constructorPattern :: SyntacticTypeExpression Parsed -> List (FieldPattern Parsed) -> SourceSpan -> Parser PatternP
constructorPattern head' fields parenSpan =
  case constructorHead head' of
    Just decomposed ->
      pure
        ( PatternConstructor
            ConstructorPattern
              { moduleQualifier = decomposed.moduleQualifier,
                name = decomposed.name,
                -- The reference points at the constructor name only; the pattern spans the whole head.
                constructorReference = parsedReference decomposed.nameSpan,
                genericArguments = decomposed.genericArguments,
                instantiation = (),
                fields = fields,
                sourceSpan = mergeSpans (sourceSpanOf head') parenSpan,
                typeOf = ()
              }
        )
    Nothing -> fail "a constructor pattern requires a constructor name before its fields"

-- | A bare head (no parentheses) is a variable binding; the head must be an unqualified plain name.
variablePatternFromHead :: SyntacticTypeExpression Parsed -> Parser PatternP
variablePatternFromHead = \case
  TypeName node | Nothing <- node.moduleQualifier -> do
    annotation <- optional (symbol ":" *> typeExpression)
    pure
      ( PatternVariable
          VariablePattern
            { name = node.name,
              variableReference = parsedReference node.sourceSpan,
              typeAnnotation = annotation,
              sourceSpan = variableSpan node.sourceSpan annotation Nothing,
              typeOf = ()
            }
      )
  _ -> fail "expected a pattern"

variableSpan :: SourceSpan -> Maybe (SyntacticTypeExpression Parsed) -> Maybe ParameterDefault -> SourceSpan
variableSpan nameSpan annotation defaultValue =
  case defaultValue of
    Just parameterDefault' -> mergeSpans nameSpan parameterDefault'.sourceSpan
    Nothing -> maybe nameSpan (mergeSpans nameSpan . sourceSpanOf) annotation

-- | A parsed head type decomposed into its constructor parts: the @nameSpan@ is the constructor name
-- alone (for its reference), while the head node still carries the whole-head span.
data ConstructorHead = ConstructorHead
  { moduleQualifier :: Maybe (ModuleQualifier Parsed),
    name :: Text,
    genericArguments :: List (SyntacticTypeExpression Parsed),
    nameSpan :: SourceSpan
  }

-- | Decompose a head into its constructor parts, or 'Nothing' if it is not a (possibly applied) name.
constructorHead :: SyntacticTypeExpression Parsed -> Maybe ConstructorHead
constructorHead = \case
  TypeName node -> Just ConstructorHead {moduleQualifier = node.moduleQualifier, name = node.name, genericArguments = [], nameSpan = node.typeReference.sourceSpan}
  TypeApplication node -> case node.applicationHead of
    TypeName inner -> Just ConstructorHead {moduleQualifier = inner.moduleQualifier, name = inner.name, genericArguments = node.applicationArguments, nameSpan = inner.typeReference.sourceSpan}
    _ -> Nothing
  _ -> Nothing

---------------------------------------------------------------------------------------------------
-- Parameter bindings (agent / request-handler formal parameters)
---------------------------------------------------------------------------------------------------

-- | @label => pattern@ (destructure), or the sugar @label@ / @label : T@ / @label [: T] ?= default@
-- (bind the label-named variable, optionally with a default). Destructure and default are mutually
-- exclusive.
parameterBinding :: Parser (ParameterBinding Parsed)
parameterBinding = do
  annotation <- optional docAnnotation
  bindingLabel <- identifier
  binder <- (BindDestructure <$> (symbol "=>" *> pattern')) <|> sugarBinder bindingLabel
  let startSpan = maybe bindingLabel.sourceSpan (.sourceSpan) annotation
  pure
    ParameterBinding
      { annotation = (.value) <$> annotation,
        name = bindingLabel.value,
        labelReference = parsedReference bindingLabel.sourceSpan,
        binder = binder,
        sourceSpan = mergeSpans startSpan (binderEndSpan bindingLabel binder)
      }

-- | The span end of a binder, for the enclosing 'ParameterBinding' span.
binderEndSpan :: Located Text -> Binder Parsed -> SourceSpan
binderEndSpan bindingLabel = \case
  BindDestructure pattern' -> sourceSpanOf pattern'
  BindVariable _ typeAnnotation defaultValue -> variableSpan bindingLabel.sourceSpan typeAnnotation defaultValue

-- | The sugar @label [: T] [?= default]@ as a variable binder on @label@.
sugarBinder :: Located Text -> Parser (Binder Parsed)
sugarBinder bindingLabel = do
  annotation <- optional (symbol ":" *> typeExpression)
  defaultValue <- optional parameterDefault
  pure (BindVariable (parsedReference bindingLabel.sourceSpan) annotation defaultValue)
