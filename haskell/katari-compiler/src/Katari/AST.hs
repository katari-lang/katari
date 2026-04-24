module Katari.AST where

import Data.Kind (Type)
import Data.Text (Text)
import GHC.TypeLits (Symbol)

data Position = Position
  { line :: Int,
    column :: Int
  }
  deriving (Eq, Show)

data SourceSpan = SrcSpan
  { filePath :: FilePath,
    start :: Position,
    end :: Position
  }
  deriving (Eq, Show)

-- | Generic accessor for nodes that carry a source span. Implemented
-- uniformly by record-shaped nodes and by GADT sum types.
class HasSourceSpan node where
  sourceSpanOf :: node -> SourceSpan

-- ---------------------------------------------------------------------------
-- NameRef: a name with phase-dependent resolution metadata attached.
-- The @symbol@ kind selects the namespace (variable / type / module).
-- ---------------------------------------------------------------------------

data NameRef (metadata :: Symbol -> Type) (symbol :: Symbol) = NameRef
  { text :: Text,
    sourceSpan :: SourceSpan,
    metadata :: metadata symbol
  }

instance HasSourceSpan (NameRef metadata symbol) where
  sourceSpanOf ref = ref.sourceSpan

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

data Module (metadata :: Symbol -> Type) = Module
  { declarations :: [Declaration metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Module metadata) where
  sourceSpanOf module' = module'.sourceSpan

-- ---------------------------------------------------------------------------
-- Declarations
-- ---------------------------------------------------------------------------

data Declaration (metadata :: Symbol -> Type) where
  DeclarationAgent :: AgentDeclaration metadata -> Declaration metadata
  DeclarationRequest :: RequestDeclaration metadata -> Declaration metadata
  DeclarationImport :: ImportDeclaration metadata -> Declaration metadata
  DeclarationExternalAgent :: ExternalAgentDeclaration metadata -> Declaration metadata
  DeclarationEnum :: EnumDeclaration metadata -> Declaration metadata

instance HasSourceSpan (Declaration metadata) where
  sourceSpanOf = \case
    DeclarationAgent declaration -> declaration.sourceSpan
    DeclarationRequest declaration -> declaration.sourceSpan
    DeclarationImport declaration -> declaration.sourceSpan
    DeclarationExternalAgent declaration -> declaration.sourceSpan
    DeclarationEnum declaration -> declaration.sourceSpan

data AgentDeclaration (metadata :: Symbol -> Type) = AgentDeclaration
  { annotation :: Maybe Text,
    name :: NameRef metadata "variable-ref",
    parameters :: [ParameterBinding metadata],
    returnType :: Maybe (SyntacticType metadata),
    withEffects :: Maybe [SyntacticRequest metadata],
    body :: Block metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (AgentDeclaration metadata) where
  sourceSpanOf declaration = declaration.sourceSpan

data RequestDeclaration (metadata :: Symbol -> Type) = RequestDeclaration
  { annotation :: Maybe Text,
    name :: NameRef metadata "variable-ref",
    parameters :: [ParameterBinding metadata],
    returnType :: SyntacticType metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RequestDeclaration metadata) where
  sourceSpanOf declaration = declaration.sourceSpan

data ImportDeclaration (metadata :: Symbol -> Type) = ImportDeclaration
  { kind :: ImportKind,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ImportDeclaration metadata) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | Import shape. Not parameterised by metadata: import names are resolved
-- by the Identifier pass and the result is stored in scope tables rather
-- than in the AST. The module path is a dot-joined @Text@ used as the
-- registry key.
data ImportKind where
  ImportNames :: {names :: [Text], moduleName :: Text} -> ImportKind
  ImportModule :: {moduleName :: Text, alias :: Maybe Text} -> ImportKind
  deriving (Eq, Show)

data ExternalAgentDeclaration (metadata :: Symbol -> Type) = ExternalAgentDeclaration
  { annotation :: Maybe Text,
    name :: NameRef metadata "variable-ref",
    parameters :: [ParameterBinding metadata],
    returnType :: SyntacticType metadata,
    withEffects :: [SyntacticRequest metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ExternalAgentDeclaration metadata) where
  sourceSpanOf declaration = declaration.sourceSpan

data EnumDeclaration (metadata :: Symbol -> Type) = EnumDeclaration
  { annotation :: Maybe Text,
    name :: NameRef metadata "type-ref",
    -- | as "discriminator" (Nothing → default discriminator "type").
    discriminator :: Maybe Text,
    constructors :: [ConstructorDeclaration metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (EnumDeclaration metadata) where
  sourceSpanOf declaration = declaration.sourceSpan

data ConstructorDeclaration (metadata :: Symbol -> Type) = ConstructorDeclaration
  { annotation :: Maybe Text,
    name :: NameRef metadata "variable-ref",
    -- | Nothing → bare constructor (represented as a string literal).
    parameters :: Maybe [ConstructorParameter metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ConstructorDeclaration metadata) where
  sourceSpanOf declaration = declaration.sourceSpan

data ConstructorParameter (metadata :: Symbol -> Type) = ConstructorParameter
  { annotation :: Maybe Text,
    -- | Parameter label is kept as bare text per the Identifier-pass scope
    -- rules: parameter names live in a per-object namespace, not in the
    -- global value namespace.
    name :: Text,
    parameterType :: SyntacticType metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ConstructorParameter metadata) where
  sourceSpanOf parameter = parameter.sourceSpan

-- ---------------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------------

data Block (metadata :: Symbol -> Type) = Block
  { statements :: [Statement metadata],
    -- | Trailing expression without semicolon (Rust-style return value).
    returnExpression :: Maybe (Expression metadata),
    -- | where (...) { ... } then(pat) { ... }
    whereBlock :: Maybe (WhereBlock metadata),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Block metadata) where
  sourceSpanOf block = block.sourceSpan

data WhereBlock (metadata :: Symbol -> Type) = WhereBlock
  { stateVariables :: [StateVariableBinding metadata],
    handlers :: [RequestHandler metadata],
    thenClause :: Maybe (Pattern metadata, Block metadata),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (WhereBlock metadata) where
  sourceSpanOf whereBlock = whereBlock.sourceSpan

data StateVariableBinding (metadata :: Symbol -> Type) = StateVariableBinding
  { name :: NameRef metadata "variable-ref",
    typeAnnotation :: Maybe (SyntacticType metadata),
    initial :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (StateVariableBinding metadata) where
  sourceSpanOf binding = binding.sourceSpan

data Statement (metadata :: Symbol -> Type) where
  StatementLet :: LetStatement metadata -> Statement metadata
  StatementAgent :: AgentStatement metadata -> Statement metadata
  StatementReturn :: ReturnStatement metadata -> Statement metadata
  StatementExpression :: Expression metadata -> Statement metadata
  StatementNext :: NextStatement metadata -> Statement metadata
  StatementBreak :: BreakStatement metadata -> Statement metadata
  StatementForNext :: ForNextStatement metadata -> Statement metadata
  StatementForBreak :: ForBreakStatement metadata -> Statement metadata

instance HasSourceSpan (Statement metadata) where
  sourceSpanOf = \case
    StatementLet statement -> statement.sourceSpan
    StatementAgent statement -> statement.sourceSpan
    StatementReturn statement -> statement.sourceSpan
    StatementExpression expression -> sourceSpanOf expression
    StatementNext statement -> statement.sourceSpan
    StatementBreak statement -> statement.sourceSpan
    StatementForNext statement -> statement.sourceSpan
    StatementForBreak statement -> statement.sourceSpan

data LetStatement (metadata :: Symbol -> Type) = LetStatement
  { name :: Pattern metadata,
    value :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (LetStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data AgentStatement (metadata :: Symbol -> Type) = AgentStatement
  { name :: NameRef metadata "variable-ref",
    parameters :: [ParameterBinding metadata],
    returnType :: Maybe (SyntacticType metadata),
    withEffects :: Maybe [SyntacticRequest metadata],
    body :: Block metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (AgentStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data ReturnStatement (metadata :: Symbol -> Type) = ReturnStatement
  { value :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ReturnStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data NextStatement (metadata :: Symbol -> Type) = NextStatement
  { value :: Expression metadata,
    modifiers :: [Modifier metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (NextStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data BreakStatement (metadata :: Symbol -> Type) = BreakStatement
  { value :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (BreakStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data ForNextStatement (metadata :: Symbol -> Type) = ForNextStatement
  { modifiers :: [Modifier metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForNextStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data ForBreakStatement (metadata :: Symbol -> Type) = ForBreakStatement
  { value :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForBreakStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data Modifier (metadata :: Symbol -> Type) = Modifier
  { name :: NameRef metadata "variable-ref",
    value :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Modifier metadata) where
  sourceSpanOf modifier = modifier.sourceSpan

data RequestHandler (metadata :: Symbol -> Type) = RequestHandler
  { name :: NameRef metadata "variable-ref",
    parameters :: [ParameterBinding metadata],
    returnType :: Maybe (SyntacticType metadata),
    withEffects :: Maybe [SyntacticRequest metadata],
    body :: Block metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RequestHandler metadata) where
  sourceSpanOf handler = handler.sourceSpan

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

data Pattern (metadata :: Symbol -> Type) where
  PatternVariable :: VariablePattern metadata -> Pattern metadata
  PatternConstructor :: ConstructorPattern metadata -> Pattern metadata
  PatternTuple :: TuplePattern metadata -> Pattern metadata
  PatternWildcard :: WildcardPattern metadata -> Pattern metadata
  PatternLiteral :: LiteralPattern metadata -> Pattern metadata

instance HasSourceSpan (Pattern metadata) where
  sourceSpanOf = \case
    PatternVariable pattern' -> pattern'.sourceSpan
    PatternConstructor pattern' -> pattern'.sourceSpan
    PatternTuple pattern' -> pattern'.sourceSpan
    PatternWildcard pattern' -> pattern'.sourceSpan
    PatternLiteral pattern' -> pattern'.sourceSpan

data TuplePattern (metadata :: Symbol -> Type) = TuplePattern
  { elements :: [Pattern metadata],
    sourceSpan :: SourceSpan,
    metadata :: metadata "pattern"
  }

instance HasSourceSpan (TuplePattern metadata) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data WildcardPattern (metadata :: Symbol -> Type) = WildcardPattern
  { typeAnnotation :: Maybe (SyntacticType metadata),
    sourceSpan :: SourceSpan,
    metadata :: metadata "pattern"
  }

instance HasSourceSpan (WildcardPattern metadata) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data VariablePattern (metadata :: Symbol -> Type) = VariablePattern
  { name :: NameRef metadata "variable-ref",
    typeAnnotation :: Maybe (SyntacticType metadata),
    sourceSpan :: SourceSpan,
    metadata :: metadata "pattern"
  }

instance HasSourceSpan (VariablePattern metadata) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data ParameterBinding (metadata :: Symbol -> Type) = ParameterBinding
  { annotation :: Maybe Text,
    -- | External call label stays as text (per Identifier-pass policy).
    label :: Text,
    pattern :: Pattern metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ParameterBinding metadata) where
  sourceSpanOf binding = binding.sourceSpan

data ConstructorPattern (metadata :: Symbol -> Type) = ConstructorPattern
  { -- | Constructor name lives in the value namespace.
    constructorName :: NameRef metadata "variable-ref",
    -- | Field label names. The "label-ref" symbol carries no payload at
    -- Identifier pass time; the Typechecker fills in the resolution once the
    -- constructor's parameter list is known.
    parameters :: [(NameRef metadata "label-ref", Pattern metadata)],
    sourceSpan :: SourceSpan,
    metadata :: metadata "pattern"
  }

instance HasSourceSpan (ConstructorPattern metadata) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data LiteralPattern (metadata :: Symbol -> Type) = LiteralPattern
  { value :: LiteralValue,
    sourceSpan :: SourceSpan,
    metadata :: metadata "pattern"
  }

instance HasSourceSpan (LiteralPattern metadata) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data LiteralValue where
  LiteralValueInteger :: Integer -> LiteralValue
  LiteralValueNumber :: Double -> LiteralValue
  LiteralValueString :: Text -> LiteralValue
  LiteralValueBoolean :: Bool -> LiteralValue
  LiteralValueNull :: LiteralValue
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

data SyntacticType (metadata :: Symbol -> Type) where
  TypePrimitive :: PrimitiveTypeNode metadata -> SyntacticType metadata
  TypeName :: TypeNameNode metadata -> SyntacticType metadata
  TypeFunction :: FunctionTypeNode metadata -> SyntacticType metadata
  TypeArray :: ArrayTypeNode metadata -> SyntacticType metadata
  TypeTuple :: TupleTypeNode metadata -> SyntacticType metadata
  -- | @module.TypeName@ qualified reference.
  TypeQualified :: QualifiedTypeNode metadata -> SyntacticType metadata

instance HasSourceSpan (SyntacticType metadata) where
  sourceSpanOf = \case
    TypePrimitive node -> node.sourceSpan
    TypeName node -> node.sourceSpan
    TypeFunction node -> node.sourceSpan
    TypeArray node -> node.sourceSpan
    TypeTuple node -> node.sourceSpan
    TypeQualified node -> node.sourceSpan

data PrimitiveTypeKind where
  PrimitiveTypeKindNull :: PrimitiveTypeKind
  PrimitiveTypeKindInteger :: PrimitiveTypeKind
  PrimitiveTypeKindNumber :: PrimitiveTypeKind
  PrimitiveTypeKindString :: PrimitiveTypeKind
  PrimitiveTypeKindBoolean :: PrimitiveTypeKind
  deriving (Eq, Show)

data PrimitiveTypeNode (metadata :: Symbol -> Type) = PrimitiveTypeNode
  { kind :: PrimitiveTypeKind,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (PrimitiveTypeNode metadata) where
  sourceSpanOf node = node.sourceSpan

data TypeNameNode (metadata :: Symbol -> Type) = TypeNameNode
  { name :: NameRef metadata "type-ref",
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeNameNode metadata) where
  sourceSpanOf node = node.sourceSpan

data FunctionTypeNode (metadata :: Symbol -> Type) = FunctionTypeNode
  { -- | Function-parameter labels live in a per-object namespace.
    parameterTypes :: [(Text, SyntacticType metadata)],
    returnType :: SyntacticType metadata,
    withEffects :: [SyntacticRequest metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (FunctionTypeNode metadata) where
  sourceSpanOf node = node.sourceSpan

data ArrayTypeNode (metadata :: Symbol -> Type) = ArrayTypeNode
  { elementType :: SyntacticType metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ArrayTypeNode metadata) where
  sourceSpanOf node = node.sourceSpan

data TupleTypeNode (metadata :: Symbol -> Type) = TupleTypeNode
  { elementTypes :: [SyntacticType metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TupleTypeNode metadata) where
  sourceSpanOf node = node.sourceSpan

data QualifiedTypeNode (metadata :: Symbol -> Type) = QualifiedTypeNode
  { qualifier :: NameRef metadata "module-ref",
    target :: NameRef metadata "type-ref",
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (QualifiedTypeNode metadata) where
  sourceSpanOf node = node.sourceSpan

data SyntacticRequest (metadata :: Symbol -> Type) = SyntacticRequest
  { name :: NameRef metadata "variable-ref",
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (SyntacticRequest metadata) where
  sourceSpanOf request = request.sourceSpan

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------

data Expression (metadata :: Symbol -> Type) where
  ExpressionLiteral :: LiteralExpression metadata -> Expression metadata
  ExpressionVariable :: VariableExpression metadata -> Expression metadata
  ExpressionTuple :: TupleExpression metadata -> Expression metadata
  ExpressionArray :: ArrayExpression metadata -> Expression metadata
  ExpressionCall :: CallExpression metadata -> Expression metadata
  ExpressionBinaryOperator :: BinaryOperatorExpression metadata -> Expression metadata
  ExpressionUnaryOperator :: UnaryOperatorExpression metadata -> Expression metadata
  ExpressionIf :: IfExpression metadata -> Expression metadata
  ExpressionMatch :: MatchExpression metadata -> Expression metadata
  ExpressionFor :: ForExpression metadata -> Expression metadata
  ExpressionBlock :: BlockExpression metadata -> Expression metadata
  ExpressionFieldAccess :: FieldAccessExpression metadata -> Expression metadata
  ExpressionIndexAccess :: IndexAccessExpression metadata -> Expression metadata
  ExpressionTemplate :: TemplateExpression metadata -> Expression metadata
  -- | Synthesised by the Identifier pass from @FieldAccessExpression@ when the
  -- object resolves to a module alias. Parser never produces this directly.
  ExpressionQualifiedReference :: QualifiedReferenceExpression metadata -> Expression metadata

instance HasSourceSpan (Expression metadata) where
  sourceSpanOf = \case
    ExpressionLiteral expression -> expression.sourceSpan
    ExpressionVariable expression -> expression.sourceSpan
    ExpressionTuple expression -> expression.sourceSpan
    ExpressionArray expression -> expression.sourceSpan
    ExpressionCall expression -> expression.sourceSpan
    ExpressionBinaryOperator expression -> expression.sourceSpan
    ExpressionUnaryOperator expression -> expression.sourceSpan
    ExpressionIf expression -> expression.sourceSpan
    ExpressionMatch expression -> expression.sourceSpan
    ExpressionFor expression -> expression.sourceSpan
    ExpressionBlock expression -> expression.sourceSpan
    ExpressionFieldAccess expression -> expression.sourceSpan
    ExpressionIndexAccess expression -> expression.sourceSpan
    ExpressionTemplate expression -> expression.sourceSpan
    ExpressionQualifiedReference expression -> expression.sourceSpan

data LiteralExpression (metadata :: Symbol -> Type) = LiteralExpression
  { value :: LiteralValue,
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (LiteralExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data VariableExpression (metadata :: Symbol -> Type) = VariableExpression
  { name :: NameRef metadata "variable-ref",
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (VariableExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data CallExpression (metadata :: Symbol -> Type) = CallExpression
  { callee :: Expression metadata,
    arguments :: [CallArgument metadata],
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (CallExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data CallArgument (metadata :: Symbol -> Type) = CallArgument
  { -- | Argument label. Resolution is type-directed (depends on the callee's
    -- parameter list), so the "label-ref" symbol is filled in by the
    -- Typechecker; Identifier pass leaves it trivial.
    label :: NameRef metadata "label-ref",
    value :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (CallArgument metadata) where
  sourceSpanOf argument = argument.sourceSpan

data BinaryOperator where
  BinaryOperatorAdd :: BinaryOperator
  BinaryOperatorSubtract :: BinaryOperator
  BinaryOperatorMultiply :: BinaryOperator
  BinaryOperatorDivide :: BinaryOperator
  BinaryOperatorEqual :: BinaryOperator
  BinaryOperatorNotEqual :: BinaryOperator
  BinaryOperatorLessThan :: BinaryOperator
  BinaryOperatorLessOrEqual :: BinaryOperator
  BinaryOperatorGreaterThan :: BinaryOperator
  BinaryOperatorGreaterOrEqual :: BinaryOperator
  BinaryOperatorAnd :: BinaryOperator
  BinaryOperatorOr :: BinaryOperator
  BinaryOperatorConcat :: BinaryOperator
  deriving (Eq, Show)

data UnaryOperator where
  UnaryOperatorNegate :: UnaryOperator
  UnaryOperatorNot :: UnaryOperator
  deriving (Eq, Show)

data BinaryOperatorExpression (metadata :: Symbol -> Type) = BinaryOperatorExpression
  { operator :: BinaryOperator,
    left :: Expression metadata,
    right :: Expression metadata,
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (BinaryOperatorExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data UnaryOperatorExpression (metadata :: Symbol -> Type) = UnaryOperatorExpression
  { operator :: UnaryOperator,
    operand :: Expression metadata,
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (UnaryOperatorExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data TupleExpression (metadata :: Symbol -> Type) = TupleExpression
  { elements :: [Expression metadata],
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (TupleExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data ArrayExpression (metadata :: Symbol -> Type) = ArrayExpression
  { elements :: [Expression metadata],
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (ArrayExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data IfExpression (metadata :: Symbol -> Type) = IfExpression
  { condition :: Expression metadata,
    thenBlock :: Block metadata,
    elseBlock :: Maybe (Block metadata),
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (IfExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data MatchExpression (metadata :: Symbol -> Type) = MatchExpression
  { subject :: Expression metadata,
    cases :: [CaseArm metadata],
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (MatchExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data ForExpression (metadata :: Symbol -> Type) = ForExpression
  { inBindings :: [ForInBinding metadata],
    varBindings :: [ForVarBinding metadata],
    body :: Block metadata,
    thenBlock :: Maybe (Block metadata),
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (ForExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data ForInBinding (metadata :: Symbol -> Type) = ForInBinding
  { pattern :: Pattern metadata,
    source :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForInBinding metadata) where
  sourceSpanOf binding = binding.sourceSpan

data ForVarBinding (metadata :: Symbol -> Type) = ForVarBinding
  { name :: NameRef metadata "variable-ref",
    typeAnnotation :: Maybe (SyntacticType metadata),
    initial :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForVarBinding metadata) where
  sourceSpanOf binding = binding.sourceSpan

data BlockExpression (metadata :: Symbol -> Type) = BlockExpression
  { block :: Block metadata,
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (BlockExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data FieldAccessExpression (metadata :: Symbol -> Type) = FieldAccessExpression
  { object :: Expression metadata,
    -- | Field name. Resolution is type-directed (depends on the object's type),
    -- so the "label-ref" symbol is filled in by the Typechecker; Identifier
    -- pass leaves it trivial.
    fieldName :: NameRef metadata "label-ref",
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (FieldAccessExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data IndexAccessExpression (metadata :: Symbol -> Type) = IndexAccessExpression
  { array :: Expression metadata,
    index :: Expression metadata,
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (IndexAccessExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data TemplateExpression (metadata :: Symbol -> Type) = TemplateExpression
  { elements :: [TemplateElement metadata],
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (TemplateExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data QualifiedReferenceExpression (metadata :: Symbol -> Type) = QualifiedReferenceExpression
  { qualifier :: NameRef metadata "module-ref",
    target :: NameRef metadata "variable-ref",
    sourceSpan :: SourceSpan,
    metadata :: metadata "expression"
  }

instance HasSourceSpan (QualifiedReferenceExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data CaseArm (metadata :: Symbol -> Type) = CaseArm
  { pattern :: Pattern metadata,
    body :: Block metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (CaseArm metadata) where
  sourceSpanOf arm = arm.sourceSpan

data TemplateElement (metadata :: Symbol -> Type) where
  TemplateElementString :: TemplateStringElement metadata -> TemplateElement metadata
  TemplateElementExpression :: TemplateExpressionElement metadata -> TemplateElement metadata

instance HasSourceSpan (TemplateElement metadata) where
  sourceSpanOf = \case
    TemplateElementString element -> element.sourceSpan
    TemplateElementExpression element -> element.sourceSpan

data TemplateStringElement (metadata :: Symbol -> Type) = TemplateStringElement
  { value :: Text,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TemplateStringElement metadata) where
  sourceSpanOf element = element.sourceSpan

data TemplateExpressionElement (metadata :: Symbol -> Type) = TemplateExpressionElement
  { value :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TemplateExpressionElement metadata) where
  sourceSpanOf element = element.sourceSpan

-- ---------------------------------------------------------------------------
-- Show / Eq for any metadata phase that provides the respective instance
-- for every Symbol tag. Phase marker types (e.g. @Parsed@ in Katari.Parser)
-- live in their owning module; AST stays phase-agnostic.
-- ---------------------------------------------------------------------------

deriving instance (Show (metadata symbol)) => Show (NameRef metadata symbol)

deriving instance (forall symbol. Show (metadata symbol)) => Show (Module metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (Declaration metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (AgentDeclaration metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (RequestDeclaration metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ImportDeclaration metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ExternalAgentDeclaration metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (EnumDeclaration metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ConstructorDeclaration metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ConstructorParameter metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (Block metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (WhereBlock metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (StateVariableBinding metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (Statement metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (LetStatement metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (AgentStatement metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ReturnStatement metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (NextStatement metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (BreakStatement metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ForNextStatement metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ForBreakStatement metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (Modifier metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (RequestHandler metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (Pattern metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (TuplePattern metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (WildcardPattern metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (VariablePattern metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ParameterBinding metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ConstructorPattern metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (LiteralPattern metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (SyntacticType metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (PrimitiveTypeNode metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (TypeNameNode metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (FunctionTypeNode metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ArrayTypeNode metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (TupleTypeNode metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (QualifiedTypeNode metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (SyntacticRequest metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (Expression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (LiteralExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (VariableExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (CallExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (CallArgument metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (BinaryOperatorExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (UnaryOperatorExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (TupleExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ArrayExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (IfExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (MatchExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ForExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ForInBinding metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (ForVarBinding metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (BlockExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (FieldAccessExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (IndexAccessExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (TemplateExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (QualifiedReferenceExpression metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (CaseArm metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (TemplateElement metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (TemplateStringElement metadata)

deriving instance (forall symbol. Show (metadata symbol)) => Show (TemplateExpressionElement metadata)

deriving instance (Eq (metadata symbol)) => Eq (NameRef metadata symbol)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (Module metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (Declaration metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (AgentDeclaration metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (RequestDeclaration metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ImportDeclaration metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ExternalAgentDeclaration metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (EnumDeclaration metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ConstructorDeclaration metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ConstructorParameter metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (Block metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (WhereBlock metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (StateVariableBinding metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (Statement metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (LetStatement metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (AgentStatement metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ReturnStatement metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (NextStatement metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (BreakStatement metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ForNextStatement metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ForBreakStatement metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (Modifier metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (RequestHandler metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (Pattern metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (TuplePattern metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (WildcardPattern metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (VariablePattern metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ParameterBinding metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ConstructorPattern metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (LiteralPattern metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (SyntacticType metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (PrimitiveTypeNode metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (TypeNameNode metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (FunctionTypeNode metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ArrayTypeNode metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (TupleTypeNode metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (QualifiedTypeNode metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (SyntacticRequest metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (Expression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (LiteralExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (VariableExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (CallExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (CallArgument metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (BinaryOperatorExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (UnaryOperatorExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (TupleExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ArrayExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (IfExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (MatchExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ForExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ForInBinding metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (ForVarBinding metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (BlockExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (FieldAccessExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (IndexAccessExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (TemplateExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (QualifiedReferenceExpression metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (CaseArm metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (TemplateElement metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (TemplateStringElement metadata)

deriving instance (forall symbol. Eq (metadata symbol)) => Eq (TemplateExpressionElement metadata)
