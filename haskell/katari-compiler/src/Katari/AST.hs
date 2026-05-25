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

-- | The namespace tag carried by a 'NameRef'. Each value separates a
-- distinct symbol space so the Identifier pass can reject category errors
-- (e.g. \"this is not a request\") at the type level rather than relying on
-- runtime checks.
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

-- | A use-site occurrence of an identifier in source code. Carries the raw
-- text, the source span, and a phase-dependent resolution payload (see
-- 'NameRefResolution'). The @nameRefKind@ phantom records which namespace
-- this reference targets (variable / type / module / label / request /
-- constructor).
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

-- | A whole compiled source file (@.ktr@). A flat list of top-level
-- 'Declaration's plus the span of the entire file.
data Module (phase :: Phase) = Module
  { declarations :: [Declaration phase],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Module phase) where
  sourceSpanOf module' = module'.sourceSpan

-- ---------------------------------------------------------------------------
-- Declarations
-- ---------------------------------------------------------------------------

-- | A top-level declaration in a module. Sum over every shape of
-- declaration the surface language admits, plus a 'DeclarationError'
-- sentinel left behind by parser recovery.
data Declaration (phase :: Phase) where
  -- | @agent name(...) -> T [with E] { body }@.
  DeclarationAgent :: AgentDeclaration phase -> Declaration phase
  -- | @req name(...) -> T@ — declares a request effect.
  DeclarationRequest :: RequestDeclaration phase -> Declaration phase
  -- | @import { ... } from \"...\"@ — Phase-independent.
  DeclarationImport :: ImportDeclaration -> Declaration phase
  -- | @ext agent name(...) -> T@ — JS sidecar binding.
  DeclarationExternalAgent :: ExternalAgentDeclaration phase -> Declaration phase
  -- | @prim agent name(...) -> T [using rule]@ — built-in primitive.
  DeclarationPrimAgent :: PrimAgentDeclaration phase -> Declaration phase
  -- | @data ctor(field: T, ...)@ — single-constructor data type.
  DeclarationData :: DataDeclaration phase -> Declaration phase
  -- | @type T = ...@ — type synonym.
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

-- | @agent name(...) -> T [with R] { body }@ — the primary callable form.
-- The optional @annotation@ is a leading @\@\"...\"@ string used for AI
-- tool-calling descriptions; @withRequests@ is the optional request set
-- (omit / @Nothing@ for pure agents).
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

-- | @req name(...) -> T@ — declares a request effect. The same source
-- identifier shows up as both a value (a callable that triggers the
-- request) and a request-namespace symbol (the target of @req@ handlers);
-- the two roles are kept as separate 'NameRef's so the Identifier pass can
-- fill in kind-specific ids independently.
data RequestDeclaration (phase :: Phase) = RequestDeclaration
  { annotation :: Maybe Text,
    name :: NameRef phase VariableRef,
    -- | Same identifier, viewed as a request-namespace symbol.
    requestName :: NameRef phase RequestRef,
    parameters :: [ParameterBinding phase],
    returnType :: SyntacticType phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RequestDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | @import { ... } from \"mod\"@ or @import \"mod\" as alias@.
-- Phase-independent: the Identifier pass records imports in scope tables,
-- so no per-phase metadata lives on the AST node.
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

-- | Which namespace an individual import item targets. Set by the parser
-- depending on whether the import was prefixed with @type@.
data ImportItemKind where
  -- | Normal value import.
  ImportItemValue :: ImportItemKind
  -- | Import with a @type@ prefix. Brings the name into the type namespace.
  ImportItemType :: ImportItemKind
  deriving (Eq, Show)

-- | @ext agent name(...) -> T [with E] from "ENDPOINT:dispatch_name"@ — a
-- foreign agent implemented outside Katari (JS sidecar, ENV module, ...).
-- The compiler treats it like a regular agent for typechecking; the runtime
-- dispatches to the named endpoint at call time using @dispatchName@ as the
-- opaque key.
--
-- @from "ENDPOINT:name"@ is **required** (parser error otherwise). The
-- endpoint string (e.g. @"FFI"@ / @"ENV"@) selects the runtime module that
-- handles dispatch, and @dispatchName@ is the flat name that module
-- registers under — completely independent of Katari's module path.
data ExternalAgentDeclaration (phase :: Phase) = ExternalAgentDeclaration
  { annotation :: Maybe Text,
    name :: NameRef phase VariableRef,
    parameters :: [ParameterBinding phase],
    returnType :: SyntacticType phase,
    withRequests :: [SyntacticRequest phase],
    -- | Endpoint identifier (e.g. @"FFI"@, @"ENV"@). Always present.
    endpoint :: Text,
    -- | Flat dispatch name inside the endpoint's registry. Always present.
    dispatchName :: Text,
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

-- | One field of a @data ctor(...)@ declaration. The field name lives in
-- the per-object label namespace and stays as bare text (no 'NameRef'):
-- label resolution is performed type-directed by the typechecker.
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

-- | A code block — a list of statements optionally followed by a trailing
-- expression. The trailing expression (when present) is the block's value,
-- in Rust-style. Appears as agent / handler / match arm / for body /
-- standalone @{ ... }@.
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

-- | One @var name [: T] = init@ binding inside a 'HandleExpression''s
-- @(...)@ list. Visible to all handlers in the same @handle@ scope; only
-- @next@ inside a handler may mutate it.
data StateVariableBinding (phase :: Phase) = StateVariableBinding
  { name :: NameRef phase VariableRef,
    typeAnnotation :: Maybe (SyntacticType phase),
    initial :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (StateVariableBinding phase) where
  sourceSpanOf binding = binding.sourceSpan

-- | A single statement inside a 'Block'. The various @next@ / @break@
-- forms split by context (for-loop vs. request handler) — the parser
-- discriminates between them based on the enclosing 'BreakContext' so that
-- downstream phases can pattern-match without re-deriving context.
data Statement (phase :: Phase) where
  -- | @let pat = expr@.
  StatementLet :: LetStatement phase -> Statement phase
  -- | Locally-bound agent (closure over the enclosing scope).
  StatementAgent :: AgentStatement phase -> Statement phase
  -- | @return expr@. Bubbles up to the enclosing agent body.
  StatementReturn :: ReturnStatement phase -> Statement phase
  -- | Bare expression used for its effects (or trailing value).
  StatementExpression :: Expression phase -> Statement phase
  -- | @next v@ inside a request handler — resumes the suspended caller
  -- and optionally updates handle-scope @var@ state.
  StatementNext :: NextStatement phase -> Statement phase
  -- | @break v@ inside a request handler — exits the @handle@ scope with
  -- value @v@.
  StatementBreak :: BreakStatement phase -> Statement phase
  -- | @next@ (no value) inside a @for@ body — proceed to the next
  -- iteration, optionally updating loop @var@ state.
  StatementForNext :: ForNextStatement phase -> Statement phase
  -- | @break v@ inside a @for@ body — exit the loop with value @v@.
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

-- | @let pat = expr@. The pattern is irrefutable; refutable patterns
-- (e.g. literals) are rejected at the Lowering phase
-- (@LowerErrorRefutablePatternInIrrefutableContext@, K0303).
data LetStatement (phase :: Phase) = LetStatement
  { pattern :: Pattern phase,
    value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (LetStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

-- | A locally-bound agent — @agent name(...) -> T { body }@ used as a
-- statement. Closure capture relies on the runtime's lexical scope
-- inheritance, so the AST does not record captures explicitly.
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

-- | @return expr@ — early exit from the enclosing agent body with @expr@
-- as the result.
data ReturnStatement (phase :: Phase) = ReturnStatement
  { value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ReturnStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

-- | @next v [with state = expr, ...]@ inside a request handler — resumes
-- the suspended caller with @v@ and optionally updates handle-scope @var@
-- state via 'Modifier's.
data NextStatement (phase :: Phase) = NextStatement
  { value :: Expression phase,
    modifiers :: [Modifier phase],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (NextStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

-- | @break v@ inside a request handler — exits the @handle@ scope and
-- delivers @v@ to the @then@ clause (or as the @handle@ expression's
-- value if no @then@).
data BreakStatement (phase :: Phase) = BreakStatement
  { value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (BreakStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

-- | @next [with var = expr, ...]@ inside a @for@ body — proceeds to the
-- next iteration. Unlike 'NextStatement' there is no carried value;
-- 'modifiers' update loop @var@ bindings.
data ForNextStatement (phase :: Phase) = ForNextStatement
  { modifiers :: [Modifier phase],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForNextStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

-- | @break v@ inside a @for@ body — exits the loop with value @v@.
data ForBreakStatement (phase :: Phase) = ForBreakStatement
  { value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForBreakStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

-- | A single @name = expr@ entry inside a @with (...)@ list on @next@ /
-- @for next@. Updates the named state variable when the continuation
-- resumes.
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

-- | A pattern used in @let@, @match@ arms, @for ... in@, and parameter
-- bindings. The five shapes (variable, constructor, tuple, wildcard,
-- literal) cover the full surface syntax; nested constructor / literal
-- patterns can recursively contain any 'Pattern'.
data Pattern (phase :: Phase) where
  -- | @x@ — bind the matched value to a new variable.
  PatternVariable :: VariablePattern phase -> Pattern phase
  -- | @ctor(field = pat, ...)@ or @module.ctor(...)@ — constructor pattern.
  PatternQualifiedConstructor :: QualifiedConstructorPattern phase -> Pattern phase
  -- | @(p1, p2, ...)@ — tuple pattern.
  PatternTuple :: TuplePattern phase -> Pattern phase
  -- | @_@ — match anything, bind nothing.
  PatternWildcard :: WildcardPattern phase -> Pattern phase
  -- | @42@ / @\"foo\"@ / @true@ — refutable; rejected in @let@-context.
  PatternLiteral :: LiteralPattern phase -> Pattern phase

instance HasSourceSpan (Pattern phase) where
  sourceSpanOf = \case
    PatternVariable pattern' -> pattern'.sourceSpan
    PatternQualifiedConstructor pattern' -> pattern'.sourceSpan
    PatternTuple pattern' -> pattern'.sourceSpan
    PatternWildcard pattern' -> pattern'.sourceSpan
    PatternLiteral pattern' -> pattern'.sourceSpan

-- | @(p1, p2, ...)@ tuple pattern. Each element is matched positionally.
data TuplePattern (phase :: Phase) = TuplePattern
  { elements :: [Pattern phase],
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (TuplePattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

-- | @_@ / @_: T@ wildcard. Matches anything, binds no name; an optional
-- type annotation can be used purely to assert the matched value's type.
data WildcardPattern (phase :: Phase) = WildcardPattern
  { typeAnnotation :: Maybe (SyntacticType phase),
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (WildcardPattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

-- | @x@ / @x: T@ variable binding pattern. The type annotation, when
-- present, is checked as a subtype assertion at the binding site.
data VariablePattern (phase :: Phase) = VariablePattern
  { name :: NameRef phase VariableRef,
    typeAnnotation :: Maybe (SyntacticType phase),
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (VariablePattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

-- | A formal parameter of an agent / request / external / prim
-- declaration: @label = pattern@. The @label@ is the call-site keyword
-- (kept as bare text, per the label-namespace policy); the @pattern@
-- destructures the argument once bound.
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

-- | A literal pattern like @42@, @\"foo\"@, @true@, or @null@. Refutable —
-- only legal inside @match@ arms; in @let@ context the Lowering pass
-- rejects it with @LowerErrorRefutablePatternInIrrefutableContext@.
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

-- | A type as it appears in source. The typechecker translates this into
-- the lattice-based 'SemanticType' used for subtype reasoning; surface
-- forms like @T1 | T2@, @never@, @unknown@, @function@ are kept as their
-- own constructors so error reporting can recover the original surface
-- shape.
data SyntacticType (phase :: Phase) where
  -- | @null@ / @integer@ / @number@ / @string@ / @boolean@.
  TypePrimitive :: PrimitiveTypeNode phase -> SyntacticType phase
  -- | Bare type name (refers to a @data@ / @type@ declaration).
  TypeName :: TypeNameNode phase -> SyntacticType phase
  -- | @(p: T, ...) -> R [with E]@ — concrete function type.
  TypeFunction :: FunctionTypeNode phase -> SyntacticType phase
  -- | @T[]@ — homogeneous array.
  TypeArray :: ArrayTypeNode phase -> SyntacticType phase
  -- | @(T1, T2, ...)@ — fixed-length, position-typed tuple.
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
  -- | @agent@ (the @function@ keyword was retired) — the top of the
  -- function-type lattice. Used by reflection-style APIs
  -- (e.g. @get_metadata@) that accept any callable (any concrete
  -- @(P) -> R with E@). Cannot be called (params unknown).
  TypeFunctionAny :: FunctionAnyTypeNode phase -> SyntacticType phase
  -- | @record[K, V]@ — a homogeneous map from keys of type @K@ to
  -- values of type @V@. In v0.1.0 @K@ is restricted to @string@ at
  -- the Identifier pass; the slot is kept generic for forward
  -- compatibility with generics (v0.2). The wire form is a plain
  -- JSON object (no @$constructor@ / @$agent@ / @$secret@ discriminator);
  -- the runtime reserves @$@-prefixed keys for tagged values.
  TypeRecord :: RecordTypeNode phase -> SyntacticType phase

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
    TypeRecord node -> node.sourceSpan

-- | Which primitive type a 'PrimitiveTypeNode' carries. The five surface
-- primitives that have a dedicated keyword.
data PrimitiveTypeKind where
  PrimitiveTypeKindNull :: PrimitiveTypeKind
  PrimitiveTypeKindInteger :: PrimitiveTypeKind
  PrimitiveTypeKindNumber :: PrimitiveTypeKind
  PrimitiveTypeKindString :: PrimitiveTypeKind
  PrimitiveTypeKindSecret :: PrimitiveTypeKind
  PrimitiveTypeKindBoolean :: PrimitiveTypeKind
  deriving (Eq, Show)

-- | AST node for a primitive type keyword (@null@ / @integer@ / @number@
-- / @string@ / @boolean@). The @kind@ field selects which one.
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

-- | AST node for a @record[K, V]@ type. The key type @K@ is currently
-- constrained to @string@ at the Identifier pass; the AST keeps the
-- slot generic to give v0.2 generics a hookable shape.
data RecordTypeNode (phase :: Phase) = RecordTypeNode
  { keyType :: SyntacticType phase,
    valueType :: SyntacticType phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RecordTypeNode p) where
  sourceSpanOf node = node.sourceSpan

-- | AST node for a bare type name. The 'NameRef' is resolved against the
-- type namespace by the Identifier pass.
data TypeNameNode (phase :: Phase) = TypeNameNode
  { name :: NameRef phase TypeRef,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeNameNode p) where
  sourceSpanOf node = node.sourceSpan

-- | AST node for a function type @(label: T, ...) -> R [with E]@. Parameter
-- labels are kept as bare text — label resolution is type-directed.
data FunctionTypeNode (phase :: Phase) = FunctionTypeNode
  { -- | Function-parameter labels live in a per-object namespace.
    parameterTypes :: [(Text, SyntacticType phase)],
    returnType :: SyntacticType phase,
    withRequests :: [SyntacticRequest phase],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (FunctionTypeNode p) where
  sourceSpanOf node = node.sourceSpan

-- | AST node for a homogeneous array type @T[]@.
data ArrayTypeNode (phase :: Phase) = ArrayTypeNode
  { elementType :: SyntacticType phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ArrayTypeNode p) where
  sourceSpanOf node = node.sourceSpan

-- | AST node for a tuple type @(T1, T2, ...)@.
data TupleTypeNode (phase :: Phase) = TupleTypeNode
  { elementTypes :: [SyntacticType phase],
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TupleTypeNode p) where
  sourceSpanOf node = node.sourceSpan

-- | AST node for @module.TypeName@ — a type imported from another module
-- and referenced via its qualifier rather than a bare name.
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

-- | An entry in a @with@-clause: one request name. Resolved against the
-- request namespace.
data SyntacticRequest (phase :: Phase) = SyntacticRequest
  { name :: NameRef phase RequestRef,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (SyntacticRequest phase) where
  sourceSpanOf request = request.sourceSpan

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------

-- | All expression shapes. Every variant carries a 'typeOf' field (in its
-- specific node type) holding phase-dependent type information.
-- 'ExpressionHandle', 'ExpressionParTuple', 'ExpressionParArray', and
-- 'ExpressionQualifiedReference' are documented with their constructors;
-- the rest correspond directly to their named node.
data Expression (phase :: Phase) where
  -- | Literal value @42@ / @\"foo\"@ / @true@ / @null@ / ...
  ExpressionLiteral :: LiteralExpression phase -> Expression phase
  -- | Bare identifier reference.
  ExpressionVariable :: VariableExpression phase -> Expression phase
  -- | Tuple literal @(e1, e2, ...)@.
  ExpressionTuple :: TupleExpression phase -> Expression phase
  -- | Array literal @[e1, e2, ...]@.
  ExpressionArray :: ArrayExpression phase -> Expression phase
  -- | Function / agent call @callee(arg = expr, ...)@.
  ExpressionCall :: CallExpression phase -> Expression phase
  -- | Binary operator application @e1 op e2@.
  ExpressionBinaryOperator :: BinaryOperatorExpression phase -> Expression phase
  -- | Unary operator application @op e@.
  ExpressionUnaryOperator :: UnaryOperatorExpression phase -> Expression phase
  -- | @if cond { ... } else { ... }@ — both branches are 'Block's.
  ExpressionIf :: IfExpression phase -> Expression phase
  -- | @match subject { arm; arm; ... }@.
  ExpressionMatch :: MatchExpression phase -> Expression phase
  -- | @for (in / var bindings) { body } then { fin }@.
  ExpressionFor :: ForExpression phase -> Expression phase
  -- | Standalone @{ ... }@ used in expression position.
  ExpressionBlock :: BlockExpression phase -> Expression phase
  -- | @obj.field@.
  ExpressionFieldAccess :: FieldAccessExpression phase -> Expression phase
  -- | @arr[idx]@.
  ExpressionIndexAccess :: IndexAccessExpression phase -> Expression phase
  -- | @f\"...\"@ template literal with interpolation.
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

-- | Literal value expression: @42@, @\"foo\"@, @true@, @null@, ...
data LiteralExpression (phase :: Phase) = LiteralExpression
  { value :: LiteralValue,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (LiteralExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | Bare identifier @x@ used as a value reference (local var, agent, req,
-- ext agent, or constructor).
data VariableExpression (phase :: Phase) = VariableExpression
  { name :: NameRef phase VariableRef,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (VariableExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | Call expression @callee(label = value, ...)@. Arguments are
-- keyword-labelled; ordering inside the parentheses doesn't matter, but
-- the AST preserves the source order.
data CallExpression (phase :: Phase) = CallExpression
  { callee :: Expression phase,
    arguments :: [CallArgument phase],
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (CallExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | One @label = value@ entry inside a 'CallExpression''s argument list.
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

-- | The set of binary operators recognised by the parser. Each maps to a
-- prim agent during Lowering.
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

-- | The set of unary operators: arithmetic negation @-x@ and logical
-- negation @!x@.
data UnaryOperator where
  UnaryOperatorNegate :: UnaryOperator
  UnaryOperatorNot :: UnaryOperator
  deriving (Eq, Show, Bounded, Enum)

-- | Binary operator application @left op right@.
data BinaryOperatorExpression (phase :: Phase) = BinaryOperatorExpression
  { operator :: BinaryOperator,
    left :: Expression phase,
    right :: Expression phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (BinaryOperatorExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | Unary operator application @op operand@.
data UnaryOperatorExpression (phase :: Phase) = UnaryOperatorExpression
  { operator :: UnaryOperator,
    operand :: Expression phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (UnaryOperatorExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | Tuple literal @(e1, e2, ...)@. Sequential evaluation (left-to-right).
-- See 'ParTupleExpression' for the @par@ variant.
data TupleExpression (phase :: Phase) = TupleExpression
  { elements :: [Expression phase],
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (TupleExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | Array literal @[e1, e2, ...]@. Sequential evaluation. See
-- 'ParArrayExpression' for the @par@ variant.
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

-- | @if cond { thenBlock } else { elseBlock }@. The @else@ branch is
-- optional; when omitted the expression's type is @null | thenType@.
data IfExpression (phase :: Phase) = IfExpression
  { condition :: Expression phase,
    thenBlock :: Block phase,
    elseBlock :: Maybe (Block phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (IfExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | @match subject { pat -> body; ... }@. Arms are tried in source order;
-- exhaustiveness is checked separately.
data MatchExpression (phase :: Phase) = MatchExpression
  { subject :: Expression phase,
    cases :: [CaseArm phase],
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (MatchExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | @[par] for (pat in src; var x = init; ...) { body } [then { fin }]@.
-- Combines iteration over sources with mutable loop state. The overall
-- type is the union of @break@ types and the @then@-block type (or @null@
-- when there is no @then@).
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

-- | One @pat in source@ binding inside a 'ForExpression' header — iterate
-- @pat@ over the elements of @source@ (an array).
data ForInBinding (phase :: Phase) = ForInBinding
  { pattern :: Pattern phase,
    source :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForInBinding phase) where
  sourceSpanOf binding = binding.sourceSpan

-- | One @var name [: T] = init@ binding inside a 'ForExpression' header —
-- mutable loop state, updated via @for next with name = expr@.
data ForVarBinding (phase :: Phase) = ForVarBinding
  { name :: NameRef phase VariableRef,
    typeAnnotation :: Maybe (SyntacticType phase),
    initial :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForVarBinding phase) where
  sourceSpanOf binding = binding.sourceSpan

-- | Standalone @{ ... }@ block used in expression position (e.g. as the
-- RHS of @let@ or an argument).
data BlockExpression (phase :: Phase) = BlockExpression
  { block :: Block phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (BlockExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | @object.fieldName@ — field projection. The Identifier pass cannot
-- resolve the field (a label) on its own; the typechecker fills it in
-- once the @object@'s type is known.
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

-- | @array[index]@ — array indexing.
data IndexAccessExpression (phase :: Phase) = IndexAccessExpression
  { array :: Expression phase,
    index :: Expression phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (IndexAccessExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | Template literal @f\"...\"@ / @f\"\"\"...\"\"\"@. The body is split
-- into a sequence of 'TemplateElement's (literal string chunks and
-- interpolated expressions) by the lexer.
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

-- | One arm of a 'MatchExpression': @pattern -> { body }@.
data CaseArm (phase :: Phase) = CaseArm
  { pattern :: Pattern phase,
    body :: Block phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (CaseArm p) where
  sourceSpanOf arm = arm.sourceSpan

-- | One piece of a 'TemplateExpression' body — either a literal string
-- chunk or an interpolated @${...}@ expression.
data TemplateElement (phase :: Phase) where
  -- | Literal string chunk between interpolations.
  TemplateElementString :: TemplateStringElement p -> TemplateElement p
  -- | Interpolated @${...}@ expression.
  TemplateElementExpression :: TemplateExpressionElement p -> TemplateElement p

instance HasSourceSpan (TemplateElement p) where
  sourceSpanOf = \case
    TemplateElementString element -> element.sourceSpan
    TemplateElementExpression element -> element.sourceSpan

-- | A literal-string chunk inside a 'TemplateExpression'. Carries the raw
-- text (after escape decoding).
data TemplateStringElement (phase :: Phase) = TemplateStringElement
  { value :: Text,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TemplateStringElement p) where
  sourceSpanOf element = element.sourceSpan

-- | An interpolated expression inside a 'TemplateExpression'. The
-- expression's value is coerced to string at runtime.
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
  TypeRecord RecordTypeNode {keyType, valueType, sourceSpan} ->
    TypeRecord
      RecordTypeNode
        { keyType = retagSyntacticType keyType,
          valueType = retagSyntacticType valueType,
          sourceSpan = sourceSpan
        }

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

-- | Phase-level Show aggregate, the Show counterpart of 'EqPhase'. Bundles
-- 'Show' constraints for every 'NameRefResolution' instance and the
-- expression / pattern type families so that standalone-deriving clauses
-- for AST nodes can use a single context name.
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

deriving instance (EqPhase phase) => Eq (RecordTypeNode phase)

deriving instance (ShowPhase phase) => Show (RecordTypeNode phase)

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
