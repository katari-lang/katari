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

instance ToJSON QualifiedName where
  toJSON = genericToJSON commonOptions

instance FromJSON QualifiedName where
  parseJSON = genericParseJSON commonOptions

-- | Render @{module_, name}@ as a string key for use as a JSON object key.
-- Aeson's default 'ToJSONKey' for record types encodes the map as a JSON
-- array of @[key, value]@ pairs, which the runtime cannot index directly.
-- We instead emit a textual @\"module.name\"@ key (or @\"name\"@ when the
-- module is empty) so the runtime can do plain object lookups.
instance ToJSONKey QualifiedName where
  toJSONKey = toJSONKeyText renderQualifiedName

instance FromJSONKey QualifiedName where
  fromJSONKey = FromJSONKeyTextParser (pure . parseQualifiedName)

renderQualifiedName :: QualifiedName -> Text
renderQualifiedName qualifiedName
  | T.null qualifiedName.module_ = qualifiedName.name
  | otherwise = qualifiedName.module_ <> "." <> qualifiedName.name

-- | Inverse of 'renderQualifiedName'. Splits at the last @.@: a name
-- without a dot becomes @QualifiedName "" name@. A name with one or
-- more dots takes everything after the final dot as the bare name.
parseQualifiedName :: Text -> QualifiedName
parseQualifiedName text =
  let (modulePart, namePart) = T.breakOnEnd "." text
   in if T.null modulePart
        then QualifiedName "" namePart
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
  deriving (Eq, Show, Generic)

instance ToJSON LiteralValue where
  toJSON = genericToJSON commonSumOptions

instance FromJSON LiteralValue where
  parseJSON = genericParseJSON commonSumOptions

-- ===========================================================================
-- Internal aeson options
-- ===========================================================================

-- | Plain record options (fields kept as-is; @Nothing@ omitted).
commonOptions :: Options
commonOptions =
  defaultOptions
    { fieldLabelModifier = id,
      omitNothingFields = True
    }

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

lowerHead :: String -> String
lowerHead [] = []
lowerHead (c : cs) = toLower c : cs
