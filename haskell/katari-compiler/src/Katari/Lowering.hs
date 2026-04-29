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

import Control.Monad (foldM)
import Control.Monad.State.Strict (State, gets, modify, runState)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32)
import Katari.AST qualified as AST
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.IR
import Katari.Typechecker.Identifier (VariableId)
import Katari.Typechecker.Zonker (ZonkResult (..), Zonked (..))

-- ===========================================================================
-- Errors
-- ===========================================================================

data LoweringError
  = -- | Encountered a 'IdentifiedUnresolvedVariable' / 'ZonkedUnresolvedVariable'
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
-- ===========================================================================

data LowerState = LowerState
  { lsNextBlockId :: !Word32,
    lsNextVarId :: !Word32,
    lsBlocks :: !(Map BlockId Block),
    lsVarNames :: !(Map VarId Text),
    lsBlockNames :: !(Map BlockId Text),
    -- | Top-level @VariableId@ → its callable @BlockId@. Used at call /
    -- closure sites to resolve agent / req / ext-agent / data-ctor names.
    -- Local bindings (let / param / pattern) are *not* in this map; they
    -- live in 'lsLocalVars' instead, and the call sites consult locals first.
    lsVarBlockIds :: !(Map VariableId BlockId),
    lsLocalVars :: !(Map VariableId VarId),
    lsPrimBlockIds :: !(Map Text BlockId),
    lsErrors :: ![LoweringError]
  }

initialLowerState :: LowerState
initialLowerState =
  LowerState
    { lsNextBlockId = 0,
      lsNextVarId = 0,
      lsBlocks = Map.empty,
      lsVarNames = Map.empty,
      lsBlockNames = Map.empty,
      lsVarBlockIds = Map.empty,
      lsLocalVars = Map.empty,
      lsPrimBlockIds = Map.empty,
      lsErrors = []
    }

type Lower = State LowerState

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

-- | Bind a local variable id mapping; return a "restore" action so the binding
-- can be undone after a scope exits.
bindLocal :: VariableId -> VarId -> Lower (Lower ())
bindLocal variableId irVar = do
  prev <- gets (Map.lookup variableId . (.lsLocalVars))
  modify (\s -> s {lsLocalVars = Map.insert variableId irVar s.lsLocalVars})
  pure $ modify $ \s ->
    s
      { lsLocalVars = case prev of
          Just v -> Map.insert variableId v s.lsLocalVars
          Nothing -> Map.delete variableId s.lsLocalVars
      }

withLocals :: [(VariableId, VarId)] -> Lower a -> Lower a
withLocals binds action = do
  restorers <- mapM (uncurry bindLocal) binds
  result <- action
  sequence_ (reverse restorers)
  pure result

primBlockId :: Text -> Lower BlockId
primBlockId name = do
  ids <- gets (.lsPrimBlockIds)
  case Map.lookup name ids of
    Just blockId -> pure blockId
    Nothing -> error ("primBlockId: unknown primitive " <> Text.unpack name)

-- ===========================================================================
-- Statement-builder context
-- ===========================================================================

-- | Statements emitted while lowering a block body. We collect into a snoc
-- list-like structure to keep ordering simple (statements are appended).
type StmtBuf = [Statement]

-- | Append a statement to the buffer.
emit :: Statement -> StmtBuf -> StmtBuf
emit s buf = buf ++ [s]

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
  let (irModule, finalState) = runState (lowerProgramM moduleName zonkResult) initialLowerState
   in (irModule, reverse finalState.lsErrors)

lowerProgramM :: Text -> ZonkResult -> Lower IRModule
lowerProgramM moduleName zonkResult = do
  registerPrimitives
  registerDeclarationKinds zonkResult
  entries <- lowerAllDeclarations zonkResult
  state <- gets id
  pure
    IRModule
      { name = moduleName,
        blocks = state.lsBlocks,
        entries = entries,
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

-- | Run @action@ with the resolved 'VariableId' from a top-level callable
-- declaration name. If the name didn't resolve (parser/identifier left an
-- 'ZonkedUnresolvedVariable' marker), record a Lowering error and skip.
registerCallable ::
  AST.NameRef Zonked 'AST.VariableRef ->
  AST.SourceSpan ->
  (VariableId -> Lower ()) ->
  Lower ()
registerCallable nameRef sp action = case nameRef.metadata of
  ZonkedVariable variableId -> action variableId
  ZonkedUnresolvedVariable -> recordError (LowerErrorUnresolvedVariable sp nameRef.text)

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
      AST.DeclarationRequest decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          blockId <- freshBlockId
          recordBlock blockId (BlockRequest {name = decl.name.text}) (Just decl.name.text)
          recordVarBlockId variableId blockId
      AST.DeclarationExternalAgent decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          blockId <- freshBlockId
          recordBlock
            blockId
            BlockExternal {moduleName = moduleName, name = decl.name.text}
            (Just decl.name.text)
          recordVarBlockId variableId blockId
      AST.DeclarationData decl ->
        registerCallable decl.name decl.sourceSpan $ \variableId -> do
          blockId <- freshBlockId
          recordBlock blockId (BlockCtor {name = decl.name.text}) (Just decl.name.text)
          recordVarBlockId variableId blockId
      AST.DeclarationImport _ -> pure ()
      AST.DeclarationTypeSynonym _ -> pure ()
      AST.DeclarationError sp -> recordError (LowerErrorParseSentinel sp)

lowerAllDeclarations :: ZonkResult -> Lower (Map Text BlockId)
lowerAllDeclarations zonkResult = do
  pairs <- concat <$> mapM lowerModule (Map.elems zonkResult.zonkedModules)
  pure (Map.fromList pairs)
  where
    lowerModule m = catMaybes <$> mapM lowerDeclaration m.declarations

    lowerDeclaration :: AST.Declaration Zonked -> Lower (Maybe (Text, BlockId))
    lowerDeclaration = \case
      AST.DeclarationAgent decl -> case decl.name.metadata of
        ZonkedVariable variableId -> do
          mBlockId <- gets (Map.lookup variableId . (.lsVarBlockIds))
          case mBlockId of
            Just blockId -> do
              lowerAgentDeclaration decl blockId
              pure (Just (decl.name.text, blockId))
            Nothing -> pure Nothing
        ZonkedUnresolvedVariable -> pure Nothing
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
lowerAgentDeclaration decl blockId = do
  paramBindings <- mapM bindParam decl.parameters
  let paramVars = map fst paramBindings
      localBinds = concatMap snd paramBindings
  withLocals localBinds $ do
    let body = decl.body
    case body.whereBlock of
      Nothing ->
        -- Plain agent body: just lower as a return-bearing block.
        lowerSimpleAgent blockId decl.name.text paramVars body
      Just wb
        | null wb.stateVariables ->
            lowerAgentWithHandlers blockId decl.name.text paramVars body wb
        | otherwise ->
            lowerAgentWithStateVars blockId decl.name.text paramVars body wb

-- | Plain agent (no @where@): single block, @catchesReturn=True@.
lowerSimpleAgent ::
  BlockId ->
  Text ->
  [Param] ->
  AST.Block Zonked ->
  Lower ()
lowerSimpleAgent blockId name paramVars blk = do
  (statements, trailing) <- lowerBlockBody blk
  let userBlock =
        defaultUserBlock
          { kind = BlockAgentEntry,
            params = paramVars,
            statements = statements,
            trailing = trailing
          }
  recordBlock blockId (BlockUser {body = userBlock}) (Just name)

-- | Agent with @where { handlers... }@ (no state vars): single block that
-- catches both Return and Break.
lowerAgentWithHandlers ::
  BlockId ->
  Text ->
  [Param] ->
  AST.Block Zonked ->
  AST.WhereBlock Zonked ->
  Lower ()
lowerAgentWithHandlers blockId name paramVars blk wb = do
  -- Lower the body's statements + trailing in this same block's scope.
  (statements, trailing) <- lowerBlockBody (stripWhereBlock blk)
  -- Lower handlers (each becomes its own UserBlock).
  handlers <- mapM (lowerHandler []) wb.handlers
  -- Lower then clause if present.
  thenBlockId <- lowerThenClause wb.thenClause
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

-- | Agent with @where (var s = init) ...@: outer/inner split.
lowerAgentWithStateVars ::
  BlockId ->
  Text ->
  [Param] ->
  AST.Block Zonked ->
  AST.WhereBlock Zonked ->
  Lower ()
lowerAgentWithStateVars outerId name paramVars blk wb = do
  -- 1. Outer: compute state init expressions; call inner with state values.
  --    statements = [init computation...; SCall inner_block_id stateInits]
  --    trailing = inner block's output var
  let initialBuf = [] :: StmtBuf
  (stateInitVars, bufAfterInits) <- lowerStateInits initialBuf wb.stateVariables
  -- 2. Inner block: state vars as stateVars, body lowered with state-var
  --    locals visible.
  innerBlockId <- buildInnerBlockWithState name wb blk
  -- 3. Outer calls inner with state init args by label.
  innerOut <- freshVarId Nothing
  let innerArgs =
        [ Arg {label = lbl, var = v}
          | (lbl, v) <- stateInitVars
        ]
      callInner =
        SCall
          CallData
            { target = CTBlock {block = innerBlockId},
              args = innerArgs,
              output = Just innerOut
            }
      outerStatements = bufAfterInits ++ [callInner]
      outerBlock =
        defaultUserBlock
          { kind = BlockAgentEntry,
            params = paramVars,
            statements = outerStatements,
            trailing = Just innerOut
          }
  recordBlock outerId (BlockUser {body = outerBlock}) (Just name)

-- | Lower the @stateVariables@ of a 'WhereBlock' in the parent's scope; the
-- init expressions emit calls into the buffer. Returns the @(label, varId)@
-- pairs and the updated buffer.
lowerStateInits ::
  StmtBuf ->
  [AST.StateVariableBinding Zonked] ->
  Lower ([(Text, VarId)], StmtBuf)
lowerStateInits = go []
  where
    go acc currentBuf [] = pure (reverse acc, currentBuf)
    go acc currentBuf (svb : rest) = do
      (initVar, currentBuf') <- lowerExpr currentBuf svb.initial
      go ((svb.name.text, initVar) : acc) currentBuf' rest

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
       in case svb.name.metadata of
            ZonkedVariable variableId -> do
              v <- freshVarId (Just nameText)
              pure (Just variableId, Param {label = nameText, var = v}, svb)
            ZonkedUnresolvedVariable -> do
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
  reqBlockId <- case hr.name.metadata of
    ZonkedVariable variableId -> do
      mBlockId <- gets (Map.lookup variableId . (.lsVarBlockIds))
      case mBlockId of
        Just bid -> pure bid
        Nothing -> do
          recordError (LowerErrorUnsupported hr.sourceSpan "handler target is not a request")
          freshBlockId
    ZonkedUnresolvedVariable -> do
      recordError (LowerErrorUnresolvedVariable hr.sourceSpan hr.name.text)
      freshBlockId
  -- Build the handler block.
  bodyBlockId <- freshBlockId
  paramBindings <- mapM bindParam hr.parameters
  let reqParamVars = map fst paramBindings
      paramLocals = concatMap snd paramBindings
  withLocals paramLocals $ do
    (statements, trailing) <- lowerBlockBody hr.body
    -- Implicit break on normal completion.
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
  pure Handler {request = reqBlockId, handlerBody = bodyBlockId}

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

-- | Bind a function parameter: produce a 'Param' (label + IR var) and the
-- @[(VariableId, VarId)]@ pairs that should be added to the local map for the
-- body. For variable patterns this is a single binding; other pattern shapes
-- will be supported in later stages.
bindParam :: AST.ParameterBinding Zonked -> Lower (Param, [(VariableId, VarId)])
bindParam pb = do
  (var, locals) <- bindPatternToFreshVar pb.pattern (Just pb.label)
  pure (Param {label = pb.label, var = var}, locals)

-- | Allocate a fresh IR var and bind it to a pattern. Returns the fresh
-- 'VarId' (= where the runtime delivers the incoming value) plus the list of
-- @(VariableId, VarId)@ pairs that should be added to the local map.
--
-- Stage 1 only supports 'PatternVariable' / 'PatternWildcard' (no destructuring
-- in params). Stage 2+ extends.
bindPatternToFreshVar :: AST.Pattern Zonked -> Maybe Text -> Lower (VarId, [(VariableId, VarId)])
bindPatternToFreshVar pat hint = case pat of
  AST.PatternVariable vp -> do
    let nameHint = Just vp.name.text
    var <- freshVarId nameHint
    case vp.name.metadata of
      ZonkedVariable variableId -> pure (var, [(variableId, var)])
      ZonkedUnresolvedVariable -> do
        recordError (LowerErrorUnresolvedVariable vp.sourceSpan vp.name.text)
        pure (var, [])
  AST.PatternWildcard _ -> do
    var <- freshVarId hint
    pure (var, [])
  other -> do
    -- Stage 2+ will properly destructure tuples / constructors / literals
    -- inside parameters; for now record an error and allocate a placeholder.
    var <- freshVarId hint
    recordError $
      LowerErrorUnsupported
        (AST.sourceSpanOf other)
        "parameter pattern shape not yet supported"
    pure (var, [])

-- ===========================================================================
-- Block body
-- ===========================================================================

-- | Lower a 'AST.Block' (statements + returnExpression). Returns the emitted
-- statements and the optional trailing var.
--
-- whereBlock handling (state vars / handlers / then) is added in Stage 6.
lowerBlockBody :: AST.Block Zonked -> Lower ([Statement], Maybe VarId)
lowerBlockBody blk = do
  -- Stage 1 ignores whereBlock; future stages will lower it.
  let initial = [] :: StmtBuf
  (afterStmts, _) <- foldM step (initial, False) blk.statements
  case blk.returnExpression of
    Nothing -> pure (afterStmts, Nothing)
    Just expr -> do
      (var, finalBuf) <- lowerExpr afterStmts expr
      pure (finalBuf, Just var)
  where
    step (buf, exited) stmt
      | exited = pure (buf, exited)
      | otherwise = lowerStmt buf stmt

-- ===========================================================================
-- Statements
-- ===========================================================================

-- | Lower one 'AST.Statement', appending IR statements to the buffer. The
-- second element of the result is 'True' if this statement causes a non-local
-- exit (return/break/etc.) — Stage 7 will use this for unreachable-code
-- detection; for now ignored.
lowerStmt :: StmtBuf -> AST.Statement Zonked -> Lower (StmtBuf, Bool)
lowerStmt buf = \case
  AST.StatementLet stmt -> do
    (var, buf') <- lowerExpr buf stmt.value
    binds <- bindPattern var stmt.pattern
    -- bindPattern modifies state for downstream statements; no extra IR.
    sequence_ binds
    pure (buf', False)
  AST.StatementReturn stmt -> do
    (var, buf') <- lowerExpr buf stmt.value
    pure (emit (SExit ExitData {exitKind = ExitReturn, value = var}) buf', True)
  AST.StatementBreak stmt -> do
    (var, buf') <- lowerExpr buf stmt.value
    pure (emit (SExit ExitData {exitKind = ExitBreak, value = var}) buf', True)
  AST.StatementForBreak stmt -> do
    (var, buf') <- lowerExpr buf stmt.value
    pure (emit (SExit ExitData {exitKind = ExitForBreak, value = var}) buf', True)
  AST.StatementNext stmt -> do
    (var, buf') <- lowerExpr buf stmt.value
    mods <- mapM (lowerModifier buf') stmt.modifiers
    let (modPairs, bufAfterMods) = unrollMods buf' mods
    pure
      ( emit
          (SCont ContData {contKind = ContNext, value = Just var, mods = modPairs})
          bufAfterMods,
        True
      )
  AST.StatementForNext stmt -> do
    mods <- mapM (lowerModifier buf) stmt.modifiers
    let (modPairs, bufAfterMods) = unrollMods buf mods
    pure
      ( emit
          (SCont ContData {contKind = ContForNext, value = Nothing, mods = modPairs})
          bufAfterMods,
        True
      )
  AST.StatementExpression expr -> do
    (_, buf') <- lowerExpr buf expr
    pure (buf', False)
  AST.StatementAgent _ -> do
    -- Stage 4 implements local agent (MakeClosure into local var).
    pure (buf, False)
  AST.StatementError sp -> do
    recordError (LowerErrorParseSentinel sp)
    pure (buf, False)

-- | Lower one 'AST.Modifier' producing @(label, value-bearing IR var)@. The
-- expression for the new value may emit statements into the shared buffer;
-- the caller is responsible for threading the buffer through.
lowerModifier ::
  StmtBuf ->
  AST.Modifier Zonked ->
  Lower ((Text, VarId), StmtBuf)
lowerModifier buf m = do
  (var, buf') <- lowerExpr buf m.value
  pure ((m.name.text, var), buf')

-- | Helper to thread the buffer through a list of modifier-lowering results.
-- Each entry is @((label, var), updatedBuf)@; we want the final buffer plus
-- the list of (label, var) pairs.
unrollMods ::
  StmtBuf ->
  [((Text, VarId), StmtBuf)] ->
  ([(Text, VarId)], StmtBuf)
unrollMods _ [] = ([], [])
unrollMods initial xs =
  let pairs = map fst xs
      finalBuf = case xs of
        [] -> initial
        _ -> snd (last xs)
   in (pairs, finalBuf)

-- | Bind a pattern against a known IR var; for variable / wildcard patterns
-- this just records a local mapping. Returns a list of effects that already
-- run (modifying the lower-state). Tuple / constructor / literal destructuring
-- is added later (Stage 2+ for match-style, Stage 3 for let).
bindPattern :: VarId -> AST.Pattern Zonked -> Lower [Lower ()]
bindPattern incoming = \case
  AST.PatternVariable vp -> case vp.name.metadata of
    ZonkedVariable variableId -> do
      modify (\s -> s {lsLocalVars = Map.insert variableId incoming s.lsLocalVars})
      pure []
    ZonkedUnresolvedVariable -> do
      recordError (LowerErrorUnresolvedVariable vp.sourceSpan vp.name.text)
      pure []
  AST.PatternWildcard _ -> pure []
  other -> do
    recordError $
      LowerErrorUnsupported
        (AST.sourceSpanOf other)
        "let-pattern destructuring not yet supported"
    pure []

-- ===========================================================================
-- Expressions
-- ===========================================================================

-- | Lower an 'AST.Expression'. Returns the IR var holding the value and the
-- updated statement buffer. The fresh var is allocated regardless (callers
-- can drop it via @SCall { output = Nothing }@-style emissions later).
lowerExpr :: StmtBuf -> AST.Expression Zonked -> Lower (VarId, StmtBuf)
lowerExpr buf = \case
  AST.ExpressionLiteral lit -> lowerLiteral buf lit
  AST.ExpressionVariable ve -> lowerVariable buf ve
  AST.ExpressionBinaryOperator be -> do
    (lhs, buf1) <- lowerExpr buf be.left
    (rhs, buf2) <- lowerExpr buf1 be.right
    out <- freshVarId Nothing
    blockId <- primBlockId (binaryOpPrim be.operator)
    let stmt =
          SCall
            CallData
              { target = CTBlock {block = blockId},
                args = [Arg "lhs" lhs, Arg "rhs" rhs],
                output = Just out
              }
    pure (out, emit stmt buf2)
  AST.ExpressionUnaryOperator ue -> do
    (operand, buf1) <- lowerExpr buf ue.operand
    out <- freshVarId Nothing
    blockId <- primBlockId (unaryOpPrim ue.operator)
    let stmt =
          SCall
            CallData
              { target = CTBlock {block = blockId},
                args = [Arg "operand" operand],
                output = Just out
              }
    pure (out, emit stmt buf1)
  AST.ExpressionCall ce -> lowerCall buf ce
  AST.ExpressionTuple te -> do
    (elements, buf') <- lowerExprList buf te.elements
    out <- freshVarId Nothing
    blockId <- primBlockId "make_tuple"
    let args = zipWith mkIndexedArg [0 ..] elements
        stmt =
          SCall
            CallData
              { target = CTBlock {block = blockId},
                args = args,
                output = Just out
              }
    pure (out, emit stmt buf')
  AST.ExpressionArray ae -> do
    (elements, buf') <- lowerExprList buf ae.elements
    out <- freshVarId Nothing
    blockId <- primBlockId "make_array"
    let args = zipWith mkIndexedArg [0 ..] elements
        stmt =
          SCall
            CallData
              { target = CTBlock {block = blockId},
                args = args,
                output = Just out
              }
    pure (out, emit stmt buf')
  AST.ExpressionFieldAccess fa -> do
    (object, buf') <- lowerExpr buf fa.object
    -- Field name is loaded as a string literal; get_field consumes (object, field).
    (fieldVar, buf1) <- emitLoadLiteral buf' (LVString fa.fieldName.text)
    out <- freshVarId Nothing
    blockId <- primBlockId "get_field"
    let getFieldCall =
          SCall
            CallData
              { target = CTBlock {block = blockId},
                args = [Arg "object" object, Arg "field" fieldVar],
                output = Just out
              }
    pure (out, emit getFieldCall buf1)
  AST.ExpressionIndexAccess ia -> do
    (array, buf1) <- lowerExpr buf ia.array
    (index, buf2) <- lowerExpr buf1 ia.index
    out <- freshVarId Nothing
    blockId <- primBlockId "array_get"
    let stmt =
          SCall
            CallData
              { target = CTBlock {block = blockId},
                args = [Arg "array" array, Arg "index" index],
                output = Just out
              }
    pure (out, emit stmt buf2)
  AST.ExpressionTemplate te -> lowerTemplate buf te
  AST.ExpressionBlock be -> lowerBlockExpr buf be
  AST.ExpressionIf ie -> lowerIfExpr buf ie
  AST.ExpressionMatch me -> lowerMatchExpr buf me
  AST.ExpressionFor fe -> lowerForExpr buf fe
  AST.ExpressionQualifiedReference qe -> do
    -- A resolved qualified reference (module.target). target.metadata holds
    -- the resolved VariableId; treat it like a bare variable expression.
    case qe.target.metadata of
      ZonkedVariable variableId -> do
        mBlockId <- gets (Map.lookup variableId . (.lsVarBlockIds))
        case mBlockId of
          Just bid -> closureRef qe.target.text bid
          Nothing -> do
            recordError (LowerErrorUnresolvedVariable qe.sourceSpan qe.target.text)
            v <- freshVarId Nothing
            pure (v, buf)
      ZonkedUnresolvedVariable -> do
        recordError (LowerErrorUnresolvedVariable qe.sourceSpan qe.target.text)
        v <- freshVarId Nothing
        pure (v, buf)
    where
      closureRef hintName bid = do
        v <- freshVarId (Just hintName)
        pure (v, emit (SMakeClosure MakeClosureData {output = v, block = bid}) buf)

-- | Lower a list of expressions, threading the buffer.
lowerExprList :: StmtBuf -> [AST.Expression Zonked] -> Lower ([VarId], StmtBuf)
lowerExprList = go []
  where
    go acc buf [] = pure (reverse acc, buf)
    go acc buf (e : es) = do
      (var, buf') <- lowerExpr buf e
      go (var : acc) buf' es

-- | Make an Arg with an indexed label like @"_0"@, @"_1"@, … for tuple /
-- array literal construction.
mkIndexedArg :: Int -> VarId -> Arg
mkIndexedArg i var = Arg {label = "_" <> Text.pack (show i), var = var}

-- | Lower a function call. Decides whether to emit a static 'CTBlock' call
-- (when the callee resolves to a top-level decl / ctor / prim) or a closure
-- 'CTValue' call (when the callee is a local variable holding a function).
lowerCall :: StmtBuf -> AST.CallExpression Zonked -> Lower (VarId, StmtBuf)
lowerCall buf ce = do
  -- Lower argument values first.
  (argVars, bufArgs) <- lowerExprList buf (map (.value) ce.arguments)
  let argLabels = map (.label.text) ce.arguments
      args = zipWith Arg argLabels argVars
  -- Resolve the callee.
  (target, bufFinal) <- resolveCallee bufArgs ce.callee
  out <- freshVarId Nothing
  let stmt =
        SCall
          CallData
            { target = target,
              args = args,
              output = Just out
            }
  pure (out, emit stmt bufFinal)

-- | Resolve an expression that's used in the callee position. Returns the
-- 'CallTarget' and the (possibly extended) statement buffer.
resolveCallee ::
  StmtBuf ->
  AST.Expression Zonked ->
  Lower (CallTarget, StmtBuf)
resolveCallee buf = \case
  AST.ExpressionVariable ve ->
    resolveCalleeName
      buf
      ve.name.metadata
      ve.sourceSpan
      ve.name.text
      (\variableId -> gets (Map.lookup variableId . (.lsLocalVars)))
  AST.ExpressionQualifiedReference qe ->
    -- Qualified references never bind locally — only consult the top-level
    -- block id table.
    resolveCalleeName buf qe.target.metadata qe.sourceSpan qe.target.text (const (pure Nothing))
  -- For any other callee shape (a higher-order computation), lower it to a
  -- closure value first.
  other -> do
    (var, buf') <- lowerExpr buf other
    pure (CTValue {var = var}, buf')

-- | Shared callee-name resolution: try the local map first (if applicable),
-- then fall back to the top-level @VariableId → BlockId@ table. Failures
-- yield a 'CTValue' on a fresh placeholder var with an error recorded.
resolveCalleeName ::
  StmtBuf ->
  Zonked 'AST.VariableRef ->
  AST.SourceSpan ->
  Text ->
  (VariableId -> Lower (Maybe VarId)) ->
  Lower (CallTarget, StmtBuf)
resolveCalleeName buf metadata sp nameText lookupLocal = case metadata of
  ZonkedVariable variableId -> do
    mLocal <- lookupLocal variableId
    case mLocal of
      Just irVar -> pure (CTValue {var = irVar}, buf)
      Nothing -> do
        mBlockId <- gets (Map.lookup variableId . (.lsVarBlockIds))
        case mBlockId of
          Just bid -> pure (CTBlock {block = bid}, buf)
          Nothing -> do
            recordError (LowerErrorUnresolvedVariable sp nameText)
            v <- freshVarId Nothing
            pure (CTValue {var = v}, buf)
  ZonkedUnresolvedVariable -> do
    recordError (LowerErrorUnresolvedVariable sp nameText)
    v <- freshVarId Nothing
    pure (CTValue {var = v}, buf)

-- | Lower an 'AST.TemplateExpression' as a left-fold of @concat@ prim calls.
lowerTemplate ::
  StmtBuf ->
  AST.TemplateExpression Zonked ->
  Lower (VarId, StmtBuf)
lowerTemplate buf te = do
  (vars, buf') <- foldElements [] buf te.elements
  case vars of
    [] ->
      -- empty template => empty string literal
      emitLoadLiteral buf' (LVString "")
    [single] ->
      -- single piece: just stringify and pass through
      stringify buf' single
    (first : rest) -> do
      (initVar, bufInit) <- ensureString buf' first
      foldM (concatStep) (initVar, bufInit) rest
  where
    foldElements acc b [] = pure (reverse acc, b)
    foldElements acc b (e : es) = do
      (v, b') <- lowerTemplateElement b e
      foldElements (v : acc) b' es

    stringify b v = do
      blockId <- primBlockId "to_string"
      out <- freshVarId Nothing
      let stmt =
            SCall
              CallData
                { target = CTBlock {block = blockId},
                  args = [Arg "value" v],
                  output = Just out
                }
      pure (out, emit stmt b)

    ensureString b v = stringify b v

    concatStep (lhs, b) rhsRaw = do
      (rhs, b1) <- ensureString b rhsRaw
      blockId <- primBlockId "concat"
      out <- freshVarId Nothing
      let stmt =
            SCall
              CallData
                { target = CTBlock {block = blockId},
                  args = [Arg "lhs" lhs, Arg "rhs" rhs],
                  output = Just out
                }
      pure (out, emit stmt b1)

lowerTemplateElement ::
  StmtBuf ->
  AST.TemplateElement Zonked ->
  Lower (VarId, StmtBuf)
lowerTemplateElement buf = \case
  AST.TemplateElementString tse -> emitLoadLiteral buf (LVString tse.value)
  AST.TemplateElementExpression tee -> lowerExpr buf tee.value

-- ===========================================================================
-- Inline block / control-flow expressions
-- ===========================================================================

-- | Lower an inline block expression @{ stmts; tail }@. We create a child
-- 'UserBlock' with @inheritScope=True@ (so it shares the parent's scope) and
-- emit a static call to it.
lowerBlockExpr ::
  StmtBuf ->
  AST.BlockExpression Zonked ->
  Lower (VarId, StmtBuf)
lowerBlockExpr buf be = do
  childBlockId <- buildInlineBlock be.block
  out <- freshVarId Nothing
  let stmt =
        SCall
          CallData
            { target = CTBlock {block = childBlockId},
              args = [],
              output = Just out
            }
  pure (out, emit stmt buf)

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
-- branch is matched by tag @"true"@; the else branch (or implicit null block)
-- is the default.
lowerIfExpr ::
  StmtBuf ->
  AST.IfExpression Zonked ->
  Lower (VarId, StmtBuf)
lowerIfExpr buf ie = do
  (cond, buf1) <- lowerExpr buf ie.condition
  thenBlockId <- buildInlineBlock ie.thenBlock
  defaultBlockId <- case ie.elseBlock of
    Just elseBlk -> Just <$> buildInlineBlock elseBlk
    Nothing -> pure Nothing
  out <- freshVarId Nothing
  let stmt =
        SMatch
          MatchData
            { subject = cond,
              arms =
                [ MatchArm
                    { tag = Just "true",
                      bindings = [],
                      body = thenBlockId
                    }
                ],
              defaultArm = defaultBlockId,
              output = Just out
            }
  pure (out, emit stmt buf1)

-- | Lower a match expression. Stage 2 supports flat patterns (variable /
-- wildcard / tuple / one-level constructor). Nested constructor patterns are
-- decomposed: each arm whose pattern contains a nested constructor is rewritten
-- internally to a chain of single-level SMatch with shared default block.
--
-- For now we support:
--   * VariablePattern - tag=Nothing, binds the subject to a fresh var
--   * WildcardPattern - tag=Nothing
--   * LiteralPattern  - tag=Just (literal as text), no bindings
--   * TuplePattern    - tag=Nothing, bindings via "_0", "_1", ...
--   * QualifiedConstructorPattern - tag=Just ctor, bindings via field labels
--     (only one level of nesting; nested patterns inside fields fall back to
--     wildcard)
lowerMatchExpr ::
  StmtBuf ->
  AST.MatchExpression Zonked ->
  Lower (VarId, StmtBuf)
lowerMatchExpr buf me = do
  (subject, buf1) <- lowerExpr buf me.subject
  arms <- mapM (lowerMatchArm subject) me.cases
  out <- freshVarId Nothing
  let stmt =
        SMatch
          MatchData
            { subject = subject,
              arms = arms,
              defaultArm = Nothing,
              output = Just out
            }
  pure (out, emit stmt buf1)

lowerMatchArm :: VarId -> AST.CaseArm Zonked -> Lower MatchArm
lowerMatchArm subject arm = do
  (tag, bindings, localBinds) <- patternToArm subject arm.pattern
  body <- buildArmBody localBinds arm.body
  pure MatchArm {tag = tag, bindings = bindings, body = body}

-- | Translate a pattern into the arm's @(tag, bindings, locals)@ tuple. The
-- @locals@ list is added to the lowering's local map while the arm body is
-- being lowered.
patternToArm ::
  VarId ->
  AST.Pattern Zonked ->
  Lower (Maybe Text, [(Text, VarId)], [(VariableId, VarId)])
patternToArm subject = \case
  AST.PatternVariable vp -> case vp.name.metadata of
    ZonkedVariable variableId ->
      pure (Nothing, [], [(variableId, subject)])
    ZonkedUnresolvedVariable -> do
      recordError (LowerErrorUnresolvedVariable vp.sourceSpan vp.name.text)
      pure (Nothing, [], [])
  AST.PatternWildcard _ -> pure (Nothing, [], [])
  AST.PatternLiteral lp -> do
    let tagText = case lp.value of
          AST.LiteralValueBoolean True -> "true"
          AST.LiteralValueBoolean False -> "false"
          AST.LiteralValueNull -> "null"
          AST.LiteralValueInteger n -> Text.pack (show n)
          AST.LiteralValueNumber n -> Text.pack (show n)
          AST.LiteralValueString s -> s
    pure (Just tagText, [], [])
  AST.PatternTuple tp -> do
    binds <- mapM bindIndexed (zip [0 :: Int ..] tp.elements)
    let bindings = [(label, var) | (label, var, _) <- binds]
        locals = concatMap (\(_, _, ls) -> ls) binds
    pure (Nothing, bindings, locals)
  AST.PatternQualifiedConstructor qp -> do
    binds <- mapM bindField qp.parameters
    let bindings = [(label, var) | (label, var, _) <- binds]
        locals = concatMap (\(_, _, ls) -> ls) binds
    pure (Just qp.constructorName.text, bindings, locals)
  where
    bindIndexed (idx, p) = do
      (var, locals) <- bindPatternToFreshVar p (Just (Text.pack ("_" <> show idx)))
      pure (Text.pack ("_" <> show idx), var, locals)

    bindField (labelRef, pat) = do
      (var, locals) <- bindPatternToFreshVar pat (Just labelRef.text)
      pure (labelRef.text, var, locals)

-- | Build a child block for a match arm body, with the arm's local bindings
-- in scope.
buildArmBody :: [(VariableId, VarId)] -> AST.Block Zonked -> Lower BlockId
buildArmBody locals blk = do
  blockId <- freshBlockId
  withLocals locals $ do
    (statements, trailing) <- lowerBlockBody blk
    let userBlock =
          defaultUserBlock
            { statements = statements,
              trailing = trailing
            }
    recordBlock blockId (BlockUser {body = userBlock}) Nothing
  pure blockId

-- | Lower a for expression. For now supports a single 'in' binding, no var
-- (state) bindings, and an optional then-block. Stage 5 extends with state
-- vars and multiple in-bindings.
lowerForExpr ::
  StmtBuf ->
  AST.ForExpression Zonked ->
  Lower (VarId, StmtBuf)
lowerForExpr buf fe = do
  -- Lower source arrays and gather (element_var, source_var) pairs + locals.
  (iterPairs, iterLocals, buf1) <- lowerForIters buf fe.inBindings
  -- Lower state var inits and gather (label, init_var) pairs.
  (stateInits, stateLocals, buf2) <- lowerForStates buf1 fe.varBindings
  -- Build body block with both iter vars and state vars in scope.
  bodyBlockId <- buildForBody iterPairs (iterLocals ++ stateLocals) fe.body
  thenBlockId <- case fe.thenBlock of
    Just thenBlk -> Just <$> buildInlineBlock thenBlk
    Nothing -> pure Nothing
  out <- freshVarId Nothing
  let stmt =
        SFor
          ForData
            { iters = iterPairs,
              stateInits = stateInits,
              bodyBlock = bodyBlockId,
              thenBlock = thenBlockId,
              output = Just out
            }
  pure (out, emit stmt buf2)

-- | Lower @for(p in arr) ...@ bindings. Each element-pattern variable receives
-- a fresh IR var; the source array is lowered to a var. Returns
-- @[(elementVar, sourceVar)]@, the locals to add to the body's scope, and the
-- updated buffer.
lowerForIters ::
  StmtBuf ->
  [AST.ForInBinding Zonked] ->
  Lower ([(VarId, VarId)], [(VariableId, VarId)], StmtBuf)
lowerForIters = go [] []
  where
    go pairsAcc localsAcc currentBuf [] =
      pure (reverse pairsAcc, reverse localsAcc, currentBuf)
    go pairsAcc localsAcc currentBuf (b : bs) = do
      (sourceVar, currentBuf') <- lowerExpr currentBuf b.source
      (elementVar, locals) <- bindPatternToFreshVar b.pattern Nothing
      go ((elementVar, sourceVar) : pairsAcc) (locals ++ localsAcc) currentBuf' bs

-- | Lower @for(... )(var s = init) ...@ state bindings. Returns
-- @(stateInits, stateLocals, updatedBuf)@. The element body needs the state
-- vars as fresh IR vars (one per state var), exposed through the local map.
lowerForStates ::
  StmtBuf ->
  [AST.ForVarBinding Zonked] ->
  Lower ([(Text, VarId)], [(VariableId, VarId)], StmtBuf)
lowerForStates buf bindings = go ([], []) buf bindings
  where
    go ::
      ([(Text, VarId)], [(VariableId, VarId)]) ->
      StmtBuf ->
      [AST.ForVarBinding Zonked] ->
      Lower ([(Text, VarId)], [(VariableId, VarId)], StmtBuf)
    go (initsAcc, localsAcc) currentBuf [] =
      pure (reverse initsAcc, reverse localsAcc, currentBuf)
    go (initsAcc, localsAcc) currentBuf (binding : rest) = do
      let nameRef = binding.name
          labelText = nameRef.text
          spanInfo = binding.sourceSpan
          initialExpr = binding.initial
      (initVar, currentBuf') <- lowerExpr currentBuf initialExpr
      case nameRef.metadata of
        ZonkedVariable variableId -> do
          bodyVar <- freshVarId (Just labelText)
          go
            ( (labelText, initVar) : initsAcc,
              (variableId, bodyVar) : localsAcc
            )
            currentBuf'
            rest
        ZonkedUnresolvedVariable -> do
          recordError (LowerErrorUnresolvedVariable spanInfo labelText)
          go (initsAcc, localsAcc) currentBuf' rest

buildForBody ::
  [(VarId, VarId)] ->
  [(VariableId, VarId)] ->
  AST.Block Zonked ->
  Lower BlockId
buildForBody _iterPairs stateLocals body = do
  blockId <- freshBlockId
  withLocals stateLocals $ do
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
emitLoadLiteral :: StmtBuf -> LiteralValue -> Lower (VarId, StmtBuf)
emitLoadLiteral buf lv = do
  out <- freshVarId Nothing
  let stmt = SLoadLiteral LoadLiteralData {output = out, value = lv}
  pure (out, emit stmt buf)

-- | Lower an 'AST.LiteralExpression' as an 'SLoadLiteral'.
lowerLiteral :: StmtBuf -> AST.LiteralExpression Zonked -> Lower (VarId, StmtBuf)
lowerLiteral buf lit = emitLoadLiteral buf (astLiteralToIR lit.value)

-- | Lower an 'AST.VariableExpression'. Result depends on whether the
-- referenced 'VariableId' is a local binding (just return its IR var) or a
-- top-level decl (allocate a closure value via 'SMakeClosure').
lowerVariable :: StmtBuf -> AST.VariableExpression Zonked -> Lower (VarId, StmtBuf)
lowerVariable buf ve = case ve.name.metadata of
  ZonkedUnresolvedVariable -> do
    recordError (LowerErrorUnresolvedVariable ve.sourceSpan ve.name.text)
    var <- freshVarId Nothing
    pure (var, buf)
  ZonkedVariable variableId -> do
    locals <- gets (.lsLocalVars)
    case Map.lookup variableId locals of
      Just irVar -> pure (irVar, buf)
      Nothing -> do
        mBlockId <- gets (Map.lookup variableId . (.lsVarBlockIds))
        case mBlockId of
          Just bid -> closureValue buf bid
          Nothing -> do
            recordError (LowerErrorUnresolvedVariable ve.sourceSpan ve.name.text)
            v <- freshVarId Nothing
            pure (v, buf)
  where
    closureValue b blockId = do
      v <- freshVarId (Just ve.name.text)
      pure (v, emit (SMakeClosure MakeClosureData {output = v, block = blockId}) b)
