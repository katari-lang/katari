-- | The accumulation side of error reporting: the writer monoid a phase emits into, the helpers it
-- emits with, and the finalization (dedup + ordering) for presentation. The error catalogue itself
-- (what each error is, its code, severity, rendering) is the pure "Katari.Error".
module Katari.Diagnostics where

import Control.Monad.Writer.Class (MonadWriter (..))
import Data.Foldable (toList)
import Data.List (partition, sortOn)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Data.SourceSpan (Located (..), SourceSpan (..))
import Katari.Error (CompilerError, Severity (..), isUnresolvedName, isUnresolvedNameShadow, renderLocatedCompilerError, severityOf)

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

-- | Order a phase's accumulated diagnostics by source position, drop exact duplicates (one node may be
-- reported more than once before spans distinguish the occurrences), and drop the shadows of an
-- unresolved name ('suppressUnresolvedNameShadows').
finalizeDiagnostics :: Diagnostics -> List (Located CompilerError)
finalizeDiagnostics = suppressUnresolvedNameShadows . sortOn bySourcePosition . Set.toList . Set.fromList . toList
  where
    -- value breaks span ties so the order is total; keep the key injective over Located.
    bySourcePosition located = (located.sourceSpan, located.value)

-- | Drop every diagnostic that can only be the shadow of a name that did not resolve, in the files that
-- report such a name ('Katari.Error.isUnresolvedNameShadow' / 'Katari.Error.isUnresolvedName'). One
-- misspelled member otherwise prints a "type never" mismatch ABOVE the K2002 that caused it — the
-- report's first line points at the wrong thing, which is the one thing a reader (or an agent
-- correcting itself) must not be handed.
--
-- Whole-file rather than span-nested, because the @never@ travels: @let x = nosuch@ poisons every later
-- use of @x@, at spans the misspelling does not enclose. Presentation only — 'hasErrors' runs on the
-- unfiltered diagnostics, so nothing compiles that would not have, and the root cause is always still
-- printed (suppression is gated on it being present).
suppressUnresolvedNameShadows :: List (Located CompilerError) -> List (Located CompilerError)
suppressUnresolvedNameShadows diagnostics = filter keep diagnostics
  where
    filesWithUnresolvedNames =
      Set.fromList [located.sourceSpan.filePath | located <- diagnostics, isUnresolvedName located.value]
    keep located =
      not (isUnresolvedNameShadow located.value && Set.member located.sourceSpan.filePath filesWithUnresolvedNames)

-- | Split finalized diagnostics into the ones to show and the warnings to withhold, given the set of
-- source files the reader is answerable for (a span's 'SourceSpan.filePath' is the module's rendered
-- name, which 'Katari.Parser.parseModule' stamps).
--
-- A WARNING about a file the reader does not own is noise they cannot act on — the only thing it
-- teaches is to stop reading warnings — while an ERROR is never withheld, wherever it comes from: it
-- stops the build, and the location is how the reader understands why. Pure and total, so the caller
-- (which is the layer that knows which package is "theirs") owns the policy and this owns only the
-- split.
partitionByOwnership ::
  Set FilePath ->
  List (Located CompilerError) ->
  (List (Located CompilerError), List (Located CompilerError))
partitionByOwnership ownedFiles = partition shown
  where
    shown located = case severityOf located.value of
      SeverityError -> True
      SeverityWarning -> Set.member located.sourceSpan.filePath ownedFiles

-- | Render every diagnostic, one per line, ordered by source position.
renderDiagnostics :: Diagnostics -> Text
renderDiagnostics = renderFinalizedDiagnostics . finalizeDiagnostics

-- | Render diagnostics that have already been through 'finalizeDiagnostics' (and possibly
-- 'partitionByOwnership'), one per line. Separate from 'renderDiagnostics' so a caller that filters
-- the finalized list still prints it in exactly the same shape.
renderFinalizedDiagnostics :: List (Located CompilerError) -> Text
renderFinalizedDiagnostics = Text.intercalate "\n" . map renderLocatedCompilerError
