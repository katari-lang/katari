module Katari.Data.AST where

import Data.Kind (Type)
import Data.Map (Map)
import Data.Text (Text)
import GHC.List (List)
import GHC.Stack (HasCallStack)
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.Id (TypeResolution (..), VariableResolution (..))
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.QualifiedName (QualifiedName)
import Katari.Data.SemanticType (SemanticGenericArgument, SemanticType)
import Katari.Data.SourceSpan (HasSourceSpan (..), SourceSpan)
import Katari.Panic (panic)

type data ReferenceKind = VariableReference | TypeReference | ModuleReference | LabelReference

type data Phase = Parsed | Identified | Typed

-- | Identifier resolves references
type family ReferenceResolution (phase :: Phase) (nameReferenceKind :: ReferenceKind) :: Type where
  ReferenceResolution Parsed _ = ()
  ReferenceResolution _ VariableReference = Maybe VariableResolution
  ReferenceResolution _ TypeReference = Maybe TypeResolution
  ReferenceResolution _ ModuleReference = Maybe ModuleName
  ReferenceResolution _ LabelReference = ()

-- | Type container for expression
type family ExpressionType (phase :: Phase) :: Type where
  ExpressionType Parsed = ()
  ExpressionType Identified = ()
  ExpressionType Typed = SemanticType

-- | Type container for pattern
type family PatternType (phase :: Phase) :: Type where
  PatternType Parsed = ()
  PatternType Identified = ()
  PatternType Typed = SemanticType

-- | callee[T, E](...), etc...  The Typed AST carries the inferred generic instantiations.
-- Also carries the explicit @handler[R, E]@ instantiation (keyed by the generic name).
type family GenericInstantiation (phase :: Phase) :: Type where
  GenericInstantiation Parsed = ()
  GenericInstantiation Identified = ()
  GenericInstantiation Typed = Map Text SemanticGenericArgument

-- | The two built-in generic parameter names of a @handler[R, E]@: its result type and its residual
-- effect. The checker keys a handler's 'instantiation' by these; lowering reads them back by the same
-- names, so they are defined here once for both producer and consumer to share.
handlerResultParameterName :: Text
handlerResultParameterName = "R"

handlerEffectParameterName :: Text
handlerEffectParameterName = "E"

data Module (phase :: Phase) = Module
  { declarations :: List (Declaration phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Module phase) where
  sourceSpanOf module' = module'.sourceSpan

data Declaration (phase :: Phase) where
  DeclarationAgent :: AgentDeclaration phase -> Declaration phase
  DeclarationRequest :: RequestDeclaration phase -> Declaration phase
  DeclarationMarkerEffect :: MarkerEffectDeclaration phase -> Declaration phase
  DeclarationImport :: ImportDeclaration -> Declaration phase
  DeclarationExternalAgent :: ExternalAgentDeclaration phase -> Declaration phase
  DeclarationPrimitiveAgent :: PrimitiveAgentDeclaration phase -> Declaration phase
  DeclarationData :: DataDeclaration phase -> Declaration phase
  DeclarationTypeSynonym :: TypeSynonymDeclaration phase -> Declaration phase
  DeclarationError :: SourceSpan -> Declaration phase

instance HasSourceSpan (Declaration phase) where
  sourceSpanOf = \case
    DeclarationAgent declaration -> declaration.sourceSpan
    DeclarationRequest declaration -> declaration.sourceSpan
    DeclarationMarkerEffect declaration -> declaration.sourceSpan
    DeclarationImport declaration -> declaration.sourceSpan
    DeclarationExternalAgent declaration -> declaration.sourceSpan
    DeclarationPrimitiveAgent declaration -> declaration.sourceSpan
    DeclarationData declaration -> declaration.sourceSpan
    DeclarationTypeSynonym declaration -> declaration.sourceSpan
    DeclarationError sourceSpan -> sourceSpan

data Reference (phase :: Phase) (nameReferenceKind :: ReferenceKind) = Reference
  { -- | Reference target's source position
    sourceSpan :: SourceSpan,
    resolution :: ReferenceResolution phase nameReferenceKind
  }

instance HasSourceSpan (Reference phase nameReferenceKind) where
  sourceSpanOf reference = reference.sourceSpan

-- | @module.@ qualifier of a cross-module reference
data ModuleQualifier (phase :: Phase) = ModuleQualifier
  { name :: Text,
    moduleReference :: Reference phase ModuleReference,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ModuleQualifier phase) where
  sourceSpanOf qualifier = qualifier.sourceSpan

-- | A formal generic parameter of an agent / request / external / prim / data /
-- type-synonym declaration.
data GenericParameter (phase :: Phase) = GenericParameter
  { name :: Text,
    labelReference :: Reference phase LabelReference,
    -- | Generic ID
    typeReference :: Reference phase TypeReference,
    kind :: GenericKind,
    -- | @literal name@ — the parameter binds at the argument's most specific literal type: a call
    -- whose argument expression is a string literal proposes the literal's singleton type instead of
    -- @string@. Only meaningful for type-kind parameters; an unmarked generic never binds a singleton
    -- implicitly.
    bindsLiteral :: Bool,
    -- | No upper bound  ~> unknown of private (top type)
    upperBound :: Maybe (SyntacticTypeExpression phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (GenericParameter phase) where
  sourceSpanOf parameter = parameter.sourceSpan

-- | @label => pattern@ — a formal parameter of an agent / request handler.
-- @label : type@ and bare @label@ are parser sugar for a variable bind pattern.
data ParameterBinding (phase :: Phase) = ParameterBinding
  { annotation :: Maybe Text,
    name :: Text,
    labelReference :: Reference phase LabelReference,
    binder :: Binder phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ParameterBinding phase) where
  sourceSpanOf binding = binding.sourceSpan

-- | What a parameter label binds its argument to. Default and destructure are mutually exclusive by
-- construction — there is no "default + rename" form; 'BindVariable' always binds the /label/-named
-- variable. Fields are positional (not a record) to avoid partial field selectors.
data Binder (phase :: Phase)
  = -- | @x@ / @x : T@ / @x ?= v@ — bind the argument to the label-named variable (its reference and
    -- optional type annotation), with the default value substituted when the argument is omitted. A
    -- defaulted parameter is optional at the call site (the runtime fills the default).
    BindVariable (Reference phase VariableReference) (Maybe (SyntacticTypeExpression phase)) (Maybe ParameterDefault)
  | -- | @x => pattern@ — destructure the argument with a pattern (no default).
    BindDestructure (Pattern phase)

-- | @label : type ?= default@ — a formal parameter of a request / external /
-- primitive / data declaration. No pattern, type required.
data ParameterSignature (phase :: Phase) = ParameterSignature
  { annotation :: Maybe Text,
    name :: Text,
    labelReference :: Reference phase LabelReference,
    parameterType :: SyntacticTypeExpression phase,
    defaultValue :: Maybe ParameterDefault,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ParameterSignature phase) where
  sourceSpanOf signature = signature.sourceSpan

data LiteralValue where
  -- Integer literals are machine-width ('Int'), not arbitrary-precision: the value model is a JS
  -- number (an IEEE-754 double) end to end, so the compiler carries no precision the runtime cannot.
  LiteralValueInteger :: Int -> LiteralValue
  LiteralValueNumber :: Double -> LiteralValue
  LiteralValueString :: Text -> LiteralValue
  LiteralValueBoolean :: Bool -> LiteralValue
  LiteralValueNull :: LiteralValue
  deriving stock (Eq, Ord, Show)

-- | @?= literal@
data ParameterDefault = ParameterDefault
  { value :: LiteralValue,
    sourceSpan :: SourceSpan
  }
  deriving stock (Eq, Show)

instance HasSourceSpan ParameterDefault where
  sourceSpanOf parameterDefault = parameterDefault.sourceSpan

-- | @[private] agent name[generics](label => pattern, ...) -> T with E { body }@.
-- @private@ marks the agent's handle private: it may be called only from a private world (the body
-- of another @private@ agent).
data AgentDeclaration (phase :: Phase) = AgentDeclaration
  { annotation :: Maybe Text,
    -- | @private agent@ — handle private (callable only from a private world)
    private :: Bool,
    name :: Text,
    variableReference :: Reference phase VariableReference,
    genericParameters :: List (GenericParameter phase),
    parameters :: List (ParameterBinding phase),
    returnType :: Maybe (SyntacticTypeExpression phase), -- Nothing ~> infer
    effects :: Maybe (SyntacticTypeExpression phase), -- Nothing ~> infer
    body :: Block phase,
    -- | The agent's resolved function type (@agent param -> return with effect@), filled by the checker
    -- at 'Typed' for both top-level and local agents — the single source lowering reads to build the
    -- callable's schema, without re-deriving the inferred return / effect. '()' before typing.
    typeOf :: ExpressionType phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (AgentDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | @request name[generics](label : type ?= default, ...) -> T@
data RequestDeclaration (phase :: Phase) = RequestDeclaration
  { annotation :: Maybe Text,
    name :: Text,
    -- | As callable
    variableReference :: Reference phase VariableReference,
    -- | As effect
    typeReference :: Reference phase TypeReference,
    genericParameters :: List (GenericParameter phase),
    parameters :: List (ParameterSignature phase),
    returnType :: SyntacticTypeExpression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RequestDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | @effect name[generics]@ — a marker effect: a pure type-level capability with NO operations. It
-- occupies only the type namespace (there is no value to perform, so it is unperformable by
-- construction), appears in effect rows exactly like a request reference, is rejected as a handler
-- clause, and vanishes at lowering. Signatures use it to introduce and discharge scope-capability
-- rows (@with E | name[T]@ on a parameter, absent from the result row).
data MarkerEffectDeclaration (phase :: Phase) = MarkerEffectDeclaration
  { annotation :: Maybe Text,
    name :: Text,
    -- | As effect (the only namespace a marker populates)
    typeReference :: Reference phase TypeReference,
    genericParameters :: List (GenericParameter phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (MarkerEffectDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | @import { ... } from "module"@ / @import "module" as alias@.
-- Phase-independent: resolved names live in scope tables, not on the node.
data ImportDeclaration = ImportDeclaration
  { kind :: ImportKind,
    sourceSpan :: SourceSpan
  }
  deriving stock (Eq, Show)

instance HasSourceSpan ImportDeclaration where
  sourceSpanOf declaration = declaration.sourceSpan

data ImportKind where
  -- | @import { ... } from "module"@
  ImportNames :: NamesImport -> ImportKind
  -- | @import "module" [as alias]@
  ImportModule :: ModuleImport -> ImportKind
  deriving stock (Eq, Show)

data NamesImport = NamesImport
  { items :: List ImportItem,
    moduleName :: ModuleName
  }
  deriving stock (Eq, Show)

data ModuleImport = ModuleImport
  { moduleName :: ModuleName,
    alias :: Maybe Text -- Nothing ~> prefix import  ex) import "foo.bar"  ~> bar.agent_name
  }
  deriving stock (Eq, Show)

data ImportItem = ImportItem
  { kind :: ImportItemKind,
    name :: Text,
    -- | Span of the imported name itself (the defining handle for go-to-definition / find-references).
    sourceSpan :: SourceSpan
  }
  deriving stock (Eq, Show)

instance HasSourceSpan ImportItem where
  sourceSpanOf item = item.sourceSpan

-- | Namespace of an import item; @type@ prefix selects the type namespace.
data ImportItemKind = ImportItemValue | ImportItemType
  deriving stock (Eq, Show)

-- | @external agent name[generics](label : type ?= default, ...) -> T with E@.
-- The declaration name is the sole handle; there is no separate endpoint / dispatch name.
data ExternalAgentDeclaration (phase :: Phase) = ExternalAgentDeclaration
  { annotation :: Maybe Text,
    name :: Text,
    variableReference :: Reference phase VariableReference,
    genericParameters :: List (GenericParameter phase),
    parameters :: List (ParameterSignature phase),
    returnType :: SyntacticTypeExpression phase,
    effects :: Maybe (SyntacticTypeExpression phase), -- Nothing ~> capture

    -- | The reactor the call routes to, from a @from "name"@ clause (e.g. @from "http"@). 'Nothing'
    -- defaults to the FFI sidecar; the runtime routes an external @delegate@ to the named reactor.
    reactor :: Maybe Text,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ExternalAgentDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | @primitive agent name[generics](label : type ?= default, ...) -> T with E@.
-- Prim-specific typing (numeric join, element-type propagation, taint) is expressed
-- through generics / attributes, so there is no @using@ rule escape hatch.
--
-- Structurally identical to 'ExternalAgentDeclaration' today, but kept a distinct type on purpose:
-- the two are different concepts (a primitive is compiler-provided; an external is a runtime-provided
-- endpoint), their @effects = Nothing@ default differs (pure vs capture), and they lower differently.
-- The field coincidence is not meaningful, so they are not merged behind a shared tag.
data PrimitiveAgentDeclaration (phase :: Phase) = PrimitiveAgentDeclaration
  { annotation :: Maybe Text,
    name :: Text,
    variableReference :: Reference phase VariableReference,
    genericParameters :: List (GenericParameter phase),
    parameters :: List (ParameterSignature phase),
    returnType :: SyntacticTypeExpression phase,
    effects :: Maybe (SyntacticTypeExpression phase), -- Nothing ~> pure
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (PrimitiveAgentDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | @data name[generics](label : type ?= default, ...)@
data DataDeclaration (phase :: Phase) = DataDeclaration
  { annotation :: Maybe Text,
    name :: Text,
    -- | As constructor
    variableReference :: Reference phase VariableReference,
    -- | As type
    typeReference :: Reference phase TypeReference,
    genericParameters :: List (GenericParameter phase),
    parameters :: List (ParameterSignature phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (DataDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | @type name[generics] = T@. Generic synonyms expand structurally; the checker
-- rejects (mutually) recursive synonym references, so expansion always terminates.
data TypeSynonymDeclaration (phase :: Phase) = TypeSynonymDeclaration
  { name :: Text,
    typeReference :: Reference phase TypeReference,
    genericParameters :: List (GenericParameter phase),
    definition :: SyntacticTypeExpression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeSynonymDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

---------------------------------------------------------------------------------------------------------------
-- Statements
---------------------------------------------------------------------------------------------------------------

-- | A list of statements plus an optional trailing expression (the block's value).
data Block (phase :: Phase) = Block
  { statements :: List (Statement phase),
    returnExpression :: Maybe (Expression phase), -- Nothing ~> null
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Block phase) where
  sourceSpanOf block = block.sourceSpan

data Statement (phase :: Phase) where
  -- | @let pattern = expression@
  StatementLet :: LetStatement phase -> Statement phase
  -- | @[let pattern =] use provider@ — a @let@-like statement (see 'UseStatement')
  StatementUse :: UseStatement phase -> Statement phase
  -- | Locally-bound agent (closure over the enclosing scope)
  StatementAgent :: AgentDeclaration phase -> Statement phase
  -- | @return expression@
  StatementReturn :: ReturnStatement phase -> Statement phase
  -- | Bare expression
  StatementExpression :: Expression phase -> Statement phase
  -- | @next v [with ...]@ inside a request handler
  StatementNext :: NextStatement phase -> Statement phase
  -- | @break v@ inside a request handler
  StatementBreak :: BreakStatement phase -> Statement phase
  -- | @next [v] [with ...]@ inside a @for@ body
  StatementForNext :: ForNextStatement phase -> Statement phase
  -- | @break v@ inside a @for@ body
  StatementForBreak :: ForBreakStatement phase -> Statement phase
  -- | @finally { ... }@ — arm the block as a finalizer of the current agent instance (see
  -- 'FinallyStatement'). A statement, not an expression: it yields no value, only the arming effect.
  StatementFinally :: FinallyStatement phase -> Statement phase
  -- | Reserved sentinel for statement-level recovery. The parser does not emit it yet (it recovers
  -- only at declaration boundaries), but downstream walkers transport it so the slot exists already.
  StatementError :: SourceSpan -> Statement phase

instance HasSourceSpan (Statement phase) where
  sourceSpanOf = \case
    StatementLet statement -> statement.sourceSpan
    StatementUse statement -> statement.sourceSpan
    StatementAgent statement -> statement.sourceSpan
    StatementReturn statement -> statement.sourceSpan
    StatementExpression expression -> sourceSpanOf expression
    StatementNext statement -> statement.sourceSpan
    StatementBreak statement -> statement.sourceSpan
    StatementForNext statement -> statement.sourceSpan
    StatementForBreak statement -> statement.sourceSpan
    StatementFinally statement -> statement.sourceSpan
    StatementError sourceSpan -> sourceSpan

data LetStatement (phase :: Phase) = LetStatement
  { pattern :: Pattern phase,
    value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (LetStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

-- | @[let pattern =] use provider@ — a @let@-like statement that applies @provider@
-- (a handler provider) to the rest of the enclosing block, captured as @body@ (the
-- continuation). @{ use e }@ desugars to @{ let _ = use e; null }@.
data UseStatement (phase :: Phase) = UseStatement
  { binder :: Maybe (Pattern phase),
    provider :: Expression phase,
    body :: Block phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (UseStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

data ReturnStatement (phase :: Phase) = ReturnStatement
  { value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ReturnStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

data NextStatement (phase :: Phase) = NextStatement
  { value :: Expression phase,
    modifiers :: List (Modifier phase), -- No modifiers ~> []
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
  { value :: Expression phase,
    modifiers :: List (Modifier phase), -- No modifiers ~> []
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

-- | @finally { body }@ — arm @body@ as a finalizer of the current agent instance. Armed finalizers
-- run in reverse arming order right before the instance acknowledges its terminal (a normal
-- completion or a cancellation), and never on a panic. The body reads the enclosing scope through
-- the ordinary parent chain, so it takes no parameters; its net effect must be within @io@ (a
-- finalizer runs while the parent may already await the instance's cancellation, so it must not
-- escalate a request through that parent).
data FinallyStatement (phase :: Phase) = FinallyStatement
  { body :: Block phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (FinallyStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

-- | One @name = expression@ entry in a @with (...)@ list of @next@
data Modifier (phase :: Phase) = Modifier
  { name :: Text,
    variableReference :: Reference phase VariableReference,
    value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Modifier phase) where
  sourceSpanOf modifier = modifier.sourceSpan

-- | @var name [: T] = initial@ — mutable state of a @for@ / @handler@
data VariableBinding (phase :: Phase) = VariableBinding
  { name :: Text,
    variableReference :: Reference phase VariableReference,
    typeAnnotation :: Maybe (SyntacticTypeExpression phase),
    initial :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (VariableBinding phase) where
  sourceSpanOf binding = binding.sourceSpan

-- | @then (pattern) { body }@ of a @for@ / @handler@
data ThenClause (phase :: Phase) = ThenClause
  { binder :: Maybe (Pattern phase),
    body :: Block phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ThenClause phase) where
  sourceSpanOf clause = clause.sourceSpan

---------------------------------------------------------------------------------------------------------------
-- Handlers
---------------------------------------------------------------------------------------------------------------

-- | @[par] handler[R, E](var s = init, ...) { request foo(...) { ... } ... } then (pattern) { body }@.
-- An anonymous handler-provider agent, generic over the continuation's return type
-- and residual effect. @genericArguments@ holds the explicit @[R, E]@ written by the
-- user (empty when omitted); @instantiation@ is the substitution the checker resolves
-- (keyed by the generic name, e.g. @\"R\"@ / @\"E\"@).
data HandlerExpression (phase :: Phase) = HandlerExpression
  { parallel :: Bool,
    genericArguments :: List (SyntacticTypeExpression phase),
    instantiation :: GenericInstantiation phase,
    stateVariables :: List (VariableBinding phase),
    handlers :: List (RequestHandler phase),
    thenClause :: Maybe (ThenClause phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (HandlerExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | @request [module.]name[generics](label => pattern, ...) [-> T] { body }@ inside a handler
data RequestHandler (phase :: Phase) = RequestHandler
  { moduleQualifier :: Maybe (ModuleQualifier phase),
    name :: Text,
    typeReference :: Reference phase TypeReference,
    genericArguments :: List (SyntacticTypeExpression phase),
    -- | The resolved substitution (declared generic -> argument), filled by the checker at
    -- 'Typed' so lowering need not re-derive it
    instantiation :: GenericInstantiation phase,
    parameters :: List (ParameterBinding phase),
    returnType :: Maybe (SyntacticTypeExpression phase),
    body :: Block phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RequestHandler phase) where
  sourceSpanOf handler = handler.sourceSpan

---------------------------------------------------------------------------------------------------------------
-- Patterns
---------------------------------------------------------------------------------------------------------------

data Pattern (phase :: Phase) where
  -- | @name [: T] [?= default]@
  PatternVariable :: VariablePattern phase -> Pattern phase
  -- | @[module.]name[generics](label => pattern, ...)@
  PatternConstructor :: ConstructorPattern phase -> Pattern phase
  -- | @(p1, p2, ...)@
  PatternTuple :: TuplePattern phase -> Pattern phase
  -- | @_ [: T]@
  PatternWildcard :: WildcardPattern phase -> Pattern phase
  -- | @42@ / @"foo"@ / @true@ / @null@ — refutable
  PatternLiteral :: LiteralPattern phase -> Pattern phase
  -- | @T(pattern)@ — runtime type filter, narrows the subject to @T@
  PatternTypeFilter :: TypeFilterPattern phase -> Pattern phase
  -- | @{ label => pattern, ... }@ — subset match against a record value
  PatternRecord :: RecordPattern phase -> Pattern phase

instance HasSourceSpan (Pattern phase) where
  sourceSpanOf = \case
    PatternVariable pattern' -> pattern'.sourceSpan
    PatternConstructor pattern' -> pattern'.sourceSpan
    PatternTuple pattern' -> pattern'.sourceSpan
    PatternWildcard pattern' -> pattern'.sourceSpan
    PatternLiteral pattern' -> pattern'.sourceSpan
    PatternTypeFilter pattern' -> pattern'.sourceSpan
    PatternRecord pattern' -> pattern'.sourceSpan

data VariablePattern (phase :: Phase) = VariablePattern
  { name :: Text,
    variableReference :: Reference phase VariableReference,
    typeAnnotation :: Maybe (SyntacticTypeExpression phase),
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (VariablePattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data ConstructorPattern (phase :: Phase) = ConstructorPattern
  { moduleQualifier :: Maybe (ModuleQualifier phase),
    name :: Text,
    constructorReference :: Reference phase VariableReference,
    genericArguments :: List (SyntacticTypeExpression phase),
    -- | The resolved substitution (declared generic -> argument), filled by the checker at
    -- 'Typed' so narrowing / lowering need not re-derive it
    instantiation :: GenericInstantiation phase,
    fields :: List (FieldPattern phase),
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (ConstructorPattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

-- | @label => pattern@ inside a constructor / record pattern
data FieldPattern (phase :: Phase) = FieldPattern
  { name :: Text,
    labelReference :: Reference phase LabelReference,
    bindPattern :: Pattern phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (FieldPattern phase) where
  sourceSpanOf field = field.sourceSpan

data TuplePattern (phase :: Phase) = TuplePattern
  { elements :: List (Pattern phase),
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (TuplePattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data WildcardPattern (phase :: Phase) = WildcardPattern
  { typeAnnotation :: Maybe (SyntacticTypeExpression phase),
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (WildcardPattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data LiteralPattern (phase :: Phase) = LiteralPattern
  { value :: LiteralValue,
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (LiteralPattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

-- | The runtime-discriminable type a type-filter pattern @T(p)@ matches on: a fixed enumeration (not an
-- arbitrary type expression), because matching is by runtime tag — a primitive, or any array / record /
-- agent. The inner pattern is then matched against the value /extracted from the scrutinee/ at that tag.
data TypeFilter
  = FilterNull
  | FilterBoolean
  | FilterInteger
  | FilterNumber
  | FilterString
  | FilterFile
  | FilterArray
  | FilterRecord
  | FilterAgent
  deriving stock (Eq, Show)

-- | @T(pattern)@ — a runtime type filter that narrows the subject to @T@
data TypeFilterPattern (phase :: Phase) = TypeFilterPattern
  { matchedType :: TypeFilter,
    inner :: Pattern phase,
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (TypeFilterPattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data RecordPattern (phase :: Phase) = RecordPattern
  { fields :: List (FieldPattern phase),
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (RecordPattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

---------------------------------------------------------------------------------------------------------------
-- Type-level syntax (types, effects, attributes)
--
-- One kind-agnostic syntax tree for everything that appears in a type position:
-- ordinary types, @with@-clause effects, and @of@ attributes.
-- All three kinds share 'SyntacticTypeExpression' and the
-- checker splits them by kind. (Because parsers don't know the kind of a type)
---------------------------------------------------------------------------------------------------------------

data SyntacticTypeExpression (phase :: Phase) where
  -- | @null@ / @integer@ / @number@ / @string@ / @boolean@ / @file@
  TypePrimitive :: PrimitiveTypeNode -> SyntacticTypeExpression phase
  -- | @"x"@ — a string literal singleton type (exactly this string; a subtype of @string@)
  TypeStringLiteral :: StringLiteralTypeNode -> SyntacticTypeExpression phase
  -- | @never@ — the type bottom
  TypeNever :: SourceSpan -> SyntacticTypeExpression phase
  -- | @unknown@ — the type top
  TypeUnknown :: SourceSpan -> SyntacticTypeExpression phase
  -- | @all@ — the effect top
  TypeAll :: SourceSpan -> SyntacticTypeExpression phase
  -- | @io@ — the effect of performing external (FFI) calls
  TypeIo :: SourceSpan -> SyntacticTypeExpression phase
  -- | @pure@ — the empty effect (no requests, no io); the effect bottom
  TypePure :: SourceSpan -> SyntacticTypeExpression phase
  -- | @[module.]name@ — a type / generic / effect / attribute name (kind resolved by
  -- the checker). With arguments it heads a 'TypeApplication'.
  TypeName :: TypeNameNode phase -> SyntacticTypeExpression phase
  -- | @agent T -> R [with E]@. The parenthesised parameter list
  -- @agent (label : T, ...) -> R@ is parser sugar for an object parameter type.
  TypeAgent :: AgentTypeNode phase -> SyntacticTypeExpression phase
  -- | The @array@ type constructor; always the head of a 'TypeApplication'
  TypeArray :: SourceSpan -> SyntacticTypeExpression phase
  -- | The @record@ type; bare = homogeneous-map top, @record[V]@ via 'TypeApplication'
  TypeRecord :: SourceSpan -> SyntacticTypeExpression phase
  -- | @head[argument, ...]@
  TypeApplication :: TypeApplicationTypeNode phase -> SyntacticTypeExpression phase
  -- | @(T1, T2, ...)@
  TypeTuple :: TupleTypeNode phase -> SyntacticTypeExpression phase
  -- | @T1 | T2 | ...@ — 2 or more branches, order preserving. Kind-agnostic: a union
  -- of types, of effects, or of attributes; the checker decides which.
  TypeUnion :: TypeUnionNode phase -> SyntacticTypeExpression phase
  -- | @{label : T, label ?: T, ...}@
  TypeObject :: ObjectTypeNode phase -> SyntacticTypeExpression phase
  -- | @T of A@
  TypeAttributed :: AttributedTypeNode phase -> SyntacticTypeExpression phase
  -- | @public@ / @private@ — an attribute literal (kind-checked)
  TypeAttributeLiteral :: AttributeLiteralNode -> SyntacticTypeExpression phase
  -- | @{...E, request[arguments], ...}@ — an effect that shadows requests of its base
  TypeOverride :: OverrideTypeNode phase -> SyntacticTypeExpression phase

instance HasSourceSpan (SyntacticTypeExpression phase) where
  sourceSpanOf = \case
    TypePrimitive node -> node.sourceSpan
    TypeStringLiteral node -> node.sourceSpan
    TypeNever sourceSpan -> sourceSpan
    TypeUnknown sourceSpan -> sourceSpan
    TypeAll sourceSpan -> sourceSpan
    TypeIo sourceSpan -> sourceSpan
    TypePure sourceSpan -> sourceSpan
    TypeName node -> node.sourceSpan
    TypeAgent node -> node.sourceSpan
    TypeArray sourceSpan -> sourceSpan
    TypeRecord sourceSpan -> sourceSpan
    TypeApplication node -> node.sourceSpan
    TypeTuple node -> node.sourceSpan
    TypeUnion node -> node.sourceSpan
    TypeObject node -> node.sourceSpan
    TypeAttributed node -> node.sourceSpan
    TypeAttributeLiteral node -> node.sourceSpan
    TypeOverride node -> node.sourceSpan

data PrimitiveTypeKind
  = PrimitiveTypeKindNull
  | PrimitiveTypeKindInteger
  | PrimitiveTypeKindNumber
  | PrimitiveTypeKindString
  | PrimitiveTypeKindBoolean
  | PrimitiveTypeKindFile
  deriving stock (Eq, Show)

data PrimitiveTypeNode = PrimitiveTypeNode
  { kind :: PrimitiveTypeKind,
    sourceSpan :: SourceSpan
  }
  deriving stock (Eq, Show)

instance HasSourceSpan PrimitiveTypeNode where
  sourceSpanOf node = node.sourceSpan

-- | @"x"@ in type position. Escaping follows expression string literals exactly (the parser reuses
-- the lexer's string body), so a value literal and its singleton type are always spelled the same.
data StringLiteralTypeNode = StringLiteralTypeNode
  { value :: Text,
    sourceSpan :: SourceSpan
  }
  deriving stock (Eq, Show)

instance HasSourceSpan StringLiteralTypeNode where
  sourceSpanOf node = node.sourceSpan

-- | @[module.]name@ — a kind-agnostic name reference. @moduleQualifier@ is the
-- optional @module.@ prefix (cross-module reference).
data TypeNameNode (phase :: Phase) = TypeNameNode
  { moduleQualifier :: Maybe (ModuleQualifier phase),
    name :: Text,
    typeReference :: Reference phase TypeReference,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeNameNode phase) where
  sourceSpanOf node = node.sourceSpan

-- | @agent T -> R [with E]@. No @with@ clause ~> pure.
data AgentTypeNode (phase :: Phase) = AgentTypeNode
  { parameterType :: SyntacticTypeExpression phase,
    returnType :: SyntacticTypeExpression phase,
    effects :: Maybe (SyntacticTypeExpression phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (AgentTypeNode phase) where
  sourceSpanOf node = node.sourceSpan

-- | @head[argument, ...]@. Arguments are parsed uniformly as type-level syntax; the
-- checker splits them into type / effect / attribute arguments by the head's
-- generic-parameter kinds.
data TypeApplicationTypeNode (phase :: Phase) = TypeApplicationTypeNode
  { applicationHead :: SyntacticTypeExpression phase,
    applicationArguments :: List (SyntacticTypeExpression phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeApplicationTypeNode phase) where
  sourceSpanOf node = node.sourceSpan

data TupleTypeNode (phase :: Phase) = TupleTypeNode
  { elementTypes :: List (SyntacticTypeExpression phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TupleTypeNode phase) where
  sourceSpanOf node = node.sourceSpan

data TypeUnionNode (phase :: Phase) = TypeUnionNode
  { branches :: List (SyntacticTypeExpression phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeUnionNode phase) where
  sourceSpanOf node = node.sourceSpan

data ObjectTypeNode (phase :: Phase) = ObjectTypeNode
  { fields :: List (ObjectTypeField phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ObjectTypeNode phase) where
  sourceSpanOf node = node.sourceSpan

-- | @label : T@ / @label ?: T@ (optional ~> the field may be absent)
data ObjectTypeField (phase :: Phase) = ObjectTypeField
  { name :: Text,
    fieldType :: SyntacticTypeExpression phase,
    optional :: Bool,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ObjectTypeField phase) where
  sourceSpanOf field = field.sourceSpan

-- | @T of A@ — the attribute side is kind-checked to be an attribute
data AttributedTypeNode (phase :: Phase) = AttributedTypeNode
  { baseType :: SyntacticTypeExpression phase,
    attribute :: SyntacticTypeExpression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (AttributedTypeNode phase) where
  sourceSpanOf node = node.sourceSpan

data AttributeLiteralKind = AttributeLiteralPublic | AttributeLiteralPrivate
  deriving stock (Eq, Show)

data AttributeLiteralNode = AttributeLiteralNode
  { kind :: AttributeLiteralKind,
    sourceSpan :: SourceSpan
  }
  deriving stock (Eq, Show)

instance HasSourceSpan AttributeLiteralNode where
  sourceSpanOf node = node.sourceSpan

-- | @{...E, request[arguments], ...}@ — each override is named-effect syntax (a
-- 'TypeName' or 'TypeApplication') that shadows the matching request of @base@.
data OverrideTypeNode (phase :: Phase) = OverrideTypeNode
  { base :: SyntacticTypeExpression phase,
    overrides :: List (SyntacticTypeExpression phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (OverrideTypeNode phase) where
  sourceSpanOf node = node.sourceSpan

---------------------------------------------------------------------------------------------------------------
-- Expressions
---------------------------------------------------------------------------------------------------------------

data Expression (phase :: Phase) where
  -- | @42@ / @"foo"@ / @true@ / @null@ / ...
  ExpressionLiteral :: LiteralExpression phase -> Expression phase
  -- | Bare identifier
  ExpressionVariable :: VariableExpression phase -> Expression phase
  -- | @[e1, e2, ...]@ (sequential) / @parallel [e1, e2, ...]@ (concurrent, results in order)
  ExpressionTuple :: TupleExpression phase -> Expression phase
  -- | @{ label = e, ... }@
  ExpressionRecord :: RecordExpression phase -> Expression phase
  -- | @callee(label = e, ...)@
  ExpressionCall :: CallExpression phase -> Expression phase
  -- | @e1 op e2@
  ExpressionBinaryOperator :: BinaryOperatorExpression phase -> Expression phase
  -- | @op e@
  ExpressionUnaryOperator :: UnaryOperatorExpression phase -> Expression phase
  -- | @if condition { ... } else { ... }@
  ExpressionIf :: IfExpression phase -> Expression phase
  -- | @match subject { case pattern -> body ... }@
  ExpressionMatch :: MatchExpression phase -> Expression phase
  -- | @[par] for (...) { body } then (pattern) { ... }@
  ExpressionFor :: ForExpression phase -> Expression phase
  -- | @forever { body }@ — repeat the block indefinitely; the expression types as @never@
  ExpressionForever :: ForeverExpression phase -> Expression phase
  -- | Standalone @{ ... }@ in expression position
  ExpressionBlock :: BlockExpression phase -> Expression phase
  -- | @object.field@
  ExpressionFieldAccess :: FieldAccessExpression phase -> Expression phase
  -- | @callee[T, E, ...]@ — generic instantiation
  ExpressionTypeApplication :: TypeApplicationExpression phase -> Expression phase
  -- | @f"..."@ template literal
  ExpressionTemplate :: TemplateExpression phase -> Expression phase
  -- | First-class handler provider
  ExpressionHandler :: HandlerExpression phase -> Expression phase
  -- | @module.target@ — synthesised by the Identifier from a field-access chain
  -- whose left-most segment resolves to a module; never produced by the parser
  ExpressionQualifiedReference :: QualifiedReferenceExpression phase -> Expression phase

instance HasSourceSpan (Expression phase) where
  sourceSpanOf = \case
    ExpressionLiteral expression -> expression.sourceSpan
    ExpressionVariable expression -> expression.sourceSpan
    ExpressionTuple expression -> expression.sourceSpan
    ExpressionRecord expression -> expression.sourceSpan
    ExpressionCall expression -> expression.sourceSpan
    ExpressionBinaryOperator expression -> expression.sourceSpan
    ExpressionUnaryOperator expression -> expression.sourceSpan
    ExpressionIf expression -> expression.sourceSpan
    ExpressionMatch expression -> expression.sourceSpan
    ExpressionFor expression -> expression.sourceSpan
    ExpressionForever expression -> expression.sourceSpan
    ExpressionBlock expression -> expression.sourceSpan
    ExpressionFieldAccess expression -> expression.sourceSpan
    ExpressionTypeApplication expression -> expression.sourceSpan
    ExpressionTemplate expression -> expression.sourceSpan
    ExpressionHandler expression -> expression.sourceSpan
    ExpressionQualifiedReference expression -> expression.sourceSpan

data LiteralExpression (phase :: Phase) = LiteralExpression
  { value :: LiteralValue,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (LiteralExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data VariableExpression (phase :: Phase) = VariableExpression
  { name :: Text,
    variableReference :: Reference phase VariableReference,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (VariableExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | @[e1, e2, ...]@ (sequential) / @parallel [e1, e2, ...]@ (concurrent). @parallel@
-- evaluates the elements concurrently; results are collected in source order either way.
data TupleExpression (phase :: Phase) = TupleExpression
  { parallel :: Bool,
    elements :: List (Expression phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (TupleExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data RecordExpression (phase :: Phase) = RecordExpression
  { entries :: List (RecordEntry phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (RecordExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | @label = value@ in a record literal. The key is a value on the wire, not a reference to a
-- declaration, so it carries no resolution — only its own span, for key-level diagnostics.
data RecordEntry (phase :: Phase) = RecordEntry
  { name :: Text,
    value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RecordEntry phase) where
  sourceSpanOf entry = entry.sourceSpan

-- | Arguments are keyword-labelled; source order is preserved
data CallExpression (phase :: Phase) = CallExpression
  { callee :: Expression phase,
    arguments :: List (CallArgument phase),
    -- | The generic substitution this call instantiates the callee with — INFERRED from the arguments
    -- when the callee is an unapplied generic (an explicit @callee[T](...)@ instantiates through
    -- 'TypeApplicationExpression' instead, leaving this empty). Filled by the checker at 'Typed' so
    -- lowering can stamp the runtime schemas onto the delegate — the runtime needs them to validate
    -- against, and to fill, the callee's @$generic@ schema placeholders.
    instantiation :: GenericInstantiation phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (CallExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | @label = value@ / @label = _@ in a call argument list
data CallArgument (phase :: Phase) = CallArgument
  { name :: Text,
    labelReference :: Reference phase LabelReference,
    value :: CallArgumentValue phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (CallArgument phase) where
  sourceSpanOf argument = argument.sourceSpan

-- | A call argument's payload: an ordinary expression, or a lone @_@ hole marking the parameter a
-- partial application leaves open (@f(x = _, y = e)@ evaluates @e@ now and yields the residual
-- @agent (x: X) -> R@). A hole is deliberately NOT an 'Expression' — it exists only in argument
-- position, so every expression walker stays hole-free by construction.
data CallArgumentValue (phase :: Phase) where
  ArgumentHole :: SourceSpan -> CallArgumentValue phase
  ArgumentExpression :: Expression phase -> CallArgumentValue phase

instance HasSourceSpan (CallArgumentValue phase) where
  sourceSpanOf = \case
    ArgumentHole sourceSpan -> sourceSpan
    ArgumentExpression expression -> sourceSpanOf expression

-- | The @label = _@ holes of a call's arguments, in written order. Empty for an ordinary call; any
-- entry makes the call a partial application. Shared by the checker (which types the residual
-- function) and lowering (which emits a closure instead of a delegate), so the two dispatch on the
-- same notion of "has holes".
callArgumentHoles :: List (CallArgument phase) -> List (Text, SourceSpan)
callArgumentHoles arguments =
  [(argument.name, holeSpan) | argument <- arguments, ArgumentHole holeSpan <- [argument.value]]

data BinaryOperator
  = BinaryOperatorAdd
  | BinaryOperatorSubtract
  | BinaryOperatorMultiply
  | BinaryOperatorDivide
  | BinaryOperatorModulo
  | BinaryOperatorEqual
  | BinaryOperatorNotEqual
  | BinaryOperatorLessThan
  | BinaryOperatorLessOrEqual
  | BinaryOperatorGreaterThan
  | BinaryOperatorGreaterOrEqual
  | BinaryOperatorAnd
  | BinaryOperatorOr
  | BinaryOperatorConcat
  deriving stock (Eq, Show, Bounded, Enum)

data UnaryOperator = UnaryOperatorNegate | UnaryOperatorNot
  deriving stock (Eq, Show, Bounded, Enum)

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

-- | No @else@ ~> the expression's type is @null | thenType@
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
    cases :: List (CaseArm phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (MatchExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | @case pattern -> body@
data CaseArm (phase :: Phase) = CaseArm
  { pattern :: Pattern phase,
    body :: Block phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (CaseArm phase) where
  sourceSpanOf arm = arm.sourceSpan

-- | @[par] for (pattern in source; var x = init; ...) { body } [then (pattern) { ... }]@.
-- A single @pattern in source@ binding drives the loop. Each @next@ value becomes an
-- element of the loop's mapped output array; the optional @then@ clause receives it.
data ForExpression (phase :: Phase) = ForExpression
  { parallel :: Bool,
    inBinding :: ForInBinding phase,
    varBindings :: List (VariableBinding phase),
    body :: Block phase,
    thenClause :: Maybe (ThenClause phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (ForExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | @forever { body }@ — the unbounded sibling of the sequential @for@: repeat @body@ indefinitely, one
-- iteration at a time, discarding each iteration's value (nothing is collected — the point of the form is
-- that a long-lived loop accumulates no state). The expression never yields a value, so it types as
-- @never@. There is deliberately no built-in exit and no jump target of its own: escaping is composed with
-- the existing catch-and-break mechanism (a surrounding handler whose request handler @break@s), exactly
-- like throw handling.
data ForeverExpression (phase :: Phase) = ForeverExpression
  { body :: Block phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (ForeverExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | @pattern in source@
data ForInBinding (phase :: Phase) = ForInBinding
  { pattern :: Pattern phase,
    source :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ForInBinding phase) where
  sourceSpanOf binding = binding.sourceSpan

data BlockExpression (phase :: Phase) = BlockExpression
  { block :: Block phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (BlockExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | Field labels resolve type-directed (by the typechecker)
data FieldAccessExpression (phase :: Phase) = FieldAccessExpression
  { object :: Expression phase,
    fieldName :: Text,
    labelReference :: Reference phase LabelReference,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (FieldAccessExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | Bracket arguments parse uniformly as type-level syntax; the typechecker splits
-- them by the callee's generic-parameter kinds and records the result in 'instantiation'.
data TypeApplicationExpression (phase :: Phase) = TypeApplicationExpression
  { callee :: Expression phase,
    typeArguments :: List (SyntacticTypeExpression phase),
    instantiation :: GenericInstantiation phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (TypeApplicationExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data TemplateExpression (phase :: Phase) = TemplateExpression
  { elements :: List (TemplateElement phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (TemplateExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data TemplateElement (phase :: Phase) where
  -- | Literal string chunk between interpolations
  TemplateElementString :: TemplateStringElement -> TemplateElement phase
  -- | Interpolated @${...}@ expression
  TemplateElementExpression :: TemplateExpressionElement phase -> TemplateElement phase

instance HasSourceSpan (TemplateElement phase) where
  sourceSpanOf = \case
    TemplateElementString element -> element.sourceSpan
    TemplateElementExpression element -> element.sourceSpan

data TemplateStringElement = TemplateStringElement
  { value :: Text,
    sourceSpan :: SourceSpan
  }
  deriving stock (Eq, Show)

instance HasSourceSpan TemplateStringElement where
  sourceSpanOf element = element.sourceSpan

data TemplateExpressionElement (phase :: Phase) = TemplateExpressionElement
  { value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TemplateExpressionElement phase) where
  sourceSpanOf element = element.sourceSpan

data QualifiedReferenceExpression (phase :: Phase) = QualifiedReferenceExpression
  { moduleQualifier :: ModuleQualifier phase,
    name :: Text,
    variableReference :: Reference phase VariableReference,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (QualifiedReferenceExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

---------------------------------------------------------------------------------------------------------------
-- Resolved identity
--
-- A top-level declaration's own reference is resolved by the identifier to the declaration's
-- module-qualified name, so post-identifier phases read identity from the reference rather than
-- rebuilding it from the declaration's name text. An unresolved own reference is a compiler bug.
---------------------------------------------------------------------------------------------------------------

referencedVariableName :: (HasCallStack) => Reference Identified VariableReference -> QualifiedName
referencedVariableName reference = case reference.resolution of
  Just (VariableResolutionQualifiedName qualifiedName) -> qualifiedName
  _ -> panic "referencedVariableName: declaration variable reference is not resolved to a qualified name"

referencedTypeName :: (HasCallStack) => Reference Identified TypeReference -> QualifiedName
referencedTypeName reference = case reference.resolution of
  Just (TypeResolutionQualifiedName qualifiedName) -> qualifiedName
  _ -> panic "referencedTypeName: declaration type reference is not resolved to a qualified name"

---------------------------------------------------------------------------------------------------------------
-- Phase retagging helpers
--
-- Identity transports between phases whose 'ReferenceResolution' agree
-- (Identified / Typed). Nodes carrying a phase-specific @typeOf@ or @instantiation@
-- are rebuilt by each walker instead.
---------------------------------------------------------------------------------------------------------------

retagReference ::
  (ReferenceResolution phase1 nameReferenceKind ~ ReferenceResolution phase2 nameReferenceKind) =>
  Reference phase1 nameReferenceKind ->
  Reference phase2 nameReferenceKind
retagReference reference =
  Reference
    { sourceSpan = reference.sourceSpan,
      resolution = reference.resolution
    }

retagModuleQualifier ::
  (ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference) =>
  ModuleQualifier phase1 ->
  ModuleQualifier phase2
retagModuleQualifier qualifier =
  ModuleQualifier
    { name = qualifier.name,
      moduleReference = retagReference qualifier.moduleReference,
      sourceSpan = qualifier.sourceSpan
    }

retagSyntacticTypeExpression ::
  ( ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference
  ) =>
  SyntacticTypeExpression phase1 ->
  SyntacticTypeExpression phase2
retagSyntacticTypeExpression = \case
  TypePrimitive node -> TypePrimitive node
  TypeStringLiteral node -> TypeStringLiteral node
  TypeNever sourceSpan -> TypeNever sourceSpan
  TypeUnknown sourceSpan -> TypeUnknown sourceSpan
  TypeAll sourceSpan -> TypeAll sourceSpan
  TypeIo sourceSpan -> TypeIo sourceSpan
  TypePure sourceSpan -> TypePure sourceSpan
  TypeName node ->
    TypeName
      TypeNameNode
        { moduleQualifier = retagModuleQualifier <$> node.moduleQualifier,
          name = node.name,
          typeReference = retagReference node.typeReference,
          sourceSpan = node.sourceSpan
        }
  TypeAgent node ->
    TypeAgent
      AgentTypeNode
        { parameterType = retagSyntacticTypeExpression node.parameterType,
          returnType = retagSyntacticTypeExpression node.returnType,
          effects = retagSyntacticTypeExpression <$> node.effects,
          sourceSpan = node.sourceSpan
        }
  TypeArray sourceSpan -> TypeArray sourceSpan
  TypeRecord sourceSpan -> TypeRecord sourceSpan
  TypeApplication node ->
    TypeApplication
      TypeApplicationTypeNode
        { applicationHead = retagSyntacticTypeExpression node.applicationHead,
          applicationArguments = retagSyntacticTypeExpression <$> node.applicationArguments,
          sourceSpan = node.sourceSpan
        }
  TypeTuple node ->
    TypeTuple
      TupleTypeNode
        { elementTypes = retagSyntacticTypeExpression <$> node.elementTypes,
          sourceSpan = node.sourceSpan
        }
  TypeUnion node ->
    TypeUnion
      TypeUnionNode
        { branches = retagSyntacticTypeExpression <$> node.branches,
          sourceSpan = node.sourceSpan
        }
  TypeObject node ->
    TypeObject
      ObjectTypeNode
        { fields = retagObjectTypeField <$> node.fields,
          sourceSpan = node.sourceSpan
        }
  TypeAttributed node ->
    TypeAttributed
      AttributedTypeNode
        { baseType = retagSyntacticTypeExpression node.baseType,
          attribute = retagSyntacticTypeExpression node.attribute,
          sourceSpan = node.sourceSpan
        }
  TypeAttributeLiteral node -> TypeAttributeLiteral node
  TypeOverride node ->
    TypeOverride
      OverrideTypeNode
        { base = retagSyntacticTypeExpression node.base,
          overrides = retagSyntacticTypeExpression <$> node.overrides,
          sourceSpan = node.sourceSpan
        }

retagObjectTypeField ::
  ( ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference
  ) =>
  ObjectTypeField phase1 ->
  ObjectTypeField phase2
retagObjectTypeField field =
  ObjectTypeField
    { name = field.name,
      fieldType = retagSyntacticTypeExpression field.fieldType,
      optional = field.optional,
      sourceSpan = field.sourceSpan
    }

retagGenericParameter ::
  ( ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference
  ) =>
  GenericParameter phase1 ->
  GenericParameter phase2
retagGenericParameter parameter =
  GenericParameter
    { name = parameter.name,
      labelReference = retagReference parameter.labelReference,
      typeReference = retagReference parameter.typeReference,
      kind = parameter.kind,
      bindsLiteral = parameter.bindsLiteral,
      upperBound = retagSyntacticTypeExpression <$> parameter.upperBound,
      sourceSpan = parameter.sourceSpan
    }

-- | Retag a 'ParameterSignature' (used in declarations that don't carry a body — data / request /
-- external / primitive). Structural — no checker types are populated here.
retagParameterSignature ::
  ( ReferenceResolution phase1 LabelReference ~ ReferenceResolution phase2 LabelReference,
    ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference
  ) =>
  ParameterSignature phase1 ->
  ParameterSignature phase2
retagParameterSignature signature =
  ParameterSignature
    { annotation = signature.annotation,
      name = signature.name,
      labelReference = retagReference signature.labelReference,
      parameterType = retagSyntacticTypeExpression signature.parameterType,
      defaultValue = signature.defaultValue,
      sourceSpan = signature.sourceSpan
    }

-- | Retag a 'DataDeclaration'. No body, no expression-level typing — purely structural.
retagDataDeclaration ::
  ( ReferenceResolution phase1 VariableReference ~ ReferenceResolution phase2 VariableReference,
    ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference,
    ReferenceResolution phase1 LabelReference ~ ReferenceResolution phase2 LabelReference
  ) =>
  DataDeclaration phase1 ->
  DataDeclaration phase2
retagDataDeclaration declaration =
  DataDeclaration
    { annotation = declaration.annotation,
      name = declaration.name,
      variableReference = retagReference declaration.variableReference,
      typeReference = retagReference declaration.typeReference,
      genericParameters = retagGenericParameter <$> declaration.genericParameters,
      parameters = retagParameterSignature <$> declaration.parameters,
      sourceSpan = declaration.sourceSpan
    }

retagRequestDeclaration ::
  ( ReferenceResolution phase1 VariableReference ~ ReferenceResolution phase2 VariableReference,
    ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference,
    ReferenceResolution phase1 LabelReference ~ ReferenceResolution phase2 LabelReference
  ) =>
  RequestDeclaration phase1 ->
  RequestDeclaration phase2
retagRequestDeclaration declaration =
  RequestDeclaration
    { annotation = declaration.annotation,
      name = declaration.name,
      variableReference = retagReference declaration.variableReference,
      typeReference = retagReference declaration.typeReference,
      genericParameters = retagGenericParameter <$> declaration.genericParameters,
      parameters = retagParameterSignature <$> declaration.parameters,
      returnType = retagSyntacticTypeExpression declaration.returnType,
      sourceSpan = declaration.sourceSpan
    }

retagMarkerEffectDeclaration ::
  ( ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference
  ) =>
  MarkerEffectDeclaration phase1 ->
  MarkerEffectDeclaration phase2
retagMarkerEffectDeclaration declaration =
  MarkerEffectDeclaration
    { annotation = declaration.annotation,
      name = declaration.name,
      typeReference = retagReference declaration.typeReference,
      genericParameters = retagGenericParameter <$> declaration.genericParameters,
      sourceSpan = declaration.sourceSpan
    }

retagExternalAgentDeclaration ::
  ( ReferenceResolution phase1 VariableReference ~ ReferenceResolution phase2 VariableReference,
    ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference,
    ReferenceResolution phase1 LabelReference ~ ReferenceResolution phase2 LabelReference
  ) =>
  ExternalAgentDeclaration phase1 ->
  ExternalAgentDeclaration phase2
retagExternalAgentDeclaration declaration =
  ExternalAgentDeclaration
    { annotation = declaration.annotation,
      name = declaration.name,
      variableReference = retagReference declaration.variableReference,
      genericParameters = retagGenericParameter <$> declaration.genericParameters,
      parameters = retagParameterSignature <$> declaration.parameters,
      returnType = retagSyntacticTypeExpression declaration.returnType,
      effects = retagSyntacticTypeExpression <$> declaration.effects,
      reactor = declaration.reactor,
      sourceSpan = declaration.sourceSpan
    }

retagPrimitiveAgentDeclaration ::
  ( ReferenceResolution phase1 VariableReference ~ ReferenceResolution phase2 VariableReference,
    ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference,
    ReferenceResolution phase1 LabelReference ~ ReferenceResolution phase2 LabelReference
  ) =>
  PrimitiveAgentDeclaration phase1 ->
  PrimitiveAgentDeclaration phase2
retagPrimitiveAgentDeclaration declaration =
  PrimitiveAgentDeclaration
    { annotation = declaration.annotation,
      name = declaration.name,
      variableReference = retagReference declaration.variableReference,
      genericParameters = retagGenericParameter <$> declaration.genericParameters,
      parameters = retagParameterSignature <$> declaration.parameters,
      returnType = retagSyntacticTypeExpression declaration.returnType,
      effects = retagSyntacticTypeExpression <$> declaration.effects,
      sourceSpan = declaration.sourceSpan
    }

retagTypeSynonymDeclaration ::
  ( ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference
  ) =>
  TypeSynonymDeclaration phase1 ->
  TypeSynonymDeclaration phase2
retagTypeSynonymDeclaration declaration =
  TypeSynonymDeclaration
    { name = declaration.name,
      typeReference = retagReference declaration.typeReference,
      genericParameters = retagGenericParameter <$> declaration.genericParameters,
      definition = retagSyntacticTypeExpression declaration.definition,
      sourceSpan = declaration.sourceSpan
    }

---------------------------------------------------------------------------------------------------------------
-- Aggregate Eq / Show constraints
---------------------------------------------------------------------------------------------------------------

-- | Bundles the Eq constraints of every phase-indexed payload so standalone
-- deriving clauses share a single context name.
class
  ( Eq (ReferenceResolution phase VariableReference),
    Eq (ReferenceResolution phase TypeReference),
    Eq (ReferenceResolution phase ModuleReference),
    Eq (ReferenceResolution phase LabelReference),
    Eq (ExpressionType phase),
    Eq (PatternType phase),
    Eq (GenericInstantiation phase)
  ) =>
  EqPhase phase

instance
  ( Eq (ReferenceResolution phase VariableReference),
    Eq (ReferenceResolution phase TypeReference),
    Eq (ReferenceResolution phase ModuleReference),
    Eq (ReferenceResolution phase LabelReference),
    Eq (ExpressionType phase),
    Eq (PatternType phase),
    Eq (GenericInstantiation phase)
  ) =>
  EqPhase phase

-- | Show counterpart of 'EqPhase'.
class
  ( Show (ReferenceResolution phase VariableReference),
    Show (ReferenceResolution phase TypeReference),
    Show (ReferenceResolution phase ModuleReference),
    Show (ReferenceResolution phase LabelReference),
    Show (ExpressionType phase),
    Show (PatternType phase),
    Show (GenericInstantiation phase)
  ) =>
  ShowPhase phase

instance
  ( Show (ReferenceResolution phase VariableReference),
    Show (ReferenceResolution phase TypeReference),
    Show (ReferenceResolution phase ModuleReference),
    Show (ReferenceResolution phase LabelReference),
    Show (ExpressionType phase),
    Show (PatternType phase),
    Show (GenericInstantiation phase)
  ) =>
  ShowPhase phase

deriving stock instance (Eq (ReferenceResolution phase nameReferenceKind)) => Eq (Reference phase nameReferenceKind)

deriving stock instance (Show (ReferenceResolution phase nameReferenceKind)) => Show (Reference phase nameReferenceKind)

deriving stock instance (EqPhase phase) => Eq (Module phase)

deriving stock instance (ShowPhase phase) => Show (Module phase)

deriving stock instance (EqPhase phase) => Eq (Declaration phase)

deriving stock instance (ShowPhase phase) => Show (Declaration phase)

deriving stock instance (EqPhase phase) => Eq (ModuleQualifier phase)

deriving stock instance (ShowPhase phase) => Show (ModuleQualifier phase)

deriving stock instance (EqPhase phase) => Eq (GenericParameter phase)

deriving stock instance (ShowPhase phase) => Show (GenericParameter phase)

deriving stock instance (EqPhase phase) => Eq (ParameterBinding phase)

deriving stock instance (ShowPhase phase) => Show (ParameterBinding phase)

deriving stock instance (EqPhase phase) => Eq (Binder phase)

deriving stock instance (ShowPhase phase) => Show (Binder phase)

deriving stock instance (EqPhase phase) => Eq (ParameterSignature phase)

deriving stock instance (ShowPhase phase) => Show (ParameterSignature phase)

deriving stock instance (EqPhase phase) => Eq (AgentDeclaration phase)

deriving stock instance (ShowPhase phase) => Show (AgentDeclaration phase)

deriving stock instance (EqPhase phase) => Eq (RequestDeclaration phase)

deriving stock instance (ShowPhase phase) => Show (RequestDeclaration phase)

deriving stock instance (EqPhase phase) => Eq (MarkerEffectDeclaration phase)

deriving stock instance (ShowPhase phase) => Show (MarkerEffectDeclaration phase)

deriving stock instance (EqPhase phase) => Eq (ExternalAgentDeclaration phase)

deriving stock instance (ShowPhase phase) => Show (ExternalAgentDeclaration phase)

deriving stock instance (EqPhase phase) => Eq (PrimitiveAgentDeclaration phase)

deriving stock instance (ShowPhase phase) => Show (PrimitiveAgentDeclaration phase)

deriving stock instance (EqPhase phase) => Eq (DataDeclaration phase)

deriving stock instance (ShowPhase phase) => Show (DataDeclaration phase)

deriving stock instance (EqPhase phase) => Eq (TypeSynonymDeclaration phase)

deriving stock instance (ShowPhase phase) => Show (TypeSynonymDeclaration phase)

deriving stock instance (EqPhase phase) => Eq (Block phase)

deriving stock instance (ShowPhase phase) => Show (Block phase)

deriving stock instance (EqPhase phase) => Eq (Statement phase)

deriving stock instance (ShowPhase phase) => Show (Statement phase)

deriving stock instance (EqPhase phase) => Eq (LetStatement phase)

deriving stock instance (ShowPhase phase) => Show (LetStatement phase)

deriving stock instance (EqPhase phase) => Eq (UseStatement phase)

deriving stock instance (ShowPhase phase) => Show (UseStatement phase)

deriving stock instance (EqPhase phase) => Eq (ReturnStatement phase)

deriving stock instance (ShowPhase phase) => Show (ReturnStatement phase)

deriving stock instance (EqPhase phase) => Eq (NextStatement phase)

deriving stock instance (ShowPhase phase) => Show (NextStatement phase)

deriving stock instance (EqPhase phase) => Eq (BreakStatement phase)

deriving stock instance (ShowPhase phase) => Show (BreakStatement phase)

deriving stock instance (EqPhase phase) => Eq (ForNextStatement phase)

deriving stock instance (ShowPhase phase) => Show (ForNextStatement phase)

deriving stock instance (EqPhase phase) => Eq (ForBreakStatement phase)

deriving stock instance (ShowPhase phase) => Show (ForBreakStatement phase)

deriving stock instance (EqPhase phase) => Eq (FinallyStatement phase)

deriving stock instance (ShowPhase phase) => Show (FinallyStatement phase)

deriving stock instance (EqPhase phase) => Eq (Modifier phase)

deriving stock instance (ShowPhase phase) => Show (Modifier phase)

deriving stock instance (EqPhase phase) => Eq (VariableBinding phase)

deriving stock instance (ShowPhase phase) => Show (VariableBinding phase)

deriving stock instance (EqPhase phase) => Eq (ThenClause phase)

deriving stock instance (ShowPhase phase) => Show (ThenClause phase)

deriving stock instance (EqPhase phase) => Eq (HandlerExpression phase)

deriving stock instance (ShowPhase phase) => Show (HandlerExpression phase)

deriving stock instance (EqPhase phase) => Eq (RequestHandler phase)

deriving stock instance (ShowPhase phase) => Show (RequestHandler phase)

deriving stock instance (EqPhase phase) => Eq (Pattern phase)

deriving stock instance (ShowPhase phase) => Show (Pattern phase)

deriving stock instance (EqPhase phase) => Eq (VariablePattern phase)

deriving stock instance (ShowPhase phase) => Show (VariablePattern phase)

deriving stock instance (EqPhase phase) => Eq (ConstructorPattern phase)

deriving stock instance (ShowPhase phase) => Show (ConstructorPattern phase)

deriving stock instance (EqPhase phase) => Eq (FieldPattern phase)

deriving stock instance (ShowPhase phase) => Show (FieldPattern phase)

deriving stock instance (EqPhase phase) => Eq (TuplePattern phase)

deriving stock instance (ShowPhase phase) => Show (TuplePattern phase)

deriving stock instance (EqPhase phase) => Eq (WildcardPattern phase)

deriving stock instance (ShowPhase phase) => Show (WildcardPattern phase)

deriving stock instance (EqPhase phase) => Eq (LiteralPattern phase)

deriving stock instance (ShowPhase phase) => Show (LiteralPattern phase)

deriving stock instance (EqPhase phase) => Eq (TypeFilterPattern phase)

deriving stock instance (ShowPhase phase) => Show (TypeFilterPattern phase)

deriving stock instance (EqPhase phase) => Eq (RecordPattern phase)

deriving stock instance (ShowPhase phase) => Show (RecordPattern phase)

deriving stock instance (EqPhase phase) => Eq (SyntacticTypeExpression phase)

deriving stock instance (ShowPhase phase) => Show (SyntacticTypeExpression phase)

deriving stock instance (EqPhase phase) => Eq (TypeNameNode phase)

deriving stock instance (ShowPhase phase) => Show (TypeNameNode phase)

deriving stock instance (EqPhase phase) => Eq (AgentTypeNode phase)

deriving stock instance (ShowPhase phase) => Show (AgentTypeNode phase)

deriving stock instance (EqPhase phase) => Eq (TypeApplicationTypeNode phase)

deriving stock instance (ShowPhase phase) => Show (TypeApplicationTypeNode phase)

deriving stock instance (EqPhase phase) => Eq (TupleTypeNode phase)

deriving stock instance (ShowPhase phase) => Show (TupleTypeNode phase)

deriving stock instance (EqPhase phase) => Eq (TypeUnionNode phase)

deriving stock instance (ShowPhase phase) => Show (TypeUnionNode phase)

deriving stock instance (EqPhase phase) => Eq (ObjectTypeNode phase)

deriving stock instance (ShowPhase phase) => Show (ObjectTypeNode phase)

deriving stock instance (EqPhase phase) => Eq (ObjectTypeField phase)

deriving stock instance (ShowPhase phase) => Show (ObjectTypeField phase)

deriving stock instance (EqPhase phase) => Eq (AttributedTypeNode phase)

deriving stock instance (ShowPhase phase) => Show (AttributedTypeNode phase)

deriving stock instance (EqPhase phase) => Eq (OverrideTypeNode phase)

deriving stock instance (ShowPhase phase) => Show (OverrideTypeNode phase)

deriving stock instance (EqPhase phase) => Eq (Expression phase)

deriving stock instance (ShowPhase phase) => Show (Expression phase)

deriving stock instance (EqPhase phase) => Eq (LiteralExpression phase)

deriving stock instance (ShowPhase phase) => Show (LiteralExpression phase)

deriving stock instance (EqPhase phase) => Eq (VariableExpression phase)

deriving stock instance (ShowPhase phase) => Show (VariableExpression phase)

deriving stock instance (EqPhase phase) => Eq (TupleExpression phase)

deriving stock instance (ShowPhase phase) => Show (TupleExpression phase)

deriving stock instance (EqPhase phase) => Eq (RecordExpression phase)

deriving stock instance (ShowPhase phase) => Show (RecordExpression phase)

deriving stock instance (EqPhase phase) => Eq (RecordEntry phase)

deriving stock instance (ShowPhase phase) => Show (RecordEntry phase)

deriving stock instance (EqPhase phase) => Eq (CallExpression phase)

deriving stock instance (ShowPhase phase) => Show (CallExpression phase)

deriving stock instance (EqPhase phase) => Eq (CallArgument phase)

deriving stock instance (ShowPhase phase) => Show (CallArgument phase)

deriving stock instance (EqPhase phase) => Eq (CallArgumentValue phase)

deriving stock instance (ShowPhase phase) => Show (CallArgumentValue phase)

deriving stock instance (EqPhase phase) => Eq (BinaryOperatorExpression phase)

deriving stock instance (ShowPhase phase) => Show (BinaryOperatorExpression phase)

deriving stock instance (EqPhase phase) => Eq (UnaryOperatorExpression phase)

deriving stock instance (ShowPhase phase) => Show (UnaryOperatorExpression phase)

deriving stock instance (EqPhase phase) => Eq (IfExpression phase)

deriving stock instance (ShowPhase phase) => Show (IfExpression phase)

deriving stock instance (EqPhase phase) => Eq (MatchExpression phase)

deriving stock instance (ShowPhase phase) => Show (MatchExpression phase)

deriving stock instance (EqPhase phase) => Eq (CaseArm phase)

deriving stock instance (ShowPhase phase) => Show (CaseArm phase)

deriving stock instance (EqPhase phase) => Eq (ForExpression phase)

deriving stock instance (ShowPhase phase) => Show (ForExpression phase)

deriving stock instance (EqPhase phase) => Eq (ForeverExpression phase)

deriving stock instance (ShowPhase phase) => Show (ForeverExpression phase)

deriving stock instance (EqPhase phase) => Eq (ForInBinding phase)

deriving stock instance (ShowPhase phase) => Show (ForInBinding phase)

deriving stock instance (EqPhase phase) => Eq (BlockExpression phase)

deriving stock instance (ShowPhase phase) => Show (BlockExpression phase)

deriving stock instance (EqPhase phase) => Eq (FieldAccessExpression phase)

deriving stock instance (ShowPhase phase) => Show (FieldAccessExpression phase)

deriving stock instance (EqPhase phase) => Eq (TypeApplicationExpression phase)

deriving stock instance (ShowPhase phase) => Show (TypeApplicationExpression phase)

deriving stock instance (EqPhase phase) => Eq (TemplateExpression phase)

deriving stock instance (ShowPhase phase) => Show (TemplateExpression phase)

deriving stock instance (EqPhase phase) => Eq (TemplateElement phase)

deriving stock instance (ShowPhase phase) => Show (TemplateElement phase)

deriving stock instance (EqPhase phase) => Eq (TemplateExpressionElement phase)

deriving stock instance (ShowPhase phase) => Show (TemplateExpressionElement phase)

deriving stock instance (EqPhase phase) => Eq (QualifiedReferenceExpression phase)

deriving stock instance (ShowPhase phase) => Show (QualifiedReferenceExpression phase)
