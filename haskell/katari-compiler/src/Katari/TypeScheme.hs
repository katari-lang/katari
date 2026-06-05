-- | A callable's type /scheme/: its body type plus the generic parameters it
-- quantifies over. This unifies what used to be two parallel maps — the type
-- environment and a separate generic-parameter map — into one value, so the
-- generics travel /with/ the type (within a module, across SCCs, and across
-- module boundaries via 'Katari.Typechecker.ModuleInterface').
--
-- A non-generic callable (and every @let@ / parameter binding) is a
-- 'monoScheme' — empty quantifiers. A generic callable carries one quantifier
-- per @[T]@ / @[effect E]@ parameter: its 'GenericsId', its 'GenericKind', and
-- the elaborated @extends@ bound. The body type mentions those ids through
-- 'Katari.SemanticType.SemanticTypeGeneric' / @SemanticEffectGeneric@ nodes;
-- instantiating @foo[args]@ substitutes them.
module Katari.TypeScheme
  ( TypeScheme (..),
    monoScheme,
    isGeneric,
  )
where

import Katari.AST (GenericKind)
import Katari.Id (GenericsId)
import Katari.SemanticType (Resolved, SemanticType)

-- | A type plus the generic parameters it quantifies over.
data TypeScheme = TypeScheme
  { -- | One entry per generic parameter, in declaration order: its id, kind
    -- (type / effect), and elaborated @extends@ bound (@unknown@ by default).
    -- Empty for a non-generic callable.
    schemeQuantifiers :: [(GenericsId, GenericKind, SemanticType Resolved)],
    -- | The callable's type, with the quantified ids appearing as
    -- @SemanticTypeGeneric@ / @SemanticEffectGeneric@ nodes.
    schemeBody :: SemanticType Resolved
  }
  deriving (Eq, Show)

-- | The scheme of a non-generic type (no quantifiers).
monoScheme :: SemanticType Resolved -> TypeScheme
monoScheme = TypeScheme []

-- | Does this scheme quantify any generic parameters (so a bare reference must
-- be instantiated with @[args]@)?
isGeneric :: TypeScheme -> Bool
isGeneric scheme = not (null scheme.schemeQuantifiers)
