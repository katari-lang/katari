-- | Phase-independent value types shared between the AST and the IR.
--
-- 'Katari.Common' sits at the same layer as 'Katari.SourceSpan' / 'Katari.Id':
-- it is imported by both 'Katari.AST' and 'Katari.IR' and depends on neither.
-- Until this module existed, 'QualifiedName' and 'LiteralValue' had two
-- definitions each (one per layer), which made them noisy in @grep@ and
-- IDE completion. The IR's flavour wins for both: structured record fields
-- and JSON tagged-object encoding, which is what the runtime actually
-- consumes.
module Katari.Common
  ( -- * Qualified names
    QualifiedName (..),
    renderQualifiedName,
    parseQualifiedName,

    -- * Literal values
    LiteralValue (..),

    -- * Pattern tags
    TypePatternTag (..),

    -- * Aeson helpers
    lowerHead,
  )
where

import Data.Aeson
  ( FromJSON (..),
    FromJSONKey (..),
    Options (..),
    SumEncoding (..),
    ToJSON (..),
    ToJSONKey (..),
    defaultOptions,
    genericParseJSON,
    genericToJSON,
    withText,
  )
import Data.Aeson.Types (FromJSONKeyFunction (..), toJSONKeyText)
import Data.Char (toLower)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

-- | A top-level declaration's qualified name (@\<modulePath\>.\<bareName\>@
-- as the canonical pair). Used as the FFI-boundary identifier in
-- 'Katari.IR.IRModule.entries' so that JS / external callers can address
-- a callable without depending on the IR's internal id allocation.
data QualifiedName = QualifiedName
  { module_ :: Text,
    name :: Text
  }
  deriving (Eq, Ord, Show, Generic)

-- | Wire format: flat dotted string @\"module.name\"@ (or @\"name\"@ when
-- the module is empty). The runtime / FFI / REST API all consume this
-- form, so wrapping a qname in JSON has minimal overhead and the wire is
-- @grep@-friendly. Pattern matching on the Haskell side still uses the
-- record fields directly — the JSON instance is the only thing that
-- flattens.
instance ToJSON QualifiedName where
  toJSON = toJSON . renderQualifiedName

instance FromJSON QualifiedName where
  parseJSON = withText "QualifiedName" (pure . parseQualifiedName)

instance ToJSONKey QualifiedName where
  toJSONKey = toJSONKeyText renderQualifiedName

instance FromJSONKey QualifiedName where
  fromJSONKey = FromJSONKeyTextParser (pure . parseQualifiedName)

-- | Render a 'QualifiedName' to its canonical flat dotted form
-- (@\"module.name\"@, or just @\"name\"@ when the module part is empty).
-- This is the wire format used in JSON output, IR @entries@ keys, and any
-- user-visible diagnostic that mentions a top-level callable. The result
-- round-trips through 'parseQualifiedName'.
renderQualifiedName :: QualifiedName -> Text
renderQualifiedName qualifiedName
  | T.null qualifiedName.module_ = qualifiedName.name
  | otherwise = qualifiedName.module_ <> "." <> qualifiedName.name

-- | Inverse of 'renderQualifiedName'. Splits at the last @.@: a name
-- without a dot becomes @QualifiedName "" name@. A name with one or
-- more dots takes everything after the final dot as the bare name.
--
-- A trailing dot or empty leaf segment (e.g. @\"abc.\"@) is malformed
-- — accepting it would produce a 'QualifiedName' whose @name@ field
-- silently round-trips to a different shape. The function is total
-- on well-formed inputs (= anything 'renderQualifiedName' emits); for
-- malformed input it falls back to keeping the whole text as the name
-- with empty module, which is the same shape as a single-segment
-- identifier and surfaces as a normal lookup miss downstream.
parseQualifiedName :: Text -> QualifiedName
parseQualifiedName text =
  let (modulePart, namePart) = T.breakOnEnd "." text
   in if T.null modulePart
        then QualifiedName "" namePart
        else
          if T.null namePart
            then QualifiedName "" text -- malformed (trailing dot); preserve verbatim
            else QualifiedName (T.dropEnd 1 modulePart) namePart

-- | Literal scalar values shared between source patterns / expressions
-- (the AST side) and IR @StatementLoadLiteral@ / @MatchPatternLiteral@
-- (the IR side). Records carry the value under a named field
-- (@integer@/@number@/@string@/@boolean@) so the JSON shape is
-- self-documenting.
data LiteralValue where
  LiteralValueInteger :: {integer :: Integer} -> LiteralValue
  LiteralValueNumber :: {number :: Double} -> LiteralValue
  LiteralValueString :: {string :: Text} -> LiteralValue
  LiteralValueBoolean :: {boolean :: Bool} -> LiteralValue
  LiteralValueNull :: LiteralValue
  -- | Reference to a top-level agent declaration. Carries only the
  -- 'QualifiedName' (FFI-stable identifier); the runtime resolves it to a
  -- 'BlockId' via 'IRModule.entries' at dispatch time. Distinct from a
  -- closure value in that it captures no lexical scope.
  LiteralValueAgent :: {qualifiedName :: QualifiedName} -> LiteralValue
  deriving (Eq, Show, Generic)

instance ToJSON LiteralValue where
  toJSON = genericToJSON commonSumOptions

instance FromJSON LiteralValue where
  parseJSON = genericParseJSON commonSumOptions

-- ===========================================================================
-- Internal aeson options
-- ===========================================================================

-- | Tagged-object sum options matching the IR's flavour: @kind@ + @body@,
-- camelCase constructor tags.
commonSumOptions :: Options
commonSumOptions =
  defaultOptions
    { sumEncoding = TaggedObject "kind" "body",
      fieldLabelModifier = id,
      constructorTagModifier = lowerHead,
      omitNothingFields = True
    }

-- | Runtime-checkable type tag used by type-guard patterns. Shared between
-- the AST ('Katari.AST.TypePattern') and the IR ('Katari.IR.MatchPatternTypeGuard').
data TypePatternTag where
  TypePatternTagInteger :: TypePatternTag
  TypePatternTagNumber :: TypePatternTag
  TypePatternTagString :: TypePatternTag
  TypePatternTagBoolean :: TypePatternTag
  TypePatternTagAgent :: TypePatternTag
  deriving (Eq, Ord, Show, Generic)

instance ToJSON TypePatternTag where
  toJSON = genericToJSON enumOptions

instance FromJSON TypePatternTag where
  parseJSON = genericParseJSON enumOptions

enumOptions :: Options
enumOptions =
  defaultOptions
    { sumEncoding = UntaggedValue,
      allNullaryToStringTag = True,
      constructorTagModifier = lowerHead
    }

lowerHead :: String -> String
lowerHead = \case
  [] -> []
  (c : cs) -> toLower c : cs
