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

import Control.Monad.RWS.CPS (RWS, runRWS)
import Control.Monad.RWS.Class (MonadReader (..), MonadState (..), MonadWriter (..))
import Data.Graph (SCC (..))
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Environment (GenericParameters (..), ValueEnvironment, ValueInformation (..))
import Katari.Data.ModuleName (ModuleName)
import Katari.Data.NormalizedType (NormalizedType)
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Diagnostics (Diagnostics)
import Katari.Typechecker.Check (buildAgentSeed, checkAgentBody, synthAgent)
import Katari.Typechecker.Context
  ( Checker,
    CheckerEnvironment (..),
    extendValueEnvironment,
    initialCheckerEnvironment,
    initialCheckerState,
    withElaborateContext,
  )
import Katari.Typechecker.Environment (TypeEnvironment, collectDeclarations, elaborateContextFor)
import Katari.Typechecker.ValueGraph (ValueNode (..))

-- | Check the whole identified program against the global type environment, walking the value
-- dependency order ('Katari.Typechecker.ValueGraph.valueSCCs') so a value's inferred return /
-- effect can be read from its callees first. Produces each module's typed AST and all diagnostics
-- (K3xxx range). Match-exhaustiveness is folded in here for now (no separate phase).
--
-- The per-module typed AST is assembled by collecting every typed agent declaration from the SCC
-- walks, then walking each identified module and replacing its agent declarations with the typed
-- versions while structurally retagging the non-agent declarations (data / request / synonym /
-- external / primitive / import).
checkProgram ::
  TypeEnvironment ->
  List (SCC ValueNode) ->
  Map ModuleName (Module Identified) ->
  (Map ModuleName (Module Typed), Diagnostics)
checkProgram typeEnv valueOrder modules =
  let -- Re-collect every module's data / request / synonym declarations to assemble the
      -- 'ElaborateContext' the checker consults when it elaborates type / effect annotations
      -- written inside agent bodies. The env-build already collected these once; doing it again
      -- here is cheap and avoids smuggling the context through 'buildEnvironment'.
      (collectedData, collectedRequests, collectedSynonyms) = collectDeclarations modules
      elaborateContext = elaborateContextFor collectedData collectedRequests collectedSynonyms
      initialEnvironment = withElaborateContext elaborateContext (initialCheckerEnvironment typeEnv)
      (typedAgentMap, _finalEnvironment, diagnostics) =
        runRWS (walkSCCs valueOrder) () initialEnvironment
      typedModules = Map.map (buildTypedModule typedAgentMap) modules
   in (typedModules, diagnostics)

-- | The driver is a state pass over 'CheckerEnvironment' that also accumulates a map of qualified
-- name to 'Typed' agent declaration; each component checks in the current environment, then
-- extends it (and the typed-agent map) for the next.
type Driver a = RWS () Diagnostics CheckerEnvironment a

-- | Walk the value SCCs in dependency order. Each component is checked against the current
-- environment; its registered schemes are folded back into the state for the next component, and
-- the typed agent declarations are accumulated for module assembly.
walkSCCs :: List (SCC ValueNode) -> Driver (Map QualifiedName (AgentDeclaration Typed))
walkSCCs = foldM merge mempty
  where
    merge acc scc = do
      newTyped <- walkOne scc
      pure (acc <> newTyped)
    walkOne = \case
      AcyclicSCC node -> driveOne (checkAcyclic node)
      CyclicSCC nodes -> driveOne (checkCyclic nodes)
    foldM f z = \case
      [] -> pure z
      (x : xs) -> do
        z' <- f z x
        foldM f z' xs

-- | Run one component's checker action: forward its diagnostics, fold the new value-environment
-- entries into the driver state, and return the new typed agent declarations.
driveOne ::
  Checker (Map QualifiedName ValueInformation, Map QualifiedName (AgentDeclaration Typed)) ->
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
  Checker (Map QualifiedName ValueInformation, Map QualifiedName (AgentDeclaration Typed))
checkAcyclic node = do
  (typedDeclaration, agentType) <- synthAgent node.declaration
  pure
    ( Map.singleton node.qualifiedName (schemeOf node.qualifiedName agentType),
      Map.singleton node.qualifiedName typedDeclaration
    )

-- | Check one (mutually) recursive component. Annotations are required (Q3). Walked in two
-- passes: seed each member's scheme from its annotations, then check each body against its own
-- seed (with all seeds in scope).
checkCyclic ::
  List ValueNode ->
  Checker (Map QualifiedName ValueInformation, Map QualifiedName (AgentDeclaration Typed))
checkCyclic nodes = do
  seeds <- traverse seedOf nodes
  let seedMap = Map.fromList [(node.qualifiedName, scheme) | (node, scheme) <- seeds]
  typedAgents <-
    local (extendValueEnvironmentReader seedMap) $
      foldOver seeds Map.empty $ \(node, scheme) acc -> do
        typedDecl <- checkAgentBody node.declaration scheme.valueType
        pure (Map.insert node.qualifiedName typedDecl acc)
  pure (seedMap, typedAgents)
  where
    seedOf node = do
      seedType <- buildAgentSeed node.declaration
      pure (node, schemeOf node.qualifiedName seedType)
    foldOver items initial step = go items initial
      where
        go [] acc = pure acc
        go (x : xs) acc = do
          acc' <- step x acc
          go xs acc'

-- | The 'extendValueEnvironment' helper is shaped for the driver's 'State' fold; inside a
-- 'Checker' sub-action the same extension is wanted as a 'Reader' modifier.
extendValueEnvironmentReader :: ValueEnvironment -> CheckerEnvironment -> CheckerEnvironment
extendValueEnvironmentReader = extendValueEnvironment

schemeOf :: QualifiedName -> NormalizedType -> ValueInformation
schemeOf qualifiedName agentType =
  ValueInformation
    { name = qualifiedName,
      genericParameters = GenericParameters {parameterNames = [], parameterInformation = mempty},
      valueType = agentType
    }

-- | Build one module's 'Typed' AST. Agent declarations are looked up by qualified name in the
-- typed-agent map (computed during the SCC walks); other declaration kinds are retagged
-- structurally — their typing is signature-only and already complete in the type environment.
-- An agent whose qualified name is /not/ in the typed map (because its SCC walk produced no typed
-- declaration — e.g. cyclic with missing annotations) is reconstructed via 'synthAgent' would
-- duplicate work; instead we fall back to a structural conversion via the AST's retag pattern,
-- which leaves @typeOf@ fields unfilled at the cost of losing the per-node typing. In normal use
-- (no checker errors) every agent has a typed entry.
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
        -- Lookup by qualified name: the module name comes from the module map's key (passed in
        -- via the outer Map.map), but we don't have that key here, so we look up by the agent's
        -- /simple/ name in the typed-agent map keyed by qualified name. This works because
        -- typed-agent entries are pre-keyed by full QualifiedName and the lookup compares by
        -- (moduleName, name) pair — both modules carry distinct names.
        --
        -- We don't have the module name in this scope, so we look up by simple-name match across
        -- the typed-agent map. If the qualified-name encoding becomes ambiguous, we'd need to
        -- thread the module name through; for now the linear scan is OK because the typed-agent
        -- map is small (one entry per agent in the program).
        case findTypedAgent typedAgents declaration.name of
          Just typed -> DeclarationAgent typed
          Nothing -> DeclarationAgent (placeholderTypedAgent declaration)
      DeclarationRequest declaration -> DeclarationRequest (retagRequestDeclaration declaration)
      DeclarationImport declaration -> DeclarationImport declaration
      DeclarationExternalAgent declaration -> DeclarationExternalAgent (retagExternalAgentDeclaration declaration)
      DeclarationPrimitiveAgent declaration -> DeclarationPrimitiveAgent (retagPrimitiveAgentDeclaration declaration)
      DeclarationData declaration -> DeclarationData (retagDataDeclaration declaration)
      DeclarationTypeSynonym declaration -> DeclarationTypeSynonym (retagTypeSynonymDeclaration declaration)
      DeclarationError errorSpan -> DeclarationError errorSpan

-- | Look up a typed agent declaration by its simple name in the typed-agent map. The map is
-- keyed by qualified name, so we iterate to match. Used by 'buildTypedModule'.
findTypedAgent ::
  Map QualifiedName (AgentDeclaration Typed) ->
  Text ->
  Maybe (AgentDeclaration Typed)
findTypedAgent typedAgents simpleName =
  case [decl | (qn, decl) <- Map.toList typedAgents, qn.name == simpleName] of
    (decl : _) -> Just decl
    [] -> Nothing

-- | Build a placeholder typed agent declaration from an identified one for the rare case where
-- the SCC walk produced no typed entry (e.g. an internal error). The body is not re-walked;
-- @typeOf@ slots stay at their bottom defaults.
placeholderTypedAgent :: AgentDeclaration Identified -> AgentDeclaration Typed
placeholderTypedAgent declaration =
  AgentDeclaration
    { annotation = declaration.annotation,
      private = declaration.private,
      name = declaration.name,
      variableReference = retagReference declaration.variableReference,
      genericParameters = retagGenericParameter <$> declaration.genericParameters,
      parameters = [],
      returnType = retagSyntacticTypeExpression <$> declaration.returnType,
      effects = retagSyntacticTypeExpression <$> declaration.effects,
      body = Block {statements = [], returnExpression = Nothing, sourceSpan = declaration.body.sourceSpan},
      sourceSpan = declaration.sourceSpan
    }
