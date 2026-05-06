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
    ForExpression (..),
    ForInBinding (..),
    IfExpression (..),
    LetStatement (..),
    MatchExpression (..),
    Module (..),
    NameRef (..),
    NameRefKind (..),
    NextStatement (..),
    Phase (Zonked),
    RequestDeclaration (..),
    ReturnStatement (..),
    Statement (..),
    TupleExpression (..),
    UnaryOperatorExpression (..),
    VariableExpression (..),
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
import Katari.SourceSpan (HasSourceSpan (..), Position (..), SourceSpan (..))
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
buildOccurrenceIndex idResult zonkResult =
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
findModuleByFilePath idResult zonkResult filePath =
  listToMaybe [m | m <- Map.elems zonkResult.zonkedModules, m.sourceSpan.filePath == filePath]

-- ===========================================================================
-- Internal: hover extraction
-- ===========================================================================

hoverFromDeclaration :: IdentifierResult -> ZonkResult -> Position -> Declaration Zonked -> Maybe HoverInfo
hoverFromDeclaration idResult zonkResult position = \case
  DeclarationAgent decl
    | spanContains decl.sourceSpan position ->
        hoverFromBlock idResult zonkResult position decl.body
          `orElse` hoverFromVariableRef idResult zonkResult decl.name
  DeclarationRequest decl
    | spanContains decl.sourceSpan position ->
        hoverFromVariableRef idResult zonkResult decl.name
  DeclarationExternalAgent decl
    | spanContains decl.sourceSpan position ->
        hoverFromVariableRef idResult zonkResult decl.name
  DeclarationData decl
    | spanContains decl.sourceSpan position ->
        hoverFromVariableRef idResult zonkResult decl.name
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
        hoverFromExpression idResult zonkResult position letStatement.value
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
  _ -> Nothing

hoverFromExpression :: IdentifierResult -> ZonkResult -> Position -> Expression Zonked -> Maybe HoverInfo
hoverFromExpression idResult zonkResult position expression
  | not (spanContains (sourceSpanOf expression) position) = Nothing
  | otherwise = case expression of
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
          `orElse` listToMaybe (mapMaybe (hoverFromBlock idResult zonkResult position . (.body)) me.cases)
      ExpressionFor fe ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult position . (.source)) fe.inBindings)
          `orElse` hoverFromBlock idResult zonkResult position fe.body
      ExpressionBlock be ->
        hoverFromBlock idResult zonkResult position be.block
      ExpressionTuple te ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult position) te.elements)
      ExpressionArray ae ->
        listToMaybe (mapMaybe (hoverFromExpression idResult zonkResult position) ae.elements)
      _ -> Nothing

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
  _ -> Nothing

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
          `orElse` refFromBlock position fe.body
      ExpressionBlock be ->
        refFromBlock position be.block
      ExpressionTuple te ->
        listToMaybe (mapMaybe (refFromExpression position) te.elements)
      ExpressionArray ae ->
        listToMaybe (mapMaybe (refFromExpression position) ae.elements)
      _ -> Nothing

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
    collectExpressionOccurrences nextStatement.value index
  _ -> index

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
    foldr (collectExpressionOccurrences . (.source)) (collectBlockOccurrences fe.body index) fe.inBindings
  ExpressionBlock be ->
    collectBlockOccurrences be.block index
  ExpressionTuple te ->
    foldr collectExpressionOccurrences index te.elements
  ExpressionArray ae ->
    foldr collectExpressionOccurrences index ae.elements
  _ -> index

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

spanContains :: SourceSpan -> Position -> Bool
spanContains sourceSpan position =
  ( sourceSpan.start.line < position.line
      || sourceSpan.start.line == position.line && sourceSpan.start.column <= position.column
  )
    && ( position.line < sourceSpan.end.line
           || position.line == sourceSpan.end.line && position.column <= sourceSpan.end.column
       )

orElse :: Maybe a -> Maybe a -> Maybe a
orElse Nothing b = b
orElse a _ = a
