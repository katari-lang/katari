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

import Control.Monad (foldM, forM)
import Control.Monad.Reader (ReaderT, asks, local, runReaderT)
import Control.Monad.State.Strict (State, gets, modify, runState)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32)
import Katari.AST (Phase (Zonked))
import Katari.AST qualified as AST
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.IR
import Katari.Internal (internalErrorNoSpan)
import Katari.Typechecker.Identifier (VariableId)
import Katari.Typechecker.Identifier qualified as Identifier
import Katari.Typechecker.Zonker (ZonkResult (..))

-- ===========================================================================
-- Errors
-- ===========================================================================

data LoweringError where
  -- | Encountered a 'IdentifiedUnresolvedVariable' / 'Nothing'
  -- (parser/identifier produced a sentinel; cannot lower).
  LoweringErrorUnresolvedVariable :: AST.SourceSpan -> Text -> LoweringError
  -- | A 'StatementError' / 'DeclarationError' sentinel left by parser
  -- recovery survived to Lowering.
  LoweringErrorParseSentinel :: AST.SourceSpan -> LoweringError
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
    "make_array",
    "make_tuple",
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
  { lsNextBlockId :: !Word32,
    lsNextVarId :: !Word32,
    lsNextReqId :: !Word32,
    lsNextCtorId :: !Word32,
    lsBlocks :: !(Map BlockId Block),
    lsVarNames :: !(Map VarId Text),
    lsBlockNames :: !(Map BlockId Text),
    -- | Top-level @VariableId@ → its callable @BlockId@. Used at call /
    -- closure sites to resolve agent / req / ext-agent / data-ctor names.
    lsTopLevelBlocks :: !(Map VariableId BlockId),
    -- | Identifier-pass 'RequestId' → IR-internal 'ReqId'. Allocated at
    -- the start of lowering (one IR ReqId per Identifier RequestId, 1:1
    -- currently). Used by 'lowerHandler' / 'patternToArm' to translate
    -- Identifier resolution into the IR's runtime-dispatch id space.
    lsReqIds :: !(Map Identifier.RequestId ReqId),
    -- | Identifier-pass 'ConstructorId' → IR-internal 'CtorId'. Same
    -- pattern as 'lsReqIds'.
    lsCtorIds :: !(Map Identifier.ConstructorId CtorId),
    -- | FFI translation table: qualified name → BlockId. Populated as
    -- top-level callables are registered; surfaces in
    -- 'IRModule.entries'.
    lsEntries :: !(Map QualifiedName BlockId),
    lsPrimBlockIds :: !(Map Text BlockId),
    -- | Statements for the block currently being lowered, stored in
    -- reverse order. 'emit' prepends; 'runWithFreshBuffer' saves/restores
    -- and reverses at the end.
    lsCurrentEmitted :: ![Statement],
    lsErrors :: ![LoweringError]
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
  state <- gets id
  let blockId = BlockId state.lsNextBlockId
  modify (\s -> s {lsNextBlockId = s.lsNextBlockId + 1})
  pure blockId

freshVarId :: Maybe Text -> Lower VarId
freshVarId hint = do
  state <- gets id
  let varId = VarId state.lsNextVarId
  modify
    ( \s ->
        s
          { lsNextVarId = s.lsNextVarId + 1,
            lsVarNames = case hint of
              Just name -> Map.insert varId name s.lsVarNames
              Nothing -> s.lsVarNames
          }
    )
  pure varId

freshReqId :: Lower ReqId
freshReqId = do
  state <- gets id
  let reqId = ReqId state.lsNextReqId
  modify (\s -> s {lsNextReqId = s.lsNextReqId + 1})
  pure reqId

freshCtorId :: Lower CtorId
freshCtorId = do
  state <- gets id
  let ctorId = CtorId state.lsNextCtorId
  modify (\s -> s {lsNextCtorId = s.lsNextCtorId + 1})
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
    Just n -> modify (\s -> s {lsBlockNames = Map.insert blockId n s.lsBlockNames})
    Nothing -> pure ()
  pure blockId

recordError :: LoweringError -> Lower ()
recordError err = modify (\s -> s {lsErrors = err : s.lsErrors})

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
  ResolvedVarLocal :: !VarId -> ResolvedVar
  ResolvedVarTopLevel :: !BlockId -> ResolvedVar
  ResolvedVarUnresolved :: ResolvedVar

-- | Resolve a 'NameMeta' to a 'ResolvedVar'. Consults the local Reader
-- scope first (if @canBeLocal@), then the top-level block id map.
resolveVariable ::
  Bool ->
  AST.NameMeta Zonked 'AST.VariableRef ->
  AST.SourceSpan ->
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
  AST.NameMeta Zonked 'AST.VariableRef ->
  AST.SourceSpan ->
  Text ->
  Maybe Text ->
  Lower VarId
resolveAsValue canBeLocal resolution sourceSpan nameText hint = do
  resolved <- resolveVariable canBeLocal resolution sourceSpan nameText
  case resolved of
    ResolvedVarLocal irVar -> pure irVar
    ResolvedVarTopLevel blockId -> do
      v <- freshVarId hint
      emit (StatementMakeClosure MakeClosureData {output = v, block = blockId, captures = []})
      pure v
    ResolvedVarUnresolved -> freshVarId Nothing

-- | Resolve a variable reference in 'call-target' context: locals yield
-- 'CallTargetValue', top-level callables yield 'CallTargetBlock'.
resolveAsCallTarget ::
  Bool ->
  AST.NameMeta Zonked 'AST.VariableRef ->
  AST.SourceSpan ->
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
-- block) used to inline 13 lines of record syntax each; now they record-
-- update only the fields they care about.
--
-- The default @kind@ is 'BlockInline' (the most common role: inline blocks /
-- match-arm bodies / for bodies / then-clauses inherit the parent scope).
-- Sites with a different role override 'kind' explicitly.
defaultUserBlock :: UserBlock
defaultUserBlock =
  UserBlock
    { kind = BlockInline,
      captures = [],
      parameters = [],
      stateVars = [],
      statements = [],
      trailing = Nothing,
      thenBlock = Nothing,
      handlers = []
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
      modify (\s -> s {lsPrimBlockIds = Map.insert primName blockId s.lsPrimBlockIds})

-- | Bind a top-level @VariableId@ to its callable @BlockId@.
recordVarBlockId :: VariableId -> BlockId -> Lower ()
recordVarBlockId variableId blockId =
  modify (\s -> s {lsTopLevelBlocks = Map.insert variableId blockId s.lsTopLevelBlocks})

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
  AST.NameRef Zonked 'AST.VariableRef ->
  AST.SourceSpan ->
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
    registerModule (_, m) = do
      mapM_ (registerDecl m.moduleName) m.declarations

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

    -- | O(1) lookup of the IR 'ReqId' for a @req@ declaration's call-side
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
       in modify (\s -> s {lsEntries = Map.insert qualifiedName blockId s.lsEntries})

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
--
-- Layouts produced:
--
-- * No @where@ clause: single block with @catchesReturn=True@.
-- * @where { handlers... }@ (no state vars): single block with both
--   @catchesReturn=True@ and @catchesBreak=True@; handlers attached.
-- * @where (var s = init) { handlers... }@: outer/inner split. Outer is the
--   agent entry (@catchesReturn=True@, fresh scope), computes init expressions,
--   then calls the inner block. Inner is the handle scope
--   (@catchesBreak=True@, inheritScope=True), receives @s@ as a state var,
--   has handlers attached and runs the body.
lowerAgentDeclaration :: AST.AgentDeclaration Zonked -> BlockId -> Lower ()
lowerAgentDeclaration decl =
  lowerAgentLike decl.name.text decl.parameters decl.body

-- | Shared lowering shape for any \"agent-like\" callable: a top-level
-- 'AgentDeclaration', or a local 'AgentStatement'. Allocates the param
-- slots, threads param destructuring as a buffer prelude, and dispatches
-- on the body's optional 'WhereBlock' to choose the user-block layout.
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
  case body.whereBlock of
    Nothing ->
      lowerSimpleAgent blockId name paramVars paramPrelude body
    Just wb
      | null wb.stateVariables ->
          lowerAgentWithHandlers blockId name paramVars paramPrelude body wb
      | otherwise ->
          lowerAgentWithStateVars blockId name paramVars paramPrelude body wb

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
          { kind = BlockAgentEntry,
            parameters = paramVars,
            statements = statements,
            trailing = trailing
          }
  recordBlock blockId (BlockUser {body = userBlock}) (Just name)

-- | Agent with @where { handlers... }@ (no state vars): single block that
-- catches both Return and Break. The @prelude@ runs inside this block's
-- buffer; handler / then bodies see the destructured locals via Reader.
lowerAgentWithHandlers ::
  BlockId ->
  Text ->
  [Param] ->
  Lower [(VariableId, VarId)] ->
  AST.Block Zonked ->
  AST.WhereBlock Zonked ->
  Lower ()
lowerAgentWithHandlers blockId name paramVars prelude blk wb = do
  ((paramLocals, trailing), statements) <- runWithFreshBuffer $ do
    locals <- prelude
    t <- withLocals locals (lowerBlockInto (stripWhereBlock blk))
    pure (locals, t)
  (handlers, thenBlockId) <- withLocals paramLocals $ do
    hs <- mapM (lowerHandler []) wb.handlers
    tb <- lowerThenClause wb.thenClause
    pure (hs, tb)
  let userBlock =
        defaultUserBlock
          { kind = BlockAgentEntryWithHandlers,
            parameters = paramVars,
            statements = statements,
            trailing = trailing,
            thenBlock = thenBlockId,
            handlers = handlers
          }
  recordBlock blockId (BlockUser {body = userBlock}) (Just name)

-- | Agent with @where (var s = init) ...@: outer/inner split. The
-- @prelude@ runs inside the *outer* block (where the runtime delivers the
-- parameters), and the destructured locals are visible to the inner block via
-- the Reader env (the inner is 'BlockHandleScope' which inherits the
-- outer scope at runtime).
lowerAgentWithStateVars ::
  BlockId ->
  Text ->
  [Param] ->
  Lower [(VariableId, VarId)] ->
  AST.Block Zonked ->
  AST.WhereBlock Zonked ->
  Lower ()
lowerAgentWithStateVars outerId name paramVars prelude blk wb = do
  innerOut <- freshVarId Nothing
  (_, outerStatements) <- runWithFreshBuffer $ do
    paramLocals <- prelude
    withLocals paramLocals $ do
      innerBlockId <- buildInnerBlockWithState name wb blk
      stateInitVars <- lowerStateInits wb.stateVariables
      let innerArgs = [Arg {label = lbl, var = v} | (lbl, v) <- stateInitVars]
      emit $
        StatementCall
          CallData
            { target = CallTargetBlock {block = innerBlockId},
              arguments = innerArgs,
              output = Just innerOut
            }
  let outerBlock =
        defaultUserBlock
          { kind = BlockAgentEntry,
            parameters = paramVars,
            statements = outerStatements,
            trailing = Just innerOut
          }
  recordBlock outerId (BlockUser {body = outerBlock}) (Just name)

-- | Lower the @stateVariables@ of a 'WhereBlock' in the parent's scope.
-- Init expression statements are emitted into the current buffer; returns
-- only the @(label, initVar)@ pairs.
lowerStateInits ::
  [AST.StateVariableBinding Zonked] ->
  Lower [(Text, VarId)]
lowerStateInits = mapM $ \svb -> do
  initVar <- lowerExpr svb.initial
  pure (svb.name.text, initVar)

-- | Build the inner handle-scope block (with state vars, handlers, and the
-- agent body). The block expects state vars as labeled parameters; its body runs
-- the original block's statements and may issue 'StatementExit ExitKindBreak' which the
-- runtime catches at this block.
buildInnerBlockWithState ::
  Text ->
  AST.WhereBlock Zonked ->
  AST.Block Zonked ->
  Lower BlockId
buildInnerBlockWithState parentName wb blk = do
  innerBlockId <- freshBlockId
  -- Allocate fresh IR vars for state vars and bind their VariableIds.
  stateBinds <- mapM mkStateParam wb.stateVariables
  let stateParams = [p | (_, p, _) <- stateBinds]
      stateLocals = [(variableId, p.var) | (Just variableId, p, _) <- stateBinds]
  withLocals stateLocals $ do
    (statements, trailing) <- lowerBlockBody (stripWhereBlock blk)
    handlers <- mapM (lowerHandler stateParams) wb.handlers
    thenBlockId <- lowerThenClause wb.thenClause
    let userBlock =
          defaultUserBlock
            { kind = BlockHandleScope,
              stateVars = stateParams,
              statements = statements,
              trailing = trailing,
              thenBlock = thenBlockId,
              handlers = handlers
            }
    recordBlock innerBlockId (BlockUser {body = userBlock}) (Just (parentName <> ":inner"))
  pure innerBlockId
  where
    mkStateParam ::
      AST.StateVariableBinding Zonked ->
      Lower (Maybe VariableId, Param, AST.StateVariableBinding Zonked)
    mkStateParam svb =
      let nameText = svb.name.text
       in case svb.name.resolution of
            Just variableId -> do
              v <- freshVarId (Just nameText)
              pure (Just variableId, Param {label = nameText, var = v}, svb)
            Nothing -> do
              recordError (LoweringErrorUnresolvedVariable svb.sourceSpan nameText)
              v <- freshVarId Nothing
              pure (Nothing, Param {label = nameText, var = v}, svb)

-- | Lower a 'RequestHandler' to its own user block. Handler parameters are
-- @[req arguments ..., state vars (as labels) ...]@. The body's trailing value is
-- treated as an implicit @break@ (Koka-style); we append an explicit
-- 'StatementExit ExitKindBreak' if the body completes normally.
lowerHandler :: [Param] -> AST.RequestHandler Zonked -> Lower Handler
lowerHandler stateParams hr = do
  -- Resolve the request's BlockId via the top-level VariableId → BlockId
  -- map. Failure modes (unresolved name, or not actually a 'BlockRequest')
  -- record an error and fall back to a fresh placeholder so lowering can
  -- continue producing partial IR for diagnostics.
  -- Identifier resolved the handler's @name@ to a 'RequestId' (the
  -- 'RequestRef' slot guarantees this is a @req@ declaration). The
  -- IR-level 'ReqId' allocated for that 'RequestId' lives in 'lsReqIds'
  -- and is what the runtime compares against when a request is raised.
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
  -- Build the handler block. Param destructuring (if any) runs inside
  -- the handler body's buffer so projection statements live alongside
  -- the body proper.
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
          { kind = BlockHandlerBody,
            parameters = reqParamVars ++ stateParams,
            statements = finalStatements
          }
  recordBlock bodyBlockId (BlockUser {body = userBlock}) (Just hr.name.text)
  pure Handler {request = irReqId, handlerBody = bodyBlockId}

-- | Lower the optional then-clause of a 'WhereBlock' to its own block.
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

-- | Strip a block's whereBlock, returning the statements / returnExpression
-- portion only. Used so 'lowerBlockBody' doesn't try to re-process it.
stripWhereBlock :: AST.Block Zonked -> AST.Block Zonked
stripWhereBlock blk = blk {AST.whereBlock = Nothing}

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
  (mp, locals) <- lowerPattern pat
  emit (StatementBindPattern BindPatternData {source = incoming, pattern = mp})
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
          emit (StatementMakeClosure MakeClosureData {output = var, block = blockId, captures = []})
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

-- | Lower one 'AST.Modifier' producing @(label, value-bearing IR var)@. The
-- expression for the new value emits statements into the current buffer.
lowerModifier :: AST.Modifier Zonked -> Lower (Text, VarId)
lowerModifier m = do
  var <- lowerExpr m.value
  pure (m.name.text, var)

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
  AST.ExpressionVariable ve -> lowerVariable ve
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
  AST.ExpressionTuple tupleExpr -> do
    elements <- mapM lowerExpr tupleExpr.elements
    out <- freshVarId Nothing
    blockId <- primBlockId "make_tuple"
    emit $
      StatementCall
        CallData
          { target = CallTargetBlock {block = blockId},
            arguments = zipWith mkIndexedArg [0 ..] elements,
            output = Just out
          }
    pure out
  AST.ExpressionArray arrayExpr -> do
    elements <- mapM lowerExpr arrayExpr.elements
    out <- freshVarId Nothing
    blockId <- primBlockId "make_array"
    emit $
      StatementCall
        CallData
          { target = CallTargetBlock {block = blockId},
            arguments = zipWith mkIndexedArg [0 ..] elements,
            output = Just out
          }
    pure out
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
  AST.ExpressionQualifiedReference qualifiedRefExpr ->
    -- Qualified references never bind locally.
    resolveAsValue
      False
      qualifiedRefExpr.target.resolution
      qualifiedRefExpr.sourceSpan
      qualifiedRefExpr.target.text
      (Just qualifiedRefExpr.target.text)

-- | Make an Arg with an indexed label like @"_0"@, @"_1"@, … for tuple /
-- array literal construction.
mkIndexedArg :: Int -> VarId -> Arg
mkIndexedArg i var = Arg {label = "_" <> Text.pack (show i), var = var}

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
  AST.ExpressionVariable ve ->
    resolveAsCallTarget True ve.name.resolution ve.sourceSpan ve.name.text
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
  out <- freshVarId Nothing
  emit $
    StatementMatch
      MatchData
        { subject = cond,
          arms =
            [ MatchArm
                { pattern = MatchPatternLiteral LiteralValueBoolean {boolean = True},
                  body = thenBlockId
                }
            ],
          defaultArm = defaultBlockId,
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
  out <- freshVarId Nothing
  arms <- mapM lowerMatchArm matchExpression.cases
  emit $
    StatementMatch
      MatchData
        { subject = subject,
          arms = arms,
          defaultArm = Nothing,
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
    (subs, localss) <- unzip <$> mapM lowerPattern tp.elements
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
  out <- freshVarId Nothing
  emit $
    StatementFor
      ForData
        { iters = iterPairs,
          stateInits = stateInits,
          bodyBlock = bodyBlockId,
          thenBlock = thenBlockId,
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
lowerForIters bs = do
  results <- mapM one bs
  pure (map fst results, concatMap snd results)
  where
    one b = do
      sourceVar <- lowerExpr b.source
      (elementVar, locals) <- bindPatternToFreshVar b.pattern Nothing
      pure ((elementVar, sourceVar), locals)

-- | Lower @for(... )(var s = init) ...@ state bindings. Returns
-- @(stateInits, stateLocals)@; the element body needs the state vars as
-- fresh IR vars (one per state var), exposed through the local map.
lowerForStates ::
  [AST.ForVarBinding Zonked] ->
  Lower ([(Text, VarId)], [(VariableId, VarId)])
lowerForStates bindings = do
  results <- mapM one bindings
  pure (map fst (catMaybes results), concatMap snd (catMaybes results))
  where
    one binding = do
      let nameRef = binding.name
          labelText = nameRef.text
      initVar <- lowerExpr binding.initial
      case nameRef.resolution of
        Just variableId -> do
          bodyVar <- freshVarId (Just labelText)
          pure (Just ((labelText, initVar), [(variableId, bodyVar)]))
        Nothing -> do
          recordError (LoweringErrorUnresolvedVariable binding.sourceSpan labelText)
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

-- | Emit a fresh load-literal statement and return the resulting var.
emitLoadLiteral :: LiteralValue -> Lower VarId
emitLoadLiteral lv = do
  out <- freshVarId Nothing
  emit (StatementLoadLiteral LoadLiteralData {output = out, value = lv})
  pure out

-- | Lower an 'AST.LiteralExpression' as an 'StatementLoadLiteral'.
lowerLiteral :: AST.LiteralExpression Zonked -> Lower VarId
lowerLiteral lit = emitLoadLiteral (literalValueToIR lit.value)

-- | Lower an 'AST.VariableExpression'. Result depends on whether the
-- referenced 'VariableId' is a local binding (just return its IR var) or
-- a top-level decl (allocate a closure value via 'StatementMakeClosure').
lowerVariable :: AST.VariableExpression Zonked -> Lower VarId
lowerVariable ve =
  resolveAsValue True ve.name.resolution ve.sourceSpan ve.name.text (Just ve.name.text)
