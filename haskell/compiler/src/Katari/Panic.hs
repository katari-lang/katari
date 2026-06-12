-- | The abnormal-termination channel for internal compiler errors: invariant violations that mean
-- a compiler bug, not a user error. Distinct from the user-facing, accumulated diagnostics of
-- "Katari.Error" — an internal error aborts rather than accumulating, because there is no
-- meaningful way to continue past it. For now it crashes loudly (right for development); the call
-- sites are a stable seam for a future catchable form (per-module recovery in a server) that would
-- change only this module.
module Katari.Panic where

import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Stack (HasCallStack, callStack, prettyCallStack)

-- | Abort with an internal-compiler-error message and the originating call site. Use only at points
-- that are unreachable by construction (e.g. a resolved name absent from an environment the
-- pipeline guarantees complete) — never for user-actionable errors, which belong in "Katari.Error".
panic :: (HasCallStack) => Text -> a
panic message =
  errorWithoutStackTrace . Text.unpack $
    "Katari internal error: "
      <> message
      <> "\nThis is a compiler bug; please report it.\n"
      <> Text.pack (prettyCallStack callStack)
