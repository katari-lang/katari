module Katari.Typechecker.AgentGraph
  ( agentSCCs,
    declarationDependencies,
  )
where

import Data.Graph (SCC (..), stronglyConnComp)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.AST
import Katari.Id (QualifiedName (..), VariableResolution (..))

-- | Compute strongly connected components of the intra-module agent call
-- graph. Each SCC is a set of top-level callable QualifiedNames that are
-- mutually recursive. Non-recursive agents form singleton SCCs.
-- Returns SCCs in topological order (callees before callers).
agentSCCs :: Text -> Module Identified -> [Set QualifiedName]
agentSCCs moduleName moduleAST =
  let declarations = moduleAST.declarations
      declQNames = concatMap (declarationQualifiedName moduleName) declarations
      declSet = Set.fromList declQNames
      edges =
        [ (qualifiedName, qualifiedName, Set.toList dependencies)
          | declaration <- declarations,
            let dependencies =
                  Set.intersection
                    declSet
                    (declarationDependencies moduleName declaration),
            qualifiedName <- declarationQualifiedName moduleName declaration
        ]
      sccs = stronglyConnComp edges
   in map sccToSet sccs

sccToSet :: SCC QualifiedName -> Set QualifiedName
sccToSet = \case
  AcyclicSCC qualifiedName -> Set.singleton qualifiedName
  CyclicSCC qualifiedNames -> Set.fromList qualifiedNames

declarationQualifiedName :: Text -> Declaration Identified -> [QualifiedName]
declarationQualifiedName moduleName = \case
  DeclarationAgent declaration -> resolveVarToQName moduleName declaration.name
  DeclarationRequest declaration -> resolveVarToQName moduleName declaration.name
  DeclarationExternalAgent declaration -> resolveVarToQName moduleName declaration.name
  DeclarationPrimAgent declaration -> resolveVarToQName moduleName declaration.name
  DeclarationData declaration -> resolveVarToQName moduleName declaration.name
  DeclarationTypeSynonym _ -> []
  DeclarationImport _ -> []
  DeclarationError _ -> []

resolveVarToQName :: Text -> NameRef Identified VariableRef -> [QualifiedName]
resolveVarToQName moduleName nameRef = case nameRef.resolution of
  Just (ResolvedTopLevel qualifiedName)
    | qualifiedName.module_ == moduleName -> [qualifiedName]
  _ -> []

-- | Collect intra-module call-graph dependencies referenced in a
-- declaration. Only 'VariableRef' edges are included (agent A calls
-- agent B). Type references, constructor references, and request
-- references are excluded because their types are fully determined by
-- their declarations (no inference needed), so they cannot form
-- genuine mutual-recursion cycles with agents.
declarationDependencies :: Text -> Declaration Identified -> Set QualifiedName
declarationDependencies moduleName = \case
  DeclarationAgent declaration ->
    collectFromParameterBindings declaration.parameters
      <> collectFromBlock declaration.body
  DeclarationRequest _ -> Set.empty
  DeclarationExternalAgent _ -> Set.empty
  DeclarationPrimAgent _ -> Set.empty
  DeclarationData _ -> Set.empty
  DeclarationTypeSynonym _ -> Set.empty
  DeclarationImport _ -> Set.empty
  DeclarationError _ -> Set.empty
  where
    isLocal :: QualifiedName -> Bool
    isLocal qualifiedName = qualifiedName.module_ == moduleName

    collectFromVariableRef :: NameRef Identified VariableRef -> Set QualifiedName
    collectFromVariableRef nameRef = case nameRef.resolution of
      Just (ResolvedTopLevel qualifiedName)
        | isLocal qualifiedName -> Set.singleton qualifiedName
      _ -> Set.empty

    collectFromBlock :: Block Identified -> Set QualifiedName
    collectFromBlock Block {statements, returnExpression} =
      Set.unions (map collectFromStatement statements)
        <> maybe Set.empty collectFromExpression returnExpression

    collectFromStatement :: Statement Identified -> Set QualifiedName
    collectFromStatement = \case
      StatementLet statement ->
        collectFromPattern statement.pattern <> collectFromExpression statement.value
      StatementAgent statement ->
        collectFromParameterBindings statement.parameters
          <> collectFromBlock statement.body
      StatementReturn statement -> collectFromExpression statement.value
      StatementExpression expression -> collectFromExpression expression
      StatementNext statement ->
        collectFromExpression statement.value
          <> Set.unions (map collectFromModifier statement.modifiers)
      StatementBreak statement -> collectFromExpression statement.value
      StatementForNext statement ->
        collectFromExpression statement.value
          <> Set.unions (map collectFromModifier statement.modifiers)
      StatementForBreak statement -> collectFromExpression statement.value
      StatementError _ -> Set.empty

    collectFromExpression :: Expression Identified -> Set QualifiedName
    collectFromExpression = \case
      ExpressionLiteral _ -> Set.empty
      ExpressionVariable expression -> collectFromVariableRef expression.name
      ExpressionTuple expression -> Set.unions (map collectFromExpression expression.elements)
      ExpressionRecord expression -> Set.unions (map (collectFromExpression . snd) expression.entries)
      ExpressionCall expression ->
        collectFromExpression expression.callee
          <> Set.unions (map collectFromCallArgument expression.arguments)
      ExpressionBinaryOperator expression ->
        collectFromExpression expression.left <> collectFromExpression expression.right
      ExpressionUnaryOperator expression -> collectFromExpression expression.operand
      ExpressionIf expression ->
        collectFromExpression expression.condition
          <> collectFromBlock expression.thenBlock
          <> maybe Set.empty collectFromBlock expression.elseBlock
      ExpressionMatch expression ->
        collectFromExpression expression.subject
          <> Set.unions (map collectFromCaseArm expression.cases)
      ExpressionFor expression ->
        Set.unions (map collectFromForInBinding expression.inBindings)
          <> Set.unions (map collectFromForVarBinding expression.varBindings)
          <> collectFromBlock expression.body
          <> maybe Set.empty collectFromThenClause expression.thenBlock
      ExpressionBlock expression -> collectFromBlock expression.block
      ExpressionHandle expression ->
        Set.unions (map collectFromStateVariable expression.stateVariables)
          <> Set.unions (map collectFromHandlerBody expression.handlers)
          <> maybe Set.empty collectFromThenClause expression.thenClause
          <> collectFromBlock expression.body
      ExpressionUse expression -> collectFromExpression expression.expr <> collectFromBlock expression.body
      ExpressionParTuple expression -> Set.unions (map collectFromExpression expression.elements)
      ExpressionFieldAccess expression -> collectFromExpression expression.object
      ExpressionTypeApplication expression -> collectFromExpression expression.callee
      ExpressionTemplate expression -> Set.unions (map collectFromTemplateElement expression.elements)
      ExpressionQualifiedReference expression -> collectFromVariableRef expression.target

    collectFromCallArgument :: CallArgument Identified -> Set QualifiedName
    collectFromCallArgument argument = collectFromExpression argument.value

    collectFromPattern :: Pattern Identified -> Set QualifiedName
    collectFromPattern = \case
      PatternVariable _ -> Set.empty
      PatternQualifiedConstructor pattern' ->
        Set.unions (map (collectFromPattern . snd) pattern'.parameters)
      PatternTuple pattern' -> Set.unions (map collectFromPattern pattern'.elements)
      PatternWildcard _ -> Set.empty
      PatternLiteral _ -> Set.empty
      PatternType pattern' -> collectFromPattern pattern'.inner
      PatternRecord pattern' -> Set.unions (map (collectFromPattern . snd) pattern'.entries)

    collectFromParameterBindings :: [ParameterBinding Identified] -> Set QualifiedName
    collectFromParameterBindings = Set.unions . map collectFromParameterBinding

    -- Parameters are plain bindings (name + optional type + literal
    -- default); none of those reference a callable, so a parameter never
    -- contributes an edge to the agent-dependency graph.
    collectFromParameterBinding :: ParameterBinding Identified -> Set QualifiedName
    collectFromParameterBinding _ = Set.empty

    collectFromModifier :: Modifier Identified -> Set QualifiedName
    collectFromModifier modifier = collectFromExpression modifier.value

    collectFromStateVariable :: StateVariableBinding Identified -> Set QualifiedName
    collectFromStateVariable binding = collectFromExpression binding.initial

    collectFromHandlerBody :: RequestHandler Identified -> Set QualifiedName
    collectFromHandlerBody handler =
      collectFromParameterBindings handler.parameters
        <> collectFromBlock handler.body

    collectFromThenClause :: (Maybe (Pattern Identified), Block Identified) -> Set QualifiedName
    collectFromThenClause (maybePattern, block) =
      maybe Set.empty collectFromPattern maybePattern
        <> collectFromBlock block

    collectFromForInBinding :: ForInBinding Identified -> Set QualifiedName
    collectFromForInBinding binding =
      collectFromPattern binding.pattern <> collectFromExpression binding.source

    collectFromForVarBinding :: ForVarBinding Identified -> Set QualifiedName
    collectFromForVarBinding binding = collectFromExpression binding.initial

    collectFromCaseArm :: CaseArm Identified -> Set QualifiedName
    collectFromCaseArm arm =
      collectFromPattern arm.pattern <> collectFromBlock arm.body

    collectFromTemplateElement :: TemplateElement Identified -> Set QualifiedName
    collectFromTemplateElement = \case
      TemplateElementString _ -> Set.empty
      TemplateElementExpression element -> collectFromExpression element.value
