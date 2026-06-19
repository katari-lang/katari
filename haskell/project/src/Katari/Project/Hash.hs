-- | The one SHA-256 hex encoding used across the package.
--
-- Two callers must agree byte-for-byte or the content-addressed cache silently corrupts: the git
-- tarball hash ("Katari.Project.Fetch") that becomes a cache directory name and a lockfile pin, and
-- the per-module IR hash ("Katari.Project.Upload") that decides which modules to re-upload. They
-- share this single encoder so a change to the encoding can never reach one without the other.
module Katari.Project.Hash
  ( sha256Hex,
  )
where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as ByteStringLazy
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding

-- | Lowercase hex SHA-256 of a lazy byte string. @Base16@ emits lowercase, so the result is the
-- canonical form the lockfile records and the cache keys on.
sha256Hex :: ByteStringLazy.ByteString -> Text
sha256Hex lazyBytes =
  let digest = hashlazy lazyBytes :: Digest SHA256
      hex = convertToBase Base16 digest :: ByteString
   in TextEncoding.decodeUtf8 hex
