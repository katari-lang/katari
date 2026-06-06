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
-- bidirectional type checker.
module Katari.SemanticType where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Katari.Common (QualifiedName (..))
import Katari.Id (GenericsId)

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
  -- Composite types. A function's parameter signature is a /single/
  -- 'SemanticType' — the type of the argument record. The type system places
  -- no constraint on what it is (object / tuple / never / unknown all type),
  -- but the surface language only ever constructs an object there: a call
  -- @foo(l1=e1, l2=e2)@ builds the object @{l1=e1, l2=e2}@ and requires it to
  -- be a subtype of the parameter type, and a definition @agent foo(l1: T1)@
  -- elaborates the parameter type to the object @{l1: T1}@. (Spread —
  -- @foo(...obj: ObjType)@ / @foo(...[1,\"x\"])@ — is what lets a tuple etc.
  -- actually reach the parameter slot.) Two functions are equal when their
  -- parameter type, return, and effects all match.
  SemanticTypeFunction ::
    SemanticType phase ->
    SemanticType phase ->
    SemanticEffect phase ->
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
  -- | Reference to a @data@ declaration.
  SemanticTypeData :: QualifiedName -> SemanticType phase
  -- | An in-scope generic type parameter, identified by its 'GenericsId'.
  -- Abstract during the checking of a generic declaration's body (bounded
  -- above by its @extends@ clause); replaced by a concrete type at every
  -- instantiation site (@foo[int]@). Normalises to the @genericsLayer@.
  SemanticTypeGeneric :: GenericsId -> SemanticType phase
  -- | Structural object type with named fields. Not surfaced in the
  -- syntactic AST: produced by the checker for structural "has field"
  -- constraints (e.g. field access on data values is encoded as
  -- @T \<: SemanticTypeObject {label: t_field}@). Convertible to / from
  -- JSON schema style records.
  SemanticTypeObject :: Map Text (Parameter phase) -> SemanticType phase
  -- | @record@ — the homogeneous-map top: any map value (object / data /
  -- record), keys @string@, reads yield @unknown@. Nullary (no element type):
  -- @object \<: record@ is always sound because @record@ is the top of the map
  -- layer. Distinct from 'SemanticTypeObject' (= statically-known field labels)
  -- — a @record@ has a runtime-dynamic key set. A typed dictionary is a generic
  -- @data@ instead. See docs/2026-06-06-generic-data-record-variance.md.
  SemanticTypeRecord :: SemanticType phase

deriving instance Show (SemanticType phase)

deriving instance Eq (SemanticType phase)

deriving instance Ord (SemanticType phase)

-- | A single function parameter — /and/ a structural object field: its type
-- plus whether it is optional (a parameter with a default, hence omittable at
-- call sites; an object field that may be absent — accessing an absent
-- optional field yields @null@). Function parameter signatures and object types
-- share this record because a parameter signature is, semantically, an object.
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

-- | Build a function type from a /labelled-parameter map/ by wrapping it in
-- the parameter object. Most construction sites (agent / request / external /
-- prim signatures, call-site argument records) think in terms of named
-- parameters; this hides the \"parameter type is a single object\" encoding.
functionType ::
  Map Text (Parameter phase) ->
  SemanticType phase ->
  SemanticEffect phase ->
  SemanticType phase
functionType parameters = SemanticTypeFunction (SemanticTypeObject parameters)

-- | Extract the labelled-parameter map from a function's parameter type,
-- assuming the object encoding. Returns the fields when the parameter type is
-- an object; for any other parameter type (tuple / never / unknown — reachable
-- only via spread) there are no named parameters, so the empty map is returned.
functionParameters :: SemanticType phase -> Map Text (Parameter phase)
functionParameters = \case
  SemanticTypeObject fields -> fields
  _ -> Map.empty

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
-- Effects
-- ---------------------------------------------------------------------------

-- | An /effect expression/: the tree of @req@ effects an expression may raise,
-- mirroring the surface @with@ syntax (@a | b | (c | d)@). Like 'SemanticType'
-- (which keeps the un-normalised 'SemanticTypeUnion' tree rather than a
-- canonical set), 'SemanticEffect' is the syntax-faithful describing form;
-- 'Katari.Typechecker.NormalizedType' flattens it to a 'Set' for the lattice.
-- The @phase@ parameter is a vestigial phantom (only @Resolved@ exists).
--
-- Once generics land, an effect-generic variable becomes another leaf of this
-- tree (alongside 'SemanticEffectRequest').
data SemanticEffect phase where
  -- | The pure (no-effect) leaf — the surface @pure@. Like 'SemanticTypeNever'
  -- for types, it is the canonical empty effect: it appears in 'SemanticEffect'
  -- (so @with pure@ round-trips) but flattens to the empty 'Set' in the
  -- normalised form. 'unionEffects' drops it from non-empty unions.
  SemanticEffectPure :: SemanticEffect phase
  -- | A single concrete @req@ effect, by its qualified name.
  SemanticEffectRequest :: QualifiedName -> SemanticEffect phase
  -- | An in-scope @effect@ generic parameter, by its 'GenericsId'. Abstract
  -- while checking a generic declaration's body; replaced by a concrete effect
  -- at every instantiation site.
  SemanticEffectGeneric :: GenericsId -> SemanticEffect phase
  -- | Union of effects (@e1 | e2 | ...@). Convention: 2+ leaf branches (a
  -- singleton flattens to its branch, an empty union collapses to
  -- 'SemanticEffectPure'). Always build via 'unionEffects' to maintain this.
  SemanticEffectUnion :: [SemanticEffect phase] -> SemanticEffect phase

deriving instance Show (SemanticEffect phase)

deriving instance Eq (SemanticEffect phase)

deriving instance Ord (SemanticEffect phase)

-- | The empty (pure) effect — \"this expression performs no request\". The
-- canonical empty effect (cf. 'SemanticTypeNever'); identity for 'unionEffect'.
emptyEffect :: SemanticEffect phase
emptyEffect = SemanticEffectPure

-- | An effect containing exactly one concrete request.
singletonEffect :: QualifiedName -> SemanticEffect phase
singletonEffect = SemanticEffectRequest

-- | Smart union over effect trees: flattens nested unions and drops
-- 'SemanticEffectPure' leaves, so the result is a single top-level union of
-- non-pure leaves — collapsing a singleton to its branch and an empty result
-- to 'SemanticEffectPure'. (Deduplication is left to normalisation — the tree
-- stays faithful to what was written.)
unionEffects :: [SemanticEffect phase] -> SemanticEffect phase
unionEffects effects = case concatMap flatten effects of
  [] -> SemanticEffectPure
  [single] -> single
  flat -> SemanticEffectUnion flat
  where
    flatten = \case
      SemanticEffectPure -> []
      SemanticEffectUnion branches -> concatMap flatten branches
      leaf -> [leaf]

-- | Binary union of two effect trees (@e1 | e2@). Combines the request sets of
-- subexpressions (@e1 + e2@'s effects = @e1@'s ∪ @e2@'s).
unionEffect :: SemanticEffect phase -> SemanticEffect phase -> SemanticEffect phase
unionEffect leftEffect rightEffect = unionEffects [leftEffect, rightEffect]
