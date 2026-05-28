-- | Position-based query layer for LSP / CLI tooling.
--
-- Callers compile a source set via 'Katari.Compile.compile', then use the
-- returned 'ZonkResult' to answer editor queries without re-running the
-- compiler. All positions are code-point based (LSP layer converts UTF-16
-- offsets before calling here).
module Katari.Query
  ( -- * Snapshot (input for all queries)
    QuerySnapshot (..),
    buildQuerySnapshot,

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
  ( QualifiedName,
    VariableResolution (..),
    renderQualifiedName,
  )
import Katari.SemanticType (Resolved, SemanticType)
import Katari.SourceSpan (HasSourceSpan (..), Position (..), SourceSpan (..), spanContains)
import Katari.Typechecker.Identifier
  ( ConstructorData (..),
    IdentifierResult (..),
    RequestData (..),
    TypeData (..),
    VariableData (..),
  )
import Katari.Typechecker.Zonker (ZonkResult (..), lookupTopLevelType, lookupTypeInModule)

-- ===========================================================================
-- Snapshot: bundled input for hover / completion / reference queries
-- ===========================================================================

-- | Cross-module data the query layer needs to answer a single
-- request. Constructed by the orchestrator from per-module compile
-- artifacts and held by the LSP / CLI tooling for as long as those
-- artifacts are valid.
data QuerySnapshot = QuerySnapshot
  { identifierResult :: IdentifierResult,
    zonkResult :: ZonkResult
  }

-- | Build a 'QuerySnapshot' from a compile's identifier and zonk
-- outputs.
buildQuerySnapshot :: IdentifierResult -> ZonkResult -> QuerySnapshot
buildQuerySnapshot idr zr = QuerySnapshot {identifierResult = idr, zonkResult = zr}

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
  let idResult = snap.identifierResult
      zonkResult = snap.zonkResult
  (moduleName, moduleData) <- findModuleByFilePath idResult zonkResult filePath
  listToMaybe (mapMaybe (hoverFromDeclaration idResult zonkResult moduleName position) moduleData.declarations)

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
  foldr
    (collectModuleOccurrences snap.identifierResult)
    emptyOccurrenceIndex
    (Map.elems snap.zonkResult.zonkedModules)

collectModuleOccurrences :: IdentifierResult -> Module Zonked -> OccurrenceIndex -> OccurrenceIndex
collectModuleOccurrences idResult moduleData index =
  foldr (collectDeclarationOccurrences idResult) index moduleData.declarations

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
  (_, moduleData) <- findModuleByFilePath snap.identifierResult snap.zonkResult filePath
  listToMaybe (mapMaybe (refFromDeclaration snap.identifierResult position) moduleData.declarations)

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
  let idResult = snap.identifierResult
  resolvedRef <- identifyAtPosition snap filePath position
  case resolvedRef of
    ResolvedReferenceVariable variableResolution -> case variableResolution of
      ResolvedTopLevel qualifiedName ->
        fmap (.variableSourceSpan) (Map.lookup qualifiedName idResult.identifiedVariables)
      ResolvedLocal _ -> Nothing
    ResolvedReferenceType qualifiedName ->
      fmap (.typeSourceSpan) (Map.lookup qualifiedName idResult.identifiedTypes)
    ResolvedReferenceModule _ -> Nothing
    ResolvedReferenceRequest qualifiedName ->
      fmap (.requestSourceSpan) (Map.lookup qualifiedName idResult.identifiedRequests)
    ResolvedReferenceConstructor qualifiedName ->
      fmap (.constructorSourceSpan) (Map.lookup qualifiedName idResult.identifiedConstructors)

-- ===========================================================================
-- Internal: module lookup
-- ===========================================================================

findModuleByFilePath :: IdentifierResult -> ZonkResult -> FilePath -> Maybe (Text, Module Zonked)
findModuleByFilePath _ zonkResult filePath =
  listToMaybe
    [ (moduleName, m)
      | (moduleName, m) <- Map.toList zonkResult.zonkedModules,
        m.sourceSpan.filePath == filePath
    ]

-- ===========================================================================
-- Internal: hover extraction
-- ===========================================================================

hoverFromDeclaration :: IdentifierResult -> ZonkResult -> Text -> Position -> Declaration Zonked -> Maybe HoverInfo
hoverFromDeclaration idResult zonkResult moduleName position = \case
  DeclarationAgent decl
    | spanContains decl.sourceSpan position ->
        hoverFromBlock idResult zonkResult moduleName position decl.body
          `orElse` listToMaybe
            (mapMaybe (hoverFromParameter idResult zonkResult moduleName position) decl.parameters)
          `orElse` ifPositionOnName decl.name (hoverFromVariableRef idResult zonkResult moduleName decl.name)
  DeclarationRequest decl
    | spanContains decl.sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromParameter idResult zonkResult moduleName position) decl.parameters)
          `orElse` ifPositionOnName decl.name (hoverFromVariableRef idResult zonkResult moduleName decl.name)
  DeclarationExternalAgent decl
    | spanContains decl.sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromParameter idResult zonkResult moduleName position) decl.parameters)
          `orElse` ifPositionOnName decl.name (hoverFromVariableRef idResult zonkResult moduleName decl.name)
  DeclarationData decl
    | spanContains decl.sourceSpan position ->
        ifPositionOnName decl.name (hoverFromVariableRef idResult zonkResult moduleName decl.name)
  _ -> Nothing
  where
    ifPositionOnName :: NameRef Zonked s -> Maybe a -> Maybe a
    ifPositionOnName nameRef value =
      if spanContains nameRef.sourceSpan position then value else Nothing

hoverFromParameter ::
  IdentifierResult ->
  ZonkResult ->
  Text ->
  Position ->
  ParameterBinding Zonked ->
  Maybe HoverInfo
hoverFromParameter idResult zonkResult moduleName position param =
  if spanContains param.sourceSpan position
    then hoverFromPattern idResult zonkResult moduleName position param.pattern
    else Nothing

hoverFromPattern ::
  IdentifierResult ->
  ZonkResult ->
  Text ->
  Position ->
  Pattern Zonked ->
  Maybe HoverInfo
hoverFromPattern idResult zonkResult moduleName position = \case
  PatternVariable vp
    | spanContains vp.name.sourceSpan position ->
        hoverFromVariableRef idResult zonkResult moduleName vp.name
  PatternTuple tp
    | spanContains tp.sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromPattern idResult zonkResult moduleName position) tp.elements)
  PatternQualifiedConstructor qp
    | spanContains qp.sourceSpan position ->
        listToMaybe
          (mapMaybe (hoverFromPattern idResult zonkResult moduleName position . snd) qp.parameters)
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
        hoverFromPattern idResult zonkResult moduleName position tp.inner
  PatternRecord rp
    | spanContains rp.sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromPattern idResult zonkResult moduleName position . snd) rp.entries)
  _ -> Nothing

hoverFromVariableRef :: IdentifierResult -> ZonkResult -> Text -> NameRef Zonked VariableRef -> Maybe HoverInfo
hoverFromVariableRef idResult zonkResult moduleName nameRef = do
  variableResolution <- nameRef.resolution
  let semanticType = lookupTypeInModule moduleName variableResolution zonkResult
      (variableData, qualifiedName) = case variableResolution of
        ResolvedTopLevel qn -> (Map.lookup qn idResult.identifiedVariables, Just qn)
        ResolvedLocal _ -> (Nothing, Nothing)
  pure
    HoverInfo
      { hoverType = semanticType,
        hoverNameSpan = nameRef.sourceSpan,
        hoverDefinitionSpan = fmap (.variableSourceSpan) variableData,
        hoverQualifiedName = fmap renderQualifiedName qualifiedName
      }

hoverFromBlock :: IdentifierResult -> ZonkResult -> Text -> Position -> Block Zonked -> Maybe HoverInfo
hoverFromBlock idResult zonkResult moduleName position block
  | spanContains block.sourceSpan position =
      listToMaybe (mapMaybe (hoverFromStatement idResult zonkResult moduleName position) block.statements)
        `orElse` (block.returnExpression >>= hoverFromExpression idResult zonkResult moduleName position)
  | otherwise = Nothing

hoverFromStatement :: IdentifierResult -> ZonkResult -> Text -> Position -> Statement Zonked -> Maybe HoverInfo
hoverFromStatement idResult zonkResult moduleName position = \case
  StatementLet letStatement
    | spanContains letStatement.sourceSpan position ->
        hoverFromPattern idResult zonkResult moduleName position letStatement.pattern
          `orElse` hoverFromExpression idResult zonkResult moduleName position letStatement.value
  StatementExpression expression
    | spanContains (sourceSpanOf expression) position ->
        hoverFromExpression idResult zonkResult moduleName position expression
  StatementAgent agentStatement
    | spanContains agentStatement.sourceSpan position ->
        hoverFromBlock idResult zonkResult moduleName position agentStatement.body
  StatementReturn returnStatement
    | spanContains returnStatement.sourceSpan position ->
        hoverFromExpression idResult zonkResult moduleName position returnStatement.value
  StatementBreak breakStatement
    | spanContains breakStatement.sourceSpan position ->
        hoverFromExpression idResult zonkResult moduleName position breakStatement.value
  StatementNext nextStatement
    | spanContains nextStatement.sourceSpan position ->
        hoverFromExpression idResult zonkResult moduleName position nextStatement.value
          `orElse` listToMaybe (mapMaybe (hoverFromModifier idResult zonkResult moduleName position) nextStatement.modifiers)
  StatementForBreak ForBreakStatement {value, sourceSpan}
    | spanContains sourceSpan position ->
        hoverFromExpression idResult zonkResult moduleName position value
  StatementForNext ForNextStatement {modifiers, sourceSpan}
    | spanContains sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromModifier idResult zonkResult moduleName position) modifiers)
  _ -> Nothing

hoverFromModifier :: IdentifierResult -> ZonkResult -> Text -> Position -> Modifier Zonked -> Maybe HoverInfo
hoverFromModifier idResult zonkResult moduleName position modifier
  | spanContains modifier.sourceSpan position =
      hoverFromExpression idResult zonkResult moduleName position modifier.value
        `orElse` if spanContains modifier.name.sourceSpan position
          then hoverFromVariableRef idResult zonkResult moduleName modifier.name
          else Nothing
  | otherwise = Nothing

hoverFromExpression :: IdentifierResult -> ZonkResult -> Text -> Position -> Expression Zonked -> Maybe HoverInfo
hoverFromExpression idResult zonkResult moduleName position expression
  | not (spanContains (sourceSpanOf expression) position) = Nothing
  | otherwise = specific `orElse` Just (genericExpressionHover expression)
  where
    specific = case expression of
      ExpressionVariable ve ->
        let maybeResolution = ve.name.resolution
            semanticType = maybeResolution >>= \vr -> lookupTypeInModule moduleName vr zonkResult
            (variableData, qualifiedName) = case maybeResolution of
              Just (ResolvedTopLevel qn) -> (Map.lookup qn idResult.identifiedVariables, Just qn)
              _ -> (Nothing, Nothing)
         in Just
              HoverInfo
                { hoverType = semanticType,
                  hoverNameSpan = ve.name.sourceSpan,
                  hoverDefinitionSpan = fmap (.variableSourceSpan) variableData,
                  hoverQualifiedName = fmap renderQualifiedName qualifiedName
                }
      ExpressionCall ce ->
        hoverFromExpression idResult zonkResult moduleName position ce.callee
          `orElse` listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult moduleName position . (.value)) ce.arguments)
      ExpressionBinaryOperator be ->
        hoverFromExpression idResult zonkResult moduleName position be.left
          `orElse` hoverFromExpression idResult zonkResult moduleName position be.right
      ExpressionUnaryOperator ue ->
        hoverFromExpression idResult zonkResult moduleName position ue.operand
      ExpressionIf ie ->
        hoverFromExpression idResult zonkResult moduleName position ie.condition
          `orElse` hoverFromBlock idResult zonkResult moduleName position ie.thenBlock
          `orElse` (ie.elseBlock >>= hoverFromBlock idResult zonkResult moduleName position)
      ExpressionMatch me ->
        hoverFromExpression idResult zonkResult moduleName position me.subject
          `orElse` listToMaybe (mapMaybe (hoverFromCaseArm idResult zonkResult moduleName position) me.cases)
      ExpressionFor fe ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult moduleName position . (.source)) fe.inBindings)
          `orElse` listToMaybe (mapMaybe (hoverFromForVarBinding idResult zonkResult moduleName position) fe.varBindings)
          `orElse` hoverFromBlock idResult zonkResult moduleName position fe.body
          `orElse` (fe.thenBlock >>= hoverFromBlock idResult zonkResult moduleName position)
      ExpressionBlock be ->
        hoverFromBlock idResult zonkResult moduleName position be.block
      ExpressionTuple te ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult moduleName position) te.elements)
      ExpressionArray ae ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult moduleName position) ae.elements)
      ExpressionParTuple pte ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult moduleName position) pte.elements)
      ExpressionParArray pae ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult moduleName position) pae.elements)
      ExpressionFieldAccess fae ->
        hoverFromExpression idResult zonkResult moduleName position fae.object
      ExpressionIndexAccess iae ->
        hoverFromExpression idResult zonkResult moduleName position iae.array
          `orElse` hoverFromExpression idResult zonkResult moduleName position iae.index
      ExpressionTemplate te ->
        listToMaybe (mapMaybe (hoverFromTemplateElement idResult zonkResult moduleName position) te.elements)
      ExpressionHandle he ->
        listToMaybe (mapMaybe (hoverFromStateVariable idResult zonkResult moduleName position) he.stateVariables)
          `orElse` listToMaybe (mapMaybe (hoverFromRequestHandler idResult zonkResult moduleName position) he.handlers)
          `orElse` (he.thenClause >>= hoverFromBlock idResult zonkResult moduleName position . snd)
          `orElse` hoverFromBlock idResult zonkResult moduleName position he.body
      ExpressionQualifiedReference qre ->
        hoverFromVariableRef idResult zonkResult moduleName qre.target
      ExpressionRecord re ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult moduleName position . snd) re.entries)
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
  IdentifierResult ->
  ZonkResult ->
  Text ->
  Position ->
  CaseArm Zonked ->
  Maybe HoverInfo
hoverFromCaseArm idResult zonkResult moduleName position arm
  | spanContains arm.sourceSpan position =
      hoverFromPattern idResult zonkResult moduleName position arm.pattern
        `orElse` hoverFromBlock idResult zonkResult moduleName position arm.body
  | otherwise = Nothing

hoverFromForVarBinding :: IdentifierResult -> ZonkResult -> Text -> Position -> ForVarBinding Zonked -> Maybe HoverInfo
hoverFromForVarBinding idResult zonkResult moduleName position binding
  | spanContains binding.sourceSpan position =
      hoverFromExpression idResult zonkResult moduleName position binding.initial
        `orElse` if spanContains binding.name.sourceSpan position
          then hoverFromVariableRef idResult zonkResult moduleName binding.name
          else Nothing
  | otherwise = Nothing

hoverFromStateVariable :: IdentifierResult -> ZonkResult -> Text -> Position -> StateVariableBinding Zonked -> Maybe HoverInfo
hoverFromStateVariable idResult zonkResult moduleName position binding
  | spanContains binding.sourceSpan position =
      hoverFromExpression idResult zonkResult moduleName position binding.initial
        `orElse` if spanContains binding.name.sourceSpan position
          then hoverFromVariableRef idResult zonkResult moduleName binding.name
          else Nothing
  | otherwise = Nothing

hoverFromRequestHandler :: IdentifierResult -> ZonkResult -> Text -> Position -> RequestHandler Zonked -> Maybe HoverInfo
hoverFromRequestHandler idResult zonkResult moduleName position handler
  | spanContains handler.sourceSpan position =
      listToMaybe (mapMaybe (hoverFromParameter idResult zonkResult moduleName position) handler.parameters)
        `orElse` hoverFromBlock idResult zonkResult moduleName position handler.body
        `orElse` hoverFromRequestNameRef idResult zonkResult position handler.name
  | otherwise = Nothing

hoverFromRequestNameRef ::
  IdentifierResult ->
  ZonkResult ->
  Position ->
  NameRef Zonked RequestRef ->
  Maybe HoverInfo
hoverFromRequestNameRef idResult zonkResult position nameRef
  | not (spanContains nameRef.sourceSpan position) = Nothing
  | otherwise = do
      qualifiedName <- nameRef.resolution
      requestData <- Map.lookup qualifiedName idResult.identifiedRequests
      let semanticType = lookupTopLevelType qualifiedName zonkResult
      pure
        HoverInfo
          { hoverType = semanticType,
            hoverNameSpan = nameRef.sourceSpan,
            hoverDefinitionSpan = Just requestData.requestSourceSpan,
            hoverQualifiedName = Just (renderQualifiedName qualifiedName)
          }

hoverFromTemplateElement :: IdentifierResult -> ZonkResult -> Text -> Position -> TemplateElement Zonked -> Maybe HoverInfo
hoverFromTemplateElement idResult zonkResult moduleName position = \case
  TemplateElementString _ -> Nothing
  TemplateElementExpression element
    | spanContains element.sourceSpan position ->
        hoverFromExpression idResult zonkResult moduleName position element.value
    | otherwise -> Nothing

-- ===========================================================================
-- Internal: reference extraction
-- ===========================================================================

refFromDeclaration :: IdentifierResult -> Position -> Declaration Zonked -> Maybe ResolvedReference
refFromDeclaration idResult position = \case
  DeclarationAgent decl
    | spanContains decl.sourceSpan position ->
        refFromBlock idResult position decl.body
          `orElse` refFromVariableNameRef idResult position decl.name
  DeclarationRequest decl
    | spanContains decl.sourceSpan position ->
        refFromVariableNameRef idResult position decl.name
  DeclarationExternalAgent decl
    | spanContains decl.sourceSpan position ->
        refFromVariableNameRef idResult position decl.name
  DeclarationData decl
    | spanContains decl.sourceSpan position ->
        refFromVariableNameRef idResult position decl.name
  _ -> Nothing

refFromVariableNameRef :: IdentifierResult -> Position -> NameRef Zonked VariableRef -> Maybe ResolvedReference
refFromVariableNameRef _idResult position nameRef
  | spanContains nameRef.sourceSpan position =
      fmap ResolvedReferenceVariable nameRef.resolution
  | otherwise = Nothing

refFromBlock :: IdentifierResult -> Position -> Block Zonked -> Maybe ResolvedReference
refFromBlock idResult position block
  | spanContains block.sourceSpan position =
      listToMaybe (mapMaybe (refFromStatement idResult position) block.statements)
        `orElse` (block.returnExpression >>= refFromExpression idResult position)
  | otherwise = Nothing

refFromStatement :: IdentifierResult -> Position -> Statement Zonked -> Maybe ResolvedReference
refFromStatement idResult position = \case
  StatementLet letStatement
    | spanContains letStatement.sourceSpan position ->
        refFromExpression idResult position letStatement.value
  StatementExpression expression
    | spanContains (sourceSpanOf expression) position ->
        refFromExpression idResult position expression
  StatementAgent agentStatement
    | spanContains agentStatement.sourceSpan position ->
        refFromBlock idResult position agentStatement.body
  StatementReturn returnStatement
    | spanContains returnStatement.sourceSpan position ->
        refFromExpression idResult position returnStatement.value
  StatementBreak breakStatement
    | spanContains breakStatement.sourceSpan position ->
        refFromExpression idResult position breakStatement.value
  StatementNext nextStatement
    | spanContains nextStatement.sourceSpan position ->
        refFromExpression idResult position nextStatement.value
          `orElse` listToMaybe (mapMaybe (refFromModifier idResult position) nextStatement.modifiers)
  StatementForBreak ForBreakStatement {value, sourceSpan}
    | spanContains sourceSpan position ->
        refFromExpression idResult position value
  StatementForNext ForNextStatement {modifiers, sourceSpan}
    | spanContains sourceSpan position ->
        listToMaybe (mapMaybe (refFromModifier idResult position) modifiers)
  _ -> Nothing

refFromModifier :: IdentifierResult -> Position -> Modifier Zonked -> Maybe ResolvedReference
refFromModifier idResult position modifier
  | spanContains modifier.sourceSpan position =
      refFromExpression idResult position modifier.value
        `orElse` refFromVariableNameRef idResult position modifier.name
  | otherwise = Nothing

refFromExpression :: IdentifierResult -> Position -> Expression Zonked -> Maybe ResolvedReference
refFromExpression idResult position expression
  | not (spanContains (sourceSpanOf expression) position) = Nothing
  | otherwise = case expression of
      ExpressionVariable ve
        | spanContains ve.name.sourceSpan position ->
            fmap ResolvedReferenceVariable ve.name.resolution
      ExpressionCall ce ->
        refFromExpression idResult position ce.callee
          `orElse` listToMaybe (mapMaybe (refFromExpression idResult position . (.value)) ce.arguments)
      ExpressionBinaryOperator be ->
        refFromExpression idResult position be.left
          `orElse` refFromExpression idResult position be.right
      ExpressionUnaryOperator ue ->
        refFromExpression idResult position ue.operand
      ExpressionIf ie ->
        refFromExpression idResult position ie.condition
          `orElse` refFromBlock idResult position ie.thenBlock
          `orElse` (ie.elseBlock >>= refFromBlock idResult position)
      ExpressionMatch me ->
        refFromExpression idResult position me.subject
          `orElse` listToMaybe (mapMaybe (refFromBlock idResult position . (.body)) me.cases)
      ExpressionFor fe ->
        listToMaybe (mapMaybe (refFromExpression idResult position . (.source)) fe.inBindings)
          `orElse` listToMaybe (mapMaybe (refFromForVarBinding idResult position) fe.varBindings)
          `orElse` refFromBlock idResult position fe.body
          `orElse` (fe.thenBlock >>= refFromBlock idResult position)
      ExpressionBlock be ->
        refFromBlock idResult position be.block
      ExpressionTuple te ->
        listToMaybe (mapMaybe (refFromExpression idResult position) te.elements)
      ExpressionArray ae ->
        listToMaybe (mapMaybe (refFromExpression idResult position) ae.elements)
      ExpressionParTuple pte ->
        listToMaybe (mapMaybe (refFromExpression idResult position) pte.elements)
      ExpressionParArray pae ->
        listToMaybe (mapMaybe (refFromExpression idResult position) pae.elements)
      ExpressionFieldAccess fae ->
        refFromExpression idResult position fae.object
      ExpressionIndexAccess iae ->
        refFromExpression idResult position iae.array
          `orElse` refFromExpression idResult position iae.index
      ExpressionTemplate te ->
        listToMaybe (mapMaybe (refFromTemplateElement idResult position) te.elements)
      ExpressionHandle he ->
        listToMaybe (mapMaybe (refFromStateVariable idResult position) he.stateVariables)
          `orElse` listToMaybe (mapMaybe (refFromRequestHandler idResult position) he.handlers)
          `orElse` (he.thenClause >>= refFromBlock idResult position . snd)
          `orElse` refFromBlock idResult position he.body
      ExpressionQualifiedReference qre
        | spanContains qre.target.sourceSpan position ->
            fmap ResolvedReferenceVariable qre.target.resolution
        | spanContains qre.moduleQualifier.sourceSpan position ->
            fmap ResolvedReferenceModule qre.moduleQualifier.resolution
      _ -> Nothing

refFromForVarBinding :: IdentifierResult -> Position -> ForVarBinding Zonked -> Maybe ResolvedReference
refFromForVarBinding idResult position binding
  | spanContains binding.sourceSpan position =
      refFromExpression idResult position binding.initial
        `orElse` refFromVariableNameRef idResult position binding.name
  | otherwise = Nothing

refFromStateVariable :: IdentifierResult -> Position -> StateVariableBinding Zonked -> Maybe ResolvedReference
refFromStateVariable idResult position binding
  | spanContains binding.sourceSpan position =
      refFromExpression idResult position binding.initial
        `orElse` refFromVariableNameRef idResult position binding.name
  | otherwise = Nothing

refFromRequestHandler :: IdentifierResult -> Position -> RequestHandler Zonked -> Maybe ResolvedReference
refFromRequestHandler idResult position handler
  | spanContains handler.sourceSpan position =
      refFromBlock idResult position handler.body
  | otherwise = Nothing

refFromTemplateElement :: IdentifierResult -> Position -> TemplateElement Zonked -> Maybe ResolvedReference
refFromTemplateElement idResult position = \case
  TemplateElementString _ -> Nothing
  TemplateElementExpression element
    | spanContains element.sourceSpan position ->
        refFromExpression idResult position element.value
    | otherwise -> Nothing

-- ===========================================================================
-- Internal: occurrence collection
-- ===========================================================================

collectDeclarationOccurrences :: IdentifierResult -> Declaration Zonked -> OccurrenceIndex -> OccurrenceIndex
collectDeclarationOccurrences idResult declaration index = case declaration of
  DeclarationAgent decl ->
    collectBlockOccurrences idResult decl.body (addVariableOccurrence idResult decl.name index)
  DeclarationRequest decl ->
    addVariableOccurrence idResult decl.name index
  DeclarationExternalAgent decl ->
    addVariableOccurrence idResult decl.name index
  DeclarationData decl ->
    addVariableOccurrence idResult decl.name index
  _ -> index

collectBlockOccurrences :: IdentifierResult -> Block Zonked -> OccurrenceIndex -> OccurrenceIndex
collectBlockOccurrences idResult block index =
  let withStatements = foldr (collectStatementOccurrences idResult) index block.statements
   in maybe withStatements (\expression -> collectExpressionOccurrences idResult expression withStatements) block.returnExpression

collectStatementOccurrences :: IdentifierResult -> Statement Zonked -> OccurrenceIndex -> OccurrenceIndex
collectStatementOccurrences idResult statement index = case statement of
  StatementLet letStatement ->
    collectExpressionOccurrences idResult letStatement.value index
  StatementExpression expression ->
    collectExpressionOccurrences idResult expression index
  StatementAgent agentStatement ->
    collectBlockOccurrences idResult agentStatement.body index
  StatementReturn returnStatement ->
    collectExpressionOccurrences idResult returnStatement.value index
  StatementBreak breakStatement ->
    collectExpressionOccurrences idResult breakStatement.value index
  StatementNext nextStatement ->
    foldr (collectModifierOccurrences idResult) (collectExpressionOccurrences idResult nextStatement.value index) nextStatement.modifiers
  StatementForBreak ForBreakStatement {value} ->
    collectExpressionOccurrences idResult value index
  StatementForNext ForNextStatement {modifiers} ->
    foldr (collectModifierOccurrences idResult) index modifiers
  _ -> index

collectModifierOccurrences :: IdentifierResult -> Modifier Zonked -> OccurrenceIndex -> OccurrenceIndex
collectModifierOccurrences idResult modifier index =
  collectExpressionOccurrences idResult modifier.value (addVariableOccurrence idResult modifier.name index)

collectExpressionOccurrences :: IdentifierResult -> Expression Zonked -> OccurrenceIndex -> OccurrenceIndex
collectExpressionOccurrences idResult expression index = case expression of
  ExpressionVariable ve ->
    addVariableOccurrence idResult ve.name index
  ExpressionCall ce ->
    foldr
      (collectExpressionOccurrences idResult . (.value))
      (collectExpressionOccurrences idResult ce.callee index)
      ce.arguments
  ExpressionBinaryOperator be ->
    collectExpressionOccurrences idResult be.left (collectExpressionOccurrences idResult be.right index)
  ExpressionUnaryOperator ue ->
    collectExpressionOccurrences idResult ue.operand index
  ExpressionIf ie ->
    collectExpressionOccurrences
      idResult
      ie.condition
      ( collectBlockOccurrences
          idResult
          ie.thenBlock
          (maybe index ((\block -> collectBlockOccurrences idResult block index)) ie.elseBlock)
      )
  ExpressionMatch me ->
    collectExpressionOccurrences
      idResult
      me.subject
      (foldr (\caseArm -> collectBlockOccurrences idResult caseArm.body) index me.cases)
  ExpressionFor fe ->
    let withInBindings = foldr (collectExpressionOccurrences idResult . (.source)) index fe.inBindings
        withVarBindings = foldr (collectForVarBindingOccurrences idResult) withInBindings fe.varBindings
        withBody = collectBlockOccurrences idResult fe.body withVarBindings
     in maybe withBody (\thenBlock -> collectBlockOccurrences idResult thenBlock withBody) fe.thenBlock
  ExpressionBlock be ->
    collectBlockOccurrences idResult be.block index
  ExpressionTuple te ->
    foldr (collectExpressionOccurrences idResult) index te.elements
  ExpressionArray ae ->
    foldr (collectExpressionOccurrences idResult) index ae.elements
  ExpressionParTuple pte ->
    foldr (collectExpressionOccurrences idResult) index pte.elements
  ExpressionParArray pae ->
    foldr (collectExpressionOccurrences idResult) index pae.elements
  ExpressionFieldAccess fae ->
    collectExpressionOccurrences idResult fae.object index
  ExpressionIndexAccess iae ->
    collectExpressionOccurrences idResult iae.array (collectExpressionOccurrences idResult iae.index index)
  ExpressionTemplate te ->
    foldr (collectTemplateElementOccurrences idResult) index te.elements
  ExpressionHandle he ->
    let withState = foldr (collectStateVariableOccurrences idResult) index he.stateVariables
        withHandlers = foldr (\handler -> collectBlockOccurrences idResult handler.body) withState he.handlers
        withThen = maybe withHandlers (\(_, thenBlock) -> collectBlockOccurrences idResult thenBlock withHandlers) he.thenClause
     in collectBlockOccurrences idResult he.body withThen
  ExpressionQualifiedReference qre ->
    addModuleOccurrence idResult qre.moduleQualifier (addVariableOccurrence idResult qre.target index)
  _ -> index

collectForVarBindingOccurrences :: IdentifierResult -> ForVarBinding Zonked -> OccurrenceIndex -> OccurrenceIndex
collectForVarBindingOccurrences idResult binding index =
  collectExpressionOccurrences idResult binding.initial (addVariableOccurrence idResult binding.name index)

collectStateVariableOccurrences :: IdentifierResult -> StateVariableBinding Zonked -> OccurrenceIndex -> OccurrenceIndex
collectStateVariableOccurrences idResult binding index =
  collectExpressionOccurrences idResult binding.initial (addVariableOccurrence idResult binding.name index)

collectTemplateElementOccurrences :: IdentifierResult -> TemplateElement Zonked -> OccurrenceIndex -> OccurrenceIndex
collectTemplateElementOccurrences idResult = \case
  TemplateElementString _ -> id
  TemplateElementExpression element -> collectExpressionOccurrences idResult element.value

addModuleOccurrence :: IdentifierResult -> NameRef Zonked ModuleRef -> OccurrenceIndex -> OccurrenceIndex
addModuleOccurrence _idResult nameRef index = case nameRef.resolution of
  Nothing -> index
  Just moduleName ->
    index
      { moduleOccurrences =
          Map.insertWith (<>) moduleName [nameRef.sourceSpan] index.moduleOccurrences
      }

addVariableOccurrence :: IdentifierResult -> NameRef Zonked VariableRef -> OccurrenceIndex -> OccurrenceIndex
addVariableOccurrence _idResult nameRef index = case nameRef.resolution of
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
