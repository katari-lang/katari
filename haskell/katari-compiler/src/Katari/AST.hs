-- |
-- Phase-agnostic AST for the Katari language.
--
-- 各 AST ノードはコンパイラのフェーズに依存しないが、@NameRef@ など一部の
-- ノードはフェーズ固有のメタデータ (@Identified@、@Typed@ 等) を運ぶ。
-- メタデータ運搬は @metadata@ 型パラメータと @symbol :: SymbolKind@ で表現する。
-- @symbol@ は名前空間の種別 (variable / type / module / label / expression /
-- pattern) を選び、フェーズマーカーがそれに応じた payload を提供する。
--
-- Note on metadata asymmetry: @Expression@ と @Pattern@ のサブノード「のみ」
-- が将来の型情報を載せる placeholder として metadata を持つ。Module /
-- Declaration / Statement 系には現時点で型情報を載せる予定がないため、
-- no-op フィールドの増加を避けるべく metadata を持たない。必要になった時点で
-- 追加する。
module Katari.AST where

import Data.Kind (Type)
import Data.Text (Text)

data Position = Position
  { line :: Int,
    column :: Int
  }
  deriving (Eq, Ord, Show)

data SourceSpan = SrcSpan
  { filePath :: FilePath,
    start :: Position,
    end :: Position
  }
  deriving (Eq, Ord, Show)

-- | Generic accessor for nodes that carry a source span. Implemented
-- uniformly by record-shaped nodes and by GADT sum types.
class HasSourceSpan node where
  sourceSpanOf :: node -> SourceSpan

-- ---------------------------------------------------------------------------
-- SymbolKind: 名前空間の種別を型レベルで分類するためのデータ kind。
-- ---------------------------------------------------------------------------

data SymbolKind
  = -- | 値空間の名前参照 (agent / req / ext agent / constructor / local var)。
    -- Constructor は値空間に住む (関数として提供される) ため、専用 kind は設けない。
    VariableRef
  | -- | 型空間の名前参照 (enum 名、TypeName)。
    TypeRef
  | -- | モジュール空間の名前参照 (import alias、qualified の左辺)。
    ModuleRef
  | -- | フィールド・引数ラベル (型指向で後段が解決)。
    LabelRef
  | -- | Expression ノードに付ける placeholder 用シンボル。
    Expression
  | -- | Pattern ノードに付ける placeholder 用シンボル。
    Pattern
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Show / Eq constraint synonyms
--
-- 各 AST 型が @forall sym. Show (metadata sym)@ の形の制約を必要とするので、
-- 短縮用のシノニムを用意する。
-- ---------------------------------------------------------------------------

type ShowMetadata m = forall sym. Show (m sym)

type EqMetadata m = forall sym. Eq (m sym)

-- ---------------------------------------------------------------------------
-- NameRef: a name with phase-dependent resolution metadata attached.
-- @symbol@ で名前空間種別を選ぶ。
-- ---------------------------------------------------------------------------

data NameRef (metadata :: SymbolKind -> Type) (symbol :: SymbolKind) = NameRef
  { text :: Text,
    sourceSpan :: SourceSpan,
    metadata :: metadata symbol
  }

instance HasSourceSpan (NameRef metadata symbol) where
  sourceSpanOf ref = ref.sourceSpan

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

data Module (metadata :: SymbolKind -> Type) = Module
  { declarations :: [Declaration metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Module metadata) where
  sourceSpanOf module' = module'.sourceSpan

-- ---------------------------------------------------------------------------
-- Declarations
-- ---------------------------------------------------------------------------

data Declaration (metadata :: SymbolKind -> Type) where
  DeclarationAgent :: AgentDeclaration metadata -> Declaration metadata
  DeclarationRequest :: RequestDeclaration metadata -> Declaration metadata
  DeclarationImport :: ImportDeclaration metadata -> Declaration metadata
  DeclarationExternalAgent :: ExternalAgentDeclaration metadata -> Declaration metadata
  DeclarationData :: DataDeclaration metadata -> Declaration metadata
  DeclarationTypeSynonym :: TypeSynonymDeclaration metadata -> Declaration metadata
  -- | Structural sentinel left behind when parser recovery skipped over a
  -- broken declaration. Carries only the source span; the structured error
  -- detail lives in the parallel @[ParseError]@ list returned alongside the
  -- module. Lookup by 'sourceSpan' (1:1 with the corresponding 'ParseError').
  DeclarationError :: SourceSpan -> Declaration metadata

instance HasSourceSpan (Declaration metadata) where
  sourceSpanOf = \case
    DeclarationAgent declaration -> declaration.sourceSpan
    DeclarationRequest declaration -> declaration.sourceSpan
    DeclarationImport declaration -> declaration.sourceSpan
    DeclarationExternalAgent declaration -> declaration.sourceSpan
    DeclarationData declaration -> declaration.sourceSpan
    DeclarationTypeSynonym declaration -> declaration.sourceSpan
    DeclarationError sourceSpan -> sourceSpan

data AgentDeclaration (metadata :: SymbolKind -> Type) = AgentDeclaration
  { annotation :: Maybe Text,
    name :: NameRef metadata 'VariableRef,
    parameters :: [ParameterBinding metadata],
    returnType :: Maybe (SyntacticType metadata),
    withEffects :: Maybe [SyntacticRequest metadata],
    body :: Block metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (AgentDeclaration metadata) where
  sourceSpanOf declaration = declaration.sourceSpan

data RequestDeclaration (metadata :: SymbolKind -> Type) = RequestDeclaration
  { annotation :: Maybe Text,
    name :: NameRef metadata 'VariableRef,
    parameters :: [ParameterBinding metadata],
    returnType :: SyntacticType metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RequestDeclaration metadata) where
  sourceSpanOf declaration = declaration.sourceSpan

data ImportDeclaration (metadata :: SymbolKind -> Type) = ImportDeclaration
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
  ImportNames :: {items :: [ImportItem], moduleName :: Text} -> ImportKind
  ImportModule :: {moduleName :: Text, alias :: Maybe Text} -> ImportKind
  deriving (Eq, Show)

-- | One name brought into scope by @import { ... } from ...@.
-- @kind@ で type 名前空間か value 名前空間かを区別する。
data ImportItem = ImportItem
  { kind :: ImportItemKind,
    name :: Text
  }
  deriving (Eq, Show)

data ImportItemKind where
  -- | 通常の値 import。
  ImportItemValue :: ImportItemKind
  -- | @type@ prefix が付いた import。型名前空間に取り込む。
  ImportItemType :: ImportItemKind
  deriving (Eq, Show)

data ExternalAgentDeclaration (metadata :: SymbolKind -> Type) = ExternalAgentDeclaration
  { annotation :: Maybe Text,
    name :: NameRef metadata 'VariableRef,
    parameters :: [ParameterBinding metadata],
    returnType :: SyntacticType metadata,
    withEffects :: [SyntacticRequest metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ExternalAgentDeclaration metadata) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | @data ctor_name(field: type, ...)@ — 1 declaration につき 1 constructor。
-- 同じ名前で値空間 (constructor 関数) と型空間 (data 型) の両方を導入する。
--
-- AST 上は両 role を別 'NameRef' として保持する: @name@ が値空間 (constructor
-- 関数) を、@typeName@ が型空間 (data 型) を指す。Parser は同一の identifier
-- token から両者を生成し (text と sourceSpan は共有)、Identifier フェーズが
-- 各々を独立に解決して metadata に固有の id (VariableId / TypeId) を埋める。
-- 後段 (ConstraintGenerator 以降) は AST から直接 TypeId を読めるので、
-- 名前テキストによる横断検索は不要。
data DataDeclaration (metadata :: SymbolKind -> Type) = DataDeclaration
  { annotation :: Maybe Text,
    name :: NameRef metadata 'VariableRef,
    typeName :: NameRef metadata 'TypeRef,
    parameters :: [DataParameter metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (DataDeclaration metadata) where
  sourceSpanOf declaration = declaration.sourceSpan

data DataParameter (metadata :: SymbolKind -> Type) = DataParameter
  { annotation :: Maybe Text,
    -- | Field label is kept as bare text per the Identifier-pass scope
    -- rules: field labels live in a per-object namespace.
    name :: Text,
    parameterType :: SyntacticType metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (DataParameter metadata) where
  sourceSpanOf parameter = parameter.sourceSpan

-- | @type T = ...@ — 型シノニム。annotation はなし、generics もなし。
data TypeSynonymDeclaration (metadata :: SymbolKind -> Type) = TypeSynonymDeclaration
  { name :: NameRef metadata 'TypeRef,
    rhs :: SyntacticType metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeSynonymDeclaration metadata) where
  sourceSpanOf declaration = declaration.sourceSpan

-- ---------------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------------

data Block (metadata :: SymbolKind -> Type) = Block
  { statements :: [Statement metadata],
    -- | Trailing expression without semicolon (Rust-style return value).
    returnExpression :: Maybe (Expression metadata),
    -- | where (...) { ... } then(pat) { ... }
    whereBlock :: Maybe (WhereBlock metadata),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Block metadata) where
  sourceSpanOf block = block.sourceSpan

data WhereBlock (metadata :: SymbolKind -> Type) = WhereBlock
  { stateVariables :: [StateVariableBinding metadata],
    handlers :: [RequestHandler metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (WhereBlock metadata) where
  sourceSpanOf whereBlock = whereBlock.sourceSpan

data StateVariableBinding (metadata :: SymbolKind -> Type) = StateVariableBinding
  { name :: NameRef metadata 'VariableRef,
    typeAnnotation :: Maybe (SyntacticType metadata),
    initial :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (StateVariableBinding metadata) where
  sourceSpanOf binding = binding.sourceSpan

data Statement (metadata :: SymbolKind -> Type) where
  StatementLet :: LetStatement metadata -> Statement metadata
  StatementAgent :: AgentStatement metadata -> Statement metadata
  StatementReturn :: ReturnStatement metadata -> Statement metadata
  StatementExpression :: Expression metadata -> Statement metadata
  StatementNext :: NextStatement metadata -> Statement metadata
  StatementBreak :: BreakStatement metadata -> Statement metadata
  StatementForNext :: ForNextStatement metadata -> Statement metadata
  StatementForBreak :: ForBreakStatement metadata -> Statement metadata
  -- | Structural sentinel left by parser statement-level recovery. Same
  -- pattern as 'DeclarationError': span only, error detail in the parallel
  -- @[ParseError]@ list.
  StatementError :: SourceSpan -> Statement metadata

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
    StatementError sourceSpan -> sourceSpan

data LetStatement (metadata :: SymbolKind -> Type) = LetStatement
  { pattern :: Pattern metadata,
    value :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (LetStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data AgentStatement (metadata :: SymbolKind -> Type) = AgentStatement
  { name :: NameRef metadata 'VariableRef,
    parameters :: [ParameterBinding metadata],
    returnType :: Maybe (SyntacticType metadata),
    withEffects :: Maybe [SyntacticRequest metadata],
    body :: Block metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (AgentStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data ReturnStatement (metadata :: SymbolKind -> Type) = ReturnStatement
  { value :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ReturnStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data NextStatement (metadata :: SymbolKind -> Type) = NextStatement
  { value :: Expression metadata,
    modifiers :: [Modifier metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (NextStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data BreakStatement (metadata :: SymbolKind -> Type) = BreakStatement
  { value :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (BreakStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data ForNextStatement (metadata :: SymbolKind -> Type) = ForNextStatement
  { modifiers :: [Modifier metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForNextStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data ForBreakStatement (metadata :: SymbolKind -> Type) = ForBreakStatement
  { value :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForBreakStatement metadata) where
  sourceSpanOf statement = statement.sourceSpan

data Modifier (metadata :: SymbolKind -> Type) = Modifier
  { name :: NameRef metadata 'VariableRef,
    value :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Modifier metadata) where
  sourceSpanOf modifier = modifier.sourceSpan

-- | @req name(...) { body }@ または @req module.name(...) { body }@。
-- @name@ は新規 binding ではなく既存の req 宣言への参照。@moduleQualifier@ が
-- @Just@ の場合は他モジュールの req を実装する形。
-- | req handler は自身の effect 集合を持たない (handler 内の effect は
-- 囲む agent に bind されるため)。よって @with@ 節は構文上も AST 上も無い。
data RequestHandler (metadata :: SymbolKind -> Type) = RequestHandler
  { moduleQualifier :: Maybe (NameRef metadata 'ModuleRef),
    name :: NameRef metadata 'VariableRef,
    parameters :: [ParameterBinding metadata],
    returnType :: Maybe (SyntacticType metadata),
    body :: Block metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RequestHandler metadata) where
  sourceSpanOf handler = handler.sourceSpan

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

data Pattern (metadata :: SymbolKind -> Type) where
  PatternVariable :: VariablePattern metadata -> Pattern metadata
  PatternQualifiedConstructor :: QualifiedConstructorPattern metadata -> Pattern metadata
  PatternTuple :: TuplePattern metadata -> Pattern metadata
  PatternWildcard :: WildcardPattern metadata -> Pattern metadata
  PatternLiteral :: LiteralPattern metadata -> Pattern metadata

instance HasSourceSpan (Pattern metadata) where
  sourceSpanOf = \case
    PatternVariable pattern' -> pattern'.sourceSpan
    PatternQualifiedConstructor pattern' -> pattern'.sourceSpan
    PatternTuple pattern' -> pattern'.sourceSpan
    PatternWildcard pattern' -> pattern'.sourceSpan
    PatternLiteral pattern' -> pattern'.sourceSpan

data TuplePattern (metadata :: SymbolKind -> Type) = TuplePattern
  { elements :: [Pattern metadata],
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Pattern
  }

instance HasSourceSpan (TuplePattern metadata) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data WildcardPattern (metadata :: SymbolKind -> Type) = WildcardPattern
  { typeAnnotation :: Maybe (SyntacticType metadata),
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Pattern
  }

instance HasSourceSpan (WildcardPattern metadata) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data VariablePattern (metadata :: SymbolKind -> Type) = VariablePattern
  { name :: NameRef metadata 'VariableRef,
    typeAnnotation :: Maybe (SyntacticType metadata),
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Pattern
  }

instance HasSourceSpan (VariablePattern metadata) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data ParameterBinding (metadata :: SymbolKind -> Type) = ParameterBinding
  { annotation :: Maybe Text,
    -- | External call label stays as text (per Identifier-pass policy).
    label :: Text,
    pattern :: Pattern metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ParameterBinding metadata) where
  sourceSpanOf binding = binding.sourceSpan

-- | Constructor pattern. Constructor は所属モジュールのトップレベル variable
-- namespace に flat 展開されるため、bare @ctor(...)@ または @module.ctor(...)@
-- の二形式のみ。@type.ctor@ 構文は廃止。
--
-- パーサーは pattern position で @ident(...)@ / @ident.ident(...)@ を見たら
-- これを生成する (lookahead で @(@ を確認)。bare @ident@ (no parens) は
-- 'VariablePattern' のまま。
data QualifiedConstructorPattern (metadata :: SymbolKind -> Type) = QualifiedConstructorPattern
  { -- | Optional module qualifier (left-most segment).
    moduleQualifier :: Maybe (NameRef metadata 'ModuleRef),
    -- | Constructor name (lives in the value namespace).
    constructorName :: NameRef metadata 'VariableRef,
    -- | Field labels and their patterns. Label resolution is type-directed.
    parameters :: [(NameRef metadata 'LabelRef, Pattern metadata)],
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Pattern
  }

instance HasSourceSpan (QualifiedConstructorPattern metadata) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data LiteralPattern (metadata :: SymbolKind -> Type) = LiteralPattern
  { value :: LiteralValue,
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Pattern
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

data SyntacticType (metadata :: SymbolKind -> Type) where
  TypePrimitive :: PrimitiveTypeNode metadata -> SyntacticType metadata
  TypeName :: TypeNameNode metadata -> SyntacticType metadata
  TypeFunction :: FunctionTypeNode metadata -> SyntacticType metadata
  TypeArray :: ArrayTypeNode metadata -> SyntacticType metadata
  TypeTuple :: TupleTypeNode metadata -> SyntacticType metadata
  -- | @module.TypeName@ qualified reference.
  TypeQualified :: QualifiedTypeNode metadata -> SyntacticType metadata
  -- | Type-level literal: @"foo"@ / @42@ / @true@ / @false@ / @null@。
  -- 値レベルの 'LiteralValue' を再利用する (Float は対象外)。
  TypeLiteral :: TypeLiteralNode -> SyntacticType metadata
  -- | @T1 | T2 | ...@ union type。precedence は最低 (function/array より弱い)。
  -- 2 個以上の branch を持つ。順序保持。
  TypeUnion :: TypeUnionNode metadata -> SyntacticType metadata
  -- | @never@ — lattice の bottom 型。値を持たない。@agent f() -> never@ 等で
  -- 「絶対に return しない」を明示する用途。
  TypeNever :: NeverTypeNode metadata -> SyntacticType metadata
  -- | @unknown@ — lattice の top 型。任意の値を許容するが、利用側で必ず
  -- narrow する必要がある (TypeScript の @unknown@ と同じ思想)。
  TypeUnknown :: UnknownTypeNode metadata -> SyntacticType metadata

instance HasSourceSpan (SyntacticType metadata) where
  sourceSpanOf = \case
    TypePrimitive node -> node.sourceSpan
    TypeName node -> node.sourceSpan
    TypeFunction node -> node.sourceSpan
    TypeArray node -> node.sourceSpan
    TypeTuple node -> node.sourceSpan
    TypeQualified node -> node.sourceSpan
    TypeLiteral node -> node.sourceSpan
    TypeUnion node -> node.sourceSpan
    TypeNever node -> node.sourceSpan
    TypeUnknown node -> node.sourceSpan

data PrimitiveTypeKind where
  PrimitiveTypeKindNull :: PrimitiveTypeKind
  PrimitiveTypeKindInteger :: PrimitiveTypeKind
  PrimitiveTypeKindNumber :: PrimitiveTypeKind
  PrimitiveTypeKindString :: PrimitiveTypeKind
  PrimitiveTypeKindBoolean :: PrimitiveTypeKind
  deriving (Eq, Show)

data PrimitiveTypeNode (metadata :: SymbolKind -> Type) = PrimitiveTypeNode
  { kind :: PrimitiveTypeKind,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (PrimitiveTypeNode metadata) where
  sourceSpanOf node = node.sourceSpan

-- | @never@ 型の AST ノード。lattice の bottom (値を持たない型) で、
-- primitive (concrete data) ではないため別ノードに分けている。
data NeverTypeNode (metadata :: SymbolKind -> Type) = NeverTypeNode
  { sourceSpan :: SourceSpan
  }

instance HasSourceSpan (NeverTypeNode metadata) where
  sourceSpanOf node = node.sourceSpan

-- | @unknown@ 型の AST ノード。lattice の top (任意の値) で、利用側で
-- narrow が必要。primitive ではないため別ノードに分けている。
data UnknownTypeNode (metadata :: SymbolKind -> Type) = UnknownTypeNode
  { sourceSpan :: SourceSpan
  }

instance HasSourceSpan (UnknownTypeNode metadata) where
  sourceSpanOf node = node.sourceSpan

data TypeNameNode (metadata :: SymbolKind -> Type) = TypeNameNode
  { name :: NameRef metadata 'TypeRef,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeNameNode metadata) where
  sourceSpanOf node = node.sourceSpan

data FunctionTypeNode (metadata :: SymbolKind -> Type) = FunctionTypeNode
  { -- | Function-parameter labels live in a per-object namespace.
    parameterTypes :: [(Text, SyntacticType metadata)],
    returnType :: SyntacticType metadata,
    withEffects :: [SyntacticRequest metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (FunctionTypeNode metadata) where
  sourceSpanOf node = node.sourceSpan

data ArrayTypeNode (metadata :: SymbolKind -> Type) = ArrayTypeNode
  { elementType :: SyntacticType metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ArrayTypeNode metadata) where
  sourceSpanOf node = node.sourceSpan

data TupleTypeNode (metadata :: SymbolKind -> Type) = TupleTypeNode
  { elementTypes :: [SyntacticType metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TupleTypeNode metadata) where
  sourceSpanOf node = node.sourceSpan

data QualifiedTypeNode (metadata :: SymbolKind -> Type) = QualifiedTypeNode
  { qualifier :: NameRef metadata 'ModuleRef,
    target :: NameRef metadata 'TypeRef,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (QualifiedTypeNode metadata) where
  sourceSpanOf node = node.sourceSpan

-- | Type-level literal node. metadata 不変なので phase parameter なし。
data TypeLiteralNode = TypeLiteralNode
  { value :: LiteralValue,
    sourceSpan :: SourceSpan
  }
  deriving (Eq, Show)

instance HasSourceSpan TypeLiteralNode where
  sourceSpanOf node = node.sourceSpan

-- | @T1 | T2 | ...@ union type。常に 2 個以上の branch を持つ。
data TypeUnionNode (metadata :: SymbolKind -> Type) = TypeUnionNode
  { branches :: [SyntacticType metadata],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeUnionNode metadata) where
  sourceSpanOf node = node.sourceSpan

data SyntacticRequest (metadata :: SymbolKind -> Type) = SyntacticRequest
  { name :: NameRef metadata 'VariableRef,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (SyntacticRequest metadata) where
  sourceSpanOf request = request.sourceSpan

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------

data Expression (metadata :: SymbolKind -> Type) where
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
  -- | Synthesised by the Identifier pass from a @FieldAccess@ chain whose
  -- left-most segment resolves to a module. 詳細は 'QualifiedReferenceExpression'
  -- のコメント参照。Parser never produces this directly.
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

data LiteralExpression (metadata :: SymbolKind -> Type) = LiteralExpression
  { value :: LiteralValue,
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (LiteralExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data VariableExpression (metadata :: SymbolKind -> Type) = VariableExpression
  { name :: NameRef metadata 'VariableRef,
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (VariableExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data CallExpression (metadata :: SymbolKind -> Type) = CallExpression
  { callee :: Expression metadata,
    arguments :: [CallArgument metadata],
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (CallExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data CallArgument (metadata :: SymbolKind -> Type) = CallArgument
  { -- | Argument label. Resolution is type-directed (depends on the callee's
    -- parameter list), so the LabelRef symbol is filled in by the
    -- Typechecker; Identifier pass leaves it trivial.
    label :: NameRef metadata 'LabelRef,
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

data BinaryOperatorExpression (metadata :: SymbolKind -> Type) = BinaryOperatorExpression
  { operator :: BinaryOperator,
    left :: Expression metadata,
    right :: Expression metadata,
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (BinaryOperatorExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data UnaryOperatorExpression (metadata :: SymbolKind -> Type) = UnaryOperatorExpression
  { operator :: UnaryOperator,
    operand :: Expression metadata,
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (UnaryOperatorExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data TupleExpression (metadata :: SymbolKind -> Type) = TupleExpression
  { elements :: [Expression metadata],
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (TupleExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data ArrayExpression (metadata :: SymbolKind -> Type) = ArrayExpression
  { elements :: [Expression metadata],
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (ArrayExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data IfExpression (metadata :: SymbolKind -> Type) = IfExpression
  { condition :: Expression metadata,
    thenBlock :: Block metadata,
    elseBlock :: Maybe (Block metadata),
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (IfExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data MatchExpression (metadata :: SymbolKind -> Type) = MatchExpression
  { subject :: Expression metadata,
    cases :: [CaseArm metadata],
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (MatchExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data ForExpression (metadata :: SymbolKind -> Type) = ForExpression
  { inBindings :: [ForInBinding metadata],
    varBindings :: [ForVarBinding metadata],
    body :: Block metadata,
    thenBlock :: Maybe (Block metadata),
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (ForExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data ForInBinding (metadata :: SymbolKind -> Type) = ForInBinding
  { pattern :: Pattern metadata,
    source :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForInBinding metadata) where
  sourceSpanOf binding = binding.sourceSpan

data ForVarBinding (metadata :: SymbolKind -> Type) = ForVarBinding
  { name :: NameRef metadata 'VariableRef,
    typeAnnotation :: Maybe (SyntacticType metadata),
    initial :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForVarBinding metadata) where
  sourceSpanOf binding = binding.sourceSpan

data BlockExpression (metadata :: SymbolKind -> Type) = BlockExpression
  { block :: Block metadata,
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (BlockExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data FieldAccessExpression (metadata :: SymbolKind -> Type) = FieldAccessExpression
  { object :: Expression metadata,
    -- | Field name. Resolution is type-directed (depends on the object's type),
    -- so the LabelRef symbol is filled in by the Typechecker; Identifier
    -- pass leaves it trivial.
    fieldName :: NameRef metadata 'LabelRef,
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (FieldAccessExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data IndexAccessExpression (metadata :: SymbolKind -> Type) = IndexAccessExpression
  { array :: Expression metadata,
    index :: Expression metadata,
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (IndexAccessExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data TemplateExpression (metadata :: SymbolKind -> Type) = TemplateExpression
  { elements :: [TemplateElement metadata],
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (TemplateExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

-- | 解決済み qualified 参照 @module.target@。
--
-- @target@ は値空間のシンボル (agent / req / ext agent / constructor)。
-- enum constructor も自モジュールの variable namespace に flat 展開されるため、
-- @module.ctor@ も同じ shape で表現される。
--
-- Parser は生成せず、Identifier フェーズで FieldAccess チェーンの最左が module
-- に解決された場合のみ合成する。
data QualifiedReferenceExpression (metadata :: SymbolKind -> Type) = QualifiedReferenceExpression
  { moduleQualifier :: NameRef metadata 'ModuleRef,
    target :: NameRef metadata 'VariableRef,
    sourceSpan :: SourceSpan,
    metadata :: metadata 'Expression
  }

instance HasSourceSpan (QualifiedReferenceExpression metadata) where
  sourceSpanOf expression = expression.sourceSpan

data CaseArm (metadata :: SymbolKind -> Type) = CaseArm
  { pattern :: Pattern metadata,
    body :: Block metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (CaseArm metadata) where
  sourceSpanOf arm = arm.sourceSpan

data TemplateElement (metadata :: SymbolKind -> Type) where
  TemplateElementString :: TemplateStringElement metadata -> TemplateElement metadata
  TemplateElementExpression :: TemplateExpressionElement metadata -> TemplateElement metadata

instance HasSourceSpan (TemplateElement metadata) where
  sourceSpanOf = \case
    TemplateElementString element -> element.sourceSpan
    TemplateElementExpression element -> element.sourceSpan

data TemplateStringElement (metadata :: SymbolKind -> Type) = TemplateStringElement
  { value :: Text,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TemplateStringElement metadata) where
  sourceSpanOf element = element.sourceSpan

data TemplateExpressionElement (metadata :: SymbolKind -> Type) = TemplateExpressionElement
  { value :: Expression metadata,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TemplateExpressionElement metadata) where
  sourceSpanOf element = element.sourceSpan

-- ---------------------------------------------------------------------------
-- Show / Eq for any metadata phase that provides the respective instance
-- for every SymbolKind tag.
-- ---------------------------------------------------------------------------

deriving instance (Show (metadata symbol)) => Show (NameRef metadata symbol)

deriving instance (ShowMetadata metadata) => Show (Module metadata)

deriving instance (ShowMetadata metadata) => Show (Declaration metadata)

deriving instance (ShowMetadata metadata) => Show (AgentDeclaration metadata)

deriving instance (ShowMetadata metadata) => Show (RequestDeclaration metadata)

deriving instance (ShowMetadata metadata) => Show (ImportDeclaration metadata)

deriving instance (ShowMetadata metadata) => Show (ExternalAgentDeclaration metadata)

deriving instance (ShowMetadata metadata) => Show (DataDeclaration metadata)

deriving instance (ShowMetadata metadata) => Show (DataParameter metadata)

deriving instance (ShowMetadata metadata) => Show (TypeSynonymDeclaration metadata)

deriving instance (ShowMetadata metadata) => Show (Block metadata)

deriving instance (ShowMetadata metadata) => Show (WhereBlock metadata)

deriving instance (ShowMetadata metadata) => Show (StateVariableBinding metadata)

deriving instance (ShowMetadata metadata) => Show (Statement metadata)

deriving instance (ShowMetadata metadata) => Show (LetStatement metadata)

deriving instance (ShowMetadata metadata) => Show (AgentStatement metadata)

deriving instance (ShowMetadata metadata) => Show (ReturnStatement metadata)

deriving instance (ShowMetadata metadata) => Show (NextStatement metadata)

deriving instance (ShowMetadata metadata) => Show (BreakStatement metadata)

deriving instance (ShowMetadata metadata) => Show (ForNextStatement metadata)

deriving instance (ShowMetadata metadata) => Show (ForBreakStatement metadata)

deriving instance (ShowMetadata metadata) => Show (Modifier metadata)

deriving instance (ShowMetadata metadata) => Show (RequestHandler metadata)

deriving instance (ShowMetadata metadata) => Show (Pattern metadata)

deriving instance (ShowMetadata metadata) => Show (TuplePattern metadata)

deriving instance (ShowMetadata metadata) => Show (WildcardPattern metadata)

deriving instance (ShowMetadata metadata) => Show (VariablePattern metadata)

deriving instance (ShowMetadata metadata) => Show (ParameterBinding metadata)

deriving instance (ShowMetadata metadata) => Show (QualifiedConstructorPattern metadata)

deriving instance (ShowMetadata metadata) => Show (LiteralPattern metadata)

deriving instance (ShowMetadata metadata) => Show (SyntacticType metadata)

deriving instance (ShowMetadata metadata) => Show (PrimitiveTypeNode metadata)

deriving instance (ShowMetadata metadata) => Show (NeverTypeNode metadata)

deriving instance (ShowMetadata metadata) => Show (UnknownTypeNode metadata)

deriving instance (ShowMetadata metadata) => Show (TypeNameNode metadata)

deriving instance (ShowMetadata metadata) => Show (FunctionTypeNode metadata)

deriving instance (ShowMetadata metadata) => Show (ArrayTypeNode metadata)

deriving instance (ShowMetadata metadata) => Show (TupleTypeNode metadata)

deriving instance (ShowMetadata metadata) => Show (QualifiedTypeNode metadata)

deriving instance (ShowMetadata metadata) => Show (TypeUnionNode metadata)

deriving instance (ShowMetadata metadata) => Show (SyntacticRequest metadata)

deriving instance (ShowMetadata metadata) => Show (Expression metadata)

deriving instance (ShowMetadata metadata) => Show (LiteralExpression metadata)

deriving instance (ShowMetadata metadata) => Show (VariableExpression metadata)

deriving instance (ShowMetadata metadata) => Show (CallExpression metadata)

deriving instance (ShowMetadata metadata) => Show (CallArgument metadata)

deriving instance (ShowMetadata metadata) => Show (BinaryOperatorExpression metadata)

deriving instance (ShowMetadata metadata) => Show (UnaryOperatorExpression metadata)

deriving instance (ShowMetadata metadata) => Show (TupleExpression metadata)

deriving instance (ShowMetadata metadata) => Show (ArrayExpression metadata)

deriving instance (ShowMetadata metadata) => Show (IfExpression metadata)

deriving instance (ShowMetadata metadata) => Show (MatchExpression metadata)

deriving instance (ShowMetadata metadata) => Show (ForExpression metadata)

deriving instance (ShowMetadata metadata) => Show (ForInBinding metadata)

deriving instance (ShowMetadata metadata) => Show (ForVarBinding metadata)

deriving instance (ShowMetadata metadata) => Show (BlockExpression metadata)

deriving instance (ShowMetadata metadata) => Show (FieldAccessExpression metadata)

deriving instance (ShowMetadata metadata) => Show (IndexAccessExpression metadata)

deriving instance (ShowMetadata metadata) => Show (TemplateExpression metadata)

deriving instance (ShowMetadata metadata) => Show (QualifiedReferenceExpression metadata)

deriving instance (ShowMetadata metadata) => Show (CaseArm metadata)

deriving instance (ShowMetadata metadata) => Show (TemplateElement metadata)

deriving instance (ShowMetadata metadata) => Show (TemplateStringElement metadata)

deriving instance (ShowMetadata metadata) => Show (TemplateExpressionElement metadata)

deriving instance (Eq (metadata symbol)) => Eq (NameRef metadata symbol)

deriving instance (EqMetadata metadata) => Eq (Module metadata)

deriving instance (EqMetadata metadata) => Eq (Declaration metadata)

deriving instance (EqMetadata metadata) => Eq (AgentDeclaration metadata)

deriving instance (EqMetadata metadata) => Eq (RequestDeclaration metadata)

deriving instance (EqMetadata metadata) => Eq (ImportDeclaration metadata)

deriving instance (EqMetadata metadata) => Eq (ExternalAgentDeclaration metadata)

deriving instance (EqMetadata metadata) => Eq (DataDeclaration metadata)

deriving instance (EqMetadata metadata) => Eq (DataParameter metadata)

deriving instance (EqMetadata metadata) => Eq (TypeSynonymDeclaration metadata)

deriving instance (EqMetadata metadata) => Eq (Block metadata)

deriving instance (EqMetadata metadata) => Eq (WhereBlock metadata)

deriving instance (EqMetadata metadata) => Eq (StateVariableBinding metadata)

deriving instance (EqMetadata metadata) => Eq (Statement metadata)

deriving instance (EqMetadata metadata) => Eq (LetStatement metadata)

deriving instance (EqMetadata metadata) => Eq (AgentStatement metadata)

deriving instance (EqMetadata metadata) => Eq (ReturnStatement metadata)

deriving instance (EqMetadata metadata) => Eq (NextStatement metadata)

deriving instance (EqMetadata metadata) => Eq (BreakStatement metadata)

deriving instance (EqMetadata metadata) => Eq (ForNextStatement metadata)

deriving instance (EqMetadata metadata) => Eq (ForBreakStatement metadata)

deriving instance (EqMetadata metadata) => Eq (Modifier metadata)

deriving instance (EqMetadata metadata) => Eq (RequestHandler metadata)

deriving instance (EqMetadata metadata) => Eq (Pattern metadata)

deriving instance (EqMetadata metadata) => Eq (TuplePattern metadata)

deriving instance (EqMetadata metadata) => Eq (WildcardPattern metadata)

deriving instance (EqMetadata metadata) => Eq (VariablePattern metadata)

deriving instance (EqMetadata metadata) => Eq (ParameterBinding metadata)

deriving instance (EqMetadata metadata) => Eq (QualifiedConstructorPattern metadata)

deriving instance (EqMetadata metadata) => Eq (LiteralPattern metadata)

deriving instance (EqMetadata metadata) => Eq (SyntacticType metadata)

deriving instance (EqMetadata metadata) => Eq (PrimitiveTypeNode metadata)

deriving instance (EqMetadata metadata) => Eq (NeverTypeNode metadata)

deriving instance (EqMetadata metadata) => Eq (UnknownTypeNode metadata)

deriving instance (EqMetadata metadata) => Eq (TypeNameNode metadata)

deriving instance (EqMetadata metadata) => Eq (FunctionTypeNode metadata)

deriving instance (EqMetadata metadata) => Eq (ArrayTypeNode metadata)

deriving instance (EqMetadata metadata) => Eq (TupleTypeNode metadata)

deriving instance (EqMetadata metadata) => Eq (QualifiedTypeNode metadata)

deriving instance (EqMetadata metadata) => Eq (TypeUnionNode metadata)

deriving instance (EqMetadata metadata) => Eq (SyntacticRequest metadata)

deriving instance (EqMetadata metadata) => Eq (Expression metadata)

deriving instance (EqMetadata metadata) => Eq (LiteralExpression metadata)

deriving instance (EqMetadata metadata) => Eq (VariableExpression metadata)

deriving instance (EqMetadata metadata) => Eq (CallExpression metadata)

deriving instance (EqMetadata metadata) => Eq (CallArgument metadata)

deriving instance (EqMetadata metadata) => Eq (BinaryOperatorExpression metadata)

deriving instance (EqMetadata metadata) => Eq (UnaryOperatorExpression metadata)

deriving instance (EqMetadata metadata) => Eq (TupleExpression metadata)

deriving instance (EqMetadata metadata) => Eq (ArrayExpression metadata)

deriving instance (EqMetadata metadata) => Eq (IfExpression metadata)

deriving instance (EqMetadata metadata) => Eq (MatchExpression metadata)

deriving instance (EqMetadata metadata) => Eq (ForExpression metadata)

deriving instance (EqMetadata metadata) => Eq (ForInBinding metadata)

deriving instance (EqMetadata metadata) => Eq (ForVarBinding metadata)

deriving instance (EqMetadata metadata) => Eq (BlockExpression metadata)

deriving instance (EqMetadata metadata) => Eq (FieldAccessExpression metadata)

deriving instance (EqMetadata metadata) => Eq (IndexAccessExpression metadata)

deriving instance (EqMetadata metadata) => Eq (TemplateExpression metadata)

deriving instance (EqMetadata metadata) => Eq (QualifiedReferenceExpression metadata)

deriving instance (EqMetadata metadata) => Eq (CaseArm metadata)

deriving instance (EqMetadata metadata) => Eq (TemplateElement metadata)

deriving instance (EqMetadata metadata) => Eq (TemplateStringElement metadata)

deriving instance (EqMetadata metadata) => Eq (TemplateExpressionElement metadata)
