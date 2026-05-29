-- | Position-based query layer for LSP / CLI tooling.
--
-- Callers compile a source set via 'Katari.Compile.compile', then use the
-- returned 'ZonkResult' to answer editor queries without re-running the
-- compiler. All positions are code-point based (LSP layer converts UTF-16
-- offsets before calling here).
module Katari.Query
  ( -- * Snapshot (input for all queries)
    QuerySnapshot (..),

    -- * Type environment lookup
    lookupTopLevelType,
    lookupTypeInModule,

    -- * Hover
    HoverInfo (..),
    lookupAtPosition,

    -- * Occurrence index
    OccurrenceIndex (..),
    buildOccurrenceIndex,

    -- * Reference / definition queries
    ResolvedReference (..),
    identifyAtPosition,
    findReferences,
    findDefinition,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Katari.AST
  ( AgentDeclaration (..),
    AgentStatement (..),
    ArrayExpression (..),
    BinaryOperatorExpression (..),
    Block (..),
    BlockExpression (..),
    BreakStatement (..),
    CallArgument (..),
    CallExpression (..),
    CaseArm (..),
    DataDeclaration (..),
    Declaration (..),
    Expression (..),
    ExternalAgentDeclaration (..),
    FieldAccessExpression (..),
    ForBreakStatement (..),
    ForExpression (..),
    ForInBinding (..),
    ForNextStatement (..),
    ForVarBinding (..),
    HandleExpression (..),
    IfExpression (..),
    IndexAccessExpression (..),
    LetStatement (..),
    LiteralExpression (..),
    LiteralPattern (..),
    MatchExpression (..),
    Modifier (..),
    Module (..),
    NameRef (..),
    NameRefKind (..),
    NextStatement (..),
    ParArrayExpression (..),
    ParTupleExpression (..),
    ParameterBinding (..),
    Pattern (..),
    Phase (Zonked),
    QualifiedConstructorPattern (..),
    QualifiedReferenceExpression (..),
    RecordExpression (..),
    RecordPattern (..),
    RequestDeclaration (..),
    RequestHandler (..),
    ReturnStatement (..),
    StateVariableBinding (..),
    Statement (..),
    TemplateElement (..),
    TemplateExpression (..),
    TemplateExpressionElement (..),
    TupleExpression (..),
    TuplePattern (..),
    TypePattern (..),
    UnaryOperatorExpression (..),
    VariableExpression (..),
    VariablePattern (..),
    WildcardPattern (..),
  )
import Katari.Id
  ( QualifiedName (..),
    VariableResolution (..),
    renderQualifiedName,
  )
import Katari.SemanticType (Resolved, SemanticType)
import Katari.SourceSpan (HasSourceSpan (..), Position (..), SourceSpan (..), spanContains)
import Katari.Typechecker.Identifier
  ( ConstructorData (..),
    ModuleData,
    RequestData (..),
    SymbolEntry,
    TypeData (..),
    VariableData (..),
  )
import Katari.Typechecker.ScopeIndex (ScopeIndex)

-- ===========================================================================
-- Snapshot: bundled input for hover / completion / reference queries
-- ===========================================================================

-- | Cross-module data the query layer needs to answer a single
-- request. Each field is independently sourced from per-module compile
-- artifacts; the snapshot is built once and reused for the lifetime of
-- those artifacts (e.g. by the LSP between recompiles).
data QuerySnapshot = QuerySnapshot
  { variables :: Map QualifiedName VariableData,
    types :: Map QualifiedName TypeData,
    requests :: Map QualifiedName RequestData,
    constructors :: Map QualifiedName ConstructorData,
    modules :: Map Text ModuleData,
    scopeIndex :: ScopeIndex SymbolEntry,
    visibleSymbols :: Map Text (Map Text SymbolEntry),
    exports :: Map Text (Map Text SymbolEntry),
    zonkedModules :: Map Text (Module Zonked),
    typeEnv :: Map Text (Map VariableResolution (SemanticType Resolved))
  }

-- | Look up a top-level qualified name's resolved type.
lookupTopLevelType :: QualifiedName -> QuerySnapshot -> Maybe (SemanticType Resolved)
lookupTopLevelType qualifiedName snap =
  Map.lookup qualifiedName.module_ snap.typeEnv
    >>= Map.lookup (ResolvedTopLevel qualifiedName)

-- | Look up a 'VariableResolution' in the context of a specific module.
lookupTypeInModule :: Text -> VariableResolution -> QuerySnapshot -> Maybe (SemanticType Resolved)
lookupTypeInModule currentModule variableResolution snap =
  case variableResolution of
    ResolvedTopLevel qualifiedName -> lookupTopLevelType qualifiedName snap
    ResolvedLocal _ ->
      Map.lookup currentModule snap.typeEnv >>= Map.lookup variableResolution

-- ===========================================================================
-- Hover
-- ===========================================================================

-- | Information surfaced on hover over a source position.
data HoverInfo = HoverInfo
  { -- | Inferred type of the innermost expression at the position.
    hoverType :: Maybe (SemanticType Resolved),
    -- | The smallest span that contains the queried position.
    hoverNameSpan :: SourceSpan,
    -- | Source span of the definition this reference points to.
    hoverDefinitionSpan :: Maybe SourceSpan,
    -- | Fully qualified name of the symbol, if it is a top-level declaration.
    hoverQualifiedName :: Maybe Text
  }
  deriving (Show)

-- | Find hover information for the innermost typed node at a position.
-- Returns 'Nothing' if the position falls outside all known spans or no
-- typed node covers it.
--
-- @
-- let result = compile input
--     info   = lookupAtPosition
--                (identifierResult result) (zonkResult result)
--                "main.ktr" (Position {line = 0, column = 10})
-- -- info :: Maybe HoverInfo
-- -- Just (HoverInfo {hoverType = Just ..., hoverNameSpan = ..., ...})
-- @
lookupAtPosition :: QuerySnapshot -> FilePath -> Position -> Maybe HoverInfo
lookupAtPosition snap filePath position = do
  (moduleName, moduleData) <- findModuleByFilePath snap filePath
  listToMaybe (mapMaybe (hoverFromDeclaration snap moduleName position) moduleData.declarations)

-- ===========================================================================
-- Occurrence index
-- ===========================================================================

-- | Pre-built index of every name-reference occurrence in all modules.
-- Build once after compilation, then query cheaply with 'findReferences'.
data OccurrenceIndex = OccurrenceIndex
  { variableOccurrences :: Map VariableResolution [SourceSpan],
    typeOccurrences :: Map QualifiedName [SourceSpan],
    moduleOccurrences :: Map Text [SourceSpan],
    requestOccurrences :: Map QualifiedName [SourceSpan],
    constructorOccurrences :: Map QualifiedName [SourceSpan]
  }
  deriving (Show)

emptyOccurrenceIndex :: OccurrenceIndex
emptyOccurrenceIndex =
  OccurrenceIndex
    { variableOccurrences = Map.empty,
      typeOccurrences = Map.empty,
      moduleOccurrences = Map.empty,
      requestOccurrences = Map.empty,
      constructorOccurrences = Map.empty
    }

-- | Walk all modules in the snapshot and collect every name-reference
-- occurrence grouped by its resolved identifier.
buildOccurrenceIndex :: QuerySnapshot -> OccurrenceIndex
buildOccurrenceIndex snap =
  foldr collectModuleOccurrences emptyOccurrenceIndex (Map.elems snap.zonkedModules)

collectModuleOccurrences :: Module Zonked -> OccurrenceIndex -> OccurrenceIndex
collectModuleOccurrences moduleData index =
  foldr collectDeclarationOccurrences index moduleData.declarations

-- ===========================================================================
-- Reference / definition queries
-- ===========================================================================

-- | Which resolved identifier sits at a source position.
data ResolvedReference where
  ResolvedReferenceVariable :: VariableResolution -> ResolvedReference
  ResolvedReferenceType :: QualifiedName -> ResolvedReference
  ResolvedReferenceModule :: Text -> ResolvedReference
  ResolvedReferenceRequest :: QualifiedName -> ResolvedReference
  ResolvedReferenceConstructor :: QualifiedName -> ResolvedReference
  deriving (Eq, Show)

-- | Identify which resolved identifier (if any) sits at a source position.
identifyAtPosition :: QuerySnapshot -> FilePath -> Position -> Maybe ResolvedReference
identifyAtPosition snap filePath position = do
  (_, moduleData) <- findModuleByFilePath snap filePath
  listToMaybe (mapMaybe (refFromDeclaration position) moduleData.declarations)

-- | All occurrence spans of a resolved identifier (uses 'OccurrenceIndex').
findReferences :: OccurrenceIndex -> ResolvedReference -> [SourceSpan]
findReferences index = \case
  ResolvedReferenceVariable variableResolution ->
    Map.findWithDefault [] variableResolution index.variableOccurrences
  ResolvedReferenceType qualifiedName ->
    Map.findWithDefault [] qualifiedName index.typeOccurrences
  ResolvedReferenceModule moduleName ->
    Map.findWithDefault [] moduleName index.moduleOccurrences
  ResolvedReferenceRequest qualifiedName ->
    Map.findWithDefault [] qualifiedName index.requestOccurrences
  ResolvedReferenceConstructor qualifiedName ->
    Map.findWithDefault [] qualifiedName index.constructorOccurrences

-- | Definition span of the symbol at a position, if it can be resolved.
findDefinition :: QuerySnapshot -> FilePath -> Position -> Maybe SourceSpan
findDefinition snap filePath position = do
  resolvedRef <- identifyAtPosition snap filePath position
  case resolvedRef of
    ResolvedReferenceVariable variableResolution -> case variableResolution of
      ResolvedTopLevel qualifiedName ->
        fmap (.variableSourceSpan) (Map.lookup qualifiedName snap.variables)
      ResolvedLocal _ -> Nothing
    ResolvedReferenceType qualifiedName ->
      fmap (.typeSourceSpan) (Map.lookup qualifiedName snap.types)
    ResolvedReferenceModule _ -> Nothing
    ResolvedReferenceRequest qualifiedName ->
      fmap (.requestSourceSpan) (Map.lookup qualifiedName snap.requests)
    ResolvedReferenceConstructor qualifiedName ->
      fmap (.constructorSourceSpan) (Map.lookup qualifiedName snap.constructors)

-- ===========================================================================
-- Internal: module lookup
-- ===========================================================================

findModuleByFilePath :: QuerySnapshot -> FilePath -> Maybe (Text, Module Zonked)
findModuleByFilePath snap filePath =
  listToMaybe
    [ (moduleName, m)
      | (moduleName, m) <- Map.toList snap.zonkedModules,
        m.sourceSpan.filePath == filePath
    ]

-- ===========================================================================
-- Internal: hover extraction
-- ===========================================================================

hoverFromDeclaration :: QuerySnapshot -> Text -> Position -> Declaration Zonked -> Maybe HoverInfo
hoverFromDeclaration snap moduleName position = \case
  DeclarationAgent decl
    | spanContains decl.sourceSpan position ->
        hoverFromBlock snap moduleName position decl.body
          `orElse` listToMaybe
            (mapMaybe (hoverFromParameter snap moduleName position) decl.parameters)
          `orElse` ifPositionOnName decl.name (hoverFromVariableRef snap moduleName decl.name)
  DeclarationRequest decl
    | spanContains decl.sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromParameter snap moduleName position) decl.parameters)
          `orElse` ifPositionOnName decl.name (hoverFromVariableRef snap moduleName decl.name)
  DeclarationExternalAgent decl
    | spanContains decl.sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromParameter snap moduleName position) decl.parameters)
          `orElse` ifPositionOnName decl.name (hoverFromVariableRef snap moduleName decl.name)
  DeclarationData decl
    | spanContains decl.sourceSpan position ->
        ifPositionOnName decl.name (hoverFromVariableRef snap moduleName decl.name)
  _ -> Nothing
  where
    ifPositionOnName :: NameRef Zonked s -> Maybe a -> Maybe a
    ifPositionOnName nameRef value =
      if spanContains nameRef.sourceSpan position then value else Nothing

hoverFromParameter ::
  QuerySnapshot ->
  Text ->
  Position ->
  ParameterBinding Zonked ->
  Maybe HoverInfo
hoverFromParameter snap moduleName position param =
  if spanContains param.sourceSpan position
    then hoverFromPattern snap moduleName position param.pattern
    else Nothing

hoverFromPattern ::
  QuerySnapshot ->
  Text ->
  Position ->
  Pattern Zonked ->
  Maybe HoverInfo
hoverFromPattern snap moduleName position = \case
  PatternVariable vp
    | spanContains vp.name.sourceSpan position ->
        hoverFromVariableRef snap moduleName vp.name
  PatternTuple tp
    | spanContains tp.sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromPattern snap moduleName position) tp.elements)
  PatternQualifiedConstructor qp
    | spanContains qp.sourceSpan position ->
        listToMaybe
          (mapMaybe (hoverFromPattern snap moduleName position . snd) qp.parameters)
  PatternLiteral lp
    | spanContains lp.sourceSpan position ->
        Just
          HoverInfo
            { hoverType = Just lp.typeOf,
              hoverNameSpan = lp.sourceSpan,
              hoverDefinitionSpan = Nothing,
              hoverQualifiedName = Nothing
            }
  PatternWildcard wp
    | spanContains wp.sourceSpan position ->
        Just
          HoverInfo
            { hoverType = Just wp.typeOf,
              hoverNameSpan = wp.sourceSpan,
              hoverDefinitionSpan = Nothing,
              hoverQualifiedName = Nothing
            }
  PatternType tp
    | spanContains tp.sourceSpan position ->
        hoverFromPattern snap moduleName position tp.inner
  PatternRecord rp
    | spanContains rp.sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromPattern snap moduleName position . snd) rp.entries)
  _ -> Nothing

hoverFromVariableRef :: QuerySnapshot -> Text -> NameRef Zonked VariableRef -> Maybe HoverInfo
hoverFromVariableRef snap moduleName nameRef = do
  variableResolution <- nameRef.resolution
  let semanticType = lookupTypeInModule moduleName variableResolution snap
      (variableData, qualifiedName) = case variableResolution of
        ResolvedTopLevel qn -> (Map.lookup qn snap.variables, Just qn)
        ResolvedLocal _ -> (Nothing, Nothing)
  pure
    HoverInfo
      { hoverType = semanticType,
        hoverNameSpan = nameRef.sourceSpan,
        hoverDefinitionSpan = fmap (.variableSourceSpan) variableData,
        hoverQualifiedName = fmap renderQualifiedName qualifiedName
      }

hoverFromBlock :: QuerySnapshot -> Text -> Position -> Block Zonked -> Maybe HoverInfo
hoverFromBlock snap moduleName position block
  | spanContains block.sourceSpan position =
      listToMaybe (mapMaybe (hoverFromStatement snap moduleName position) block.statements)
        `orElse` (block.returnExpression >>= hoverFromExpression snap moduleName position)
  | otherwise = Nothing

hoverFromStatement :: QuerySnapshot -> Text -> Position -> Statement Zonked -> Maybe HoverInfo
hoverFromStatement snap moduleName position = \case
  StatementLet letStatement
    | spanContains letStatement.sourceSpan position ->
        hoverFromPattern snap moduleName position letStatement.pattern
          `orElse` hoverFromExpression snap moduleName position letStatement.value
  StatementExpression expression
    | spanContains (sourceSpanOf expression) position ->
        hoverFromExpression snap moduleName position expression
  StatementAgent agentStatement
    | spanContains agentStatement.sourceSpan position ->
        hoverFromBlock snap moduleName position agentStatement.body
  StatementReturn returnStatement
    | spanContains returnStatement.sourceSpan position ->
        hoverFromExpression snap moduleName position returnStatement.value
  StatementBreak breakStatement
    | spanContains breakStatement.sourceSpan position ->
        hoverFromExpression snap moduleName position breakStatement.value
  StatementNext nextStatement
    | spanContains nextStatement.sourceSpan position ->
        hoverFromExpression snap moduleName position nextStatement.value
          `orElse` listToMaybe (mapMaybe (hoverFromModifier snap moduleName position) nextStatement.modifiers)
  StatementForBreak ForBreakStatement {value, sourceSpan}
    | spanContains sourceSpan position ->
        hoverFromExpression snap moduleName position value
  StatementForNext ForNextStatement {modifiers, sourceSpan}
    | spanContains sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromModifier snap moduleName position) modifiers)
  _ -> Nothing

hoverFromModifier :: QuerySnapshot -> Text -> Position -> Modifier Zonked -> Maybe HoverInfo
hoverFromModifier snap moduleName position modifier
  | spanContains modifier.sourceSpan position =
      hoverFromExpression snap moduleName position modifier.value
        `orElse` if spanContains modifier.name.sourceSpan position
          then hoverFromVariableRef snap moduleName modifier.name
          else Nothing
  | otherwise = Nothing

hoverFromExpression :: QuerySnapshot -> Text -> Position -> Expression Zonked -> Maybe HoverInfo
hoverFromExpression snap moduleName position expression
  | not (spanContains (sourceSpanOf expression) position) = Nothing
  | otherwise = specific `orElse` Just (genericExpressionHover expression)
  where
    specific = case expression of
      ExpressionVariable ve ->
        let maybeResolution = ve.name.resolution
            semanticType = maybeResolution >>= \vr -> lookupTypeInModule moduleName vr snap
            (variableData, qualifiedName) = case maybeResolution of
              Just (ResolvedTopLevel qn) -> (Map.lookup qn snap.variables, Just qn)
              _ -> (Nothing, Nothing)
         in Just
              HoverInfo
                { hoverType = semanticType,
                  hoverNameSpan = ve.name.sourceSpan,
                  hoverDefinitionSpan = fmap (.variableSourceSpan) variableData,
                  hoverQualifiedName = fmap renderQualifiedName qualifiedName
                }
      ExpressionCall ce ->
        hoverFromExpression snap moduleName position ce.callee
          `orElse` listToMaybe (mapMaybe (hoverFromExpression snap moduleName position . (.value)) ce.arguments)
      ExpressionBinaryOperator be ->
        hoverFromExpression snap moduleName position be.left
          `orElse` hoverFromExpression snap moduleName position be.right
      ExpressionUnaryOperator ue ->
        hoverFromExpression snap moduleName position ue.operand
      ExpressionIf ie ->
        hoverFromExpression snap moduleName position ie.condition
          `orElse` hoverFromBlock snap moduleName position ie.thenBlock
          `orElse` (ie.elseBlock >>= hoverFromBlock snap moduleName position)
      ExpressionMatch me ->
        hoverFromExpression snap moduleName position me.subject
          `orElse` listToMaybe (mapMaybe (hoverFromCaseArm snap moduleName position) me.cases)
      ExpressionFor fe ->
        listToMaybe (mapMaybe (hoverFromExpression snap moduleName position . (.source)) fe.inBindings)
          `orElse` listToMaybe (mapMaybe (hoverFromForVarBinding snap moduleName position) fe.varBindings)
          `orElse` hoverFromBlock snap moduleName position fe.body
          `orElse` (fe.thenBlock >>= hoverFromBlock snap moduleName position)
      ExpressionBlock be ->
        hoverFromBlock snap moduleName position be.block
      ExpressionTuple te ->
        listToMaybe (mapMaybe (hoverFromExpression snap moduleName position) te.elements)
      ExpressionArray ae ->
        listToMaybe (mapMaybe (hoverFromExpression snap moduleName position) ae.elements)
      ExpressionParTuple pte ->
        listToMaybe (mapMaybe (hoverFromExpression snap moduleName position) pte.elements)
      ExpressionParArray pae ->
        listToMaybe (mapMaybe (hoverFromExpression snap moduleName position) pae.elements)
      ExpressionFieldAccess fae ->
        hoverFromExpression snap moduleName position fae.object
      ExpressionIndexAccess iae ->
        hoverFromExpression snap moduleName position iae.array
          `orElse` hoverFromExpression snap moduleName position iae.index
      ExpressionTemplate te ->
        listToMaybe (mapMaybe (hoverFromTemplateElement snap moduleName position) te.elements)
      ExpressionHandle he ->
        listToMaybe (mapMaybe (hoverFromStateVariable snap moduleName position) he.stateVariables)
          `orElse` listToMaybe (mapMaybe (hoverFromRequestHandler snap moduleName position) he.handlers)
          `orElse` (he.thenClause >>= hoverFromBlock snap moduleName position . snd)
          `orElse` hoverFromBlock snap moduleName position he.body
      ExpressionQualifiedReference qre ->
        hoverFromVariableRef snap moduleName qre.target
      ExpressionRecord re ->
        listToMaybe (mapMaybe (hoverFromExpression snap moduleName position . snd) re.entries)
      ExpressionLiteral _ -> Nothing

-- | Fall-back hover that just surfaces an expression's inferred type.
-- Used when no more-specific child hover matched. Carries no qualified
-- name or definition span — those make sense only for named symbols.
genericExpressionHover :: Expression Zonked -> HoverInfo
genericExpressionHover expr =
  HoverInfo
    { hoverType = Just (zonkedExpressionType expr),
      hoverNameSpan = sourceSpanOf expr,
      hoverDefinitionSpan = Nothing,
      hoverQualifiedName = Nothing
    }

-- | Extract the inferred @typeOf@ from a zonked 'Expression'. Every
-- variant carries it as a record field; this just dispatches on the
-- constructor.
zonkedExpressionType :: Expression Zonked -> SemanticType Resolved
zonkedExpressionType = \case
  ExpressionLiteral e -> e.typeOf
  ExpressionVariable e -> e.typeOf
  ExpressionTuple e -> e.typeOf
  ExpressionArray e -> e.typeOf
  ExpressionRecord e -> e.typeOf
  ExpressionCall e -> e.typeOf
  ExpressionBinaryOperator e -> e.typeOf
  ExpressionUnaryOperator e -> e.typeOf
  ExpressionIf e -> e.typeOf
  ExpressionMatch e -> e.typeOf
  ExpressionFor e -> e.typeOf
  ExpressionBlock e -> e.typeOf
  ExpressionFieldAccess e -> e.typeOf
  ExpressionIndexAccess e -> e.typeOf
  ExpressionTemplate e -> e.typeOf
  ExpressionHandle e -> e.typeOf
  ExpressionParTuple e -> e.typeOf
  ExpressionParArray e -> e.typeOf
  ExpressionQualifiedReference e -> e.typeOf

-- | Walk a match-case arm: try the pattern bindings first (so hover on
-- a bound name shows that name's inferred type), then the body block.
hoverFromCaseArm ::
  QuerySnapshot ->
  Text ->
  Position ->
  CaseArm Zonked ->
  Maybe HoverInfo
hoverFromCaseArm snap moduleName position arm
  | spanContains arm.sourceSpan position =
      hoverFromPattern snap moduleName position arm.pattern
        `orElse` hoverFromBlock snap moduleName position arm.body
  | otherwise = Nothing

hoverFromForVarBinding :: QuerySnapshot -> Text -> Position -> ForVarBinding Zonked -> Maybe HoverInfo
hoverFromForVarBinding snap moduleName position binding
  | spanContains binding.sourceSpan position =
      hoverFromExpression snap moduleName position binding.initial
        `orElse` if spanContains binding.name.sourceSpan position
          then hoverFromVariableRef snap moduleName binding.name
          else Nothing
  | otherwise = Nothing

hoverFromStateVariable :: QuerySnapshot -> Text -> Position -> StateVariableBinding Zonked -> Maybe HoverInfo
hoverFromStateVariable snap moduleName position binding
  | spanContains binding.sourceSpan position =
      hoverFromExpression snap moduleName position binding.initial
        `orElse` if spanContains binding.name.sourceSpan position
          then hoverFromVariableRef snap moduleName binding.name
          else Nothing
  | otherwise = Nothing

hoverFromRequestHandler :: QuerySnapshot -> Text -> Position -> RequestHandler Zonked -> Maybe HoverInfo
hoverFromRequestHandler snap moduleName position handler
  | spanContains handler.sourceSpan position =
      listToMaybe (mapMaybe (hoverFromParameter snap moduleName position) handler.parameters)
        `orElse` hoverFromBlock snap moduleName position handler.body
        `orElse` hoverFromRequestNameRef snap position handler.name
  | otherwise = Nothing

hoverFromRequestNameRef ::
  QuerySnapshot ->
  Position ->
  NameRef Zonked RequestRef ->
  Maybe HoverInfo
hoverFromRequestNameRef snap position nameRef
  | not (spanContains nameRef.sourceSpan position) = Nothing
  | otherwise = do
      qualifiedName <- nameRef.resolution
      requestData <- Map.lookup qualifiedName snap.requests
      let semanticType = lookupTopLevelType qualifiedName snap
      pure
        HoverInfo
          { hoverType = semanticType,
            hoverNameSpan = nameRef.sourceSpan,
            hoverDefinitionSpan = Just requestData.requestSourceSpan,
            hoverQualifiedName = Just (renderQualifiedName qualifiedName)
          }

hoverFromTemplateElement :: QuerySnapshot -> Text -> Position -> TemplateElement Zonked -> Maybe HoverInfo
hoverFromTemplateElement snap moduleName position = \case
  TemplateElementString _ -> Nothing
  TemplateElementExpression element
    | spanContains element.sourceSpan position ->
        hoverFromExpression snap moduleName position element.value
    | otherwise -> Nothing

-- ===========================================================================
-- Internal: reference extraction
-- ===========================================================================

refFromDeclaration :: Position -> Declaration Zonked -> Maybe ResolvedReference
refFromDeclaration position = \case
  DeclarationAgent decl
    | spanContains decl.sourceSpan position ->
        refFromBlock position decl.body
          `orElse` refFromVariableNameRef position decl.name
  DeclarationRequest decl
    | spanContains decl.sourceSpan position ->
        refFromVariableNameRef position decl.name
  DeclarationExternalAgent decl
    | spanContains decl.sourceSpan position ->
        refFromVariableNameRef position decl.name
  DeclarationData decl
    | spanContains decl.sourceSpan position ->
        refFromVariableNameRef position decl.name
  _ -> Nothing

refFromVariableNameRef :: Position -> NameRef Zonked VariableRef -> Maybe ResolvedReference
refFromVariableNameRef position nameRef
  | spanContains nameRef.sourceSpan position =
      fmap ResolvedReferenceVariable nameRef.resolution
  | otherwise = Nothing

refFromBlock :: Position -> Block Zonked -> Maybe ResolvedReference
refFromBlock position block
  | spanContains block.sourceSpan position =
      listToMaybe (mapMaybe (refFromStatement position) block.statements)
        `orElse` (block.returnExpression >>= refFromExpression position)
  | otherwise = Nothing

refFromStatement :: Position -> Statement Zonked -> Maybe ResolvedReference
refFromStatement position = \case
  StatementLet letStatement
    | spanContains letStatement.sourceSpan position ->
        refFromExpression position letStatement.value
  StatementExpression expression
    | spanContains (sourceSpanOf expression) position ->
        refFromExpression position expression
  StatementAgent agentStatement
    | spanContains agentStatement.sourceSpan position ->
        refFromBlock position agentStatement.body
  StatementReturn returnStatement
    | spanContains returnStatement.sourceSpan position ->
        refFromExpression position returnStatement.value
  StatementBreak breakStatement
    | spanContains breakStatement.sourceSpan position ->
        refFromExpression position breakStatement.value
  StatementNext nextStatement
    | spanContains nextStatement.sourceSpan position ->
        refFromExpression position nextStatement.value
          `orElse` listToMaybe (mapMaybe (refFromModifier position) nextStatement.modifiers)
  StatementForBreak ForBreakStatement {value, sourceSpan}
    | spanContains sourceSpan position ->
        refFromExpression position value
  StatementForNext ForNextStatement {modifiers, sourceSpan}
    | spanContains sourceSpan position ->
        listToMaybe (mapMaybe (refFromModifier position) modifiers)
  _ -> Nothing

refFromModifier :: Position -> Modifier Zonked -> Maybe ResolvedReference
refFromModifier position modifier
  | spanContains modifier.sourceSpan position =
      refFromExpression position modifier.value
        `orElse` refFromVariableNameRef position modifier.name
  | otherwise = Nothing

refFromExpression :: Position -> Expression Zonked -> Maybe ResolvedReference
refFromExpression position expression
  | not (spanContains (sourceSpanOf expression) position) = Nothing
  | otherwise = case expression of
      ExpressionVariable ve
        | spanContains ve.name.sourceSpan position ->
            fmap ResolvedReferenceVariable ve.name.resolution
      ExpressionCall ce ->
        refFromExpression position ce.callee
          `orElse` listToMaybe (mapMaybe (refFromExpression position . (.value)) ce.arguments)
      ExpressionBinaryOperator be ->
        refFromExpression position be.left
          `orElse` refFromExpression position be.right
      ExpressionUnaryOperator ue ->
        refFromExpression position ue.operand
      ExpressionIf ie ->
        refFromExpression position ie.condition
          `orElse` refFromBlock position ie.thenBlock
          `orElse` (ie.elseBlock >>= refFromBlock position)
      ExpressionMatch me ->
        refFromExpression position me.subject
          `orElse` listToMaybe (mapMaybe (refFromBlock position . (.body)) me.cases)
      ExpressionFor fe ->
        listToMaybe (mapMaybe (refFromExpression position . (.source)) fe.inBindings)
          `orElse` listToMaybe (mapMaybe (refFromForVarBinding position) fe.varBindings)
          `orElse` refFromBlock position fe.body
          `orElse` (fe.thenBlock >>= refFromBlock position)
      ExpressionBlock be ->
        refFromBlock position be.block
      ExpressionTuple te ->
        listToMaybe (mapMaybe (refFromExpression position) te.elements)
      ExpressionArray ae ->
        listToMaybe (mapMaybe (refFromExpression position) ae.elements)
      ExpressionParTuple pte ->
        listToMaybe (mapMaybe (refFromExpression position) pte.elements)
      ExpressionParArray pae ->
        listToMaybe (mapMaybe (refFromExpression position) pae.elements)
      ExpressionFieldAccess fae ->
        refFromExpression position fae.object
      ExpressionIndexAccess iae ->
        refFromExpression position iae.array
          `orElse` refFromExpression position iae.index
      ExpressionTemplate te ->
        listToMaybe (mapMaybe (refFromTemplateElement position) te.elements)
      ExpressionHandle he ->
        listToMaybe (mapMaybe (refFromStateVariable position) he.stateVariables)
          `orElse` listToMaybe (mapMaybe (refFromRequestHandler position) he.handlers)
          `orElse` (he.thenClause >>= refFromBlock position . snd)
          `orElse` refFromBlock position he.body
      ExpressionQualifiedReference qre
        | spanContains qre.target.sourceSpan position ->
            fmap ResolvedReferenceVariable qre.target.resolution
        | spanContains qre.moduleQualifier.sourceSpan position ->
            fmap ResolvedReferenceModule qre.moduleQualifier.resolution
      _ -> Nothing

refFromForVarBinding :: Position -> ForVarBinding Zonked -> Maybe ResolvedReference
refFromForVarBinding position binding
  | spanContains binding.sourceSpan position =
      refFromExpression position binding.initial
        `orElse` refFromVariableNameRef position binding.name
  | otherwise = Nothing

refFromStateVariable :: Position -> StateVariableBinding Zonked -> Maybe ResolvedReference
refFromStateVariable position binding
  | spanContains binding.sourceSpan position =
      refFromExpression position binding.initial
        `orElse` refFromVariableNameRef position binding.name
  | otherwise = Nothing

refFromRequestHandler :: Position -> RequestHandler Zonked -> Maybe ResolvedReference
refFromRequestHandler position handler
  | spanContains handler.sourceSpan position =
      refFromBlock position handler.body
  | otherwise = Nothing

refFromTemplateElement :: Position -> TemplateElement Zonked -> Maybe ResolvedReference
refFromTemplateElement position = \case
  TemplateElementString _ -> Nothing
  TemplateElementExpression element
    | spanContains element.sourceSpan position ->
        refFromExpression position element.value
    | otherwise -> Nothing

-- ===========================================================================
-- Internal: occurrence collection
-- ===========================================================================

collectDeclarationOccurrences :: Declaration Zonked -> OccurrenceIndex -> OccurrenceIndex
collectDeclarationOccurrences declaration index = case declaration of
  DeclarationAgent decl ->
    collectBlockOccurrences decl.body (addVariableOccurrence decl.name index)
  DeclarationRequest decl ->
    addVariableOccurrence decl.name index
  DeclarationExternalAgent decl ->
    addVariableOccurrence decl.name index
  DeclarationData decl ->
    addVariableOccurrence decl.name index
  _ -> index

collectBlockOccurrences :: Block Zonked -> OccurrenceIndex -> OccurrenceIndex
collectBlockOccurrences block index =
  let withStatements = foldr collectStatementOccurrences index block.statements
   in maybe withStatements (`collectExpressionOccurrences` withStatements) block.returnExpression

collectStatementOccurrences :: Statement Zonked -> OccurrenceIndex -> OccurrenceIndex
collectStatementOccurrences statement index = case statement of
  StatementLet letStatement ->
    collectExpressionOccurrences letStatement.value index
  StatementExpression expression ->
    collectExpressionOccurrences expression index
  StatementAgent agentStatement ->
    collectBlockOccurrences agentStatement.body index
  StatementReturn returnStatement ->
    collectExpressionOccurrences returnStatement.value index
  StatementBreak breakStatement ->
    collectExpressionOccurrences breakStatement.value index
  StatementNext nextStatement ->
    foldr collectModifierOccurrences (collectExpressionOccurrences nextStatement.value index) nextStatement.modifiers
  StatementForBreak ForBreakStatement {value} ->
    collectExpressionOccurrences value index
  StatementForNext ForNextStatement {modifiers} ->
    foldr collectModifierOccurrences index modifiers
  _ -> index

collectModifierOccurrences :: Modifier Zonked -> OccurrenceIndex -> OccurrenceIndex
collectModifierOccurrences modifier index =
  collectExpressionOccurrences modifier.value (addVariableOccurrence modifier.name index)

collectExpressionOccurrences :: Expression Zonked -> OccurrenceIndex -> OccurrenceIndex
collectExpressionOccurrences expression index = case expression of
  ExpressionVariable ve ->
    addVariableOccurrence ve.name index
  ExpressionCall ce ->
    foldr
      (collectExpressionOccurrences . (.value))
      (collectExpressionOccurrences ce.callee index)
      ce.arguments
  ExpressionBinaryOperator be ->
    collectExpressionOccurrences be.left (collectExpressionOccurrences be.right index)
  ExpressionUnaryOperator ue ->
    collectExpressionOccurrences ue.operand index
  ExpressionIf ie ->
    collectExpressionOccurrences
      ie.condition
      ( collectBlockOccurrences
          ie.thenBlock
          (maybe index (`collectBlockOccurrences` index) ie.elseBlock)
      )
  ExpressionMatch me ->
    collectExpressionOccurrences
      me.subject
      (foldr (\caseArm -> collectBlockOccurrences caseArm.body) index me.cases)
  ExpressionFor fe ->
    let withInBindings = foldr (collectExpressionOccurrences . (.source)) index fe.inBindings
        withVarBindings = foldr collectForVarBindingOccurrences withInBindings fe.varBindings
        withBody = collectBlockOccurrences fe.body withVarBindings
     in maybe withBody (`collectBlockOccurrences` withBody) fe.thenBlock
  ExpressionBlock be ->
    collectBlockOccurrences be.block index
  ExpressionTuple te ->
    foldr collectExpressionOccurrences index te.elements
  ExpressionArray ae ->
    foldr collectExpressionOccurrences index ae.elements
  ExpressionParTuple pte ->
    foldr collectExpressionOccurrences index pte.elements
  ExpressionParArray pae ->
    foldr collectExpressionOccurrences index pae.elements
  ExpressionFieldAccess fae ->
    collectExpressionOccurrences fae.object index
  ExpressionIndexAccess iae ->
    collectExpressionOccurrences iae.array (collectExpressionOccurrences iae.index index)
  ExpressionTemplate te ->
    foldr collectTemplateElementOccurrences index te.elements
  ExpressionHandle he ->
    let withState = foldr collectStateVariableOccurrences index he.stateVariables
        withHandlers = foldr (\handler -> collectBlockOccurrences handler.body) withState he.handlers
        withThen = maybe withHandlers (\(_, thenBlock) -> collectBlockOccurrences thenBlock withHandlers) he.thenClause
     in collectBlockOccurrences he.body withThen
  ExpressionQualifiedReference qre ->
    addModuleOccurrence qre.moduleQualifier (addVariableOccurrence qre.target index)
  _ -> index

collectForVarBindingOccurrences :: ForVarBinding Zonked -> OccurrenceIndex -> OccurrenceIndex
collectForVarBindingOccurrences binding index =
  collectExpressionOccurrences binding.initial (addVariableOccurrence binding.name index)

collectStateVariableOccurrences :: StateVariableBinding Zonked -> OccurrenceIndex -> OccurrenceIndex
collectStateVariableOccurrences binding index =
  collectExpressionOccurrences binding.initial (addVariableOccurrence binding.name index)

collectTemplateElementOccurrences :: TemplateElement Zonked -> OccurrenceIndex -> OccurrenceIndex
collectTemplateElementOccurrences = \case
  TemplateElementString _ -> id
  TemplateElementExpression element -> collectExpressionOccurrences element.value

addModuleOccurrence :: NameRef Zonked ModuleRef -> OccurrenceIndex -> OccurrenceIndex
addModuleOccurrence nameRef index = case nameRef.resolution of
  Nothing -> index
  Just moduleName ->
    index
      { moduleOccurrences =
          Map.insertWith (<>) moduleName [nameRef.sourceSpan] index.moduleOccurrences
      }

addVariableOccurrence :: NameRef Zonked VariableRef -> OccurrenceIndex -> OccurrenceIndex
addVariableOccurrence nameRef index = case nameRef.resolution of
  Nothing -> index
  Just variableResolution ->
    index
      { variableOccurrences =
          Map.insertWith (<>) variableResolution [nameRef.sourceSpan] index.variableOccurrences
      }

-- ===========================================================================
-- Internal: span helpers
-- ===========================================================================

orElse :: Maybe a -> Maybe a -> Maybe a
orElse Nothing b = b
orElse a _ = a
