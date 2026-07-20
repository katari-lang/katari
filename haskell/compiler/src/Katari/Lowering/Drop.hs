-- | The post-lowering drop-insertion pass: release provably-dead variables early via 'OperationDrop'.
--
-- A thread's whole scope (its @values@ map) is re-persisted every turn, so a compiler-internal
-- temporary that stays bound for the scope's lifetime — a call's argument record, a delegate output
-- consumed by the very next bind — costs write volume on every later turn. This pass walks each
-- finished 'IRModule' and inserts, after the operation holding a variable's last mention, a @drop@
-- releasing it. The analysis is deliberately conservative: anything it cannot prove dead simply stays
-- bound for the runtime's scope-level GC — correctness (never drop a variable that could still be
-- read) is the only hard requirement, while a missed drop is merely a smaller saving.
--
-- Soundness rests on three premises of the IR / runtime, verified against the current code:
--
--   1. A 'Sequence' block is straight-line: the runtime's cursor passes each operation at most once
--      (@runSequence@, and the callAck resume that advances a suspended operation), and every
--      operation of the sequence runs on the one thread whose local scope also receives every write
--      the operations perform — @writeVariable@ writes only locally, and a suspended operation's
--      output lands in the same @thread.scopeId@ when its answer arrives. Control flow — match /
--      for / handle / parallel — lives in OTHER blocks, each run as its own thread in a fresh child
--      scope.
--   2. 'VariableId's are unique module-wide (lowering draws them from one @nextVariableId@ counter
--      that is never reset), so an id written by a sequence's operation can only ever be mentioned
--      by this module's own blocks.
--   3. No block of another module can reference this module's 'VariableId's: a cross-module call
--      passes an argument record (a value), never a scope, and a closure value resolves back to a
--      block of the module that made it.
--
-- Therefore a variable WRITTEN by an operation of sequence S is provably dead right after its last
-- mention within S, provided it is mentioned nowhere else in the module — not in any other block's
-- operations or variable-bearing fields, not in any block's 'BlockInformation.parameters', and not
-- as S's own 'result' (which the runtime reads after the last operation). The rule is uniform: the
-- last mention may be a read or the write itself, so an unread output is dropped immediately after
-- it is written.
--
-- The mention walkers below total-case over every 'Block' / 'Operation' / 'Pattern' constructor, so
-- adding a variable-bearing constructor fails to compile here instead of being silently missed.
module Katari.Lowering.Drop
  ( insertDropOperations,
  )
where

import Data.List (sort)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (maybeToList)
import Data.Set (Set)
import Data.Set qualified as Set
import GHC.List (List)
import Katari.Data.IR

-- | Insert 'OperationDrop's into every 'BlockSequence' of the module (see the module header for the
-- liveness rule). Non-sequence blocks carry no operation list, so they pass through unchanged.
insertDropOperations :: IRModule -> IRModule
insertDropOperations irModule = irModule {blocks = Map.map rewriteBlock irModule.blocks}
  where
    moduleWideMentions = moduleMentions irModule
    -- Named construction rather than a record update: 'DeferOperation' also carries a @block@ field, so
    -- an unqualified @information {block = ...}@ update would be ambiguous under DuplicateRecordFields.
    rewriteBlock :: BlockInformation -> BlockInformation
    rewriteBlock information = case information.block of
      BlockSequence sequenceBlock ->
        BlockInformation
          { block = BlockSequence (insertSequenceDrops moduleWideMentions sequenceBlock),
            parameters = information.parameters
          }
      _ -> information

-- | Rewrite one sequence: compute each locally-written variable's last mention index and insert one
-- @drop@ — its variables sorted, so the emitted IR is deterministic — after each index where at least
-- one variable dies. An operation that unconditionally transfers control away ('OperationExit' /
-- 'OperationContinue') never falls through, so a drop after it would be unreachable and is skipped
-- rather than emitted as dead IR.
insertSequenceDrops :: Map VariableId Int -> Sequence -> Sequence
insertSequenceDrops moduleWideMentions sequenceBlock = sequenceBlock {operations = rebuilt}
  where
    operations = sequenceBlock.operations
    localMentions = countMentions (concatMap operationVariables operations)
    -- Provably dead within this sequence: written by one of its operations, and every mention the
    -- whole module has of it is one of this sequence's own operation mentions. The sequence's
    -- 'result' and every block's parameters map are counted module-wide but not in 'localMentions',
    -- so a variable escaping through either is excluded automatically.
    escapesSequence variable =
      Map.lookup variable moduleWideMentions /= Map.lookup variable localMentions
    candidates :: Set VariableId
    candidates =
      Set.filter (not . escapesSequence) (Set.fromList (concatMap operationWrites operations))
    -- 'Map.fromList' keeps the last value per key, and the indices ascend, so each candidate maps to
    -- the index of the operation mentioning it last.
    lastMentionIndex :: Map VariableId Int
    lastMentionIndex =
      Map.fromList
        [ (variable, index)
          | (index, operation) <- zip [0 :: Int ..] operations,
            variable <- operationVariables operation,
            Set.member variable candidates
        ]
    diesAfter :: Map Int (List VariableId)
    diesAfter =
      Map.map sort $
        Map.fromListWith (<>) [(index, [variable]) | (variable, index) <- Map.toList lastMentionIndex]
    rebuilt =
      concat [operation : dropsAfter index operation | (index, operation) <- zip [0 :: Int ..] operations]
    dropsAfter index operation = case Map.lookup index diesAfter of
      Just variables | not (transfersControl operation) -> [OperationDrop DropOperation {variables = variables}]
      _ -> []

-- | An operation past which the cursor never resumes: the raised control ask is consumed by its
-- target and the asking thread is unwound, never stepped further, so anything after it is
-- unreachable. (Lowering emits these only in tail position anyway.)
transfersControl :: Operation -> Bool
transfersControl = \case
  OperationExit _ -> True
  OperationContinue _ -> True
  _ -> False

---------------------------------------------------------------------------------------------------
-- Mention walkers (total over every constructor)
---------------------------------------------------------------------------------------------------

-- | How many times each variable is mentioned anywhere in the module: every block's variable-bearing
-- fields (operations included) plus every block's scope-seeding parameters. Comparing a sequence's
-- own operation mentions against this count decides whether a variable escapes that sequence.
moduleMentions :: IRModule -> Map VariableId Int
moduleMentions irModule = countMentions (concatMap informationVariables (Map.elems irModule.blocks))
  where
    informationVariables information =
      Map.elems information.parameters <> blockVariables information.block

countMentions :: List VariableId -> Map VariableId Int
countMentions variables = Map.fromListWith (+) [(variable, 1 :: Int) | variable <- variables]

-- | Every 'VariableId' a block's own fields mention (a sequence's operations included). Block-id
-- references (bodies, arms, closure agents) carry no variables themselves — each referenced block is
-- walked as its own 'IRModule.blocks' entry.
blockVariables :: Block -> List VariableId
blockVariables = \case
  BlockAgent _ -> []
  BlockSequence sequenceBlock ->
    concatMap operationVariables sequenceBlock.operations <> maybeToList sequenceBlock.result
  BlockPrimitive primitive -> [primitive.input]
  BlockConstruct construct -> [construct.input]
  BlockRequest request -> [request.input]
  BlockExternal external -> [external.input]
  BlockMatch match -> match.subject : concatMap (patternVariables . (.pattern)) match.arms
  BlockFor for -> for.source : for.initialStates
  -- A forever block references its caller-scope @var@ initials (seeded into the body's @state_N@); its
  -- body's own variables are counted where that block is walked as its own entry.
  BlockForever forever' -> forever'.initialStates
  BlockHandle handle -> handle.initialStates
  BlockParallel _ -> []

-- | Every 'VariableId' one operation mentions — reads and writes alike. The liveness rule counts the
-- write itself as a mention, which is what lets an unread output die right where it is written.
operationVariables :: Operation -> List VariableId
operationVariables = \case
  OperationCall operation -> maybeToList operation.output
  OperationDelegate operation ->
    calleeVariables operation.target <> (operation.argument : maybeToList operation.output)
  OperationLoadLiteral operation -> [operation.output]
  OperationLoadAgent operation -> [operation.output]
  OperationMakeClosure operation -> [operation.output]
  OperationMakeRecord operation -> map snd operation.entries <> [operation.output]
  OperationMakeTuple operation -> operation.elements <> [operation.output]
  OperationGetField operation -> [operation.source, operation.output]
  OperationBindPattern operation -> operation.source : patternVariables operation.pattern
  OperationApplyGenerics operation -> [operation.source, operation.output]
  OperationExit operation -> [operation.value]
  OperationContinue operation ->
    maybeToList operation.value <> concatMap (\(state, value) -> [state, value]) operation.modifiers
  OperationDrop operation -> operation.variables
  -- A defer names only the block to arm; that block reads the enclosing scope through the ordinary
  -- parent chain, so the defer op mentions no variables of this sequence. The armed block's own reads
  -- are counted where the block is walked as its own 'IRModule.blocks' entry.
  OperationDefer _ -> []

-- | The variables an operation writes into the EXECUTING thread's local scope — the drop candidates.
-- A 'ContinueOperation''s modifiers write into the TARGET block's scope instead, so they are not
-- local writes (their state variables live in that body's parameters map besides, which already
-- disqualifies them as candidates).
operationWrites :: Operation -> List VariableId
operationWrites = \case
  OperationCall operation -> maybeToList operation.output
  OperationDelegate operation -> maybeToList operation.output
  OperationLoadLiteral operation -> [operation.output]
  OperationLoadAgent operation -> [operation.output]
  OperationMakeClosure operation -> [operation.output]
  OperationMakeRecord operation -> [operation.output]
  OperationMakeTuple operation -> [operation.output]
  OperationGetField operation -> [operation.output]
  OperationBindPattern operation -> patternVariables operation.pattern
  OperationApplyGenerics operation -> [operation.output]
  OperationExit _ -> []
  OperationContinue _ -> []
  OperationDrop _ -> []
  -- A defer transfers no value into the executing thread's scope, so it writes nothing.
  OperationDefer _ -> []

calleeVariables :: CalleeReference -> List VariableId
calleeVariables = \case
  CalleeName _ -> []
  CalleeValue variable -> [variable]

-- | The variables a pattern binds (every 'PatternVariable' position; the runtime writes each matched
-- sub-value into the executing thread's scope).
patternVariables :: Pattern -> List VariableId
patternVariables = \case
  PatternAny -> []
  PatternVariable variable -> [variable]
  PatternLiteral _ -> []
  PatternConstructor _ fields -> concatMap (patternVariables . snd) fields
  PatternTuple elements -> concatMap patternVariables elements
  PatternRecord fields -> concatMap (patternVariables . snd) fields
  PatternTypeGuard _ inner -> patternVariables inner
