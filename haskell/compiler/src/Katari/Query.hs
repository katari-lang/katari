-- | Position-based query layer for LSP tooling: hover, go-to-definition, and find-references.
--
-- Callers compile a source set via 'Katari.Compile.compile', build a 'QuerySnapshot' from the
-- result once, and answer editor queries against it until the next recompile. All positions are
-- code-point based, 1-indexed (the LSP layer converts UTF-16 offsets before calling here), and all
-- module keys are compiler 'ModuleName's — a span's @filePath@ is the rendered module name (see
-- 'Katari.Compile.moduleStartSpan'), so the editor layer owns the module-name ↔ real-file mapping.
--
-- The snapshot is two flat fact lists per module, produced by one total walk over the typed AST:
--
--   * 'Occurrence' — every resolved name reference (uses AND defining occurrences, since a
--     declaration's own name is a resolved 'Reference' node like any other), keyed by a
--     module-disambiguated 'ResolvedReference'.
--   * 'TypedSpan' — every node that carries a 'SemanticType' at 'Typed'.
--
-- Queries are then "innermost span containing the position" filters over those lists. Linear scans
-- are deliberate: modules are editor-buffer sized, and a flat list keeps the walk total per AST
-- constructor (a new node that is not walked is a missing-case compile error here, not a silently
-- unqueryable span).
module Katari.Query where

import Data.List (minimumBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (comparing)
import Data.Text (Text)
import GHC.List (List)
import Katari.Compile (CompileResult (..), stdlibParsed)
import Katari.Data.AST
import Katari.Data.Id (GenericId (..), LocalVariableId, TypeResolution (..), VariableResolution (..))
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.QualifiedName (QualifiedName (..), renderQualifiedName)
import Katari.Data.SemanticType (FieldInformation (..), SemanticType (..), renderSemanticType)
import Katari.Data.SourceSpan (Position (..), SourceSpan (..), spanContains)
import Katari.Identifier.Monad
  ( ModuleInterface (..),
    SymbolResolution (..),
    SymbolTable (..),
    definitionSpanOf,
  )

---------------------------------------------------------------------------------------------------
-- Snapshot
---------------------------------------------------------------------------------------------------

-- | Which resolved entity a source occurrence points at. Local variables carry their containing
-- module: a 'LocalVariableId' is a per-module counter, so two modules' locals would collide without
-- it. Generics already carry their declaring module inside 'GenericId'.
data ResolvedReference
  = ResolvedReferenceLocal ModuleName LocalVariableId
  | ResolvedReferenceTopLevelVariable QualifiedName
  | ResolvedReferenceGeneric GenericId
  | ResolvedReferenceTopLevelType QualifiedName
  | ResolvedReferenceModule ModuleName
  deriving stock (Eq, Ord, Show)

-- | One resolved name occurrence in a module's source.
data Occurrence = Occurrence
  { sourceSpan :: SourceSpan,
    target :: ResolvedReference
  }
  deriving stock (Eq, Show)

-- | One node's inferred type, at its span.
data TypedSpan = TypedSpan
  { sourceSpan :: SourceSpan,
    semanticType :: SemanticType
  }
  deriving stock (Eq, Show)

-- | Everything the walk collects for one module.
data ModuleFacts = ModuleFacts
  { occurrences :: List Occurrence,
    typedSpans :: List TypedSpan,
    -- | The binding type of each local variable whose defining node carries (or implies) one:
    -- pattern binders, agent parameters, @var@ state. Read by completion (the type of a bare local
    -- in scope) — use sites carry their own type on the 'TypedSpan' facts already.
    localVariableTypes :: Map LocalVariableId SemanticType
  }
  deriving stock (Show)

instance Semigroup ModuleFacts where
  left <> right =
    ModuleFacts
      { occurrences = left.occurrences <> right.occurrences,
        typedSpans = left.typedSpans <> right.typedSpans,
        localVariableTypes = Map.union left.localVariableTypes right.localVariableTypes
      }

instance Monoid ModuleFacts where
  mempty = ModuleFacts {occurrences = [], typedSpans = [], localVariableTypes = Map.empty}

-- | What kind of declaration a top-level name is, for completion-item classification.
data DeclarationKind
  = DeclarationKindAgent
  | DeclarationKindRequest
  | DeclarationKindConstructor
  | DeclarationKindType
  deriving stock (Eq, Show)

-- | The completion-facing surface of one top-level declaration: its kind, its doc annotation, and
-- (for agents, whose 'Typed' node carries it) its resolved type.
data DeclarationInformation = DeclarationInformation
  { kind :: DeclarationKind,
    documentation :: Maybe Text,
    declaredType :: Maybe SemanticType
  }
  deriving stock (Show)

data QuerySnapshot = QuerySnapshot
  { moduleFacts :: Map ModuleName ModuleFacts,
    symbolTables :: Map ModuleName SymbolTable,
    moduleInterfaces :: Map ModuleName ModuleInterface,
    -- | Variable-namespace declarations (agents, requests-as-callables, data-as-constructors),
    -- across user modules AND the stdlib.
    valueDeclarations :: Map QualifiedName DeclarationInformation,
    -- | Type-namespace declarations (data types, synonyms, requests-as-effects), same coverage.
    typeDeclarations :: Map QualifiedName DeclarationInformation
  }
  deriving stock (Show)

-- | Build the query surface from a compile. The user's modules contribute facts from their typed
-- ASTs; the stdlib (not part of 'CompileResult.typedModules') contributes declaration kinds and doc
-- annotations from its shared parsed form, so member completion on @prelude.*@ still classifies and
-- documents items — it just has no resolved types or navigable spans.
buildQuerySnapshot :: CompileResult -> QuerySnapshot
buildQuerySnapshot result =
  QuerySnapshot
    { moduleFacts = Map.mapWithKey moduleFactsOf result.typedModules,
      symbolTables = result.symbolTables,
      moduleInterfaces = result.moduleInterfaces,
      valueDeclarations = Map.union userValues stdlibValues,
      typeDeclarations = Map.union userTypes stdlibTypes
    }
  where
    (userValues, userTypes) = declarationInformationOf typedDeclarationSurface result.typedModules
    (stdlibValues, stdlibTypes) = declarationInformationOf parsedDeclarationSurface (fst <$> stdlibParsed)

---------------------------------------------------------------------------------------------------
-- Declaration information (kinds / docs / agent types)
---------------------------------------------------------------------------------------------------

-- | One declaration's contribution to the two namespace maps: @(name, value entry?, type entry?)@.
type DeclarationSurface = (Text, Maybe DeclarationInformation, Maybe DeclarationInformation)

declarationInformationOf ::
  (Declaration phase -> List DeclarationSurface) ->
  Map ModuleName (Module phase) ->
  (Map QualifiedName DeclarationInformation, Map QualifiedName DeclarationInformation)
declarationInformationOf surfaceOf modules = (Map.fromList values, Map.fromList types)
  where
    surfaces =
      [ (QualifiedName {moduleName = moduleName, name = name}, valueEntry, typeEntry)
        | (moduleName, module') <- Map.toList modules,
          declaration <- module'.declarations,
          (name, valueEntry, typeEntry) <- surfaceOf declaration
      ]
    values = [(qualifiedName, entry) | (qualifiedName, Just entry, _) <- surfaces]
    types = [(qualifiedName, entry) | (qualifiedName, _, Just entry) <- surfaces]

-- | The declaration surface at 'Typed': agents additionally carry their checked type.
typedDeclarationSurface :: Declaration Typed -> List DeclarationSurface
typedDeclarationSurface = \case
  DeclarationAgent declaration ->
    [(declaration.name, Just (information DeclarationKindAgent declaration.annotation (Just declaration.typeOf)), Nothing)]
  other -> parsedDeclarationSurface other

-- | The phase-agnostic declaration surface (kinds and docs come from fields every phase shares).
parsedDeclarationSurface :: Declaration phase -> List DeclarationSurface
parsedDeclarationSurface = \case
  DeclarationAgent declaration ->
    [(declaration.name, Just (information DeclarationKindAgent declaration.annotation Nothing), Nothing)]
  DeclarationExternalAgent declaration ->
    [(declaration.name, Just (information DeclarationKindAgent declaration.annotation Nothing), Nothing)]
  DeclarationPrimitiveAgent declaration ->
    [(declaration.name, Just (information DeclarationKindAgent declaration.annotation Nothing), Nothing)]
  DeclarationRequest declaration ->
    [ ( declaration.name,
        Just (information DeclarationKindRequest declaration.annotation Nothing),
        Just (information DeclarationKindRequest declaration.annotation Nothing)
      )
    ]
  -- A marker effect surfaces only in the type namespace (there is no value to perform); it presents
  -- as a request there because that is how it is referenced — inside effect rows.
  DeclarationMarkerEffect declaration ->
    [(declaration.name, Nothing, Just (information DeclarationKindRequest declaration.annotation Nothing))]
  DeclarationData declaration ->
    [ ( declaration.name,
        Just (information DeclarationKindConstructor declaration.annotation Nothing),
        Just (information DeclarationKindType declaration.annotation Nothing)
      )
    ]
  DeclarationTypeSynonym declaration ->
    [(declaration.name, Nothing, Just (information DeclarationKindType Nothing Nothing))]
  DeclarationImport _ -> []
  DeclarationError _ -> []

information :: DeclarationKind -> Maybe Text -> Maybe SemanticType -> DeclarationInformation
information kind documentation declaredType =
  DeclarationInformation {kind = kind, documentation = documentation, declaredType = declaredType}

---------------------------------------------------------------------------------------------------
-- Position queries
---------------------------------------------------------------------------------------------------

-- | The innermost occurrence covering a position (names never overlap except by nesting through
-- qualifiers, so smallest-span-wins picks the name itself over its enclosing expression).
occurrenceAt :: QuerySnapshot -> ModuleName -> Position -> Maybe Occurrence
occurrenceAt snapshot moduleName position = do
  facts <- Map.lookup moduleName snapshot.moduleFacts
  innermostBy (.sourceSpan) position facts.occurrences

-- | The innermost typed node covering a position.
typedSpanAt :: QuerySnapshot -> ModuleName -> Position -> Maybe TypedSpan
typedSpanAt snapshot moduleName position = do
  facts <- Map.lookup moduleName snapshot.moduleFacts
  innermostBy (.sourceSpan) position facts.typedSpans

innermostBy :: (fact -> SourceSpan) -> Position -> List fact -> Maybe fact
innermostBy spanOf position facts = case covering of
  [] -> Nothing
  _ -> Just (minimumBy (comparing (spanSize . spanOf)) covering)
  where
    covering = filter (\fact -> spanContains (spanOf fact) position) facts
    -- Lexicographic (line delta, column delta): a span within another has a smaller or equal line
    -- delta, and a smaller column delta on a tie.
    spanSize sourceSpan =
      (sourceSpan.end.line - sourceSpan.start.line, sourceSpan.end.column - sourceSpan.start.column)

---------------------------------------------------------------------------------------------------
-- Hover
---------------------------------------------------------------------------------------------------

-- | What hover shows for a position: the span to slice the source snippet from, the inferred type
-- (when a typed node covers the position), and the qualified name (when the position sits on a
-- top-level reference).
data HoverInfo = HoverInfo
  { nameSpan :: SourceSpan,
    semanticType :: Maybe SemanticType,
    qualifiedName :: Maybe Text
  }
  deriving stock (Show)

hoverAt :: QuerySnapshot -> ModuleName -> Position -> Maybe HoverInfo
hoverAt snapshot moduleName position =
  case (occurrenceAt snapshot moduleName position, typedSpanAt snapshot moduleName position) of
    (Just occurrence, typedSpan) ->
      Just
        HoverInfo
          { nameSpan = occurrence.sourceSpan,
            semanticType = (.semanticType) <$> typedSpan,
            qualifiedName = qualifiedNameOf occurrence.target
          }
    (Nothing, Just typedSpan) ->
      Just
        HoverInfo
          { nameSpan = typedSpan.sourceSpan,
            semanticType = Just typedSpan.semanticType,
            qualifiedName = Nothing
          }
    (Nothing, Nothing) -> Nothing
  where
    qualifiedNameOf = \case
      ResolvedReferenceTopLevelVariable qualifiedName -> Just (renderQualifiedName qualifiedName)
      ResolvedReferenceTopLevelType qualifiedName -> Just (renderQualifiedName qualifiedName)
      ResolvedReferenceModule referencedModule -> Just (renderQualifiedNameOfModule referencedModule)
      ResolvedReferenceLocal _ _ -> Nothing
      ResolvedReferenceGeneric _ -> Nothing
    renderQualifiedNameOfModule referencedModule =
      renderQualifiedName QualifiedName {moduleName = referencedModule, name = "*"}

-- | Render a hover type in surface syntax (re-exported here so the LSP does not import the type
-- module directly).
renderHoverType :: SemanticType -> Text
renderHoverType = renderSemanticType

---------------------------------------------------------------------------------------------------
-- Definition
---------------------------------------------------------------------------------------------------

-- | The defining occurrence of the name at a position, when it is recorded in some user module's
-- symbol table. Stdlib names resolve to 'Nothing' — they have no navigable source file.
definitionAt :: QuerySnapshot -> ModuleName -> Position -> Maybe SourceSpan
definitionAt snapshot moduleName position = do
  occurrence <- occurrenceAt snapshot moduleName position
  definitionOf snapshot moduleName occurrence.target

-- | Where a resolved reference is defined: local bindings and module qualifiers are recorded in the
-- referencing module's own table; top-level names and generics in their declaring module's.
definitionOf :: QuerySnapshot -> ModuleName -> ResolvedReference -> Maybe SourceSpan
definitionOf snapshot currentModule = \case
  ResolvedReferenceLocal owningModule localVariableId ->
    inTable owningModule (SymbolVariable (VariableResolutionLocalVariable localVariableId))
  ResolvedReferenceTopLevelVariable qualifiedName ->
    inTable qualifiedName.moduleName (SymbolVariable (VariableResolutionQualifiedName qualifiedName))
  ResolvedReferenceGeneric genericId ->
    let GenericId owningModule _ = genericId
     in inTable owningModule (SymbolType (TypeResolutionGeneric genericId))
  ResolvedReferenceTopLevelType qualifiedName ->
    inTable qualifiedName.moduleName (SymbolType (TypeResolutionQualifiedName qualifiedName))
  -- A module's "definition" is the import that bound its qualifier in the referencing module
  -- (default-import qualifiers are not recorded and yield 'Nothing').
  ResolvedReferenceModule referencedModule ->
    inTable currentModule (SymbolModule referencedModule)
  where
    inTable owningModule resolution = do
      table <- Map.lookup owningModule snapshot.symbolTables
      definitionSpanOf table resolution

---------------------------------------------------------------------------------------------------
-- References
---------------------------------------------------------------------------------------------------

-- | Every occurrence in the snapshot, grouped by target. Build once per compile (the LSP caches it
-- on its workspace state) and query per request.
newtype OccurrenceIndex = OccurrenceIndex
  { bySymbol :: Map ResolvedReference (List SourceSpan)
  }
  deriving stock (Show)

buildOccurrenceIndex :: QuerySnapshot -> OccurrenceIndex
buildOccurrenceIndex snapshot =
  OccurrenceIndex
    { bySymbol =
        Map.fromListWith
          (<>)
          [ (occurrence.target, [occurrence.sourceSpan])
            | facts <- Map.elems snapshot.moduleFacts,
              occurrence <- facts.occurrences
          ]
    }

-- | All occurrence spans of the reference (defining occurrence included — it is a resolved
-- reference node like any use).
findReferences :: OccurrenceIndex -> ResolvedReference -> List SourceSpan
findReferences index target = Map.findWithDefault [] target index.bySymbol

---------------------------------------------------------------------------------------------------
-- Fact collection: the total walk over a typed module
---------------------------------------------------------------------------------------------------

moduleFactsOf :: ModuleName -> Module Typed -> ModuleFacts
moduleFactsOf moduleName module' = foldMap (declarationFacts moduleName) module'.declarations

declarationFacts :: ModuleName -> Declaration Typed -> ModuleFacts
declarationFacts moduleName = \case
  DeclarationAgent declaration -> agentDeclarationFacts moduleName declaration
  DeclarationRequest declaration ->
    variableReferenceFacts moduleName declaration.variableReference
      <> typeReferenceFacts moduleName declaration.typeReference
      <> foldMap (genericParameterFacts moduleName) declaration.genericParameters
      <> foldMap (parameterSignatureFacts moduleName) declaration.parameters
      <> typeExpressionFacts moduleName declaration.returnType
  DeclarationMarkerEffect declaration ->
    typeReferenceFacts moduleName declaration.typeReference
      <> foldMap (genericParameterFacts moduleName) declaration.genericParameters
  DeclarationExternalAgent declaration ->
    variableReferenceFacts moduleName declaration.variableReference
      <> foldMap (genericParameterFacts moduleName) declaration.genericParameters
      <> foldMap (parameterSignatureFacts moduleName) declaration.parameters
      <> typeExpressionFacts moduleName declaration.returnType
      <> foldMap (typeExpressionFacts moduleName) declaration.effects
  DeclarationPrimitiveAgent declaration ->
    variableReferenceFacts moduleName declaration.variableReference
      <> foldMap (genericParameterFacts moduleName) declaration.genericParameters
      <> foldMap (parameterSignatureFacts moduleName) declaration.parameters
      <> typeExpressionFacts moduleName declaration.returnType
      <> foldMap (typeExpressionFacts moduleName) declaration.effects
  DeclarationData declaration ->
    variableReferenceFacts moduleName declaration.variableReference
      <> typeReferenceFacts moduleName declaration.typeReference
      <> foldMap (genericParameterFacts moduleName) declaration.genericParameters
      <> foldMap (parameterSignatureFacts moduleName) declaration.parameters
  DeclarationTypeSynonym declaration ->
    typeReferenceFacts moduleName declaration.typeReference
      <> foldMap (genericParameterFacts moduleName) declaration.genericParameters
      <> typeExpressionFacts moduleName declaration.definition
  -- Imports carry no 'Reference' nodes (their bindings live in the symbol table only).
  DeclarationImport _ -> mempty
  DeclarationError _ -> mempty

-- | An agent declaration (top-level or local statement): its own name gets both an occurrence and a
-- typed span (hovering the name shows the full agent type), and each plain-variable parameter's
-- binding type is recovered from the agent type's parameter object.
agentDeclarationFacts :: ModuleName -> AgentDeclaration Typed -> ModuleFacts
agentDeclarationFacts moduleName declaration =
  variableReferenceFacts moduleName declaration.variableReference
    <> typedSpanFacts declaration.variableReference.sourceSpan declaration.typeOf
    <> localTypeOfReference moduleName declaration.variableReference declaration.typeOf
    <> foldMap (genericParameterFacts moduleName) declaration.genericParameters
    <> foldMap (parameterBindingFacts moduleName parameterTypes) declaration.parameters
    <> foldMap (typeExpressionFacts moduleName) declaration.returnType
    <> foldMap (typeExpressionFacts moduleName) declaration.effects
    <> blockFacts moduleName declaration.body
  where
    parameterTypes = parameterObjectFields declaration.typeOf

-- | The parameter-label → type map of an agent type, seen through attribute wrappers. Empty when
-- the parameter side is not an object (a generic, or a checker recovery type).
parameterObjectFields :: SemanticType -> Map Text SemanticType
parameterObjectFields agentType = case stripAttributes agentType of
  SemanticTypeAgent parameterType _ _ -> case stripAttributes parameterType of
    SemanticTypeObject fields -> (.semanticType) <$> fields
    _ -> Map.empty
  _ -> Map.empty

stripAttributes :: SemanticType -> SemanticType
stripAttributes = \case
  SemanticTypeAttribute baseType _ -> stripAttributes baseType
  other -> other

genericParameterFacts :: ModuleName -> GenericParameter Typed -> ModuleFacts
genericParameterFacts moduleName parameter =
  typeReferenceFacts moduleName parameter.typeReference
    <> foldMap (typeExpressionFacts moduleName) parameter.upperBound

parameterSignatureFacts :: ModuleName -> ParameterSignature Typed -> ModuleFacts
parameterSignatureFacts moduleName signature =
  typeExpressionFacts moduleName signature.parameterType

-- | A formal parameter of an agent / request handler. @parameterTypes@ carries the enclosing
-- callable's label → type map when known ('Map.empty' otherwise), so a plain 'BindVariable' — which
-- has no typed node of its own — still gets a binding type and a hover span.
parameterBindingFacts :: ModuleName -> Map Text SemanticType -> ParameterBinding Typed -> ModuleFacts
parameterBindingFacts moduleName parameterTypes binding = case binding.binder of
  BindVariable reference annotation _ ->
    variableReferenceFacts moduleName reference
      <> foldMap (typeExpressionFacts moduleName) annotation
      <> case Map.lookup binding.name parameterTypes of
        Nothing -> mempty
        Just parameterType ->
          typedSpanFacts reference.sourceSpan parameterType
            <> localTypeOfReference moduleName reference parameterType
  BindDestructure pattern' -> patternFacts moduleName pattern'

---------------------------------------------------------------------------------------------------
-- Patterns
---------------------------------------------------------------------------------------------------

patternFacts :: ModuleName -> Pattern Typed -> ModuleFacts
patternFacts moduleName = \case
  PatternVariable pattern' ->
    variableReferenceFacts moduleName pattern'.variableReference
      <> typedSpanFacts pattern'.sourceSpan pattern'.typeOf
      <> localTypeOfReference moduleName pattern'.variableReference pattern'.typeOf
      <> foldMap (typeExpressionFacts moduleName) pattern'.typeAnnotation
  PatternConstructor pattern' ->
    foldMap (moduleQualifierFacts moduleName) pattern'.moduleQualifier
      <> variableReferenceFacts moduleName pattern'.constructorReference
      <> foldMap (typeExpressionFacts moduleName) pattern'.genericArguments
      <> foldMap (fieldPatternFacts moduleName) pattern'.fields
      <> typedSpanFacts pattern'.sourceSpan pattern'.typeOf
  PatternTuple pattern' ->
    foldMap (patternFacts moduleName) pattern'.elements
      <> typedSpanFacts pattern'.sourceSpan pattern'.typeOf
  PatternWildcard pattern' ->
    foldMap (typeExpressionFacts moduleName) pattern'.typeAnnotation
      <> typedSpanFacts pattern'.sourceSpan pattern'.typeOf
  PatternLiteral pattern' -> typedSpanFacts pattern'.sourceSpan pattern'.typeOf
  PatternTypeFilter pattern' ->
    patternFacts moduleName pattern'.inner
      <> typedSpanFacts pattern'.sourceSpan pattern'.typeOf
  PatternRecord pattern' ->
    foldMap (fieldPatternFacts moduleName) pattern'.fields
      <> typedSpanFacts pattern'.sourceSpan pattern'.typeOf

fieldPatternFacts :: ModuleName -> FieldPattern Typed -> ModuleFacts
fieldPatternFacts moduleName field = patternFacts moduleName field.bindPattern

---------------------------------------------------------------------------------------------------
-- Type-level syntax
---------------------------------------------------------------------------------------------------

typeExpressionFacts :: ModuleName -> SyntacticTypeExpression Typed -> ModuleFacts
typeExpressionFacts moduleName = \case
  TypePrimitive _ -> mempty
  TypeStringLiteral _ -> mempty
  TypeNever _ -> mempty
  TypeUnknown _ -> mempty
  TypeAll _ -> mempty
  TypeIo _ -> mempty
  TypePure _ -> mempty
  TypeName node ->
    foldMap (moduleQualifierFacts moduleName) node.moduleQualifier
      <> typeReferenceFacts moduleName node.typeReference
  TypeAgent node ->
    typeExpressionFacts moduleName node.parameterType
      <> typeExpressionFacts moduleName node.returnType
      <> foldMap (typeExpressionFacts moduleName) node.effects
  TypeArray _ -> mempty
  TypeRecord _ -> mempty
  TypeApplication node ->
    typeExpressionFacts moduleName node.applicationHead
      <> foldMap (typeExpressionFacts moduleName) node.applicationArguments
  TypeTuple node -> foldMap (typeExpressionFacts moduleName) node.elementTypes
  TypeUnion node -> foldMap (typeExpressionFacts moduleName) node.branches
  TypeObject node -> foldMap (\field -> typeExpressionFacts moduleName field.fieldType) node.fields
  TypeAttributed node ->
    typeExpressionFacts moduleName node.baseType
      <> typeExpressionFacts moduleName node.attribute
  TypeAttributeLiteral _ -> mempty
  TypeOverride node ->
    typeExpressionFacts moduleName node.base
      <> foldMap (typeExpressionFacts moduleName) node.overrides

---------------------------------------------------------------------------------------------------
-- Statements and blocks
---------------------------------------------------------------------------------------------------

blockFacts :: ModuleName -> Block Typed -> ModuleFacts
blockFacts moduleName block =
  foldMap (statementFacts moduleName) block.statements
    <> foldMap (expressionFacts moduleName) block.returnExpression

statementFacts :: ModuleName -> Statement Typed -> ModuleFacts
statementFacts moduleName = \case
  StatementLet statement ->
    patternFacts moduleName statement.pattern
      <> expressionFacts moduleName statement.value
  StatementUse statement ->
    foldMap (patternFacts moduleName) statement.binder
      <> expressionFacts moduleName statement.provider
      <> blockFacts moduleName statement.body
  StatementAgent declaration -> agentDeclarationFacts moduleName declaration
  StatementReturn statement -> expressionFacts moduleName statement.value
  StatementExpression expression -> expressionFacts moduleName expression
  StatementNext statement ->
    expressionFacts moduleName statement.value
      <> foldMap (modifierFacts moduleName) statement.modifiers
  StatementBreak statement -> expressionFacts moduleName statement.value
  StatementForNext statement ->
    expressionFacts moduleName statement.value
      <> foldMap (modifierFacts moduleName) statement.modifiers
  StatementForBreak statement -> expressionFacts moduleName statement.value
  StatementFinally statement -> blockFacts moduleName statement.body
  StatementError _ -> mempty

modifierFacts :: ModuleName -> Modifier Typed -> ModuleFacts
modifierFacts moduleName modifier =
  variableReferenceFacts moduleName modifier.variableReference
    <> expressionFacts moduleName modifier.value

-- | A @var@ binding of a @for@ / @handler@. The variable's type is the initializer's (the annotation
-- may widen it, but the initializer type is always present and correct for display).
variableBindingFacts :: ModuleName -> VariableBinding Typed -> ModuleFacts
variableBindingFacts moduleName binding =
  variableReferenceFacts moduleName binding.variableReference
    <> foldMap (typeExpressionFacts moduleName) binding.typeAnnotation
    <> expressionFacts moduleName binding.initial
    <> typedSpanFacts binding.variableReference.sourceSpan (typeOfExpression binding.initial)
    <> localTypeOfReference moduleName binding.variableReference (typeOfExpression binding.initial)

thenClauseFacts :: ModuleName -> ThenClause Typed -> ModuleFacts
thenClauseFacts moduleName clause =
  foldMap (patternFacts moduleName) clause.binder
    <> blockFacts moduleName clause.body

---------------------------------------------------------------------------------------------------
-- Expressions
---------------------------------------------------------------------------------------------------

-- | A hole contributes no facts (it is a marker, not an expression); an expression payload recurses.
callArgumentFacts :: ModuleName -> CallArgument Typed -> ModuleFacts
callArgumentFacts moduleName argument = case argument.value of
  ArgumentHole _ -> mempty
  ArgumentExpression expression -> expressionFacts moduleName expression

expressionFacts :: ModuleName -> Expression Typed -> ModuleFacts
expressionFacts moduleName expression = case expression of
  ExpressionLiteral literal -> typedSpanFacts literal.sourceSpan literal.typeOf
  ExpressionVariable variable ->
    variableReferenceFacts moduleName variable.variableReference
      <> typedSpanFacts variable.sourceSpan variable.typeOf
  ExpressionTuple tuple ->
    foldMap (expressionFacts moduleName) tuple.elements
      <> typedSpanFacts tuple.sourceSpan tuple.typeOf
  ExpressionRecord record ->
    foldMap (\entry -> expressionFacts moduleName entry.value) record.entries
      <> typedSpanFacts record.sourceSpan record.typeOf
  ExpressionCall call ->
    expressionFacts moduleName call.callee
      <> foldMap (callArgumentFacts moduleName) call.arguments
      <> typedSpanFacts call.sourceSpan call.typeOf
  ExpressionBinaryOperator operator ->
    expressionFacts moduleName operator.left
      <> expressionFacts moduleName operator.right
      <> typedSpanFacts operator.sourceSpan operator.typeOf
  ExpressionUnaryOperator operator ->
    expressionFacts moduleName operator.operand
      <> typedSpanFacts operator.sourceSpan operator.typeOf
  ExpressionIf if' ->
    expressionFacts moduleName if'.condition
      <> blockFacts moduleName if'.thenBlock
      <> foldMap (blockFacts moduleName) if'.elseBlock
      <> typedSpanFacts if'.sourceSpan if'.typeOf
  ExpressionMatch match ->
    expressionFacts moduleName match.subject
      <> foldMap (caseArmFacts moduleName) match.cases
      <> typedSpanFacts match.sourceSpan match.typeOf
  ExpressionFor for ->
    patternFacts moduleName for.inBinding.pattern
      <> expressionFacts moduleName for.inBinding.source
      <> foldMap (variableBindingFacts moduleName) for.varBindings
      <> blockFacts moduleName for.body
      <> foldMap (thenClauseFacts moduleName) for.thenClause
      <> typedSpanFacts for.sourceSpan for.typeOf
  ExpressionForever forever' ->
    blockFacts moduleName forever'.body
      <> typedSpanFacts forever'.sourceSpan forever'.typeOf
  ExpressionBlock block ->
    blockFacts moduleName block.block
      <> typedSpanFacts block.sourceSpan block.typeOf
  ExpressionFieldAccess fieldAccess ->
    expressionFacts moduleName fieldAccess.object
      -- The field label itself gets the access's type, so hovering @.field@ shows the field type.
      <> typedSpanFacts fieldAccess.labelReference.sourceSpan fieldAccess.typeOf
      <> typedSpanFacts fieldAccess.sourceSpan fieldAccess.typeOf
  ExpressionTypeApplication application ->
    expressionFacts moduleName application.callee
      <> foldMap (typeExpressionFacts moduleName) application.typeArguments
      <> typedSpanFacts application.sourceSpan application.typeOf
  ExpressionTemplate template ->
    foldMap (templateElementFacts moduleName) template.elements
      <> typedSpanFacts template.sourceSpan template.typeOf
  ExpressionHandler handler -> handlerExpressionFacts moduleName handler
  ExpressionQualifiedReference qualified ->
    moduleQualifierFacts moduleName qualified.moduleQualifier
      <> variableReferenceFacts moduleName qualified.variableReference
      <> typedSpanFacts qualified.sourceSpan qualified.typeOf

caseArmFacts :: ModuleName -> CaseArm Typed -> ModuleFacts
caseArmFacts moduleName arm =
  patternFacts moduleName arm.pattern
    <> blockFacts moduleName arm.body

templateElementFacts :: ModuleName -> TemplateElement Typed -> ModuleFacts
templateElementFacts moduleName = \case
  TemplateElementString _ -> mempty
  TemplateElementExpression element -> expressionFacts moduleName element.value

handlerExpressionFacts :: ModuleName -> HandlerExpression Typed -> ModuleFacts
handlerExpressionFacts moduleName handler =
  foldMap (typeExpressionFacts moduleName) handler.genericArguments
    <> foldMap (variableBindingFacts moduleName) handler.stateVariables
    <> foldMap (requestHandlerFacts moduleName) handler.handlers
    <> foldMap (thenClauseFacts moduleName) handler.thenClause
    <> typedSpanFacts handler.sourceSpan handler.typeOf

requestHandlerFacts :: ModuleName -> RequestHandler Typed -> ModuleFacts
requestHandlerFacts moduleName handler =
  foldMap (moduleQualifierFacts moduleName) handler.moduleQualifier
    <> typeReferenceFacts moduleName handler.typeReference
    <> foldMap (typeExpressionFacts moduleName) handler.genericArguments
    -- The handled request's parameter types live in the request declaration (another module's
    -- environment), so plain-variable handler parameters carry no recovered binding type here.
    <> foldMap (parameterBindingFacts moduleName Map.empty) handler.parameters
    <> foldMap (typeExpressionFacts moduleName) handler.returnType
    <> blockFacts moduleName handler.body

---------------------------------------------------------------------------------------------------
-- Leaf fact builders
---------------------------------------------------------------------------------------------------

variableReferenceFacts :: ModuleName -> Reference Typed VariableReference -> ModuleFacts
variableReferenceFacts moduleName reference = case reference.resolution of
  Nothing -> mempty
  Just (VariableResolutionLocalVariable localVariableId) ->
    occurrenceFacts reference.sourceSpan (ResolvedReferenceLocal moduleName localVariableId)
  Just (VariableResolutionQualifiedName qualifiedName) ->
    occurrenceFacts reference.sourceSpan (ResolvedReferenceTopLevelVariable qualifiedName)

typeReferenceFacts :: ModuleName -> Reference Typed TypeReference -> ModuleFacts
typeReferenceFacts _ reference = case reference.resolution of
  Nothing -> mempty
  Just (TypeResolutionGeneric genericId) ->
    occurrenceFacts reference.sourceSpan (ResolvedReferenceGeneric genericId)
  Just (TypeResolutionQualifiedName qualifiedName) ->
    occurrenceFacts reference.sourceSpan (ResolvedReferenceTopLevelType qualifiedName)

moduleQualifierFacts :: ModuleName -> ModuleQualifier Typed -> ModuleFacts
moduleQualifierFacts _ qualifier = case qualifier.moduleReference.resolution of
  Nothing -> mempty
  Just referencedModule ->
    occurrenceFacts qualifier.moduleReference.sourceSpan (ResolvedReferenceModule referencedModule)

occurrenceFacts :: SourceSpan -> ResolvedReference -> ModuleFacts
occurrenceFacts sourceSpan target =
  mempty {occurrences = [Occurrence {sourceSpan = sourceSpan, target = target}]}

typedSpanFacts :: SourceSpan -> SemanticType -> ModuleFacts
typedSpanFacts sourceSpan semanticType =
  mempty {typedSpans = [TypedSpan {sourceSpan = sourceSpan, semanticType = semanticType}]}

-- | Record a local variable's binding type, when the reference resolved to a local.
localTypeOfReference :: ModuleName -> Reference Typed VariableReference -> SemanticType -> ModuleFacts
localTypeOfReference _ reference semanticType = case reference.resolution of
  Just (VariableResolutionLocalVariable localVariableId) ->
    mempty {localVariableTypes = Map.singleton localVariableId semanticType}
  _ -> mempty

---------------------------------------------------------------------------------------------------
-- Shared type-shape helpers (used by completion)
---------------------------------------------------------------------------------------------------

-- | The named field types of a type, seen through attribute wrappers. Objects yield their fields;
-- everything else (records are keyed dynamically) yields nothing.
objectFieldsOf :: SemanticType -> Map Text FieldInformation
objectFieldsOf semanticType = case stripAttributes semanticType of
  SemanticTypeObject fields -> fields
  _ -> Map.empty

-- | The binding type of a local variable, when its defining node recorded one.
localVariableTypeOf :: QuerySnapshot -> ModuleName -> LocalVariableId -> Maybe SemanticType
localVariableTypeOf snapshot moduleName localVariableId = do
  facts <- Map.lookup moduleName snapshot.moduleFacts
  Map.lookup localVariableId facts.localVariableTypes

-- | The declared type of a top-level value (agents carry one; requests / constructors do not).
topLevelValueTypeOf :: QuerySnapshot -> QualifiedName -> Maybe SemanticType
topLevelValueTypeOf snapshot qualifiedName = do
  declaration <- Map.lookup qualifiedName snapshot.valueDeclarations
  declaration.declaredType

-- | The type stamped on any typed expression node (every constructor carries one).
typeOfExpression :: Expression Typed -> SemanticType
typeOfExpression = \case
  ExpressionLiteral expression -> expression.typeOf
  ExpressionVariable expression -> expression.typeOf
  ExpressionTuple expression -> expression.typeOf
  ExpressionRecord expression -> expression.typeOf
  ExpressionCall expression -> expression.typeOf
  ExpressionBinaryOperator expression -> expression.typeOf
  ExpressionUnaryOperator expression -> expression.typeOf
  ExpressionIf expression -> expression.typeOf
  ExpressionMatch expression -> expression.typeOf
  ExpressionFor expression -> expression.typeOf
  ExpressionForever expression -> expression.typeOf
  ExpressionBlock expression -> expression.typeOf
  ExpressionFieldAccess expression -> expression.typeOf
  ExpressionTypeApplication expression -> expression.typeOf
  ExpressionTemplate expression -> expression.typeOf
  ExpressionHandler expression -> expression.typeOf
  ExpressionQualifiedReference expression -> expression.typeOf
