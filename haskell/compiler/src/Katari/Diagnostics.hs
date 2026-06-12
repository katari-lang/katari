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
import Katari.Error (CompilerError, renderLocatedCompilerError)

-- | The errors a phase has accumulated, in emission order. Phases use this as their writer monoid;
-- the span-free Normalizer keeps its own @[TypeError]@ and is bridged into this by the checker.
type Diagnostics = Seq (Located CompilerError)

-- | Emit an error at the given source span. Phases hold the AST node they are reporting about, so
-- this is the form they use.
reportAt :: (MonadWriter Diagnostics m) => SourceSpan -> CompilerError -> m ()
reportAt sourceSpan compilerError = tell (Seq.singleton (Located {value = compilerError, sourceSpan = sourceSpan}))

-- | Run a sub-computation and hand back its diagnostics instead of letting them propagate — for
-- checks that inspect their own errors before deciding what to surface.
capture :: (MonadWriter Diagnostics m) => m a -> m (a, Diagnostics)
capture action = pass $ do
  (result, diagnostics) <- listen action
  pure ((result, diagnostics), const mempty)

-- | Order a phase's accumulated diagnostics by source position and drop exact duplicates (one node
-- may be reported more than once before spans distinguish the occurrences).
finalizeDiagnostics :: Diagnostics -> List (Located CompilerError)
finalizeDiagnostics = sortOn bySourcePosition . Set.toList . Set.fromList . toList
  where
    bySourcePosition located = (located.sourceSpan, located.value)

-- | Render every diagnostic, one per line, ordered by source position.
renderDiagnostics :: Diagnostics -> Text
renderDiagnostics = Text.intercalate "\n" . map renderLocatedCompilerError . finalizeDiagnostics
