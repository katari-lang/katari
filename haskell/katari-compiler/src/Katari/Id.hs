-- | Stable identifiers used throughout the Katari compiler.
--
-- These newtypes are issued by the Identifier pass and live in the AST from
-- 'Identified' phase onward. They are split into a dedicated module so that
-- both 'Katari.AST' and 'Katari.Typechecker.SemanticType' can depend on them
-- without circular imports.
module Katari.Id where

import Data.Aeson (FromJSON, FromJSONKey, ToJSON, ToJSONKey)
import Data.Text (Text)
import GHC.Generics (Generic)

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

-- | A top-level declaration's fully qualified name: the dotted module path
-- plus the bare name. Local variables (let / pattern bind / param) do not
-- carry a 'QualifiedName' (they live inside a scope and have no addressable
-- identity outside it).
--
-- The structured form (rather than a single 'Text') keeps the components
-- queryable inside the compiler; render to dotted form via
-- 'renderQualifiedName' at FFI / debug boundaries.
data QualifiedName = QualifiedName
  { module_ :: Text,
    name :: Text
  }
  deriving (Eq, Ord, Show, Generic)

instance ToJSON QualifiedName

instance FromJSON QualifiedName

instance ToJSONKey QualifiedName

instance FromJSONKey QualifiedName

-- | Join a 'QualifiedName' into its dotted form @\"path.to.mod.name\"@.
-- Handles the empty-module-path edge case (which should not occur in
-- well-formed sources) by emitting just the bare name.
renderQualifiedName :: QualifiedName -> Text
renderQualifiedName q = q.module_ <> "." <> q.name
