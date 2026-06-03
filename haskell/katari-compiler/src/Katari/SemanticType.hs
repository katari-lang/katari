-- | Semantic type representation for the Katari typechecker.
--
-- 'SemanticType' carries a vestigial @phase@ tag (only @Resolved@ exists now —
-- the bidirectional checker never introduces unification variables). A value is
-- therefore always fully resolved.
--
-- This is a separate data type from 'Katari.AST.SyntacticType': the AST
-- captures user-written syntax (e.g. type names, qualified references, type
-- synonyms) while @SemanticType@ captures the actual type meaning after
-- elaboration. Type synonyms are expanded transparently — they do not
-- appear in @SemanticType@.
--
-- This module has no dependency on 'Katari.AST'. The 'ExpressionType' / 'PatternType'
-- closed type families in 'Katari.AST' reference 'SemanticType' directly.
--
-- 'NormalizedType' (see 'Katari.Typechecker.NormalizedType') is yet another
-- representation that further normalises union / tuple shapes for use by the
-- constraint solver.
module Katari.SemanticType where

import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Common (QualifiedName (..))

-- ---------------------------------------------------------------------------
-- Phase markers
-- ---------------------------------------------------------------------------

-- | Phase tag for fully-resolved @SemanticType@ values. The bidirectional
-- checker produces these directly, so it is the only phase that exists now
-- (the @phase@ parameter is retained as a vestigial single-inhabitant tag).
type data Resolved

-- ---------------------------------------------------------------------------
-- Semantic types
-- ---------------------------------------------------------------------------

-- | Semantic type. Every value is fully resolved (no unification variables —
-- the checker never introduces any).
data SemanticType phase where
  -- | Lattice bottom: no values inhabit this type.
  SemanticTypeNever :: SemanticType phase
  -- | Lattice top: any value satisfies this type.
  SemanticTypeUnknown :: SemanticType phase
  -- Primitive (concrete) types.
  SemanticTypeNull :: SemanticType phase
  SemanticTypeInteger :: SemanticType phase
  SemanticTypeNumber :: SemanticType phase
  SemanticTypeString :: SemanticType phase
  -- | Opaque credential string. Disjoint from 'SemanticTypeString'
  -- (no subtype relation). Values flow into runtime only via env-bound
  -- ext agents (e.g. @get_secret_env@); they propagate transparently
  -- through f-string interpolation (the @fstring_join@ prim rule taints
  -- the result type with @secret@), but cannot be printed, compared,
  -- pattern-matched, or downcast to @string@. The runtime stores the
  -- value as a string but treats the wrapper as a separate Value
  -- variant for boundary-crossing concerns (redaction in logs,
  -- AES encryption in DB persistence).
  SemanticTypeSecret :: SemanticType phase
  -- | Opaque byte sequence (@file@). Disjoint from 'SemanticTypeString'
  -- (no subtype relation). Identity-typed: @file == file@ compares
  -- reference identity, not content. Has no literals (cannot be pattern-
  -- matched against a value). The runtime represents it as a value
  -- reference (always a blob ref); the value model never inlines it.
  SemanticTypeFile :: SemanticType phase
  SemanticTypeBoolean :: SemanticType phase
  -- Literal types: a singleton type containing exactly one value.
  SemanticTypeLiteralInteger :: Integer -> SemanticType phase
  SemanticTypeLiteralString :: Text -> SemanticType phase
  SemanticTypeLiteralBoolean :: Bool -> SemanticType phase
  -- Composite types. Function parameters are keyed by label; their order is
  -- not significant (named-parameter calling convention). Each 'Parameter'
  -- carries its type and whether it is /optional/ (declared with a default):
  -- a call site may omit an optional parameter — the runtime fills the
  -- declared default — so the subtype rule does not demand it. Two functions
  -- are equal when their parameters (type + optionality), return, and
  -- effects all match.
  SemanticTypeFunction ::
    Map Text (Parameter phase) ->
    SemanticType phase ->
    SemanticRequest phase ->
    SemanticType phase
  -- | Top of the function-type lattice: any callable
  -- ('SemanticTypeFunction' with any params/return/effects) is a subtype.
  -- Callers can pass values typed as concrete functions to APIs expecting
  -- @function@ (e.g. @get_metadata(value: function)@) but cannot @call@
  -- a value typed at 'SemanticTypeFunctionAny' because the parameter
  -- shape is unknown. Used by reflection-style prims.
  SemanticTypeFunctionAny :: SemanticType phase
  SemanticTypeArray :: SemanticType phase -> SemanticType phase
  SemanticTypeTuple :: [SemanticType phase] -> SemanticType phase
  -- | Union of types. Convention: 0 or 2+ branches.
  SemanticTypeUnion :: [SemanticType phase] -> SemanticType phase
  -- | Reference to a @data@ declaration. Generics are not supported, so no
  -- parameter list.
  SemanticTypeData :: QualifiedName -> SemanticType phase
  -- | Structural object type with named fields. Not surfaced in the
  -- syntactic AST: synthesised by the constraint generator for "has field"
  -- constraints (e.g. field access on data values is encoded as
  -- @T \<: SemanticTypeObject {label: t_field}@). Convertible to / from
  -- JSON schema style records.
  SemanticTypeObject :: Map Text (SemanticType phase) -> SemanticType phase
  -- | @record[V]@ — homogeneous map from string keys to values of
  -- type @V@. Keys are implicitly @string@ because the wire form is
  -- plain JSON object syntax and JSON object keys are always
  -- strings. Distinct from 'SemanticTypeObject' (= statically-known
  -- field labels) — a @record@ has a runtime-dynamic key set.
  SemanticTypeRecord :: SemanticType phase -> SemanticType phase

deriving instance Show (SemanticType phase)

deriving instance Eq (SemanticType phase)

deriving instance Ord (SemanticType phase)

-- | A single function parameter: its type plus whether it is optional
-- (declared with a default, hence omittable at call sites). Folding
-- optionality into the parameter map (rather than a parallel label set)
-- keeps the invariant "every optional label has a type" by construction.
data Parameter phase = Parameter
  { parameterType :: SemanticType phase,
    optional :: Bool
  }

deriving instance Show (Parameter phase)

deriving instance Eq (Parameter phase)

deriving instance Ord (Parameter phase)

-- | A required (non-optional) parameter — the common case for synthesised
-- function types (call-site argument signatures, agent-type annotations,
-- constructor signatures) where optionality does not arise.
requiredParameter :: SemanticType phase -> Parameter phase
requiredParameter parameterType = Parameter {parameterType = parameterType, optional = False}

-- | Smart constructor for 'SemanticTypeUnion'. The convention is that a
-- union always has 0 or 2+ branches; a singleton list is flattened to its
-- contained type, and an empty list collapses to 'SemanticTypeNever' (the
-- bottom of the lattice). Always prefer this helper over the raw
-- 'SemanticTypeUnion' constructor when the branch count is computed
-- dynamically (e.g. after @nub@ or filtering).
unionSemantic :: [SemanticType phase] -> SemanticType phase
unionSemantic = \case
  [] -> SemanticTypeNever
  [single] -> single
  branches -> SemanticTypeUnion branches

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

-- | An request set is the disjoint sum of "request type variables that have
-- not yet been resolved" and "concrete @req@ VariableIds that have already
-- been pinned down". Subtyping on requests is just set inclusion on both
-- components.
--
-- The @phase@ parameter is phantom: at @Resolved@ phase the
-- 'requestVars' field is required to be empty (the solver enforces this when
-- zonking), but the type system does not enforce it. Keeping the same
-- representation across phases lets the same operations (union, equality)
-- work without case splits.
data SemanticRequest phase where
  SemanticRequest :: Set (SemanticRequestElement phase) -> SemanticRequest phase

deriving instance Show (SemanticRequest phase)

deriving instance Eq (SemanticRequest phase)

deriving instance Ord (SemanticRequest phase)

-- | One member of a 'SemanticRequest' set: a concrete element pointing at a
-- specific @req@ declaration by its 'QualifiedName'.
data SemanticRequestElement phase where
  SemanticRequestElementConcrete :: QualifiedName -> SemanticRequestElement phase

deriving instance Show (SemanticRequestElement phase)

deriving instance Eq (SemanticRequestElement phase)

deriving instance Ord (SemanticRequestElement phase)

-- | The empty request set. Represents \"this expression performs no
-- request\". Identity for 'unionRequests'.
emptyRequest :: SemanticRequest phase
emptyRequest = SemanticRequest Set.empty

-- | A request set containing exactly one concrete request. Used when
-- the constraint generator records that a particular call site triggers
-- a specific declared @req@.
singletonRequest :: QualifiedName -> SemanticRequest phase
singletonRequest requestId = SemanticRequest (Set.singleton (SemanticRequestElementConcrete requestId))

-- | Set union over request elements. Used to combine the request sets
-- of subexpressions (@e1 + e2@'s requests = @e1@'s ∪ @e2@'s).
unionRequests :: SemanticRequest phase -> SemanticRequest phase -> SemanticRequest phase
unionRequests (SemanticRequest elements1) (SemanticRequest elements2) =
  SemanticRequest (Set.union elements1 elements2)
