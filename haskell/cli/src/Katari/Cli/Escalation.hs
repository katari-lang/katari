-- | The ESCALATION REPORT `katari check` prints beneath its success summary: for each entry point in
-- the project's own modules, the requests that escalate all the way to the run root (unhandled at the
-- top of the entry agent). This is the run's effect contract — what a run started at that agent will
-- pause to ask the operator, and what it surfaces to the runtime — so an AI or an operator can read it
-- off `check` without running the program. It is informational only, never an error.
--
-- An entry point is every top-level @agent@ declaration in the project's own modules (the runtime
-- starts an agent by name, so any top-level agent could be a run root). Its residual effect row is
-- read directly off the checked agent's 'typeOf' — the outward-facing @with ...@ row the typechecker
-- already inferred — so nothing is re-inferred here.
module Katari.Cli.Escalation
  ( EntryPointReport (..),
    entryPointReports,
    renderEntryPointSection,
  )
where

import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Data.AST (AgentDeclaration (..), Declaration (..), Module (..), Phase (Typed))
import Katari.Data.ModuleName (ModuleName, lastSegment, renderModuleName)
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SemanticType
  ( NameStyle (..),
    SemanticEffect (..),
    SemanticType (..),
    renderSemanticEffectLeavesWith,
    renderSemanticGenericArgumentsWith,
  )

-- | One entry point's residual effect row, split for the report into the requests that escalate (the
-- interesting part — @prelude.throw[...]@, store ops, oauth, region requests, app-defined requests, …)
-- and whether plain @io@ rides along. @requests@ is module-prefixed (@store.get@, not a bare @get@),
-- sorted, and deduplicated, so the report reads in the same names as the source and does so
-- deterministically.
data EntryPointReport = EntryPointReport
  { qualifiedName :: Text,
    requests :: List Text,
    io :: Bool
  }
  deriving stock (Eq, Show)

-- | The entry-point reports for the given modules, in the given module order (the caller lists the
-- root module first). Within a module the agents keep their source-declaration order. Only top-level
-- @agent@ declarations are entry points; a module absent from the typed set contributes nothing.
entryPointReports :: List ModuleName -> Map ModuleName (Module Typed) -> List EntryPointReport
entryPointReports moduleNames typedModules =
  [ reportFor moduleName agentDeclaration
    | moduleName <- moduleNames,
      Just module' <- [Map.lookup moduleName typedModules],
      DeclarationAgent agentDeclaration <- module'.declarations
  ]

-- | Build one agent's report: its qualified name and its residual row split into escalating requests
-- and io.
reportFor :: ModuleName -> AgentDeclaration Typed -> EntryPointReport
reportFor moduleName agentDeclaration =
  EntryPointReport
    { qualifiedName = renderModuleName moduleName <> "." <> agentDeclaration.name,
      requests = nub (sort escalatingRequests),
      io = escalatesIo
    }
  where
    (escalatingRequests, escalatesIo) =
      maybe ([], False) splitEscalations (agentResidualEffect agentDeclaration.typeOf)

-- | The residual effect row of a top-level agent, read off its checked function type. A @private@
-- agent's type is the function type wrapped in a @of private@ attribute, so peel any attribute to
-- reach the agent. Anything that is not an agent type (never expected for an agent declaration)
-- contributes no row.
agentResidualEffect :: SemanticType -> Maybe SemanticEffect
agentResidualEffect = \case
  SemanticTypeAgent _ _ effect -> Just effect
  SemanticTypeAttribute inner _ -> agentResidualEffect inner
  _ -> Nothing

-- | Split an effect row into (rendered escalating requests, has io). A request renders module-prefixed
-- by its module's LAST SEGMENT — @store.get@, @prelude.throw@ — which is exactly the prefix-import
-- alias users write in source (@prelude.store@ is imported as @store@), so the report reads in the same
-- names as the code and the docs. Its generic arguments render in the SAME 'QualifiedByLastSegment'
-- style, so a nested request / data type carries its module too — @approve_async[gmail.credential |
-- google_calendar.credential]@, not a conflated @credential | credential@ — and the shared renderer
-- deduplicates the qualified union. A generic tail, @all@, or a @{...}@ overwrite falls back to the
-- shared leaf renderer and counts as a request (it is not plain io); only 'SemanticEffectIo' sets the
-- io flag.
splitEscalations :: SemanticEffect -> (List Text, Bool)
splitEscalations = \case
  SemanticEffectPure -> ([], False)
  SemanticEffectIo -> ([], True)
  SemanticEffectRequest requestName arguments ->
    ([lastSegment requestName.moduleName <> "." <> requestName.name <> renderSemanticGenericArgumentsWith QualifiedByLastSegment arguments], False)
  SemanticEffectUnion effects ->
    let parts = splitEscalations <$> effects
     in (concatMap fst parts, any snd parts)
  other -> (renderSemanticEffectLeavesWith QualifiedByLastSegment other, False)

-- | Render the whole section printed beneath @check@'s @OK@ line. Every entry point prints its
-- qualified name and an @escalates:@ line; a row with no requests and no io reads @(nothing)@, a
-- row of only io reads @(nothing but io)@, otherwise the requests are listed with @io@ last. A
-- project with no top-level agents prints a single @(none)@ line under the header.
renderEntryPointSection :: List EntryPointReport -> Text
renderEntryPointSection reports =
  Text.intercalate "\n" (header : bodyLines)
  where
    header = "Entry points (requests that escalate to the run root):"
    bodyLines = case reports of
      [] -> ["  (none)"]
      _ -> concatMap renderReport reports

-- | The two lines one entry point contributes.
renderReport :: EntryPointReport -> List Text
renderReport report =
  [ "  " <> report.qualifiedName,
    "    escalates: " <> body
  ]
  where
    body = case (report.requests, report.io) of
      ([], False) -> "(nothing)"
      ([], True) -> "(nothing but io)"
      (requests, hasIo) -> Text.intercalate ", " (requests <> ["io" | hasIo])
