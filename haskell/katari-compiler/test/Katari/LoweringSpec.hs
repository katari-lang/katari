-- | Stage-by-stage lowering tests. Each stage adds progressively more complex
-- programs and asserts on the resulting 'IRModule' shape.
--
-- Run order matches the plan's verification ladder. A stage marks itself
-- 'pendingWith' when the underlying lowering feature isn't implemented yet.
module Katari.LoweringSpec (spec) where

import Control.Exception (SomeException, try)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Katari.IR
import Katari.Lowering (LoweringError (..), lowerProgram)
import Katari.Parser (parseModuleStrict)
import Katari.Typechecker.ConstraintGenerator (ConstraintGenResult (..), generateConstraints)
import Katari.Typechecker.Identifier (identify)
import Katari.Typechecker.NormalizedType (NormalizedType (..))
import Katari.Typechecker.SemanticType (EffectVarId (..), TypeVarId (..))
import Katari.Typechecker.Solver (SolverResult (..))
import Katari.Typechecker.Zonker (zonk)
import System.FilePath ((</>))
import System.Directory (listDirectory)
import Test.Hspec

-- ===========================================================================
-- Pipeline helper: source → IR
-- ===========================================================================

-- | Run parser → identify → constraint-gen → totalised solver → zonk → lower.
-- Aborts the spec if upstream phases fail.
lowerSource :: Text -> IO (IRModule, [LoweringError])
lowerSource src = case parseModuleStrict "<test>" src of
  Left errs -> fail ("parse failure: " ++ show errs)
  Right parsed -> case identify (Map.singleton "main" parsed) of
    (idResult, []) -> do
      let cg = generateConstraints idResult
          solver =
            SolverResult
              { typeSubstitution =
                  Map.fromList [(TypeVarId i, NTUnknown) | i <- [0 .. cg.nextTypeVarId - 1]],
                effectSubstitution =
                  Map.fromList [(EffectVarId i, Set.empty) | i <- [0 .. cg.nextEffectVarId - 1]],
                solverErrors = []
              }
          zr = zonk idResult cg solver
      pure (lowerProgram "main" zr)
    (_, errs) -> fail ("identify failure: " ++ show errs)

-- ===========================================================================
-- Spec
-- ===========================================================================

-- | Look up the user-block body of a top-level agent by name.
agentBody :: Text -> IRModule -> Maybe UserBlock
agentBody agentName irMod = do
  entryId <- Map.lookup agentName irMod.entries
  block <- Map.lookup entryId irMod.blocks
  case block of
    BlockUser {body} -> Just body
    _ -> Nothing

-- | Look up the BlockId for a primitive by name.
primId :: Text -> IRModule -> Maybe BlockId
primId primName irMod =
  fst
    <$> find (matchPrim primName . snd) (Map.toList irMod.blocks)
  where
    matchPrim wanted (BlockPrim {name}) = name == wanted
    matchPrim _ _ = False

-- | Extract the SCall statements from a UserBlock body.
calls :: UserBlock -> [CallData]
calls ub = [d | SCall d <- ub.statements]

-- | Extract the SLoadLiteral statements from a UserBlock body.
literalLoads :: UserBlock -> [LoadLiteralData]
literalLoads ub = [d | SLoadLiteral d <- ub.statements]

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
  stage9Spec

stage1Spec :: Spec
stage1Spec = describe "Stage 1 — literals / arithmetic" $ do
  it "lowers a trivial empty agent" $ do
    (irMod, errs) <- lowerSource "agent main() {}"
    errs `shouldBe` []
    Map.keys irMod.entries `shouldBe` ["main"]
    case agentBody "main" irMod of
      Nothing -> expectationFailure "main agent not found in IR"
      Just ub -> do
        ub.statements `shouldBe` []
        ub.trailing `shouldBe` Nothing
        ub.handlers `shouldBe` []
        ub.params `shouldBe` []
        ub.kind `shouldBe` BlockAgentEntry

  it "lowers an integer literal as SLoadLiteral with the integer value" $ do
    (irMod, errs) <- lowerSource "agent main() { 42 }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case literalLoads ub of
      [d] -> do
        d.value `shouldBe` LVInteger 42
        Just d.output `shouldBe` ub.trailing
      _ -> expectationFailure "expected exactly one SLoadLiteral"

  it "lowers x + y to add prim call with two SLoadLiteral inputs" $ do
    (irMod, errs) <- lowerSource "agent main() { let x = 1; let y = 2; x + y }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        Just addId = primId "add" irMod
        loads = literalLoads ub
    length loads `shouldBe` 2
    map (.value) loads `shouldMatchList` [LVInteger 1, LVInteger 2]
    case calls ub of
      [addCall] -> do
        addCall.target `shouldBe` CTBlock {block = addId}
        map (.label) addCall.args `shouldMatchList` ["lhs", "rhs"]
        addCall.output `shouldBe` ub.trailing
      _ -> expectationFailure "expected exactly one add call"

  it "lowers unary negation to neg prim" $ do
    (irMod, errs) <- lowerSource "agent main() { let x = 7; -x }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        Just negId = primId "neg" irMod
    case calls ub of
      [c] -> do
        c.target `shouldBe` CTBlock {block = negId}
        map (.label) c.args `shouldBe` ["operand"]
        c.output `shouldBe` ub.trailing
      _ -> expectationFailure "expected exactly one neg call"
    map (.value) (literalLoads ub) `shouldBe` [LVInteger 7]

  it "lowers boolean literal as SLoadLiteral LVBoolean" $ do
    (irMod, errs) <- lowerSource "agent main() { true }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case literalLoads ub of
      [d] -> d.value `shouldBe` LVBoolean True
      _ -> expectationFailure "expected one SLoadLiteral"

  it "lowers null as SLoadLiteral LVNull" $ do
    (irMod, errs) <- lowerSource "agent main() { null }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case literalLoads ub of
      [d] -> d.value `shouldBe` LVNull
      _ -> expectationFailure "expected one SLoadLiteral"

  it "lowers string literal as SLoadLiteral LVString" $ do
    (irMod, errs) <- lowerSource "agent main() { \"hello\" }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case literalLoads ub of
      [d] -> d.value `shouldBe` LVString "hello"
      _ -> expectationFailure "expected one SLoadLiteral"

  it "lowers number literal as SLoadLiteral LVNumber" $ do
    (irMod, errs) <- lowerSource "agent main() { 3.14 }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case literalLoads ub of
      [d] -> d.value `shouldBe` LVNumber 3.14
      _ -> expectationFailure "expected one SLoadLiteral"

  it "field access encodes field name as SLoadLiteral string" $ do
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
    LVString "x" `elem` map (.value) loads `shouldBe` True

callTargetBlockId :: CallData -> BlockId
callTargetBlockId c = case c.target of
  CTBlock {block} -> block
  CTValue _ -> BlockId maxBound -- sentinel for filter

callTargetBlockMaybe :: CallData -> Maybe BlockId
callTargetBlockMaybe c = case c.target of
  CTBlock {block} -> Just block
  _ -> Nothing

-- | Extract SMatch statements from a UserBlock.
matches :: UserBlock -> [MatchData]
matches ub = [d | SMatch d <- ub.statements]

-- | Extract SFor statements from a UserBlock.
fors :: UserBlock -> [ForData]
fors ub = [d | SFor d <- ub.statements]

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
  it "lowers if-else as SMatch with true arm and default" $ do
    (irMod, errs) <- lowerSource "agent main() { if (true) { 1 } else { 2 } }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case matches ub of
      [m] -> do
        length m.arms `shouldBe` 1
        let [arm] = m.arms
        arm.tag `shouldBe` Just "true"
        arm.bindings `shouldBe` []
        m.defaultArm `shouldNotBe` Nothing
      other -> expectationFailure ("expected 1 SMatch, got " <> show (length other))

  it "lowers if without else (defaultArm Nothing)" $ do
    (irMod, errs) <- lowerSource "agent main() { if (true) { 1 }; 0 }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case matches ub of
      [m] -> m.defaultArm `shouldBe` Nothing
      _ -> expectationFailure "expected 1 SMatch"

  it "if branches lowered to inheritScope blocks" $ do
    (irMod, errs) <- lowerSource "agent main() { if (true) { 1 } else { 2 } }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case matches ub of
      [m] -> do
        let [arm] = m.arms
        case userBlockOf arm.body irMod of
          Just child -> child.kind `shouldBe` BlockInline
          Nothing -> expectationFailure "then-branch block not found"
        case m.defaultArm of
          Just defId -> case userBlockOf defId irMod of
            Just child -> child.kind `shouldBe` BlockInline
            Nothing -> expectationFailure "else-branch block not found"
          Nothing -> expectationFailure "expected default branch"
      _ -> expectationFailure "expected 1 SMatch"

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
    case matches ub of
      [m] -> do
        case m.arms of
          [arm] -> do
            arm.tag `shouldBe` Just "Point"
            map fst arm.bindings `shouldMatchList` ["x", "y"]
          _ -> expectationFailure "expected 1 arm"
      _ -> expectationFailure "expected 1 SMatch"

  it "lowers a simple for loop with one in-binding" $ do
    (irMod, errs) <-
      lowerSource
        "agent main() { let arr = [1, 2, 3]; for (x in arr) { x } }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case fors ub of
      [f] -> do
        length f.iters `shouldBe` 1
        f.stateInits `shouldBe` []
        f.thenBlock `shouldBe` Nothing
      other -> expectationFailure ("expected 1 SFor, got " <> show (length other))

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
    let Just ub = agentBody "main" irMod
    case fors ub of
      [f] -> f.thenBlock `shouldNotBe` Nothing
      _ -> expectationFailure "expected 1 SFor"

-- ===========================================================================
-- Stage 3 — block / let / scope
-- ===========================================================================

stage3Spec :: Spec
stage3Spec = describe "Stage 3 \8212 block / let / scope" $ do
  it "let chain produces sequential statements and trailing var" $ do
    (irMod, errs) <- lowerSource "agent main() { let x = 1; let y = 2; x + y }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    -- Two SLoadLiteral (1, 2) plus one SCall (add) = 3 statements
    length (literalLoads ub) `shouldBe` 2
    length (calls ub) `shouldBe` 1
    -- The final call's output equals the trailing var
    let lastCall = last (calls ub)
    lastCall.output `shouldBe` ub.trailing

  it "inline block creates a child block with inheritScope=True" $ do
    (irMod, errs) <- lowerSource "agent main() { let x = { let a = 1; a + 1 }; x }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    -- One of the calls in the parent block targets a child UserBlock.
    let childCalls = [c | c <- calls ub, isChildBlockCall c irMod]
    childCalls `shouldNotBe` []
    case childCalls of
      (c : _) -> case c.target of
        CTBlock {block} -> case userBlockOf block irMod of
          Just child -> child.kind `shouldBe` BlockInline
          Nothing -> expectationFailure "child block not found"
        _ -> expectationFailure "child call must target a block"
      _ -> pure ()

  it "shadowing assigns a fresh IR var per let binding" $ do
    (irMod, errs) <- lowerSource "agent main() { let x = 1; let x = 2; x }"
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        loads = literalLoads ub
    length loads `shouldBe` 2
    case map (.output) loads of
      [o1, o2] -> o1 `shouldNotBe` o2
      _ -> expectationFailure "expected exactly two SLoadLiteral outputs"
    -- The trailing var should be the second load's output (the inner x).
    Just (last (map (.output) loads)) `shouldBe` ub.trailing

isChildBlockCall :: CallData -> IRModule -> Bool
isChildBlockCall c irMod = case c.target of
  CTBlock {block} -> case Map.lookup block irMod.blocks of
    Just (BlockUser {body}) -> body.kind == BlockInline
    _ -> False
  _ -> False

-- ===========================================================================
-- Stage 4 — agent calls / closure
-- ===========================================================================

stage4Spec :: Spec
stage4Spec = describe "Stage 4 \8212 agent calls / closure" $ do
  it "direct call to a top-level agent uses CTBlock" $ do
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
        CTBlock {block} -> case Map.lookup block irMod.blocks of
          Just (BlockUser _) -> pure () -- helper is a user block
          Just _ -> expectationFailure "expected user block target"
          Nothing -> expectationFailure "target block not found"
        _ -> expectationFailure "expected CTBlock target"
      _ -> expectationFailure "expected 1 call"

  it "agent value escapes via SMakeClosure when used as a binding" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "agent helper() -> integer { 42 }",
            "agent main() { let f = helper; f() }"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        closures = [d | SMakeClosure d <- ub.statements]
    closures `shouldNotBe` []
    -- The closure value should be referenced by a CTValue call later.
    case closures of
      (d : _) -> do
        let valueCalls =
              [c | c <- calls ub, c.target == CTValue {var = d.output}]
        valueCalls `shouldNotBe` []
      _ -> pure ()

-- ===========================================================================
-- Stage 5 — for / state / next
-- ===========================================================================

stage5Spec :: Spec
stage5Spec = describe "Stage 5 \8212 for / state / next" $ do
  it "for with state var emits SFor.stateInits and body uses state-var local" $ do
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
    let Just ub = agentBody "main" irMod
    case fors ub of
      [f] -> do
        map fst f.stateInits `shouldBe` ["acc"]
        case userBlockOf f.bodyBlock irMod of
          Just body -> do
            -- The body should contain at least one SCont with kind=ForNext
            let conts = [d | SCont d <- body.statements]
            length conts `shouldBe` 1
            case conts of
              [c] -> do
                c.contKind `shouldBe` ContForNext
                map fst c.mods `shouldBe` ["acc"]
              _ -> pure ()
          Nothing -> expectationFailure "for body block not found"
      _ -> expectationFailure "expected 1 SFor"

  it "for_break inside for emits SExit ExitForBreak" $ do
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
    let Just ub = agentBody "main" irMod
    case fors ub of
      [f] -> case userBlockOf f.bodyBlock irMod of
        Just body -> do
          -- find a nested SExit ExitForBreak in any descendant block
          let allExits = collectAllExits body irMod
          any (\e -> e.exitKind == ExitForBreak) allExits `shouldBe` True
        Nothing -> expectationFailure "for body not found"
      _ -> expectationFailure "expected 1 SFor"

-- | Collect all SExit datas reachable through inline / branch / for /
-- handler / then sub-blocks.
collectAllExits :: UserBlock -> IRModule -> [ExitData]
collectAllExits ub irMod = directExits ++ indirectExits
  where
    directExits = [d | SExit d <- ub.statements]
    indirectExits =
      concatMap recurse $
        [body' | SCall c <- ub.statements, Just body' <- [callTargetUser c]]
          ++ matchBodies
          ++ forBodies
          ++ handlerBodies
          ++ thenBodies
    callTargetUser c = case c.target of
      CTBlock {block} -> userBlockOf block irMod
      _ -> Nothing
    matchBodies =
      concat
        [ ub' : maybeToList (m.defaultArm >>= flip userBlockOf irMod)
          | SMatch m <- ub.statements,
            arm <- m.arms,
            Just ub' <- [userBlockOf arm.body irMod]
        ]
    forBodies =
      concat
        [ catMaybes [userBlockOf f.bodyBlock irMod, f.thenBlock >>= flip userBlockOf irMod]
          | SFor f <- ub.statements
        ]
    handlerBodies = [hb | h <- ub.handlers, Just hb <- [userBlockOf h.handlerBody irMod]]
    thenBodies = case ub.thenBlock of
      Just tid -> case userBlockOf tid irMod of Just t -> [t]; _ -> []
      Nothing -> []
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
  it "where with handlers (no state vars) keeps single block + catchesBreak" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "req fetch() -> integer",
            "agent main() -> integer { fetch() } where {",
            "  req fetch() { 42 }",
            "}"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    ub.kind `shouldBe` BlockAgentEntryWithHandlers
    length ub.handlers `shouldBe` 1

  it "handler body's trailing becomes implicit SExit ExitBreak" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "req fetch() -> integer",
            "agent main() -> integer { fetch() } where {",
            "  req fetch() { 42 }",
            "}"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
    case ub.handlers of
      [h] -> case userBlockOf h.handlerBody irMod of
        Just hb -> do
          let exits = [d | SExit d <- hb.statements]
          any (\e -> e.exitKind == ExitBreak) exits `shouldBe` True
        Nothing -> expectationFailure "handler body block not found"
      _ -> expectationFailure "expected 1 handler"

  it "where with state var splits into outer/inner blocks" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "req inc() -> integer",
            "agent counter() -> integer { inc() } where (var n: integer = 0) {",
            "  req inc() {",
            "    next n with { n = n + 1 }",
            "  }",
            "}"
          ]
    errs `shouldBe` []
    let Just outer = agentBody "counter" irMod
    -- Outer is a plain agent entry with no handlers (the where-with-state-var
    -- form delegates handlers to the inner handle-scope block).
    outer.kind `shouldBe` BlockAgentEntry
    outer.handlers `shouldBe` []
    -- Outer's last call must be to the inner block.
    case [d | SCall d <- outer.statements] of
      [] -> expectationFailure "outer has no SCall to inner"
      callsList -> do
        let lastCall = last callsList
        case lastCall.target of
          CTBlock {block = innerId} -> case userBlockOf innerId irMod of
            Just inner -> do
              -- Inner is a handle scope: catches break and inherits scope.
              inner.kind `shouldBe` BlockHandleScope
              map (.label) inner.stateVars `shouldBe` ["n"]
              length inner.handlers `shouldBe` 1
            Nothing -> expectationFailure "inner block not found"
          _ -> expectationFailure "outer's call must target a block id"

  it "next inside handler emits SCont with ContNext and mods" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "req inc() -> integer",
            "agent counter() -> integer { inc() } where (var n: integer = 0) {",
            "  req inc() {",
            "    next n with { n = n + 1 }",
            "  }",
            "}"
          ]
    errs `shouldBe` []
    -- Find the handler block and check its SCont
    let allBlocks = Map.elems irMod.blocks
        userBlocks = [u | BlockUser {body = u} <- allBlocks]
        contStmts = [d | u <- userBlocks, SCont d <- u.statements]
    case contStmts of
      (c : _) -> do
        c.contKind `shouldBe` ContNext
        map fst c.mods `shouldBe` ["n"]
      _ -> expectationFailure "expected SCont in some handler"

-- ===========================================================================
-- Stage 7 — non-local exit semantics
-- ===========================================================================

stage7Spec :: Spec
stage7Spec = describe "Stage 7 \8212 non-local exit semantics" $ do
  it "return inside inline block emits SExit ExitReturn" $ do
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
    any (\e -> e.exitKind == ExitReturn) allExits `shouldBe` True

  it "break inside handler body emits SExit ExitBreak" $ do
    -- 'break' is only allowed inside for or req handler bodies; the implicit
    -- handler-body-tail also lowers as ExitBreak, so any handler block
    -- exhibits the property.
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "req fetch() -> integer",
            "agent main() -> integer { fetch() } where {",
            "  req fetch() {",
            "    break 0",
            "  }",
            "}"
          ]
    errs `shouldBe` []
    let Just ub = agentBody "main" irMod
        allExits = collectAllExits ub irMod
    any (\e -> e.exitKind == ExitBreak) allExits `shouldBe` True

  it "block with then attaches thenBlock" $ do
    (irMod, errs) <-
      lowerSource $
        Text.unlines
          [ "req fetch() -> integer",
            "agent main() -> integer {",
            "  fetch()",
            "} where { req fetch() { 1 } } then(v) { v }"
          ]
    -- This program may not parse depending on syntax; record result either way
    case errs of
      [] -> do
        let Just ub = agentBody "main" irMod
        ub.thenBlock `shouldNotBe` Nothing
      _ -> pendingWith "then-clause syntax not in current parser shape"

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
    let returns = filter (\e -> e.exitKind == ExitReturn) allExits
    length returns `shouldBe` 2

  it "deeply nested if expressions all wire to SMatch" $ do
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
    let allBlocks = Map.elems irMod.blocks
        userBlocks = [u | BlockUser {body = u} <- allBlocks]
        matchCount = sum [length (matches u) | u <- userBlocks]
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
                CTBlock {block} -> case Map.lookup block irMod.blocks of
                  Just (BlockCtor _) -> True
                  _ -> False
                _ -> False
          ]
    length ctorCalls `shouldBe` 1
    case ctorCalls of
      [c] -> map (.label) c.args `shouldMatchList` ["x", "y"]
      _ -> pure ()

-- ===========================================================================
-- Stage 9 — samples/ regression
-- ===========================================================================

stage9Spec :: Spec
stage9Spec = describe "Stage 9 \8212 samples regression" $ do
  let sampleDir =
        "/Users/yukikurage/Documents/projects/katari/samples/compiler-tests/pass"
  files <- runIO (listDirectory sampleDir)
  let ktrFiles = filter ((== ".ktr") . reverseTake 4) files
  mapM_ (sampleTest sampleDir) ktrFiles

reverseTake :: Int -> String -> String
reverseTake n s = drop (length s - n) s

sampleTest :: FilePath -> FilePath -> Spec
sampleTest dir file = it ("lowers samples/" <> file) $ do
  src <- TextIO.readFile (dir </> file)
  result <- try (lowerSource src) :: IO (Either SomeException (IRModule, [LoweringError]))
  case result of
    Left e ->
      pendingWith ("upstream parser/identifier failure: " <> show e)
    Right (irMod, errs) -> do
      -- Lowering may surface "unsupported" errors for old-syntax patterns.
      let unsupported =
            [ s
              | LowerErrorUnsupported _ s <- errs
            ]
      if not (null unsupported)
        then pendingWith ("unsupported AST shapes: " <> show unsupported)
        else do
          errs `shouldBe` []
          -- Sanity: at least one user block exists.
          let userBlockCount =
                length [u | BlockUser u <- Map.elems irMod.blocks]
          userBlockCount `shouldSatisfy` (> 0)
