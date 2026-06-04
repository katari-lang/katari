-- | Identifiers used throughout the Katari compiler.
--
-- Top-level declarations are identified by 'QualifiedName' (the inter-module
-- identifier). Local variables (let bindings, parameters, for variables) are
-- identified by 'LocalVarId', a module-local counter that starts at 0 for
-- each module.
--
-- The 'VariableResolution' type captures this distinction at the AST level:
-- a resolved variable reference is either a top-level 'QualifiedName' or a
-- local 'LocalVarId'.
--
-- 'QualifiedName' / 'renderQualifiedName' live in 'Katari.Common' so the
-- IR can share them; they are re-exported here for convenience.
module Katari.Id
  ( -- * Variable resolution
    VariableResolution (..),
    LocalVarId (..),

    -- * Type resolution
    TypeResolution (..),

    -- * Effect resolution
    EffectResolution (..),

    -- * Generics
    GenericsId (..),

    -- * Re-exports from Common
    QualifiedName (..),
    renderQualifiedName,
  )
where

import Katari.Common (QualifiedName (..), renderQualifiedName)

-- | How a variable reference was resolved by the Identifier phase.
--
-- Top-level declarations (agent, data constructor, request, external) are
-- identified by their 'QualifiedName'. Local variables (let, parameter, for)
-- are identified by a 'LocalVarId' scoped to the enclosing module.
data VariableResolution
  = ResolvedTopLevel QualifiedName
  | ResolvedLocal LocalVarId
  deriving (Eq, Ord, Show)

-- | Module-local variable identifier. Issued by the Identifier phase for
-- local bindings (let, parameters, for variables). The counter starts at 0
-- for each module independently — no global state is needed.
newtype LocalVarId = LocalVarId Int
  deriving (Eq, Ord, Show)

-- | How a /type/ reference (a 'Katari.AST.TypeRef' name) was resolved by the
-- Identifier phase.
--
--   * 'ResolvedNamedType' — a top-level @data@ type or type synonym.
--   * 'ResolvedGenericParam' — a generic parameter (type /or/ effect kind) in
--     scope, identified by its 'GenericsId'.
--   * 'ResolvedRequestName' — a @req@ name. Only meaningful when the reference
--     appears in an effect-argument position of a generic application
--     (@foo[..., req_a | req_b]@), where the same bare-name syntax that the
--     parser reads as a type is reinterpreted as an effect by the checker.
data TypeResolution
  = ResolvedNamedType QualifiedName
  | ResolvedGenericParam GenericsId
  | ResolvedRequestName QualifiedName
  | -- | An @effect@ generic parameter appearing in a type-ish position (an
    -- effect argument of a generic application, e.g. @foo[E]@). Like
    -- 'ResolvedRequestName' it denotes an effect, rejected in an ordinary type
    -- position.
    ResolvedEffectGenericName GenericsId
  deriving (Eq, Ord, Show)

-- | How an /effect/ reference (a @with@-clause leaf — a
-- 'Katari.AST.RequestRef' name) was resolved by the Identifier phase.
--
--   * 'ResolvedConcreteRequest' — a concrete @req@ declaration.
--   * 'ResolvedEffectGeneric' — an in-scope @effect@ generic parameter,
--     identified by its 'GenericsId'.
data EffectResolution
  = ResolvedConcreteRequest QualifiedName
  | ResolvedEffectGeneric GenericsId
  deriving (Eq, Ord, Show)

-- | Module-local generic-parameter identifier. Issued by the Identifier phase
-- for each declared generic parameter (@[T extends t, effect R]@). Like
-- 'LocalVarId', the counter is per-module; no global state is needed. Used by
-- later phases to dispatch on a specific generic parameter
-- ('Katari.SemanticType.SemanticTypeGeneric' / the @genericsLayer@ in the
-- normalized form) without relying on its surface name.
newtype GenericsId = GenericsId Int
  deriving (Eq, Ord, Show)
