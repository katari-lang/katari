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

import Control.Monad (foldM, forM, zipWithM)
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
import Katari.Typechecker.Identifier
  ( ConstructorData (..),
    RequestData (..),
    VariableId,
  )
import Katari.Typechecker.Identifier qualified as Identifier
import Katari.Typechecker.Zonker (ZonkResult (..))

-- ===========================================================================
-- Errors
-- ===========================================================================

data LoweringError
  = -- | Encountered a 'IdentifiedUnresolvedVariable' / 'Nothing'
    -- (parser/identifier produced a sentinel; cannot lower).
    LowerErrorUnresolvedVariable AST.SourceSpan Text
  | -- | A 'StatementError' / 'DeclarationError' sentinel left by parser
    -- recovery survived to Lowering.
    LowerErrorParseSentinel AST.SourceSpan
  | -- | A construct the lowering does not yet support (ext agent in module
    -- without server annotation, qualified ref out of scope, etc.).
    LowerErrorUnsupported AST.SourceSpan Text
  deriving (Eq, Show)

-- | Convert a 'LoweringError' to a unified 'Diagnostic'. Codes K0300-K0399
-- are reserved for the lowering pass.
toDiagnostic :: LoweringError -> Diagnostic
toDiagnostic = \case
  LowerErrorUnresolvedVariable sp name ->
    diagnosticError
      "K0300"
      ("unresolved variable in lowering: '" <> name <> "'")
      sp
  LowerErrorParseSentinel sp ->
    diagnosticError
      "K0301"
      "parser/identifier sentinel reached lowering (likely a recovery artifact)"
      sp
  LowerErrorUnsupported sp detail ->
    diagnosticError
      "K0302"
      ("unsupported construct in lowering: " <> detail)
      sp

-- ===========================================================================
-- Primitive table
-- ===========================================================================

-- | Names of all primitive blocks. Block ids are assigned at the start of
-- lowering in a deterministic order (so test expectations are stable).
--
-- Literals do not use prim blocks: they are emitted as 'SLoadLiteral'
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
    "tuple_get",
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
  { -- | 局所束縛: @let@ / 関数 param / pattern によって導入された
    -- @VariableId → IRの VarId@。トップレベルの callable 解決は別途
    -- 'lsVarBlockIds' を見る。
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
    lsVarBlockIds :: !(Map VariableId BlockId),
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
      lsVarBlockIds = Map.empty,
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
allocateReqAndCtorIds zr = do
  reqIdPairs <- forM (Map.keys zr.zonkedRequests) $ \identRid -> do
    rid <- freshReqId
    pure (identRid, rid)
  ctorIdPairs <- forM (Map.keys zr.zonkedConstructors) $ \identCid -> do
    cid <- freshCtorId
    pure (identCid, cid)
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
lookupLocal vid = asks (Map.lookup vid . (.localVars))

primBlockId :: Text -> Lower BlockId
primBlockId name = do
  ids <- gets (.lsPrimBlockIds)
  case Map.lookup name ids of
    Just blockId -> pure blockId
    Nothing -> error ("primBlockId: unknown primitive " <> Text.unpack name)

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
      params = [],
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
      { name = moduleName,
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
  modify (\s -> s {lsVarBlockIds = Map.insert variableId blockId s.lsVarBlockIds})

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
registerCallable nameRef sp action = case nameRef.resolution of
  Just variableId -> action variableId
  Nothing -> recordError (LowerErrorUnresolvedVariable sp nameRef.text)

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
    registerModule (mid, m) = do
      let moduleName = Map.findWithDefault "" mid zonkResult.zonkedModuleNames
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
          rid <- requestIdForVariable variableId
          recordBlock blockId (BlockRequest {reqId = rid}) (Just decl.name.text)
          recordVarBlockId variableId blockId
          recordEntry moduleName decl.name.text blockId
      AST.DeclarationExternalAgent decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          blockId <- freshBlockId
          let qn = QualifiedName {module_ = moduleName, name = decl.name.text}
          recordBlock
            blockId
            BlockExternal {externalName = ExternalName qn}
            (Just decl.name.text)
          recordVarBlockId variableId blockId
          recordEntry moduleName decl.name.text blockId
      AST.DeclarationData decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          blockId <- freshBlockId
          cid <- constructorIdForVariable variableId
          recordBlock blockId (BlockCtor {ctorId = cid}) (Just decl.name.text)
          recordVarBlockId variableId blockId
          recordEntry moduleName decl.name.text blockId
      AST.DeclarationImport _ -> pure ()
      AST.DeclarationTypeSynonym _ -> pure ()
      AST.DeclarationError sp -> recordError (LowerErrorParseSentinel sp)

    -- | The IR 'ReqId' assigned to a @req@ declaration's call-side
    -- 'VariableId'. The Identifier-pass 'RequestId' is found by scanning
    -- 'zonkedRequests' for a matching 'requestVariableId'; 'lsReqIds'
    -- then translates to the IR ReqId. Falls back to 'freshReqId' on
    -- a miss (which would indicate upstream inconsistency).
    requestIdForVariable :: VariableId -> Lower ReqId
    requestIdForVariable vid = do
      let identRid =
            firstWhere
              (\(_, rd) -> rd.requestVariableId == vid)
              (Map.toList zonkResult.zonkedRequests)
      case identRid of
        Just (rid, _) -> do
          mapped <- gets (Map.lookup rid . (.lsReqIds))
          case mapped of
            Just irRid -> pure irRid
            Nothing -> freshReqId
        Nothing -> freshReqId

    constructorIdForVariable :: VariableId -> Lower CtorId
    constructorIdForVariable vid = do
      let identCid =
            firstWhere
              (\(_, cd) -> cd.constructorVariableId == vid)
              (Map.toList zonkResult.zonkedConstructors)
      case identCid of
        Just (cid, _) -> do
          mapped <- gets (Map.lookup cid . (.lsCtorIds))
          case mapped of
            Just irCid -> pure irCid
            Nothing -> freshCtorId
        Nothing -> freshCtorId

    firstWhere :: (a -> Bool) -> [a] -> Maybe a
    firstWhere predicate = foldr (\x acc -> if predicate x then Just x else acc) Nothing

    recordEntry :: Text -> Text -> BlockId -> Lower ()
    recordEntry m n bid =
      let qn = QualifiedName {module_ = m, name = n}
       in modify (\s -> s {lsEntries = Map.insert qn bid s.lsEntries})

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
          mBlockId <- gets (Map.lookup variableId . (.lsVarBlockIds))
          case mBlockId of
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
            params = paramVars,
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
            params = paramVars,
            statements = statements,
            trailing = trailing,
            thenBlock = thenBlockId,
            handlers = handlers
          }
  recordBlock blockId (BlockUser {body = userBlock}) (Just name)

-- | Agent with @where (var s = init) ...@: outer/inner split. The
-- @prelude@ runs inside the *outer* block (where the runtime delivers the
-- params), and the destructured locals are visible to the inner block via
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
        SCall
          CallData
            { target = CTBlock {block = innerBlockId},
              args = innerArgs,
              output = Just innerOut
            }
  let outerBlock =
        defaultUserBlock
          { kind = BlockAgentEntry,
            params = paramVars,
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
-- agent body). The block expects state vars as labeled params; its body runs
-- the original block's statements and may issue 'SExit ExitBreak' which the
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
      stateLocals = [(vid, p.var) | (Just vid, p, _) <- stateBinds]
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
              recordError (LowerErrorUnresolvedVariable svb.sourceSpan nameText)
              v <- freshVarId Nothing
              pure (Nothing, Param {label = nameText, var = v}, svb)

-- | Lower a 'RequestHandler' to its own user block. Handler params are
-- @[req args ..., state vars (as labels) ...]@. The body's trailing value is
-- treated as an implicit @break@ (Koka-style); we append an explicit
-- 'SExit ExitBreak' if the body completes normally.
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
    Just identRid -> do
      mapped <- gets (Map.lookup identRid . (.lsReqIds))
      case mapped of
        Just rid -> pure rid
        Nothing -> do
          recordError (LowerErrorUnresolvedVariable hr.sourceSpan hr.name.text)
          freshReqId
    Nothing -> do
      recordError (LowerErrorUnresolvedVariable hr.sourceSpan hr.name.text)
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
          statements ++ [SExit ExitData {exitKind = ExitBreak, value = t}]
        Nothing -> statements
      userBlock =
        defaultUserBlock
          { kind = BlockHandlerBody,
            params = reqParamVars ++ stateParams,
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
    bid <- freshBlockId
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
              { params = [Param {label = "value", var = paramVar}],
                statements = statements,
                trailing = trailing
              }
      recordBlock bid (BlockUser {body = userBlock}) Nothing
    pure (Just bid)

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

-- | Allocate a fresh IR var (where the runtime delivers the incoming value)
-- and destructure it according to the given pattern. Returns the fresh
-- 'VarId' plus the @(VariableId, VarId)@ pairs to add to the local map.
--
-- Refutable patterns (literals) are rejected with 'LowerErrorUnsupported':
-- 'let' / function parameters demand irrefutable patterns.
bindPatternToFreshVar :: AST.Pattern Zonked -> Maybe Text -> Lower (VarId, [(VariableId, VarId)])
bindPatternToFreshVar pat hint = do
  let nameHint = case pat of
        AST.PatternVariable vp -> Just vp.name.text
        _ -> hint
  var <- freshVarId nameHint
  locals <- destructurePattern var pat
  pure (var, locals)

-- | Recursively destructure an incoming IR var according to the given
-- pattern, emitting projection calls ('tuple_get' / 'get_field') as needed.
-- Returns the @(VariableId, VarId)@ pairs introduced by every variable
-- sub-pattern.
--
-- Refutable patterns (literals) are rejected: callers use this for
-- irrefutable contexts ('let' / function parameter / known-tag match arm).
destructurePattern :: VarId -> AST.Pattern Zonked -> Lower [(VariableId, VarId)]
destructurePattern incoming = \case
  AST.PatternVariable vp -> case vp.name.resolution of
    Just variableId -> pure [(variableId, incoming)]
    Nothing -> do
      recordError (LowerErrorUnresolvedVariable vp.sourceSpan vp.name.text)
      pure []
  AST.PatternWildcard _ -> pure []
  AST.PatternTuple tp -> do
    pairs <- mapM (extractTupleElement incoming) (zip [0 ..] tp.elements)
    pure (concat pairs)
  AST.PatternQualifiedConstructor qp -> do
    pairs <- mapM (extractField incoming) qp.parameters
    pure (concat pairs)
  AST.PatternLiteral lp -> do
    recordError $
      LowerErrorUnsupported
        lp.sourceSpan
        "literal pattern is refutable; only allowed in match arms"
    pure []

-- | Extract @incoming._idx@ via the @tuple_get@ primitive and recurse.
extractTupleElement ::
  VarId ->
  (Int, AST.Pattern Zonked) ->
  Lower [(VariableId, VarId)]
extractTupleElement tupleVar (idx, sub) = do
  indexVar <- emitLoadLiteral (LVInteger (fromIntegral idx))
  out <- freshVarId (Just (Text.pack ("_" <> show idx)))
  blockId <- primBlockId "tuple_get"
  emit $
    SCall
      CallData
        { target = CTBlock {block = blockId},
          args = [Arg "tuple" tupleVar, Arg "index" indexVar],
          output = Just out
        }
  destructurePattern out sub

-- | Extract @incoming.label@ via the @get_field@ primitive and recurse.
extractField ::
  VarId ->
  (AST.NameRef Zonked 'AST.LabelRef, AST.Pattern Zonked) ->
  Lower [(VariableId, VarId)]
extractField objectVar (labelRef, sub) = do
  labelVar <- emitLoadLiteral (LVString labelRef.text)
  out <- freshVarId (Just labelRef.text)
  blockId <- primBlockId "get_field"
  emit $
    SCall
      CallData
        { target = CTBlock {block = blockId},
          args = [Arg "object" objectVar, Arg "field" labelVar],
          output = Just out
        }
  destructurePattern out sub

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
    go (stmt : rest) = do
      exited <- lowerStmt stmt
      if exited then pure Nothing else go rest

-- ===========================================================================
-- Statements
-- ===========================================================================

-- | Lower one 'AST.Statement'. Statements are emitted into the current
-- buffer. Returns 'True' if this statement causes a non-local exit
-- (return/break/etc.) so the caller can stop emitting further code.
--
-- @let@ in particular returns 'False' but its 'bindPattern' side-effect
-- — extending the local-variable Reader for downstream statements — is
-- handled by the caller via 'withLocalsCont'-style threading. We keep a
-- simpler design: 'bindPattern' returns the locals to add and the caller
-- (here, 'lowerBlockBody' / 'foldM step') is responsible for continuing
-- under those locals.
--
-- For now 'bindPattern' is a no-op for non-variable patterns; the locals
-- propagate via the @MonadReader@ extension below.
-- | Lower one non-let 'AST.Statement'. Statements are emitted into the
-- current buffer. Returns 'True' if this statement causes a non-local
-- exit (return/break/etc.) so the caller can stop emitting further code.
--
-- 'StatementLet' is handled specially by 'lowerBlockBody.go' (which
-- peels it off so the introduced bindings can extend the Reader scope
-- for subsequent statements) and therefore does not appear in this
-- dispatch.
lowerStmt :: AST.Statement Zonked -> Lower Bool
lowerStmt = \case
  AST.StatementLet ls -> do
    -- Defensive fall-through: 'lowerBlockBody.go' should have peeled
    -- this case off already. If we get here it means a 'let' was used
    -- in a context that does not thread Reader-scope bindings — bring
    -- it through as a no-effect emit and continue.
    var <- lowerExpr ls.value
    _ <- bindPatternLocals var ls.pattern
    pure False
  AST.StatementReturn stmt -> do
    var <- lowerExpr stmt.value
    emit (SExit ExitData {exitKind = ExitReturn, value = var})
    pure True
  AST.StatementBreak stmt -> do
    var <- lowerExpr stmt.value
    emit (SExit ExitData {exitKind = ExitBreak, value = var})
    pure True
  AST.StatementForBreak stmt -> do
    var <- lowerExpr stmt.value
    emit (SExit ExitData {exitKind = ExitForBreak, value = var})
    pure True
  AST.StatementNext stmt -> do
    var <- lowerExpr stmt.value
    modPairs <- mapM lowerModifier stmt.modifiers
    emit (SCont ContData {contKind = ContNext, value = Just var, mods = modPairs})
    pure True
  AST.StatementForNext stmt -> do
    modPairs <- mapM lowerModifier stmt.modifiers
    emit (SCont ContData {contKind = ContForNext, value = Nothing, mods = modPairs})
    pure True
  AST.StatementExpression expr -> do
    _ <- lowerExpr expr
    pure False
  AST.StatementAgent stmt -> do
    -- Local agent declared inside another agent's body. Allocate a fresh
    -- BlockId, register it in the @VariableId → BlockId@ map (so calls
    -- and 'SMakeClosure' on the agent name resolve to 'CTBlock' /
    -- 'BlockUser'), then lower its body using the shared agent layout.
    --
    -- The body is lowered with the OUTER 'localVars' frame still in
    -- scope: agent-side references to outer-scope variables are
    -- by-value (state vars are only mutated by @next@ inside @req@
    -- handlers, which a local agent cannot use), so the runtime can
    -- inherit the parent's variable scope when invoking the closure.
    -- No explicit IR captures are needed.
    case stmt.name.resolution of
      Just variableId -> do
        bid <- freshBlockId
        modify $ \s ->
          s {lsVarBlockIds = Map.insert variableId bid s.lsVarBlockIds}
        lowerAgentLike stmt.name.text stmt.parameters stmt.body bid
      Nothing ->
        recordError
          (LowerErrorUnresolvedVariable stmt.sourceSpan stmt.name.text)
    pure False
  AST.StatementError sp -> do
    recordError (LowerErrorParseSentinel sp)
    pure False

-- | Lower one 'AST.Modifier' producing @(label, value-bearing IR var)@. The
-- expression for the new value emits statements into the current buffer.
lowerModifier :: AST.Modifier Zonked -> Lower (Text, VarId)
lowerModifier m = do
  var <- lowerExpr m.value
  pure (m.name.text, var)

-- | Compute the @(VariableId, VarId)@ pairs introduced by binding a
-- pattern against an incoming IR var. Emits projection calls
-- ('tuple_get' / 'get_field') for tuple / constructor sub-patterns. The
-- caller is responsible for bringing the result into scope via
-- 'withLocals'.
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
  AST.ExpressionBinaryOperator be -> do
    lhs <- lowerExpr be.left
    rhs <- lowerExpr be.right
    out <- freshVarId Nothing
    blockId <- primBlockId (binaryOpPrim be.operator)
    emit $
      SCall
        CallData
          { target = CTBlock {block = blockId},
            args = [Arg "lhs" lhs, Arg "rhs" rhs],
            output = Just out
          }
    pure out
  AST.ExpressionUnaryOperator ue -> do
    operand <- lowerExpr ue.operand
    out <- freshVarId Nothing
    blockId <- primBlockId (unaryOpPrim ue.operator)
    emit $
      SCall
        CallData
          { target = CTBlock {block = blockId},
            args = [Arg "operand" operand],
            output = Just out
          }
    pure out
  AST.ExpressionCall ce -> lowerCall ce
  AST.ExpressionTuple te -> do
    elements <- mapM lowerExpr te.elements
    out <- freshVarId Nothing
    blockId <- primBlockId "make_tuple"
    emit $
      SCall
        CallData
          { target = CTBlock {block = blockId},
            args = zipWith mkIndexedArg [0 ..] elements,
            output = Just out
          }
    pure out
  AST.ExpressionArray ae -> do
    elements <- mapM lowerExpr ae.elements
    out <- freshVarId Nothing
    blockId <- primBlockId "make_array"
    emit $
      SCall
        CallData
          { target = CTBlock {block = blockId},
            args = zipWith mkIndexedArg [0 ..] elements,
            output = Just out
          }
    pure out
  AST.ExpressionFieldAccess fa -> do
    object <- lowerExpr fa.object
    -- Field name is loaded as a string literal; get_field consumes
    -- (object, field).
    fieldVar <- emitLoadLiteral (LVString fa.fieldName.text)
    out <- freshVarId Nothing
    blockId <- primBlockId "get_field"
    emit $
      SCall
        CallData
          { target = CTBlock {block = blockId},
            args = [Arg "object" object, Arg "field" fieldVar],
            output = Just out
          }
    pure out
  AST.ExpressionIndexAccess ia -> do
    array <- lowerExpr ia.array
    index <- lowerExpr ia.index
    out <- freshVarId Nothing
    blockId <- primBlockId "array_get"
    emit $
      SCall
        CallData
          { target = CTBlock {block = blockId},
            args = [Arg "array" array, Arg "index" index],
            output = Just out
          }
    pure out
  AST.ExpressionTemplate te -> lowerTemplate te
  AST.ExpressionBlock be -> lowerBlockExpr be
  AST.ExpressionIf ie -> lowerIfExpr ie
  AST.ExpressionMatch me -> lowerMatchExpr me
  AST.ExpressionFor fe -> lowerForExpr fe
  AST.ExpressionQualifiedReference qe ->
    -- A resolved qualified reference (module.target). target.resolution
    -- holds the resolved VariableId; treat it like a bare variable
    -- expression. Qualified references never bind locally.
    case qe.target.resolution of
      Just variableId -> do
        mBlockId <- gets (Map.lookup variableId . (.lsVarBlockIds))
        case mBlockId of
          Just bid -> do
            v <- freshVarId (Just qe.target.text)
            emit (SMakeClosure MakeClosureData {output = v, block = bid, captures = []})
            pure v
          Nothing -> do
            recordError (LowerErrorUnresolvedVariable qe.sourceSpan qe.target.text)
            freshVarId Nothing
      Nothing -> do
        recordError (LowerErrorUnresolvedVariable qe.sourceSpan qe.target.text)
        freshVarId Nothing

-- | Make an Arg with an indexed label like @"_0"@, @"_1"@, … for tuple /
-- array literal construction.
mkIndexedArg :: Int -> VarId -> Arg
mkIndexedArg i var = Arg {label = "_" <> Text.pack (show i), var = var}

-- | Lower a function call. Decides whether to emit a static 'CTBlock' call
-- (when the callee resolves to a top-level decl / ctor / prim) or a closure
-- 'CTValue' call (when the callee is a local variable holding a function).
lowerCall :: AST.CallExpression Zonked -> Lower VarId
lowerCall ce = do
  argVars <- mapM (lowerExpr . (.value)) ce.arguments
  let args = zipWith Arg (map (.label.text) ce.arguments) argVars
  target <- resolveCallee ce.callee
  out <- freshVarId Nothing
  emit (SCall CallData {target = target, args = args, output = Just out})
  pure out

-- | Resolve an expression that's used in the callee position.
resolveCallee :: AST.Expression Zonked -> Lower CallTarget
resolveCallee = \case
  AST.ExpressionVariable ve ->
    resolveCalleeName ve.name.resolution ve.sourceSpan ve.name.text True
  AST.ExpressionQualifiedReference qe ->
    -- Qualified references never bind locally — only consult the
    -- top-level block id table.
    resolveCalleeName qe.target.resolution qe.sourceSpan qe.target.text False
  -- For any other callee shape (a higher-order computation), lower it to
  -- a closure value first.
  other -> do
    var <- lowerExpr other
    pure (CTValue {var = var})

-- | Shared callee-name resolution: try the local Reader scope first (if
-- the callee may be a local), then fall back to the top-level
-- @VariableId → BlockId@ table. Failures yield a 'CTValue' on a fresh
-- placeholder var with an error recorded.
resolveCalleeName ::
  AST.NameMeta Zonked 'AST.VariableRef ->
  AST.SourceSpan ->
  Text ->
  Bool ->
  Lower CallTarget
resolveCalleeName resolution sp nameText canBeLocal = case resolution of
  Just variableId -> do
    mLocal <-
      if canBeLocal
        then lookupLocal variableId
        else pure Nothing
    case mLocal of
      Just irVar -> pure (CTValue {var = irVar})
      Nothing -> do
        mBlockId <- gets (Map.lookup variableId . (.lsVarBlockIds))
        case mBlockId of
          Just bid -> pure (CTBlock {block = bid})
          Nothing -> failTarget
  Nothing -> failTarget
  where
    failTarget = do
      recordError (LowerErrorUnresolvedVariable sp nameText)
      v <- freshVarId Nothing
      pure (CTValue {var = v})

-- | Lower an 'AST.TemplateExpression' as a left-fold of @concat@ prim
-- calls.
lowerTemplate :: AST.TemplateExpression Zonked -> Lower VarId
lowerTemplate te = do
  vars <- mapM lowerTemplateElement te.elements
  case vars of
    [] -> emitLoadLiteral (LVString "")
    [single] -> stringify single
    (first : rest) -> do
      initVar <- stringify first
      foldM concatStep initVar rest
  where
    stringify v = do
      blockId <- primBlockId "to_string"
      out <- freshVarId Nothing
      emit $
        SCall
          CallData
            { target = CTBlock {block = blockId},
              args = [Arg "value" v],
              output = Just out
            }
      pure out

    concatStep lhs rhsRaw = do
      rhs <- stringify rhsRaw
      blockId <- primBlockId "concat"
      out <- freshVarId Nothing
      emit $
        SCall
          CallData
            { target = CTBlock {block = blockId},
              args = [Arg "lhs" lhs, Arg "rhs" rhs],
              output = Just out
            }
      pure out

lowerTemplateElement :: AST.TemplateElement Zonked -> Lower VarId
lowerTemplateElement = \case
  AST.TemplateElementString tse -> emitLoadLiteral (LVString tse.value)
  AST.TemplateElementExpression tee -> lowerExpr tee.value

-- ===========================================================================
-- Inline block / control-flow expressions
-- ===========================================================================

-- | Lower an inline block expression @{ stmts; tail }@. We create a child
-- 'UserBlock' (kind = 'BlockInline', so it shares the parent's scope) and
-- emit a static call to it.
lowerBlockExpr :: AST.BlockExpression Zonked -> Lower VarId
lowerBlockExpr be = do
  childBlockId <- buildInlineBlock be.block
  out <- freshVarId Nothing
  emit $
    SCall
      CallData
        { target = CTBlock {block = childBlockId},
          args = [],
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

-- | Lower an if expression as 'SMatch' on a boolean subject. The "true"
-- branch is matched by tag @"true"@; the else branch (or implicit null
-- block) is the default.
lowerIfExpr :: AST.IfExpression Zonked -> Lower VarId
lowerIfExpr ie = do
  cond <- lowerExpr ie.condition
  thenBlockId <- buildInlineBlock ie.thenBlock
  defaultBlockId <- traverse buildInlineBlock ie.elseBlock
  out <- freshVarId Nothing
  emit $
    SMatch
      MatchData
        { subject = cond,
          arms =
            [ MatchArm
                { tag = MatchTagLiteral LVBoolean {boolean = True},
                  bindings = [],
                  body = thenBlockId
                }
            ],
          defaultArm = defaultBlockId,
          output = Just out
        }
  pure out

-- | Lower a match expression. Each source arm becomes one outer
-- 'MatchArm' (so multiple arms with the same top-level constructor stay
-- separate, even though the runtime might want to merge them into a
-- single dispatch — see Phase 15-G note below).
--
-- Nested refutable sub-patterns inside an arm (e.g. @Some(0)@,
-- @Pair(left=true, right=y)@) are handled by chaining inner 'SMatch'
-- statements inside the arm body. Each inner 'SMatch' uses the
-- outermost wildcard/catch-all arm's body as its 'defaultArm', so a
-- failed inner refutable check falls through to the catch-all rather
-- than to the next sibling source arm. This matches the user-confirmed
-- design described in CLAUDE.md: \"3 段階 nest で 2 段階目に shared
-- default がある\" works because each inner cascade carries the same
-- shared default to the bottom.
--
-- Limitation: source arms that overlap on their top-level tag (e.g.
-- @Some(0) -> a; Some(n) -> b@) are not merged. Each source arm
-- compiles to a separate IR arm; if @Some(0)@'s inner check fails,
-- control jumps to the shared default (the outermost @_@), bypassing
-- the next @Some(n)@ arm. Tests should avoid this overlap pattern, or
-- a future revision can add same-tag grouping.
--
-- Top-level patterns supported:
--   * VariablePattern - tag=MatchTagAny, binds subject to the named local.
--   * WildcardPattern - tag=MatchTagAny.
--   * LiteralPattern  - tag=MatchTagLiteral, no bindings.
--   * TuplePattern    - tag=MatchTagAny, bindings via "_0", "_1", ...
--   * QualifiedConstructorPattern - tag=MatchTagConstructor, bindings via
--     field labels. Inner refutable sub-patterns chain via inner SMatch.
lowerMatchExpr :: AST.MatchExpression Zonked -> Lower VarId
lowerMatchExpr me = do
  subject <- lowerExpr me.subject
  out <- freshVarId Nothing
  -- Pre-allocate the shared default block id. Inner refutable cascades
  -- emitted while lowering arms reference this id; we fill it after
  -- regular arm lowering.
  sharedDefault <- freshBlockId
  -- Split the source arms into regular (refutable / specific) and
  -- unconditional (variable / wildcard). The LAST unconditional arm's
  -- body becomes the shared default so the wildcard branch is emitted
  -- exactly once. Subsequent arms after that wildcard are unreachable
  -- — we still lower them (their errors deserve to surface) but mark
  -- them as such by skipping the IR arm emission.
  let (regular, defaultBody) = splitOnLastUnconditional me.cases
  arms <- mapM (lowerMatchArm sharedDefault subject) regular
  case defaultBody of
    Just blk ->
      -- Lower the wildcard arm's body INTO the pre-allocated
      -- sharedDefault block id. We bypass 'buildArmBody' here because
      -- it would allocate a fresh id; instead inline the same logic
      -- with the existing id.
      lowerArmBodyInto sharedDefault blk
    Nothing ->
      -- No wildcard: shared default is a panic placeholder.
      recordBlock sharedDefault (BlockUser {body = defaultUserBlock}) Nothing
  emit $
    SMatch
      MatchData
        { subject = subject,
          arms = arms,
          defaultArm = Just sharedDefault,
          output = Just out
        }
  pure out

-- | Partition arms: take everything strictly *before* the last
-- unconditional arm (variable / wildcard) as \"regular\", and return
-- that arm's body separately. Anything after the last unconditional
-- arm in source order is unreachable; we drop it from the regular
-- arms list. (This matches the @match@ runtime semantics: the
-- defaultArm catches anything not handled by a regular arm.)
splitOnLastUnconditional ::
  [AST.CaseArm Zonked] ->
  ([AST.CaseArm Zonked], Maybe (AST.Block Zonked))
splitOnLastUnconditional cases =
  case findLastUnconditionalIndex cases of
    Just idx -> (take idx cases, Just (cases !! idx).body)
    Nothing -> (cases, Nothing)
  where
    findLastUnconditionalIndex =
      fst
        . foldr
          ( \(idx, arm) (acc, found) ->
              if not found && isUnconditional arm
                then (Just idx, True)
                else (acc, found)
          )
          (Nothing, False)
        . zip [0 :: Int ..]
    isUnconditional arm = case arm.pattern of
      AST.PatternVariable _ -> True
      AST.PatternWildcard _ -> True
      _ -> False

-- | Lower an arm body block into the given pre-allocated 'BlockId'.
-- Used for the shared default so the wildcard arm's body lives at
-- exactly one BlockId.
lowerArmBodyInto :: BlockId -> AST.Block Zonked -> Lower ()
lowerArmBodyInto bid blk = do
  (trailing, statements) <- runWithFreshBuffer (lowerBlockInto blk)
  let userBlock =
        defaultUserBlock
          { statements = statements,
            trailing = trailing
          }
  recordBlock bid (BlockUser {body = userBlock}) Nothing

lowerMatchArm :: BlockId -> VarId -> AST.CaseArm Zonked -> Lower MatchArm
lowerMatchArm sharedDefault subject arm = do
  (tag, bindings, refutables, prelude) <- patternToArm subject arm.pattern
  body <- buildArmBodyWithRefutables sharedDefault refutables prelude arm.body
  pure MatchArm {tag = tag, bindings = bindings, body = body}

-- | One layer of refutable nested matching that needs an inner 'SMatch'
-- in the arm body. Each step matches @stepSubject@ against the
-- pattern's tag with the indicated @stepBindings@; on success the next
-- inner step (or the user's arm body) runs, on failure control falls
-- through to the surrounding @sharedDefault@.
data RefutableStep = RefutableStep
  { stepSubject :: !VarId,
    stepTag :: !MatchTag,
    stepBindings :: ![(Text, VarId)],
    -- | Irrefutable destructuring (tuple_get / get_field) that should
    -- run inside this step's matched arm body, before the next inner
    -- step or the user body. Returns the new locals introduced.
    stepPrelude :: !(Lower [(VariableId, VarId)])
  }

-- | Translate a top-level arm pattern into @(tag, bindings, refutables,
-- prelude)@:
--
--   * @tag@ — the runtime tag the OUTER 'SMatch' arm matches against.
--   * @bindings@ — the @(label, IRVar)@ pairs the outer arm pre-populates.
--   * @refutables@ — list of 'RefutableStep's to chain in the arm body
--     for any nested refutable sub-patterns (literal / constructor
--     pattern below the top level). Empty when the pattern has only
--     irrefutable nested parts. Steps are in *outermost-first* source
--     order; 'buildArmBodyWithRefutables' folds them innermost-out.
--   * @prelude@ — a 'Lower' action, run inside the OUTER arm body's
--     buffer (before any inner SMatch), that emits irrefutable
--     destructuring for the top-level pattern and returns its locals.
patternToArm ::
  VarId ->
  AST.Pattern Zonked ->
  Lower (MatchTag, [(Text, VarId)], [RefutableStep], Lower [(VariableId, VarId)])
patternToArm subject = \case
  AST.PatternVariable vp -> case vp.name.resolution of
    Just variableId ->
      pure (MatchTagAny, [], [], pure [(variableId, subject)])
    Nothing -> do
      recordError (LowerErrorUnresolvedVariable vp.sourceSpan vp.name.text)
      pure (MatchTagAny, [], [], pure [])
  AST.PatternWildcard _ -> pure (MatchTagAny, [], [], pure [])
  AST.PatternLiteral lp -> do
    let lit = literalValueToIR lp.value
    pure (MatchTagLiteral lit, [], [], pure [])
  AST.PatternTuple tp -> do
    fields <- mapM allocTupleField (zip [0 :: Int ..] tp.elements)
    let bindings = [(label, var) | (label, var, _) <- fields]
    refutables <- concat <$> mapM (\(_, var, sub) -> nestedRefutables var sub) fields
    let prelude =
          concat
            <$> mapM (\(_, var, sub) -> destructurePattern var sub) fields
    pure (MatchTagAny, bindings, refutables, prelude)
  AST.PatternQualifiedConstructor qp -> do
    cid <- resolveCtorId qp
    fields <- mapM allocConstructorField qp.parameters
    let bindings = [(label, var) | (label, var, _) <- fields]
    refutables <- concat <$> mapM (\(_, var, sub) -> nestedRefutables var sub) fields
    let prelude =
          concat
            <$> mapM (\(_, var, sub) -> destructurePattern var sub) fields
    pure (MatchTagConstructor cid, bindings, refutables, prelude)
  where
    allocTupleField (idx, sub) = do
      let label = Text.pack ("_" <> show idx)
      var <- freshVarId (Just label)
      pure (label, var, sub)

    allocConstructorField (labelRef, sub) = do
      var <- freshVarId (Just labelRef.text)
      pure (labelRef.text, var, sub)

    resolveCtorId qp = case qp.constructorName.resolution of
      Just identCid -> do
        mapped <- gets (Map.lookup identCid . (.lsCtorIds))
        case mapped of
          Just irCid -> pure irCid
          Nothing -> do
            recordError (LowerErrorUnresolvedVariable qp.sourceSpan qp.constructorName.text)
            freshCtorId
      Nothing -> do
        recordError (LowerErrorUnresolvedVariable qp.sourceSpan qp.constructorName.text)
        freshCtorId

literalValueToIR :: AST.LiteralValue -> LiteralValue
literalValueToIR = \case
  AST.LiteralValueBoolean b -> LVBoolean {boolean = b}
  AST.LiteralValueNull -> LVNull
  AST.LiteralValueInteger n -> LVInteger {integer = n}
  AST.LiteralValueNumber n -> LVNumber {number = n}
  AST.LiteralValueString s -> LVString {string = s}

-- | Collect 'RefutableStep's for any nested LITERAL sub-patterns below
-- @subject@'s pattern. Nested constructor / tuple sub-patterns are NOT
-- treated as refutable — Katari's semantics for @match@ allow nested
-- constructor patterns to act as irrefutable destructuring (matching
-- the original 'destructurePattern' behaviour). Only nested literal
-- patterns require an inner SMatch.
nestedRefutables :: VarId -> AST.Pattern Zonked -> Lower [RefutableStep]
nestedRefutables subject = \case
  AST.PatternVariable _ -> pure []
  AST.PatternWildcard _ -> pure []
  AST.PatternLiteral lp ->
    pure
      [ RefutableStep
          { stepSubject = subject,
            stepTag = MatchTagLiteral (literalValueToIR lp.value),
            stepBindings = [],
            stepPrelude = pure []
          }
      ]
  AST.PatternTuple tp -> do
    let allocField idx _ = freshVarId (Just (Text.pack ("_" <> show idx)))
    fieldVars <- zipWithM allocField [0 :: Int ..] tp.elements
    concat <$> zipWithM nestedRefutables fieldVars tp.elements
  AST.PatternQualifiedConstructor qp -> do
    -- Allocate field vars for each parameter and recurse to find any
    -- nested LITERAL refutables. The constructor itself isn't a
    -- refutable step; its destructuring is part of the irrefutable
    -- prelude built by 'destructurePattern'.
    fieldVarsAndSubs <- forM qp.parameters $ \(labelRef, sub) -> do
      var <- freshVarId (Just labelRef.text)
      pure (labelRef.text, var, sub)
    concat <$> mapM (\(_, var, sub) -> nestedRefutables var sub) fieldVarsAndSubs

-- | Build a child block for a match arm body. The @prelude@ action runs
-- first inside the arm body's fresh statement buffer, emitting any
-- nested-pattern destructuring; its returned locals are then in scope
-- when the user-written body is lowered.
buildArmBody :: Lower [(VariableId, VarId)] -> AST.Block Zonked -> Lower BlockId
buildArmBody prelude blk = do
  blockId <- freshBlockId
  (trailing, statements) <- runWithFreshBuffer $ do
    locals <- prelude
    withLocals locals (lowerBlockInto blk)
  let userBlock =
        defaultUserBlock
          { statements = statements,
            trailing = trailing
          }
  recordBlock blockId (BlockUser {body = userBlock}) Nothing
  pure blockId

-- | Build a match arm body that may contain inner refutable cascades.
-- 'refutables' is the list of nested 'RefutableStep's produced by
-- 'patternToArm'; we fold them innermost-out so each step's 'SMatch'
-- wraps the previous \"leaf\" block, and the deepest leaf runs the
-- prelude + user body.
buildArmBodyWithRefutables ::
  BlockId {- shared default -} ->
  [RefutableStep] ->
  Lower [(VariableId, VarId)] {- top-level prelude -} ->
  AST.Block Zonked {- user-written arm body -} ->
  Lower BlockId
buildArmBodyWithRefutables sharedDefault refutables topPrelude blk = do
  -- Innermost block: the user's body wrapped together with the
  -- innermost refutable's prelude. We apply the *top-level* prelude
  -- here only when there are no inner refutables; otherwise the
  -- top-level prelude already ran in the OUTER SMatch arm body (see
  -- 'wrapWithStep' below).
  case refutables of
    [] ->
      -- No nested refutable: classic prelude + body block.
      buildArmBody topPrelude blk
    (firstStep : restSteps) -> do
      leaf <- buildArmBody (combineLastPrelude restSteps) blk
      -- Wrap from innermost-out: each step's SMatch lives in a block
      -- that becomes the previous step's arm body. The outermost step
      -- is wrapped in a block that ALSO runs the top-level prelude.
      wrappedInner <- foldNestedSteps sharedDefault leaf (reverse restSteps)
      wrapOutermost sharedDefault topPrelude firstStep wrappedInner
  where
    -- The innermost step's prelude is what runs alongside the user's body.
    combineLastPrelude steps = case lastMay steps of
      Just step -> step.stepPrelude
      Nothing -> pure []

    lastMay [] = Nothing
    lastMay xs = Just (last xs)

-- | Fold a list of refutable steps innermost-out. Each step wraps the
-- previous \"leaf\" block in an SMatch (with @sharedDefault@ as the
-- fall-through). 'innerSteps' is reversed so we process bottom-up.
foldNestedSteps :: BlockId -> BlockId -> [RefutableStep] -> Lower BlockId
foldNestedSteps _ leaf [] = pure leaf
foldNestedSteps sharedDefault leaf (step : moreInnerToOuter) = do
  -- This step's arm body is the previous leaf. Build an SMatch block
  -- whose only matching arm jumps to that leaf.
  matchBlock <- buildSMatchWrapper sharedDefault step leaf
  foldNestedSteps sharedDefault matchBlock moreInnerToOuter

-- | The OUTERMOST step also needs to run the top-level prelude
-- (irrefutable destructuring of the outer SMatch arm's bindings) before
-- emitting the inner SMatch.
wrapOutermost ::
  BlockId ->
  Lower [(VariableId, VarId)] ->
  RefutableStep ->
  BlockId {- inner-wrapped block to jump into on match -} ->
  Lower BlockId
wrapOutermost sharedDefault topPrelude step innerBlock = do
  blockId <- freshBlockId
  (_, statements) <- runWithFreshBuffer $ do
    topLocals <- topPrelude
    withLocals topLocals $ do
      stepLocals <- step.stepPrelude
      withLocals stepLocals $ do
        emit $
          SMatch
            MatchData
              { subject = step.stepSubject,
                arms =
                  [ MatchArm
                      { tag = step.stepTag,
                        bindings = step.stepBindings,
                        body = innerBlock
                      }
                  ],
                defaultArm = Just sharedDefault,
                output = Nothing
              }
  let userBlock =
        defaultUserBlock
          { statements = statements,
            trailing = Nothing
          }
  recordBlock blockId (BlockUser {body = userBlock}) Nothing
  pure blockId

-- | Build the wrapper block for a non-outermost step: just emits the
-- inner SMatch (no top-level prelude — that already ran higher up).
buildSMatchWrapper :: BlockId -> RefutableStep -> BlockId -> Lower BlockId
buildSMatchWrapper sharedDefault step innerBlock = do
  blockId <- freshBlockId
  (_, statements) <- runWithFreshBuffer $ do
    stepLocals <- step.stepPrelude
    withLocals stepLocals $
      emit $
        SMatch
          MatchData
            { subject = step.stepSubject,
              arms =
                [ MatchArm
                    { tag = step.stepTag,
                      bindings = step.stepBindings,
                      body = innerBlock
                    }
                ],
              defaultArm = Just sharedDefault,
              output = Nothing
            }
  let userBlock =
        defaultUserBlock
          { statements = statements,
            trailing = Nothing
          }
  recordBlock blockId (BlockUser {body = userBlock}) Nothing
  pure blockId

-- | Lower a for expression. Supports zero or more 'in' bindings, zero or
-- more 'var' (state) bindings, and an optional then-block.
lowerForExpr :: AST.ForExpression Zonked -> Lower VarId
lowerForExpr fe = do
  (iterPairs, iterLocals) <- lowerForIters fe.inBindings
  (stateInits, stateLocals) <- lowerForStates fe.varBindings
  bodyBlockId <- buildForBody (iterLocals ++ stateLocals) fe.body
  thenBlockId <- traverse buildInlineBlock fe.thenBlock
  out <- freshVarId Nothing
  emit $
    SFor
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
          recordError (LowerErrorUnresolvedVariable binding.sourceSpan labelText)
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

-- | Convert an 'AST.LiteralValue' to its 'IR.LiteralValue' counterpart.
astLiteralToIR :: AST.LiteralValue -> LiteralValue
astLiteralToIR = \case
  AST.LiteralValueInteger n -> LVInteger n
  AST.LiteralValueNumber n -> LVNumber n
  AST.LiteralValueString s -> LVString s
  AST.LiteralValueBoolean b -> LVBoolean b
  AST.LiteralValueNull -> LVNull

-- | Emit a fresh load-literal statement and return the resulting var.
emitLoadLiteral :: LiteralValue -> Lower VarId
emitLoadLiteral lv = do
  out <- freshVarId Nothing
  emit (SLoadLiteral LoadLiteralData {output = out, value = lv})
  pure out

-- | Lower an 'AST.LiteralExpression' as an 'SLoadLiteral'.
lowerLiteral :: AST.LiteralExpression Zonked -> Lower VarId
lowerLiteral lit = emitLoadLiteral (astLiteralToIR lit.value)

-- | Lower an 'AST.VariableExpression'. Result depends on whether the
-- referenced 'VariableId' is a local binding (just return its IR var) or
-- a top-level decl (allocate a closure value via 'SMakeClosure').
lowerVariable :: AST.VariableExpression Zonked -> Lower VarId
lowerVariable ve = case ve.name.resolution of
  Nothing -> do
    recordError (LowerErrorUnresolvedVariable ve.sourceSpan ve.name.text)
    freshVarId Nothing
  Just variableId -> do
    mLocal <- lookupLocal variableId
    case mLocal of
      Just irVar -> pure irVar
      Nothing -> do
        mBlockId <- gets (Map.lookup variableId . (.lsVarBlockIds))
        case mBlockId of
          Just bid -> do
            v <- freshVarId (Just ve.name.text)
            emit (SMakeClosure MakeClosureData {output = v, block = bid, captures = []})
            pure v
          Nothing -> do
            recordError (LowerErrorUnresolvedVariable ve.sourceSpan ve.name.text)
            freshVarId Nothing
