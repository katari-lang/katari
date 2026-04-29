-- | Stable identifiers used throughout the Katari compiler.
--
-- These newtypes are issued by the Identifier pass and live in the AST from
-- 'Identified' phase onward. They are split into a dedicated module so that
-- both 'Katari.AST' and 'Katari.Typechecker.SemanticType' can depend on them
-- without circular imports.
module Katari.AST.Identifiers
  ( VariableId (..),
    TypeId (..),
    ModuleId (..),
  )
where

-- | Unique id in the value namespace. Shared by agent / req / ext-agent /
-- constructor function / local variable.
newtype VariableId = VariableId Int
  deriving (Eq, Ord, Show)

-- | Unique id in the type namespace. Issued for data declarations and type
-- synonyms.
newtype TypeId = TypeId Int
  deriving (Eq, Ord, Show)

-- | Unique id in the module namespace.
newtype ModuleId = ModuleId Int
  deriving (Eq, Ord, Show)
