-- | Internal panic helpers for compiler-invariant violations.
--
-- These should never fire under correct compiler state. They wrap raw
-- 'error' calls so the message is consistent and includes a call stack.
-- User-facing problems must go through 'Katari.Diagnostic' instead.
module Katari.Internal
  ( internalError,
    internalErrorNoSpan,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Stack (HasCallStack)
import Katari.SourceSpan (SourceSpan)

-- | Panic with a location and a message describing the violated invariant.
-- The location is 'Show'-constrained so that callers can pass a 'SourceSpan'
-- (or any other printable locator) without this module depending on
-- 'Katari.AST'.
internalError :: (HasCallStack) => SourceSpan -> Text -> a
internalError location msg =
  error ("internal compiler error at " <> show location <> ": " <> Text.unpack msg)

-- | Panic without a span. Use only when the call site has no easy way to
-- thread a 'SourceSpan'; the 'HasCallStack' constraint preserves location
-- information in the panic.
internalErrorNoSpan :: (HasCallStack) => Text -> a
internalErrorNoSpan msg =
  error ("internal compiler error: " <> Text.unpack msg)
