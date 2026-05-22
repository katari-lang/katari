-- | Position-based query layer for LSP / CLI tooling.
--
-- Callers compile a source set via 'Katari.Compile.compile', then use the
-- returned 'ZonkResult' to answer editor queries without re-running the
-- compiler. All positions are code-point based (LSP layer converts UTF-16
-- offsets before calling here).
module Katari.Query
  ( -- * Hover
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
    UnaryOperatorExpression (..),
    VariableExpression (..),
    VariablePattern (..),
    WildcardPattern (..),
  )
import Katari.Id
  ( ConstructorId,
    ModuleId,
    RequestId,
    TypeId,
    VariableId,
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
import Katari.Typechecker.Zonker (ZonkResult (..))

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
lookupAtPosition :: IdentifierResult -> ZonkResult -> FilePath -> Position -> Maybe HoverInfo
lookupAtPosition idResult zonkResult filePath position = do
  moduleData <- findModuleByFilePath idResult zonkResult filePath
  listToMaybe (mapMaybe (hoverFromDeclaration idResult zonkResult position) moduleData.declarations)

-- ===========================================================================
-- Occurrence index
-- ===========================================================================

-- | Pre-built index of every name-reference occurrence in all modules.
-- Build once after compilation, then query cheaply with 'findReferences'.
data OccurrenceIndex = OccurrenceIndex
  { variableOccurrences :: Map VariableId [SourceSpan],
    typeOccurrences :: Map TypeId [SourceSpan],
    moduleOccurrences :: Map ModuleId [SourceSpan],
    requestOccurrences :: Map RequestId [SourceSpan],
    constructorOccurrences :: Map ConstructorId [SourceSpan]
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

-- | Walk all modules in 'ZonkResult' and collect every name-reference
-- occurrence grouped by its resolved identifier.
buildOccurrenceIndex :: IdentifierResult -> ZonkResult -> OccurrenceIndex
buildOccurrenceIndex _ zonkResult =
  foldr collectModuleOccurrences emptyOccurrenceIndex (Map.elems zonkResult.zonkedModules)

collectModuleOccurrences :: Module Zonked -> OccurrenceIndex -> OccurrenceIndex
collectModuleOccurrences moduleData index =
  foldr collectDeclarationOccurrences index moduleData.declarations

-- ===========================================================================
-- Reference / definition queries
-- ===========================================================================

-- | Which resolved identifier sits at a source position.
data ResolvedReference where
  ResolvedReferenceVariable :: VariableId -> ResolvedReference
  ResolvedReferenceType :: TypeId -> ResolvedReference
  ResolvedReferenceModule :: ModuleId -> ResolvedReference
  ResolvedReferenceRequest :: RequestId -> ResolvedReference
  ResolvedReferenceConstructor :: ConstructorId -> ResolvedReference
  deriving (Eq, Show)

-- | Identify which resolved identifier (if any) sits at a source position.
identifyAtPosition :: IdentifierResult -> ZonkResult -> FilePath -> Position -> Maybe ResolvedReference
identifyAtPosition idResult zonkResult filePath position = do
  moduleData <- findModuleByFilePath idResult zonkResult filePath
  listToMaybe (mapMaybe (refFromDeclaration position) moduleData.declarations)

-- | All occurrence spans of a resolved identifier (uses 'OccurrenceIndex').
findReferences :: OccurrenceIndex -> ResolvedReference -> [SourceSpan]
findReferences index = \case
  ResolvedReferenceVariable variableId ->
    Map.findWithDefault [] variableId index.variableOccurrences
  ResolvedReferenceType typeId ->
    Map.findWithDefault [] typeId index.typeOccurrences
  ResolvedReferenceModule moduleId ->
    Map.findWithDefault [] moduleId index.moduleOccurrences
  ResolvedReferenceRequest requestId ->
    Map.findWithDefault [] requestId index.requestOccurrences
  ResolvedReferenceConstructor constructorId ->
    Map.findWithDefault [] constructorId index.constructorOccurrences

-- | Definition span of the symbol at a position, if it can be resolved.
findDefinition :: IdentifierResult -> ZonkResult -> FilePath -> Position -> Maybe SourceSpan
findDefinition idResult zonkResult filePath position = do
  resolvedRef <- identifyAtPosition idResult zonkResult filePath position
  case resolvedRef of
    ResolvedReferenceVariable variableId ->
      fmap (.variableSourceSpan) (Map.lookup variableId idResult.identifiedVariables)
    ResolvedReferenceType typeId ->
      fmap (.typeSourceSpan) (Map.lookup typeId idResult.identifiedTypes)
    ResolvedReferenceModule _ -> Nothing
    ResolvedReferenceRequest requestId ->
      fmap (.requestSourceSpan) (Map.lookup requestId idResult.identifiedRequests)
    ResolvedReferenceConstructor constructorId ->
      fmap (.constructorSourceSpan) (Map.lookup constructorId idResult.identifiedConstructors)

-- ===========================================================================
-- Internal: module lookup
-- ===========================================================================

findModuleByFilePath :: IdentifierResult -> ZonkResult -> FilePath -> Maybe (Module Zonked)
findModuleByFilePath _ zonkResult filePath =
  listToMaybe [m | m <- Map.elems zonkResult.zonkedModules, m.sourceSpan.filePath == filePath]

-- ===========================================================================
-- Internal: hover extraction
-- ===========================================================================

hoverFromDeclaration :: IdentifierResult -> ZonkResult -> Position -> Declaration Zonked -> Maybe HoverInfo
hoverFromDeclaration idResult zonkResult position = \case
  DeclarationAgent decl
    | spanContains decl.sourceSpan position ->
        -- Body / parameter hover takes priority. Only fall back to the
        -- agent name's hover when the cursor is literally on the
        -- agent name; otherwise we leak the agent's hover into
        -- arbitrary positions inside the body.
        hoverFromBlock idResult zonkResult position decl.body
          `orElse` listToMaybe
            (mapMaybe (hoverFromParameter idResult zonkResult position) decl.parameters)
          `orElse` ifPositionOnName decl.name (hoverFromVariableRef idResult zonkResult decl.name)
  DeclarationRequest decl
    | spanContains decl.sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromParameter idResult zonkResult position) decl.parameters)
          `orElse` ifPositionOnName decl.name (hoverFromVariableRef idResult zonkResult decl.name)
  DeclarationExternalAgent decl
    | spanContains decl.sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromParameter idResult zonkResult position) decl.parameters)
          `orElse` ifPositionOnName decl.name (hoverFromVariableRef idResult zonkResult decl.name)
  DeclarationData decl
    | spanContains decl.sourceSpan position ->
        ifPositionOnName decl.name (hoverFromVariableRef idResult zonkResult decl.name)
  _ -> Nothing
  where
    ifPositionOnName :: NameRef Zonked s -> Maybe a -> Maybe a
    ifPositionOnName nameRef value =
      if spanContains nameRef.sourceSpan position then value else Nothing

-- | Hover for a parameter's binding name (e.g. the @name@ in
-- @agent foo(name = name: string)@).
hoverFromParameter ::
  IdentifierResult ->
  ZonkResult ->
  Position ->
  ParameterBinding Zonked ->
  Maybe HoverInfo
hoverFromParameter idResult zonkResult position param =
  if spanContains param.sourceSpan position
    then hoverFromPattern idResult zonkResult position param.pattern
    else Nothing

-- | Hover for a pattern node — currently only the @VariablePattern@
-- case is meaningful (binding name → variable hover). Recurses into
-- composite patterns so destructured binders show up too.
hoverFromPattern ::
  IdentifierResult ->
  ZonkResult ->
  Position ->
  Pattern Zonked ->
  Maybe HoverInfo
hoverFromPattern idResult zonkResult position = \case
  PatternVariable vp
    | spanContains vp.name.sourceSpan position ->
        hoverFromVariableRef idResult zonkResult vp.name
  PatternTuple tp
    | spanContains tp.sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromPattern idResult zonkResult position) tp.elements)
  PatternQualifiedConstructor qp
    | spanContains qp.sourceSpan position ->
        listToMaybe
          (mapMaybe (hoverFromPattern idResult zonkResult position . snd) qp.parameters)
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
  _ -> Nothing

hoverFromVariableRef :: IdentifierResult -> ZonkResult -> NameRef Zonked VariableRef -> Maybe HoverInfo
hoverFromVariableRef idResult zonkResult nameRef = do
  variableId <- nameRef.resolution
  let semanticType = Map.lookup variableId zonkResult.zonkedTypeEnvironment
      variableData = Map.lookup variableId idResult.identifiedVariables
      qualifiedName = variableData >>= (.variableQualifiedName)
  pure
    HoverInfo
      { hoverType = semanticType,
        hoverNameSpan = nameRef.sourceSpan,
        hoverDefinitionSpan = fmap (.variableSourceSpan) variableData,
        hoverQualifiedName = fmap renderQualifiedName qualifiedName
      }

hoverFromBlock :: IdentifierResult -> ZonkResult -> Position -> Block Zonked -> Maybe HoverInfo
hoverFromBlock idResult zonkResult position block
  | spanContains block.sourceSpan position =
      listToMaybe (mapMaybe (hoverFromStatement idResult zonkResult position) block.statements)
        `orElse` (block.returnExpression >>= hoverFromExpression idResult zonkResult position)
  | otherwise = Nothing

hoverFromStatement :: IdentifierResult -> ZonkResult -> Position -> Statement Zonked -> Maybe HoverInfo
hoverFromStatement idResult zonkResult position = \case
  StatementLet letStatement
    | spanContains letStatement.sourceSpan position ->
        -- Try the LHS pattern first (hover on a freshly-bound name
        -- shows the variable's inferred type), then the RHS.
        hoverFromPattern idResult zonkResult position letStatement.pattern
          `orElse` hoverFromExpression idResult zonkResult position letStatement.value
  StatementExpression expression
    | spanContains (sourceSpanOf expression) position ->
        hoverFromExpression idResult zonkResult position expression
  StatementAgent agentStatement
    | spanContains agentStatement.sourceSpan position ->
        hoverFromBlock idResult zonkResult position agentStatement.body
  StatementReturn returnStatement
    | spanContains returnStatement.sourceSpan position ->
        hoverFromExpression idResult zonkResult position returnStatement.value
  StatementBreak breakStatement
    | spanContains breakStatement.sourceSpan position ->
        hoverFromExpression idResult zonkResult position breakStatement.value
  StatementNext nextStatement
    | spanContains nextStatement.sourceSpan position ->
        hoverFromExpression idResult zonkResult position nextStatement.value
          `orElse` listToMaybe (mapMaybe (hoverFromModifier idResult zonkResult position) nextStatement.modifiers)
  StatementForBreak ForBreakStatement {value, sourceSpan}
    | spanContains sourceSpan position ->
        hoverFromExpression idResult zonkResult position value
  StatementForNext ForNextStatement {modifiers, sourceSpan}
    | spanContains sourceSpan position ->
        listToMaybe (mapMaybe (hoverFromModifier idResult zonkResult position) modifiers)
  _ -> Nothing

hoverFromModifier :: IdentifierResult -> ZonkResult -> Position -> Modifier Zonked -> Maybe HoverInfo
hoverFromModifier idResult zonkResult position modifier
  | spanContains modifier.sourceSpan position =
      hoverFromExpression idResult zonkResult position modifier.value
        `orElse` if spanContains modifier.name.sourceSpan position
          then hoverFromVariableRef idResult zonkResult modifier.name
          else Nothing
  | otherwise = Nothing

hoverFromExpression :: IdentifierResult -> ZonkResult -> Position -> Expression Zonked -> Maybe HoverInfo
hoverFromExpression idResult zonkResult position expression
  | not (spanContains (sourceSpanOf expression) position) = Nothing
  -- Try the most-specific (= innermost) hover first; fall back to the
  -- enclosing expression's inferred type if no inner node matched.
  -- This ensures variable references win when both apply, while still
  -- giving every expression position a meaningful hover.
  | otherwise = specific `orElse` Just (genericExpressionHover expression)
  where
    specific = case expression of
      ExpressionVariable ve ->
        let semanticType = ve.name.resolution >>= \vid -> Map.lookup vid zonkResult.zonkedTypeEnvironment
            variableData = ve.name.resolution >>= \vid -> Map.lookup vid idResult.identifiedVariables
         in Just
              HoverInfo
                { hoverType = semanticType,
                  hoverNameSpan = ve.name.sourceSpan,
                  hoverDefinitionSpan = fmap (.variableSourceSpan) variableData,
                  hoverQualifiedName =
                    variableData >>= (.variableQualifiedName) >>= Just . renderQualifiedName
                }
      ExpressionCall ce ->
        hoverFromExpression idResult zonkResult position ce.callee
          `orElse` listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult position . (.value)) ce.arguments)
      ExpressionBinaryOperator be ->
        hoverFromExpression idResult zonkResult position be.left
          `orElse` hoverFromExpression idResult zonkResult position be.right
      ExpressionUnaryOperator ue ->
        hoverFromExpression idResult zonkResult position ue.operand
      ExpressionIf ie ->
        hoverFromExpression idResult zonkResult position ie.condition
          `orElse` hoverFromBlock idResult zonkResult position ie.thenBlock
          `orElse` (ie.elseBlock >>= hoverFromBlock idResult zonkResult position)
      ExpressionMatch me ->
        hoverFromExpression idResult zonkResult position me.subject
          `orElse` listToMaybe (mapMaybe (hoverFromCaseArm idResult zonkResult position) me.cases)
      ExpressionFor fe ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult position . (.source)) fe.inBindings)
          `orElse` listToMaybe (mapMaybe (hoverFromForVarBinding idResult zonkResult position) fe.varBindings)
          `orElse` hoverFromBlock idResult zonkResult position fe.body
          `orElse` (fe.thenBlock >>= hoverFromBlock idResult zonkResult position)
      ExpressionBlock be ->
        hoverFromBlock idResult zonkResult position be.block
      ExpressionTuple te ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult position) te.elements)
      ExpressionArray ae ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult position) ae.elements)
      ExpressionParTuple pte ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult position) pte.elements)
      ExpressionParArray pae ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult position) pae.elements)
      ExpressionFieldAccess fae ->
        hoverFromExpression idResult zonkResult position fae.object
      ExpressionIndexAccess iae ->
        hoverFromExpression idResult zonkResult position iae.array
          `orElse` hoverFromExpression idResult zonkResult position iae.index
      ExpressionTemplate te ->
        listToMaybe (mapMaybe (hoverFromTemplateElement idResult zonkResult position) te.elements)
      ExpressionHandle he ->
        listToMaybe (mapMaybe (hoverFromStateVariable idResult zonkResult position) he.stateVariables)
          `orElse` listToMaybe (mapMaybe (hoverFromRequestHandler idResult zonkResult position) he.handlers)
          `orElse` (he.thenClause >>= hoverFromBlock idResult zonkResult position . snd)
          `orElse` hoverFromBlock idResult zonkResult position he.body
      ExpressionQualifiedReference qre ->
        hoverFromVariableRef idResult zonkResult qre.target
      ExpressionLiteral _ -> Nothing -- fall through to generic typeOf hover

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
  Position ->
  CaseArm Zonked ->
  Maybe HoverInfo
hoverFromCaseArm idResult zonkResult position arm
  | spanContains arm.sourceSpan position =
      hoverFromPattern idResult zonkResult position arm.pattern
        `orElse` hoverFromBlock idResult zonkResult position arm.body
  | otherwise = Nothing

hoverFromForVarBinding :: IdentifierResult -> ZonkResult -> Position -> ForVarBinding Zonked -> Maybe HoverInfo
hoverFromForVarBinding idResult zonkResult position binding
  | spanContains binding.sourceSpan position =
      hoverFromExpression idResult zonkResult position binding.initial
        `orElse` if spanContains binding.name.sourceSpan position
          then hoverFromVariableRef idResult zonkResult binding.name
          else Nothing
  | otherwise = Nothing

hoverFromStateVariable :: IdentifierResult -> ZonkResult -> Position -> StateVariableBinding Zonked -> Maybe HoverInfo
hoverFromStateVariable idResult zonkResult position binding
  | spanContains binding.sourceSpan position =
      hoverFromExpression idResult zonkResult position binding.initial
        `orElse` if spanContains binding.name.sourceSpan position
          then hoverFromVariableRef idResult zonkResult binding.name
          else Nothing
  | otherwise = Nothing

hoverFromRequestHandler :: IdentifierResult -> ZonkResult -> Position -> RequestHandler Zonked -> Maybe HoverInfo
hoverFromRequestHandler idResult zonkResult position handler
  | spanContains handler.sourceSpan position =
      -- Try parameter bindings first (handler params bind names that
      -- might be hovered), then the handler body, then fall back to
      -- the req-name itself when the cursor is on the @req <name>@
      -- token.
      listToMaybe (mapMaybe (hoverFromParameter idResult zonkResult position) handler.parameters)
        `orElse` hoverFromBlock idResult zonkResult position handler.body
        `orElse` hoverFromRequestNameRef idResult zonkResult position handler.name
  | otherwise = Nothing

-- | Hover for the @name@ on @req <name>(...)@ inside a handle block.
-- Looks up the request's call-side type via 'RequestData.requestVariableId'
-- and surfaces it together with the qualified name.
hoverFromRequestNameRef ::
  IdentifierResult ->
  ZonkResult ->
  Position ->
  NameRef Zonked RequestRef ->
  Maybe HoverInfo
hoverFromRequestNameRef idResult zonkResult position nameRef
  | not (spanContains nameRef.sourceSpan position) = Nothing
  | otherwise = do
      requestId <- nameRef.resolution
      requestData <- Map.lookup requestId idResult.identifiedRequests
      let variableId = requestData.requestVariableId
          semanticType = Map.lookup variableId zonkResult.zonkedTypeEnvironment
      pure
        HoverInfo
          { hoverType = semanticType,
            hoverNameSpan = nameRef.sourceSpan,
            hoverDefinitionSpan = Just requestData.requestSourceSpan,
            hoverQualifiedName = Just (renderQualifiedName requestData.requestQualifiedName)
          }

hoverFromTemplateElement :: IdentifierResult -> ZonkResult -> Position -> TemplateElement Zonked -> Maybe HoverInfo
hoverFromTemplateElement idResult zonkResult position = \case
  TemplateElementString _ -> Nothing
  TemplateElementExpression element
    | spanContains element.sourceSpan position ->
        hoverFromExpression idResult zonkResult position element.value
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
      (foldr (collectBlockOccurrences . (.body)) index me.cases)
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
        withHandlers = foldr (collectBlockOccurrences . (.body)) withState he.handlers
        withThen = maybe withHandlers ((`collectBlockOccurrences` withHandlers) . snd) he.thenClause
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
  Just moduleId ->
    index
      { moduleOccurrences =
          Map.insertWith (<>) moduleId [nameRef.sourceSpan] index.moduleOccurrences
      }

addVariableOccurrence :: NameRef Zonked VariableRef -> OccurrenceIndex -> OccurrenceIndex
addVariableOccurrence nameRef index = case nameRef.resolution of
  Nothing -> index
  Just variableId ->
    index
      { variableOccurrences =
          Map.insertWith (<>) variableId [nameRef.sourceSpan] index.variableOccurrences
      }

-- ===========================================================================
-- Internal: span helpers
-- ===========================================================================

orElse :: Maybe a -> Maybe a -> Maybe a
orElse Nothing b = b
orElse a _ = a
