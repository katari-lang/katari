-- | The Check (typecheck) phase: bidirectional type & effect checking, producing a 'Typed' AST
-- (every expression / pattern carries its 'Katari.Data.SemanticType.SemanticType') and diagnostics.
--
-- Whole-program, not per module: an @agent@ may infer its return / effect from the agents it calls,
-- and those callees can live in other modules and form mutual-recursion cycles, so the checker walks
-- the value-dependency SCCs ('Katari.Typechecker.ValueGraph.valueSCCs') to grow the value
-- environment dependency-first. A 'Data.Graph.CyclicSCC' is a (mutually) recursive group whose
-- members must annotate their return / effect (inference does not cross a recursion). The data /
-- request / synonym type info is signature-determined and already complete in the 'TypeEnvironment'.
--
-- The per-kind checking walks live in the @Katari.Typechecker.*@ submodules
-- ('Katari.Typechecker.Normalizer' for the type lattice, 'Katari.Typechecker.Environment' for the
-- global env, 'Katari.Typechecker.ValueGraph' for the dependency order, 'Katari.Typechecker.Context'
-- for the checker monad and read-only environment, 'Katari.Typechecker.Check' for the bidirectional
-- walkers that produce the 'Typed' AST).
module Katari.Typechecker where

import Control.Monad (foldM)
import Control.Monad.RWS.CPS (RWS, runRWS)
import Control.Monad.RWS.Class (MonadReader (..), MonadState (..), MonadWriter (..))
import Data.Graph (SCC (..))
import Data.Map (Map)
import Data.Map qualified as Map
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Environment (Scheme, ValueEnvironment)
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.QualifiedName (QualifiedName, renderQualifiedName)
import Katari.Diagnostics (Diagnostics)
import Katari.Panic (panic)
import Katari.Typechecker.Check (checkAgentBody, checkExternalReactor, dataValueScheme, prepareAgent, requestValueScheme, seedAgentType, signatureValueScheme, synthAgent)
import Katari.Typechecker.Context
  ( Checker,
    CheckerEnvironment,
    extendValueEnvironment,
    initialCheckerEnvironment,
    initialCheckerState,
    valueEnvironment,
  )
import Katari.Typechecker.Environment (TypeEnvironment)
import Katari.Typechecker.ValueGraph (ValueDeclaration (..), ValueNode (..))

-- | Check the whole identified program against the global type environment, walking the value
-- dependency order ('Katari.Typechecker.ValueGraph.valueSCCs') so a value's inferred return /
-- effect can be read from its callees first. Produces each module's typed AST and all diagnostics
-- (K3xxx range). Match-exhaustiveness is folded in here for now (no separate phase).
--
-- The SCC walk types every top-level agent and returns them keyed by their resolved identity; each
-- module's typed AST is then assembled by replacing its agent declarations with the typed versions
-- and structurally retagging the non-agent declarations (their typing is signature-only and already
-- complete in the type environment).
checkProgram ::
  TypeEnvironment ->
  List (SCC ValueNode) ->
  Map ModuleName (Module Identified) ->
  (Map ModuleName (Module Typed), ValueEnvironment, Diagnostics)
checkProgram typeEnvironment valueOrder modules =
  let (typedAgents, finalEnvironment, diagnostics) =
        runRWS (walkSCCs valueOrder) () (initialCheckerEnvironment typeEnvironment)
   in -- The accumulated value environment carries every top-level callable's scheme (its full function
      -- type, including the inferred return / effect), which lowering consumes to build each callable's
      -- schema. Agents also stamp their type on the typed declaration, but the four signature-determined
      -- kinds (data / request / external / primitive) are read back from here.
      (buildTypedModule typedAgents <$> modules, finalEnvironment.valueEnvironment, diagnostics)

-- | The driver is a state pass over 'CheckerEnvironment' that also accumulates a map from each
-- agent's resolved identity to its 'Typed' declaration; each component checks in the current
-- environment, then extends it for the next.
type Driver a = RWS () Diagnostics CheckerEnvironment a

-- | Walk the value SCCs in dependency order. Each component is checked against the current
-- environment; its registered schemes are folded back into the state for the next component, and
-- the typed agent declarations are accumulated for module assembly.
walkSCCs :: List (SCC ValueNode) -> Driver (Map QualifiedName (AgentDeclaration Typed))
walkSCCs = foldM (\acc scc -> (acc <>) <$> walkOne scc) mempty
  where
    walkOne = \case
      AcyclicSCC node -> driveOne (checkAcyclic node)
      CyclicSCC nodes -> driveOne (checkCyclic nodes)

-- | Run one component's checker action: forward its diagnostics, fold the new value-environment
-- entries into the driver state, and return the new typed agent declarations.
driveOne ::
  Checker (Map QualifiedName Scheme, Map QualifiedName (AgentDeclaration Typed)) ->
  Driver (Map QualifiedName (AgentDeclaration Typed))
driveOne action = do
  environment <- get
  let ((valueAdditions, typedAgents), _, diagnostics) =
        runRWS action environment initialCheckerState
  tell diagnostics
  put (extendValueEnvironment valueAdditions environment)
  pure typedAgents

-- | Check one non-recursive component and produce its scheme (for the value environment) plus, for
-- an agent, its typed declaration (for module assembly). A signature-determined value (data
-- constructor / external / primitive / request) contributes only its scheme.
checkAcyclic ::
  ValueNode ->
  Checker (Map QualifiedName Scheme, Map QualifiedName (AgentDeclaration Typed))
checkAcyclic node = case node.declaration of
  ValueAgent declaration -> do
    (typedDeclaration, scheme) <- synthAgent declaration
    pure (Map.singleton node.qualifiedName scheme, Map.singleton node.qualifiedName typedDeclaration)
  ValueData declaration -> signatureOnly (dataValueScheme declaration.sourceSpan node.qualifiedName declaration.parameters)
  ValueExternal declaration -> do
    -- Reject an unknown `from "reactor"` name up front (a typo / unimplemented reactor), rather than
    -- letting it silently default to the FFI reactor at runtime.
    checkExternalReactor declaration.sourceSpan declaration.reactor
    -- An external call performs io (impure): the strict, non-lifting call path + an un-dischargeable io
    -- effect that rides to the run root.
    signatureOnly (signatureValueScheme declaration.genericParameters declaration.parameters declaration.returnType declaration.effects True)
  ValuePrimitive declaration ->
    signatureOnly (signatureValueScheme declaration.genericParameters declaration.parameters declaration.returnType declaration.effects False)
  ValueRequest declaration -> signatureOnly (requestValueScheme declaration.sourceSpan node.qualifiedName declaration.parameters)
  where
    signatureOnly build = do
      scheme <- build
      pure (Map.singleton node.qualifiedName scheme, Map.empty)

-- | Check one (mutually) recursive component. Annotations are required (inference does not cross a
-- recursion). Walked in two passes: seed each member's scheme from its annotations, then check each
-- body against its own seed (with all seeds in scope).
checkCyclic ::
  List ValueNode ->
  Checker (Map QualifiedName Scheme, Map QualifiedName (AgentDeclaration Typed))
checkCyclic nodes = do
  seeds <- traverse seedOf nodes
  let seedMap = Map.fromList [(node.qualifiedName, scheme) | (node, _, _, scheme) <- seeds]
  typedAgents <-
    local (extendValueEnvironment seedMap) $
      foldM
        ( \acc (node, declaration, preparation, _) -> do
            typedDecl <- checkAgentBody declaration preparation
            pure (Map.insert node.qualifiedName typedDecl acc)
        )
        Map.empty
        seeds
  pure (seedMap, typedAgents)
  where
    -- Only agents can form a recursive component: every other value is signature-determined and has
    -- no value-level edges, so it is always an acyclic source. Prepare each member once and reuse
    -- the preparation for both the seed scheme and the body check.
    seedOf node = case node.declaration of
      ValueAgent declaration -> do
        preparation <- prepareAgent declaration
        scheme <- seedAgentType declaration preparation
        pure (node, declaration, preparation, scheme)
      _ -> panic "checkCyclic: only agents can form a recursive component"

-- | Build one module's 'Typed' AST. Each agent declaration is looked up by its identifier-resolved
-- identity in the typed-agent map (every top-level agent is a value node, so the entry always
-- exists — a miss is a compiler bug). Other declaration kinds are retagged structurally: their
-- typing is signature-only and already complete in the type environment.
buildTypedModule ::
  Map QualifiedName (AgentDeclaration Typed) ->
  Module Identified ->
  Module Typed
buildTypedModule typedAgents identifiedModule =
  Module
    { declarations = buildDeclaration <$> identifiedModule.declarations,
      sourceSpan = identifiedModule.sourceSpan
    }
  where
    buildDeclaration = \case
      DeclarationAgent declaration ->
        let qualifiedName = referencedVariableName declaration.variableReference
         in case Map.lookup qualifiedName typedAgents of
              Just typed -> DeclarationAgent typed
              Nothing -> panic ("buildTypedModule: no typed agent for " <> renderQualifiedName qualifiedName)
      DeclarationRequest declaration -> DeclarationRequest (retagRequestDeclaration declaration)
      DeclarationImport declaration -> DeclarationImport declaration
      DeclarationExternalAgent declaration -> DeclarationExternalAgent (retagExternalAgentDeclaration declaration)
      DeclarationPrimitiveAgent declaration -> DeclarationPrimitiveAgent (retagPrimitiveAgentDeclaration declaration)
      DeclarationData declaration -> DeclarationData (retagDataDeclaration declaration)
      DeclarationTypeSynonym declaration -> DeclarationTypeSynonym (retagTypeSynonymDeclaration declaration)
      DeclarationError errorSpan -> DeclarationError errorSpan
