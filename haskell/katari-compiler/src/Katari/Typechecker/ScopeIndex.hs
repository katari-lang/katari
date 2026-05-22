-- | A flat index of "what symbols are visible in which source region".
--
-- Built during the Identifier pass: every @withScopeFrameAt span@
-- captures @(span, innermost-frame-symbols)@ on exit and accumulates
-- them in 'IdentifierState'. The accumulated list is then grouped by
-- file path into a 'ScopeIndex' so the LSP / completion query layer
-- can ask "which symbols are in scope at this position?" without
-- re-running name resolution.
--
-- The capture granularity is /per scope frame/, not per statement.
-- That means the snapshot reflects the frame's bindings as of the
-- moment the frame closes — a @let x = 1; let y = 2@ block captures
-- @{x, y}@ even when the query position sits between the two @let@s.
-- For completion that is harmless (the prefix filter discards
-- not-yet-typed names anyway); for stricter use cases a finer
-- granularity can be layered on top later.
--
-- The module is parameterised on the symbol payload type @a@ (typically
-- 'Katari.Typechecker.Identifier.SymbolEntry') so it can live below
-- 'Identifier' in the module graph without creating a cycle.
module Katari.Typechecker.ScopeIndex
  ( ScopeFrame (..),
    ScopeIndex (..),
    emptyScopeIndex,
    buildScopeIndex,
    scopeAt,
  )
where

import Data.Function (on)
import Data.List (sortBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Katari.SourceSpan (Position (..), SourceSpan (..), spanContains)

data ScopeFrame a = ScopeFrame
  { frameSpan :: SourceSpan,
    frameSymbols :: Map Text a
  }
  deriving (Show)

newtype ScopeIndex a = ScopeIndex
  { framesByFile :: Map FilePath [ScopeFrame a]
  }
  deriving (Show)

emptyScopeIndex :: ScopeIndex a
emptyScopeIndex = ScopeIndex {framesByFile = Map.empty}

-- | Build a 'ScopeIndex' from the flat list of frames captured during
-- the Identifier pass.
buildScopeIndex :: [ScopeFrame a] -> ScopeIndex a
buildScopeIndex frames =
  ScopeIndex
    { framesByFile = Map.fromListWith (<>) [(f.frameSpan.filePath, [f]) | f <- frames]
    }

-- | Frame symbol maps whose span contains @position@, ordered
-- innermost-first. Callers typically @Map.unions@ them to flatten the
-- view (innermost wins for shadowing) or fold them manually for
-- shadow-aware semantics.
scopeAt :: ScopeIndex a -> FilePath -> Position -> [Map Text a]
scopeAt index filePath position =
  let candidates = Map.findWithDefault [] filePath index.framesByFile
      containing = [f | f <- candidates, spanContains f.frameSpan position]
   in map (.frameSymbols) (sortBy (compare `on` spanLooseness) containing)

-- | Sort key: lexicographically smaller = tighter span. With
-- innermost-first sort, frames whose start position is later and end
-- position is earlier come first.
spanLooseness :: ScopeFrame a -> (Int, Int, Int, Int)
spanLooseness f =
  let s = f.frameSpan.start
      e = f.frameSpan.end
   in (-s.line, -s.column, e.line, e.column)
