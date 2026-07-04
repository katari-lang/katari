-- | The accumulation side of error reporting: the writer monoid a phase emits into, the helpers it
-- emits with, and the finalization (dedup + ordering) for presentation. The error catalogue itself
-- (what each error is, its code, severity, rendering) is the pure "Katari.Error".
module Katari.Diagnostics where

import Control.Monad.Writer.Class (MonadWriter (..))
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Data.SourceSpan (Located (..), SourceSpan)
import Katari.Error (CompilerError, Severity (..), renderLocatedCompilerError, severityOf)

-- | The errors a phase has accumulated, in emission order. Phases use this as their writer monoid;
-- the span-free Normalizer keeps its own @[TypeError]@ and is bridged into this by the checker.
type Diagnostics = Seq (Located CompilerError)

-- | A single diagnostic as a 'Diagnostics' value, for pure builders that @mconcat@ / @foldMap@ their
-- results rather than emitting into a 'MonadWriter'. This module is the only place that knows the
-- 'Seq' encoding of 'Diagnostics'.
diagnosticAt :: SourceSpan -> CompilerError -> Diagnostics
diagnosticAt sourceSpan compilerError = Seq.singleton (Located {value = compilerError, sourceSpan = sourceSpan})

-- | Emit one already-located diagnostic.
report :: (MonadWriter Diagnostics m) => Located CompilerError -> m ()
report located = tell (Seq.singleton located)

-- | Emit an error at the given source span. Phases hold the AST node they are reporting about, so
-- this is the form they use.
reportAt :: (MonadWriter Diagnostics m) => SourceSpan -> CompilerError -> m ()
reportAt sourceSpan compilerError = report (Located {value = compilerError, sourceSpan = sourceSpan})

-- | Whether any diagnostic is an error (rather than a warning). Used to gate later phases — lowering
-- does not run on a program with errors, so it never emits IR for code that did not type-check.
hasErrors :: Diagnostics -> Bool
hasErrors = any (isError . (.value))
  where
    isError compilerError = case severityOf compilerError of
      SeverityError -> True
      SeverityWarning -> False

-- | Order a phase's accumulated diagnostics by source position and drop exact duplicates (one node
-- may be reported more than once before spans distinguish the occurrences).
finalizeDiagnostics :: Diagnostics -> List (Located CompilerError)
finalizeDiagnostics = sortOn bySourcePosition . Set.toList . Set.fromList . toList
  where
    -- value breaks span ties so the order is total; keep the key injective over Located.
    bySourcePosition located = (located.sourceSpan, located.value)

-- | Render every diagnostic, one per line, ordered by source position.
renderDiagnostics :: Diagnostics -> Text
renderDiagnostics = Text.intercalate "\n" . map renderLocatedCompilerError . finalizeDiagnostics
