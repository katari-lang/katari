-- |
-- Phase-indexed AST for the Katari language.
--
-- Each AST node is parameterized by the compiler phase via a 'Phase' tag
-- (type-level only, TypeData). 'NameRef' holds @NameRefResolution phase s@
-- (resolution information per phase + symbol kind) in its @resolution@ field,
-- and expression / pattern nodes hold @ExpressionType p@ / @PatternType phase@
-- in their @typeOf@ field.
--
-- Key design points:
--
--   * @NameRefResolution@ is a closed type family returning the same shape
--     (@Maybe Identifier@) for the three phases Identified / Constrained /
--     Zonked. Phase transitions can be passed through via 'retagNameRef' /
--     'retagSyntacticType' etc.
--   * @ExpressionType@ / @PatternType@ are also closed type families:
--     @()@ for Parsed / Identified, @SemanticType@ for Constrained / Zonked.
--     'Katari.SemanticType' is a leaf module so no cycles.
--   * 'Module' / 'Declaration' / 'Statement' families are not expected to
--     carry type information and therefore do not have a @typeOf@ field
--     (to avoid adding placeholder no-op fields).
module Katari.AST where

import Data.Kind (Type)
import Data.Text (Text)
import Katari.Common (LiteralValue (..))
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
-- NameRefKind: the kind of namespace that 'NameRef' refers to.
-- ---------------------------------------------------------------------------

type data NameRefKind where
  -- | Name reference in the value namespace (agent / req / ext agent /
  -- constructor / local var). Every name that can be called as a value goes
  -- through here.
  VariableRef :: NameRefKind
  -- | Name reference in the type namespace (enum names, TypeName).
  TypeRef :: NameRefKind
  -- | Name reference in the module namespace (import alias, left side of a
  -- qualified name).
  ModuleRef :: NameRefKind
  -- | Field / argument label (resolved later via type-directed lookup).
  LabelRef :: NameRefKind
  -- | Target of a req handler. Writing any name other than a @req@
  -- declaration as a handler is rejected at the Identifier stage (slots are
  -- separated at the type level).
  RequestRef :: NameRefKind
  -- | Constructor in a match pattern. Writing any name other than a @data@
  -- declaration as a constructor pattern is rejected at the Identifier stage.
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
  DeclarationImport :: ImportDeclaration -> Declaration phase
  DeclarationExternalAgent :: ExternalAgentDeclaration phase -> Declaration phase
  DeclarationPrimAgent :: PrimAgentDeclaration phase -> Declaration phase
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
    DeclarationPrimAgent declaration -> declaration.sourceSpan
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

data ImportDeclaration = ImportDeclaration
  { kind :: ImportKind,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan ImportDeclaration where
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
-- @kind@ distinguishes between the type namespace and the value namespace.
data ImportItem = ImportItem
  { kind :: ImportItemKind,
    name :: Text
  }
  deriving (Eq, Show)

data ImportItemKind where
  -- | Normal value import.
  ImportItemValue :: ImportItemKind
  -- | Import with a @type@ prefix. Brings the name into the type namespace.
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

-- | @prim agent name(...) -> T [with E] [using rule_name]@ — a built-in
-- primitive declared via the surface language. Treated like 'ExternalAgentDeclaration'
-- throughout typechecking; the only runtime difference is that the runtime
-- executes a hardcoded implementation keyed on 'name' rather than
-- delegating to a sidecar.
--
-- @using@ optionally names a special typing rule consulted by the
-- constraint generator (e.g. @numeric_join_binary@ for arithmetic prims
-- whose result is the join of operand types floored at integer). When
-- omitted the prim is type-checked as a vanilla function — its declared
-- 'returnType' is the inferred result.
data PrimAgentDeclaration (phase :: Phase) = PrimAgentDeclaration
  { annotation :: Maybe Text,
    name :: NameRef phase VariableRef,
    parameters :: [ParameterBinding phase],
    returnType :: SyntacticType phase,
    withRequests :: [SyntacticRequest phase],
    using :: Maybe Text,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (PrimAgentDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | @data ctor_name(field: type, ...)@ — one constructor per declaration.
-- Introduces the same name into both the value namespace (constructor
-- function) and the type namespace (data type).
--
-- In the AST both roles are kept as separate 'NameRef's: @name@ points to
-- the value namespace (constructor function) and @typeName@ points to the
-- type namespace (data type). The Parser produces both from the same
-- identifier token (sharing text and sourceSpan), and the Identifier phase
-- resolves each independently, filling the resolution with a kind-specific
-- id (VariableId / TypeId). Later phases (ConstraintGenerator onward) can
-- read the TypeId directly from the AST, so no name-text cross lookup is
-- needed.
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

-- | @type T = ...@ — type synonym. No annotation, no generics.
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
  { -- | Optional @\@"..."@ annotation, mirroring top-level @agent@ decls
    -- (parsed in front of the @agent@ keyword). Documentation only —
    -- ignored by the type system; surfaces in 'Katari.IR.AgentBlock'
    -- so AI tool-calling consumers can read it via @get_metadata@.
    annotation :: Maybe Text,
    name :: NameRef phase VariableRef,
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

-- | @req name(...) { body }@ or @req module.name(...) { body }@.
-- @name@ is not a new binding but a reference to an existing req declaration.
-- When @moduleQualifier@ is @Just@, this implements a req from another
-- module.
-- | A req handler does not have its own request set (requests inside the
-- handler are bound to the enclosing agent), so there is no @with@ clause
-- syntactically or in the AST.
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

-- | Constructor pattern. Constructors are flattened into the top-level
-- variable namespace of their owning module, so only two forms exist:
-- bare @ctor(...)@ or @module.ctor(...)@. The @type.ctor@ syntax is
-- obsolete.
--
-- The parser produces this when it sees @ident(...)@ / @ident.ident(...)@
-- at a pattern position (with a @(@ lookahead). A bare @ident@ (no parens)
-- stays as 'VariablePattern'.
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
  -- | Type-level literal: @"foo"@ / @42@ / @true@ / @false@ / @null@.
  -- Reuses the value-level 'LiteralValue' (Float is not supported).
  TypeLiteral :: TypeLiteralNode -> SyntacticType phase
  -- | @T1 | T2 | ...@ union type. Lowest precedence (weaker than
  -- function/array). Always has 2 or more branches. Order preserving.
  TypeUnion :: TypeUnionNode phase -> SyntacticType phase
  -- | @never@ — the bottom type of the lattice. Has no values. Used in
  -- @agent f() -> never@ etc. to declare "never returns".
  TypeNever :: NeverTypeNode phase -> SyntacticType phase
  -- | @unknown@ — the top type of the lattice. Accepts any value, but the
  -- consumer must narrow it before use (same idea as TypeScript's
  -- @unknown@).
  TypeUnknown :: UnknownTypeNode phase -> SyntacticType phase
  -- | @function@ — the top of the function-type lattice. Used by
  -- reflection-style APIs (e.g. @get_metadata@) that accept any callable
  -- (any concrete @(P) -> R with E@). Cannot be called (params unknown).
  TypeFunctionAny :: FunctionAnyTypeNode phase -> SyntacticType phase

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
    TypeFunctionAny node -> node.sourceSpan

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

-- | AST node for the @never@ type. The bottom of the lattice (a type with
-- no values); kept as a separate node because it is not a primitive
-- (concrete data) type.
newtype NeverTypeNode (phase :: Phase) = NeverTypeNode
  { sourceSpan :: SourceSpan
  }

instance HasSourceSpan (NeverTypeNode p) where
  sourceSpanOf node = node.sourceSpan

-- | AST node for the @unknown@ type. The top of the lattice (any value);
-- callers must narrow it before use. Kept as a separate node because it is
-- not a primitive.
newtype UnknownTypeNode (phase :: Phase) = UnknownTypeNode
  { sourceSpan :: SourceSpan
  }

instance HasSourceSpan (UnknownTypeNode p) where
  sourceSpanOf node = node.sourceSpan

-- | AST node for the @function@ type. The top of the function-type
-- lattice; a supertype of any concrete 'FunctionTypeNode'. Cannot be called
-- (params unknown).
newtype FunctionAnyTypeNode (phase :: Phase) = FunctionAnyTypeNode
  { sourceSpan :: SourceSpan
  }

instance HasSourceSpan (FunctionAnyTypeNode p) where
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

-- | @T1 | T2 | ...@ union type. Always has 2 or more branches.
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
  -- left-most segment resolves to a module. See the comment on
  -- 'QualifiedReferenceExpression' for details. Parser never produces this
  -- directly.
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
  BinaryOperatorModulo :: BinaryOperator
  BinaryOperatorEqual :: BinaryOperator
  BinaryOperatorNotEqual :: BinaryOperator
  BinaryOperatorLessThan :: BinaryOperator
  BinaryOperatorLessOrEqual :: BinaryOperator
  BinaryOperatorGreaterThan :: BinaryOperator
  BinaryOperatorGreaterOrEqual :: BinaryOperator
  BinaryOperatorAnd :: BinaryOperator
  BinaryOperatorOr :: BinaryOperator
  BinaryOperatorConcat :: BinaryOperator
  deriving (Eq, Show, Bounded, Enum)

data UnaryOperator where
  UnaryOperatorNegate :: UnaryOperator
  UnaryOperatorNot :: UnaryOperator
  deriving (Eq, Show, Bounded, Enum)

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

-- | Resolved qualified reference @module.target@.
--
-- @target@ is a symbol in the value namespace (agent / req / ext agent /
-- constructor). Enum constructors are also flattened into their owning
-- module's variable namespace, so @module.ctor@ is represented with the
-- same shape.
--
-- The parser does not produce this; the Identifier phase synthesises it
-- only when the left-most segment of a FieldAccess chain resolves to a
-- module.
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
-- Utility for downstream phases that want to pass through upstream phase
-- ASTs with only "type-level tag rewriting". Safety is established by
-- using a @~@ constraint to assert that @NameRefResolution@ agrees between
-- the two phases (the three phases Identified / Constrained / Zonked share
-- the same shape via a closed type family).
--
-- Only @NameRef@ / @SyntacticType@ / @SyntacticRequest@ / each @TypeNode@
-- are provided here. Expression / Pattern / Statement / Declaration /
-- Module have a phase-specific @typeOf@, so each walker constructs them
-- locally.
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
  TypeFunctionAny FunctionAnyTypeNode {sourceSpan} ->
    TypeFunctionAny FunctionAnyTypeNode {sourceSpan = sourceSpan}

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

-- ---------------------------------------------------------------------------
-- Aggregate Eq / Show constraints
--
-- The Eq / Show instances of every AST node require Eq / Show for all the
-- phase metadata types (NameRefResolution / ExpressionType / PatternType).
-- With @QuantifiedConstraints@ + @UndecidableInstances@ we can write a
-- quantified constraint like @forall s. Eq (NameRefResolution phase s)@,
-- which we bundle into the 'EqPhase' / 'ShowPhase' synonyms to unify the
-- preambles of every standalone deriving.
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

deriving instance (Eq (NameRefResolution phase nameRefKind)) => Eq (NameRef phase nameRefKind)

deriving instance (Show (NameRefResolution phase nameRefKind)) => Show (NameRef phase nameRefKind)

deriving instance (EqPhase phase) => Eq (Module phase)

deriving instance (ShowPhase phase) => Show (Module phase)

deriving instance (EqPhase phase) => Eq (Declaration phase)

deriving instance (ShowPhase phase) => Show (Declaration phase)

deriving instance (EqPhase phase) => Eq (AgentDeclaration phase)

deriving instance (ShowPhase phase) => Show (AgentDeclaration phase)

deriving instance (EqPhase phase) => Eq (RequestDeclaration phase)

deriving instance (ShowPhase phase) => Show (RequestDeclaration phase)

deriving instance Eq ImportDeclaration

deriving instance Show ImportDeclaration

deriving instance (EqPhase phase) => Eq (ExternalAgentDeclaration phase)

deriving instance (ShowPhase phase) => Show (ExternalAgentDeclaration phase)

deriving instance (EqPhase phase) => Eq (PrimAgentDeclaration phase)

deriving instance (ShowPhase phase) => Show (PrimAgentDeclaration phase)

deriving instance (EqPhase phase) => Eq (DataDeclaration phase)

deriving instance (ShowPhase phase) => Show (DataDeclaration phase)

deriving instance (EqPhase phase) => Eq (DataParameter phase)

deriving instance (ShowPhase phase) => Show (DataParameter phase)

deriving instance (EqPhase phase) => Eq (TypeSynonymDeclaration phase)

deriving instance (ShowPhase phase) => Show (TypeSynonymDeclaration phase)

deriving instance (EqPhase phase) => Eq (Block phase)

deriving instance (ShowPhase phase) => Show (Block phase)

deriving instance (EqPhase phase) => Eq (HandleExpression phase)

deriving instance (ShowPhase phase) => Show (HandleExpression phase)

deriving instance (EqPhase phase) => Eq (StateVariableBinding phase)

deriving instance (ShowPhase phase) => Show (StateVariableBinding phase)

deriving instance (EqPhase phase) => Eq (Statement phase)

deriving instance (ShowPhase phase) => Show (Statement phase)

deriving instance (EqPhase phase) => Eq (LetStatement phase)

deriving instance (ShowPhase phase) => Show (LetStatement phase)

deriving instance (EqPhase phase) => Eq (AgentStatement phase)

deriving instance (ShowPhase phase) => Show (AgentStatement phase)

deriving instance (EqPhase phase) => Eq (ReturnStatement phase)

deriving instance (ShowPhase phase) => Show (ReturnStatement phase)

deriving instance (EqPhase phase) => Eq (NextStatement phase)

deriving instance (ShowPhase phase) => Show (NextStatement phase)

deriving instance (EqPhase phase) => Eq (BreakStatement phase)

deriving instance (ShowPhase phase) => Show (BreakStatement phase)

deriving instance (EqPhase phase) => Eq (ForNextStatement phase)

deriving instance (ShowPhase phase) => Show (ForNextStatement phase)

deriving instance (EqPhase phase) => Eq (ForBreakStatement phase)

deriving instance (ShowPhase phase) => Show (ForBreakStatement phase)

deriving instance (EqPhase phase) => Eq (Modifier phase)

deriving instance (ShowPhase phase) => Show (Modifier phase)

deriving instance (EqPhase phase) => Eq (RequestHandler phase)

deriving instance (ShowPhase phase) => Show (RequestHandler phase)

deriving instance (EqPhase phase) => Eq (Pattern phase)

deriving instance (ShowPhase phase) => Show (Pattern phase)

deriving instance (EqPhase phase) => Eq (TuplePattern phase)

deriving instance (ShowPhase phase) => Show (TuplePattern phase)

deriving instance (EqPhase phase) => Eq (WildcardPattern phase)

deriving instance (ShowPhase phase) => Show (WildcardPattern phase)

deriving instance (EqPhase phase) => Eq (VariablePattern phase)

deriving instance (ShowPhase phase) => Show (VariablePattern phase)

deriving instance (EqPhase phase) => Eq (ParameterBinding phase)

deriving instance (ShowPhase phase) => Show (ParameterBinding phase)

deriving instance (EqPhase phase) => Eq (QualifiedConstructorPattern phase)

deriving instance (ShowPhase phase) => Show (QualifiedConstructorPattern phase)

deriving instance (EqPhase phase) => Eq (LiteralPattern phase)

deriving instance (ShowPhase phase) => Show (LiteralPattern phase)

deriving instance (EqPhase phase) => Eq (SyntacticType phase)

deriving instance (ShowPhase phase) => Show (SyntacticType phase)

deriving instance Eq (PrimitiveTypeNode phase)

deriving instance Show (PrimitiveTypeNode phase)

deriving instance Eq (NeverTypeNode phase)

deriving instance Show (NeverTypeNode phase)

deriving instance Eq (UnknownTypeNode phase)

deriving instance Show (UnknownTypeNode phase)

deriving instance Eq (FunctionAnyTypeNode phase)

deriving instance Show (FunctionAnyTypeNode phase)

deriving instance (EqPhase phase) => Eq (TypeNameNode phase)

deriving instance (ShowPhase phase) => Show (TypeNameNode phase)

deriving instance (EqPhase phase) => Eq (FunctionTypeNode phase)

deriving instance (ShowPhase phase) => Show (FunctionTypeNode phase)

deriving instance (EqPhase phase) => Eq (ArrayTypeNode phase)

deriving instance (ShowPhase phase) => Show (ArrayTypeNode phase)

deriving instance (EqPhase phase) => Eq (TupleTypeNode phase)

deriving instance (ShowPhase phase) => Show (TupleTypeNode phase)

deriving instance (EqPhase phase) => Eq (QualifiedTypeNode phase)

deriving instance (ShowPhase phase) => Show (QualifiedTypeNode phase)

deriving instance (EqPhase phase) => Eq (TypeUnionNode phase)

deriving instance (ShowPhase phase) => Show (TypeUnionNode phase)

deriving instance (EqPhase phase) => Eq (SyntacticRequest phase)

deriving instance (ShowPhase phase) => Show (SyntacticRequest phase)

deriving instance (EqPhase phase) => Eq (Expression phase)

deriving instance (ShowPhase phase) => Show (Expression phase)

deriving instance (EqPhase phase) => Eq (LiteralExpression phase)

deriving instance (ShowPhase phase) => Show (LiteralExpression phase)

deriving instance (EqPhase phase) => Eq (VariableExpression phase)

deriving instance (ShowPhase phase) => Show (VariableExpression phase)

deriving instance (EqPhase phase) => Eq (CallExpression phase)

deriving instance (ShowPhase phase) => Show (CallExpression phase)

deriving instance (EqPhase phase) => Eq (CallArgument phase)

deriving instance (ShowPhase phase) => Show (CallArgument phase)

deriving instance (EqPhase phase) => Eq (BinaryOperatorExpression phase)

deriving instance (ShowPhase phase) => Show (BinaryOperatorExpression phase)

deriving instance (EqPhase phase) => Eq (UnaryOperatorExpression phase)

deriving instance (ShowPhase phase) => Show (UnaryOperatorExpression phase)

deriving instance (EqPhase phase) => Eq (TupleExpression phase)

deriving instance (ShowPhase phase) => Show (TupleExpression phase)

deriving instance (EqPhase phase) => Eq (ArrayExpression phase)

deriving instance (ShowPhase phase) => Show (ArrayExpression phase)

deriving instance (EqPhase phase) => Eq (ParTupleExpression phase)

deriving instance (ShowPhase phase) => Show (ParTupleExpression phase)

deriving instance (EqPhase phase) => Eq (ParArrayExpression phase)

deriving instance (ShowPhase phase) => Show (ParArrayExpression phase)

deriving instance (EqPhase phase) => Eq (IfExpression phase)

deriving instance (ShowPhase phase) => Show (IfExpression phase)

deriving instance (EqPhase phase) => Eq (MatchExpression phase)

deriving instance (ShowPhase phase) => Show (MatchExpression phase)

deriving instance (EqPhase phase) => Eq (ForExpression phase)

deriving instance (ShowPhase phase) => Show (ForExpression phase)

deriving instance (EqPhase phase) => Eq (ForInBinding phase)

deriving instance (ShowPhase phase) => Show (ForInBinding phase)

deriving instance (EqPhase phase) => Eq (ForVarBinding phase)

deriving instance (ShowPhase phase) => Show (ForVarBinding phase)

deriving instance (EqPhase phase) => Eq (BlockExpression phase)

deriving instance (ShowPhase phase) => Show (BlockExpression phase)

deriving instance (EqPhase phase) => Eq (FieldAccessExpression phase)

deriving instance (ShowPhase phase) => Show (FieldAccessExpression phase)

deriving instance (EqPhase phase) => Eq (IndexAccessExpression phase)

deriving instance (ShowPhase phase) => Show (IndexAccessExpression phase)

deriving instance (EqPhase phase) => Eq (TemplateExpression phase)

deriving instance (ShowPhase phase) => Show (TemplateExpression phase)

deriving instance (EqPhase phase) => Eq (QualifiedReferenceExpression phase)

deriving instance (ShowPhase phase) => Show (QualifiedReferenceExpression phase)

deriving instance (EqPhase phase) => Eq (CaseArm phase)

deriving instance (ShowPhase phase) => Show (CaseArm phase)

deriving instance (EqPhase phase) => Eq (TemplateElement phase)

deriving instance (ShowPhase phase) => Show (TemplateElement phase)

deriving instance Eq (TemplateStringElement phase)

deriving instance Show (TemplateStringElement phase)

deriving instance (EqPhase phase) => Eq (TemplateExpressionElement phase)

deriving instance (ShowPhase phase) => Show (TemplateExpressionElement phase)
