-- |
-- Phase-indexed AST for the Katari language.
--
-- 各 AST ノードはコンパイラのフェーズを 'Phase' tag (型レベル only,
-- TypeData) でパラメータ化する。'NameRef' は @resolution@ フィールドに
-- @NameMeta p s@ (各 phase + symbol kind に応じた解決情報) を持ち、
-- expression / pattern ノードは @typeOf@ フィールドに @ExprType p@ /
-- @PatType p@ を持つ。
--
-- 設計上の重要点:
--
--   * @NameMeta@ は閉じた type family で、Identified / Constrained /
--     Zonked の三相について同じ shape (@Maybe Identifier@) を返す。
--     これにより、phase 推移は payload を素通しする identity 変換に
--     なり、@passThrough@ 系の boilerplate が一切不要になる。
--   * @ExprType@ / @PatType@ は別の open type family で、
--     'Katari.Typechecker.SemanticType' に Constrained / Zonked instance
--     が定義されている (型推論の方向に依存性が向く)。
--   * 'Module' / 'Declaration' / 'Statement' 系には型情報を載せる予定が
--     ないため @typeOf@ フィールドを持たない (placeholder の no-op
--     フィールドを増やさないため)。
module Katari.AST where

import Data.Aeson (FromJSON, ToJSON)
import Data.Kind (Type)
import Data.Text (Text)
import GHC.Generics (Generic)
import Katari.AST.Identifiers
  ( ConstructorId,
    ModuleId,
    RequestId,
    TypeId,
    VariableId,
  )

data Position = Position
  { line :: Int,
    column :: Int
  }
  deriving (Eq, Ord, Show, Generic)

instance ToJSON Position

instance FromJSON Position

data SourceSpan = SrcSpan
  { filePath :: FilePath,
    start :: Position,
    end :: Position
  }
  deriving (Eq, Ord, Show, Generic)

instance ToJSON SourceSpan

instance FromJSON SourceSpan

-- | Generic accessor for nodes that carry a source span. Implemented
-- uniformly by record-shaped nodes and by GADT sum types.
class HasSourceSpan node where
  sourceSpanOf :: node -> SourceSpan

-- ---------------------------------------------------------------------------
-- SymbolKind: 'NameRef' が指す名前空間の種別。
-- ---------------------------------------------------------------------------

data SymbolKind
  = -- | 値空間の名前参照 (agent / req / ext agent / constructor / local var)。
    -- 値として呼べる名前はすべてここを通る。
    VariableRef
  | -- | 型空間の名前参照 (enum 名、TypeName)。
    TypeRef
  | -- | モジュール空間の名前参照 (import alias、qualified の左辺)。
    ModuleRef
  | -- | フィールド・引数ラベル (型指向で後段が解決)。
    LabelRef
  | -- | req handler の対象。@req@ 宣言以外の名前を handler として書くと
    -- Identifier 段階で reject される (型レベルでスロットを分離している)。
    RequestRef
  | -- | match パターンの constructor。@data@ 宣言以外の名前を constructor
    -- パターンとして書くと Identifier 段階で reject される。
    ConstructorRef
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Phase markers and per-phase metadata type families (Trees-that-Grow style)
--
-- Each phase tag selects the carrier type for 'NameRef' resolution metadata
-- as well as for the type information attached to expressions / patterns.
--
-- Why type families:
--   * The resolution metadata for 'Identified' / 'Constrained' / 'Zonked'
--     is identical (a 'Maybe' identifier per symbol kind), so all three
--     phases share the same instances — no boilerplate phase-conversion
--     functions are needed.
--   * The expression / pattern type carriers ('ExprType' / 'PatType') are
--     phase-dependent but live in a separate family, so name resolution
--     and type elaboration evolve independently.
-- ---------------------------------------------------------------------------

-- | Compiler phase tag. Defined with 'TypeData' so that the constructors
-- live exclusively at the type level — there are no term-level
-- constructors. The AST is parametrised by 'Phase' from the parser
-- onward.
type data Phase = Parsed | Identified | Constrained | Zonked

-- | NameRef resolution metadata for a given phase + symbol kind. After
-- Identifier the shape stabilises (@Maybe@ + identifier), and
-- 'Constrained' / 'Zonked' keep the same resolution metadata. The
-- 'Parsed' phase carries no resolution information yet.
type family NameMeta (p :: Phase) (s :: SymbolKind) :: Type where
  NameMeta Parsed _ = ()
  NameMeta _ 'VariableRef = Maybe VariableId
  NameMeta _ 'TypeRef = Maybe TypeId
  NameMeta _ 'ModuleRef = Maybe ModuleId
  NameMeta _ 'LabelRef = ()
  NameMeta _ 'RequestRef = Maybe RequestId
  NameMeta _ 'ConstructorRef = Maybe ConstructorId

-- | Expression node type metadata. Open family because 'Constrained' /
-- 'Zonked' instances live in 'Katari.Typechecker.SemanticType' (which
-- depends on this module).
type family ExprType (p :: Phase) :: Type

type instance ExprType Parsed = ()

type instance ExprType Identified = ()

-- | Pattern node type metadata. Same shape as 'ExprType'; the two are kept
-- as separate families so future divergence (e.g. pattern-only annotations)
-- doesn't require revisiting both call sites.
type family PatType (p :: Phase) :: Type

type instance PatType Parsed = ()

type instance PatType Identified = ()

-- ---------------------------------------------------------------------------
-- NameRef: a name with phase-dependent resolution metadata attached.
-- ---------------------------------------------------------------------------

data NameRef (p :: Phase) (symbol :: SymbolKind) = NameRef
  { text :: Text,
    sourceSpan :: SourceSpan,
    -- | Phase-specific resolution payload. 'Parsed': trivial. 'Identified'
    -- / 'Constrained' / 'Zonked': @Maybe Identifier@.
    resolution :: NameMeta p symbol
  }

instance HasSourceSpan (NameRef p symbol) where
  sourceSpanOf ref = ref.sourceSpan

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

data Module (p :: Phase) = Module
  { declarations :: [Declaration p],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Module p) where
  sourceSpanOf module' = module'.sourceSpan

-- ---------------------------------------------------------------------------
-- Declarations
-- ---------------------------------------------------------------------------

data Declaration (p :: Phase) where
  DeclarationAgent :: AgentDeclaration p -> Declaration p
  DeclarationRequest :: RequestDeclaration p -> Declaration p
  DeclarationImport :: ImportDeclaration p -> Declaration p
  DeclarationExternalAgent :: ExternalAgentDeclaration p -> Declaration p
  DeclarationData :: DataDeclaration p -> Declaration p
  DeclarationTypeSynonym :: TypeSynonymDeclaration p -> Declaration p
  -- | Structural sentinel left behind when parser recovery skipped over a
  -- broken declaration. Carries only the source span; the structured error
  -- detail lives in the parallel @[ParseError]@ list returned alongside the
  -- module. Lookup by 'sourceSpan' (1:1 with the corresponding 'ParseError').
  DeclarationError :: SourceSpan -> Declaration p

instance HasSourceSpan (Declaration p) where
  sourceSpanOf = \case
    DeclarationAgent declaration -> declaration.sourceSpan
    DeclarationRequest declaration -> declaration.sourceSpan
    DeclarationImport declaration -> declaration.sourceSpan
    DeclarationExternalAgent declaration -> declaration.sourceSpan
    DeclarationData declaration -> declaration.sourceSpan
    DeclarationTypeSynonym declaration -> declaration.sourceSpan
    DeclarationError sourceSpan -> sourceSpan

data AgentDeclaration (p :: Phase) = AgentDeclaration
  { annotation :: Maybe Text,
    name :: NameRef p 'VariableRef,
    parameters :: [ParameterBinding p],
    returnType :: Maybe (SyntacticType p),
    withEffects :: Maybe [SyntacticRequest p],
    body :: Block p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (AgentDeclaration p) where
  sourceSpanOf declaration = declaration.sourceSpan

data RequestDeclaration (p :: Phase) = RequestDeclaration
  { annotation :: Maybe Text,
    name :: NameRef p 'VariableRef,
    parameters :: [ParameterBinding p],
    returnType :: SyntacticType p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RequestDeclaration p) where
  sourceSpanOf declaration = declaration.sourceSpan

data ImportDeclaration (p :: Phase) = ImportDeclaration
  { kind :: ImportKind,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ImportDeclaration p) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | Import shape. Not phase-parameterised: import names are resolved
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

data ExternalAgentDeclaration (p :: Phase) = ExternalAgentDeclaration
  { annotation :: Maybe Text,
    name :: NameRef p 'VariableRef,
    parameters :: [ParameterBinding p],
    returnType :: SyntacticType p,
    withEffects :: [SyntacticRequest p],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ExternalAgentDeclaration p) where
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
data DataDeclaration (p :: Phase) = DataDeclaration
  { annotation :: Maybe Text,
    name :: NameRef p 'VariableRef,
    typeName :: NameRef p 'TypeRef,
    parameters :: [DataParameter p],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (DataDeclaration p) where
  sourceSpanOf declaration = declaration.sourceSpan

data DataParameter (p :: Phase) = DataParameter
  { annotation :: Maybe Text,
    -- | Field label is kept as bare text per the Identifier-pass scope
    -- rules: field labels live in a per-object namespace.
    name :: Text,
    parameterType :: SyntacticType p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (DataParameter p) where
  sourceSpanOf parameter = parameter.sourceSpan

-- | @type T = ...@ — 型シノニム。annotation はなし、generics もなし。
data TypeSynonymDeclaration (p :: Phase) = TypeSynonymDeclaration
  { name :: NameRef p 'TypeRef,
    rhs :: SyntacticType p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeSynonymDeclaration p) where
  sourceSpanOf declaration = declaration.sourceSpan

-- ---------------------------------------------------------------------------
-- Statements
-- ---------------------------------------------------------------------------

data Block (p :: Phase) = Block
  { statements :: [Statement p],
    -- | Trailing expression without semicolon (Rust-style return value).
    returnExpression :: Maybe (Expression p),
    -- | where (...) { ... } then(pat) { ... }
    whereBlock :: Maybe (WhereBlock p),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Block p) where
  sourceSpanOf block = block.sourceSpan

-- | A @where@ clause optionally followed by a @then@ clause.
--
-- The @then@ clause runs after the body terminates (whether by normal
-- completion, @break@, or @return@). When the body's tail value is
-- destructured by a pattern, that pattern is the @Just@ payload of
-- @thenClause@'s outer @Maybe@. The pattern itself can be omitted
-- (@then { ... }@), in which case the body's value is discarded.
data WhereBlock (p :: Phase) = WhereBlock
  { stateVariables :: [StateVariableBinding p],
    handlers :: [RequestHandler p],
    thenClause :: Maybe (Maybe (Pattern p), Block p),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (WhereBlock p) where
  sourceSpanOf whereBlock = whereBlock.sourceSpan

data StateVariableBinding (p :: Phase) = StateVariableBinding
  { name :: NameRef p 'VariableRef,
    typeAnnotation :: Maybe (SyntacticType p),
    initial :: Expression p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (StateVariableBinding p) where
  sourceSpanOf binding = binding.sourceSpan

data Statement (p :: Phase) where
  StatementLet :: LetStatement p -> Statement p
  StatementAgent :: AgentStatement p -> Statement p
  StatementReturn :: ReturnStatement p -> Statement p
  StatementExpression :: Expression p -> Statement p
  StatementNext :: NextStatement p -> Statement p
  StatementBreak :: BreakStatement p -> Statement p
  StatementForNext :: ForNextStatement p -> Statement p
  StatementForBreak :: ForBreakStatement p -> Statement p
  -- | Structural sentinel left by parser statement-level recovery. Same
  -- pattern as 'DeclarationError': span only, error detail in the parallel
  -- @[ParseError]@ list.
  StatementError :: SourceSpan -> Statement p

instance HasSourceSpan (Statement p) where
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

data LetStatement (p :: Phase) = LetStatement
  { pattern :: Pattern p,
    value :: Expression p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (LetStatement p) where
  sourceSpanOf statement = statement.sourceSpan

data AgentStatement (p :: Phase) = AgentStatement
  { name :: NameRef p 'VariableRef,
    parameters :: [ParameterBinding p],
    returnType :: Maybe (SyntacticType p),
    withEffects :: Maybe [SyntacticRequest p],
    body :: Block p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (AgentStatement p) where
  sourceSpanOf statement = statement.sourceSpan

data ReturnStatement (p :: Phase) = ReturnStatement
  { value :: Expression p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ReturnStatement p) where
  sourceSpanOf statement = statement.sourceSpan

data NextStatement (p :: Phase) = NextStatement
  { value :: Expression p,
    modifiers :: [Modifier p],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (NextStatement p) where
  sourceSpanOf statement = statement.sourceSpan

data BreakStatement (p :: Phase) = BreakStatement
  { value :: Expression p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (BreakStatement p) where
  sourceSpanOf statement = statement.sourceSpan

data ForNextStatement (p :: Phase) = ForNextStatement
  { modifiers :: [Modifier p],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForNextStatement p) where
  sourceSpanOf statement = statement.sourceSpan

data ForBreakStatement (p :: Phase) = ForBreakStatement
  { value :: Expression p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForBreakStatement p) where
  sourceSpanOf statement = statement.sourceSpan

data Modifier (p :: Phase) = Modifier
  { name :: NameRef p 'VariableRef,
    value :: Expression p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Modifier p) where
  sourceSpanOf modifier = modifier.sourceSpan

-- | @req name(...) { body }@ または @req module.name(...) { body }@。
-- @name@ は新規 binding ではなく既存の req 宣言への参照。@moduleQualifier@ が
-- @Just@ の場合は他モジュールの req を実装する形。
-- | req handler は自身の effect 集合を持たない (handler 内の effect は
-- 囲む agent に bind されるため)。よって @with@ 節は構文上も AST 上も無い。
data RequestHandler (p :: Phase) = RequestHandler
  { moduleQualifier :: Maybe (NameRef p 'ModuleRef),
    -- | The request being handled. Resolved against the request namespace
    -- ('RequestRef'); a name that does not name a @req@ declaration is
    -- rejected at the Identifier phase rather than passed through as a
    -- regular variable reference.
    name :: NameRef p 'RequestRef,
    parameters :: [ParameterBinding p],
    returnType :: Maybe (SyntacticType p),
    body :: Block p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RequestHandler p) where
  sourceSpanOf handler = handler.sourceSpan

-- ---------------------------------------------------------------------------
-- Patterns
-- ---------------------------------------------------------------------------

data Pattern (p :: Phase) where
  PatternVariable :: VariablePattern p -> Pattern p
  PatternQualifiedConstructor :: QualifiedConstructorPattern p -> Pattern p
  PatternTuple :: TuplePattern p -> Pattern p
  PatternWildcard :: WildcardPattern p -> Pattern p
  PatternLiteral :: LiteralPattern p -> Pattern p

instance HasSourceSpan (Pattern p) where
  sourceSpanOf = \case
    PatternVariable pattern' -> pattern'.sourceSpan
    PatternQualifiedConstructor pattern' -> pattern'.sourceSpan
    PatternTuple pattern' -> pattern'.sourceSpan
    PatternWildcard pattern' -> pattern'.sourceSpan
    PatternLiteral pattern' -> pattern'.sourceSpan

data TuplePattern (p :: Phase) = TuplePattern
  { elements :: [Pattern p],
    sourceSpan :: SourceSpan,
    typeOf :: PatType p
  }

instance HasSourceSpan (TuplePattern p) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data WildcardPattern (p :: Phase) = WildcardPattern
  { typeAnnotation :: Maybe (SyntacticType p),
    sourceSpan :: SourceSpan,
    typeOf :: PatType p
  }

instance HasSourceSpan (WildcardPattern p) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data VariablePattern (p :: Phase) = VariablePattern
  { name :: NameRef p 'VariableRef,
    typeAnnotation :: Maybe (SyntacticType p),
    sourceSpan :: SourceSpan,
    typeOf :: PatType p
  }

instance HasSourceSpan (VariablePattern p) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data ParameterBinding (p :: Phase) = ParameterBinding
  { annotation :: Maybe Text,
    -- | External call label stays as text (per Identifier-pass policy).
    label :: Text,
    pattern :: Pattern p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ParameterBinding p) where
  sourceSpanOf binding = binding.sourceSpan

-- | Constructor pattern. Constructor は所属モジュールのトップレベル variable
-- namespace に flat 展開されるため、bare @ctor(...)@ または @module.ctor(...)@
-- の二形式のみ。@type.ctor@ 構文は廃止。
--
-- パーサーは pattern position で @ident(...)@ / @ident.ident(...)@ を見たら
-- これを生成する (lookahead で @(@ を確認)。bare @ident@ (no parens) は
-- 'VariablePattern' のまま。
data QualifiedConstructorPattern (p :: Phase) = QualifiedConstructorPattern
  { -- | Optional module qualifier (left-most segment).
    moduleQualifier :: Maybe (NameRef p 'ModuleRef),
    -- | Constructor name. Resolved against the constructor namespace
    -- ('ConstructorRef'); a name that does not name a @data@ declaration is
    -- rejected at the Identifier phase rather than passed through as a
    -- regular variable reference.
    constructorName :: NameRef p 'ConstructorRef,
    -- | Field labels and their patterns. Label resolution is type-directed.
    parameters :: [(NameRef p 'LabelRef, Pattern p)],
    sourceSpan :: SourceSpan,
    typeOf :: PatType p
  }

instance HasSourceSpan (QualifiedConstructorPattern p) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data LiteralPattern (p :: Phase) = LiteralPattern
  { value :: LiteralValue,
    sourceSpan :: SourceSpan,
    typeOf :: PatType p
  }

instance HasSourceSpan (LiteralPattern p) where
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

data SyntacticType (p :: Phase) where
  TypePrimitive :: PrimitiveTypeNode p -> SyntacticType p
  TypeName :: TypeNameNode p -> SyntacticType p
  TypeFunction :: FunctionTypeNode p -> SyntacticType p
  TypeArray :: ArrayTypeNode p -> SyntacticType p
  TypeTuple :: TupleTypeNode p -> SyntacticType p
  -- | @module.TypeName@ qualified reference.
  TypeQualified :: QualifiedTypeNode p -> SyntacticType p
  -- | Type-level literal: @"foo"@ / @42@ / @true@ / @false@ / @null@。
  -- 値レベルの 'LiteralValue' を再利用する (Float は対象外)。
  TypeLiteral :: TypeLiteralNode -> SyntacticType p
  -- | @T1 | T2 | ...@ union type。precedence は最低 (function/array より弱い)。
  -- 2 個以上の branch を持つ。順序保持。
  TypeUnion :: TypeUnionNode p -> SyntacticType p
  -- | @never@ — lattice の bottom 型。値を持たない。@agent f() -> never@ 等で
  -- 「絶対に return しない」を明示する用途。
  TypeNever :: NeverTypeNode p -> SyntacticType p
  -- | @unknown@ — lattice の top 型。任意の値を許容するが、利用側で必ず
  -- narrow する必要がある (TypeScript の @unknown@ と同じ思想)。
  TypeUnknown :: UnknownTypeNode p -> SyntacticType p

instance HasSourceSpan (SyntacticType p) where
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

data PrimitiveTypeNode (p :: Phase) = PrimitiveTypeNode
  { kind :: PrimitiveTypeKind,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (PrimitiveTypeNode p) where
  sourceSpanOf node = node.sourceSpan

-- | @never@ 型の AST ノード。lattice の bottom (値を持たない型) で、
-- primitive (concrete data) ではないため別ノードに分けている。
newtype NeverTypeNode (p :: Phase) = NeverTypeNode
  { sourceSpan :: SourceSpan
  }

instance HasSourceSpan (NeverTypeNode p) where
  sourceSpanOf node = node.sourceSpan

-- | @unknown@ 型の AST ノード。lattice の top (任意の値) で、利用側で
-- narrow が必要。primitive ではないため別ノードに分けている。
newtype UnknownTypeNode (p :: Phase) = UnknownTypeNode
  { sourceSpan :: SourceSpan
  }

instance HasSourceSpan (UnknownTypeNode p) where
  sourceSpanOf node = node.sourceSpan

data TypeNameNode (p :: Phase) = TypeNameNode
  { name :: NameRef p 'TypeRef,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeNameNode p) where
  sourceSpanOf node = node.sourceSpan

data FunctionTypeNode (p :: Phase) = FunctionTypeNode
  { -- | Function-parameter labels live in a per-object namespace.
    parameterTypes :: [(Text, SyntacticType p)],
    returnType :: SyntacticType p,
    withEffects :: [SyntacticRequest p],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (FunctionTypeNode p) where
  sourceSpanOf node = node.sourceSpan

data ArrayTypeNode (p :: Phase) = ArrayTypeNode
  { elementType :: SyntacticType p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ArrayTypeNode p) where
  sourceSpanOf node = node.sourceSpan

data TupleTypeNode (p :: Phase) = TupleTypeNode
  { elementTypes :: [SyntacticType p],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TupleTypeNode p) where
  sourceSpanOf node = node.sourceSpan

data QualifiedTypeNode (p :: Phase) = QualifiedTypeNode
  { qualifier :: NameRef p 'ModuleRef,
    target :: NameRef p 'TypeRef,
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
data TypeUnionNode (p :: Phase) = TypeUnionNode
  { branches :: [SyntacticType p],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeUnionNode p) where
  sourceSpanOf node = node.sourceSpan

data SyntacticRequest (p :: Phase) = SyntacticRequest
  { name :: NameRef p 'RequestRef,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (SyntacticRequest p) where
  sourceSpanOf request = request.sourceSpan

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------

data Expression (p :: Phase) where
  ExpressionLiteral :: LiteralExpression p -> Expression p
  ExpressionVariable :: VariableExpression p -> Expression p
  ExpressionTuple :: TupleExpression p -> Expression p
  ExpressionArray :: ArrayExpression p -> Expression p
  ExpressionCall :: CallExpression p -> Expression p
  ExpressionBinaryOperator :: BinaryOperatorExpression p -> Expression p
  ExpressionUnaryOperator :: UnaryOperatorExpression p -> Expression p
  ExpressionIf :: IfExpression p -> Expression p
  ExpressionMatch :: MatchExpression p -> Expression p
  ExpressionFor :: ForExpression p -> Expression p
  ExpressionBlock :: BlockExpression p -> Expression p
  ExpressionFieldAccess :: FieldAccessExpression p -> Expression p
  ExpressionIndexAccess :: IndexAccessExpression p -> Expression p
  ExpressionTemplate :: TemplateExpression p -> Expression p
  -- | Synthesised by the Identifier pass from a @FieldAccess@ chain whose
  -- left-most segment resolves to a module. 詳細は 'QualifiedReferenceExpression'
  -- のコメント参照。Parser never produces this directly.
  ExpressionQualifiedReference :: QualifiedReferenceExpression p -> Expression p

instance HasSourceSpan (Expression p) where
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

data LiteralExpression (p :: Phase) = LiteralExpression
  { value :: LiteralValue,
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (LiteralExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data VariableExpression (p :: Phase) = VariableExpression
  { name :: NameRef p 'VariableRef,
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (VariableExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data CallExpression (p :: Phase) = CallExpression
  { callee :: Expression p,
    arguments :: [CallArgument p],
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (CallExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data CallArgument (p :: Phase) = CallArgument
  { -- | Argument label. Resolution is type-directed (depends on the callee's
    -- parameter list), so the LabelRef symbol is filled in by the
    -- Typechecker; Identifier pass leaves it trivial.
    label :: NameRef p 'LabelRef,
    value :: Expression p,
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

data BinaryOperatorExpression (p :: Phase) = BinaryOperatorExpression
  { operator :: BinaryOperator,
    left :: Expression p,
    right :: Expression p,
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (BinaryOperatorExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data UnaryOperatorExpression (p :: Phase) = UnaryOperatorExpression
  { operator :: UnaryOperator,
    operand :: Expression p,
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (UnaryOperatorExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data TupleExpression (p :: Phase) = TupleExpression
  { elements :: [Expression p],
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (TupleExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data ArrayExpression (p :: Phase) = ArrayExpression
  { elements :: [Expression p],
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (ArrayExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data IfExpression (p :: Phase) = IfExpression
  { condition :: Expression p,
    thenBlock :: Block p,
    elseBlock :: Maybe (Block p),
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (IfExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data MatchExpression (p :: Phase) = MatchExpression
  { subject :: Expression p,
    cases :: [CaseArm p],
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (MatchExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data ForExpression (p :: Phase) = ForExpression
  { inBindings :: [ForInBinding p],
    varBindings :: [ForVarBinding p],
    body :: Block p,
    thenBlock :: Maybe (Block p),
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (ForExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data ForInBinding (p :: Phase) = ForInBinding
  { pattern :: Pattern p,
    source :: Expression p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForInBinding p) where
  sourceSpanOf binding = binding.sourceSpan

data ForVarBinding (p :: Phase) = ForVarBinding
  { name :: NameRef p 'VariableRef,
    typeAnnotation :: Maybe (SyntacticType p),
    initial :: Expression p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForVarBinding p) where
  sourceSpanOf binding = binding.sourceSpan

data BlockExpression (p :: Phase) = BlockExpression
  { block :: Block p,
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (BlockExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data FieldAccessExpression (p :: Phase) = FieldAccessExpression
  { object :: Expression p,
    -- | Field name. Resolution is type-directed (depends on the object's type),
    -- so the LabelRef symbol is filled in by the Typechecker; Identifier
    -- pass leaves it trivial.
    fieldName :: NameRef p 'LabelRef,
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (FieldAccessExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data IndexAccessExpression (p :: Phase) = IndexAccessExpression
  { array :: Expression p,
    index :: Expression p,
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (IndexAccessExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data TemplateExpression (p :: Phase) = TemplateExpression
  { elements :: [TemplateElement p],
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (TemplateExpression p) where
  sourceSpanOf expression = expression.sourceSpan

-- | 解決済み qualified 参照 @module.target@。
--
-- @target@ は値空間のシンボル (agent / req / ext agent / constructor)。
-- enum constructor も自モジュールの variable namespace に flat 展開されるため、
-- @module.ctor@ も同じ shape で表現される。
--
-- Parser は生成せず、Identifier フェーズで FieldAccess チェーンの最左が module
-- に解決された場合のみ合成する。
data QualifiedReferenceExpression (p :: Phase) = QualifiedReferenceExpression
  { moduleQualifier :: NameRef p 'ModuleRef,
    target :: NameRef p 'VariableRef,
    sourceSpan :: SourceSpan,
    typeOf :: ExprType p
  }

instance HasSourceSpan (QualifiedReferenceExpression p) where
  sourceSpanOf expression = expression.sourceSpan

data CaseArm (p :: Phase) = CaseArm
  { pattern :: Pattern p,
    body :: Block p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (CaseArm p) where
  sourceSpanOf arm = arm.sourceSpan

data TemplateElement (p :: Phase) where
  TemplateElementString :: TemplateStringElement p -> TemplateElement p
  TemplateElementExpression :: TemplateExpressionElement p -> TemplateElement p

instance HasSourceSpan (TemplateElement p) where
  sourceSpanOf = \case
    TemplateElementString element -> element.sourceSpan
    TemplateElementExpression element -> element.sourceSpan

data TemplateStringElement (p :: Phase) = TemplateStringElement
  { value :: Text,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TemplateStringElement p) where
  sourceSpanOf element = element.sourceSpan

data TemplateExpressionElement (p :: Phase) = TemplateExpressionElement
  { value :: Expression p,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TemplateExpressionElement p) where
  sourceSpanOf element = element.sourceSpan

-- ---------------------------------------------------------------------------
-- Phase retagging helpers
--
-- 後段フェーズが上流フェーズの AST を「型レベルのタグ書き換えだけ」で渡し
-- 替えたい場合のための utility。NameMeta が両フェーズで一致している
-- (Identified / Constrained / Zonked の三相は閉じた type family により同じ
-- shape) ことを @~@ 制約で明示することで、安全に retag できる。
--
-- ここで提供するのは @NameRef@ / @SyntacticType@ / @SyntacticRequest@ /
-- 各 @TypeNode@ のみ。Expression / Pattern / Statement / Declaration /
-- Module はフェーズごとに @typeOf@ が異なるため、各 walker が局所的に
-- 構築する。
-- ---------------------------------------------------------------------------

-- | Change the phase tag of a 'NameRef' when both phases share the same
-- 'NameMeta' resolution.
retagNameRef ::
  (NameMeta p1 s ~ NameMeta p2 s) =>
  NameRef p1 s ->
  NameRef p2 s
retagNameRef ref =
  NameRef
    { text = ref.text,
      sourceSpan = ref.sourceSpan,
      resolution = ref.resolution
    }

-- | Change the phase tag of a 'SyntacticType' tree when both phases share
-- the same 'NameMeta' resolution. Recurses structurally; literal nodes
-- carry no phase-dependent payload.
retagSyntacticType ::
  ( NameMeta p1 'TypeRef ~ NameMeta p2 'TypeRef,
    NameMeta p1 'ModuleRef ~ NameMeta p2 'ModuleRef,
    NameMeta p1 'VariableRef ~ NameMeta p2 'VariableRef,
    NameMeta p1 'RequestRef ~ NameMeta p2 'RequestRef
  ) =>
  SyntacticType p1 ->
  SyntacticType p2
retagSyntacticType = \case
  TypePrimitive PrimitiveTypeNode {kind, sourceSpan} ->
    TypePrimitive PrimitiveTypeNode {kind = kind, sourceSpan = sourceSpan}
  TypeName TypeNameNode {name, sourceSpan} ->
    TypeName
      TypeNameNode
        { name = retagNameRef name,
          sourceSpan = sourceSpan
        }
  TypeFunction FunctionTypeNode {parameterTypes, returnType, withEffects, sourceSpan} ->
    TypeFunction
      FunctionTypeNode
        { parameterTypes =
            [ (label, retagSyntacticType subType)
              | (label, subType) <- parameterTypes
            ],
          returnType = retagSyntacticType returnType,
          withEffects = retagSyntacticRequest <$> withEffects,
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
  (NameMeta p1 'RequestRef ~ NameMeta p2 'RequestRef) =>
  SyntacticRequest p1 ->
  SyntacticRequest p2
retagSyntacticRequest req =
  SyntacticRequest
    { name = retagNameRef req.name,
      sourceSpan = req.sourceSpan
    }

-- ---------------------------------------------------------------------------
-- Aggregate Eq / Show constraints
--
-- 各 AST ノードの Eq / Show instance は phase の metadata 型 (NameMeta /
-- ExprType / PatType) すべての Eq / Show を必要とする。@QuantifiedConstraints@
-- + @UndecidableInstances@ により @forall s. Eq (NameMeta p s)@ という
-- 量化制約が書けるので、それを束ねた 'EqPhase' / 'ShowPhase' synonym で
-- 全ての standalone deriving の前置きを統一する。
-- ---------------------------------------------------------------------------

-- | Phase-level Eq aggregate. Bundled as a class (rather than a type
-- synonym) so it can be reused as a single constraint name. GHC forbids
-- type-family applications inside quantified constraints, so we
-- enumerate each 'SymbolKind' explicitly — this is closed-kind, so the
-- four cases cover every 'NameMeta p s' use.
class
  ( Eq (NameMeta p 'VariableRef),
    Eq (NameMeta p 'TypeRef),
    Eq (NameMeta p 'ModuleRef),
    Eq (NameMeta p 'LabelRef),
    Eq (NameMeta p 'RequestRef),
    Eq (NameMeta p 'ConstructorRef),
    Eq (ExprType p),
    Eq (PatType p)
  ) =>
  EqPhase p

instance
  ( Eq (NameMeta p 'VariableRef),
    Eq (NameMeta p 'TypeRef),
    Eq (NameMeta p 'ModuleRef),
    Eq (NameMeta p 'LabelRef),
    Eq (NameMeta p 'RequestRef),
    Eq (NameMeta p 'ConstructorRef),
    Eq (ExprType p),
    Eq (PatType p)
  ) =>
  EqPhase p

class
  ( Show (NameMeta p 'VariableRef),
    Show (NameMeta p 'TypeRef),
    Show (NameMeta p 'ModuleRef),
    Show (NameMeta p 'LabelRef),
    Show (NameMeta p 'RequestRef),
    Show (NameMeta p 'ConstructorRef),
    Show (ExprType p),
    Show (PatType p)
  ) =>
  ShowPhase p

instance
  ( Show (NameMeta p 'VariableRef),
    Show (NameMeta p 'TypeRef),
    Show (NameMeta p 'ModuleRef),
    Show (NameMeta p 'LabelRef),
    Show (NameMeta p 'RequestRef),
    Show (NameMeta p 'ConstructorRef),
    Show (ExprType p),
    Show (PatType p)
  ) =>
  ShowPhase p

deriving instance (Eq (NameMeta p s)) => Eq (NameRef p s)

deriving instance (Show (NameMeta p s)) => Show (NameRef p s)

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

deriving instance (EqPhase p) => Eq (WhereBlock p)

deriving instance (ShowPhase p) => Show (WhereBlock p)

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
