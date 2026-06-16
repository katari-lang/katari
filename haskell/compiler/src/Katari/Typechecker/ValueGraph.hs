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
import Data.Set (Set)
import Data.Set qualified as Set
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Id (VariableResolution (..))
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.QualifiedName (QualifiedName (..))

-- | One node of the graph: a top-level agent, carrying its qualified name, home module, and the
-- declaration itself (so the driver can check it without a second lookup).
data ValueNode = ValueNode
  { qualifiedName :: QualifiedName,
    moduleName :: ModuleName,
    declaration :: AgentDeclaration Identified
  }

-- | Every top-level @agent@ across all modules, in module-then-declaration order.
topLevelAgents :: Map ModuleName (Module Identified) -> List ValueNode
topLevelAgents modules =
  [ ValueNode
      { qualifiedName = QualifiedName {moduleName = moduleName, name = declaration.name},
        moduleName = moduleName,
        declaration = declaration
      }
    | (moduleName, module') <- Map.toList modules,
      DeclarationAgent declaration <- module'.declarations
  ]

-- | The dependency-first strongly-connected components of the value graph. An edge @a -> b@ means
-- agent @a@ references agent @b@; 'stronglyConnComp' orders the components so that a component is
-- listed before any component that depends on it (callees before callers).
valueSCCs :: Map ModuleName (Module Identified) -> List (SCC ValueNode)
valueSCCs modules = stronglyConnComp (valueGraph modules)

-- | The graph as 'stronglyConnComp' input: each agent with its key and the keys of the top-level
-- agents it references (references to non-agent values are dropped — they are not nodes).
valueGraph :: Map ModuleName (Module Identified) -> List (ValueNode, QualifiedName, List QualifiedName)
valueGraph modules =
  [ (node, node.qualifiedName, Set.toList (Set.intersection (referencesInAgent node.declaration) agentNames))
    | node <- nodes
  ]
  where
    nodes = topLevelAgents modules
    agentNames = Set.fromList [node.qualifiedName | node <- nodes]

------------------------------------------------------------------------------------------------
-- Reference collection: every top-level value an agent's body (including nested agent bodies)
-- refers to. Only 'VariableResolutionQualifiedName' references are top-level; locals are skipped.
-- Patterns bind / match against constructors and types, never an agent value, so they contribute no
-- edges and are not traversed.
------------------------------------------------------------------------------------------------

referencesInAgent :: AgentDeclaration Identified -> Set QualifiedName
referencesInAgent declaration = referencesInBlock declaration.body

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
  ExpressionBlock expression -> referencesInBlock expression.block
  ExpressionFieldAccess expression -> referencesInExpression expression.object
  ExpressionTypeApplication expression -> referencesInExpression expression.callee
  ExpressionTemplate expression -> foldMap referencesInTemplateElement expression.elements
  ExpressionHandler expression -> referencesInHandler expression
  ExpressionQualifiedReference expression -> referenceOf expression.variableReference

referencesInCallArgument :: CallArgument Identified -> Set QualifiedName
referencesInCallArgument argument = referencesInExpression argument.value

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
