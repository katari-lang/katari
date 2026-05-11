-- | Compiler-blessed source snippets that are spliced into every program
-- before the user's modules are processed.
--
-- The motivating use case is supplying \"system\" data declarations like
-- @agent_metadata@ which the runtime / prim system needs to refer to by
-- name. Keeping them as Katari source (rather than building constructor
-- definitions from Haskell) lets the normal Identifier / Lowering /
-- Schema pipeline produce all the usual derived data (qname-keyed
-- constructor identity, field types, JSON schema, ...) without
-- special-case shortcuts.
--
-- All snippets are injected under their stated module name and become
-- part of that module's exports. For @prim@ in particular, the
-- Identifier-pass auto-import mechanism then propagates the resulting
-- symbols into every user module's lexical scope (so end-users can write
-- @agent_metadata@ unqualified).
module Katari.Stdlib
  ( stdlibSources,
    stdlibModuleNames,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as Text

-- | All compiler-blessed sources, keyed by the module name they are
-- spliced under. Module-name keys may overlap with prim-reserved names
-- (@prim@ / @prim.*@) — that's exactly the point of stdlib snippets.
stdlibSources :: Map Text Text
stdlibSources =
  Map.singleton "prim" primStdlibSource

-- | The set of module names occupied by 'stdlibSources'. Identifier
-- skips its K0113 \"reserved prim module\" check for these names since
-- they originate from the compiler, not the user.
stdlibModuleNames :: Set Text
stdlibModuleNames = Map.keysSet stdlibSources

-- | The @prim@ module's stdlib source. Currently provides @agent_metadata@:
-- the data type returned by @get_metadata@ for any callable value.
primStdlibSource :: Text
primStdlibSource =
  Text.unlines
    [ "data agent_metadata(",
      "  name: string,",
      "  id: string,",
      "  description: string,",
      "  input: string,",
      "  output: string,",
      ")"
    ]
