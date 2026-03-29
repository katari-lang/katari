{- | Internal type representation for the Qatali type system.

This module defines the /un-normalized/ type language used during
type checking.  After normalization (see "QataliCompiler.Type.NormalizedEffect"),
types are in a canonical form suitable for subtype comparison.

Key design decisions:
  * Subtyping with union\/intersection (no HM unification)
  * Literal types: @1 <: integer <: number@
  * Effect is a separate type from Type
  * Generics are first-order only (always fully applied at use site)
-}
module QataliCompiler.Type.Type (
    -- * Primitive types
    PrimType (..),
    LitType (..),

    -- * Variance & bounds
    Variance (..),
    Bound (..),
    TypeParam (..),
    DataTypeParam (..),

    -- * Effect
    Effect (..),

    -- * Types
    Type (..),
    FunParam (..),

    -- * Type variable abstraction
    TypeVar (..),
    TyVarKind,
    UnknownVarKind,

    -- * Generic variable utilities
    freeVarsOf,
    effectFreeVarsOf,
    substituteVarsOf,
    containsVarOf,

    -- * Type variable utilities (convenience)
    containsTVar,
    typeVarNames,
    substituteTVars,

    -- * Unknown variable utilities (convenience)
    containsUnknownVar,
    unknownVarNames,
    substituteUnknownVars,

    -- * Display
    showType,
    showPrim,
    showLit,
) where

import           Data.Map.Strict     (Map)
import qualified Data.Map.Strict     as Map
import           Data.Proxy          (Proxy (..))
import           Data.Set            (Set)
import qualified Data.Set            as Set
import           Data.Text           (Text)
import qualified Data.Text           as T
import           QataliCompiler.Name (Name (..))

-- ---------------------------------------------------------------------------
-- Primitive types

-- | Built-in primitive types (JSON Schema vocabulary).
data PrimType
    = PrimInteger    -- ^ integer (subtype of number)
    | PrimNumber     -- ^ number  (includes integer and float)
    | PrimString     -- ^ string
    | PrimBoolean    -- ^ boolean
    | PrimNull       -- ^ null
    deriving (Eq, Ord, Show)

-- | Literal types — singleton types for concrete values.
data LitType
    = LitIntegerType !Integer   -- ^ e.g. @1@, @42@
    | LitNumberType  !Double    -- ^ e.g. @2.5@, @3.14@
    | LitStringType  !Text      -- ^ e.g. @"hello"@
    | LitBooleanType !Bool      -- ^ @true@ or @false@
    deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Variance & bounds

-- | Variance annotation — used exclusively in data declarations.
data Variance
    = Covariant      -- ^ @out@
    | Contravariant  -- ^ @in@
    | Bivariant      -- ^ (none)
    | Invariant      -- ^ @in out@
    deriving (Eq, Ord, Show)

-- | Generics bound — constrains a type parameter.
data Bound
    = BoundSub  !Type   -- ^ @T sub U@  (T <: U, upper bound)
    | BoundSup  !Type   -- ^ @T sup U@  (T :> U, lower bound)
    | BoundIs   !Type   -- ^ @T is U@   (T = U, exact)
    | BoundNone         -- ^ no bound   (equivalent to @sub unknown@)
    deriving (Eq, Ord, Show)

-- | A generic type parameter: name + bound.  No variance (that belongs to data decls).
data TypeParam = TypeParam
    { tpName  :: !Name
    , tpBound :: !Bound
    }
    deriving (Eq, Ord, Show)

-- | A data declaration's type-argument slot: only variance.  Name is not needed
-- in the internal representation (arity is implied by list length).
newtype DataTypeParam = DataTypeParam
    { dtpVariance :: Variance
    }
    deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Effect

{- | Effect type — separate from 'Type'.

Effects describe the side-effects a function may perform.
They form their own lattice: @EffPure <: any single effect <: EffImpure@.
-}
data Effect
    = EffPure                      -- ^ No effect (bottom of effects)
    | EffSingle !Name ![Type]      -- ^ A single named effect, e.g. @Log<string>@
    | EffUnion  ![Effect]          -- ^ Union of effects, e.g. @Log<T> | Ask<T,R>@
                                   --   Normalized form: flat list of 'EffSingle'.
    | EffImpure                    -- ^ Any effect (top of effects)
    | EffVar    !Name              -- ^ Effect variable (from generics)
    deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Types

{- | The un-normalized type language.

These types correspond closely to what the user writes in source code
(after name resolution).  They may contain 'TUnion' and 'TIntersection'
which are eliminated during normalization.
-}
data Type
    = TUnknown                          -- ^ @unknown@ — top type
    | TNever                            -- ^ @never@   — bottom type
    | TPrim         !PrimType           -- ^ Primitive: integer, number, string, boolean, null
    | TLit          !LitType            -- ^ Literal type: @1@, @"hello"@, @true@
    | TArray        !Type               -- ^ Array type: @Array\<T\>@
    | TFun          ![FunParam] !Type !Effect
                                        -- ^ Function: @(params) => RetTy with Effect@
    | TData         !Name ![Type]       -- ^ Applied data type: @Failure\<string\>@
    | TUnion        !Type !Type         -- ^ Union: @A | B@
    | TIntersection !Type !Type         -- ^ Intersection: @A & B@
    | TVar          !Name               -- ^ Type variable (from generics)
    | TUnknownVar   !Name               -- ^ Unknown variable (solver-introduced)
    deriving (Eq, Ord, Show)

-- | A named function parameter with its type.
data FunParam = FunParam
    { fpName :: !Name
    , fpType :: !Type
    }
    deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Type variable abstraction

-- | Type class abstracting over the two kinds of type variables
-- (user-introduced 'TVar' vs solver-introduced 'TUnknownVar').
class TypeVar v where
    -- | Extract a variable name from a type, if it matches this kind.
    extractVar :: Proxy v -> Type -> Maybe Name
    -- | Construct a type variable of this kind from a name.
    injectVar  :: Proxy v -> Name -> Type

-- | Phantom type tag for user-introduced type variables ('TVar').
data TyVarKind

-- | Phantom type tag for solver-introduced unknown variables ('TUnknownVar').
data UnknownVarKind

instance TypeVar TyVarKind where
    extractVar _ (TVar n) = Just n
    extractVar _ _        = Nothing
    injectVar _ = TVar

instance TypeVar UnknownVarKind where
    extractVar _ (TUnknownVar n) = Just n
    extractVar _ _               = Nothing
    injectVar _ = TUnknownVar

-- ---------------------------------------------------------------------------
-- Generic variable utilities

-- | Collect all variable names of a given kind occurring in a type.
freeVarsOf :: forall v. TypeVar v => Proxy v -> Type -> Set Name
freeVarsOf p = go
  where
    go ty = case extractVar p ty of
        Just n  -> Set.singleton n
        Nothing -> case ty of
            TArray t          -> go t
            TFun params ret eff ->
                foldMap (go . fpType) params <> go ret <> effectFreeVarsOf p eff
            TData _ args      -> foldMap go args
            TUnion a b        -> go a <> go b
            TIntersection a b -> go a <> go b
            _                 -> Set.empty  -- TUnknown, TNever, TPrim, TLit, other var kind

-- | Collect variable names of a given kind from an effect.
effectFreeVarsOf :: forall v. TypeVar v => Proxy v -> Effect -> Set Name
effectFreeVarsOf p = \case
    EffPure          -> Set.empty
    EffSingle _ args -> foldMap (freeVarsOf p) args
    EffUnion effs    -> foldMap (effectFreeVarsOf p) effs
    EffImpure        -> Set.empty
    EffVar _         -> Set.empty

-- | Substitute variables of a given kind using a mapping.
substituteVarsOf :: forall v. TypeVar v => Proxy v -> Map Name Type -> Type -> Type
substituteVarsOf p subst = go
  where
    go ty = case extractVar p ty of
        Just n  -> Map.findWithDefault (injectVar p n) n subst
        Nothing -> case ty of
            TArray t -> TArray (go t)
            TFun params ret eff ->
                TFun (map (\fp -> fp { fpType = go (fpType fp) }) params)
                     (go ret) (goEff eff)
            TData name args -> TData name (map go args)
            TUnion a b -> TUnion (go a) (go b)
            TIntersection a b -> TIntersection (go a) (go b)
            other -> other  -- TUnknown, TNever, TPrim, TLit, other var kind

    goEff = \case
        EffPure -> EffPure
        EffImpure -> EffImpure
        EffSingle name args -> EffSingle name (map go args)
        EffUnion effs -> EffUnion (map goEff effs)
        EffVar n -> EffVar n

-- | Does the type contain any variable of the given kind?
containsVarOf :: forall v. TypeVar v => Proxy v -> Type -> Bool
containsVarOf p = not . Set.null . freeVarsOf p

-- ---------------------------------------------------------------------------
-- Convenience wrappers (type variable)

-- | Does the type contain any TVar?
containsTVar :: Type -> Bool
containsTVar = containsVarOf (Proxy :: Proxy TyVarKind)

-- | Collect all type variable names occurring in a type.
typeVarNames :: Type -> Set Name
typeVarNames = freeVarsOf (Proxy :: Proxy TyVarKind)

-- | Substitute type variables using a mapping.
substituteTVars :: Map Name Type -> Type -> Type
substituteTVars = substituteVarsOf (Proxy :: Proxy TyVarKind)

-- ---------------------------------------------------------------------------
-- Convenience wrappers (unknown variable)

-- | Does the type contain any TUnknownVar?
containsUnknownVar :: Type -> Bool
containsUnknownVar = containsVarOf (Proxy :: Proxy UnknownVarKind)

-- | Collect all unknown variable names occurring in a type.
unknownVarNames :: Type -> Set Name
unknownVarNames = freeVarsOf (Proxy :: Proxy UnknownVarKind)

-- | Substitute unknown variables using a mapping.
substituteUnknownVars :: Map Name Type -> Type -> Type
substituteUnknownVars = substituteVarsOf (Proxy :: Proxy UnknownVarKind)

-- ---------------------------------------------------------------------------
-- Display

-- | Simple type display for error messages.
showType :: Type -> Text
showType = \case
    TUnknown       -> "unknown"
    TNever         -> "never"
    TPrim p        -> showPrim p
    TLit l         -> showLit l
    TVar n         -> unName n
    TUnknownVar n  -> "?" <> unName n
    TArray t       -> "Array<" <> showType t <> ">"
    TFun _ ret _   -> "(...) => " <> showType ret
    TData n args   -> unName n <> if null args then "" else "<" <> T.intercalate ", " (map showType args) <> ">"
    TUnion a b     -> showType a <> " | " <> showType b
    TIntersection a b -> showType a <> " & " <> showType b

showPrim :: PrimType -> Text
showPrim = \case
    PrimInteger -> "integer"
    PrimNumber  -> "number"
    PrimString  -> "string"
    PrimBoolean -> "boolean"
    PrimNull    -> "null"

showLit :: LitType -> Text
showLit = \case
    LitIntegerType n -> T.pack (show n)
    LitNumberType d  -> T.pack (show d)
    LitStringType s  -> "\"" <> s <> "\""
    LitBooleanType b -> if b then "true" else "false"

