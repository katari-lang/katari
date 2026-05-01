-- | Typechecker phase 4: Zonk — Solver の置換結果を AST に焼き込む。
--
-- Input  : 'IdentifierResult' (Identifier 段階の VariableData / TypeData / ModuleData
--          引き当て用)、'ConstraintGenResult' (Constrained AST と
--          'typeEnvironment')、'SolverResult' (substitution maps)。
-- Output : 'ZonkResult' — Zonked AST、解決済 type environment、Solver 契約逸脱
--          検知用エラー集合。
--
-- 設計仮定:
--
--   * Solver の出力は **total** : 'typeSubstitution' / 'effectSubstitution' は
--     ConstraintGenerator が allocate した全 TypeVarId / EffectVarId に対し
--     entry を持つ。Zonker から見て lookup miss は発生しない想定。
--   * 万一の Solver bug (lookup miss) は 'ZonkErrorMissingTypeVar' /
--     'ZonkErrorMissingEffectVar' で検知し、'SemanticTypeUnknown' /
--     空 effect set にフォールバックして AST 生成は中断しない。
--   * Zonked AST の Expression / Pattern metadata は @SemanticType Resolved@
--     を直接保持する。'SemanticEffect' Resolved は @effectVars = Set.empty@ を
--     構築側で強制する。
module Katari.Typechecker.Zonker
  ( -- * Result
    ZonkResult (..),
    ZonkError (..),

    -- * Diagnostics
    toDiagnostic,

    -- * Entry
    zonk,
  )
where

import Control.Monad (foldM)
import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Control.Monad.State.Strict (State, modify, runState)
import Control.Monad.Trans (lift)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Katari.AST
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.Typechecker.ConstraintGenerator (ConstraintGenResult (..))
import Katari.Typechecker.Identifier
  ( ConstructorData (..),
    ConstructorId,
    IdentifierResult (..),
    ModuleId,
    RequestData (..),
    RequestId,
    TypeData (..),
    TypeId,
    VariableData (..),
    VariableId,
  )
import Katari.Typechecker.NormalizedType (denormalise)
import Katari.Typechecker.SemanticType
  ( EffectVarId (..),
    Resolved,
    SemanticEffect (..),
    SemanticType (..),
    TypeVarId (..),
    Unresolved,
    traverseSemanticChildren,
  )
import Katari.Typechecker.Solver (SolverResult (..))

-- The 'Zonked' phase reuses the 'NameMeta Zonked s' family for name
-- resolution (identical to 'Identified' / 'Constrained'), and stores the
-- resolved @SemanticType Resolved@ on each expression / pattern via the
-- @ExprType Zonked@ / @PatType Zonked@ instances defined in
-- 'Katari.Typechecker.SemanticType'.

-- ===========================================================================
-- Result types
-- ===========================================================================

data ZonkResult = ZonkResult
  { zonkedModules :: !(Map ModuleId (Module Zonked)),
    zonkedTypeEnvironment :: !(Map VariableId (SemanticType Resolved)),
    -- | Passthroughs from 'IdentifierResult' so 'Katari.Lowering' and
    -- 'Katari.Schema' can resolve qualified names and look up
    -- 'RequestId' / 'ConstructorId' → 'VariableId' cross-references
    -- without re-threading 'IdentifierResult' alongside 'ZonkResult'.
    zonkedVariables :: !(Map VariableId VariableData),
    zonkedTypes :: !(Map TypeId TypeData),
    zonkedRequests :: !(Map RequestId RequestData),
    zonkedConstructors :: !(Map ConstructorId ConstructorData),
    -- | Inverse maps built at ZonkResult construction time. Allow O(1)
    -- lookup of RequestId / ConstructorId by the call-side VariableId
    -- without O(n) scans through 'zonkedRequests' / 'zonkedConstructors'.
    zonkedRequestByVariable :: !(Map VariableId RequestId),
    zonkedConstructorByVariable :: !(Map VariableId ConstructorId),
    -- | Solver 契約逸脱 (lookup miss) 検知用。通常 path では空のはず。
    zonkErrors :: ![ZonkError]
  }
  deriving (Show)

data ZonkError where
  ZonkErrorMissingTypeVar :: SourceSpan -> TypeVarId -> ZonkError
  ZonkErrorMissingEffectVar :: SourceSpan -> EffectVarId -> ZonkError

deriving instance Eq ZonkError

deriving instance Show ZonkError

-- | Convert a 'ZonkError' to a unified 'Diagnostic'. Codes K0250-K0279
-- are reserved for the zonker. These errors indicate a Solver-contract
-- violation (the substitution should be total) and should be
-- treated as internal compiler errors.
toDiagnostic :: ZonkError -> Diagnostic
toDiagnostic = \case
  ZonkErrorMissingTypeVar sourceSpan (TypeVarId typeVar) ->
    diagnosticError
      "K0250"
      ( "internal: solver substitution missing for type variable α"
          <> Text.pack (show typeVar)
      )
      sourceSpan
  ZonkErrorMissingEffectVar sourceSpan (EffectVarId effectVar) ->
    diagnosticError
      "K0251"
      ( "internal: solver substitution missing for effect variable ε"
          <> Text.pack (show effectVar)
      )
      sourceSpan

-- ===========================================================================
-- Zonker monad
-- ===========================================================================

type Zonk = ReaderT SolverResult (State [ZonkError])

recordZonkError :: ZonkError -> Zonk ()
recordZonkError err = lift (modify (err :))

-- ===========================================================================
-- Type / effect substitution
-- ===========================================================================

-- | Zonk a 'SemanticType Unresolved' to 'SemanticType Resolved'. Variables
-- are looked up in the solver's type substitution; structural recursion is
-- delegated to 'traverseSemanticChildren' (the bulk of what used to be a
-- 14-case @\\case@).
zonkType :: SourceSpan -> SemanticType Unresolved -> Zonk (SemanticType Resolved)
zonkType sourceSpan = \case
  SemanticTypeVariable typeVar -> do
    solverResult <- ask
    case Map.lookup typeVar solverResult.typeSubstitution of
      Just normalizedType -> pure (denormalise normalizedType)
      Nothing -> do
        recordZonkError (ZonkErrorMissingTypeVar sourceSpan typeVar)
        pure SemanticTypeUnknown
  t -> traverseSemanticChildren (zonkType sourceSpan) (zonkEffect sourceSpan) t

zonkEffect :: SourceSpan -> SemanticEffect Unresolved -> Zonk (SemanticEffect Resolved)
zonkEffect sourceSpan (SemanticEffect vars reqs) = do
  expanded <- foldM addEffectVar reqs (Set.toList vars)
  pure (SemanticEffect Set.empty expanded)
  where
    addEffectVar acc effectVar = do
      solverResult <- ask
      case Map.lookup effectVar solverResult.effectSubstitution of
        Just resolvedReqs -> pure (Set.union acc resolvedReqs)
        Nothing -> do
          recordZonkError (ZonkErrorMissingEffectVar sourceSpan effectVar)
          pure acc

-- ===========================================================================
-- AST walker
-- ===========================================================================

walkModule :: Module Constrained -> Zonk (Module Zonked)
walkModule Module {moduleName, declarations, sourceSpan} = do
  declarations' <- mapM walkDeclaration declarations
  pure Module {moduleName = moduleName, declarations = declarations', sourceSpan = sourceSpan}

walkDeclaration :: Declaration Constrained -> Zonk (Declaration Zonked)
walkDeclaration = \case
  DeclarationAgent decl -> DeclarationAgent <$> walkAgentDecl decl
  DeclarationRequest decl -> DeclarationRequest <$> walkRequestDecl decl
  DeclarationExternalAgent decl -> DeclarationExternalAgent <$> walkExternalAgentDecl decl
  DeclarationData decl -> DeclarationData <$> walkDataDecl decl
  DeclarationTypeSynonym decl -> DeclarationTypeSynonym <$> walkTypeSynonymDecl decl
  DeclarationImport decl -> pure (DeclarationImport (retagImportDeclaration decl))
  DeclarationError span_ -> pure (DeclarationError span_)

walkAgentDecl :: AgentDeclaration Constrained -> Zonk (AgentDeclaration Zonked)
walkAgentDecl AgentDeclaration {annotation, name, parameters, returnType, withEffects, body, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  body' <- walkBlock body
  pure
    AgentDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        parameters = parameters',
        returnType = fmap retagSyntacticType returnType,
        withEffects = fmap (fmap retagSyntacticRequest) withEffects,
        body = body',
        sourceSpan = sourceSpan
      }

walkRequestDecl :: RequestDeclaration Constrained -> Zonk (RequestDeclaration Zonked)
walkRequestDecl RequestDeclaration {annotation, name, parameters, returnType, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  pure
    RequestDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        parameters = parameters',
        returnType = retagSyntacticType returnType,
        sourceSpan = sourceSpan
      }

walkExternalAgentDecl :: ExternalAgentDeclaration Constrained -> Zonk (ExternalAgentDeclaration Zonked)
walkExternalAgentDecl ExternalAgentDeclaration {annotation, name, parameters, returnType, withEffects, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  pure
    ExternalAgentDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        parameters = parameters',
        returnType = retagSyntacticType returnType,
        withEffects = map retagSyntacticRequest withEffects,
        sourceSpan = sourceSpan
      }

walkDataDecl :: DataDeclaration Constrained -> Zonk (DataDeclaration Zonked)
walkDataDecl DataDeclaration {annotation, name, typeName, parameters, sourceSpan} = do
  parameters' <- mapM walkDataParameter parameters
  pure
    DataDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        typeName = retagNameRef typeName,
        parameters = parameters',
        sourceSpan = sourceSpan
      }

walkTypeSynonymDecl :: TypeSynonymDeclaration Constrained -> Zonk (TypeSynonymDeclaration Zonked)
walkTypeSynonymDecl TypeSynonymDeclaration {name, rhs, sourceSpan} =
  pure
    TypeSynonymDeclaration
      { name = retagNameRef name,
        rhs = retagSyntacticType rhs,
        sourceSpan = sourceSpan
      }

walkDataParameter :: DataParameter Constrained -> Zonk (DataParameter Zonked)
walkDataParameter DataParameter {annotation, name, parameterType, sourceSpan} =
  pure
    DataParameter
      { annotation = annotation,
        name = name,
        parameterType = retagSyntacticType parameterType,
        sourceSpan = sourceSpan
      }

walkParameter :: ParameterBinding Constrained -> Zonk (ParameterBinding Zonked)
walkParameter ParameterBinding {annotation, label, pattern, sourceSpan} = do
  pattern' <- walkPattern pattern
  pure
    ParameterBinding
      { annotation = annotation,
        label = label,
        pattern = pattern',
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

walkPattern :: Pattern Constrained -> Zonk (Pattern Zonked)
walkPattern = \case
  PatternVariable VariablePattern {name, typeAnnotation, sourceSpan, typeOf} -> do
    typeOf' <- zonkPatternMetadata sourceSpan typeOf
    pure
      ( PatternVariable
          VariablePattern
            { name = retagNameRef name,
              typeAnnotation = fmap retagSyntacticType typeAnnotation,
              sourceSpan = sourceSpan,
              typeOf = typeOf'
            }
      )
  PatternWildcard WildcardPattern {typeAnnotation, sourceSpan, typeOf} -> do
    typeOf' <- zonkPatternMetadata sourceSpan typeOf
    pure
      ( PatternWildcard
          WildcardPattern
            { typeAnnotation = fmap retagSyntacticType typeAnnotation,
              sourceSpan = sourceSpan,
              typeOf = typeOf'
            }
      )
  PatternLiteral LiteralPattern {value, sourceSpan, typeOf} -> do
    typeOf' <- zonkPatternMetadata sourceSpan typeOf
    pure
      ( PatternLiteral
          LiteralPattern
            { value = value,
              sourceSpan = sourceSpan,
              typeOf = typeOf'
            }
      )
  PatternTuple TuplePattern {elements, sourceSpan, typeOf} -> do
    elements' <- mapM walkPattern elements
    typeOf' <- zonkPatternMetadata sourceSpan typeOf
    pure
      ( PatternTuple
          TuplePattern
            { elements = elements',
              sourceSpan = sourceSpan,
              typeOf = typeOf'
            }
      )
  PatternQualifiedConstructor QualifiedConstructorPattern {moduleQualifier, constructorName, parameters, sourceSpan, typeOf} -> do
    parameters' <- traverse (\(label, sub) -> (,) (retagNameRef label) <$> walkPattern sub) parameters
    typeOf' <- zonkPatternMetadata sourceSpan typeOf
    pure
      ( PatternQualifiedConstructor
          QualifiedConstructorPattern
            { moduleQualifier = fmap retagNameRef moduleQualifier,
              constructorName = retagNameRef constructorName,
              parameters = parameters',
              sourceSpan = sourceSpan,
              typeOf = typeOf'
            }
      )

-- | Resolve the @typeOf@ payload of a 'Constrained' pattern (a
-- 'SemanticType Unresolved') to its 'Resolved' form for the 'Zonked'
-- phase. Type-family equations make the input and output types align.
zonkPatternMetadata :: SourceSpan -> SemanticType Unresolved -> Zonk (SemanticType Resolved)
zonkPatternMetadata = zonkType

-- | Same as 'zonkPatternMetadata' but for expression nodes; kept as a
-- separate name so that future divergence (different propagation rules)
-- doesn't ripple through call sites.
zonkExpressionMetadata :: SourceSpan -> SemanticType Unresolved -> Zonk (SemanticType Resolved)
zonkExpressionMetadata = zonkType

-- ---------------------------------------------------------------------------
-- Block / where / state vars / handlers
-- ---------------------------------------------------------------------------

walkBlock :: Block Constrained -> Zonk (Block Zonked)
walkBlock Block {statements, returnExpression, whereBlock, sourceSpan} = do
  statements' <- mapM walkStatement statements
  returnExpression' <- traverse walkExpression returnExpression
  whereBlock' <- traverse walkWhereBlock whereBlock
  pure
    Block
      { statements = statements',
        returnExpression = returnExpression',
        whereBlock = whereBlock',
        sourceSpan = sourceSpan
      }

walkWhereBlock :: WhereBlock Constrained -> Zonk (WhereBlock Zonked)
walkWhereBlock WhereBlock {stateVariables, handlers, thenClause, sourceSpan} = do
  stateVariables' <- mapM walkStateVariable stateVariables
  handlers' <- mapM walkRequestHandler handlers
  thenClause' <-
    traverse
      ( \(maybePattern, block) -> do
          maybePattern' <- traverse walkPattern maybePattern
          block' <- walkBlock block
          pure (maybePattern', block')
      )
      thenClause
  pure
    WhereBlock
      { stateVariables = stateVariables',
        handlers = handlers',
        thenClause = thenClause',
        sourceSpan = sourceSpan
      }

walkStateVariable :: StateVariableBinding Constrained -> Zonk (StateVariableBinding Zonked)
walkStateVariable StateVariableBinding {name, typeAnnotation, initial, sourceSpan} = do
  initial' <- walkExpression initial
  pure
    StateVariableBinding
      { name = retagNameRef name,
        typeAnnotation = fmap retagSyntacticType typeAnnotation,
        initial = initial',
        sourceSpan = sourceSpan
      }

walkRequestHandler :: RequestHandler Constrained -> Zonk (RequestHandler Zonked)
walkRequestHandler RequestHandler {moduleQualifier, name, parameters, returnType, body, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  body' <- walkBlock body
  pure
    RequestHandler
      { moduleQualifier = fmap retagNameRef moduleQualifier,
        name = retagNameRef name,
        parameters = parameters',
        returnType = fmap retagSyntacticType returnType,
        body = body',
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------------

walkStatement :: Statement Constrained -> Zonk (Statement Zonked)
walkStatement = \case
  StatementLet stmt -> StatementLet <$> walkLet stmt
  StatementAgent stmt -> StatementAgent <$> walkAgentStatement stmt
  StatementReturn stmt -> StatementReturn <$> walkReturn stmt
  StatementExpression expr -> StatementExpression <$> walkExpression expr
  StatementNext stmt -> StatementNext <$> walkNext stmt
  StatementBreak stmt -> StatementBreak <$> walkBreak stmt
  StatementForNext stmt -> StatementForNext <$> walkForNext stmt
  StatementForBreak stmt -> StatementForBreak <$> walkForBreak stmt
  StatementError span_ -> pure (StatementError span_)

walkLet :: LetStatement Constrained -> Zonk (LetStatement Zonked)
walkLet LetStatement {pattern, value, sourceSpan} = do
  pattern' <- walkPattern pattern
  value' <- walkExpression value
  pure LetStatement {pattern = pattern', value = value', sourceSpan = sourceSpan}

walkAgentStatement :: AgentStatement Constrained -> Zonk (AgentStatement Zonked)
walkAgentStatement AgentStatement {name, parameters, returnType, withEffects, body, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  body' <- walkBlock body
  pure
    AgentStatement
      { name = retagNameRef name,
        parameters = parameters',
        returnType = fmap retagSyntacticType returnType,
        withEffects = fmap (fmap retagSyntacticRequest) withEffects,
        body = body',
        sourceSpan = sourceSpan
      }

walkReturn :: ReturnStatement Constrained -> Zonk (ReturnStatement Zonked)
walkReturn ReturnStatement {value, sourceSpan} = do
  value' <- walkExpression value
  pure ReturnStatement {value = value', sourceSpan = sourceSpan}

walkNext :: NextStatement Constrained -> Zonk (NextStatement Zonked)
walkNext NextStatement {value, modifiers, sourceSpan} = do
  value' <- walkExpression value
  modifiers' <- mapM walkModifier modifiers
  pure NextStatement {value = value', modifiers = modifiers', sourceSpan = sourceSpan}

walkBreak :: BreakStatement Constrained -> Zonk (BreakStatement Zonked)
walkBreak BreakStatement {value, sourceSpan} = do
  value' <- walkExpression value
  pure BreakStatement {value = value', sourceSpan = sourceSpan}

walkForNext :: ForNextStatement Constrained -> Zonk (ForNextStatement Zonked)
walkForNext ForNextStatement {modifiers, sourceSpan} = do
  modifiers' <- mapM walkModifier modifiers
  pure ForNextStatement {modifiers = modifiers', sourceSpan = sourceSpan}

walkForBreak :: ForBreakStatement Constrained -> Zonk (ForBreakStatement Zonked)
walkForBreak ForBreakStatement {value, sourceSpan} = do
  value' <- walkExpression value
  pure ForBreakStatement {value = value', sourceSpan = sourceSpan}

walkModifier :: Modifier Constrained -> Zonk (Modifier Zonked)
walkModifier Modifier {name, value, sourceSpan} = do
  value' <- walkExpression value
  pure Modifier {name = retagNameRef name, value = value', sourceSpan = sourceSpan}

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------

walkExpression :: Expression Constrained -> Zonk (Expression Zonked)
walkExpression = \case
  ExpressionLiteral expr -> ExpressionLiteral <$> walkLiteralExpr expr
  ExpressionVariable expr -> ExpressionVariable <$> walkVariableExpr expr
  ExpressionTuple expr -> ExpressionTuple <$> walkTupleExpr expr
  ExpressionArray expr -> ExpressionArray <$> walkArrayExpr expr
  ExpressionCall expr -> ExpressionCall <$> walkCallExpr expr
  ExpressionBinaryOperator expr -> ExpressionBinaryOperator <$> walkBinaryExpr expr
  ExpressionUnaryOperator expr -> ExpressionUnaryOperator <$> walkUnaryExpr expr
  ExpressionIf expr -> ExpressionIf <$> walkIfExpr expr
  ExpressionMatch expr -> ExpressionMatch <$> walkMatchExpr expr
  ExpressionFor expr -> ExpressionFor <$> walkForExpr expr
  ExpressionBlock expr -> ExpressionBlock <$> walkBlockExpr expr
  ExpressionFieldAccess expr -> ExpressionFieldAccess <$> walkFieldAccessExpr expr
  ExpressionIndexAccess expr -> ExpressionIndexAccess <$> walkIndexAccessExpr expr
  ExpressionTemplate expr -> ExpressionTemplate <$> walkTemplateExpr expr
  ExpressionQualifiedReference expr -> ExpressionQualifiedReference <$> walkQualifiedReferenceExpr expr

walkLiteralExpr :: LiteralExpression Constrained -> Zonk (LiteralExpression Zonked)
walkLiteralExpr LiteralExpression {value, sourceSpan, typeOf} = do
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure LiteralExpression {value = value, sourceSpan = sourceSpan, typeOf = typeOf'}

walkVariableExpr :: VariableExpression Constrained -> Zonk (VariableExpression Zonked)
walkVariableExpr VariableExpression {name, sourceSpan, typeOf} = do
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure
    VariableExpression
      { name = retagNameRef name,
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

walkTupleExpr :: TupleExpression Constrained -> Zonk (TupleExpression Zonked)
walkTupleExpr TupleExpression {elements, sourceSpan, typeOf} = do
  elements' <- mapM walkExpression elements
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure TupleExpression {elements = elements', sourceSpan = sourceSpan, typeOf = typeOf'}

walkArrayExpr :: ArrayExpression Constrained -> Zonk (ArrayExpression Zonked)
walkArrayExpr ArrayExpression {elements, sourceSpan, typeOf} = do
  elements' <- mapM walkExpression elements
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure ArrayExpression {elements = elements', sourceSpan = sourceSpan, typeOf = typeOf'}

walkCallExpr :: CallExpression Constrained -> Zonk (CallExpression Zonked)
walkCallExpr CallExpression {callee, arguments, sourceSpan, typeOf} = do
  callee' <- walkExpression callee
  arguments' <- mapM walkCallArgument arguments
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure
    CallExpression
      { callee = callee',
        arguments = arguments',
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

walkCallArgument :: CallArgument Constrained -> Zonk (CallArgument Zonked)
walkCallArgument CallArgument {label, value, sourceSpan} = do
  value' <- walkExpression value
  pure
    CallArgument
      { label = retagNameRef label,
        value = value',
        sourceSpan = sourceSpan
      }

walkBinaryExpr :: BinaryOperatorExpression Constrained -> Zonk (BinaryOperatorExpression Zonked)
walkBinaryExpr BinaryOperatorExpression {operator, left, right, sourceSpan, typeOf} = do
  left' <- walkExpression left
  right' <- walkExpression right
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure
    BinaryOperatorExpression
      { operator = operator,
        left = left',
        right = right',
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

walkUnaryExpr :: UnaryOperatorExpression Constrained -> Zonk (UnaryOperatorExpression Zonked)
walkUnaryExpr UnaryOperatorExpression {operator, operand, sourceSpan, typeOf} = do
  operand' <- walkExpression operand
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure
    UnaryOperatorExpression
      { operator = operator,
        operand = operand',
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

walkIfExpr :: IfExpression Constrained -> Zonk (IfExpression Zonked)
walkIfExpr IfExpression {condition, thenBlock, elseBlock, sourceSpan, typeOf} = do
  condition' <- walkExpression condition
  thenBlock' <- walkBlock thenBlock
  elseBlock' <- traverse walkBlock elseBlock
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure
    IfExpression
      { condition = condition',
        thenBlock = thenBlock',
        elseBlock = elseBlock',
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

walkMatchExpr :: MatchExpression Constrained -> Zonk (MatchExpression Zonked)
walkMatchExpr MatchExpression {subject, cases, sourceSpan, typeOf} = do
  subject' <- walkExpression subject
  cases' <- mapM walkCaseArm cases
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure
    MatchExpression
      { subject = subject',
        cases = cases',
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

walkCaseArm :: CaseArm Constrained -> Zonk (CaseArm Zonked)
walkCaseArm CaseArm {pattern, body, sourceSpan} = do
  pattern' <- walkPattern pattern
  body' <- walkBlock body
  pure CaseArm {pattern = pattern', body = body', sourceSpan = sourceSpan}

walkForExpr :: ForExpression Constrained -> Zonk (ForExpression Zonked)
walkForExpr ForExpression {inBindings, varBindings, body, thenBlock, sourceSpan, typeOf} = do
  inBindings' <- mapM walkForInBinding inBindings
  varBindings' <- mapM walkForVarBinding varBindings
  body' <- walkBlock body
  thenBlock' <- traverse walkBlock thenBlock
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure
    ForExpression
      { inBindings = inBindings',
        varBindings = varBindings',
        body = body',
        thenBlock = thenBlock',
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

walkForInBinding :: ForInBinding Constrained -> Zonk (ForInBinding Zonked)
walkForInBinding ForInBinding {pattern, source, sourceSpan} = do
  pattern' <- walkPattern pattern
  source' <- walkExpression source
  pure ForInBinding {pattern = pattern', source = source', sourceSpan = sourceSpan}

walkForVarBinding :: ForVarBinding Constrained -> Zonk (ForVarBinding Zonked)
walkForVarBinding ForVarBinding {name, typeAnnotation, initial, sourceSpan} = do
  initial' <- walkExpression initial
  pure
    ForVarBinding
      { name = retagNameRef name,
        typeAnnotation = fmap retagSyntacticType typeAnnotation,
        initial = initial',
        sourceSpan = sourceSpan
      }

walkBlockExpr :: BlockExpression Constrained -> Zonk (BlockExpression Zonked)
walkBlockExpr BlockExpression {block, sourceSpan, typeOf} = do
  block' <- walkBlock block
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure BlockExpression {block = block', sourceSpan = sourceSpan, typeOf = typeOf'}

walkFieldAccessExpr :: FieldAccessExpression Constrained -> Zonk (FieldAccessExpression Zonked)
walkFieldAccessExpr FieldAccessExpression {object, fieldName, sourceSpan, typeOf} = do
  object' <- walkExpression object
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure
    FieldAccessExpression
      { object = object',
        fieldName = retagNameRef fieldName,
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

walkIndexAccessExpr :: IndexAccessExpression Constrained -> Zonk (IndexAccessExpression Zonked)
walkIndexAccessExpr IndexAccessExpression {array, index, sourceSpan, typeOf} = do
  array' <- walkExpression array
  index' <- walkExpression index
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure
    IndexAccessExpression
      { array = array',
        index = index',
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

walkTemplateExpr :: TemplateExpression Constrained -> Zonk (TemplateExpression Zonked)
walkTemplateExpr TemplateExpression {elements, sourceSpan, typeOf} = do
  elements' <- mapM walkTemplateElement elements
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure
    TemplateExpression
      { elements = elements',
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

walkTemplateElement :: TemplateElement Constrained -> Zonk (TemplateElement Zonked)
walkTemplateElement = \case
  TemplateElementString TemplateStringElement {value, sourceSpan} ->
    pure (TemplateElementString TemplateStringElement {value = value, sourceSpan = sourceSpan})
  TemplateElementExpression TemplateExpressionElement {value, sourceSpan} -> do
    value' <- walkExpression value
    pure (TemplateElementExpression TemplateExpressionElement {value = value', sourceSpan = sourceSpan})

walkQualifiedReferenceExpr :: QualifiedReferenceExpression Constrained -> Zonk (QualifiedReferenceExpression Zonked)
walkQualifiedReferenceExpr QualifiedReferenceExpression {moduleQualifier, target, sourceSpan, typeOf} = do
  typeOf' <- zonkExpressionMetadata sourceSpan typeOf
  pure
    QualifiedReferenceExpression
      { moduleQualifier = retagNameRef moduleQualifier,
        target = retagNameRef target,
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

-- ===========================================================================
-- Entry point
-- ===========================================================================

-- | Run zonking over the constrained AST and the type environment.
zonk :: IdentifierResult -> ConstraintGenResult -> SolverResult -> ZonkResult
zonk idResult cgResult solverResult =
  let action =
        (,)
          <$> traverse walkModule cgResult.constrainedModules
          <*> Map.traverseWithKey (zonkEnvEntry idResult) cgResult.typeEnvironment
      ((modulesResult, envResult), errs) = runState (runReaderT action solverResult) []
   in ZonkResult
        { zonkedModules = modulesResult,
          zonkedTypeEnvironment = envResult,
          zonkedVariables = idResult.identifiedVariables,
          zonkedTypes = idResult.identifiedTypes,
          zonkedRequests = idResult.identifiedRequests,
          zonkedConstructors = idResult.identifiedConstructors,
          zonkedRequestByVariable =
            Map.fromList
              [ (requestData.requestVariableId, requestId)
                | (requestId, requestData) <- Map.toList idResult.identifiedRequests
              ],
          zonkedConstructorByVariable =
            Map.fromList
              [ (constructorData.constructorVariableId, constructorId)
                | (constructorId, constructorData) <- Map.toList idResult.identifiedConstructors
              ],
          zonkErrors = reverse errs
        }
  where
    zonkEnvEntry idResult_ variableId t =
      let sourceSpan = case Map.lookup variableId idResult_.identifiedVariables of
            Just vd -> vd.variableSourceSpan
            Nothing -> placeholderSpan
       in zonkType sourceSpan t
    placeholderSpan =
      SrcSpan
        { filePath = "",
          start = Position {line = 0, column = 0},
          end = Position {line = 0, column = 0}
        }
