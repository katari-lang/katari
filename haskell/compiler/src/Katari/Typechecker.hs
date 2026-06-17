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
import Katari.Data.Environment (Scheme (..))
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.QualifiedName (QualifiedName, renderQualifiedName)
import Katari.Diagnostics (Diagnostics)
import Katari.Panic (panic)
import Katari.Typechecker.Check (checkAgentBody, prepareAgent, seedAgentType, synthAgent)
import Katari.Typechecker.Context
  ( Checker,
    CheckerEnvironment,
    extendValueEnvironment,
    initialCheckerEnvironment,
    initialCheckerState,
  )
import Katari.Typechecker.Environment (TypeEnvironment)
import Katari.Typechecker.ValueGraph (ValueNode (..))

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
  (Map ModuleName (Module Typed), Diagnostics)
checkProgram typeEnv valueOrder modules =
  let (typedAgents, _finalEnvironment, diagnostics) =
        runRWS (walkSCCs valueOrder) () (initialCheckerEnvironment typeEnv)
   in (buildTypedModule typedAgents <$> modules, diagnostics)

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

-- | Check one non-recursive component. Annotation policy is optional — a missing return type is
-- synthesized from the body, a missing effect defaults to pure. The typed agent declaration is
-- returned for module assembly.
checkAcyclic ::
  ValueNode ->
  Checker (Map QualifiedName Scheme, Map QualifiedName (AgentDeclaration Typed))
checkAcyclic node = do
  (typedDeclaration, scheme) <- synthAgent node.declaration
  pure
    ( Map.singleton node.qualifiedName scheme,
      Map.singleton node.qualifiedName typedDeclaration
    )

-- | Check one (mutually) recursive component. Annotations are required (inference does not cross a
-- recursion). Walked in two passes: seed each member's scheme from its annotations, then check each
-- body against its own seed (with all seeds in scope).
checkCyclic ::
  List ValueNode ->
  Checker (Map QualifiedName Scheme, Map QualifiedName (AgentDeclaration Typed))
checkCyclic nodes = do
  seeds <- traverse seedOf nodes
  let seedMap = Map.fromList [(node.qualifiedName, scheme) | (node, _, scheme) <- seeds]
  typedAgents <-
    local (extendValueEnvironment seedMap) $
      foldM
        ( \acc (node, preparation, scheme) -> do
            typedDecl <- checkAgentBody node.declaration preparation scheme.valueType
            pure (Map.insert node.qualifiedName typedDecl acc)
        )
        Map.empty
        seeds
  pure (seedMap, typedAgents)
  where
    -- Prepare each member once (parameters elaborated, attributes computed) and reuse that
    -- preparation for both the seed scheme and the body check, so nothing is done twice.
    seedOf node = do
      preparation <- prepareAgent node.declaration
      scheme <- seedAgentType node.declaration preparation
      pure (node, preparation, scheme)

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
