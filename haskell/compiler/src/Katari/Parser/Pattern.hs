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
        -- Before 'literalPattern' so @null(x)@ is a type filter (not the @null@ literal plus leftover),
        -- and before 'constructorOrVariablePattern'; 'try' lets a bare tag word fall through.
        try typeFilterPattern,
        literalPattern,
        constructorOrVariablePattern
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
  (fields, sourceSpan) <- bracesMultiline (commaSeparated fieldPattern)
  pure (PatternRecord RecordPattern {fields = fields, sourceSpan = sourceSpan, typeOf = ()})

-- | @[p1, p2, ...]@ — a tuple pattern of any arity, including the empty @[]@ and the single @[p]@.
-- Tuples are bracketed (matching tuple values and types); a head's @(...)@ is constructor /
-- type-filter arguments, not a tuple.
tuplePattern :: Parser PatternP
tuplePattern = do
  (elements, sourceSpan) <- brackets (commaSeparated pattern')
  pure (PatternTuple TuplePattern {elements = elements, sourceSpan = sourceSpan, typeOf = ()})

-- | A constructor- / record-pattern field: @label => pattern@ (destructure) or the bare @label@ sugar,
-- which binds the field's value to a variable named after the label (@{ x }@ ~> @{ x => x }@). The bare
-- form is unambiguous: a constructor head is always a (data-type) name (@point(x)@), while a type filter's
-- head is always a primitive (@integer(n)@) — the two are split on the head in
-- 'constructorFilterOrVariablePattern'.
fieldPattern :: Parser (FieldPattern Parsed)
fieldPattern = do
  name <- identifier
  bindPattern <- (symbol "=>" *> pattern') <|> pure (bareFieldVariable name)
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

-- | A head (parsed as a type) and what follows it, split on the /head/ — which removes the constructor
-- vs. type-filter ambiguity:
--
--   * a primitive head (@integer@, @string@, ...) is a type filter @T(inner)@ (the only type-filter
--     form — type filters are primitive-only);
--   * a (possibly applied) name head is a data constructor, whose parentheses hold its fields (bare
--     @label@ or @label => pattern@); with no parentheses it is a plain variable binding.
-- (A type filter @tag(inner)@ is parsed separately by 'typeFilterPattern', which is tried first.)
constructorOrVariablePattern :: Parser PatternP
constructorOrVariablePattern = do
  head' <- applicationType
  case constructorHead head' of
    Just _ -> do
      maybeFields <- optional (parens (commaSeparated fieldPattern))
      case maybeFields of
        Just (fields, parenSpan) -> constructorPattern head' fields parenSpan
        Nothing -> variablePatternFromHead head'
    Nothing -> variablePatternFromHead head'

-- | A type filter @tag(inner)@ on one of the fixed runtime tags (primitive, @array@, @record@,
-- @agent@). Parsed by its own fixed keywords (not the general type parser), so @agent(f)@ does not
-- collide with the @agent(T) -> R@ type syntax, and @point(x)@ stays a constructor. Tried with
-- backtracking, so a bare tag word with no parentheses (e.g. the @null@ literal) falls through.
typeFilterPattern :: Parser PatternP
typeFilterPattern = do
  (tag, tagSpan) <- filterTag
  (inner, parenSpan) <- parens pattern'
  pure
    ( PatternTypeFilter
        TypeFilterPattern
          { matchedType = tag,
            inner = inner,
            sourceSpan = mergeSpans tagSpan parenSpan,
            typeOf = ()
          }
    )

-- | The fixed type-filter tag keywords and their 'TypeFilter', with the keyword's span.
filterTag :: Parser (TypeFilter, SourceSpan)
filterTag =
  choice
    [ tagged FilterNull "null",
      tagged FilterBoolean "boolean",
      tagged FilterInteger "integer",
      tagged FilterNumber "number",
      tagged FilterString "string",
      tagged FilterFile "file",
      tagged FilterArray "array",
      tagged FilterRecord "record",
      tagged FilterAgent "agent"
    ]
  where
    tagged filter' word = (,) filter' <$> keyword word

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
  BindDestructure parsedPattern -> sourceSpanOf parsedPattern
  BindVariable _ typeAnnotation defaultValue -> variableSpan bindingLabel.sourceSpan typeAnnotation defaultValue

-- | The sugar @label [: T] [?= default]@ as a variable binder on @label@.
sugarBinder :: Located Text -> Parser (Binder Parsed)
sugarBinder bindingLabel = do
  annotation <- optional (symbol ":" *> typeExpression)
  defaultValue <- optional parameterDefault
  pure (BindVariable (parsedReference bindingLabel.sourceSpan) annotation defaultValue)
