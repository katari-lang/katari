-- | Resolving patterns: constructor / type-filter references, and the variable bindings a pattern
-- introduces (returned to the caller, which scopes them over the pattern's body).
--
-- Each pattern returns the variable bindings it introduces — a variable pattern binds its name (with
-- a fresh local-variable id), a constructor / record / tuple pattern accumulates its sub-patterns'
-- bindings. The caller threads them into scope.
module Katari.Identifier.Pattern where

import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Id (VariableResolution (..))
import Katari.Identifier.Monad
import Katari.Identifier.Type (resolveType)

resolvePattern :: Pattern Parsed -> Identifier (Pattern Identified, List Binding)
resolvePattern = \case
  PatternVariable node -> do
    localVariableId <- freshLocalVariableId
    typeAnnotation <- traverse resolveType node.typeAnnotation
    let resolution = VariableResolutionLocalVariable localVariableId
    pure
      ( PatternVariable
          VariablePattern
            { name = node.name,
              variableReference = identifiedReference node.variableReference.sourceSpan (Just resolution),
              typeAnnotation = typeAnnotation,
              defaultValue = node.defaultValue,
              sourceSpan = node.sourceSpan,
              typeOf = ()
            },
        [variableBinding node.name node.variableReference.sourceSpan resolution]
      )
  PatternWildcard node -> do
    typeAnnotation <- traverse resolveType node.typeAnnotation
    pure (PatternWildcard WildcardPattern {typeAnnotation = typeAnnotation, sourceSpan = node.sourceSpan, typeOf = ()}, [])
  PatternLiteral node ->
    pure (PatternLiteral LiteralPattern {value = node.value, sourceSpan = node.sourceSpan, typeOf = ()}, [])
  PatternTuple node -> do
    (elements, bindings) <- resolvePatternList node.elements
    pure (PatternTuple TuplePattern {elements = elements, sourceSpan = node.sourceSpan, typeOf = ()}, bindings)
  PatternTypeFilter node -> do
    matchedType <- resolveType node.matchedType
    (inner, bindings) <- resolvePattern node.inner
    pure (PatternTypeFilter TypeFilterPattern {matchedType = matchedType, inner = inner, sourceSpan = node.sourceSpan, typeOf = ()}, bindings)
  PatternRecord node -> do
    (fields, bindings) <- resolveFieldPatterns node.fields
    pure (PatternRecord RecordPattern {fields = fields, sourceSpan = node.sourceSpan, typeOf = ()}, bindings)
  PatternConstructor node -> do
    (moduleQualifier, constructorReference) <- resolveConstructorReference node.moduleQualifier node.name node.constructorReference
    genericArguments <- traverse resolveType node.genericArguments
    (fields, bindings) <- resolveFieldPatterns node.fields
    pure
      ( PatternConstructor
          ConstructorPattern
            { moduleQualifier = moduleQualifier,
              name = node.name,
              constructorReference = constructorReference,
              genericArguments = genericArguments,
              instantiation = (),
              fields = fields,
              sourceSpan = node.sourceSpan,
              typeOf = ()
            },
        bindings
      )

resolvePatternList :: List (Pattern Parsed) -> Identifier (List (Pattern Identified), List Binding)
resolvePatternList = resolveAll resolvePattern

resolveFieldPatterns :: List (FieldPattern Parsed) -> Identifier (List (FieldPattern Identified), List Binding)
resolveFieldPatterns = resolveAll resolveFieldPattern

resolveFieldPattern :: FieldPattern Parsed -> Identifier (FieldPattern Identified, List Binding)
resolveFieldPattern field = do
  (bindPattern, bindings) <- resolvePattern field.bindPattern
  pure
    ( FieldPattern {name = field.name, labelReference = retagReference field.labelReference, bindPattern = bindPattern, sourceSpan = field.sourceSpan},
      bindings
    )

-- | Resolve a constructor reference (the constructor lives in the variable namespace), qualified or
-- not.
resolveConstructorReference ::
  Maybe (ModuleQualifier Parsed) ->
  Text ->
  Reference Parsed VariableReference ->
  Identifier (Maybe (ModuleQualifier Identified), Reference Identified VariableReference)
resolveConstructorReference = resolveQualifiedReference resolveVariableReference resolveVariableMember

---------------------------------------------------------------------------------------------------
-- Parameter bindings (agent / request-handler formal parameters)
---------------------------------------------------------------------------------------------------

-- | Resolve a @label => pattern@ parameter, returning the variables its pattern binds (the label
-- itself is not a name reference).
resolveParameterBinding :: ParameterBinding Parsed -> Identifier (ParameterBinding Identified, List Binding)
resolveParameterBinding binding = do
  (bindPattern, bindings) <- resolvePattern binding.bindPattern
  pure
    ( ParameterBinding
        { annotation = binding.annotation,
          name = binding.name,
          labelReference = retagReference binding.labelReference,
          bindPattern = bindPattern,
          sourceSpan = binding.sourceSpan
        },
      bindings
    )
