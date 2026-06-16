-- | Parser for type-level syntax (types, effects, attributes): 'SyntacticTypeExpression', plus the
-- generic-parameter and typed-parameter-signature forms that decorate declarations.
--
-- One kind-agnostic grammar covers types, @with@-clause effects, and @of@ attributes; the checker
-- splits them by kind after name resolution (see "Katari.Data.AST"). Precedence, loosest first:
-- union @|@, attribution @of@, application @head[args]@, then atoms.
module Katari.Parser.Type where

import Data.Maybe (fromMaybe)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.SourceSpan (HasSourceSpan (..), Located (..), SourceSpan)
import Katari.Parser.Lexer
import Text.Megaparsec

-- | A parsed type-level expression.
type TypeExpression = SyntacticTypeExpression Parsed

---------------------------------------------------------------------------------------------------
-- Entry point + operator levels
---------------------------------------------------------------------------------------------------

typeExpression :: Parser TypeExpression
typeExpression = label "type" unionType

-- | @T1 | T2 | ...@ — a union of 2+ branches, else just the single branch.
unionType :: Parser TypeExpression
unionType = do
  first <- attributedType
  rest <- many (symbol "|" *> attributedType)
  pure $ case rest of
    [] -> first
    _ ->
      TypeUnion
        TypeUnionNode
          { branches = first : rest,
            sourceSpan = mergeSpans (sourceSpanOf first) (lastSpanOr (sourceSpanOf first) rest)
          }

-- | @T of A of ...@ — left-associative attribution.
attributedType :: Parser TypeExpression
attributedType = do
  base <- applicationType
  attributes <- many (keyword "of" *> applicationType)
  pure (foldl attribute base attributes)
  where
    attribute baseType attributeType =
      TypeAttributed
        AttributedTypeNode
          { baseType = baseType,
            attribute = attributeType,
            sourceSpan = mergeSpans (sourceSpanOf baseType) (sourceSpanOf attributeType)
          }

-- | @head[argument, ...][...]...@ — left-associative postfix application.
applicationType :: Parser TypeExpression
applicationType = do
  head' <- atomType
  applications <- many (brackets (commaSeparated typeExpression))
  pure (foldl apply head' applications)
  where
    apply applicationHead (applicationArguments, bracketSpan) =
      TypeApplication
        TypeApplicationTypeNode
          { applicationHead = applicationHead,
            applicationArguments = applicationArguments,
            sourceSpan = mergeSpans (sourceSpanOf applicationHead) bracketSpan
          }

atomType :: Parser TypeExpression
atomType =
  choice
    [ agentType,
      primitiveType,
      TypeNever <$> keyword "never",
      TypeUnknown <$> keyword "unknown",
      TypeAll <$> keyword "all",
      attributeLiteralType,
      TypeArray <$> keyword "array",
      TypeRecord <$> keyword "record",
      bracesType,
      bracketTupleType,
      parenType,
      nameType
    ]

---------------------------------------------------------------------------------------------------
-- Atoms
---------------------------------------------------------------------------------------------------

primitiveType :: Parser TypeExpression
primitiveType =
  choice
    [ primitive "null" PrimitiveTypeKindNull,
      primitive "integer" PrimitiveTypeKindInteger,
      primitive "number" PrimitiveTypeKindNumber,
      primitive "string" PrimitiveTypeKindString,
      primitive "boolean" PrimitiveTypeKindBoolean,
      primitive "file" PrimitiveTypeKindFile
    ]
  where
    primitive word kind =
      (\sourceSpan -> TypePrimitive PrimitiveTypeNode {kind = kind, sourceSpan = sourceSpan})
        <$> keyword word

attributeLiteralType :: Parser TypeExpression
attributeLiteralType =
  choice
    [ literal "public" AttributeLiteralPublic,
      literal "private" AttributeLiteralPrivate
    ]
  where
    literal word kind =
      (\sourceSpan -> TypeAttributeLiteral AttributeLiteralNode {kind = kind, sourceSpan = sourceSpan})
        <$> keyword word

-- | @[module.]name@ — a kind-agnostic name reference, optionally qualified by exactly one module
-- segment. Builtins (@integer@, @array@, ...) are matched by earlier atoms, so they never reach
-- here as names.
nameType :: Parser TypeExpression
nameType = do
  first <- identifier
  member <- optional (symbol "." *> identifier)
  pure $ case member of
    Nothing ->
      TypeName
        TypeNameNode
          { moduleQualifier = Nothing,
            name = first.value,
            typeReference = parsedReference first.sourceSpan,
            sourceSpan = first.sourceSpan
          }
    Just second ->
      let sourceSpan = mergeSpans first.sourceSpan second.sourceSpan
       in TypeName
            TypeNameNode
              { moduleQualifier =
                  Just
                    ModuleQualifier
                      { name = first.value,
                        moduleReference = parsedReference first.sourceSpan,
                        sourceSpan = first.sourceSpan
                      },
                name = second.value,
                -- The reference points at the member name only; @sourceSpan@ spans the whole @module.Name@.
                typeReference = parsedReference second.sourceSpan,
                sourceSpan = sourceSpan
              }

-- | @[T1, T2, ...]@ — a tuple type of any arity, including the empty @[]@ and the single-element
-- @[T]@. Tuples are bracketed (matching tuple values and patterns); @array[T]@ / @record[T]@ are
-- keyword applications, and @(T)@ is mere grouping (see 'parenType').
bracketTupleType :: Parser TypeExpression
bracketTupleType = do
  (elementTypes, sourceSpan) <- brackets (commaSeparated typeExpression)
  pure (TypeTuple TupleTypeNode {elementTypes = elementTypes, sourceSpan = sourceSpan})

-- | @(T)@ — grouping only. Tuples moved to @[...]@, so parentheses no longer build a tuple; they
-- only override precedence around a single type.
parenType :: Parser TypeExpression
parenType = fst <$> parens typeExpression

-- | @{label : T, ...}@ object type, or @{...E, request[args], ...}@ effect override.
bracesType :: Parser TypeExpression
bracesType = do
  (build, sourceSpan) <- bracesMultiline (overrideBody <|> objectBody)
  pure (build sourceSpan)
  where
    overrideBody = do
      _ <- symbol "..."
      base <- typeExpression
      overrides <- option [] (symbol "," *> commaSeparated applicationType)
      pure (\sourceSpan -> TypeOverride OverrideTypeNode {base = base, overrides = overrides, sourceSpan = sourceSpan})
    objectBody = do
      fields <- commaSeparated objectTypeField
      pure (\sourceSpan -> TypeObject ObjectTypeNode {fields = fields, sourceSpan = sourceSpan})

-- | @label : T@ / @label ?: T@ — one field of an object type (also the agent-parameter sugar).
objectTypeField :: Parser (ObjectTypeField Parsed)
objectTypeField = do
  name <- identifier
  isOptional <- option False (True <$ symbol "?")
  _ <- symbol ":"
  fieldType <- typeExpression
  pure
    ObjectTypeField
      { name = name.value,
        fieldType = fieldType,
        optional = isOptional,
        sourceSpan = mergeSpans name.sourceSpan (sourceSpanOf fieldType)
      }

-- | @agent Param -> Return [with Effect]@. The parenthesised form @agent (label : T, ...) -> R@ is
-- sugar for an object parameter type; @agent () -> R@ is the empty object.
agentType :: Parser TypeExpression
agentType = do
  agentSpan <- keyword "agent"
  parameterType <- agentParameterType
  _ <- symbol "->"
  returnType <- typeExpression
  effects <- optional (keyword "with" *> typeExpression)
  let endSpan = maybe (sourceSpanOf returnType) sourceSpanOf effects
  pure
    ( TypeAgent
        AgentTypeNode
          { parameterType = parameterType,
            returnType = returnType,
            effects = effects,
            sourceSpan = mergeSpans agentSpan endSpan
          }
    )

-- | The parameter side of an agent type: the labelled sugar @(label : T, ...)@ desugars to an
-- object type; otherwise a single type (which may itself be @(T)@ or @(T1, T2)@).
agentParameterType :: Parser TypeExpression
agentParameterType = try objectSugar <|> applicationType
  where
    objectSugar = do
      (fields, sourceSpan) <- parens (commaSeparated objectTypeField)
      pure (TypeObject ObjectTypeNode {fields = fields, sourceSpan = sourceSpan})

---------------------------------------------------------------------------------------------------
-- Declaration decorations: generic parameters, typed parameter signatures
---------------------------------------------------------------------------------------------------

-- | @[A, effect E, attribute T, ...]@ — the formal generic parameter list, empty when omitted.
genericParameters :: Parser (List (GenericParameter Parsed))
genericParameters = option [] (fst <$> brackets (commaSeparated1 genericParameter))

genericParameter :: Parser (GenericParameter Parsed)
genericParameter = do
  (kind, kindSpan) <- genericParameterKind
  name <- identifier
  upperBound <- optional (keyword "extends" *> typeExpression)
  pure
    GenericParameter
      { name = name.value,
        labelReference = parsedReference name.sourceSpan,
        typeReference = parsedReference name.sourceSpan,
        kind = kind,
        upperBound = upperBound,
        sourceSpan = mergeSpans (fromMaybe name.sourceSpan kindSpan) (maybe name.sourceSpan sourceSpanOf upperBound)
      }

-- | An optional @effect@ / @attribute@ kind prefix; absent (or not followed by a name) means a
-- plain type parameter, so @[effect]@ is a parameter literally named @effect@.
genericParameterKind :: Parser (GenericKind, Maybe SourceSpan)
genericParameterKind =
  prefix "effect" GenericKindEffect
    <|> prefix "attribute" GenericKindAttribute
    <|> pure (GenericKindType, Nothing)
  where
    prefix word kind = do
      kindSpan <- try (keyword word <* lookAhead identifier)
      pure (kind, Just kindSpan)

-- | @label : T [?= default]@ — a typed parameter of a request / external / primitive / data.
parameterSignature :: Parser (ParameterSignature Parsed)
parameterSignature = do
  annotation <- optional docAnnotation
  name <- identifier
  _ <- symbol ":"
  parameterType <- typeExpression
  defaultValue <- optional parameterDefault
  let startSpan = maybe name.sourceSpan (.sourceSpan) annotation
      endSpan = maybe (sourceSpanOf parameterType) (.sourceSpan) defaultValue
  pure
    ParameterSignature
      { annotation = (.value) <$> annotation,
        name = name.value,
        labelReference = parsedReference name.sourceSpan,
        parameterType = parameterType,
        defaultValue = defaultValue,
        sourceSpan = mergeSpans startSpan endSpan
      }

-- | @?= literal@ — a parameter default (a literal value, not an arbitrary expression).
parameterDefault :: Parser ParameterDefault
parameterDefault = do
  defaultSpan <- symbol "?="
  value <- defaultLiteralValue
  pure ParameterDefault {value = value.value, sourceSpan = mergeSpans defaultSpan value.sourceSpan}
