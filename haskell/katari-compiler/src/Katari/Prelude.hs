-- | Project-wide Prelude shim.
--
-- Enabling @RebindableSyntax@ disables the implicit @Prelude@ import and
-- relies on user-defined @ifThenElse@ (for @if-then-else@), @getField@ (for
-- @OverloadedRecordDot@'s @expr.field@), and @fromString@ (for
-- @OverloadedStrings@) being in scope. This module re-exports the standard
-- @Prelude@ together with those bindings so every source file can simply
-- @import Katari.Prelude@ and write ordinary Haskell.
module Katari.Prelude
  ( module Prelude,
    getField,
    ifThenElse,
    fromString,
  )
where

import Data.String (fromString)
import GHC.Records (getField)
import Prelude

-- | Under @RebindableSyntax@, @if c then a else b@ desugars to a call to
-- @ifThenElse c a b@. Implementing this with @if-then-else@ would silently
-- recurse forever (the same desugaring rule applies inside this body!), so it
-- is implemented with @case@ instead.
ifThenElse :: Bool -> a -> a -> a
ifThenElse condition true false = case condition of
  True -> true
  False -> false
