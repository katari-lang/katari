-- | Stable identifiers used throughout the Katari compiler.
--
-- These newtypes are issued by the Identifier pass and live in the AST from
-- 'Identified' phase onward. They are split into a dedicated module so that
-- both 'Katari.AST' and 'Katari.Typechecker.SemanticType' can depend on them
-- without circular imports.
--
-- 'QualifiedName' / 'renderQualifiedName' live in 'Katari.Common' so the
-- IR can share them; they are re-exported here for convenience.
module Katari.Id
  ( VariableId (..),
    TypeId (..),
    ModuleId (..),
    RequestId (..),
    ConstructorId (..),
    QualifiedName (..),
    renderQualifiedName,
  )
where

import Katari.Common (QualifiedName (..), renderQualifiedName)

-- | Unique id in the value namespace. Shared by agent / req / ext-agent /
-- constructor function / local variable. (\"value\" here means a name that
-- can appear on the right-hand side of an expression as a callable / read.)
newtype VariableId = VariableId Int
  deriving (Eq, Ord, Show)

-- | Unique id in the type namespace. Issued for data declarations and type
-- synonyms.
newtype TypeId = TypeId Int
  deriving (Eq, Ord, Show)

-- | Unique id in the module namespace.
newtype ModuleId = ModuleId Int
  deriving (Eq, Ord, Show)

-- | Unique id in the request namespace. Issued for @req@ declarations only.
-- Used to identify the target of @req@ handlers and the elements of request
-- sets, separately from 'VariableId' which covers the call-as-a-function
-- side of the same declaration.
newtype RequestId = RequestId Int
  deriving (Eq, Ord, Show)

-- | Unique id in the data-constructor namespace. Issued for @data@
-- declarations only. Used to identify the constructor of a @match@ arm
-- pattern, separately from 'VariableId' (callable side) and 'TypeId' (type
-- side) of the same declaration.
newtype ConstructorId = ConstructorId Int
  deriving (Eq, Ord, Show)
