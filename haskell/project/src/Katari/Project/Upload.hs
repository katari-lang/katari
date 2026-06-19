-- | Per-module differential upload.
--
-- v0.1 has no build cache (see 'Katari.Project.Cache'): the CLI compiles the whole project from
-- source every time. Uploads are still incremental, though — the runtime stores modules
-- individually, so the CLI need only send the ones that actually changed.
--
-- The mechanism is a pure diff over IR hashes: hash every freshly built 'IRModule', ask the runtime
-- for the hashes it currently holds, and compare. A module is uploaded when its hash is new or
-- differs; one the runtime holds but the build no longer produces is marked for removal. No on-disk
-- state is needed — the comparison is between the fresh build and the runtime's reported state.
--
-- The HTTP upload itself lives in the CLI; this module only computes the plan, so it stays pure and
-- testable.
module Katari.Project.Upload
  ( ModuleHash (..),
    UploadPlan (..),
    hashModule,
    planUpload,
  )
where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Builder qualified as Builder
import Data.Foldable (toList)
import Data.List (intersperse, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Katari.Data.IR (IRModule)
import Katari.Data.ModuleName (ModuleName)

-- | A stable content hash of a module's IR (hex SHA-256 of its canonical serialisation). Equal
-- hashes mean the runtime already holds an identical module, so the upload can be skipped.
newtype ModuleHash = ModuleHash Text
  deriving (Show, Eq, Ord)

-- | The outcome of diffing a fresh build against the runtime's current modules.
data UploadPlan = UploadPlan
  { -- | Modules to upload: new, or whose hash differs from the runtime's.
    changed :: Map ModuleName IRModule,
    -- | Modules whose hash already matches the runtime's; skipped.
    unchanged :: Set ModuleName,
    -- | Modules the runtime holds but this build no longer produces; to be removed.
    removed :: Set ModuleName
  }
  deriving (Show, Eq)

-- | Hash one module's IR into the stable identity used for the diff. The hash is taken over a
-- /canonical/ serialisation ('canonicalize') so that the same 'IRModule' always yields the same
-- hash regardless of 'Map' / aeson 'KeyMap' iteration order.
hashModule :: IRModule -> ModuleHash
hashModule irModule =
  let canonicalBytes = Builder.toLazyByteString (canonicalize (Aeson.toJSON irModule))
      digest = hashlazy canonicalBytes :: Digest SHA256
      hex = convertToBase Base16 digest :: ByteString
   in ModuleHash (TextEncoding.decodeUtf8 hex)

-- | Serialise an aeson 'Value' to a deterministic byte string: object keys are sorted so the result
-- is independent of 'Map' / aeson 'KeyMap' iteration order, while arrays keep their order and
-- scalars reuse aeson's own (deterministic) encoding. Its SHA-256 is a module's stable identity.
--
-- Only the Haskell CLI computes this hash (the runtime treats it as an opaque key), so the encoder
-- need only be self-consistent — full cross-language JSON canonicalisation (RFC 8785) is not needed.
canonicalize :: Value -> Builder.Builder
canonicalize value = case value of
  Object keyMap ->
    let sortedPairs = sortOn fst [(Key.toText key, fieldValue) | (key, fieldValue) <- KeyMap.toList keyMap]
        renderPair (key, fieldValue) = encodeString key <> Builder.char7 ':' <> canonicalize fieldValue
     in Builder.char7 '{'
          <> mconcat (intersperse (Builder.char7 ',') (map renderPair sortedPairs))
          <> Builder.char7 '}'
  Array values ->
    Builder.char7 '['
      <> mconcat (intersperse (Builder.char7 ',') (map canonicalize (toList values)))
      <> Builder.char7 ']'
  -- Scalars (string / number / boolean / null) have a single deterministic aeson encoding; reuse it.
  scalar -> Builder.lazyByteString (Aeson.encode scalar)

-- | Encode a 'Text' as a canonical JSON string literal, delegating escaping to aeson.
encodeString :: Text -> Builder.Builder
encodeString text = Builder.lazyByteString (Aeson.encode (String text))

-- | Diff a fresh build (module → IR) against the runtime's current per-module hashes (module → hash)
-- into an 'UploadPlan'.
planUpload :: Map ModuleName IRModule -> Map ModuleName ModuleHash -> UploadPlan
planUpload built runtimeHashes =
  UploadPlan
    { changed = changedModules,
      unchanged = Map.keysSet unchangedModules,
      removed = Map.keysSet runtimeHashes `Set.difference` Map.keysSet built
    }
  where
    -- A module is unchanged when the runtime already holds its exact hash; everything else (new, or
    -- hash differs) goes in 'changed'.
    (unchangedModules, changedModules) =
      Map.partitionWithKey
        (\moduleName irModule -> Map.lookup moduleName runtimeHashes == Just (hashModule irModule))
        built
