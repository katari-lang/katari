-- | Lower Zonked AST to 'IRModule'.
--
-- 設計の概要は doc/ir-design 相当 / plan を参照。本モジュールは Zonked phase の
-- AST を入力に取り、型情報を捨てた 'IRModule' を返す。
--
-- パイプライン:
--
--   1. registerPrimitives — primitive 名 → BlockId を割当
--   2. registerDeclarationKinds — 全宣言の VariableId に kind/BlockId を予約
--   3. lowerAllDeclarations — 各宣言の本体を lower
module Katari.Lowering
  ( lowerProgram,
    LoweringError (..),
    toDiagnostic,
  )
where

import Control.Monad (foldM, forM, mapAndUnzipM)
import Control.Monad.Reader (ReaderT, asks, local, runReaderT)
import Control.Monad.State.Strict (State, gets, modify, runState)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Word (Word32)
import Katari.AST (Phase (Zonked))
import Katari.AST qualified as AST
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.IR
import Katari.Internal (internalErrorNoSpan)
import Katari.SourceSpan (SourceSpan)
import Katari.Id (VariableId)
import Katari.Id qualified as Id
import Katari.Typechecker.Zonker (ZonkResult (..))

-- ===========================================================================
-- Errors
-- ===========================================================================

data LoweringError where
  -- | Encountered a 'IdentifiedUnresolvedVariable' / 'Nothing'
  -- (parser/identifier produced a sentinel; cannot lower).
  LoweringErrorUnresolvedVariable :: SourceSpan -> Text -> LoweringError
  -- | A 'StatementError' / 'DeclarationError' sentinel left by parser
  -- recovery survived to Lowering.
  LoweringErrorParseSentinel :: SourceSpan -> LoweringError
  deriving (Eq, Show)

-- | Convert a 'LoweringError' to a unified 'Diagnostic'. Codes K0300-K0399
-- are reserved for the lowering pass.
toDiagnostic :: LoweringError -> Diagnostic
toDiagnostic = \case
  LoweringErrorUnresolvedVariable sourceSpan name ->
    diagnosticError
      "K0300"
      ("unresolved variable in lowering: '" <> name <> "'")
      sourceSpan
  LoweringErrorParseSentinel sourceSpan ->
    diagnosticError
      "K0301"
      "parser/identifier sentinel reached lowering (likely a recovery artifact)"
      sourceSpan

-- ===========================================================================
-- Primitive table
-- ===========================================================================

-- | Names of all primitive blocks. Block ids are assigned at the start of
-- lowering in a deterministic order (so test expectations are stable).
--
-- Literals do not use prim blocks: they are emitted as 'StatementLoadLiteral'
-- statements that carry the value directly.
primitiveNames :: [Text]
primitiveNames =
  [ -- arithmetic / comparison / logic
    "add",
    "sub",
    "mul",
    "div",
    "neg",
    "eq",
    "ne",
    "lt",
    "le",
    "gt",
    "ge",
    "and",
    "or",
    "not",
    "concat",
    -- aggregate construction / access
    "array_get",
    "array_length",
    "get_field",
    -- type
    "type_of",
    "to_string"
  ]

-- | Map an 'AST.BinaryOperator' to its primitive name.
binaryOpPrim :: AST.BinaryOperator -> Text
binaryOpPrim = \case
  AST.BinaryOperatorAdd -> "add"
  AST.BinaryOperatorSubtract -> "sub"
  AST.BinaryOperatorMultiply -> "mul"
  AST.BinaryOperatorDivide -> "div"
  AST.BinaryOperatorEqual -> "eq"
  AST.BinaryOperatorNotEqual -> "ne"
  AST.BinaryOperatorLessThan -> "lt"
  AST.BinaryOperatorLessOrEqual -> "le"
  AST.BinaryOperatorGreaterThan -> "gt"
  AST.BinaryOperatorGreaterOrEqual -> "ge"
  AST.BinaryOperatorAnd -> "and"
  AST.BinaryOperatorOr -> "or"
  AST.BinaryOperatorConcat -> "concat"

-- | Map an 'AST.UnaryOperator' to its primitive name.
unaryOpPrim :: AST.UnaryOperator -> Text
unaryOpPrim = \case
  AST.UnaryOperatorNegate -> "neg"
  AST.UnaryOperatorNot -> "not"

-- ===========================================================================
-- Lowering monad
--
-- 'Lower' は @ReaderT LowerEnv (State LowerState)@。
--
--   * 'LowerEnv' は scope-local な情報のみ。@local@ で透過的に save/restore
--     できるため、@bindLocal@ + 手書き restorer が不要になる。
--   * 'LowerState' は累積的な情報 (allocator counters / 既出 block 表 /
--     errors) と「現在 build 中の block の statements」(@lsCurrentEmitted@)。
--     Statements は逆順で蓄積し、block を確定させる時 (@runWithFreshBuffer@)
--     に一度だけ reverse して O(n) で取り出す。
-- ===========================================================================

newtype LowerEnv = LowerEnv
  { -- | 局所束縛: @let@ / 関数 param / pattern / local agent によって
    -- 導入された @VariableId → IRの VarId@。トップレベルの callable
    -- 解決は別途 'lsTopLevelBlocks' を見る。
    localVars :: Map VariableId VarId
  }

emptyLowerEnv :: LowerEnv
emptyLowerEnv = LowerEnv {localVars = Map.empty}

data LowerState = LowerState
  { lsNextBlockId :: Word32,
    lsNextVarId :: Word32,
    lsNextReqId :: Word32,
    lsNextCtorId :: Word32,
    lsBlocks :: Map BlockId Block,
    lsVarNames :: Map VarId Text,
    lsBlockNames :: Map BlockId Text,
    -- | Top-level @VariableId@ → its callable @BlockId@. Used at call /
    -- closure sites to resolve agent / req / ext-agent / data-ctor names.
    lsTopLevelBlocks :: Map VariableId BlockId,
    -- | Identifier-pass 'RequestId' → IR-internal 'ReqId'. Allocated at
    -- the start of lowering (one IR ReqId per Identifier RequestId, 1:1
    -- currently). Used by 'lowerHandler' / 'patternToArm' to translate
    -- Identifier resolution into the IR's runtime-dispatch id space.
    lsReqIds :: Map Id.RequestId ReqId,
    -- | Identifier-pass 'ConstructorId' → IR-internal 'CtorId'. Same
    -- pattern as 'lsReqIds'.
    lsCtorIds :: Map Id.ConstructorId CtorId,
    -- | FFI translation table: qualified name → BlockId. Populated as
    -- top-level callables are registered; surfaces in
    -- 'IRModule.entries'.
    lsEntries :: Map QualifiedName BlockId,
    lsPrimBlockIds :: Map Text BlockId,
    -- | Statements for the block currently being lowered, stored in
    -- reverse order. 'emit' prepends; 'runWithFreshBuffer' saves/restores
    -- and reverses at the end.
    lsCurrentEmitted :: [Statement],
    lsErrors :: [LoweringError]
  }

initialLowerState :: LowerState
initialLowerState =
  LowerState
    { lsNextBlockId = 0,
      lsNextVarId = 0,
      lsNextReqId = 0,
      lsNextCtorId = 0,
      lsBlocks = Map.empty,
      lsVarNames = Map.empty,
      lsBlockNames = Map.empty,
      lsTopLevelBlocks = Map.empty,
      lsReqIds = Map.empty,
      lsCtorIds = Map.empty,
      lsEntries = Map.empty,
      lsPrimBlockIds = Map.empty,
      lsCurrentEmitted = [],
      lsErrors = []
    }

type Lower = ReaderT LowerEnv (State LowerState)

freshBlockId :: Lower BlockId
freshBlockId = do
  blockId <- gets (BlockId . (.lsNextBlockId))
  modify (\state -> state {lsNextBlockId = state.lsNextBlockId + 1})
  pure blockId

freshVarId :: Maybe Text -> Lower VarId
freshVarId hint = do
  varId <- gets (VarId . (.lsNextVarId))
  modify
    ( \state ->
        state
          { lsNextVarId = state.lsNextVarId + 1,
            lsVarNames = case hint of
              Just name -> Map.insert varId name state.lsVarNames
              Nothing -> state.lsVarNames
          }
    )
  pure varId

freshReqId :: Lower ReqId
freshReqId = do
  reqId <- gets (ReqId . (.lsNextReqId))
  modify (\state -> state {lsNextReqId = state.lsNextReqId + 1})
  pure reqId

freshCtorId :: Lower CtorId
freshCtorId = do
  ctorId <- gets (CtorId . (.lsNextCtorId))
  modify (\state -> state {lsNextCtorId = state.lsNextCtorId + 1})
  pure ctorId

-- | Allocate one IR 'ReqId' per Identifier 'RequestId' and one IR
-- 'CtorId' per Identifier 'ConstructorId'. Stores both translation
-- tables in 'lsReqIds' / 'lsCtorIds'. Called once at the start of
-- 'lowerProgramM' before declaration walking begins.
allocateReqAndCtorIds :: ZonkResult -> Lower ()
allocateReqAndCtorIds zonkResult = do
  reqIdPairs <- forM (Map.keys zonkResult.zonkedRequests) $ \identRid -> do
    irReqId <- freshReqId
    pure (identRid, irReqId)
  ctorIdPairs <- forM (Map.keys zonkResult.zonkedConstructors) $ \identCid -> do
    irCtorId <- freshCtorId
    pure (identCid, irCtorId)
  modify $ \s ->
    s
      { lsReqIds = Map.fromList reqIdPairs,
        lsCtorIds = Map.fromList ctorIdPairs
      }

recordBlock :: BlockId -> Block -> Maybe Text -> Lower ()
recordBlock blockId block name =
  modify
    ( \s ->
        s
          { lsBlocks = Map.insert blockId block s.lsBlocks,
            lsBlockNames = case name of
              Just n -> Map.insert blockId n s.lsBlockNames
              Nothing -> s.lsBlockNames
          }
    )

reserveBlockId :: Maybe Text -> Lower BlockId
reserveBlockId name = do
  blockId <- freshBlockId
  case name of
    Just n -> modify (\state -> state {lsBlockNames = Map.insert blockId n state.lsBlockNames})
    Nothing -> pure ()
  pure blockId

recordError :: LoweringError -> Lower ()
recordError err = modify (\state -> state {lsErrors = err : state.lsErrors})

-- | Run an action with additional local variable bindings in scope. Uses
-- 'ReaderT' 'local' so cleanup is automatic — no manual restorer chain.
withLocals :: [(VariableId, VarId)] -> Lower a -> Lower a
withLocals binds = local $ \env ->
  env {localVars = Map.union (Map.fromList binds) env.localVars}

-- | Look up a local variable id in the current scope.
lookupLocal :: VariableId -> Lower (Maybe VarId)
lookupLocal variableId = asks (Map.lookup variableId . (.localVars))

-- ===========================================================================
-- Variable resolution
-- ===========================================================================

-- | Outcome of resolving a variable reference. An error has already been
-- recorded via 'recordError' before 'ResolvedVarUnresolved' is returned.
data ResolvedVar where
  ResolvedVarLocal :: VarId -> ResolvedVar
  ResolvedVarTopLevel :: BlockId -> ResolvedVar
  ResolvedVarUnresolved :: ResolvedVar

-- | Resolve a 'NameRefResolution' to a 'ResolvedVar'. Consults the local Reader
-- scope first (if @canBeLocal@), then the top-level block id map.
resolveVariable ::
  Bool ->
  AST.NameRefResolution Zonked AST.VariableRef ->
  SourceSpan ->
  Text ->
  Lower ResolvedVar
resolveVariable canBeLocal resolution sourceSpan nameText = case resolution of
  Nothing -> do
    recordError (LoweringErrorUnresolvedVariable sourceSpan nameText)
    pure ResolvedVarUnresolved
  Just variableId -> do
    mLocal <- if canBeLocal then lookupLocal variableId else pure Nothing
    case mLocal of
      Just irVar -> pure (ResolvedVarLocal irVar)
      Nothing -> do
        maybeBlockId <- gets (Map.lookup variableId . (.lsTopLevelBlocks))
        case maybeBlockId of
          Just blockId -> pure (ResolvedVarTopLevel blockId)
          Nothing -> do
            recordError (LoweringErrorUnresolvedVariable sourceSpan nameText)
            pure ResolvedVarUnresolved

-- | Resolve a variable reference in 'value' context: locals pass through,
-- top-level callables emit an implicit 'StatementMakeClosure'.
resolveAsValue ::
  Bool ->
  AST.NameRefResolution Zonked AST.VariableRef ->
  SourceSpan ->
  Text ->
  Maybe Text ->
  Lower VarId
resolveAsValue canBeLocal resolution sourceSpan nameText hint = do
  resolved <- resolveVariable canBeLocal resolution sourceSpan nameText
  case resolved of
    ResolvedVarLocal irVar -> pure irVar
    ResolvedVarTopLevel blockId -> do
      v <- freshVarId hint
      emit (StatementMakeClosure MakeClosureData {output = v, block = blockId})
      pure v
    ResolvedVarUnresolved -> freshVarId Nothing

-- | Resolve a variable reference in 'call-target' context: locals yield
-- 'CallTargetValue', top-level callables yield 'CallTargetBlock'.
resolveAsCallTarget ::
  Bool ->
  AST.NameRefResolution Zonked AST.VariableRef ->
  SourceSpan ->
  Text ->
  Lower CallTarget
resolveAsCallTarget canBeLocal resolution sourceSpan nameText = do
  resolved <- resolveVariable canBeLocal resolution sourceSpan nameText
  case resolved of
    ResolvedVarLocal irVar -> pure (CallTargetValue {var = irVar})
    ResolvedVarTopLevel blockId -> pure (CallTargetBlock {block = blockId})
    ResolvedVarUnresolved -> do
      v <- freshVarId Nothing
      pure (CallTargetValue {var = v})

-- | Resolve a primitive name to its 'BlockId'. The map is populated by
-- 'registerPrimitives' once at the start of lowering, so a missing entry
-- means the call site references a name that is not in 'primitiveNames'
-- — a compiler invariant violation, not a user error.
primBlockId :: Text -> Lower BlockId
primBlockId name = do
  ids <- gets (.lsPrimBlockIds)
  case Map.lookup name ids of
    Just blockId -> pure blockId
    Nothing -> internalErrorNoSpan ("primBlockId: unknown primitive " <> name)

-- ===========================================================================
-- Statement buffer (implicit via 'lsCurrentEmitted')
-- ===========================================================================

-- | Append a statement to the current block's emit buffer. Statements are
-- stored in reverse order in 'lsCurrentEmitted' for O(1) prepend; the
-- final list is reversed once when the block boundary is reached
-- ('runWithFreshBuffer').
emit :: Statement -> Lower ()
emit s = modify (\st -> st {lsCurrentEmitted = s : st.lsCurrentEmitted})

-- | Run an action with a fresh empty emit buffer; on completion, restore
-- the parent's buffer and return both the action's result and the
-- forward-ordered list of statements emitted during the action. Used at
-- block boundaries (e.g. when lowering an inline block / arm body).
runWithFreshBuffer :: Lower a -> Lower (a, [Statement])
runWithFreshBuffer action = do
  prev <- gets (.lsCurrentEmitted)
  modify (\st -> st {lsCurrentEmitted = []})
  result <- action
  emitted <- gets (.lsCurrentEmitted)
  modify (\st -> st {lsCurrentEmitted = prev})
  pure (result, reverse emitted)

-- ===========================================================================
-- UserBlock default template
-- ===========================================================================

-- | Empty 'UserBlock' template. The 5 different roles a block plays
-- (agent entry / agent-with-handlers / handle scope / handler body / inline
-- block) used to inline several lines of record syntax each; now they
-- record-update only the fields they care about.
--
-- The default @kind@ is 'BlockKindInline' (the most common role: inline
-- blocks / match-arm bodies / for bodies / then-clauses inherit the parent
-- scope). Sites with a different role override 'kind' explicitly.
defaultUserBlock :: UserBlock
defaultUserBlock =
  UserBlock
    { kind = BlockKindInline,
      parameters = [],
      statements = [],
      trailing = Nothing
    }

-- ===========================================================================
-- Entry
-- ===========================================================================

-- | Lower a 'ZonkResult' to an 'IRModule'. Returns the module plus any
-- structural lowering errors encountered. Errors do not abort the pipeline:
-- the resulting IR may be partial.
lowerProgram :: Text -> ZonkResult -> (IRModule, [LoweringError])
lowerProgram moduleName zonkResult =
  let (irModule, finalState) =
        runState (runReaderT (lowerProgramM moduleName zonkResult) emptyLowerEnv) initialLowerState
   in (irModule, reverse finalState.lsErrors)

lowerProgramM :: Text -> ZonkResult -> Lower IRModule
lowerProgramM moduleName zonkResult = do
  registerPrimitives
  -- Allocate one IR 'ReqId' per Identifier 'RequestId' (and one IR
  -- 'CtorId' per Identifier 'ConstructorId') so the handler / pattern
  -- match call sites can translate from the Identifier id space to the
  -- IR's runtime-dispatch id space.
  allocateReqAndCtorIds zonkResult
  registerDeclarationKinds zonkResult
  _ <- lowerAllDeclarations zonkResult
  state <- gets id
  pure
    IRModule
      { metadata = currentIRMetadata,
        name = moduleName,
        blocks = state.lsBlocks,
        entries = state.lsEntries,
        nameTable =
          NameTable
            { varNames = state.lsVarNames,
              blockNames = state.lsBlockNames
            }
      }

-- | Allocate one 'BlockPrim' per primitive name so call sites can resolve
-- by name → BlockId.
registerPrimitives :: Lower ()
registerPrimitives = mapM_ go primitiveNames
  where
    go primName = do
      blockId <- freshBlockId
      recordBlock blockId (BlockPrim {name = primName}) (Just ("prim:" <> primName))
      modify (\state -> state {lsPrimBlockIds = Map.insert primName blockId state.lsPrimBlockIds})

-- | Bind a top-level @VariableId@ to its callable @BlockId@.
recordVarBlockId :: VariableId -> BlockId -> Lower ()
recordVarBlockId variableId blockId =
  modify (\state -> state {lsTopLevelBlocks = Map.insert variableId blockId state.lsTopLevelBlocks})

-- Closure capture for local agents is handled by the runtime: a local
-- agent's body block runs with the parent scope visible (the runtime
-- consults a scope chain when resolving locals). Lowering therefore
-- preserves the outer 'localVars' Reader frame when entering a local
-- agent's body, and emits no per-block capture metadata. This is sound
-- because agent-side references to a state var read its current value
-- (state vars are only mutated inside @req@ handlers via @next@, which
-- a local agent cannot do without entering a different scope).

-- | Run @action@ with the resolved 'VariableId' from a top-level callable
-- declaration name. If the name didn't resolve (parser/identifier left an
-- 'Nothing' marker), record a Lowering error and skip.
registerCallable ::
  AST.NameRef Zonked AST.VariableRef ->
  SourceSpan ->
  (VariableId -> Lower ()) ->
  Lower ()
registerCallable nameRef sourceSpan action = case nameRef.resolution of
  Just variableId -> action variableId
  Nothing -> recordError (LoweringErrorUnresolvedVariable sourceSpan nameRef.text)

-- | Walk all declarations, registering each top-level agent / req / ext /
-- ctor's @VariableId → BlockId@ mapping. Bodies are filled in by
-- 'lowerAllDeclarations'.
--
-- The current module's name is threaded through so that 'BlockExternal'
-- entries can be stamped with @(moduleName, name)@ — that pair is how the
-- runtime sidecar will look up the JS implementation. The @\@"..."@
-- annotation on the declaration is documentation only and is dropped here
-- (it surfaces in the Schema layer instead, Phase 11).
registerDeclarationKinds :: ZonkResult -> Lower ()
registerDeclarationKinds zonkResult =
  mapM_ registerModule (Map.toList zonkResult.zonkedModules)
  where
    registerModule (moduleId, m) = do
      let moduleName = case Map.lookup moduleId zonkResult.zonkedModuleNames of
            Just name -> name
            Nothing -> internalErrorNoSpan "registerDeclarationKinds: ModuleId not in zonkedModuleNames (internal invariant violated)"
      mapM_ (registerDecl moduleName) m.declarations

    registerDecl :: Text -> AST.Declaration Zonked -> Lower ()
    registerDecl moduleName = \case
      AST.DeclarationAgent decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          blockId <- reserveBlockId (Just decl.name.text)
          recordVarBlockId variableId blockId
          recordEntry moduleName decl.name.text blockId
      AST.DeclarationRequest decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          blockId <- freshBlockId
          -- Look up the IR ReqId we pre-allocated for this Identifier RequestId
          -- (the request id slot of the @req@ name). Defensive fallback:
          -- allocate a fresh ReqId if missing (would indicate an upstream
          -- consistency bug).
          irReqId <- requestIdForVariable variableId
          recordBlock blockId (BlockRequest {reqId = irReqId}) (Just decl.name.text)
          recordVarBlockId variableId blockId
          recordEntry moduleName decl.name.text blockId
      AST.DeclarationExternalAgent decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          blockId <- freshBlockId
          let qualifiedName = QualifiedName {module_ = moduleName, name = decl.name.text}
          recordBlock
            blockId
            BlockExternal {externalName = ExternalName qualifiedName}
            (Just decl.name.text)
          recordVarBlockId variableId blockId
          recordEntry moduleName decl.name.text blockId
      AST.DeclarationData decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          blockId <- freshBlockId
          irCtorId <- constructorIdForVariable variableId
          recordBlock blockId (BlockCtor {ctorId = irCtorId}) (Just decl.name.text)
          recordVarBlockId variableId blockId
          recordEntry moduleName decl.name.text blockId
      AST.DeclarationImport _ -> pure ()
      AST.DeclarationTypeSynonym _ -> pure ()
      AST.DeclarationError sourceSpan -> recordError (LoweringErrorParseSentinel sourceSpan)

    -- \| O(1) lookup of the IR 'ReqId' for a @req@ declaration's call-side
    -- 'VariableId', using the pre-built inverse map in 'ZonkResult'.
    requestIdForVariable :: VariableId -> Lower ReqId
    requestIdForVariable variableId =
      case Map.lookup variableId zonkResult.zonkedRequestByVariable of
        Just requestId -> do
          mapped <- gets (Map.lookup requestId . (.lsReqIds))
          case mapped of
            Just irReqId -> pure irReqId
            Nothing -> internalErrorNoSpan "requestIdForVariable: ReqId not pre-allocated"
        Nothing -> internalErrorNoSpan "requestIdForVariable: VariableId not in zonkedRequestByVariable"

    constructorIdForVariable :: VariableId -> Lower CtorId
    constructorIdForVariable variableId =
      case Map.lookup variableId zonkResult.zonkedConstructorByVariable of
        Just constructorId -> do
          mapped <- gets (Map.lookup constructorId . (.lsCtorIds))
          case mapped of
            Just irCtorId -> pure irCtorId
            Nothing -> internalErrorNoSpan "constructorIdForVariable: CtorId not pre-allocated"
        Nothing -> internalErrorNoSpan "constructorIdForVariable: VariableId not in zonkedConstructorByVariable"

    recordEntry :: Text -> Text -> BlockId -> Lower ()
    recordEntry moduleName_ declName blockId =
      let qualifiedName = QualifiedName {module_ = moduleName_, name = declName}
       in modify (\state -> state {lsEntries = Map.insert qualifiedName blockId state.lsEntries})

lowerAllDeclarations :: ZonkResult -> Lower (Map Text BlockId)
lowerAllDeclarations zonkResult = do
  pairs <- concat <$> mapM lowerModule (Map.elems zonkResult.zonkedModules)
  pure (Map.fromList pairs)
  where
    lowerModule m = catMaybes <$> mapM lowerDeclaration m.declarations

    lowerDeclaration :: AST.Declaration Zonked -> Lower (Maybe (Text, BlockId))
    lowerDeclaration = \case
      AST.DeclarationAgent decl -> case decl.name.resolution of
        Just variableId -> do
          maybeBlockId <- gets (Map.lookup variableId . (.lsTopLevelBlocks))
          case maybeBlockId of
            Just blockId -> do
              lowerAgentDeclaration decl blockId
              pure (Just (decl.name.text, blockId))
            Nothing -> pure Nothing
        Nothing -> pure Nothing
      _ -> pure Nothing

-- ===========================================================================
-- Agent declaration
-- ===========================================================================

-- | Lower a top-level 'AgentDeclaration' into the reserved BlockId.
-- Produces a single 'BlockKindAgent' block that catches @return@.
lowerAgentDeclaration :: AST.AgentDeclaration Zonked -> BlockId -> Lower ()
lowerAgentDeclaration decl =
  lowerAgentLike decl.name.text decl.parameters decl.body

-- | Shared lowering shape for any \"agent-like\" callable: a top-level
-- 'AgentDeclaration', or a local 'AgentStatement'. Allocates param
-- slots, threads param destructuring as a prelude, and builds the
-- agent block.
lowerAgentLike ::
  Text ->
  [AST.ParameterBinding Zonked] ->
  AST.Block Zonked ->
  BlockId ->
  Lower ()
lowerAgentLike name parameters body blockId = do
  paramBindings <- mapM bindParam parameters
  let paramVars = map fst paramBindings
      paramPrelude = combineParamPreludes (map snd paramBindings)
  lowerSimpleAgent blockId name paramVars paramPrelude body

-- | Plain agent (no @where@): single block, @catchesReturn=True@. The
-- @prelude@ runs inside the block's buffer so any parameter destructuring
-- is emitted before the body proper.
lowerSimpleAgent ::
  BlockId ->
  Text ->
  [Param] ->
  Lower [(VariableId, VarId)] ->
  AST.Block Zonked ->
  Lower ()
lowerSimpleAgent blockId name paramVars prelude blk = do
  (trailing, statements) <- runWithFreshBuffer $ do
    locals <- prelude
    withLocals locals (lowerBlockInto blk)
  let userBlock =
        defaultUserBlock
          { kind = BlockKindAgent,
            parameters = paramVars,
            statements = statements,
            trailing = trailing
          }
  recordBlock blockId (BlockUser {body = userBlock}) (Just name)


-- | Lower a 'RequestHandler' to a 'BlockKindInline' user block.
-- The handler body inherits the handle scope (state vars are directly
-- accessible). Only req args are passed via 'parameters'.
-- The body's trailing value is treated as an implicit @break@; an explicit
-- 'StatementExit ExitKindBreak' is appended if the body completes normally.
--
-- @stateLocals@ is the @(VariableId, VarId)@ map already in scope via
-- 'withLocals'; it is passed here only so the caller's intent is explicit.
lowerHandler :: [(VariableId, VarId)] -> AST.RequestHandler Zonked -> Lower Handler
lowerHandler _stateLocals hr = do
  irReqId <- case hr.name.resolution of
    Just identRequestId -> do
      mapped <- gets (Map.lookup identRequestId . (.lsReqIds))
      case mapped of
        Just foundReqId -> pure foundReqId
        Nothing -> do
          recordError (LoweringErrorUnresolvedVariable hr.sourceSpan hr.name.text)
          freshReqId
    Nothing -> do
      recordError (LoweringErrorUnresolvedVariable hr.sourceSpan hr.name.text)
      freshReqId
  bodyBlockId <- freshBlockId
  paramBindings <- mapM bindParam hr.parameters
  let reqParamVars = map fst paramBindings
      paramPrelude = combineParamPreludes (map snd paramBindings)
  (trailing, statements) <- runWithFreshBuffer $ do
    locals <- paramPrelude
    withLocals locals (lowerBlockInto hr.body)
  let finalStatements = case trailing of
        Just t ->
          statements ++ [StatementExit ExitData {exitKind = ExitKindBreak, value = t}]
        Nothing -> statements
      userBlock =
        defaultUserBlock
          { kind = BlockKindInline,
            parameters = reqParamVars,
            statements = finalStatements
          }
  recordBlock bodyBlockId (BlockUser {body = userBlock}) (Just hr.name.text)
  pure Handler {request = irReqId, handlerBody = bodyBlockId}

-- | Lower the optional then-clause to its own block.
lowerThenClause ::
  Maybe (Maybe (AST.Pattern Zonked), AST.Block Zonked) ->
  Lower (Maybe BlockId)
lowerThenClause = \case
  Nothing -> pure Nothing
  Just (mpat, blk) -> do
    blockId <- freshBlockId
    -- The then block receives the body's tail as a single param. If the user
    -- wrote @then(p) { ... }@ we bind the pattern; otherwise we just use
    -- a wildcard.
    (paramVar, paramLocals) <- case mpat of
      Just pat -> bindPatternToFreshVar pat (Just "value")
      Nothing -> do
        v <- freshVarId (Just "value")
        pure (v, [])
    withLocals paramLocals $ do
      (statements, trailing) <- lowerBlockBody blk
      let userBlock =
            defaultUserBlock
              { parameters = [Param {label = "value", var = paramVar}],
                statements = statements,
                trailing = trailing
              }
      recordBlock blockId (BlockUser {body = userBlock}) Nothing
    pure (Just blockId)

-- | Bind a function parameter: allocate the param's IR var (the slot the
-- runtime populates) and return a deferred destructuring action.
--
-- The 'Param' is allocated immediately so callers can install the agent /
-- handler signature before the body runs. The 'Lower' action — to be run
-- inside the body's statement buffer — emits any 'tuple_get' / 'get_field'
-- projections needed for non-variable patterns and returns the
-- @(VariableId, VarId)@ pairs introduced.
bindParam :: AST.ParameterBinding Zonked -> Lower (Param, Lower [(VariableId, VarId)])
bindParam pb = do
  let nameHint = case pb.pattern of
        AST.PatternVariable vp -> Just vp.name.text
        _ -> Just pb.label
  var <- freshVarId nameHint
  pure (Param {label = pb.label, var = var}, destructurePattern var pb.pattern)

-- | Compose multiple parameter destructuring actions into a single
-- prelude that can be threaded into a body buffer.
combineParamPreludes :: [Lower [(VariableId, VarId)]] -> Lower [(VariableId, VarId)]
combineParamPreludes acts = concat <$> sequence acts

-- | Allocate a fresh IR var for an incoming value and destructure it by
-- emitting a single 'StatementBindPattern'. Returns the fresh 'VarId' and the
-- '(VariableId, VarId)' pairs to add to the local scope.
--
-- Irrefutability is guaranteed upstream by the Maranget exhaustiveness
-- checker (K0291); callers do not need to guard against refutable patterns.
bindPatternToFreshVar :: AST.Pattern Zonked -> Maybe Text -> Lower (VarId, [(VariableId, VarId)])
bindPatternToFreshVar pat hint = do
  let nameHint = case pat of
        AST.PatternVariable vp -> Just vp.name.text
        _ -> hint
  var <- freshVarId nameHint
  locals <- destructurePattern var pat
  pure (var, locals)

-- | Emit a 'StatementBindPattern' that destructures @incoming@ according to the
-- given AST pattern. Returns the '(VariableId, VarId)' pairs for all
-- variable sub-patterns; the runtime walks the pattern tree at execution time.
--
-- Irrefutability (no unguarded literal patterns) is guaranteed by the
-- Maranget exhaustiveness checker (K0291) before lowering runs.
destructurePattern :: VarId -> AST.Pattern Zonked -> Lower [(VariableId, VarId)]
destructurePattern incoming pat = do
  (matchPattern, locals) <- lowerPattern pat
  emit (StatementBindPattern BindPatternData {source = incoming, pattern = matchPattern})
  pure locals

-- ===========================================================================
-- Block body
-- ===========================================================================

-- | Lower a 'AST.Block' (statements + returnExpression) into a fresh
-- buffer. Returns the emitted statements and the optional trailing var
-- (the value of the block's tail expression, if any).
--
-- @let@ statements need to bring their bindings into scope for the
-- statements that follow. We thread that via 'withLocals' here rather
-- than letting 'lowerStmt' mutate the environment, which keeps the
-- 'ReaderT' contract intact (no @local-then-throw-away@ tricks).
lowerBlockBody :: AST.Block Zonked -> Lower ([Statement], Maybe VarId)
lowerBlockBody blk = do
  (trailing, statements) <- runWithFreshBuffer (lowerBlockInto blk)
  pure (statements, trailing)

-- | Lower a 'AST.Block''s contents into the *current* statement buffer.
-- Unlike 'lowerBlockBody' this does not allocate a fresh buffer — the
-- caller is responsible for the surrounding 'runWithFreshBuffer' (and
-- any 'withLocals') so prelude statements (e.g. match-arm destructuring)
-- can be emitted into the same buffer first.
lowerBlockInto :: AST.Block Zonked -> Lower (Maybe VarId)
lowerBlockInto blk = go blk.statements
  where
    go [] = traverse lowerExpr blk.returnExpression
    go (AST.StatementLet ls : rest) = do
      v <- lowerExpr ls.value
      locals <- bindPatternLocals v ls.pattern
      withLocals locals (go rest)
    go (AST.StatementAgent stmt : rest) = case stmt.name.resolution of
      Nothing -> do
        recordError (LoweringErrorUnresolvedVariable stmt.sourceSpan stmt.name.text)
        go rest
      Just variableId -> do
        blockId <- freshBlockId
        var <- freshVarId (Just stmt.name.text)
        withLocals [(variableId, var)] $ do
          lowerAgentLike stmt.name.text stmt.parameters stmt.body blockId
          emit (StatementMakeClosure MakeClosureData {output = var, block = blockId})
          go rest
    go (stmt : rest) = do
      exited <- lowerStmt stmt
      if exited then pure Nothing else go rest

-- ===========================================================================
-- Statements
-- ===========================================================================

-- | Lower one non-let, non-agent 'AST.Statement'. Statements are emitted
-- into the current buffer. Returns 'True' if this statement causes a
-- non-local exit (return/break/etc.) so the caller can stop emitting
-- further code.
--
-- 'StatementLet' and 'StatementAgent' are peeled off before reaching
-- this dispatch by 'lowerBlockInto.go', so both arms here are
-- 'internalError' guards.
lowerStmt :: AST.Statement Zonked -> Lower Bool
lowerStmt = \case
  AST.StatementLet _ ->
    internalErrorNoSpan "lowerStmt: StatementLet must be peeled by lowerBlockInto"
  AST.StatementReturn stmt -> do
    var <- lowerExpr stmt.value
    emit (StatementExit ExitData {exitKind = ExitKindReturn, value = var})
    pure True
  AST.StatementBreak stmt -> do
    var <- lowerExpr stmt.value
    emit (StatementExit ExitData {exitKind = ExitKindBreak, value = var})
    pure True
  AST.StatementForBreak stmt -> do
    var <- lowerExpr stmt.value
    emit (StatementExit ExitData {exitKind = ExitKindForBreak, value = var})
    pure True
  AST.StatementNext stmt -> do
    var <- lowerExpr stmt.value
    modPairs <- mapM lowerModifier stmt.modifiers
    emit (StatementCont ContData {contKind = ContKindNext, value = Just var, modifiers = modPairs})
    pure True
  AST.StatementForNext stmt -> do
    modPairs <- mapM lowerModifier stmt.modifiers
    emit (StatementCont ContData {contKind = ContKindForNext, value = Nothing, modifiers = modPairs})
    pure True
  AST.StatementExpression expr -> do
    _ <- lowerExpr expr
    pure False
  AST.StatementAgent _ ->
    internalErrorNoSpan "lowerStmt: StatementAgent must be peeled by lowerBlockInto"
  AST.StatementError sourceSpan -> do
    recordError (LoweringErrorParseSentinel sourceSpan)
    pure False

-- | Lower one 'AST.Modifier' producing @(targetVar, newValueVar)@.
-- 'targetVar' is the state var's VarId in the enclosing loop/handle scope,
-- resolved via 'lookupLocal' using the Modifier's 'VariableId'.
lowerModifier :: AST.Modifier Zonked -> Lower (VarId, VarId)
lowerModifier m = do
  newValue <- lowerExpr m.value
  targetVar <- case m.name.resolution of
    Just variableId -> do
      mLocal <- lookupLocal variableId
      case mLocal of
        Just v -> pure v
        Nothing -> do
          recordError (LoweringErrorUnresolvedVariable m.sourceSpan m.name.text)
          freshVarId Nothing
    Nothing -> do
      recordError (LoweringErrorUnresolvedVariable m.sourceSpan m.name.text)
      freshVarId Nothing
  pure (targetVar, newValue)

-- | Emit a 'StatementBindPattern' for an incoming IR var and return the
-- '(VariableId, VarId)' pairs to bring into scope via 'withLocals'.
bindPatternLocals :: VarId -> AST.Pattern Zonked -> Lower [(VariableId, VarId)]
bindPatternLocals = destructurePattern

-- ===========================================================================
-- Expressions
-- ===========================================================================

-- | Lower an 'AST.Expression'. Returns the IR var holding the value;
-- statements are emitted into the current buffer.
lowerExpr :: AST.Expression Zonked -> Lower VarId
lowerExpr = \case
  AST.ExpressionLiteral lit -> lowerLiteral lit
  AST.ExpressionVariable variableExpression -> lowerVariable variableExpression
  AST.ExpressionBinaryOperator binaryExpr -> do
    lhs <- lowerExpr binaryExpr.left
    rhs <- lowerExpr binaryExpr.right
    out <- freshVarId Nothing
    blockId <- primBlockId (binaryOpPrim binaryExpr.operator)
    emit $
      StatementCall
        CallData
          { target = CallTargetBlock {block = blockId},
            arguments = [Arg "lhs" lhs, Arg "rhs" rhs],
            output = Just out
          }
    pure out
  AST.ExpressionUnaryOperator unaryExpr -> do
    operand <- lowerExpr unaryExpr.operand
    out <- freshVarId Nothing
    blockId <- primBlockId (unaryOpPrim unaryExpr.operator)
    emit $
      StatementCall
        CallData
          { target = CallTargetBlock {block = blockId},
            arguments = [Arg "operand" operand],
            output = Just out
          }
    pure out
  AST.ExpressionCall callExpr -> lowerCall callExpr
  AST.ExpressionTuple tupleExpr -> lowerTupleExpr False tupleExpr.elements
  AST.ExpressionArray arrayExpr -> lowerArrayExpr False arrayExpr.elements
  AST.ExpressionFieldAccess fieldAccessExpr -> do
    object <- lowerExpr fieldAccessExpr.object
    -- Field name is loaded as a string literal; get_field consumes
    -- (object, field).
    fieldVar <- emitLoadLiteral (LiteralValueString fieldAccessExpr.fieldName.text)
    out <- freshVarId Nothing
    blockId <- primBlockId "get_field"
    emit $
      StatementCall
        CallData
          { target = CallTargetBlock {block = blockId},
            arguments = [Arg "object" object, Arg "field" fieldVar],
            output = Just out
          }
    pure out
  AST.ExpressionIndexAccess indexAccessExpr -> do
    array <- lowerExpr indexAccessExpr.array
    index <- lowerExpr indexAccessExpr.index
    out <- freshVarId Nothing
    blockId <- primBlockId "array_get"
    emit $
      StatementCall
        CallData
          { target = CallTargetBlock {block = blockId},
            arguments = [Arg "array" array, Arg "index" index],
            output = Just out
          }
    pure out
  AST.ExpressionTemplate templateExpr -> lowerTemplate templateExpr
  AST.ExpressionBlock blockExpr -> lowerBlockExpr blockExpr
  AST.ExpressionIf ifExpr -> lowerIfExpr ifExpr
  AST.ExpressionMatch matchExpr -> lowerMatchExpr matchExpr
  AST.ExpressionFor forExpr -> lowerForExpr forExpr
  AST.ExpressionHandle handleExpr -> lowerHandleExpr handleExpr
  AST.ExpressionParTuple parTupleExpr -> lowerTupleExpr True parTupleExpr.elements
  AST.ExpressionParArray parArrayExpr -> lowerArrayExpr True parArrayExpr.elements
  AST.ExpressionQualifiedReference qualifiedRefExpr ->
    -- Qualified references never bind locally.
    resolveAsValue
      False
      qualifiedRefExpr.target.resolution
      qualifiedRefExpr.sourceSpan
      qualifiedRefExpr.target.text
      (Just qualifiedRefExpr.target.text)

-- | Lower a function call. Decides whether to emit a static 'CallTargetBlock' call
-- (when the callee resolves to a top-level decl / ctor / prim) or a closure
-- 'CallTargetValue' call (when the callee is a local variable holding a function).
lowerCall :: AST.CallExpression Zonked -> Lower VarId
lowerCall callExpression = do
  argVars <- mapM (lowerExpr . (.value)) callExpression.arguments
  let callArgs = zipWith Arg (map (.label.text) callExpression.arguments) argVars
  target <- resolveCallee callExpression.callee
  out <- freshVarId Nothing
  emit (StatementCall CallData {target = target, arguments = callArgs, output = Just out})
  pure out

-- | Resolve an expression that's used in the callee position.
resolveCallee :: AST.Expression Zonked -> Lower CallTarget
resolveCallee = \case
  AST.ExpressionVariable variableExpression ->
    resolveAsCallTarget True variableExpression.name.resolution variableExpression.sourceSpan variableExpression.name.text
  AST.ExpressionQualifiedReference qualifiedRefExpr ->
    -- Qualified references never bind locally.
    resolveAsCallTarget False qualifiedRefExpr.target.resolution qualifiedRefExpr.sourceSpan qualifiedRefExpr.target.text
  other -> do
    var <- lowerExpr other
    pure (CallTargetValue {var = var})

-- | Lower an 'AST.TemplateExpression' as a left-fold of @concat@ prim
-- calls.
lowerTemplate :: AST.TemplateExpression Zonked -> Lower VarId
lowerTemplate templateExpression = do
  vars <- mapM lowerTemplateElement templateExpression.elements
  case vars of
    [] -> emitLoadLiteral (LiteralValueString "")
    [single] -> stringify single
    (first : rest) -> do
      initVar <- stringify first
      foldM concatStep initVar rest
  where
    stringify v = do
      blockId <- primBlockId "to_string"
      out <- freshVarId Nothing
      emit $
        StatementCall
          CallData
            { target = CallTargetBlock {block = blockId},
              arguments = [Arg "value" v],
              output = Just out
            }
      pure out

    concatStep lhs rhsRaw = do
      rhs <- stringify rhsRaw
      blockId <- primBlockId "concat"
      out <- freshVarId Nothing
      emit $
        StatementCall
          CallData
            { target = CallTargetBlock {block = blockId},
              arguments = [Arg "lhs" lhs, Arg "rhs" rhs],
              output = Just out
            }
      pure out

lowerTemplateElement :: AST.TemplateElement Zonked -> Lower VarId
lowerTemplateElement = \case
  AST.TemplateElementString tse -> emitLoadLiteral (LiteralValueString tse.value)
  AST.TemplateElementExpression tee -> lowerExpr tee.value

-- ===========================================================================
-- Inline block / control-flow expressions
-- ===========================================================================

-- | Lower an inline block expression @{ stmts; tail }@. We create a child
-- 'UserBlock' (kind = 'BlockInline', so it shares the parent's scope) and
-- emit a static call to it.
lowerBlockExpr :: AST.BlockExpression Zonked -> Lower VarId
lowerBlockExpr blockExpression = do
  childBlockId <- buildInlineBlock blockExpression.block
  out <- freshVarId Nothing
  emit $
    StatementCall
      CallData
        { target = CallTargetBlock {block = childBlockId},
          arguments = [],
          output = Just out
        }
  pure out

-- | Build an inline block (inheritScope=True, no boundary catches) and return
-- its newly minted BlockId.
buildInlineBlock :: AST.Block Zonked -> Lower BlockId
buildInlineBlock blk = do
  blockId <- freshBlockId
  (statements, trailing) <- lowerBlockBody blk
  let userBlock =
        defaultUserBlock
          { statements = statements,
            trailing = trailing
          }
  recordBlock blockId (BlockUser {body = userBlock}) Nothing
  pure blockId

-- | Lower an if expression as 'StatementMatch' on a boolean subject. The "true"
-- branch is matched by tag @"true"@; the else branch (or implicit null
-- block) is the default.
lowerIfExpr :: AST.IfExpression Zonked -> Lower VarId
lowerIfExpr ifExpression = do
  cond <- lowerExpr ifExpression.condition
  thenBlockId <- buildInlineBlock ifExpression.thenBlock
  defaultBlockId <- traverse buildInlineBlock ifExpression.elseBlock
  matchBlockId <- freshBlockId
  recordBlock matchBlockId
    (BlockMatch
      { matchBlock = MatchBlock
          { subject = cond,
            arms =
              [ MatchArm
                  { pattern = MatchPatternLiteral LiteralValueBoolean {boolean = True},
                    body = thenBlockId
                  }
              ],
            defaultArm = defaultBlockId
          }
      })
    Nothing
  out <- freshVarId Nothing
  emit $
    StatementCall
      CallData
        { target = CallTargetBlock {block = matchBlockId},
          arguments = [],
          output = Just out
        }
  pure out

-- | Lower a match expression. Each source arm becomes one IR
-- 'MatchArm' carrying the full nested 'MatchPattern' tree; the runtime
-- walks that tree against the subject, binds matched sub-values to the
-- 'VarId's introduced by 'MatchPatternVariable', and jumps into the arm's body
-- on success. Falling through (no arm matches) hits 'defaultArm' if
-- the match has an unconditional arm, else the runtime errors.
--
-- Compared to compiling each nested refutable position into a separate
-- inner 'StatementMatch', this design keeps the IR 1:1 with the source
-- @match@: all dispatch / binding logic lives in one place at the
-- runtime, and arbitrary nesting / overlap-on-tag arms work naturally
-- (the runtime tries arms in source order).
lowerMatchExpr :: AST.MatchExpression Zonked -> Lower VarId
lowerMatchExpr matchExpression = do
  subject <- lowerExpr matchExpression.subject
  arms <- mapM lowerMatchArm matchExpression.cases
  matchBlockId <- freshBlockId
  recordBlock matchBlockId
    (BlockMatch
      { matchBlock = MatchBlock
          { subject = subject,
            arms = arms,
            defaultArm = Nothing
          }
      })
    Nothing
  out <- freshVarId Nothing
  emit $
    StatementCall
      CallData
        { target = CallTargetBlock {block = matchBlockId},
          arguments = [],
          output = Just out
        }
  pure out

-- | Lower one source arm. Translate the AST pattern to an IR
-- 'MatchPattern' and collect every binding (Identifier 'VariableId' →
-- IR 'VarId') the pattern introduces, so the arm body block can read
-- them as locals.
lowerMatchArm :: AST.CaseArm Zonked -> Lower MatchArm
lowerMatchArm arm = do
  (irPat, locals) <- lowerPattern arm.pattern
  body <- buildArmBodyWithLocals locals arm.body
  pure MatchArm {pattern = irPat, body = body}

-- | Translate an AST 'Pattern' to an IR 'MatchPattern'. Each variable
-- pattern allocates a fresh 'VarId' (the runtime will bind the matched
-- sub-value into it) and records an Identifier→IR mapping so the arm
-- body's lowering can resolve user-side variable references.
lowerPattern :: AST.Pattern Zonked -> Lower (MatchPattern, [(VariableId, VarId)])
lowerPattern = \case
  AST.PatternVariable vp -> case vp.name.resolution of
    Just variableId -> do
      var <- freshVarId (Just vp.name.text)
      pure (MatchPatternVariable var, [(variableId, var)])
    Nothing -> do
      recordError (LoweringErrorUnresolvedVariable vp.sourceSpan vp.name.text)
      pure (MatchPatternAny, [])
  AST.PatternWildcard _ -> pure (MatchPatternAny, [])
  AST.PatternLiteral lp -> pure (MatchPatternLiteral (literalValueToIR lp.value), [])
  AST.PatternTuple tp -> do
    (subs, localss) <- mapAndUnzipM lowerPattern tp.elements
    pure (MatchPatternTuple subs, concat localss)
  AST.PatternQualifiedConstructor qp -> do
    irCtorId <- case qp.constructorName.resolution of
      Just identCtorId -> do
        mapped <- gets (Map.lookup identCtorId . (.lsCtorIds))
        case mapped of
          Just resolvedCtorId -> pure resolvedCtorId
          Nothing -> do
            recordError
              (LoweringErrorUnresolvedVariable qp.sourceSpan qp.constructorName.text)
            freshCtorId
      Nothing -> do
        recordError
          (LoweringErrorUnresolvedVariable qp.sourceSpan qp.constructorName.text)
        freshCtorId
    pairs <- forM qp.parameters $ \(labelRef, sub) -> do
      (subPat, subLocals) <- lowerPattern sub
      pure ((labelRef.text, subPat), subLocals)
    let fields = map fst pairs
        locals = concatMap snd pairs
    pure (MatchPatternConstructor irCtorId fields, locals)

literalValueToIR :: AST.LiteralValue -> LiteralValue
literalValueToIR = \case
  AST.LiteralValueBoolean b -> LiteralValueBoolean {boolean = b}
  AST.LiteralValueNull -> LiteralValueNull
  AST.LiteralValueInteger n -> LiteralValueInteger {integer = n}
  AST.LiteralValueNumber n -> LiteralValueNumber {number = n}
  AST.LiteralValueString s -> LiteralValueString {string = s}

-- | Build a child block for a match arm body. The given locals (from
-- pattern bindings) are added to the Reader scope before lowering the
-- body, so user-side variable references resolve to the right
-- 'VarId's.
buildArmBodyWithLocals :: [(VariableId, VarId)] -> AST.Block Zonked -> Lower BlockId
buildArmBodyWithLocals locals blk = do
  blockId <- freshBlockId
  (trailing, statements) <-
    runWithFreshBuffer (withLocals locals (lowerBlockInto blk))
  let userBlock =
        defaultUserBlock
          { statements = statements,
            trailing = trailing
          }
  recordBlock blockId (BlockUser {body = userBlock}) Nothing
  pure blockId

-- | Lower a for expression. Supports zero or more 'in' bindings, zero or
-- more 'var' (state) bindings, and an optional then-block.
lowerForExpr :: AST.ForExpression Zonked -> Lower VarId
lowerForExpr forExpression = do
  (iterPairs, iterLocals) <- lowerForIters forExpression.inBindings
  (stateInits, stateLocals) <- lowerForStates forExpression.varBindings
  bodyBlockId <- buildForBody (iterLocals ++ stateLocals) forExpression.body
  thenBlockId <- traverse buildInlineBlock forExpression.thenBlock
  forBlockId <- freshBlockId
  recordBlock forBlockId
    (BlockFor
      { forBlock = ForBlock
          { parallel = forExpression.parallel,
            iters = iterPairs,
            stateInits = stateInits,
            bodyBlock = bodyBlockId,
            thenBlock = thenBlockId
          }
      })
    Nothing
  out <- freshVarId Nothing
  emit $
    StatementCall
      CallData
        { target = CallTargetBlock {block = forBlockId},
          arguments = [],
          output = Just out
        }
  pure out

-- | Lower @for(p in arr) ...@ bindings. Each element-pattern variable
-- receives a fresh IR var; the source array is lowered to a var.
-- Returns @[(elementVar, sourceVar)]@ and the locals to add to the body
-- scope.
lowerForIters ::
  [AST.ForInBinding Zonked] ->
  Lower ([(VarId, VarId)], [(VariableId, VarId)])
lowerForIters bindings = do
  results <- mapM one bindings
  pure (map fst results, concatMap snd results)
  where
    one b = do
      sourceVar <- lowerExpr b.source
      (elementVar, locals) <- bindPatternToFreshVar b.pattern Nothing
      pure ((elementVar, sourceVar), locals)

-- | Lower @for(... )(var s = init) ...@ state bindings. Returns
-- @(stateInits, stateLocals)@ where @stateInits = [(bodyVar, initVar)]@
-- (no Text labels) and @stateLocals@ maps each state var's VariableId to
-- its bodyVar so the for body can resolve references via 'lookupLocal'.
lowerForStates ::
  [AST.ForVarBinding Zonked] ->
  Lower ([(VarId, VarId)], [(VariableId, VarId)])
lowerForStates bindings = do
  results <- mapM one bindings
  pure (map fst (catMaybes results), concatMap snd (catMaybes results))
  where
    one binding = do
      let nameRef = binding.name
      initVar <- lowerExpr binding.initial
      case nameRef.resolution of
        Just variableId -> do
          bodyVar <- freshVarId (Just nameRef.text)
          pure (Just ((bodyVar, initVar), [(variableId, bodyVar)]))
        Nothing -> do
          recordError (LoweringErrorUnresolvedVariable binding.sourceSpan nameRef.text)
          pure Nothing

buildForBody :: [(VariableId, VarId)] -> AST.Block Zonked -> Lower BlockId
buildForBody locals body = do
  blockId <- freshBlockId
  withLocals locals $ do
    (statements, trailing) <- lowerBlockBody body
    let userBlock =
          defaultUserBlock
            { statements = statements,
              trailing = trailing
            }
    recordBlock blockId (BlockUser {body = userBlock}) Nothing
  pure blockId

-- ===========================================================================
-- Tuple / Array / Handle expression lowering
-- ===========================================================================

-- | Lower a tuple expression (sequential or parallel) to a 'BlockTuple'.
-- Each element is lowered into its own inline block.
lowerTupleExpr :: Bool -> [AST.Expression Zonked] -> Lower VarId
lowerTupleExpr isParallel elements = do
  elementBlockIds <- mapM buildElementBlock elements
  tupleBlockId <- freshBlockId
  recordBlock tupleBlockId
    (BlockTuple
      { tupleBlock = TupleBlock
          { parallel = isParallel,
            elements = elementBlockIds
          }
      })
    Nothing
  out <- freshVarId Nothing
  emit $
    StatementCall
      CallData
        { target = CallTargetBlock {block = tupleBlockId},
          arguments = [],
          output = Just out
        }
  pure out

-- | Lower an array expression (sequential or parallel) to a 'BlockArray'.
-- Each element is lowered into its own inline block.
lowerArrayExpr :: Bool -> [AST.Expression Zonked] -> Lower VarId
lowerArrayExpr isParallel elements = do
  elementBlockIds <- mapM buildElementBlock elements
  arrayBlockId <- freshBlockId
  recordBlock arrayBlockId
    (BlockArray
      { arrayBlock = ArrayBlock
          { parallel = isParallel,
            elements = elementBlockIds
          }
      })
    Nothing
  out <- freshVarId Nothing
  emit $
    StatementCall
      CallData
        { target = CallTargetBlock {block = arrayBlockId},
          arguments = [],
          output = Just out
        }
  pure out

-- | Lower a single expression into its own inline block (used for
-- tuple/array element blocks).
buildElementBlock :: AST.Expression Zonked -> Lower BlockId
buildElementBlock expr = do
  blockId <- freshBlockId
  (trailing, statements) <- runWithFreshBuffer (Just <$> lowerExpr expr)
  let userBlock =
        defaultUserBlock
          { statements = statements,
            trailing = trailing
          }
  recordBlock blockId (BlockUser {body = userBlock}) Nothing
  pure blockId

-- | Lower a handle expression (Koka-style). State vars are evaluated in
-- the current scope; the body (continuation) and handlers are built as
-- child blocks, then a 'BlockHandle' is constructed and called.
lowerHandleExpr :: AST.HandleExpression Zonked -> Lower VarId
lowerHandleExpr handleExpr = do
  bodyBlockId <- freshBlockId
  -- Evaluate state var inits in outer scope.
  stateBinds <- mapM mkHandleStateInit handleExpr.stateVariables
  let stateInits_ = [(bodyVar, initVar) | (_, bodyVar, initVar) <- stateBinds]
      stateLocals = [(variableId, bodyVar) | (Just variableId, bodyVar, _) <- stateBinds]
  withLocals stateLocals $ do
    -- Body block (the continuation).
    (bodyTrailing, bodyStatements) <- runWithFreshBuffer (lowerBlockInto handleExpr.body)
    recordBlock bodyBlockId
      (BlockUser {body = defaultUserBlock {kind = BlockKindInline, statements = bodyStatements, trailing = bodyTrailing}})
      Nothing
    -- Handlers.
    handlerList <- mapM (lowerHandler stateLocals) handleExpr.handlers
    -- Then clause.
    thenBlockId <- lowerThenClause handleExpr.thenClause
    -- Record BlockHandle and call it.
    handleBlockId <- freshBlockId
    recordBlock handleBlockId
      (BlockHandle
        { handleBlock = HandleBlock
            { parallel = handleExpr.parallel,
              stateInits = stateInits_,
              body = bodyBlockId,
              handlers = handlerList,
              thenBlock = thenBlockId
            }
        })
      Nothing
    out <- freshVarId Nothing
    emit $
      StatementCall
        CallData
          { target = CallTargetBlock {block = handleBlockId},
            arguments = [],
            output = Just out
          }
    pure out
  where
    mkHandleStateInit ::
      AST.StateVariableBinding Zonked ->
      Lower (Maybe VariableId, VarId, VarId)
    mkHandleStateInit svb = do
      initVar <- lowerExpr svb.initial
      case svb.name.resolution of
        Just variableId -> do
          bodyVar <- freshVarId (Just svb.name.text)
          pure (Just variableId, bodyVar, initVar)
        Nothing -> do
          recordError (LoweringErrorUnresolvedVariable svb.sourceSpan svb.name.text)
          bodyVar <- freshVarId Nothing
          pure (Nothing, bodyVar, initVar)

-- | Emit a fresh load-literal statement and return the resulting var.
emitLoadLiteral :: LiteralValue -> Lower VarId
emitLoadLiteral literalValue = do
  outputVar <- freshVarId Nothing
  emit (StatementLoadLiteral LoadLiteralData {output = outputVar, value = literalValue})
  pure outputVar

-- | Lower an 'AST.LiteralExpression' as an 'StatementLoadLiteral'.
lowerLiteral :: AST.LiteralExpression Zonked -> Lower VarId
lowerLiteral lit = emitLoadLiteral (literalValueToIR lit.value)

-- | Lower an 'AST.VariableExpression'. Result depends on whether the
-- referenced 'VariableId' is a local binding (just return its IR var) or
-- a top-level decl (allocate a closure value via 'StatementMakeClosure').
lowerVariable :: AST.VariableExpression Zonked -> Lower VarId
lowerVariable variableExpression =
  resolveAsValue True variableExpression.name.resolution variableExpression.sourceSpan variableExpression.name.text (Just variableExpression.name.text)
