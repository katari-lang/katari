module Katari.Typechecker.AgentGraph
  ( agentSCCs,
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
            qualifiedName <- declarationQualifiedName moduleName declaration,
            let dependencies = Set.intersection declSet (declarationDependencies moduleName declaration)
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

-- | Collect intra-module dependencies referenced anywhere in a
-- declaration: body expressions, type annotations, constructor
-- patterns, and request references.
declarationDependencies :: Text -> Declaration Identified -> Set QualifiedName
declarationDependencies moduleName = \case
  DeclarationAgent declaration ->
    collectFromParameterBindings declaration.parameters
      <> collectFromOptionalType declaration.returnType
      <> collectFromOptionalRequests declaration.withRequests
      <> collectFromBlock declaration.body
  DeclarationRequest declaration ->
    collectFromParameterBindings declaration.parameters
      <> collectFromSyntacticType declaration.returnType
  DeclarationExternalAgent declaration ->
    collectFromParameterBindings declaration.parameters
      <> collectFromSyntacticType declaration.returnType
      <> collectFromRequests declaration.withRequests
  DeclarationPrimAgent declaration ->
    collectFromParameterBindings declaration.parameters
      <> collectFromSyntacticType declaration.returnType
      <> collectFromRequests declaration.withRequests
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

    collectFromConstructorRef :: NameRef Identified ConstructorRef -> Set QualifiedName
    collectFromConstructorRef nameRef = case nameRef.resolution of
      Just qualifiedName
        | isLocal qualifiedName -> Set.singleton qualifiedName
      _ -> Set.empty

    collectFromTypeRef :: NameRef Identified TypeRef -> Set QualifiedName
    collectFromTypeRef nameRef = case nameRef.resolution of
      Just qualifiedName
        | isLocal qualifiedName -> Set.singleton qualifiedName
      _ -> Set.empty

    collectFromSyntacticType :: SyntacticType Identified -> Set QualifiedName
    collectFromSyntacticType = \case
      TypePrimitive _ -> Set.empty
      TypeName TypeNameNode {name} -> collectFromTypeRef name
      TypeQualified QualifiedTypeNode {target} -> collectFromTypeRef target
      TypeFunction FunctionTypeNode {parameterTypes, returnType, withRequests} ->
        Set.unions (map (collectFromSyntacticType . snd) parameterTypes)
          <> collectFromSyntacticType returnType
          <> collectFromRequests withRequests
      TypeArray ArrayTypeNode {elementType} -> collectFromSyntacticType elementType
      TypeTuple TupleTypeNode {elementTypes} -> Set.unions (map collectFromSyntacticType elementTypes)
      TypeUnion TypeUnionNode {branches} -> Set.unions (map collectFromSyntacticType branches)
      TypeLiteral _ -> Set.empty
      TypeNever _ -> Set.empty
      TypeUnknown _ -> Set.empty
      TypeFunctionAny _ -> Set.empty
      TypeRecord RecordTypeNode {valueType} -> collectFromSyntacticType valueType

    collectFromOptionalType :: Maybe (SyntacticType Identified) -> Set QualifiedName
    collectFromOptionalType = maybe Set.empty collectFromSyntacticType

    collectFromRequests :: [SyntacticRequest Identified] -> Set QualifiedName
    collectFromRequests = Set.unions . map collectFromRequest

    collectFromOptionalRequests :: Maybe [SyntacticRequest Identified] -> Set QualifiedName
    collectFromOptionalRequests = maybe Set.empty collectFromRequests

    collectFromRequest :: SyntacticRequest Identified -> Set QualifiedName
    collectFromRequest SyntacticRequest {name} = case name.resolution of
      Just qualifiedName | isLocal qualifiedName -> Set.singleton qualifiedName
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
          <> collectFromOptionalType statement.returnType
          <> collectFromOptionalRequests statement.withRequests
          <> collectFromBlock statement.body
      StatementReturn statement -> collectFromExpression statement.value
      StatementExpression expression -> collectFromExpression expression
      StatementNext statement ->
        collectFromExpression statement.value
          <> Set.unions (map collectFromModifier statement.modifiers)
      StatementBreak statement -> collectFromExpression statement.value
      StatementForNext statement -> Set.unions (map collectFromModifier statement.modifiers)
      StatementForBreak statement -> collectFromExpression statement.value
      StatementError _ -> Set.empty

    collectFromExpression :: Expression Identified -> Set QualifiedName
    collectFromExpression = \case
      ExpressionLiteral _ -> Set.empty
      ExpressionVariable expression -> collectFromVariableRef expression.name
      ExpressionTuple expression -> Set.unions (map collectFromExpression expression.elements)
      ExpressionArray expression -> Set.unions (map collectFromExpression expression.elements)
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
          <> maybe Set.empty collectFromBlock expression.thenBlock
      ExpressionBlock expression -> collectFromBlock expression.block
      ExpressionHandle expression ->
        Set.unions (map collectFromStateVariable expression.stateVariables)
          <> Set.unions (map collectFromRequestHandler expression.handlers)
          <> maybe Set.empty collectFromThenClause expression.thenClause
          <> collectFromBlock expression.body
      ExpressionParTuple expression -> Set.unions (map collectFromExpression expression.elements)
      ExpressionParArray expression -> Set.unions (map collectFromExpression expression.elements)
      ExpressionFieldAccess expression -> collectFromExpression expression.object
      ExpressionIndexAccess expression ->
        collectFromExpression expression.array <> collectFromExpression expression.index
      ExpressionTemplate expression -> Set.unions (map collectFromTemplateElement expression.elements)
      ExpressionQualifiedReference expression -> collectFromVariableRef expression.target

    collectFromCallArgument :: CallArgument Identified -> Set QualifiedName
    collectFromCallArgument argument = collectFromExpression argument.value

    collectFromPattern :: Pattern Identified -> Set QualifiedName
    collectFromPattern = \case
      PatternVariable VariablePattern {typeAnnotation} -> collectFromOptionalType typeAnnotation
      PatternQualifiedConstructor pattern' ->
        collectFromConstructorRef pattern'.constructorName
          <> Set.unions (map (collectFromPattern . snd) pattern'.parameters)
      PatternTuple pattern' -> Set.unions (map collectFromPattern pattern'.elements)
      PatternWildcard WildcardPattern {typeAnnotation} -> collectFromOptionalType typeAnnotation
      PatternLiteral _ -> Set.empty
      PatternType pattern' -> collectFromPattern pattern'.inner
      PatternRecord pattern' -> Set.unions (map (collectFromPattern . snd) pattern'.entries)

    collectFromParameterBindings :: [ParameterBinding Identified] -> Set QualifiedName
    collectFromParameterBindings = Set.unions . map collectFromParameterBinding

    collectFromParameterBinding :: ParameterBinding Identified -> Set QualifiedName
    collectFromParameterBinding binding = collectFromPattern binding.pattern

    collectFromModifier :: Modifier Identified -> Set QualifiedName
    collectFromModifier modifier = collectFromExpression modifier.value

    collectFromStateVariable :: StateVariableBinding Identified -> Set QualifiedName
    collectFromStateVariable binding =
      collectFromOptionalType binding.typeAnnotation
        <> collectFromExpression binding.initial

    collectFromRequestHandler :: RequestHandler Identified -> Set QualifiedName
    collectFromRequestHandler handler =
      collectFromParameterBindings handler.parameters
        <> collectFromOptionalType handler.returnType
        <> collectFromBlock handler.body

    collectFromThenClause :: (Maybe (Pattern Identified), Block Identified) -> Set QualifiedName
    collectFromThenClause (maybePattern, block) =
      maybe Set.empty collectFromPattern maybePattern
        <> collectFromBlock block

    collectFromForInBinding :: ForInBinding Identified -> Set QualifiedName
    collectFromForInBinding binding =
      collectFromPattern binding.pattern <> collectFromExpression binding.source

    collectFromForVarBinding :: ForVarBinding Identified -> Set QualifiedName
    collectFromForVarBinding binding =
      collectFromOptionalType binding.typeAnnotation
        <> collectFromExpression binding.initial

    collectFromCaseArm :: CaseArm Identified -> Set QualifiedName
    collectFromCaseArm arm =
      collectFromPattern arm.pattern <> collectFromBlock arm.body

    collectFromTemplateElement :: TemplateElement Identified -> Set QualifiedName
    collectFromTemplateElement = \case
      TemplateElementString _ -> Set.empty
      TemplateElementExpression element -> collectFromExpression element.value
