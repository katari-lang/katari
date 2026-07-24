-- | The root-row pass: a @local request@ — one only a handler INSIDE the program can answer, never
-- machine-answered by the runtime — must not reach the INFERRED residual row of a top-level agent. A
-- run started at such an agent would suspend forever at the first perform (a callable-carrying
-- operator question nobody outside the run can answer), so the stall is turned into a compile error
-- (K3027) here.
--
-- Deliberately a self-contained pass, separate from "Katari.Typechecker.Check": it reads only the
-- typed AST (every top-level agent's @typeOf@ carries its resolved @agent param -> return with
-- effect@ type, so the residual row is already computed) and the @local@ flags, and emits diagnostics.
-- Keeping it out of the check walk keeps that walk unentangled — the concern is a whole-program
-- property (which requests are @local@, gathered across every module) rather than a per-expression one.
--
-- The exemption is intentional: only an agent whose effect row is INFERRED (@effects == Nothing@) is
-- enforced. Writing the row out explicitly (@with store.exclusive@) is the honest hand-off of the
-- serving obligation to this agent's callers, so an explicit row is never flagged.
module Katari.Typechecker.RootRow (checkRootRows, escalatingRequestNames) where

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Id (TypeResolution (..))
import Katari.Data.ModuleName (ModuleName, lastSegment)
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SemanticType (SemanticEffect (..), SemanticType (..))
import Katari.Data.SourceSpan (SourceSpan, renderSourceSpan)
import Katari.Diagnostics (Diagnostics, diagnosticAt)
import Katari.Error (CompilerError (..), LocalRequestEscalatesErrorInfo (..), TypeError (..))

-- | Reject every @local request@ that escapes an inferred top-level agent's residual row (K3027).
-- The @local@ set is gathered across ALL modules first (a local request declared in one module can
-- escalate through an agent in another), then every module's top-level agents are checked against it.
checkRootRows :: Map ModuleName (Module Typed) -> Diagnostics
checkRootRows modules =
  let allModules = Map.elems modules
      localRequests = collectLocalRequests allModules
   in foldMap (checkModule localRequests) allModules

-- | Every @local request@ in the program, mapped to its declaration span (the diagnostic points a
-- reader at "the request's declaration at ..." for the request's install discipline). A request with
-- no resolved type identity is skipped — it has no name to match against a residual row anyway.
collectLocalRequests :: List (Module Typed) -> Map QualifiedName SourceSpan
collectLocalRequests modules =
  Map.fromList
    [ (qualifiedName, declaration.sourceSpan)
      | module' <- modules,
        DeclarationRequest declaration <- module'.declarations,
        declaration.local,
        Just qualifiedName <- [requestQualifiedName declaration]
    ]

-- | The resolved type identity of a request declaration (the name it occupies in effect rows), or
-- 'Nothing' if the reference did not resolve (a prior error the checker already reported).
requestQualifiedName :: RequestDeclaration Typed -> Maybe QualifiedName
requestQualifiedName declaration = case declaration.typeReference.resolution of
  Just (TypeResolutionQualifiedName qualifiedName) -> Just qualifiedName
  _ -> Nothing

checkModule :: Map QualifiedName SourceSpan -> Module Typed -> Diagnostics
checkModule localRequests module' = foldMap (checkDeclaration localRequests) module'.declarations

-- | A top-level agent with an INFERRED row is the only shape enforced: its residual request leaves
-- are intersected with the program's @local@ set, and each survivor is one stall-in-waiting (K3027).
-- An explicit row, and every non-agent declaration, is left alone.
checkDeclaration :: Map QualifiedName SourceSpan -> Declaration Typed -> Diagnostics
checkDeclaration localRequests = \case
  DeclarationAgent declaration
    | isNothing declaration.effects ->
        let escalating = escalatingRequestNames (residualEffect declaration.typeOf)
            leaks = Map.toList (Map.restrictKeys localRequests escalating)
         in foldMap (escalatingLocalDiagnostic declaration) leaks
  _ -> mempty

-- | Build the K3027 diagnostic for one @local request@ leaking out of an agent's inferred row,
-- anchored at the agent declaration (the run root a reader would start from).
escalatingLocalDiagnostic :: AgentDeclaration Typed -> (QualifiedName, SourceSpan) -> Diagnostics
escalatingLocalDiagnostic declaration (requestName, declarationSpan) =
  diagnosticAt
    declaration.sourceSpan
    ( CompilerErrorType
        ( TypeErrorLocalRequestEscalates
            LocalRequestEscalatesErrorInfo
              { agent = declaration.name,
                request = displayName requestName,
                declaration = renderSourceSpan declarationSpan
              }
        )
    )

-- | A top-level agent's @typeOf@ is its @agent param -> return with effect@ type, so the residual
-- effect row is the third component. Anything else has no row to leak (kept total — no partial peek).
residualEffect :: SemanticType -> SemanticEffect
residualEffect = \case
  SemanticTypeAgent _ _ effect -> effect
  _ -> SemanticEffectPure

-- | The set of request NAMES that a residual effect row escalates — the leaves the run would have to
-- find an answer for. The rules mirror the effect lattice:
--
--   * a union collects its arms;
--   * an overwrite is @(base minus the lacks names) plus the overwrites@ — a @lacks@ entry drops a
--     name that a nested install has taken over, so it is genuinely no longer escalated;
--   * @all@ (unconstrained), @io@ (un-dischargeable, machine-carried to the root), a generic tail
--     and @pure@ escalate no NAMED request, so none contributes;
--   * a request leaf contributes its own name only — its generic arguments are NOT descended into,
--     because an effect that merely appears as a request's type argument (e.g. the connection row of
--     @approve_async[...]@) is not itself performed here.
escalatingRequestNames :: SemanticEffect -> Set QualifiedName
escalatingRequestNames = \case
  SemanticEffectPure -> Set.empty
  SemanticEffectAny -> Set.empty
  SemanticEffectIo -> Set.empty
  SemanticEffectRequest qualifiedName _ -> Set.singleton qualifiedName
  SemanticEffectGeneric _ -> Set.empty
  SemanticEffectUnion effects -> foldMap escalatingRequestNames effects
  SemanticEffectOverwrite base lacksNames overwrites ->
    Set.union
      (Set.difference (escalatingRequestNames base) lacksNames)
      (Set.fromList (fst <$> overwrites))

-- | How a request reads in source: its module's last segment joined to its name (@store.exclusive@,
-- @time.race_settled@), the form a user writes and would spell in a @with@ clause.
displayName :: QualifiedName -> Text
displayName qualifiedName = lastSegment qualifiedName.moduleName <> "." <> qualifiedName.name
