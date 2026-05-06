-- | Stage-by-stage lowering tests. Each stage adds progressively more complex
-- programs and asserts on the resulting 'IRModule' shape.
--
-- Run order matches the plan's verification ladder. A stage marks itself
-- 'pendingWith' when the underlying lowering feature isn't implemented yet.
module Katari.LoweringSpec (spec) where

import Control.Exception (SomeException, try)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Katari.IR
import Katari.Lowering (LoweringError (..), lowerProgram)
import Katari.Lexer qualified as Lexer
import Katari.Parser qualified as Parser
import Katari.SemanticType (RequestVariableId (..), TypeVariableId (..))
import Katari.Typechecker.ConstraintGenerator (ConstraintGenResult (..), VariableSupply (..), generateConstraints)
import Katari.Typechecker.Identifier (identify)
import Katari.Typechecker.NormalizedType (NormalizedType (..))
import Katari.Typechecker.Solver (SolverResult (..))
import Katari.Typechecker.Zonker (zonk)
import System.Directory (listDirectory)
import System.FilePath ((</>))
import Test.Hspec

-- ===========================================================================
-- Pipeline helper: source → IR
-- ===========================================================================

-- | Run parser → identify → constraint-gen → totalised solver → zonk → lower.
-- Aborts the spec if upstream phases fail.
lowerSource :: Text -> IO (IRModule, [LoweringError])
lowerSource src =
  let (stream, _) = Lexer.lex "<test>" src
      (parsed, parseErrors) = Parser.parse "<test>" stream
  in case parseErrors of
    (_:_) -> fail ("parse failure: " ++ show parseErrors)
    [] -> case identify (Map.singleton "main" parsed) of
      (idResult, []) -> do
        let (cg, _) = generateConstraints idResult
            solver =
              SolverResult
                { typeSubstitution =
                    Map.fromList [(TypeVariableId i, NormalizedTypeUnknown) | i <- [0 .. cg.variableSupply.typeVarSupply - 1]],
                  requestSubstitution =
                    Map.fromList [(RequestVariableId i, Set.empty) | i <- [0 .. cg.variableSupply.requestVarSupply - 1]]
                }
            (zr, _) = zonk idResult cg solver
        pure (lowerProgram "main" idResult zr)
      (_, errs) -> fail ("identify failure: " ++ show errs)

-- ===========================================================================
-- Spec
-- ===========================================================================

-- | Look up the user-block body of a top-level agent by bare name.
-- Test fixtures load every source under module name @"main"@, so the
-- qualified name we look up is @QualifiedName "main" agentName@.
agentBody :: Text -> IRModule -> Maybe UserBlock
agentBody agentName irMod = do
  entryId <- Map.lookup (QualifiedName "main" agentName) irMod.entries
  block <- Map.lookup entryId irMod.blocks
  case block of
    BlockUser {body} -> Just body
    _ -> Nothing

-- | Resolve a constructor's bare name (in module @"main"@) to its IR
-- 'CtorId' so 'MatchTag' assertions can compare against the
-- declaration-side identifier rather than a string.
ctorIdOf :: Text -> IRModule -> Maybe CtorId
ctorIdOf ctorName irMod = do
  bid <- Map.lookup (QualifiedName "main" ctorName) irMod.entries
  case Map.lookup bid irMod.blocks of
    Just BlockCtor {ctorId} -> Just ctorId
    _ -> Nothing

-- | Look up the BlockId for a primitive by name.
primId :: Text -> IRModule -> Maybe BlockId
primId primName irMod =
  fst
    <$> find (matchPrim primName . snd) (Map.toList irMod.blocks)
  where
    matchPrim wanted (BlockPrim {name}) = name == wanted
    matchPrim _ _ = False

-- | Extract the StatementCall statements from a UserBlock body.
calls :: UserBlock -> [CallData]
calls ub = [d | StatementCall d <- ub.statements]

-- | Extract the StatementLoadLiteral statements from a UserBlock body.
literalLoads :: UserBlock -> [LoadLiteralData]
literalLoads ub = [d | StatementLoadLiteral d <- ub.statements]

-- | Extract MatchBlock from a block in the IR module (for BlockMatch blocks).
matchBlockOf :: BlockId -> IRModule -> Maybe MatchBlock
matchBlockOf bid irMod = case Map.lookup bid irMod.blocks of
  Just (BlockMatch {matchBlock}) -> Just matchBlock
  _ -> Nothing

-- | Extract ForBlock from a block in the IR module (for BlockFor blocks).
forBlockOf :: BlockId -> IRModule -> Maybe ForBlock
forBlockOf bid irMod = case Map.lookup bid irMod.blocks of
  Just (BlockFor {forBlock}) -> Just forBlock
  _ -> Nothing

-- | Extract HandleBlock from a block in the IR module (for BlockHandle blocks).
handleBlockOf :: BlockId -> IRModule -> Maybe HandleBlock
handleBlockOf bid irMod = case Map.lookup bid irMod.blocks of
  Just (BlockHandle {handleBlock}) -> Just handleBlock
  _ -> Nothing

-- | Find all BlockMatch blocks that are called from a UserBlock.
calledMatchBlocks :: UserBlock -> IRModule -> [MatchBlock]
calledMatchBlocks ub irMod =
  [ mb
    | StatementCall c <- ub.statements,
      CallTargetBlock {block} <- [c.target],
      Just mb <- [matchBlockOf block irMod]
  ]

-- | Find all BlockFor blocks that are called from a UserBlock.
calledForBlocks :: UserBlock -> IRModule -> [ForBlock]
calledForBlocks ub irMod =
  [ fb
    | StatementCall c <- ub.statements,
      CallTargetBlock {block} <- [c.target],
      Just fb <- [forBlockOf block irMod]
  ]

-- | Find all BlockHandle blocks that are called from a UserBlock.
calledHandleBlocks :: UserBlock -> IRModule -> [HandleBlock]
calledHandleBlocks ub irMod =
  [ hb
    | StatementCall c <- ub.statements,
      CallTargetBlock {block} <- [c.target],
      Just hb <- [handleBlockOf block irMod]
  ]

spec :: Spec
spec = describe "Katari.Lowering" $ do
  stage1Spec
  stage2Spec
  stage3Spec
  stage4Spec
  stage5Spec
  stage6Spec
  stage7Spec
  stage8Spec

stage1Spec :: Spec
stage1Spec = describe "Stage 1 — literals / arithmetic" $ do
  it "lowers a trivial empty agent" $ do
    (irMod, errs) <- lowerSource "agent main() {}"
    errs `shouldBe` []
    Map.keys irMod.entries `shouldBe` [QualifiedName "main" "main"]
    case agentBody "main" irMod of
      Nothing -> expectationFailure "main agent not found in IR"
      Just ub -> do
        ub.statements `shouldBe` []
        ub.trailing `shouldBe` Nothing
        ub.parameters `shouldBe` []
        ub.kind `shouldBe` BlockKindAgent

  it "lowers an integer literal as StatementLoadLiteral with the integer value" $ do
    (irMod, errs) <- lowerSource "agent main() { 42 }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case literalLoads ub of
      [d] -> do
        d.value `shouldBe` LiteralValueInteger 42
        Just d.output `shouldBe` ub.trailing
      _ -> expectationFailure "expected exactly one StatementLoadLiteral"

  it "lowers x + y to add prim call with two StatementLoadLiteral inputs" $ do
    (irMod, errs) <- lowerSource "agent main() { let x = 1; let y = 2; x + y }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        Just addId = primId "add" irMod
        loads = literalLoads ub
    length loads `shouldBe` 2
    map (.value) loads `shouldMatchList` [LiteralValueInteger 1, LiteralValueInteger 2]
    case calls ub of
      [addCall] -> do
        addCall.target `shouldBe` CallTargetBlock {block = addId}
        map (.label) addCall.arguments `shouldMatchList` ["lhs", "rhs"]
        addCall.output `shouldBe` ub.trailing
      _ -> expectationFailure "expected exactly one add call"

  it "lowers unary negation to neg prim" $ do
    (irMod, errs) <- lowerSource "agent main() { let x = 7; -x }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        Just negId = primId "neg" irMod
    case calls ub of
      [c] -> do
        c.target `shouldBe` CallTargetBlock {block = negId}
        map (.label) c.arguments `shouldBe` ["operand"]
        c.output `shouldBe` ub.trailing
      _ -> expectationFailure "expected exactly one neg call"
    map (.value) (literalLoads ub) `shouldBe` [LiteralValueInteger 7]

  it "lowers boolean literal as StatementLoadLiteral LiteralValueBoolean" $ do
    (irMod, errs) <- lowerSource "agent main() { true }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case literalLoads ub of
      [d] -> d.value `shouldBe` LiteralValueBoolean True
      _ -> expectationFailure "expected one StatementLoadLiteral"

  it "lowers null as StatementLoadLiteral LiteralValueNull" $ do
    (irMod, errs) <- lowerSource "agent main() { null }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case literalLoads ub of
      [d] -> d.value `shouldBe` LiteralValueNull
      _ -> expectationFailure "expected one StatementLoadLiteral"

  it "lowers string literal as StatementLoadLiteral LiteralValueString" $ do
    (irMod, errs) <- lowerSource "agent main() { \"hello\" }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case literalLoads ub of
      [d] -> d.value `shouldBe` LiteralValueString "hello"
      _ -> expectationFailure "expected one StatementLoadLiteral"

  it "lowers number literal as StatementLoadLiteral LiteralValueNumber" $ do
    (irMod, errs) <- lowerSource "agent main() { 3.14 }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case literalLoads ub of
      [d] -> d.value `shouldBe` LiteralValueNumber 3.14
      _ -> expectationFailure "expected one StatementLoadLiteral"

  it "field access encodes field name as StatementLoadLiteral string" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "data Point(x: integer, y: integer)",
            "agent main() {",
            "  let p = Point(x = 1, y = 2)",
            "  p.x",
            "}"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        loads = literalLoads ub
    -- Among the literal loads should be the field name "x".
    LiteralValueString "x" `elem` map (.value) loads `shouldBe` True

callTargetBlockId :: CallData -> BlockId
callTargetBlockId c = case c.target of
  CallTargetBlock {block} -> block
  CallTargetValue _ -> BlockId maxBound -- sentinel for filter

callTargetBlockMaybe :: CallData -> Maybe BlockId
callTargetBlockMaybe c = case c.target of
  CallTargetBlock {block} -> Just block
  _ -> Nothing

-- | Look up a UserBlock by id.
userBlockOf :: BlockId -> IRModule -> Maybe UserBlock
userBlockOf bid irMod = case Map.lookup bid irMod.blocks of
  Just (BlockUser {body}) -> Just body
  _ -> Nothing

-- ===========================================================================
-- Stage 2 — control flow (if / match / for)
-- ===========================================================================

stage2Spec :: Spec
stage2Spec = describe "Stage 2 \8212 control flow" $ do
  it "lowers if-else as BlockMatch with true arm and default" $ do
    (irMod, errs) <- lowerSource "agent main() { if (true) { 1 } else { 2 } }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case calledMatchBlocks ub irMod of
      [m] -> do
        length m.arms `shouldBe` 1
        let [arm] = m.arms
        arm.pattern `shouldBe` MatchPatternLiteral LiteralValueBoolean {boolean = True}
        m.defaultArm `shouldNotBe` Nothing
      other -> expectationFailure ("expected 1 BlockMatch call, got " <> show (length other))

  it "lowers if without else (defaultArm Nothing)" $ do
    (irMod, errs) <- lowerSource "agent main() { if (true) { 1 }; 0 }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case calledMatchBlocks ub irMod of
      [m] -> m.defaultArm `shouldBe` Nothing
      _ -> expectationFailure "expected 1 BlockMatch call"

  it "if branches lowered to inline blocks" $ do
    (irMod, errs) <- lowerSource "agent main() { if (true) { 1 } else { 2 } }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case calledMatchBlocks ub irMod of
      [m] -> do
        let [arm] = m.arms
        case userBlockOf arm.body irMod of
          Just child -> child.kind `shouldBe` BlockKindInline
          Nothing -> expectationFailure "then-branch block not found"
        case m.defaultArm of
          Just defId -> case userBlockOf defId irMod of
            Just child -> child.kind `shouldBe` BlockKindInline
            Nothing -> expectationFailure "else-branch block not found"
          Nothing -> expectationFailure "expected default branch"
      _ -> expectationFailure "expected 1 BlockMatch call"

  it "lowers data constructor match arm with field bindings" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "data Point(x: integer, y: integer)",
            "agent main() {",
            "  let p = Point(x = 1, y = 2)",
            "  match (p) {",
            "    case Point(x = a, y = b) => { a + b }",
            "  }",
            "}"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        allMatchBlocks = findAllMatchBlocks irMod
    case allMatchBlocks of
      [m] -> do
        case m.arms of
          [arm] -> case arm.pattern of
            MatchPatternConstructor cid fields -> do
              case ctorIdOf "Point" irMod of
                Just expected -> cid `shouldBe` expected
                Nothing -> expectationFailure "Point ctor not in IR entries"
              map fst fields `shouldMatchList` ["x", "y"]
            other -> expectationFailure ("expected MatchPatternConstructor, got " <> show other)
          _ -> expectationFailure "expected 1 arm"
      _ -> expectationFailure ("expected 1 BlockMatch, got " <> show (length allMatchBlocks))

  it "destructures nested constructor patterns inside match arms via pattern tree" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "data Pair(left: integer, right: integer)",
            "data Outer(inner: Pair)",
            "agent main() {",
            "  let v = Outer(inner = Pair(left = 1, right = 2))",
            "  match (v) {",
            "    case Outer(inner = Pair(left = a, right = b)) => { a + b }",
            "  }",
            "}"
          ]
    errs `shouldBe` []
    let allMatchBlocks = findAllMatchBlocks irMod
    case allMatchBlocks of
      [m] -> case m.arms of
        [arm] -> case arm.pattern of
          MatchPatternConstructor outerCid [(outerLabel, innerPat)] -> do
            case ctorIdOf "Outer" irMod of
              Just expected -> outerCid `shouldBe` expected
              Nothing -> expectationFailure "Outer ctor not in IR entries"
            outerLabel `shouldBe` "inner"
            -- The nested Pair pattern is preserved structurally as a
            -- sub-MatchPatternConstructor; runtime walks the tree to bind a / b.
            case innerPat of
              MatchPatternConstructor pairCid pairFields -> do
                case ctorIdOf "Pair" irMod of
                  Just expected -> pairCid `shouldBe` expected
                  Nothing -> expectationFailure "Pair ctor not in IR entries"
                map fst pairFields `shouldMatchList` ["left", "right"]
              other -> expectationFailure ("expected nested MatchPatternConstructor, got " <> show other)
          other -> expectationFailure ("expected MatchPatternConstructor at top level, got " <> show other)
        _ -> expectationFailure "expected 1 arm"
      _ -> expectationFailure ("expected 1 BlockMatch, got " <> show (length allMatchBlocks))

  it "lowers a simple for loop with one in-binding" $ do
    (irMod, errs) <-
      lowerSource
        "agent main() { let arr = [1, 2, 3]; for (x in arr) { x } }"
    errs `shouldBe` []
    let allForBlocks = findAllForBlocks irMod
    case allForBlocks of
      [f] -> do
        length f.iters `shouldBe` 1
        f.stateInits `shouldBe` []
        f.thenBlock `shouldBe` Nothing
      other -> expectationFailure ("expected 1 BlockFor, got " <> show (length other))

  it "lowers a for with then clause" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "agent main() {",
            "  let arr = [1, 2, 3]",
            "  for (x in arr) { x } then { 0 }",
            "}"
          ]
    errs `shouldBe` []
    let allForBlocks = findAllForBlocks irMod
    case allForBlocks of
      [f] -> f.thenBlock `shouldNotBe` Nothing
      _ -> expectationFailure "expected 1 BlockFor"

-- | Find all MatchBlock payloads in the module.
findAllMatchBlocks :: IRModule -> [MatchBlock]
findAllMatchBlocks irMod =
  [mb | BlockMatch {matchBlock = mb} <- Map.elems irMod.blocks]

-- | Find all ForBlock payloads in the module.
findAllForBlocks :: IRModule -> [ForBlock]
findAllForBlocks irMod =
  [fb | BlockFor {forBlock = fb} <- Map.elems irMod.blocks]

-- | Find all HandleBlock payloads in the module.
findAllHandleBlocks :: IRModule -> [HandleBlock]
findAllHandleBlocks irMod =
  [hb | BlockHandle {handleBlock = hb} <- Map.elems irMod.blocks]

-- ===========================================================================
-- Stage 3 — block / let / scope
-- ===========================================================================

stage3Spec :: Spec
stage3Spec = describe "Stage 3 \8212 block / let / scope" $ do
  it "let chain produces sequential statements and trailing var" $ do
    (irMod, errs) <- lowerSource "agent main() { let x = 1; let y = 2; x + y }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    -- Two StatementLoadLiteral (1, 2) plus one StatementCall (add) = 3 statements
    length (literalLoads ub) `shouldBe` 2
    length (calls ub) `shouldBe` 1
    -- The final call's output equals the trailing var
    let lastCall = last (calls ub)
    lastCall.output `shouldBe` ub.trailing

  it "inline block creates a child block with BlockKindInline" $ do
    (irMod, errs) <- lowerSource "agent main() { let x = { let a = 1; a + 1 }; x }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    -- One of the calls in the parent block targets a child UserBlock.
    let childCalls = [c | c <- calls ub, isChildBlockCall c irMod]
    childCalls `shouldNotBe` []
    case childCalls of
      (c : _) -> case c.target of
        CallTargetBlock {block} -> case userBlockOf block irMod of
          Just child -> child.kind `shouldBe` BlockKindInline
          Nothing -> expectationFailure "child block not found"
        _ -> expectationFailure "child call must target a block"
      _ -> pure ()

  it "shadowing assigns a fresh IR var per let binding" $ do
    (irMod, errs) <- lowerSource "agent main() { let x = 1; let x = 2; x }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        loads = literalLoads ub
        -- With StatementBindPattern each let emits a pattern var distinct from the load var.
        bindVars = [v | StatementBindPattern d <- ub.statements, MatchPatternVariable v <- [d.pattern]]
    length loads `shouldBe` 2
    -- Each StatementBindPattern introduces a fresh var; the two must be different.
    case bindVars of
      [v1, v2] -> v1 `shouldNotBe` v2
      _ -> expectationFailure "expected exactly two StatementBindPattern variable outputs"
    -- The trailing var is the second binding's pattern var (the inner x).
    fmap (last bindVars ==) ub.trailing `shouldBe` Just True

  it "let with tuple pattern emits StatementBindPattern with MatchPatternTuple" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "agent main() {",
            "  let (a, b) = (1, 2)",
            "  a + b",
            "}"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        bindPats = [d | StatementBindPattern d <- ub.statements]
    -- Exactly one StatementBindPattern for the tuple destructure.
    length bindPats `shouldBe` 1
    case bindPats of
      [d] -> case d.pattern of
        MatchPatternTuple subs -> length subs `shouldBe` 2
        _ -> expectationFailure "expected MatchPatternTuple pattern"
      _ -> expectationFailure "expected exactly one StatementBindPattern"

  it "let with nested constructor pattern emits StatementBindPattern with MatchPatternConstructor" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "data Pair(left: integer, right: integer)",
            "agent main() {",
            "  let Pair(left = a, right = b) = Pair(left = 1, right = 2)",
            "  a + b",
            "}"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        bindPats = [d | StatementBindPattern d <- ub.statements]
    -- Exactly one StatementBindPattern for the constructor destructure.
    length bindPats `shouldBe` 1
    case bindPats of
      [d] -> case d.pattern of
        MatchPatternConstructor _ fields -> length fields `shouldBe` 2
        _ -> expectationFailure "expected MatchPatternConstructor pattern"
      _ -> expectationFailure "expected exactly one StatementBindPattern"

  it "local agent statement registers a fresh BlockUser and is callable" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "agent main() -> integer {",
            "  agent helper(x: integer) -> integer { x + 1 }",
            "  helper(x = 41)",
            "}"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    -- The main body should issue a StatementMakeClosure whose block is a
    -- BlockUser (the local helper agent), followed by a StatementCall via
    -- CallTargetValue (the closure var).
    let closures =
          [ mc | StatementMakeClosure mc <- ub.statements, Just (BlockUser _) <- [Map.lookup mc.block irMod.blocks]
          ]
    length closures `shouldBe` 1
    let helperVar = (head closures).output
    let valueCalls =
          [ c | StatementCall c <- ub.statements, CallTargetValue {var} <- [c.target], var == helperVar
          ]
    length valueCalls `shouldBe` 1

  it "function parameter with tuple pattern destructures via StatementBindPattern" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "agent helper(pair = (a, b)) -> integer { a + b }",
            "agent main() -> integer { helper(pair = (1, 2)) }"
          ]
    errs `shouldBe` []
    -- The helper agent's user block should contain exactly one StatementBindPattern for
    -- the tuple parameter destructure (the runtime handles the field splitting).
    case agentBody "helper" irMod of
      Just helperBody -> do
        let bindPats = [d | StatementBindPattern d <- helperBody.statements]
        length bindPats `shouldBe` 1
        case bindPats of
          [d] -> case d.pattern of
            MatchPatternTuple subs -> length subs `shouldBe` 2
            _ -> expectationFailure "expected MatchPatternTuple pattern"
          _ -> pure ()
      Nothing -> expectationFailure "helper agent body not found"

isChildBlockCall :: CallData -> IRModule -> Bool
isChildBlockCall c irMod = case c.target of
  CallTargetBlock {block} -> case Map.lookup block irMod.blocks of
    Just (BlockUser {body}) -> body.kind == BlockKindInline
    _ -> False
  _ -> False

-- ===========================================================================
-- Stage 4 — agent calls / closure
-- ===========================================================================

stage4Spec :: Spec
stage4Spec = describe "Stage 4 \8212 agent calls / closure" $ do
  it "direct call to a top-level agent uses CallTargetBlock" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "agent helper() -> integer { 42 }",
            "agent main() { helper() }"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case calls ub of
      [c] -> case c.target of
        CallTargetBlock {block} -> case Map.lookup block irMod.blocks of
          Just (BlockUser _) -> pure () -- helper is a user block
          Just _ -> expectationFailure "expected user block target"
          Nothing -> expectationFailure "target block not found"
        _ -> expectationFailure "expected CallTargetBlock target"
      _ -> expectationFailure "expected 1 call"

  it "agent value escapes via StatementMakeClosure when used as a binding" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "agent helper() -> integer { 42 }",
            "agent main() { let f = helper; f() }"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        closures = [d | StatementMakeClosure d <- ub.statements]
    closures `shouldNotBe` []
    -- With StatementBindPattern, the closure var is routed through a pattern binding.
    -- The call should use CallTargetValue on the pattern-bound var, not the closure var.
    case closures of
      (d : _) -> do
        -- The StatementBindPattern that follows should source from the closure output.
        let bindPat = listToMaybe [bp | StatementBindPattern bp <- ub.statements, bp.source == d.output]
        bindPat `shouldSatisfy` isJust
        -- The var used in the CallTargetValue call is the pattern var (not d.output).
        case bindPat of
          Just bp -> case bp.pattern of
            MatchPatternVariable patVar -> do
              let valueCalls = [c | c <- calls ub, c.target == CallTargetValue {var = patVar}]
              valueCalls `shouldNotBe` []
            _ -> expectationFailure "expected MatchPatternVariable pattern for simple let binding"
          Nothing -> pure ()
      _ -> pure ()

-- ===========================================================================
-- Stage 5 — for / state / next
-- ===========================================================================

stage5Spec :: Spec
stage5Spec = describe "Stage 5 \8212 for / state / next" $ do
  it "for with state var emits ForBlock.stateInits and body uses state-var local" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "agent main() -> integer {",
            "  for (x in [1,2,3], var acc: integer = 0) {",
            "    next with { acc = acc + x }",
            "  }",
            "}"
          ]
    errs `shouldBe` []
    let allForBlocks = findAllForBlocks irMod
    case allForBlocks of
      [f] -> do
        length f.stateInits `shouldBe` 1
        case userBlockOf f.bodyBlock irMod of
          Just body -> do
            -- The body should contain at least one StatementCont with kind=ForNext
            let conts = [d | StatementCont d <- body.statements]
            length conts `shouldBe` 1
            case conts of
              [c] -> do
                c.contKind `shouldBe` ContKindForNext
                length c.modifiers `shouldBe` 1
              _ -> pure ()
          Nothing -> expectationFailure "for body block not found"
      _ -> expectationFailure "expected 1 BlockFor"

  it "for_break inside for emits StatementExit ExitKindForBreak" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "agent main() -> integer | null {",
            "  for (x in [1,2,3]) {",
            "    if (x == 2) {",
            "      break x",
            "    }",
            "  }",
            "}"
          ]
    errs `shouldBe` []
    let allForBlocks = findAllForBlocks irMod
    case allForBlocks of
      [f] -> case userBlockOf f.bodyBlock irMod of
        Just body -> do
          -- find a nested StatementExit ExitKindForBreak in any descendant block
          let allExits = collectAllExits body irMod
          any (\e -> e.exitKind == ExitKindForBreak) allExits `shouldBe` True
        Nothing -> expectationFailure "for body not found"
      _ -> expectationFailure "expected 1 BlockFor"

-- | Collect all StatementExit datas reachable through inline / branch / for /
-- handler / then sub-blocks.
collectAllExits :: UserBlock -> IRModule -> [ExitData]
collectAllExits ub irMod = directExits ++ indirectExits
  where
    directExits = [d | StatementExit d <- ub.statements]
    indirectExits =
      concatMap recurse $
        [body' | StatementCall c <- ub.statements, Just body' <- [callTargetUser c]]
          ++ matchBodies
          ++ forBodies
          ++ handleBodies
    callTargetUser c = case c.target of
      CallTargetBlock {block} -> userBlockOf block irMod
      _ -> Nothing
    matchBodies =
      concat
        [ ub' : maybeToList (mb.defaultArm >>= flip userBlockOf irMod)
          | StatementCall c <- ub.statements,
            CallTargetBlock {block} <- [c.target],
            Just mb <- [matchBlockOf block irMod],
            arm <- mb.arms,
            Just ub' <- [userBlockOf arm.body irMod]
        ]
    forBodies =
      concat
        [ catMaybes [userBlockOf fb.bodyBlock irMod, fb.thenBlock >>= flip userBlockOf irMod]
          | StatementCall c <- ub.statements,
            CallTargetBlock {block} <- [c.target],
            Just fb <- [forBlockOf block irMod]
        ]
    handleBodies =
      concat
        [ catMaybes [userBlockOf hb.body irMod] ++ [hBody | h <- hb.handlers, Just hBody <- [userBlockOf h.handlerBody irMod]]
          | StatementCall c <- ub.statements,
            CallTargetBlock {block} <- [c.target],
            Just hb <- [handleBlockOf block irMod]
        ]
    recurse child = collectAllExits child irMod

maybeToList :: Maybe a -> [a]
maybeToList = maybe [] (: [])

catMaybes :: [Maybe a] -> [a]
catMaybes = foldr (\x acc -> case x of Just v -> v : acc; Nothing -> acc) []

-- ===========================================================================
-- Stage 6 — handle scope / where / state vars
-- ===========================================================================

stage6Spec :: Spec
stage6Spec = describe "Stage 6 \8212 handle scope / where / state vars" $ do
  it "where with handlers produces a BlockHandle with handlers" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "req fetch() -> integer",
            "agent main() -> integer {",
            "  handle {",
            "    req fetch() { 42 }",
            "  }",
            "  fetch()",
            "}"
          ]
    errs `shouldBe` []
    let allHandleBlocks = findAllHandleBlocks irMod
    case allHandleBlocks of
      [hb] -> length hb.handlers `shouldBe` 1
      _ -> expectationFailure ("expected 1 BlockHandle, got " <> show (length allHandleBlocks))

  it "handler body's trailing becomes implicit StatementExit ExitKindBreak" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "req fetch() -> integer",
            "agent main() -> integer {",
            "  handle {",
            "    req fetch() { 42 }",
            "  }",
            "  fetch()",
            "}"
          ]
    errs `shouldBe` []
    let allHandleBlocks = findAllHandleBlocks irMod
    case allHandleBlocks of
      [hb] -> case hb.handlers of
        [h] -> case userBlockOf h.handlerBody irMod of
          Just handlerBody -> do
            let exits = [d | StatementExit d <- handlerBody.statements]
            any (\e -> e.exitKind == ExitKindBreak) exits `shouldBe` True
          Nothing -> expectationFailure "handler body block not found"
        _ -> expectationFailure "expected 1 handler"
      _ -> expectationFailure "expected 1 BlockHandle"

  it "where with state var produces BlockHandle with stateInits" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "req inc() -> integer",
            "agent counter() -> integer {",
            "  handle (var n: integer = 0) {",
            "    req inc() {",
            "      next n with { n = n + 1 }",
            "    }",
            "  }",
            "  inc()",
            "}"
          ]
    errs `shouldBe` []
    let allHandleBlocks = findAllHandleBlocks irMod
    case allHandleBlocks of
      [hb] -> do
        length hb.stateInits `shouldBe` 1
        length hb.handlers `shouldBe` 1
      _ -> expectationFailure ("expected 1 BlockHandle, got " <> show (length allHandleBlocks))

  it "next inside handler emits StatementCont with ContKindNext and modifiers" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "req inc() -> integer",
            "agent counter() -> integer {",
            "  handle (var n: integer = 0) {",
            "    req inc() {",
            "      next n with { n = n + 1 }",
            "    }",
            "  }",
            "  inc()",
            "}"
          ]
    errs `shouldBe` []
    -- Find the handler block and check its StatementCont
    let allBlocks = Map.elems irMod.blocks
        userBlocks = [u | BlockUser {body = u} <- allBlocks]
        contStmts = [d | u <- userBlocks, StatementCont d <- u.statements]
    case contStmts of
      (c : _) -> do
        c.contKind `shouldBe` ContKindNext
        length c.modifiers `shouldBe` 1
      _ -> expectationFailure "expected StatementCont in some handler"

-- ===========================================================================
-- Stage 7 — non-local exit semantics
-- ===========================================================================

stage7Spec :: Spec
stage7Spec = describe "Stage 7 \8212 non-local exit semantics" $ do
  it "return inside inline block emits StatementExit ExitKindReturn" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "agent main() -> integer {",
            "  let x = {",
            "    return 1",
            "  }",
            "  2",
            "}"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        allExits = collectAllExits ub irMod
    any (\e -> e.exitKind == ExitKindReturn) allExits `shouldBe` True

  it "break inside handler body emits StatementExit ExitKindBreak" $ do
    -- 'break' is only allowed inside for or req handler bodies; the implicit
    -- handler-body-tail also lowers as ExitKindBreak, so any handler block
    -- exhibits the property.
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "req fetch() -> integer",
            "agent main() -> integer {",
            "  handle {",
            "    req fetch() {",
            "      break 0",
            "    }",
            "  }",
            "  fetch()",
            "}"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        allExits = collectAllExits ub irMod
    any (\e -> e.exitKind == ExitKindBreak) allExits `shouldBe` True

  it "block with then attaches thenBlock" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "req fetch() -> integer",
            "agent main() -> integer {",
            "  handle { req fetch() { 1 } } then(v) { v }",
            "  fetch()",
            "}"
          ]
    errs `shouldBe` []
    let allHandleBlocks = findAllHandleBlocks irMod
    case allHandleBlocks of
      [hb] -> hb.thenBlock `shouldNotBe` Nothing
      _ -> expectationFailure ("expected 1 BlockHandle, got " <> show (length allHandleBlocks))

-- ===========================================================================
-- Stage 8 — edge cases / fail-mode tests
-- ===========================================================================

stage8Spec :: Spec
stage8Spec = describe "Stage 8 \8212 edge cases" $ do
  it "empty agent body produces trailing=Nothing" $ do
    (irMod, errs) <- lowerSource "agent main() {}"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    ub.trailing `shouldBe` Nothing

  it "match where every arm exits has no usable trailing" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "agent main() -> integer {",
            "  match (1) {",
            "    case 1 => {",
            "      return 1",
            "    }",
            "    case _ => {",
            "      return 2",
            "    }",
            "  }",
            "}"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        allExits = collectAllExits ub irMod
    -- Every arm's body should contain a Return exit.
    let returns = filter (\e -> e.exitKind == ExitKindReturn) allExits
    length returns `shouldBe` 2

  it "deeply nested if expressions all wire to BlockMatch" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "agent main() -> integer {",
            "  if (true) {",
            "    if (false) { 1 } else { 2 }",
            "  } else {",
            "    3",
            "  }",
            "}"
          ]
    errs `shouldBe` []
    let matchCount = length (findAllMatchBlocks irMod)
    matchCount `shouldBe` 2 -- outer + nested
  it "shadowing in nested let does not collide var ids" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "agent main() -> integer {",
            "  let x = 1",
            "  let y = { let x = 2; x }",
            "  x + y",
            "}"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        outputVars = catMaybes [c.output | c <- calls ub]
    length outputVars `shouldBe` length (Set.toList (Set.fromList outputVars))

  it "data constructor call targets a BlockCtor" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "data Point(x: integer, y: integer)",
            "agent main() { Point(x = 1, y = 2) }"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        ctorCalls =
          [ c
            | c <- calls ub,
              case c.target of
                CallTargetBlock {block} -> case Map.lookup block irMod.blocks of
                  Just (BlockCtor _) -> True
                  _ -> False
                _ -> False
          ]
    length ctorCalls `shouldBe` 1
    case ctorCalls of
      [c] -> map (.label) c.arguments `shouldMatchList` ["x", "y"]
      _ -> pure ()

  it "nested literal pattern lowers to MatchPatternConstructor with MatchPatternLiteral inner" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "data Some(value: integer)",
            "agent main() {",
            "  let v = Some(value = 0)",
            "  match (v) {",
            "    case Some(value = 0) => { 1 }",
            "    case Some(value = n) => { 2 }",
            "  }",
            "}"
          ]
    errs `shouldBe` []
    let allMatchBlocks = findAllMatchBlocks irMod
    case allMatchBlocks of
      [m] -> case m.arms of
        [arm0, arm1] -> do
          -- First arm: Some(value = 0) — literal nested under ctor
          case arm0.pattern of
            MatchPatternConstructor _ [(label, MatchPatternLiteral (LiteralValueInteger n))] -> do
              label `shouldBe` "value"
              n `shouldBe` 0
            other -> expectationFailure ("expected MatchPatternConstructor with literal inner, got " <> show other)
          -- Second arm: Some(value = n) — variable binding
          case arm1.pattern of
            MatchPatternConstructor _ [(label, MatchPatternVariable _)] -> label `shouldBe` "value"
            other -> expectationFailure ("expected MatchPatternConstructor with variable inner, got " <> show other)
        other -> expectationFailure ("expected 2 arms, got " <> show (length other))
      other -> expectationFailure ("expected 1 BlockMatch, got " <> show (length other))

  it "local agent body can reference outer locals (runtime scope inheritance)" $ do
    (_, errs) <-
      lowerSource $
        Text.unlines
          [ "agent main() {",
            "  let x = 1",
            "  agent inner() -> integer { x }",
            "  inner()",
            "}"
          ]
    -- Previously this produced LoweringErrorUnresolvedVariable for @x@; under
    -- runtime scope inheritance the outer locals stay visible at lower
    -- time and the runtime bridges them at call time.
    errs `shouldBe` []
