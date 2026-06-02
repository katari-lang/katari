-- | Typechecker phase 4: Zonk — bakes the Solver's substitution results
-- into the AST.
--
-- Input  : @variables@ (per-module 'VariableData' map, used only for
--          source-span attribution on substitution-miss errors),
--          'ConstraintGenResult' (Constrained AST and type environment
--          for this SCC), 'SolverResult' (substitution maps).
-- Output : 'ModuleZonkResult' — the SCC's Zonked AST + resolved type
--          environment, plus an error list for detecting Solver-contract
--          violations.
--
-- Design assumptions:
--
--   * The Solver's output is **total**: 'typeSubstitution' /
--     'requestSubstitution' have an entry for every TypeVariableId /
--     RequestVariableId allocated by the ConstraintGenerator. From the
--     Zonker's perspective lookup misses should not occur.
--   * In case of a Solver bug (lookup miss) we detect it via
--     'ZonkErrorMissingTypeVar' / 'ZonkErrorMissingRequestVar' and fall
--     back to 'SemanticTypeUnknown' / an empty request set so AST
--     generation is not aborted.
--   * Expression / Pattern metadata on the Zonked AST holds
--     @SemanticType Resolved@ directly. The construction side enforces
--     @requestVars = Set.empty@ for any 'SemanticRequest' Resolved.
module Katari.Typechecker.Zonker
  ( -- * Per-module zonk output
    ModuleZonkResult (..),
    ZonkError (..),

    -- * Diagnostics
    toDiagnostic,

    -- * Entry
    zonk,
  )
where

import Control.Monad.Reader (ReaderT, ask, runReaderT)
import Control.Monad.State.Strict (State, modify, runState)
import Control.Monad.Trans (lift)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Katari.AST
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.Common (QualifiedName (..))
import Katari.Id
  ( VariableResolution (..),
  )
import Katari.SemanticType
  ( RequestVariableId (..),
    Resolved,
    SemanticRequest (..),
    SemanticRequestElement (..),
    SemanticType (..),
    TypeVariableId (..),
    Unresolved,
    substituteVariable,
  )
import Katari.SourceSpan (SourceSpan, emptySourceSpan)
import Katari.Typechecker.ConstraintGenerator (ConstraintGenResult (..))
import Katari.Typechecker.Identifier (VariableData (..))
import Katari.Typechecker.NormalizedType (denormalise)
import Katari.Typechecker.Solver (SolverResult (..))

-- The 'Zonked' phase reuses the 'NameRefResolution Zonked s' family for name
-- resolution (identical to 'Identified' / 'Constrained'), and stores the
-- resolved @SemanticType Resolved@ on each expression / pattern via the
-- @ExpressionType Zonked@ / @PatternType Zonked@ instances defined in
-- 'Katari.SemanticType'.

-- ===========================================================================
-- Result types
-- ===========================================================================

-- | Per-module zonk output. Holds the SCC's zonked declarations and
-- the local type environment for the same SCC. The caller (typechecker
-- orchestration) accumulates these across SCCs into the module's full
-- output.
data ModuleZonkResult = ModuleZonkResult
  { zonkedModule :: Module Zonked,
    zonkedTypeEnv :: Map VariableResolution (SemanticType Resolved)
  }
  deriving (Show)

data ZonkError where
  ZonkErrorMissingTypeVar :: SourceSpan -> TypeVariableId -> ZonkError
  ZonkErrorMissingRequestVar :: SourceSpan -> RequestVariableId -> ZonkError

deriving instance Eq ZonkError

deriving instance Show ZonkError

-- | Convert a 'ZonkError' to a unified 'Diagnostic'. Codes K0250-K0279
-- are reserved for the zonker. These errors indicate a Solver-contract
-- violation (the substitution should be total) and should be
-- treated as internal compiler errors.
toDiagnostic :: ZonkError -> Diagnostic
toDiagnostic = \case
  ZonkErrorMissingTypeVar sourceSpan (TypeVariableId typeVar) ->
    diagnosticError
      "K0250"
      ( "internal: solver substitution missing for type variable α"
          <> Text.pack (show typeVar)
      )
      sourceSpan
  ZonkErrorMissingRequestVar sourceSpan (RequestVariableId requestVar) ->
    diagnosticError
      "K0251"
      ( "internal: solver substitution missing for request variable ε"
          <> Text.pack (show requestVar)
      )
      sourceSpan

-- ===========================================================================
-- Zonker monad
-- ===========================================================================

type Zonk = ReaderT SolverResult (State [ZonkError])

recordZonkError :: ZonkError -> Zonk ()
recordZonkError err = lift (modify (err :))

-- ===========================================================================
-- Type / request substitution
-- ===========================================================================

-- | Zonk a 'SemanticType Unresolved' to 'SemanticType Resolved'. Variables
-- are looked up in the solver's type substitution; structural recursion is
-- delegated to 'substituteVariable' (the bulk of what used to be a
-- 14-case @\\case@).
zonkType :: SourceSpan -> SemanticType Unresolved -> Zonk (SemanticType Resolved)
zonkType sourceSpan =
  substituteVariable
    ( \typeVar -> do
        solverResult <- ask
        case Map.lookup typeVar solverResult.typeSubstitution of
          Just normalizedType -> pure (denormalise normalizedType)
          Nothing -> do
            recordZonkError (ZonkErrorMissingTypeVar sourceSpan typeVar)
            pure SemanticTypeUnknown
    )
    (zonkRequestVariable sourceSpan)

zonkRequestVariable :: SourceSpan -> RequestVariableId -> Zonk (SemanticRequest Resolved)
zonkRequestVariable sourceSpan requestVariableId = do
  solverResult <- ask
  case Map.lookup requestVariableId solverResult.requestSubstitution of
    Just resolvedReqs -> pure $ SemanticRequest $ Set.map SemanticRequestElementConcrete resolvedReqs
    Nothing -> do
      recordZonkError (ZonkErrorMissingRequestVar sourceSpan requestVariableId)
      pure $ SemanticRequest Set.empty

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
  DeclarationPrimAgent decl -> DeclarationPrimAgent <$> walkPrimAgentDecl decl
  DeclarationData decl -> DeclarationData <$> walkDataDecl decl
  DeclarationTypeSynonym decl -> DeclarationTypeSynonym <$> walkTypeSynonymDecl decl
  DeclarationImport decl -> pure (DeclarationImport decl)
  DeclarationError span_ -> pure (DeclarationError span_)

walkAgentDecl :: AgentDeclaration Constrained -> Zonk (AgentDeclaration Zonked)
walkAgentDecl AgentDeclaration {annotation, name, parameters, returnType, withRequests, body, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  body' <- walkBlock body
  pure
    AgentDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        parameters = parameters',
        returnType = fmap retagSyntacticType returnType,
        withRequests = fmap (fmap retagSyntacticRequest) withRequests,
        body = body',
        sourceSpan = sourceSpan
      }

walkRequestDecl :: RequestDeclaration Constrained -> Zonk (RequestDeclaration Zonked)
walkRequestDecl RequestDeclaration {annotation, name, requestName, parameters, returnType, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  pure
    RequestDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        requestName = retagNameRef requestName,
        parameters = parameters',
        returnType = retagSyntacticType returnType,
        sourceSpan = sourceSpan
      }

walkExternalAgentDecl :: ExternalAgentDeclaration Constrained -> Zonk (ExternalAgentDeclaration Zonked)
walkExternalAgentDecl ExternalAgentDeclaration {annotation, name, parameters, returnType, withRequests, endpoint, dispatchName, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  pure
    ExternalAgentDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        parameters = parameters',
        returnType = retagSyntacticType returnType,
        withRequests = map retagSyntacticRequest withRequests,
        endpoint = endpoint,
        dispatchName = dispatchName,
        sourceSpan = sourceSpan
      }

walkPrimAgentDecl :: PrimAgentDeclaration Constrained -> Zonk (PrimAgentDeclaration Zonked)
walkPrimAgentDecl PrimAgentDeclaration {annotation, name, parameters, returnType, withRequests, using, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  pure
    PrimAgentDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        parameters = parameters',
        returnType = retagSyntacticType returnType,
        withRequests = map retagSyntacticRequest withRequests,
        using = using,
        sourceSpan = sourceSpan
      }

walkDataDecl :: DataDeclaration Constrained -> Zonk (DataDeclaration Zonked)
walkDataDecl DataDeclaration {annotation, name, constructorName, typeName, parameters, sourceSpan} = do
  parameters' <- mapM walkDataParameter parameters
  pure
    DataDeclaration
      { annotation = annotation,
        name = retagNameRef name,
        constructorName = retagNameRef constructorName,
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
walkParameter ParameterBinding {annotation, name, typeAnnotation, defaultValue, sourceSpan} =
  pure
    ParameterBinding
      { annotation = annotation,
        name = retagNameRef name,
        typeAnnotation = fmap retagSyntacticType typeAnnotation,
        defaultValue = defaultValue,
        sourceSpan = sourceSpan
      }

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

walkPattern :: Pattern Constrained -> Zonk (Pattern Zonked)
walkPattern = \case
  PatternVariable VariablePattern {name, typeAnnotation, sourceSpan, typeOf} -> do
    typeOf' <- zonkType sourceSpan typeOf
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
    typeOf' <- zonkType sourceSpan typeOf
    pure
      ( PatternWildcard
          WildcardPattern
            { typeAnnotation = fmap retagSyntacticType typeAnnotation,
              sourceSpan = sourceSpan,
              typeOf = typeOf'
            }
      )
  PatternLiteral LiteralPattern {value, sourceSpan, typeOf} -> do
    typeOf' <- zonkType sourceSpan typeOf
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
    typeOf' <- zonkType sourceSpan typeOf
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
    typeOf' <- zonkType sourceSpan typeOf
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
  PatternType TypePattern {typeTag, inner, sourceSpan, typeOf} -> do
    inner' <- walkPattern inner
    typeOf' <- zonkType sourceSpan typeOf
    pure
      ( PatternType
          TypePattern
            { typeTag = typeTag,
              inner = inner',
              sourceSpan = sourceSpan,
              typeOf = typeOf'
            }
      )
  PatternRecord RecordPattern {entries, sourceSpan, typeOf} -> do
    entries' <- traverse (\(entryLabel, sub) -> (entryLabel,) <$> walkPattern sub) entries
    typeOf' <- zonkType sourceSpan typeOf
    pure
      ( PatternRecord
          RecordPattern
            { entries = entries',
              sourceSpan = sourceSpan,
              typeOf = typeOf'
            }
      )

-- ---------------------------------------------------------------------------
-- Block / where / state vars / handlers
-- ---------------------------------------------------------------------------

walkBlock :: Block Constrained -> Zonk (Block Zonked)
walkBlock Block {statements, returnExpression, sourceSpan} = do
  statements' <- mapM walkStatement statements
  returnExpression' <- traverse walkExpression returnExpression
  pure
    Block
      { statements = statements',
        returnExpression = returnExpression',
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
walkAgentStatement AgentStatement {annotation, name, parameters, returnType, withRequests, body, sourceSpan} = do
  parameters' <- mapM walkParameter parameters
  body' <- walkBlock body
  pure
    AgentStatement
      { annotation = annotation,
        name = retagNameRef name,
        parameters = parameters',
        returnType = fmap retagSyntacticType returnType,
        withRequests = fmap (fmap retagSyntacticRequest) withRequests,
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
  ExpressionRecord expr -> ExpressionRecord <$> walkRecordExpr expr
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
  ExpressionHandle expr -> ExpressionHandle <$> walkHandleExpr expr
  ExpressionParTuple expr -> ExpressionParTuple <$> walkParTupleExpr expr
  ExpressionParArray expr -> ExpressionParArray <$> walkParArrayExpr expr
  ExpressionQualifiedReference expr -> ExpressionQualifiedReference <$> walkQualifiedReferenceExpr expr

walkLiteralExpr :: LiteralExpression Constrained -> Zonk (LiteralExpression Zonked)
walkLiteralExpr LiteralExpression {value, sourceSpan, typeOf} = do
  typeOf' <- zonkType sourceSpan typeOf
  pure LiteralExpression {value = value, sourceSpan = sourceSpan, typeOf = typeOf'}

walkVariableExpr :: VariableExpression Constrained -> Zonk (VariableExpression Zonked)
walkVariableExpr VariableExpression {name, sourceSpan, typeOf} = do
  typeOf' <- zonkType sourceSpan typeOf
  pure
    VariableExpression
      { name = retagNameRef name,
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

walkTupleExpr :: TupleExpression Constrained -> Zonk (TupleExpression Zonked)
walkTupleExpr TupleExpression {elements, sourceSpan, typeOf} = do
  elements' <- mapM walkExpression elements
  typeOf' <- zonkType sourceSpan typeOf
  pure TupleExpression {elements = elements', sourceSpan = sourceSpan, typeOf = typeOf'}

walkArrayExpr :: ArrayExpression Constrained -> Zonk (ArrayExpression Zonked)
walkArrayExpr ArrayExpression {elements, sourceSpan, typeOf} = do
  elements' <- mapM walkExpression elements
  typeOf' <- zonkType sourceSpan typeOf
  pure ArrayExpression {elements = elements', sourceSpan = sourceSpan, typeOf = typeOf'}

walkRecordExpr :: RecordExpression Constrained -> Zonk (RecordExpression Zonked)
walkRecordExpr RecordExpression {entries, sourceSpan, typeOf} = do
  entries' <- mapM (\(lbl, e) -> (lbl,) <$> walkExpression e) entries
  typeOf' <- zonkType sourceSpan typeOf
  pure RecordExpression {entries = entries', sourceSpan = sourceSpan, typeOf = typeOf'}

walkCallExpr :: CallExpression Constrained -> Zonk (CallExpression Zonked)
walkCallExpr CallExpression {callee, arguments, sourceSpan, typeOf} = do
  callee' <- walkExpression callee
  arguments' <- mapM walkCallArgument arguments
  typeOf' <- zonkType sourceSpan typeOf
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
  typeOf' <- zonkType sourceSpan typeOf
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
  typeOf' <- zonkType sourceSpan typeOf
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
  typeOf' <- zonkType sourceSpan typeOf
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
  typeOf' <- zonkType sourceSpan typeOf
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
walkForExpr ForExpression {parallel, inBindings, varBindings, body, thenBlock, sourceSpan, typeOf} = do
  inBindings' <- mapM walkForInBinding inBindings
  varBindings' <- mapM walkForVarBinding varBindings
  body' <- walkBlock body
  thenBlock' <- traverse walkBlock thenBlock
  typeOf' <- zonkType sourceSpan typeOf
  pure
    ForExpression
      { parallel = parallel,
        inBindings = inBindings',
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
  typeOf' <- zonkType sourceSpan typeOf
  pure BlockExpression {block = block', sourceSpan = sourceSpan, typeOf = typeOf'}

walkFieldAccessExpr :: FieldAccessExpression Constrained -> Zonk (FieldAccessExpression Zonked)
walkFieldAccessExpr FieldAccessExpression {object, fieldName, sourceSpan, typeOf} = do
  object' <- walkExpression object
  typeOf' <- zonkType sourceSpan typeOf
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
  typeOf' <- zonkType sourceSpan typeOf
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
  typeOf' <- zonkType sourceSpan typeOf
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
  typeOf' <- zonkType sourceSpan typeOf
  pure
    QualifiedReferenceExpression
      { moduleQualifier = retagNameRef moduleQualifier,
        target = retagNameRef target,
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

walkHandleExpr :: HandleExpression Constrained -> Zonk (HandleExpression Zonked)
walkHandleExpr HandleExpression {parallel, stateVariables, handlers, thenClause, body, sourceSpan, typeOf} = do
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
  body' <- walkBlock body
  typeOf' <- zonkType sourceSpan typeOf
  pure
    HandleExpression
      { parallel = parallel,
        stateVariables = stateVariables',
        handlers = handlers',
        thenClause = thenClause',
        body = body',
        sourceSpan = sourceSpan,
        typeOf = typeOf'
      }

walkParTupleExpr :: ParTupleExpression Constrained -> Zonk (ParTupleExpression Zonked)
walkParTupleExpr ParTupleExpression {elements, sourceSpan, typeOf} = do
  elements' <- mapM walkExpression elements
  typeOf' <- zonkType sourceSpan typeOf
  pure ParTupleExpression {elements = elements', sourceSpan = sourceSpan, typeOf = typeOf'}

walkParArrayExpr :: ParArrayExpression Constrained -> Zonk (ParArrayExpression Zonked)
walkParArrayExpr ParArrayExpression {elements, sourceSpan, typeOf} = do
  elements' <- mapM walkExpression elements
  typeOf' <- zonkType sourceSpan typeOf
  pure ParArrayExpression {elements = elements', sourceSpan = sourceSpan, typeOf = typeOf'}

-- ===========================================================================
-- Entry point
-- ===========================================================================

-- | Zonk one SCC's constrained AST + type environment against the
-- Solver's substitutions. Returns the zonked module + the SCC's
-- resolved type environment. @variables@ is a (qname → 'VariableData')
-- map covering anything that might appear as 'ResolvedTopLevel' in the
-- environment — used only to attach source spans to type-substitution
-- errors.
zonk ::
  Map QualifiedName VariableData ->
  ConstraintGenResult ->
  SolverResult ->
  (ModuleZonkResult, [ZonkError])
zonk variables cgResult solverResult =
  let action =
        (,)
          <$> walkModule cgResult.constrainedModule
          <*> Map.traverseWithKey zonkEnvEntry cgResult.typeEnvironment
      ((zonkedModule_, envResult), errs) = runState (runReaderT action solverResult) []
      result =
        ModuleZonkResult
          { zonkedModule = zonkedModule_,
            zonkedTypeEnv = envResult
          }
   in (result, reverse errs)
  where
    zonkEnvEntry resolution t =
      let sourceSpan = case resolution of
            ResolvedTopLevel qualifiedName ->
              case Map.lookup qualifiedName variables of
                Just variableData -> variableData.variableSourceSpan
                Nothing -> emptySourceSpan
            ResolvedLocal _ -> emptySourceSpan
       in zonkType sourceSpan t
