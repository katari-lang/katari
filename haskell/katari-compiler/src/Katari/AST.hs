-- |
-- Phase-indexed AST for the Katari language.
--
-- 各 AST ノードはコンパイラのフェーズを 'Phase' tag (型レベル only,
-- TypeData) でパラメータ化する。'NameRef' は @resolution@ フィールドに
-- @NameRefResolution phase s@ (各 phase + symbol kind に応じた解決情報) を持ち、
-- expression / pattern ノードは @typeOf@ フィールドに @ExpressionType p@ /
-- @PatternType phase@ を持つ。
--
-- 設計上の重要点:
--
--   * @NameRefResolution@ は閉じた type family で、Identified / Constrained /
--     Zonked の三相について同じ shape (@Maybe Identifier@) を返す。
--     phase 推移は 'retagNameRef' / 'retagSyntacticType' 等で素通しできる。
--   * @ExpressionType@ / @PatternType@ も閉じた type family で、Parsed / Identified
--     は @()@、Constrained / Zonked は @SemanticType@ を返す。
--     'Katari.SemanticType' は leaf module なので循環しない。
--   * 'Module' / 'Declaration' / 'Statement' 系には型情報を載せる予定が
--     ないため @typeOf@ フィールドを持たない (placeholder の no-op
--     フィールドを増やさないため)。
module Katari.AST where

import Data.Kind (Type)
import Data.Text (Text)
import Katari.Id
  ( ConstructorId,
    ModuleId,
    RequestId,
    TypeId,
    VariableId,
  )
import Katari.SemanticType (Resolved, SemanticType, Unresolved)
import Katari.SourceSpan (HasSourceSpan (..), SourceSpan)

-- ---------------------------------------------------------------------------
-- NameRefKind: 'NameRef' が指す名前空間の種別。
-- ---------------------------------------------------------------------------

type data NameRefKind where
  -- | 値空間の名前参照 (agent / req / ext agent / constructor / local var)。
  -- 値として呼べる名前はすべてここを通る。
  VariableRef :: NameRefKind
  -- | 型空間の名前参照 (enum 名、TypeName)。
  TypeRef :: NameRefKind
  -- | モジュール空間の名前参照 (import alias、qualified の左辺)。
  ModuleRef :: NameRefKind
  -- | フィールド・引数ラベル (型指向で後段が解決)。
  LabelRef :: NameRefKind
  -- | req handler の対象。@req@ 宣言以外の名前を handler として書くと
  -- Identifier 段階で reject される (型レベルでスロットを分離している)。
  RequestRef :: NameRefKind
  -- | match パターンの constructor。@data@ 宣言以外の名前を constructor
  -- パターンとして書くと Identifier 段階で reject される。
  ConstructorRef :: NameRefKind

-- | Compiler phase tag
type data Phase where
  -- | Initial parse, no resolution information.
  Parsed :: Phase
  -- | Identifier resolution complete: 'NameRef' nodes carry 'Just' identifiers
  -- for successfully resolved names and 'Nothing' for unresolved names.
  Identified :: Phase
  -- | Constraint generation complete: 'NameRef' nodes carry the same
  -- resolution metadata as 'Identified', but expression / pattern nodes
  -- also carry semantic type information (see 'ExpressionType' / 'PatternType').
  Constrained :: Phase
  -- | Zoning complete: same shape as 'Constrained', but all identifiers are
  -- replaced with their final IR ids (e.g. 'VariableId'), and all type
  -- information is fully elaborated (no remaining references to AST-level
  -- types).
  Zonked :: Phase

-- | NameRef resolution metadata for a given phase + symbol kind. After
-- Identifier the shape stabilises (@Maybe@ + identifier), and
-- 'Constrained' / 'Zonked' keep the same resolution metadata. The
-- 'Parsed' phase carries no resolution information yet.
type family NameRefResolution (phase :: Phase) (nameRefKind :: NameRefKind) :: Type where
  NameRefResolution Parsed _ = ()
  NameRefResolution _ VariableRef = Maybe VariableId
  NameRefResolution _ TypeRef = Maybe TypeId
  NameRefResolution _ ModuleRef = Maybe ModuleId
  NameRefResolution _ LabelRef = ()
  NameRefResolution _ RequestRef = Maybe RequestId
  NameRefResolution _ ConstructorRef = Maybe ConstructorId

-- | Expression node type metadata. Closed family: all four phases are
-- enumerated here. 'Parsed' / 'Identified' carry no type information;
-- 'Constrained' / 'Zonked' carry 'SemanticType' at the appropriate
-- resolution phase.
type family ExpressionType (phase :: Phase) :: Type where
  ExpressionType Parsed = ()
  ExpressionType Identified = ()
  ExpressionType Constrained = SemanticType Unresolved
  ExpressionType Zonked = SemanticType Resolved

-- | Pattern node type metadata. Same shape as 'ExpressionType'; the two are kept
-- as separate families so future divergence (e.g. pattern-only annotations)
-- doesn't require revisiting both call sites.
type family PatternType (phase :: Phase) :: Type where
  PatternType Parsed = ()
  PatternType Identified = ()
  PatternType Constrained = SemanticType Unresolved
  PatternType Zonked = SemanticType Resolved

-- ---------------------------------------------------------------------------
-- NameRef: a name with phase-dependent resolution metadata attached.
-- ---------------------------------------------------------------------------

data NameRef (phase :: Phase) (nameRefKind :: NameRefKind) = NameRef
  { text :: Text,
    sourceSpan :: SourceSpan,
    -- | Phase-specific resolution payload. 'Parsed': trivial. 'Identified'
    -- / 'Constrained' / 'Zonked': @Maybe Identifier@.
    resolution :: NameRefResolution phase nameRefKind
  }

instance HasSourceSpan (NameRef phase nameRefKind) where
  sourceSpanOf nameRef = nameRef.sourceSpan

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

data Module (phase :: Phase) = Module
  { declarations :: [Declaration phase],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Module phase) where
  sourceSpanOf module' = module'.sourceSpan

-- ---------------------------------------------------------------------------
-- Declarations
-- ---------------------------------------------------------------------------

data Declaration (phase :: Phase) where
  DeclarationAgent :: AgentDeclaration phase -> Declaration phase
  DeclarationRequest :: RequestDeclaration phase -> Declaration phase
  DeclarationImport :: ImportDeclaration phase -> Declaration phase
  DeclarationExternalAgent :: ExternalAgentDeclaration phase -> Declaration phase
  DeclarationData :: DataDeclaration phase -> Declaration phase
  DeclarationTypeSynonym :: TypeSynonymDeclaration phase -> Declaration phase
  -- | Structural sentinel left behind when parser recovery skipped over a
  -- broken declaration. Carries only the source span; the structured error
  -- detail lives in the parallel @[ParseError]@ list returned alongside the
  -- module. Lookup by 'sourceSpan' (1:1 with the corresponding 'ParseError').
  DeclarationError :: SourceSpan -> Declaration phase

instance HasSourceSpan (Declaration phase) where
  sourceSpanOf = \case
    DeclarationAgent declaration -> declaration.sourceSpan
    DeclarationRequest declaration -> declaration.sourceSpan
    DeclarationImport declaration -> declaration.sourceSpan
    DeclarationExternalAgent declaration -> declaration.sourceSpan
    DeclarationData declaration -> declaration.sourceSpan
    DeclarationTypeSynonym declaration -> declaration.sourceSpan
    DeclarationError sourceSpan -> sourceSpan

data AgentDeclaration (phase :: Phase) = AgentDeclaration
  { annotation :: Maybe Text,
    name :: NameRef phase VariableRef,
    parameters :: [ParameterBinding phase],
    returnType :: Maybe (SyntacticType phase),
    withRequests :: Maybe [SyntacticRequest phase],
    body :: Block phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (AgentDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

data RequestDeclaration (phase :: Phase) = RequestDeclaration
  { annotation :: Maybe Text,
    name :: NameRef phase VariableRef,
    -- | As Request
    requestName :: NameRef phase RequestRef,
    parameters :: [ParameterBinding phase],
    returnType :: SyntacticType phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RequestDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

data ImportDeclaration (phase :: Phase) = ImportDeclaration
  { kind :: ImportKind,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ImportDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | Import shape. Not phase-parameterised: import names are resolved
-- by the Identifier pass and the result is stored in scope tables rather
-- than in the AST. The module phaseath is a dot-joined @Text@ used as the
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

data ExternalAgentDeclaration (phase :: Phase) = ExternalAgentDeclaration
  { annotation :: Maybe Text,
    name :: NameRef phase VariableRef,
    parameters :: [ParameterBinding phase],
    returnType :: SyntacticType phase,
    withRequests :: [SyntacticRequest phase],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ExternalAgentDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | @data ctor_name(field: type, ...)@ — 1 declaration につき 1 constructor。
-- 同じ名前で値空間 (constructor 関数) と型空間 (data 型) の両方を導入する。
--
-- AST 上は両 role を別 'NameRef' として保持する: @name@ が値空間 (constructor
-- 関数) を、@typeName@ が型空間 (data 型) を指す。Parser は同一の identifier
-- token から両者を生成し (text と sourceSpan は共有)、Identifier フェーズが
-- 各々を独立に解決して resolution に固有の id (VariableId / TypeId) を埋める。
-- 後段 (ConstraintGenerator 以降) は AST から直接 TypeId を読めるので、
-- 名前テキストによる横断検索は不要。
data DataDeclaration (phase :: Phase) = DataDeclaration
  { annotation :: Maybe Text,
    name :: NameRef phase VariableRef,
    -- | As type
    typeName :: NameRef phase TypeRef,
    -- | As constructor
    constructorName :: NameRef phase ConstructorRef,
    parameters :: [DataParameter phase],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (DataDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

data DataParameter (phase :: Phase) = DataParameter
  { annotation :: Maybe Text,
    -- | Field label is kept as bare text per the Identifier-pass scope
    -- rules: field labels live in a per-object namespace.
    name :: Text,
    parameterType :: SyntacticType phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (DataParameter phase) where
  sourceSpanOf parameter = parameter.sourceSpan

-- | @type T = ...@ — 型シノニム。annotation はなし、generics もなし。
data TypeSynonymDeclaration (phase :: Phase) = TypeSynonymDeclaration
  { name :: NameRef phase TypeRef,
    rhs :: SyntacticType phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeSynonymDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

-- ---------------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------------

data Block (phase :: Phase) = Block
  { statements :: [Statement phase],
    -- | Trailing expression without semicolon (Rust-style return value).
    returnExpression :: Maybe (Expression phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Block phase) where
  sourceSpanOf block = block.sourceSpan

-- | Koka-style handle expression. Installs request handlers for its
-- continuation body. The body (continuation after @handle@) runs under
-- the installed handlers.
--
-- @
-- handle (var s = init) {
--   req foo() -> T { next v; s = new }
-- } then (pat) { finalizer }
-- continuation_body
-- @
--
-- When @parallel = True@, handlers run concurrently and @stateVariables@
-- must be empty (enforced by the typechecker).
data HandleExpression (phase :: Phase) = HandleExpression
  { parallel :: !Bool,
    stateVariables :: [StateVariableBinding phase],
    handlers :: [RequestHandler phase],
    thenClause :: Maybe (Maybe (Pattern phase), Block phase),
    -- | Continuation body that runs under the installed handlers.
    body :: Block phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (HandleExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data StateVariableBinding (phase :: Phase) = StateVariableBinding
  { name :: NameRef phase VariableRef,
    typeAnnotation :: Maybe (SyntacticType phase),
    initial :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (StateVariableBinding phase) where
  sourceSpanOf binding = binding.sourceSpan

data Statement (phase :: Phase) where
  StatementLet :: LetStatement phase -> Statement phase
  StatementAgent :: AgentStatement phase -> Statement phase
  StatementReturn :: ReturnStatement phase -> Statement phase
  StatementExpression :: Expression phase -> Statement phase
  StatementNext :: NextStatement phase -> Statement phase
  StatementBreak :: BreakStatement phase -> Statement phase
  StatementForNext :: ForNextStatement phase -> Statement phase
  StatementForBreak :: ForBreakStatement phase -> Statement phase
  -- | Structural sentinel left by parser statement-level recovery. Same
  -- pattern as 'DeclarationError': span only, error detail in the parallel
  -- @[ParseError]@ list.
  StatementError :: SourceSpan -> Statement phase

instance HasSourceSpan (Statement phase) where
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

data LetStatement (phase :: Phase) = LetStatement
  { pattern :: Pattern phase,
    value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (LetStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

data AgentStatement (phase :: Phase) = AgentStatement
  { name :: NameRef phase VariableRef,
    parameters :: [ParameterBinding phase],
    returnType :: Maybe (SyntacticType phase),
    withRequests :: Maybe [SyntacticRequest phase],
    body :: Block phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (AgentStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

data ReturnStatement (phase :: Phase) = ReturnStatement
  { value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ReturnStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

data NextStatement (phase :: Phase) = NextStatement
  { value :: Expression phase,
    modifiers :: [Modifier phase],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (NextStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

data BreakStatement (phase :: Phase) = BreakStatement
  { value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (BreakStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

data ForNextStatement (phase :: Phase) = ForNextStatement
  { modifiers :: [Modifier phase],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForNextStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

data ForBreakStatement (phase :: Phase) = ForBreakStatement
  { value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForBreakStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

data Modifier (phase :: Phase) = Modifier
  { name :: NameRef phase VariableRef,
    value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Modifier phase) where
  sourceSpanOf modifier = modifier.sourceSpan

-- | @req name(...) { body }@ または @req module.name(...) { body }@。
-- @name@ は新規 binding ではなく既存の req 宣言への参照。@moduleQualifier@ が
-- @Just@ の場合は他モジュールの req を実装する形。
-- | req handler は自身の request 集合を持たない (handler 内の request は
-- 囲む agent に bind されるため)。よって @with@ 節は構文上も AST 上も無い。
data RequestHandler (phase :: Phase) = RequestHandler
  { moduleQualifier :: Maybe (NameRef phase ModuleRef),
    -- | The request being handled. Resolved against the request namespace
    -- (RequestRef'); a name that does not name a @req@ declaration is
    -- rejected at the Identifier phase rather than passed through as a
    -- regular variable reference.
    name :: NameRef phase RequestRef,
    parameters :: [ParameterBinding phase],
    returnType :: Maybe (SyntacticType phase),
    body :: Block phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RequestHandler phase) where
  sourceSpanOf handler = handler.sourceSpan

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

data Pattern (phase :: Phase) where
  PatternVariable :: VariablePattern phase -> Pattern phase
  PatternQualifiedConstructor :: QualifiedConstructorPattern phase -> Pattern phase
  PatternTuple :: TuplePattern phase -> Pattern phase
  PatternWildcard :: WildcardPattern phase -> Pattern phase
  PatternLiteral :: LiteralPattern phase -> Pattern phase

instance HasSourceSpan (Pattern phase) where
  sourceSpanOf = \case
    PatternVariable pattern' -> pattern'.sourceSpan
    PatternQualifiedConstructor pattern' -> pattern'.sourceSpan
    PatternTuple pattern' -> pattern'.sourceSpan
    PatternWildcard pattern' -> pattern'.sourceSpan
    PatternLiteral pattern' -> pattern'.sourceSpan

data TuplePattern (phase :: Phase) = TuplePattern
  { elements :: [Pattern phase],
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (TuplePattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data WildcardPattern (phase :: Phase) = WildcardPattern
  { typeAnnotation :: Maybe (SyntacticType phase),
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (WildcardPattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data VariablePattern (phase :: Phase) = VariablePattern
  { name :: NameRef phase VariableRef,
    typeAnnotation :: Maybe (SyntacticType phase),
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (VariablePattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data ParameterBinding (phase :: Phase) = ParameterBinding
  { annotation :: Maybe Text,
    -- | External call label stays as text (per Identifier-pass policy).
    label :: Text,
    pattern :: Pattern phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ParameterBinding phase) where
  sourceSpanOf binding = binding.sourceSpan

-- | Constructor pattern. Constructor は所属モジュールのトップレベル variable
-- namespace に flat 展開されるため、bare @ctor(...)@ または @module.ctor(...)@
-- の二形式のみ。@type.ctor@ 構文は廃止。
--
-- パーサーは pattern phaseosition で @ident(...)@ / @ident.ident(...)@ を見たら
-- これを生成する (lookahead で @(@ を確認)。bare @ident@ (no parens) は
-- 'VariablePattern' のまま。
data QualifiedConstructorPattern (phase :: Phase) = QualifiedConstructorPattern
  { -- | Optional module qualifier (left-most segment).
    moduleQualifier :: Maybe (NameRef phase ModuleRef),
    -- | Constructor name. Resolved against the constructor namespace
    -- (ConstructorRef'); a name that does not name a @data@ declaration is
    -- rejected at the Identifier phase rather than passed through as a
    -- regular variable reference.
    constructorName :: NameRef phase ConstructorRef,
    -- | Field labels and their patterns. Label resolution is type-directed.
    parameters :: [(NameRef phase LabelRef, Pattern phase)],
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (QualifiedConstructorPattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data LiteralPattern (phase :: Phase) = LiteralPattern
  { value :: LiteralValue,
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (LiteralPattern phase) where
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

data SyntacticType (phase :: Phase) where
  TypePrimitive :: PrimitiveTypeNode phase -> SyntacticType phase
  TypeName :: TypeNameNode phase -> SyntacticType phase
  TypeFunction :: FunctionTypeNode phase -> SyntacticType phase
  TypeArray :: ArrayTypeNode phase -> SyntacticType phase
  TypeTuple :: TupleTypeNode phase -> SyntacticType phase
  -- | @module.TypeName@ qualified reference.
  TypeQualified :: QualifiedTypeNode phase -> SyntacticType phase
  -- | Type-level literal: @"foo"@ / @42@ / @true@ / @false@ / @null@。
  -- 値レベルの 'LiteralValue' を再利用する (Float は対象外)。
  TypeLiteral :: TypeLiteralNode -> SyntacticType phase
  -- | @T1 | T2 | ...@ union type。precedence は最低 (function/array より弱い)。
  -- 2 個以上の branch を持つ。順序保持。
  TypeUnion :: TypeUnionNode phase -> SyntacticType phase
  -- | @never@ — lattice の bottom 型。値を持たない。@agent f() -> never@ 等で
  -- 「絶対に return しない」を明示する用途。
  TypeNever :: NeverTypeNode phase -> SyntacticType phase
  -- | @unknown@ — lattice の top 型。任意の値を許容するが、利用側で必ず
  -- narrow する必要がある (TypeScript の @unknown@ と同じ思想)。
  TypeUnknown :: UnknownTypeNode phase -> SyntacticType phase

instance HasSourceSpan (SyntacticType phase) where
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

data PrimitiveTypeNode (phase :: Phase) = PrimitiveTypeNode
  { kind :: PrimitiveTypeKind,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (PrimitiveTypeNode p) where
  sourceSpanOf node = node.sourceSpan

-- | @never@ 型の AST ノード。lattice の bottom (値を持たない型) で、
-- primitive (concrete data) ではないため別ノードに分けている。
newtype NeverTypeNode (phase :: Phase) = NeverTypeNode
  { sourceSpan :: SourceSpan
  }

instance HasSourceSpan (NeverTypeNode p) where
  sourceSpanOf node = node.sourceSpan

-- | @unknown@ 型の AST ノード。lattice の top (任意の値) で、利用側で
-- narrow が必要。primitive ではないため別ノードに分けている。
newtype UnknownTypeNode (phase :: Phase) = UnknownTypeNode
  { sourceSpan :: SourceSpan
  }

instance HasSourceSpan (UnknownTypeNode p) where
  sourceSpanOf node = node.sourceSpan

data TypeNameNode (phase :: Phase) = TypeNameNode
  { name :: NameRef phase TypeRef,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeNameNode p) where
  sourceSpanOf node = node.sourceSpan

data FunctionTypeNode (phase :: Phase) = FunctionTypeNode
  { -- | Function-parameter labels live in a per-object namespace.
    parameterTypes :: [(Text, SyntacticType phase)],
    returnType :: SyntacticType phase,
    withRequests :: [SyntacticRequest phase],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (FunctionTypeNode p) where
  sourceSpanOf node = node.sourceSpan

data ArrayTypeNode (phase :: Phase) = ArrayTypeNode
  { elementType :: SyntacticType phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ArrayTypeNode p) where
  sourceSpanOf node = node.sourceSpan

data TupleTypeNode (phase :: Phase) = TupleTypeNode
  { elementTypes :: [SyntacticType phase],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TupleTypeNode p) where
  sourceSpanOf node = node.sourceSpan

data QualifiedTypeNode (phase :: Phase) = QualifiedTypeNode
  { qualifier :: NameRef phase ModuleRef,
    target :: NameRef phase TypeRef,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (QualifiedTypeNode p) where
  sourceSpanOf node = node.sourceSpan

-- | Type-level literal node. Phase-independent (no embedded NameRefs).
data TypeLiteralNode = TypeLiteralNode
  { value :: LiteralValue,
    sourceSpan :: SourceSpan
  }
  deriving (Eq, Show)

instance HasSourceSpan TypeLiteralNode where
  sourceSpanOf node = node.sourceSpan

-- | @T1 | T2 | ...@ union type。常に 2 個以上の branch を持つ。
data TypeUnionNode (phase :: Phase) = TypeUnionNode
  { branches :: [SyntacticType phase],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeUnionNode p) where
  sourceSpanOf node = node.sourceSpan

data SyntacticRequest (phase :: Phase) = SyntacticRequest
  { name :: NameRef phase RequestRef,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (SyntacticRequest phase) where
  sourceSpanOf request = request.sourceSpan

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------

data Expression (phase :: Phase) where
  ExpressionLiteral :: LiteralExpression phase -> Expression phase
  ExpressionVariable :: VariableExpression phase -> Expression phase
  ExpressionTuple :: TupleExpression phase -> Expression phase
  ExpressionArray :: ArrayExpression phase -> Expression phase
  ExpressionCall :: CallExpression phase -> Expression phase
  ExpressionBinaryOperator :: BinaryOperatorExpression phase -> Expression phase
  ExpressionUnaryOperator :: UnaryOperatorExpression phase -> Expression phase
  ExpressionIf :: IfExpression phase -> Expression phase
  ExpressionMatch :: MatchExpression phase -> Expression phase
  ExpressionFor :: ForExpression phase -> Expression phase
  ExpressionBlock :: BlockExpression phase -> Expression phase
  ExpressionFieldAccess :: FieldAccessExpression phase -> Expression phase
  ExpressionIndexAccess :: IndexAccessExpression phase -> Expression phase
  ExpressionTemplate :: TemplateExpression phase -> Expression phase
  -- | Koka-style handle expression. Captures the continuation as its body.
  ExpressionHandle :: HandleExpression phase -> Expression phase
  -- | Parallel tuple construction: @par (e1, e2, ...)@.
  ExpressionParTuple :: ParTupleExpression phase -> Expression phase
  -- | Parallel array construction: @par [e1, e2, ...]@.
  ExpressionParArray :: ParArrayExpression phase -> Expression phase
  -- | Synthesised by the Identifier pass from a @FieldAccess@ chain whose
  -- left-most segment resolves to a module. 詳細は 'QualifiedReferenceExpression'
  -- のコメント参照。Parser never produces this directly.
  ExpressionQualifiedReference :: QualifiedReferenceExpression phase -> Expression phase

instance HasSourceSpan (Expression phase) where
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
    ExpressionHandle expression -> expression.sourceSpan
    ExpressionParTuple expression -> expression.sourceSpan
    ExpressionParArray expression -> expression.sourceSpan
    ExpressionQualifiedReference expression -> expression.sourceSpan

data LiteralExpression (phase :: Phase) = LiteralExpression
  { value :: LiteralValue,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (LiteralExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data VariableExpression (phase :: Phase) = VariableExpression
  { name :: NameRef phase VariableRef,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (VariableExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data CallExpression (phase :: Phase) = CallExpression
  { callee :: Expression phase,
    arguments :: [CallArgument phase],
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (CallExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data CallArgument (phase :: Phase) = CallArgument
  { -- | Argument label. Resolution is type-directed (depends on the callee's
    -- parameter list), so the LabelRef symbol is filled in by the
    -- Typechecker; Identifier pass leaves it trivial.
    label :: NameRef phase LabelRef,
    value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (CallArgument p) where
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

data BinaryOperatorExpression (phase :: Phase) = BinaryOperatorExpression
  { operator :: BinaryOperator,
    left :: Expression phase,
    right :: Expression phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (BinaryOperatorExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data UnaryOperatorExpression (phase :: Phase) = UnaryOperatorExpression
  { operator :: UnaryOperator,
    operand :: Expression phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (UnaryOperatorExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data TupleExpression (phase :: Phase) = TupleExpression
  { elements :: [Expression phase],
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (TupleExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data ArrayExpression (phase :: Phase) = ArrayExpression
  { elements :: [Expression phase],
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (ArrayExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | Parallel tuple construction: @par (e1, e2, ...)@.
-- Each element is evaluated concurrently; results collected in order.
data ParTupleExpression (phase :: Phase) = ParTupleExpression
  { elements :: [Expression phase],
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (ParTupleExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | Parallel array construction: @par [e1, e2, ...]@.
-- Each element is evaluated concurrently; results collected in order.
data ParArrayExpression (phase :: Phase) = ParArrayExpression
  { elements :: [Expression phase],
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (ParArrayExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data IfExpression (phase :: Phase) = IfExpression
  { condition :: Expression phase,
    thenBlock :: Block phase,
    elseBlock :: Maybe (Block phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (IfExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data MatchExpression (phase :: Phase) = MatchExpression
  { subject :: Expression phase,
    cases :: [CaseArm phase],
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (MatchExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data ForExpression (phase :: Phase) = ForExpression
  { parallel :: !Bool,
    inBindings :: [ForInBinding phase],
    varBindings :: [ForVarBinding phase],
    body :: Block phase,
    thenBlock :: Maybe (Block phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (ForExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data ForInBinding (phase :: Phase) = ForInBinding
  { pattern :: Pattern phase,
    source :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForInBinding phase) where
  sourceSpanOf binding = binding.sourceSpan

data ForVarBinding (phase :: Phase) = ForVarBinding
  { name :: NameRef phase VariableRef,
    typeAnnotation :: Maybe (SyntacticType phase),
    initial :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForVarBinding phase) where
  sourceSpanOf binding = binding.sourceSpan

data BlockExpression (phase :: Phase) = BlockExpression
  { block :: Block phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (BlockExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data FieldAccessExpression (phase :: Phase) = FieldAccessExpression
  { object :: Expression phase,
    -- | Field name. Resolution is type-directed (depends on the object's type),
    -- so the LabelRef symbol is filled in by the Typechecker; Identifier
    -- pass leaves it trivial.
    fieldName :: NameRef phase LabelRef,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (FieldAccessExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data IndexAccessExpression (phase :: Phase) = IndexAccessExpression
  { array :: Expression phase,
    index :: Expression phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (IndexAccessExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data TemplateExpression (phase :: Phase) = TemplateExpression
  { elements :: [TemplateElement phase],
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (TemplateExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | 解決済み qualified 参照 @module.target@。
--
-- @target@ は値空間のシンボル (agent / req / ext agent / constructor)。
-- enum constructor も自モジュールの variable namespace に flat 展開されるため、
-- @module.ctor@ も同じ shape で表現される。
--
-- Parser は生成せず、Identifier フェーズで FieldAccess チェーンの最左が module
-- に解決された場合のみ合成する。
data QualifiedReferenceExpression (phase :: Phase) = QualifiedReferenceExpression
  { moduleQualifier :: NameRef phase ModuleRef,
    target :: NameRef phase VariableRef,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (QualifiedReferenceExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data CaseArm (phase :: Phase) = CaseArm
  { pattern :: Pattern phase,
    body :: Block phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (CaseArm p) where
  sourceSpanOf arm = arm.sourceSpan

data TemplateElement (phase :: Phase) where
  TemplateElementString :: TemplateStringElement p -> TemplateElement p
  TemplateElementExpression :: TemplateExpressionElement p -> TemplateElement p

instance HasSourceSpan (TemplateElement p) where
  sourceSpanOf = \case
    TemplateElementString element -> element.sourceSpan
    TemplateElementExpression element -> element.sourceSpan

data TemplateStringElement (phase :: Phase) = TemplateStringElement
  { value :: Text,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TemplateStringElement p) where
  sourceSpanOf element = element.sourceSpan

data TemplateExpressionElement (phase :: Phase) = TemplateExpressionElement
  { value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TemplateExpressionElement p) where
  sourceSpanOf element = element.sourceSpan

-- ---------------------------------------------------------------------------
-- Phase retagging helpers
--
-- 後段フェーズが上流フェーズの AST を「型レベルのタグ書き換えだけ」で渡し
-- 替えたい場合のための utility。NameRefResolution が両フェーズで一致している
-- (Identified / Constrained / Zonked の三相は閉じた type family により同じ
-- shape) ことを @~@ 制約で明示することで、安全に retag できる。
--
-- ここで提供するのは @NameRef@ / @SyntacticType@ / @SyntacticRequest@ /
-- 各 @TypeNode@ のみ。Expression / Pattern / Statement / Declaration /
-- Module はフェーズごとに @typeOf@ が異なるため、各 walker が局所的に
-- 構築する。
-- ---------------------------------------------------------------------------

-- | Change the phase tag of a 'NameRef' when both phases share the same
-- 'NameRefResolution' resolution.
retagNameRef ::
  (NameRefResolution phase1 nameRefKind ~ NameRefResolution phase2 nameRefKind) =>
  NameRef phase1 nameRefKind ->
  NameRef phase2 nameRefKind
retagNameRef nameRef =
  NameRef
    { text = nameRef.text,
      sourceSpan = nameRef.sourceSpan,
      resolution = nameRef.resolution
    }

-- | Change the phase tag of a 'SyntacticType' tree when both phases share
-- the same 'NameRefResolution' resolution. Recurses structurally; literal nodes
-- carry no phase-dependent payload.
retagSyntacticType ::
  ( NameRefResolution phase1 TypeRef ~ NameRefResolution phase2 TypeRef,
    NameRefResolution phase1 ModuleRef ~ NameRefResolution phase2 ModuleRef,
    NameRefResolution phase1 LabelRef ~ NameRefResolution phase2 LabelRef,
    NameRefResolution phase1 RequestRef ~ NameRefResolution phase2 RequestRef
  ) =>
  SyntacticType phase1 ->
  SyntacticType phase2
retagSyntacticType = \case
  TypePrimitive PrimitiveTypeNode {kind, sourceSpan} ->
    TypePrimitive PrimitiveTypeNode {kind = kind, sourceSpan = sourceSpan}
  TypeName TypeNameNode {name, sourceSpan} ->
    TypeName
      TypeNameNode
        { name = retagNameRef name,
          sourceSpan = sourceSpan
        }
  TypeFunction FunctionTypeNode {parameterTypes, returnType, withRequests, sourceSpan} ->
    TypeFunction
      FunctionTypeNode
        { parameterTypes =
            [ (label, retagSyntacticType subType)
              | (label, subType) <- parameterTypes
            ],
          returnType = retagSyntacticType returnType,
          withRequests = retagSyntacticRequest <$> withRequests,
          sourceSpan = sourceSpan
        }
  TypeArray ArrayTypeNode {elementType, sourceSpan} ->
    TypeArray
      ArrayTypeNode
        { elementType = retagSyntacticType elementType,
          sourceSpan = sourceSpan
        }
  TypeTuple TupleTypeNode {elementTypes, sourceSpan} ->
    TypeTuple
      TupleTypeNode
        { elementTypes = retagSyntacticType <$> elementTypes,
          sourceSpan = sourceSpan
        }
  TypeQualified QualifiedTypeNode {qualifier, target, sourceSpan} ->
    TypeQualified
      QualifiedTypeNode
        { qualifier = retagNameRef qualifier,
          target = retagNameRef target,
          sourceSpan = sourceSpan
        }
  TypeLiteral node -> TypeLiteral node
  TypeUnion TypeUnionNode {branches, sourceSpan} ->
    TypeUnion
      TypeUnionNode
        { branches = retagSyntacticType <$> branches,
          sourceSpan = sourceSpan
        }
  TypeNever NeverTypeNode {sourceSpan} ->
    TypeNever NeverTypeNode {sourceSpan = sourceSpan}
  TypeUnknown UnknownTypeNode {sourceSpan} ->
    TypeUnknown UnknownTypeNode {sourceSpan = sourceSpan}

-- | Change the phase tag of a 'SyntacticRequest'.
retagSyntacticRequest ::
  ( NameRefResolution phase1 RequestRef ~ NameRefResolution phase2 RequestRef
  ) =>
  SyntacticRequest phase1 ->
  SyntacticRequest phase2
retagSyntacticRequest req =
  SyntacticRequest
    { name = retagNameRef req.name,
      sourceSpan = req.sourceSpan
    }

-- | Change the phase tag of an 'ImportDeclaration'. Safe for any pair of
-- phases because 'ImportDeclaration' carries no phase-dependent fields.
retagImportDeclaration :: ImportDeclaration phase1 -> ImportDeclaration phase2
retagImportDeclaration ImportDeclaration {kind, sourceSpan} =
  ImportDeclaration {kind = kind, sourceSpan = sourceSpan}

-- ---------------------------------------------------------------------------
-- Aggregate Eq / Show constraints
--
-- 各 AST ノードの Eq / Show instance は phase の metadata 型 (NameRefResolution /
-- ExpressionType / PatternType) すべての Eq / Show を必要とする。@QuantifiedConstraints@
-- + @UndecidableInstances@ により @forall s. Eq (NameRefResolution phase s)@ という
-- 量化制約が書けるので、それを束ねた 'EqPhase' / 'ShowPhase' synonym で
-- 全ての standalone deriving の前置きを統一する。
-- ---------------------------------------------------------------------------

-- | Phase-level Eq aggregate. Bundled as a class (rather than a type
-- synonym) so it can be reused as a single constraint name. GHC forbids
-- type-family applications inside quantified constraints, so we
-- enumerate each 'NameRefKind' explicitly — this is closed-kind, so the
-- four cases cover every 'NameRefResolution phase s' use.
class
  ( Eq (NameRefResolution phase VariableRef),
    Eq (NameRefResolution phase TypeRef),
    Eq (NameRefResolution phase ModuleRef),
    Eq (NameRefResolution phase LabelRef),
    Eq (NameRefResolution phase RequestRef),
    Eq (NameRefResolution phase ConstructorRef),
    Eq (ExpressionType phase),
    Eq (PatternType phase)
  ) =>
  EqPhase phase

instance
  ( Eq (NameRefResolution phase VariableRef),
    Eq (NameRefResolution phase TypeRef),
    Eq (NameRefResolution phase ModuleRef),
    Eq (NameRefResolution phase LabelRef),
    Eq (NameRefResolution phase RequestRef),
    Eq (NameRefResolution phase ConstructorRef),
    Eq (ExpressionType phase),
    Eq (PatternType phase)
  ) =>
  EqPhase phase

class
  ( Show (NameRefResolution phase VariableRef),
    Show (NameRefResolution phase TypeRef),
    Show (NameRefResolution phase ModuleRef),
    Show (NameRefResolution phase LabelRef),
    Show (NameRefResolution phase RequestRef),
    Show (NameRefResolution phase ConstructorRef),
    Show (ExpressionType phase),
    Show (PatternType phase)
  ) =>
  ShowPhase phase

instance
  ( Show (NameRefResolution phase VariableRef),
    Show (NameRefResolution phase TypeRef),
    Show (NameRefResolution phase ModuleRef),
    Show (NameRefResolution phase LabelRef),
    Show (NameRefResolution phase RequestRef),
    Show (NameRefResolution phase ConstructorRef),
    Show (ExpressionType phase),
    Show (PatternType phase)
  ) =>
  ShowPhase phase

deriving instance (Eq (NameRefResolution p s)) => Eq (NameRef p s)

deriving instance (Show (NameRefResolution p s)) => Show (NameRef p s)

deriving instance (EqPhase p) => Eq (Module p)

deriving instance (ShowPhase p) => Show (Module p)

deriving instance (EqPhase p) => Eq (Declaration p)

deriving instance (ShowPhase p) => Show (Declaration p)

deriving instance (EqPhase p) => Eq (AgentDeclaration p)

deriving instance (ShowPhase p) => Show (AgentDeclaration p)

deriving instance (EqPhase p) => Eq (RequestDeclaration p)

deriving instance (ShowPhase p) => Show (RequestDeclaration p)

deriving instance Eq (ImportDeclaration p)

deriving instance Show (ImportDeclaration p)

deriving instance (EqPhase p) => Eq (ExternalAgentDeclaration p)

deriving instance (ShowPhase p) => Show (ExternalAgentDeclaration p)

deriving instance (EqPhase p) => Eq (DataDeclaration p)

deriving instance (ShowPhase p) => Show (DataDeclaration p)

deriving instance (EqPhase p) => Eq (DataParameter p)

deriving instance (ShowPhase p) => Show (DataParameter p)

deriving instance (EqPhase p) => Eq (TypeSynonymDeclaration p)

deriving instance (ShowPhase p) => Show (TypeSynonymDeclaration p)

deriving instance (EqPhase p) => Eq (Block p)

deriving instance (ShowPhase p) => Show (Block p)

deriving instance (EqPhase p) => Eq (HandleExpression p)

deriving instance (ShowPhase p) => Show (HandleExpression p)

deriving instance (EqPhase p) => Eq (StateVariableBinding p)

deriving instance (ShowPhase p) => Show (StateVariableBinding p)

deriving instance (EqPhase p) => Eq (Statement p)

deriving instance (ShowPhase p) => Show (Statement p)

deriving instance (EqPhase p) => Eq (LetStatement p)

deriving instance (ShowPhase p) => Show (LetStatement p)

deriving instance (EqPhase p) => Eq (AgentStatement p)

deriving instance (ShowPhase p) => Show (AgentStatement p)

deriving instance (EqPhase p) => Eq (ReturnStatement p)

deriving instance (ShowPhase p) => Show (ReturnStatement p)

deriving instance (EqPhase p) => Eq (NextStatement p)

deriving instance (ShowPhase p) => Show (NextStatement p)

deriving instance (EqPhase p) => Eq (BreakStatement p)

deriving instance (ShowPhase p) => Show (BreakStatement p)

deriving instance (EqPhase p) => Eq (ForNextStatement p)

deriving instance (ShowPhase p) => Show (ForNextStatement p)

deriving instance (EqPhase p) => Eq (ForBreakStatement p)

deriving instance (ShowPhase p) => Show (ForBreakStatement p)

deriving instance (EqPhase p) => Eq (Modifier p)

deriving instance (ShowPhase p) => Show (Modifier p)

deriving instance (EqPhase p) => Eq (RequestHandler p)

deriving instance (ShowPhase p) => Show (RequestHandler p)

deriving instance (EqPhase p) => Eq (Pattern p)

deriving instance (ShowPhase p) => Show (Pattern p)

deriving instance (EqPhase p) => Eq (TuplePattern p)

deriving instance (ShowPhase p) => Show (TuplePattern p)

deriving instance (EqPhase p) => Eq (WildcardPattern p)

deriving instance (ShowPhase p) => Show (WildcardPattern p)

deriving instance (EqPhase p) => Eq (VariablePattern p)

deriving instance (ShowPhase p) => Show (VariablePattern p)

deriving instance (EqPhase p) => Eq (ParameterBinding p)

deriving instance (ShowPhase p) => Show (ParameterBinding p)

deriving instance (EqPhase p) => Eq (QualifiedConstructorPattern p)

deriving instance (ShowPhase p) => Show (QualifiedConstructorPattern p)

deriving instance (EqPhase p) => Eq (LiteralPattern p)

deriving instance (ShowPhase p) => Show (LiteralPattern p)

deriving instance (EqPhase p) => Eq (SyntacticType p)

deriving instance (ShowPhase p) => Show (SyntacticType p)

deriving instance Eq (PrimitiveTypeNode p)

deriving instance Show (PrimitiveTypeNode p)

deriving instance Eq (NeverTypeNode p)

deriving instance Show (NeverTypeNode p)

deriving instance Eq (UnknownTypeNode p)

deriving instance Show (UnknownTypeNode p)

deriving instance (EqPhase p) => Eq (TypeNameNode p)

deriving instance (ShowPhase p) => Show (TypeNameNode p)

deriving instance (EqPhase p) => Eq (FunctionTypeNode p)

deriving instance (ShowPhase p) => Show (FunctionTypeNode p)

deriving instance (EqPhase p) => Eq (ArrayTypeNode p)

deriving instance (ShowPhase p) => Show (ArrayTypeNode p)

deriving instance (EqPhase p) => Eq (TupleTypeNode p)

deriving instance (ShowPhase p) => Show (TupleTypeNode p)

deriving instance (EqPhase p) => Eq (QualifiedTypeNode p)

deriving instance (ShowPhase p) => Show (QualifiedTypeNode p)

deriving instance (EqPhase p) => Eq (TypeUnionNode p)

deriving instance (ShowPhase p) => Show (TypeUnionNode p)

deriving instance (EqPhase p) => Eq (SyntacticRequest p)

deriving instance (ShowPhase p) => Show (SyntacticRequest p)

deriving instance (EqPhase p) => Eq (Expression p)

deriving instance (ShowPhase p) => Show (Expression p)

deriving instance (EqPhase p) => Eq (LiteralExpression p)

deriving instance (ShowPhase p) => Show (LiteralExpression p)

deriving instance (EqPhase p) => Eq (VariableExpression p)

deriving instance (ShowPhase p) => Show (VariableExpression p)

deriving instance (EqPhase p) => Eq (CallExpression p)

deriving instance (ShowPhase p) => Show (CallExpression p)

deriving instance (EqPhase p) => Eq (CallArgument p)

deriving instance (ShowPhase p) => Show (CallArgument p)

deriving instance (EqPhase p) => Eq (BinaryOperatorExpression p)

deriving instance (ShowPhase p) => Show (BinaryOperatorExpression p)

deriving instance (EqPhase p) => Eq (UnaryOperatorExpression p)

deriving instance (ShowPhase p) => Show (UnaryOperatorExpression p)

deriving instance (EqPhase p) => Eq (TupleExpression p)

deriving instance (ShowPhase p) => Show (TupleExpression p)

deriving instance (EqPhase p) => Eq (ArrayExpression p)

deriving instance (ShowPhase p) => Show (ArrayExpression p)

deriving instance (EqPhase p) => Eq (ParTupleExpression p)

deriving instance (ShowPhase p) => Show (ParTupleExpression p)

deriving instance (EqPhase p) => Eq (ParArrayExpression p)

deriving instance (ShowPhase p) => Show (ParArrayExpression p)

deriving instance (EqPhase p) => Eq (IfExpression p)

deriving instance (ShowPhase p) => Show (IfExpression p)

deriving instance (EqPhase p) => Eq (MatchExpression p)

deriving instance (ShowPhase p) => Show (MatchExpression p)

deriving instance (EqPhase p) => Eq (ForExpression p)

deriving instance (ShowPhase p) => Show (ForExpression p)

deriving instance (EqPhase p) => Eq (ForInBinding p)

deriving instance (ShowPhase p) => Show (ForInBinding p)

deriving instance (EqPhase p) => Eq (ForVarBinding p)

deriving instance (ShowPhase p) => Show (ForVarBinding p)

deriving instance (EqPhase p) => Eq (BlockExpression p)

deriving instance (ShowPhase p) => Show (BlockExpression p)

deriving instance (EqPhase p) => Eq (FieldAccessExpression p)

deriving instance (ShowPhase p) => Show (FieldAccessExpression p)

deriving instance (EqPhase p) => Eq (IndexAccessExpression p)

deriving instance (ShowPhase p) => Show (IndexAccessExpression p)

deriving instance (EqPhase p) => Eq (TemplateExpression p)

deriving instance (ShowPhase p) => Show (TemplateExpression p)

deriving instance (EqPhase p) => Eq (QualifiedReferenceExpression p)

deriving instance (ShowPhase p) => Show (QualifiedReferenceExpression p)

deriving instance (EqPhase p) => Eq (CaseArm p)

deriving instance (ShowPhase p) => Show (CaseArm p)

deriving instance (EqPhase p) => Eq (TemplateElement p)

deriving instance (ShowPhase p) => Show (TemplateElement p)

deriving instance Eq (TemplateStringElement p)

deriving instance Show (TemplateStringElement p)

deriving instance (EqPhase p) => Eq (TemplateExpressionElement p)

deriving instance (ShowPhase p) => Show (TemplateExpressionElement p)
