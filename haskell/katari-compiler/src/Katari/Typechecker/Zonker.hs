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
  ( -- * Phase marker
    Zonked (..),

    -- * Result
    ZonkResult (..),
    ZonkError (..),

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
import Katari.AST
import Katari.Typechecker.ConstraintGenerator
  ( Constrained (..),
    ConstraintGenResult (..),
  )
import Katari.Typechecker.Identifier
  ( IdentifierResult (..),
    ModuleId,
    TypeId,
    VariableData (..),
    VariableId,
  )
import Katari.Typechecker.NormalizedType (denormalise)
import Katari.Typechecker.SemanticType
  ( EffectVarId,
    Resolved,
    SemanticEffect (..),
    SemanticType (..),
    TypeVarId,
    Unresolved,
  )
import Katari.Typechecker.Solver (SolverResult (..))

-- ===========================================================================
-- Zonked phase marker
-- ===========================================================================

data Zonked (s :: SymbolKind) where
  ZonkedVariable :: VariableId -> Zonked 'VariableRef
  ZonkedUnresolvedVariable :: Zonked 'VariableRef
  ZonkedType :: TypeId -> Zonked 'TypeRef
  ZonkedUnresolvedType :: Zonked 'TypeRef
  ZonkedModule :: ModuleId -> Zonked 'ModuleRef
  ZonkedUnresolvedModule :: Zonked 'ModuleRef
  ZonkedExpression :: SemanticType Resolved -> Zonked 'Expression
  ZonkedPattern :: SemanticType Resolved -> Zonked 'Pattern
  ZonkedLabel :: Zonked 'LabelRef

deriving instance Show (Zonked s)

deriving instance Eq (Zonked s)

-- ===========================================================================
-- Result types
-- ===========================================================================

data ZonkResult = ZonkResult
  { zonkedModules :: !(Map ModuleId (Module Zonked)),
    zonkedTypeEnvironment :: !(Map VariableId (SemanticType Resolved)),
    -- | Solver 契約逸脱 (lookup miss) 検知用。通常 path では空のはず。
    zonkErrors :: ![ZonkError]
  }
  deriving (Show)

data ZonkError where
  ZonkErrorMissingTypeVar :: SourceSpan -> TypeVarId -> ZonkError
  ZonkErrorMissingEffectVar :: SourceSpan -> EffectVarId -> ZonkError

deriving instance Eq ZonkError

deriving instance Show ZonkError

-- ===========================================================================
-- Zonker monad
-- ===========================================================================

type Zonk = ReaderT SolverResult (State [ZonkError])

recordZonkError :: ZonkError -> Zonk ()
recordZonkError err = lift (modify (err :))

-- ===========================================================================
-- Type / effect substitution
-- ===========================================================================

zonkType :: SourceSpan -> SemanticType Unresolved -> Zonk (SemanticType Resolved)
zonkType sp = \case
  SemanticTypeVariable tv -> do
    sr <- ask
    case Map.lookup tv sr.typeSubstitution of
      Just nt -> pure (denormalise nt)
      Nothing -> do
        recordZonkError (ZonkErrorMissingTypeVar sp tv)
        pure SemanticTypeUnknown
  SemanticTypeNever -> pure SemanticTypeNever
  SemanticTypeUnknown -> pure SemanticTypeUnknown
  SemanticTypeNull -> pure SemanticTypeNull
  SemanticTypeInteger -> pure SemanticTypeInteger
  SemanticTypeNumber -> pure SemanticTypeNumber
  SemanticTypeString -> pure SemanticTypeString
  SemanticTypeBoolean -> pure SemanticTypeBoolean
  SemanticTypeLiteralInteger n -> pure (SemanticTypeLiteralInteger n)
  SemanticTypeLiteralString s -> pure (SemanticTypeLiteralString s)
  SemanticTypeLiteralBoolean b -> pure (SemanticTypeLiteralBoolean b)
  SemanticTypeFunction params returnType effects -> do
    params' <- traverse (zonkType sp) params
    returnType' <- zonkType sp returnType
    effects' <- zonkEffect sp effects
    pure (SemanticTypeFunction params' returnType' effects')
  SemanticTypeArray elementType -> SemanticTypeArray <$> zonkType sp elementType
  SemanticTypeTuple elementTypes -> SemanticTypeTuple <$> traverse (zonkType sp) elementTypes
  SemanticTypeUnion branches -> SemanticTypeUnion <$> traverse (zonkType sp) branches
  SemanticTypeData tid -> pure (SemanticTypeData tid)
  SemanticTypeObject fields -> SemanticTypeObject <$> traverse (zonkType sp) fields

zonkEffect :: SourceSpan -> SemanticEffect Unresolved -> Zonk (SemanticEffect Resolved)
zonkEffect sp (SemanticEffect vars reqs) = do
  expanded <- foldM addEffectVar reqs (Set.toList vars)
  pure (SemanticEffect Set.empty expanded)
  where
    addEffectVar acc ev = do
      sr <- ask
      case Map.lookup ev sr.effectSubstitution of
        Just rs -> pure (Set.union acc rs)
        Nothing -> do
          recordZonkError (ZonkErrorMissingEffectVar sp ev)
          pure acc

-- ===========================================================================
-- passThrough helpers (Constrained -> Zonked) for ref-only nodes
-- ===========================================================================

passThroughVariableName :: NameRef Constrained 'VariableRef -> NameRef Zonked 'VariableRef
passThroughVariableName = mapNameRefMetadata constrainedToZonked

passThroughTypeName :: NameRef Constrained 'TypeRef -> NameRef Zonked 'TypeRef
passThroughTypeName = mapNameRefMetadata constrainedToZonked

passThroughModuleName :: NameRef Constrained 'ModuleRef -> NameRef Zonked 'ModuleRef
passThroughModuleName = mapNameRefMetadata constrainedToZonked

passThroughLabelName :: NameRef Constrained 'LabelRef -> NameRef Zonked 'LabelRef
passThroughLabelName = mapNameRefMetadata constrainedToZonked

passThroughType :: SyntacticType Constrained -> SyntacticType Zonked
passThroughType = mapSyntacticTypeMetadata constrainedToZonked

passThroughRequest :: SyntacticRequest Constrained -> SyntacticRequest Zonked
passThroughRequest = mapSyntacticRequestMetadata constrainedToZonked

-- | The metadata transformation for the trivial NameRef kinds. The
-- 'ConstrainedExpression' / 'ConstrainedPattern' cases require a
-- 'SemanticType Resolved' resolved via 'zonkType' (which needs the solver
-- result and the AST node's source span), so they are handled by the
-- per-node walkers ('walk*Expr' / 'walkPattern') instead.
constrainedToZonked :: Constrained sym -> Zonked sym
constrainedToZonked = \case
  ConstrainedVariable vid -> ZonkedVariable vid
  ConstrainedUnresolvedVariable -> ZonkedUnresolvedVariable
  ConstrainedType tid -> ZonkedType tid
  ConstrainedUnresolvedType -> ZonkedUnresolvedType
  ConstrainedModule mid -> ZonkedModule mid
  ConstrainedUnresolvedModule -> ZonkedUnresolvedModule
  ConstrainedLabel -> ZonkedLabel
  ConstrainedExpression _ ->
    error "constrainedToZonked: Expression metadata requires zonkType (use walk*Expr)"
  ConstrainedPattern _ ->
    error "constrainedToZonked: Pattern metadata requires zonkType (use walkPattern)"

-- ===========================================================================
-- AST walker
-- ===========================================================================

walkModule :: Module Constrained -> Zonk (Module Zonked)
walkModule Module {declarations, sourceSpan} = do
  declarations' <- mapM walkDeclaration declarations
  pure Module {declarations = declarations', sourceSpan = sourceSpan}

walkDeclaration :: Declaration Constrained -> Zonk (Declaration Zonked)
walkDeclaration = \case
  DeclarationAgent decl -> DeclarationAgent <$> walkAgentDecl decl
  DeclarationRequest decl -> DeclarationRequest <$> walkRequestDecl decl
  DeclarationExternalAgent decl -> DeclarationExternalAgent <$> walkExternalAgentDecl decl
  DeclarationData decl -> DeclarationData <$> walkDataDecl decl
  DeclarationTypeSynonym decl -> DeclarationTypeSynonym <$> walkTypeSynonymDecl decl
  DeclarationImport decl -> pure (DeclarationImport (passThroughImport decl))
  DeclarationError span_ -> pure (DeclarationError span_)

passThroughImport :: ImportDeclaration Constrained -> ImportDeclaration Zonked
passThroughImport ImportDeclaration {kind, sourceSpan} =
  ImportDeclaration {kind = kind, sourceSpan = sourceSpan}

walkAgentDecl :: AgentDeclaration Constrained -> Zonk (AgentDeclaration Zonked)
walkAgentDecl AgentDeclaration {annotation, name, parameters, returnType, withEffects, body, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  body' <- walkBlock body
  pure
    AgentDeclaration
      { annotation = annotation,
        name = passThroughVariableName name,
        parameters = parameters',
        returnType = fmap passThroughType returnType,
        withEffects = fmap (fmap passThroughRequest) withEffects,
        body = body',
        sourceSpan = sourceSpan
      }

walkRequestDecl :: RequestDeclaration Constrained -> Zonk (RequestDeclaration Zonked)
walkRequestDecl RequestDeclaration {annotation, name, parameters, returnType, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  pure
    RequestDeclaration
      { annotation = annotation,
        name = passThroughVariableName name,
        parameters = parameters',
        returnType = passThroughType returnType,
        sourceSpan = sourceSpan
      }

walkExternalAgentDecl :: ExternalAgentDeclaration Constrained -> Zonk (ExternalAgentDeclaration Zonked)
walkExternalAgentDecl ExternalAgentDeclaration {annotation, name, parameters, returnType, withEffects, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  pure
    ExternalAgentDeclaration
      { annotation = annotation,
        name = passThroughVariableName name,
        parameters = parameters',
        returnType = passThroughType returnType,
        withEffects = map passThroughRequest withEffects,
        sourceSpan = sourceSpan
      }

walkDataDecl :: DataDeclaration Constrained -> Zonk (DataDeclaration Zonked)
walkDataDecl DataDeclaration {annotation, name, typeName, parameters, sourceSpan} = do
  parameters' <- mapM walkDataParameter parameters
  pure
    DataDeclaration
      { annotation = annotation,
        name = passThroughVariableName name,
        typeName = passThroughTypeName typeName,
        parameters = parameters',
        sourceSpan = sourceSpan
      }

walkTypeSynonymDecl :: TypeSynonymDeclaration Constrained -> Zonk (TypeSynonymDeclaration Zonked)
walkTypeSynonymDecl TypeSynonymDeclaration {name, rhs, sourceSpan} =
  pure
    TypeSynonymDeclaration
      { name = passThroughTypeName name,
        rhs = passThroughType rhs,
        sourceSpan = sourceSpan
      }

walkDataParameter :: DataParameter Constrained -> Zonk (DataParameter Zonked)
walkDataParameter DataParameter {annotation, name, parameterType, sourceSpan} =
  pure
    DataParameter
      { annotation = annotation,
        name = name,
        parameterType = passThroughType parameterType,
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
  PatternVariable VariablePattern {name, typeAnnotation, sourceSpan, metadata} -> do
    metadata' <- zonkPatternMetadata sourceSpan metadata
    pure
      ( PatternVariable
          VariablePattern
            { name = passThroughVariableName name,
              typeAnnotation = fmap passThroughType typeAnnotation,
              sourceSpan = sourceSpan,
              metadata = metadata'
            }
      )
  PatternWildcard WildcardPattern {typeAnnotation, sourceSpan, metadata} -> do
    metadata' <- zonkPatternMetadata sourceSpan metadata
    pure
      ( PatternWildcard
          WildcardPattern
            { typeAnnotation = fmap passThroughType typeAnnotation,
              sourceSpan = sourceSpan,
              metadata = metadata'
            }
      )
  PatternLiteral LiteralPattern {value, sourceSpan, metadata} -> do
    metadata' <- zonkPatternMetadata sourceSpan metadata
    pure
      ( PatternLiteral
          LiteralPattern
            { value = value,
              sourceSpan = sourceSpan,
              metadata = metadata'
            }
      )
  PatternTuple TuplePattern {elements, sourceSpan, metadata} -> do
    elements' <- mapM walkPattern elements
    metadata' <- zonkPatternMetadata sourceSpan metadata
    pure
      ( PatternTuple
          TuplePattern
            { elements = elements',
              sourceSpan = sourceSpan,
              metadata = metadata'
            }
      )
  PatternQualifiedConstructor QualifiedConstructorPattern {moduleQualifier, constructorName, parameters, sourceSpan, metadata} -> do
    parameters' <- traverse (\(label, sub) -> (,) (passThroughLabelName label) <$> walkPattern sub) parameters
    metadata' <- zonkPatternMetadata sourceSpan metadata
    pure
      ( PatternQualifiedConstructor
          QualifiedConstructorPattern
            { moduleQualifier = fmap passThroughModuleName moduleQualifier,
              constructorName = passThroughVariableName constructorName,
              parameters = parameters',
              sourceSpan = sourceSpan,
              metadata = metadata'
            }
      )

zonkPatternMetadata :: SourceSpan -> Constrained 'Pattern -> Zonk (Zonked 'Pattern)
zonkPatternMetadata sp = \case
  ConstrainedPattern t -> ZonkedPattern <$> zonkType sp t

zonkExpressionMetadata :: SourceSpan -> Constrained 'Expression -> Zonk (Zonked 'Expression)
zonkExpressionMetadata sp = \case
  ConstrainedExpression t -> ZonkedExpression <$> zonkType sp t

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
      { name = passThroughVariableName name,
        typeAnnotation = fmap passThroughType typeAnnotation,
        initial = initial',
        sourceSpan = sourceSpan
      }

walkRequestHandler :: RequestHandler Constrained -> Zonk (RequestHandler Zonked)
walkRequestHandler RequestHandler {moduleQualifier, name, parameters, returnType, body, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  body' <- walkBlock body
  pure
    RequestHandler
      { moduleQualifier = fmap passThroughModuleName moduleQualifier,
        name = passThroughVariableName name,
        parameters = parameters',
        returnType = fmap passThroughType returnType,
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
      { name = passThroughVariableName name,
        parameters = parameters',
        returnType = fmap passThroughType returnType,
        withEffects = fmap (fmap passThroughRequest) withEffects,
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
  pure Modifier {name = passThroughVariableName name, value = value', sourceSpan = sourceSpan}

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
walkLiteralExpr LiteralExpression {value, sourceSpan, metadata} = do
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure LiteralExpression {value = value, sourceSpan = sourceSpan, metadata = metadata'}

walkVariableExpr :: VariableExpression Constrained -> Zonk (VariableExpression Zonked)
walkVariableExpr VariableExpression {name, sourceSpan, metadata} = do
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure
    VariableExpression
      { name = passThroughVariableName name,
        sourceSpan = sourceSpan,
        metadata = metadata'
      }

walkTupleExpr :: TupleExpression Constrained -> Zonk (TupleExpression Zonked)
walkTupleExpr TupleExpression {elements, sourceSpan, metadata} = do
  elements' <- mapM walkExpression elements
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure TupleExpression {elements = elements', sourceSpan = sourceSpan, metadata = metadata'}

walkArrayExpr :: ArrayExpression Constrained -> Zonk (ArrayExpression Zonked)
walkArrayExpr ArrayExpression {elements, sourceSpan, metadata} = do
  elements' <- mapM walkExpression elements
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure ArrayExpression {elements = elements', sourceSpan = sourceSpan, metadata = metadata'}

walkCallExpr :: CallExpression Constrained -> Zonk (CallExpression Zonked)
walkCallExpr CallExpression {callee, arguments, sourceSpan, metadata} = do
  callee' <- walkExpression callee
  arguments' <- mapM walkCallArgument arguments
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure
    CallExpression
      { callee = callee',
        arguments = arguments',
        sourceSpan = sourceSpan,
        metadata = metadata'
      }

walkCallArgument :: CallArgument Constrained -> Zonk (CallArgument Zonked)
walkCallArgument CallArgument {label, value, sourceSpan} = do
  value' <- walkExpression value
  pure
    CallArgument
      { label = passThroughLabelName label,
        value = value',
        sourceSpan = sourceSpan
      }

walkBinaryExpr :: BinaryOperatorExpression Constrained -> Zonk (BinaryOperatorExpression Zonked)
walkBinaryExpr BinaryOperatorExpression {operator, left, right, sourceSpan, metadata} = do
  left' <- walkExpression left
  right' <- walkExpression right
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure
    BinaryOperatorExpression
      { operator = operator,
        left = left',
        right = right',
        sourceSpan = sourceSpan,
        metadata = metadata'
      }

walkUnaryExpr :: UnaryOperatorExpression Constrained -> Zonk (UnaryOperatorExpression Zonked)
walkUnaryExpr UnaryOperatorExpression {operator, operand, sourceSpan, metadata} = do
  operand' <- walkExpression operand
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure
    UnaryOperatorExpression
      { operator = operator,
        operand = operand',
        sourceSpan = sourceSpan,
        metadata = metadata'
      }

walkIfExpr :: IfExpression Constrained -> Zonk (IfExpression Zonked)
walkIfExpr IfExpression {condition, thenBlock, elseBlock, sourceSpan, metadata} = do
  condition' <- walkExpression condition
  thenBlock' <- walkBlock thenBlock
  elseBlock' <- traverse walkBlock elseBlock
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure
    IfExpression
      { condition = condition',
        thenBlock = thenBlock',
        elseBlock = elseBlock',
        sourceSpan = sourceSpan,
        metadata = metadata'
      }

walkMatchExpr :: MatchExpression Constrained -> Zonk (MatchExpression Zonked)
walkMatchExpr MatchExpression {subject, cases, sourceSpan, metadata} = do
  subject' <- walkExpression subject
  cases' <- mapM walkCaseArm cases
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure
    MatchExpression
      { subject = subject',
        cases = cases',
        sourceSpan = sourceSpan,
        metadata = metadata'
      }

walkCaseArm :: CaseArm Constrained -> Zonk (CaseArm Zonked)
walkCaseArm CaseArm {pattern, body, sourceSpan} = do
  pattern' <- walkPattern pattern
  body' <- walkBlock body
  pure CaseArm {pattern = pattern', body = body', sourceSpan = sourceSpan}

walkForExpr :: ForExpression Constrained -> Zonk (ForExpression Zonked)
walkForExpr ForExpression {inBindings, varBindings, body, thenBlock, sourceSpan, metadata} = do
  inBindings' <- mapM walkForInBinding inBindings
  varBindings' <- mapM walkForVarBinding varBindings
  body' <- walkBlock body
  thenBlock' <- traverse walkBlock thenBlock
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure
    ForExpression
      { inBindings = inBindings',
        varBindings = varBindings',
        body = body',
        thenBlock = thenBlock',
        sourceSpan = sourceSpan,
        metadata = metadata'
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
      { name = passThroughVariableName name,
        typeAnnotation = fmap passThroughType typeAnnotation,
        initial = initial',
        sourceSpan = sourceSpan
      }

walkBlockExpr :: BlockExpression Constrained -> Zonk (BlockExpression Zonked)
walkBlockExpr BlockExpression {block, sourceSpan, metadata} = do
  block' <- walkBlock block
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure BlockExpression {block = block', sourceSpan = sourceSpan, metadata = metadata'}

walkFieldAccessExpr :: FieldAccessExpression Constrained -> Zonk (FieldAccessExpression Zonked)
walkFieldAccessExpr FieldAccessExpression {object, fieldName, sourceSpan, metadata} = do
  object' <- walkExpression object
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure
    FieldAccessExpression
      { object = object',
        fieldName = passThroughLabelName fieldName,
        sourceSpan = sourceSpan,
        metadata = metadata'
      }

walkIndexAccessExpr :: IndexAccessExpression Constrained -> Zonk (IndexAccessExpression Zonked)
walkIndexAccessExpr IndexAccessExpression {array, index, sourceSpan, metadata} = do
  array' <- walkExpression array
  index' <- walkExpression index
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure
    IndexAccessExpression
      { array = array',
        index = index',
        sourceSpan = sourceSpan,
        metadata = metadata'
      }

walkTemplateExpr :: TemplateExpression Constrained -> Zonk (TemplateExpression Zonked)
walkTemplateExpr TemplateExpression {elements, sourceSpan, metadata} = do
  elements' <- mapM walkTemplateElement elements
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure
    TemplateExpression
      { elements = elements',
        sourceSpan = sourceSpan,
        metadata = metadata'
      }

walkTemplateElement :: TemplateElement Constrained -> Zonk (TemplateElement Zonked)
walkTemplateElement = \case
  TemplateElementString TemplateStringElement {value, sourceSpan} ->
    pure (TemplateElementString TemplateStringElement {value = value, sourceSpan = sourceSpan})
  TemplateElementExpression TemplateExpressionElement {value, sourceSpan} -> do
    value' <- walkExpression value
    pure (TemplateElementExpression TemplateExpressionElement {value = value', sourceSpan = sourceSpan})

walkQualifiedReferenceExpr :: QualifiedReferenceExpression Constrained -> Zonk (QualifiedReferenceExpression Zonked)
walkQualifiedReferenceExpr QualifiedReferenceExpression {moduleQualifier, target, sourceSpan, metadata} = do
  metadata' <- zonkExpressionMetadata sourceSpan metadata
  pure
    QualifiedReferenceExpression
      { moduleQualifier = passThroughModuleName moduleQualifier,
        target = passThroughVariableName target,
        sourceSpan = sourceSpan,
        metadata = metadata'
      }

-- ===========================================================================
-- Entry point
-- ===========================================================================

-- | Run zonking over the constrained AST and the type environment.
zonk :: IdentifierResult -> ConstraintGenResult -> SolverResult -> ZonkResult
zonk idResult cgResult solverResult =
  let action = (,)
        <$> traverse walkModule cgResult.constrainedModules
        <*> Map.traverseWithKey (zonkEnvEntry idResult) cgResult.typeEnvironment
      ((modulesResult, envResult), errs) = runState (runReaderT action solverResult) []
   in ZonkResult
        { zonkedModules = modulesResult,
          zonkedTypeEnvironment = envResult,
          zonkErrors = reverse errs
        }
  where
    zonkEnvEntry idResult_ vid t =
      let sp = case Map.lookup vid idResult_.identifiedVariables of
            Just vd -> vd.variableSourceSpan
            Nothing -> placeholderSpan
       in zonkType sp t
    placeholderSpan =
      SrcSpan
        { filePath = "",
          start = Position {line = 0, column = 0},
          end = Position {line = 0, column = 0}
        }
