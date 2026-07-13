-- | The value dependency graph and its strongly-connected components — the scaffolding the Phase C
-- driver walks to grow the value environment in dependency order.
--
-- Typechecking a value (an @agent@'s scheme, when its return / effect is inferred) needs the schemes
-- of the values it calls, so definitions must be checked dependency-first. The nodes are the
-- top-level @agent@ declarations (the only values whose scheme can require checking a body); their
-- edges are the other top-level agents they reference. References to constructors / requests /
-- externals / primitives are not edges: those schemes are signature-determined, so they impose no
-- ordering.
--
-- 'valueSCCs' returns the components in dependency-first topological order. A 'CyclicSCC' is a
-- (mutually) recursive group: the driver will require an explicit return / effect annotation on its
-- members (inference does not cross a recursion). This module only builds and orders the graph; it
-- does not check anything or enforce that policy.
module Katari.Typechecker.ValueGraph where

import Data.Graph (SCC (..), stronglyConnComp)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Id (VariableResolution (..))
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.QualifiedName (QualifiedName (..))

-- | Every top-level value declaration is a node. Only an @agent@ has a body whose checking can
-- depend on other values' schemes; the rest are signature-determined, so they reference no value
-- and are always acyclic sources — but they are still nodes, so the driver seeds every value's
-- scheme through one uniform walk.
data ValueDeclaration
  = ValueAgent (AgentDeclaration Identified)
  | ValueData (DataDeclaration Identified)
  | ValueExternal (ExternalAgentDeclaration Identified)
  | ValuePrimitive (PrimitiveAgentDeclaration Identified)
  | ValueRequest (RequestDeclaration Identified)

-- | One node of the graph: a top-level value, carrying its identifier-resolved qualified name and
-- the declaration itself (so the driver can check it without a second lookup).
data ValueNode = ValueNode
  { qualifiedName :: QualifiedName,
    declaration :: ValueDeclaration
  }

-- | The value node a declaration contributes, if any (synonyms / imports / errors are not values).
-- Identity comes from the identifier-resolved defining reference, never from the declaration's name.
valueNodeOf :: Declaration Identified -> Maybe ValueNode
valueNodeOf = \case
  DeclarationAgent declaration -> Just (node declaration.variableReference (ValueAgent declaration))
  DeclarationData declaration -> Just (node declaration.variableReference (ValueData declaration))
  DeclarationExternalAgent declaration -> Just (node declaration.variableReference (ValueExternal declaration))
  DeclarationPrimitiveAgent declaration -> Just (node declaration.variableReference (ValuePrimitive declaration))
  DeclarationRequest declaration -> Just (node declaration.variableReference (ValueRequest declaration))
  _ -> Nothing
  where
    node reference value = ValueNode {qualifiedName = referencedVariableName reference, declaration = value}

-- | Every top-level value across all modules, in module-then-declaration order.
topLevelValues :: Map ModuleName (Module Identified) -> List ValueNode
topLevelValues modules = mapMaybe valueNodeOf [declaration | module' <- Map.elems modules, declaration <- module'.declarations]

-- | The dependency-first strongly-connected components of the value graph. An edge @a -> b@ means
-- value @a@'s body references value @b@; 'stronglyConnComp' orders the components so that a
-- component is listed before any component that depends on it (callees before callers).
valueSCCs :: Map ModuleName (Module Identified) -> List (SCC ValueNode)
valueSCCs modules = stronglyConnComp (valueGraph modules)

-- | The value references a node's body makes. Only an agent has a body; signature-determined values
-- reference no other value's scheme.
referencesInValue :: ValueDeclaration -> Set QualifiedName
referencesInValue = \case
  ValueAgent declaration -> referencesInBlock declaration.body
  _ -> Set.empty

-- | The graph as 'stronglyConnComp' input: each value with its key and the keys of the values it
-- references (restricted to value nodes; a reference to anything else is dropped).
valueGraph :: Map ModuleName (Module Identified) -> List (ValueNode, QualifiedName, List QualifiedName)
valueGraph modules =
  [ (node, node.qualifiedName, Set.toList (Set.intersection (referencesInValue node.declaration) valueNames))
    | node <- nodes
  ]
  where
    nodes = topLevelValues modules
    valueNames = Set.fromList [node.qualifiedName | node <- nodes]

------------------------------------------------------------------------------------------------
-- Reference collection: every top-level value an agent's body (including nested agent bodies)
-- refers to. Only 'VariableResolutionQualifiedName' references are top-level; locals are skipped.
-- Patterns bind / match against constructors and types, never an agent value, so they contribute no
-- edges and are not traversed.
------------------------------------------------------------------------------------------------

referenceOf :: Reference Identified VariableReference -> Set QualifiedName
referenceOf reference = case reference.resolution of
  Just (VariableResolutionQualifiedName qualifiedName) -> Set.singleton qualifiedName
  _ -> Set.empty

referencesInBlock :: Block Identified -> Set QualifiedName
referencesInBlock block = foldMap referencesInStatement block.statements <> foldMap referencesInExpression block.returnExpression

referencesInStatement :: Statement Identified -> Set QualifiedName
referencesInStatement = \case
  StatementLet statement -> referencesInExpression statement.value
  StatementUse statement -> referencesInExpression statement.provider <> referencesInBlock statement.body
  -- A nested agent's references are its enclosing top-level agent's dependencies (checking the
  -- enclosing body checks the nested body).
  StatementAgent statement -> referencesInBlock statement.body
  StatementReturn statement -> referencesInExpression statement.value
  StatementExpression expression -> referencesInExpression expression
  StatementNext statement -> referencesInExpression statement.value <> foldMap referencesInModifier statement.modifiers
  StatementBreak statement -> referencesInExpression statement.value
  StatementForNext statement -> referencesInExpression statement.value <> foldMap referencesInModifier statement.modifiers
  StatementForBreak statement -> referencesInExpression statement.value
  StatementFinally statement -> referencesInBlock statement.body
  StatementError _ -> Set.empty

referencesInModifier :: Modifier Identified -> Set QualifiedName
referencesInModifier modifier = referencesInExpression modifier.value

referencesInExpression :: Expression Identified -> Set QualifiedName
referencesInExpression = \case
  ExpressionLiteral _ -> Set.empty
  ExpressionVariable expression -> referenceOf expression.variableReference
  ExpressionTuple expression -> foldMap referencesInExpression expression.elements
  ExpressionRecord expression -> foldMap (\entry -> referencesInExpression entry.value) expression.entries
  ExpressionCall expression -> referencesInExpression expression.callee <> foldMap referencesInCallArgument expression.arguments
  ExpressionBinaryOperator expression -> referencesInExpression expression.left <> referencesInExpression expression.right
  ExpressionUnaryOperator expression -> referencesInExpression expression.operand
  ExpressionIf expression -> referencesInExpression expression.condition <> referencesInBlock expression.thenBlock <> foldMap referencesInBlock expression.elseBlock
  ExpressionMatch expression -> referencesInExpression expression.subject <> foldMap referencesInCaseArm expression.cases
  ExpressionFor expression ->
    referencesInExpression expression.inBinding.source
      <> foldMap referencesInVariableBinding expression.varBindings
      <> referencesInBlock expression.body
      <> foldMap referencesInThenClause expression.thenClause
  ExpressionForever expression ->
    foldMap referencesInVariableBinding expression.varBindings
      <> referencesInBlock expression.body
  ExpressionBlock expression -> referencesInBlock expression.block
  ExpressionFieldAccess expression -> referencesInExpression expression.object
  ExpressionTypeApplication expression -> referencesInExpression expression.callee
  ExpressionTemplate expression -> foldMap referencesInTemplateElement expression.elements
  ExpressionHandler expression -> referencesInHandler expression
  ExpressionQualifiedReference expression -> referenceOf expression.variableReference

referencesInCallArgument :: CallArgument Identified -> Set QualifiedName
referencesInCallArgument argument = case argument.value of
  ArgumentHole _ -> Set.empty
  ArgumentExpression expression -> referencesInExpression expression

referencesInCaseArm :: CaseArm Identified -> Set QualifiedName
referencesInCaseArm arm = referencesInBlock arm.body

referencesInVariableBinding :: VariableBinding Identified -> Set QualifiedName
referencesInVariableBinding binding = referencesInExpression binding.initial

referencesInThenClause :: ThenClause Identified -> Set QualifiedName
referencesInThenClause clause = referencesInBlock clause.body

referencesInTemplateElement :: TemplateElement Identified -> Set QualifiedName
referencesInTemplateElement = \case
  TemplateElementString _ -> Set.empty
  TemplateElementExpression element -> referencesInExpression element.value

referencesInHandler :: HandlerExpression Identified -> Set QualifiedName
referencesInHandler handler =
  foldMap referencesInVariableBinding handler.stateVariables
    <> foldMap referencesInRequestHandler handler.handlers
    <> foldMap referencesInThenClause handler.thenClause

referencesInRequestHandler :: RequestHandler Identified -> Set QualifiedName
referencesInRequestHandler handler = referencesInBlock handler.body
