module Katari.Data.AST where

import Data.Kind (Type)
import Data.Map (Map)
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.Id (TypeResolution, VariableResolution)
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.SemanticType (SemanticGenericArgument, SemanticType)
import Katari.Data.SourceSpan (HasSourceSpan (..), SourceSpan)

type data ReferenceKind where
  VariableReference :: ReferenceKind
  TypeReference :: ReferenceKind
  ModuleReference :: ReferenceKind
  LabelReference :: ReferenceKind

type data Phase where
  Parsed :: Phase
  Identified :: Phase
  Typed :: Phase

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

-- | callee[T, E](...), etc...  Typed AST will contains infered generic instantiations
type family GenericInstantiation (phase :: Phase) :: Type where
  GenericInstantiation Parsed = ()
  GenericInstantiation Identified = ()
  GenericInstantiation Typed = Map Text SemanticGenericArgument

-- | handler[R, E] {...}  Typed AST will contains infered generic instantiations for R and E
type family HandlerGenerics (phase :: Phase) :: Type where
  HandlerGenerics Parsed = ()
  HandlerGenerics Identified = ()
  HandlerGenerics Typed = (SemanticGenericArgument, SemanticGenericArgument) -- (return type, effect)

data Module (phase :: Phase) = Module
  { declarations :: List (Declaration phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Module phase) where
  sourceSpanOf module' = module'.sourceSpan

data Declaration (phase :: Phase) where
  DeclarationAgent :: AgentDeclaration phase -> Declaration phase
  DeclarationRequest :: RequestDeclaration phase -> Declaration phase
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

-- | A formal generic parameter of an agent / request / external / prim declaration.
data GenericParameter (phase :: Phase) = GenericParameter
  { name :: Text,
    labelReference :: Reference phase LabelReference,
    -- | Generic ID
    typeReference :: Reference phase TypeReference,
    kind :: GenericKind,
    -- | No upper bound  ~> unknown of private (top type)
    upperBound :: Maybe (SyntacticType phase),
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
    bindPattern :: Pattern phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ParameterBinding phase) where
  sourceSpanOf binding = binding.sourceSpan

-- | @label : type ?= default@ — a formal parameter of a request / external /
-- primitive / data declaration. No pattern, type required.
data ParameterSignature (phase :: Phase) = ParameterSignature
  { annotation :: Maybe Text,
    name :: Text,
    labelReference :: Reference phase LabelReference,
    parameterType :: SyntacticType phase,
    defaultValue :: Maybe ParameterDefault,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ParameterSignature phase) where
  sourceSpanOf signature = signature.sourceSpan

data LiteralValue where
  LiteralValueInteger :: Integer -> LiteralValue
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

-- | @agent name[generics](label => pattern, ...) -> T with E { body }@
data AgentDeclaration (phase :: Phase) = AgentDeclaration
  { annotation :: Maybe Text,
    name :: Text,
    variableReference :: Reference phase VariableReference,
    genericParameters :: List (GenericParameter phase),
    parameters :: List (ParameterBinding phase),
    returnType :: SyntacticType phase,
    effects :: Maybe (SyntacticEffect phase),
    body :: Block phase,
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
    returnType :: SyntacticType phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RequestDeclaration phase) where
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
    alias :: Maybe Text
  }
  deriving stock (Eq, Show)

data ImportItem = ImportItem
  { kind :: ImportItemKind,
    name :: Text
  }
  deriving stock (Eq, Show)

-- | Namespace of an import item; @type@ prefix selects the type namespace.
data ImportItemKind where
  ImportItemValue :: ImportItemKind
  ImportItemType :: ImportItemKind
  deriving stock (Eq, Show)

-- | @external agent name[generics](label : type ?= default, ...) -> T with E from "ENDPOINT:dispatch_name"@
data ExternalAgentDeclaration (phase :: Phase) = ExternalAgentDeclaration
  { annotation :: Maybe Text,
    name :: Text,
    variableReference :: Reference phase VariableReference,
    genericParameters :: List (GenericParameter phase),
    parameters :: List (ParameterSignature phase),
    returnType :: SyntacticType phase,
    effects :: Maybe (SyntacticEffect phase),
    endpoint :: Text,
    dispatchName :: Text,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ExternalAgentDeclaration phase) where
  sourceSpanOf declaration = declaration.sourceSpan

-- | @primitive agent name[generics](label : type ?= default, ...) -> T with E using rule@
data PrimitiveAgentDeclaration (phase :: Phase) = PrimitiveAgentDeclaration
  { annotation :: Maybe Text,
    name :: Text,
    variableReference :: Reference phase VariableReference,
    genericParameters :: List (GenericParameter phase),
    parameters :: List (ParameterSignature phase),
    returnType :: SyntacticType phase,
    effects :: Maybe (SyntacticEffect phase),
    -- | Special typing rule consulted by the typechecker
    using :: Maybe Text,
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

-- | @type name = T@
data TypeSynonymDeclaration (phase :: Phase) = TypeSynonymDeclaration
  { name :: Text,
    typeReference :: Reference phase TypeReference,
    definition :: SyntacticType phase,
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
    returnExpression :: Maybe (Expression phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (Block phase) where
  sourceSpanOf block = block.sourceSpan

data Statement (phase :: Phase) where
  -- | @let pattern = expression@
  StatementLet :: LetStatement phase -> Statement phase
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
  -- | Sentinel left by parser recovery; details live in the parallel parse-error list
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

data ReturnStatement (phase :: Phase) = ReturnStatement
  { value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ReturnStatement phase) where
  sourceSpanOf statement = statement.sourceSpan

data NextStatement (phase :: Phase) = NextStatement
  { value :: Expression phase,
    modifiers :: List (Modifier phase),
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
    modifiers :: List (Modifier phase),
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
    typeAnnotation :: Maybe (SyntacticType phase),
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

-- | @[par] handler (var s = init, ...) { request foo(...) { ... } ... } then (pattern) { body }@.
-- An anonymous handler-provider agent, implicitly generic over the continuation's
-- return type and residual effect ('HandlerGenerics').
data HandlerExpression (phase :: Phase) = HandlerExpression
  { parallel :: Bool,
    stateVariables :: List (VariableBinding phase),
    handlers :: List (RequestHandler phase),
    thenClause :: Maybe (ThenClause phase),
    generics :: HandlerGenerics phase,
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
    genericArguments :: List (SyntacticType phase),
    -- | The resolved substitution (declared generic -> argument), filled by the checker at
    -- 'Typed' so lowering need not re-derive it
    instantiation :: GenericInstantiation phase,
    parameters :: List (ParameterBinding phase),
    returnType :: Maybe (SyntacticType phase),
    body :: Block phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (RequestHandler phase) where
  sourceSpanOf handler = handler.sourceSpan

-- | @[let pattern =] use provider@ — applies @provider@ (a handler provider) to
-- the rest of the enclosing block, captured as @body@ (the continuation).
data UseExpression (phase :: Phase) = UseExpression
  { binder :: Maybe (Pattern phase),
    provider :: Expression phase,
    body :: Block phase,
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (UseExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

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
  PatternType :: TypePattern phase -> Pattern phase
  -- | @{ label => pattern, ... }@ — subset match against a record value
  PatternRecord :: RecordPattern phase -> Pattern phase

instance HasSourceSpan (Pattern phase) where
  sourceSpanOf = \case
    PatternVariable pattern' -> pattern'.sourceSpan
    PatternConstructor pattern' -> pattern'.sourceSpan
    PatternTuple pattern' -> pattern'.sourceSpan
    PatternWildcard pattern' -> pattern'.sourceSpan
    PatternLiteral pattern' -> pattern'.sourceSpan
    PatternType pattern' -> pattern'.sourceSpan
    PatternRecord pattern' -> pattern'.sourceSpan

data VariablePattern (phase :: Phase) = VariablePattern
  { name :: Text,
    variableReference :: Reference phase VariableReference,
    typeAnnotation :: Maybe (SyntacticType phase),
    -- | Only meaningful in parameter position
    defaultValue :: Maybe ParameterDefault,
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (VariablePattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data ConstructorPattern (phase :: Phase) = ConstructorPattern
  { moduleQualifier :: Maybe (ModuleQualifier phase),
    name :: Text,
    constructorReference :: Reference phase VariableReference,
    genericArguments :: List (SyntacticType phase),
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
  { typeAnnotation :: Maybe (SyntacticType phase),
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

data TypePattern (phase :: Phase) = TypePattern
  { matchedType :: SyntacticType phase,
    inner :: Pattern phase,
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (TypePattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

data RecordPattern (phase :: Phase) = RecordPattern
  { fields :: List (FieldPattern phase),
    sourceSpan :: SourceSpan,
    typeOf :: PatternType phase
  }

instance HasSourceSpan (RecordPattern phase) where
  sourceSpanOf pattern' = pattern'.sourceSpan

---------------------------------------------------------------------------------------------------------------
-- Types
---------------------------------------------------------------------------------------------------------------

data SyntacticType (phase :: Phase) where
  -- | @null@ / @integer@ / @number@ / @string@ / @boolean@ / @file@
  TypePrimitive :: PrimitiveTypeNode -> SyntacticType phase
  -- | @never@ — bottom
  TypeNever :: SourceSpan -> SyntacticType phase
  -- | @unknown@ — top
  TypeUnknown :: SourceSpan -> SyntacticType phase
  -- | Bare type name. Resolution also covers generic effect / attribute names.
  TypeName :: TypeNameNode phase -> SyntacticType phase
  -- | @module.name@
  TypeQualified :: QualifiedTypeNode phase -> SyntacticType phase
  -- | @agent T -> R [with E]@. The parenthesised parameter list
  -- @agent (label : T, ...) -> R@ is parser sugar for an object parameter type.
  TypeAgent :: AgentTypeNode phase -> SyntacticType phase
  -- | The @array@ type constructor; always the head of a 'TypeApplication'
  TypeArray :: SourceSpan -> SyntacticType phase
  -- | The @record@ type; bare = homogeneous-map top, @record[V]@ via 'TypeApplication'
  TypeRecord :: SourceSpan -> SyntacticType phase
  -- | @head[argument, ...]@
  TypeApplication :: TypeApplicationTypeNode phase -> SyntacticType phase
  -- | @(T1, T2, ...)@
  TypeTuple :: TupleTypeNode phase -> SyntacticType phase
  -- | @T1 | T2 | ...@ — 2 or more branches, order preserving
  TypeUnion :: TypeUnionNode phase -> SyntacticType phase
  -- | @{label : T, label ?: T, ...}@
  TypeObject :: ObjectTypeNode phase -> SyntacticType phase
  -- | @T of A@
  TypeAttributed :: AttributedTypeNode phase -> SyntacticType phase
  -- | @public@ / @private@ — only meaningful in attribute positions (kind-checked)
  TypeAttributeLiteral :: AttributeLiteralNode -> SyntacticType phase

instance HasSourceSpan (SyntacticType phase) where
  sourceSpanOf = \case
    TypePrimitive node -> node.sourceSpan
    TypeNever sourceSpan -> sourceSpan
    TypeUnknown sourceSpan -> sourceSpan
    TypeName node -> node.sourceSpan
    TypeQualified node -> node.sourceSpan
    TypeAgent node -> node.sourceSpan
    TypeArray sourceSpan -> sourceSpan
    TypeRecord sourceSpan -> sourceSpan
    TypeApplication node -> node.sourceSpan
    TypeTuple node -> node.sourceSpan
    TypeUnion node -> node.sourceSpan
    TypeObject node -> node.sourceSpan
    TypeAttributed node -> node.sourceSpan
    TypeAttributeLiteral node -> node.sourceSpan

data PrimitiveTypeKind where
  PrimitiveTypeKindNull :: PrimitiveTypeKind
  PrimitiveTypeKindInteger :: PrimitiveTypeKind
  PrimitiveTypeKindNumber :: PrimitiveTypeKind
  PrimitiveTypeKindString :: PrimitiveTypeKind
  PrimitiveTypeKindBoolean :: PrimitiveTypeKind
  PrimitiveTypeKindFile :: PrimitiveTypeKind
  deriving stock (Eq, Show)

data PrimitiveTypeNode = PrimitiveTypeNode
  { kind :: PrimitiveTypeKind,
    sourceSpan :: SourceSpan
  }
  deriving stock (Eq, Show)

instance HasSourceSpan PrimitiveTypeNode where
  sourceSpanOf node = node.sourceSpan

data TypeNameNode (phase :: Phase) = TypeNameNode
  { name :: Text,
    typeReference :: Reference phase TypeReference,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeNameNode phase) where
  sourceSpanOf node = node.sourceSpan

data QualifiedTypeNode (phase :: Phase) = QualifiedTypeNode
  { moduleQualifier :: ModuleQualifier phase,
    name :: Text,
    typeReference :: Reference phase TypeReference,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (QualifiedTypeNode phase) where
  sourceSpanOf node = node.sourceSpan

-- | @agent T -> R [with E]@. No @with@ clause ~> pure.
data AgentTypeNode (phase :: Phase) = AgentTypeNode
  { parameterType :: SyntacticType phase,
    returnType :: SyntacticType phase,
    effects :: Maybe (SyntacticEffect phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (AgentTypeNode phase) where
  sourceSpanOf node = node.sourceSpan

-- | Arguments are parsed uniformly as types; the typechecker splits them into
-- type / effect / attribute arguments by the head's generic-parameter kinds.
data TypeApplicationTypeNode (phase :: Phase) = TypeApplicationTypeNode
  { applicationHead :: SyntacticType phase,
    applicationArguments :: List (SyntacticType phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TypeApplicationTypeNode phase) where
  sourceSpanOf node = node.sourceSpan

data TupleTypeNode (phase :: Phase) = TupleTypeNode
  { elementTypes :: List (SyntacticType phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (TupleTypeNode phase) where
  sourceSpanOf node = node.sourceSpan

data TypeUnionNode (phase :: Phase) = TypeUnionNode
  { branches :: List (SyntacticType phase),
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
    fieldType :: SyntacticType phase,
    optional :: Bool,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (ObjectTypeField phase) where
  sourceSpanOf field = field.sourceSpan

-- | @T of A@ — the attribute side is kind-checked to be an attribute
data AttributedTypeNode (phase :: Phase) = AttributedTypeNode
  { baseType :: SyntacticType phase,
    attribute :: SyntacticType phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (AttributedTypeNode phase) where
  sourceSpanOf node = node.sourceSpan

data AttributeLiteralKind where
  AttributeLiteralPublic :: AttributeLiteralKind
  AttributeLiteralPrivate :: AttributeLiteralKind
  deriving stock (Eq, Show)

data AttributeLiteralNode = AttributeLiteralNode
  { kind :: AttributeLiteralKind,
    sourceSpan :: SourceSpan
  }
  deriving stock (Eq, Show)

instance HasSourceSpan AttributeLiteralNode where
  sourceSpanOf node = node.sourceSpan

---------------------------------------------------------------------------------------------------------------
-- Effects
---------------------------------------------------------------------------------------------------------------

-- | A @with@-clause effect expression. An omitted clause means pure.
data SyntacticEffect (phase :: Phase) where
  -- | @all@ — the effect top
  EffectAll :: SourceSpan -> SyntacticEffect phase
  -- | A request / generic-effect name with optional arguments
  EffectNamed :: NamedEffectNode phase -> SyntacticEffect phase
  -- | @E1 | E2 | ...@
  EffectUnion :: EffectUnionNode phase -> SyntacticEffect phase
  -- | @{...E, request[arguments], ...}@ — shadows requests of the base effect
  EffectOverride :: OverrideEffectNode phase -> SyntacticEffect phase

instance HasSourceSpan (SyntacticEffect phase) where
  sourceSpanOf = \case
    EffectAll sourceSpan -> sourceSpan
    EffectNamed node -> node.sourceSpan
    EffectUnion node -> node.sourceSpan
    EffectOverride node -> node.sourceSpan

-- | @[module.]name[argument, ...]@
data NamedEffectNode (phase :: Phase) = NamedEffectNode
  { moduleQualifier :: Maybe (ModuleQualifier phase),
    name :: Text,
    typeReference :: Reference phase TypeReference,
    arguments :: List (SyntacticType phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (NamedEffectNode phase) where
  sourceSpanOf node = node.sourceSpan

data EffectUnionNode (phase :: Phase) = EffectUnionNode
  { branches :: List (SyntacticEffect phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (EffectUnionNode phase) where
  sourceSpanOf node = node.sourceSpan

data OverrideEffectNode (phase :: Phase) = OverrideEffectNode
  { base :: SyntacticEffect phase,
    overrides :: List (NamedEffectNode phase),
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (OverrideEffectNode phase) where
  sourceSpanOf node = node.sourceSpan

---------------------------------------------------------------------------------------------------------------
-- Expressions
---------------------------------------------------------------------------------------------------------------

data Expression (phase :: Phase) where
  -- | @42@ / @"foo"@ / @true@ / @null@ / ...
  ExpressionLiteral :: LiteralExpression phase -> Expression phase
  -- | Bare identifier
  ExpressionVariable :: VariableExpression phase -> Expression phase
  -- | @[e1, e2, ...]@ — sequential evaluation
  ExpressionTuple :: TupleExpression phase -> Expression phase
  -- | @par [e1, e2, ...]@ — concurrent evaluation, results in order
  ExpressionParallelTuple :: ParallelTupleExpression phase -> Expression phase
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
  -- | @[let pattern =] use provider@
  ExpressionUse :: UseExpression phase -> Expression phase
  -- | @module.target@ — synthesised by the Identifier from a field-access chain
  -- whose left-most segment resolves to a module; never produced by the parser
  ExpressionQualifiedReference :: QualifiedReferenceExpression phase -> Expression phase

instance HasSourceSpan (Expression phase) where
  sourceSpanOf = \case
    ExpressionLiteral expression -> expression.sourceSpan
    ExpressionVariable expression -> expression.sourceSpan
    ExpressionTuple expression -> expression.sourceSpan
    ExpressionParallelTuple expression -> expression.sourceSpan
    ExpressionRecord expression -> expression.sourceSpan
    ExpressionCall expression -> expression.sourceSpan
    ExpressionBinaryOperator expression -> expression.sourceSpan
    ExpressionUnaryOperator expression -> expression.sourceSpan
    ExpressionIf expression -> expression.sourceSpan
    ExpressionMatch expression -> expression.sourceSpan
    ExpressionFor expression -> expression.sourceSpan
    ExpressionBlock expression -> expression.sourceSpan
    ExpressionFieldAccess expression -> expression.sourceSpan
    ExpressionTypeApplication expression -> expression.sourceSpan
    ExpressionTemplate expression -> expression.sourceSpan
    ExpressionHandler expression -> expression.sourceSpan
    ExpressionUse expression -> expression.sourceSpan
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

data TupleExpression (phase :: Phase) = TupleExpression
  { elements :: List (Expression phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (TupleExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

data ParallelTupleExpression (phase :: Phase) = ParallelTupleExpression
  { elements :: List (Expression phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (ParallelTupleExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | Keys are values on the wire, not references
data RecordExpression (phase :: Phase) = RecordExpression
  { entries :: List (Text, Expression phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (RecordExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | Arguments are keyword-labelled; source order is preserved
data CallExpression (phase :: Phase) = CallExpression
  { callee :: Expression phase,
    arguments :: List (CallArgument phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (CallExpression phase) where
  sourceSpanOf expression = expression.sourceSpan

-- | @label = value@ in a call argument list
data CallArgument (phase :: Phase) = CallArgument
  { name :: Text,
    labelReference :: Reference phase LabelReference,
    value :: Expression phase,
    sourceSpan :: SourceSpan
  }

instance HasSourceSpan (CallArgument phase) where
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
  deriving stock (Eq, Show, Bounded, Enum)

data UnaryOperator where
  UnaryOperatorNegate :: UnaryOperator
  UnaryOperatorNot :: UnaryOperator
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
-- Each @next@ value becomes an element of the loop's mapped output array; the
-- optional @then@ clause receives that array.
data ForExpression (phase :: Phase) = ForExpression
  { parallel :: Bool,
    inBindings :: List (ForInBinding phase),
    varBindings :: List (VariableBinding phase),
    body :: Block phase,
    thenClause :: Maybe (ThenClause phase),
    sourceSpan :: SourceSpan,
    typeOf :: ExpressionType phase
  }

instance HasSourceSpan (ForExpression phase) where
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

-- | Bracket arguments parse uniformly as types; the typechecker splits them by
-- the callee's generic-parameter kinds and records the result in 'instantiation'.
data TypeApplicationExpression (phase :: Phase) = TypeApplicationExpression
  { callee :: Expression phase,
    typeArguments :: List (SyntacticType phase),
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
-- Phase retagging helpers
--
-- Identity transports between phases whose 'ReferenceResolution' agree
-- (Identified / Typed). Nodes carrying a phase-specific @typeOf@ are rebuilt
-- by each walker instead.
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

retagSyntacticType ::
  ( ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference
  ) =>
  SyntacticType phase1 ->
  SyntacticType phase2
retagSyntacticType = \case
  TypePrimitive node -> TypePrimitive node
  TypeNever sourceSpan -> TypeNever sourceSpan
  TypeUnknown sourceSpan -> TypeUnknown sourceSpan
  TypeName node ->
    TypeName
      TypeNameNode
        { name = node.name,
          typeReference = retagReference node.typeReference,
          sourceSpan = node.sourceSpan
        }
  TypeQualified node ->
    TypeQualified
      QualifiedTypeNode
        { moduleQualifier = retagModuleQualifier node.moduleQualifier,
          name = node.name,
          typeReference = retagReference node.typeReference,
          sourceSpan = node.sourceSpan
        }
  TypeAgent node ->
    TypeAgent
      AgentTypeNode
        { parameterType = retagSyntacticType node.parameterType,
          returnType = retagSyntacticType node.returnType,
          effects = retagSyntacticEffect <$> node.effects,
          sourceSpan = node.sourceSpan
        }
  TypeArray sourceSpan -> TypeArray sourceSpan
  TypeRecord sourceSpan -> TypeRecord sourceSpan
  TypeApplication node ->
    TypeApplication
      TypeApplicationTypeNode
        { applicationHead = retagSyntacticType node.applicationHead,
          applicationArguments = retagSyntacticType <$> node.applicationArguments,
          sourceSpan = node.sourceSpan
        }
  TypeTuple node ->
    TypeTuple
      TupleTypeNode
        { elementTypes = retagSyntacticType <$> node.elementTypes,
          sourceSpan = node.sourceSpan
        }
  TypeUnion node ->
    TypeUnion
      TypeUnionNode
        { branches = retagSyntacticType <$> node.branches,
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
        { baseType = retagSyntacticType node.baseType,
          attribute = retagSyntacticType node.attribute,
          sourceSpan = node.sourceSpan
        }
  TypeAttributeLiteral node -> TypeAttributeLiteral node

retagObjectTypeField ::
  ( ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference
  ) =>
  ObjectTypeField phase1 ->
  ObjectTypeField phase2
retagObjectTypeField field =
  ObjectTypeField
    { name = field.name,
      fieldType = retagSyntacticType field.fieldType,
      optional = field.optional,
      sourceSpan = field.sourceSpan
    }

retagSyntacticEffect ::
  ( ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference
  ) =>
  SyntacticEffect phase1 ->
  SyntacticEffect phase2
retagSyntacticEffect = \case
  EffectAll sourceSpan -> EffectAll sourceSpan
  EffectNamed node -> EffectNamed (retagNamedEffectNode node)
  EffectUnion node ->
    EffectUnion
      EffectUnionNode
        { branches = retagSyntacticEffect <$> node.branches,
          sourceSpan = node.sourceSpan
        }
  EffectOverride node ->
    EffectOverride
      OverrideEffectNode
        { base = retagSyntacticEffect node.base,
          overrides = retagNamedEffectNode <$> node.overrides,
          sourceSpan = node.sourceSpan
        }

retagNamedEffectNode ::
  ( ReferenceResolution phase1 TypeReference ~ ReferenceResolution phase2 TypeReference,
    ReferenceResolution phase1 ModuleReference ~ ReferenceResolution phase2 ModuleReference
  ) =>
  NamedEffectNode phase1 ->
  NamedEffectNode phase2
retagNamedEffectNode node =
  NamedEffectNode
    { moduleQualifier = retagModuleQualifier <$> node.moduleQualifier,
      name = node.name,
      typeReference = retagReference node.typeReference,
      arguments = retagSyntacticType <$> node.arguments,
      sourceSpan = node.sourceSpan
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
      upperBound = retagSyntacticType <$> parameter.upperBound,
      sourceSpan = parameter.sourceSpan
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
    Eq (GenericInstantiation phase),
    Eq (HandlerGenerics phase)
  ) =>
  EqPhase phase

instance
  ( Eq (ReferenceResolution phase VariableReference),
    Eq (ReferenceResolution phase TypeReference),
    Eq (ReferenceResolution phase ModuleReference),
    Eq (ReferenceResolution phase LabelReference),
    Eq (ExpressionType phase),
    Eq (PatternType phase),
    Eq (GenericInstantiation phase),
    Eq (HandlerGenerics phase)
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
    Show (GenericInstantiation phase),
    Show (HandlerGenerics phase)
  ) =>
  ShowPhase phase

instance
  ( Show (ReferenceResolution phase VariableReference),
    Show (ReferenceResolution phase TypeReference),
    Show (ReferenceResolution phase ModuleReference),
    Show (ReferenceResolution phase LabelReference),
    Show (ExpressionType phase),
    Show (PatternType phase),
    Show (GenericInstantiation phase),
    Show (HandlerGenerics phase)
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

deriving stock instance (EqPhase phase) => Eq (ParameterSignature phase)

deriving stock instance (ShowPhase phase) => Show (ParameterSignature phase)

deriving stock instance (EqPhase phase) => Eq (AgentDeclaration phase)

deriving stock instance (ShowPhase phase) => Show (AgentDeclaration phase)

deriving stock instance (EqPhase phase) => Eq (RequestDeclaration phase)

deriving stock instance (ShowPhase phase) => Show (RequestDeclaration phase)

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

deriving stock instance (EqPhase phase) => Eq (UseExpression phase)

deriving stock instance (ShowPhase phase) => Show (UseExpression phase)

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

deriving stock instance (EqPhase phase) => Eq (TypePattern phase)

deriving stock instance (ShowPhase phase) => Show (TypePattern phase)

deriving stock instance (EqPhase phase) => Eq (RecordPattern phase)

deriving stock instance (ShowPhase phase) => Show (RecordPattern phase)

deriving stock instance (EqPhase phase) => Eq (SyntacticType phase)

deriving stock instance (ShowPhase phase) => Show (SyntacticType phase)

deriving stock instance (EqPhase phase) => Eq (TypeNameNode phase)

deriving stock instance (ShowPhase phase) => Show (TypeNameNode phase)

deriving stock instance (EqPhase phase) => Eq (QualifiedTypeNode phase)

deriving stock instance (ShowPhase phase) => Show (QualifiedTypeNode phase)

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

deriving stock instance (EqPhase phase) => Eq (SyntacticEffect phase)

deriving stock instance (ShowPhase phase) => Show (SyntacticEffect phase)

deriving stock instance (EqPhase phase) => Eq (NamedEffectNode phase)

deriving stock instance (ShowPhase phase) => Show (NamedEffectNode phase)

deriving stock instance (EqPhase phase) => Eq (EffectUnionNode phase)

deriving stock instance (ShowPhase phase) => Show (EffectUnionNode phase)

deriving stock instance (EqPhase phase) => Eq (OverrideEffectNode phase)

deriving stock instance (ShowPhase phase) => Show (OverrideEffectNode phase)

deriving stock instance (EqPhase phase) => Eq (Expression phase)

deriving stock instance (ShowPhase phase) => Show (Expression phase)

deriving stock instance (EqPhase phase) => Eq (LiteralExpression phase)

deriving stock instance (ShowPhase phase) => Show (LiteralExpression phase)

deriving stock instance (EqPhase phase) => Eq (VariableExpression phase)

deriving stock instance (ShowPhase phase) => Show (VariableExpression phase)

deriving stock instance (EqPhase phase) => Eq (TupleExpression phase)

deriving stock instance (ShowPhase phase) => Show (TupleExpression phase)

deriving stock instance (EqPhase phase) => Eq (ParallelTupleExpression phase)

deriving stock instance (ShowPhase phase) => Show (ParallelTupleExpression phase)

deriving stock instance (EqPhase phase) => Eq (RecordExpression phase)

deriving stock instance (ShowPhase phase) => Show (RecordExpression phase)

deriving stock instance (EqPhase phase) => Eq (CallExpression phase)

deriving stock instance (ShowPhase phase) => Show (CallExpression phase)

deriving stock instance (EqPhase phase) => Eq (CallArgument phase)

deriving stock instance (ShowPhase phase) => Show (CallArgument phase)

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
