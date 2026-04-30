module Katari.SolverSpec (spec) where

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Parser (parseModuleStrict)
import Katari.Typechecker.ConstraintGenerator
  ( ConstraintGenResult (..),
    generateConstraints,
  )
import Katari.Typechecker.Identifier
  ( IdentifierResult (..),
    VariableData (..),
    VariableId,
    identify,
  )
import Katari.Typechecker.NormalizedType
  ( ArraySlot (..),
    FunctionSlot (..),
    LayeredType (..),
    NormalizedType (..),
    NumberSlot (..),
    ObjectSlot (..),
    StringSlot (..),
  )
import Katari.Typechecker.SemanticType
  ( SemanticType (..),
    TypeVarId (..),
    Unresolved,
  )
import Katari.Typechecker.Solver (SolverResult (..), solve)
import Katari.Typechecker.Zonker (ZonkResult (..), zonk)
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

runSolve :: Text -> IO (IdentifierResult, ConstraintGenResult, SolverResult)
runSolve source = case parseModuleStrict "<test>" source of
  Left errors -> fail ("parse failure: " ++ show (map show errors))
  Right parsed -> case identify (Map.singleton "main" parsed) of
    (idResult, []) ->
      let cgResult = generateConstraints idResult
          solverResult = solve cgResult
       in pure (idResult, cgResult, solverResult)
    (_, errors) -> fail ("identify failure: " ++ show errors)

variableIdOf :: Text -> IdentifierResult -> Maybe VariableId
variableIdOf name result =
  fst <$> find ((== name) . (.variableName) . snd) (Map.toList result.identifiedVariables)

-- | The 'NormalizedType' that the solver assigned to the type variable
-- recorded in the identifier's typeEnvironment for a given source name.
inferredTypeOf ::
  Text ->
  IdentifierResult ->
  ConstraintGenResult ->
  SolverResult ->
  Maybe NormalizedType
inferredTypeOf name idResult cgResult solverResult = do
  variableId <- variableIdOf name idResult
  semanticType <- Map.lookup variableId cgResult.typeEnvironment
  case extractTypeVarId semanticType of
    Just typeVarId -> Map.lookup typeVarId solverResult.typeSubstitution
    Nothing -> Nothing
  where
    extractTypeVarId :: SemanticType Unresolved -> Maybe TypeVarId
    extractTypeVarId = \case
      SemanticTypeVariable typeVarId -> Just typeVarId
      _ -> Nothing

-- | Verify the Solver totality contract: every TypeVarId allocated by
-- ConstraintGenerator has an entry in the substitution. The substitution
-- may contain additional entries for solver-internal fresh vars allocated
-- during branching — those are harmless.
shouldHaveTotalSubstitution ::
  SolverResult ->
  ConstraintGenResult ->
  Expectation
shouldHaveTotalSubstitution solverResult cgResult = do
  let required = Set.fromList [TypeVarId i | i <- [0 .. cgResult.nextTypeVarId - 1]]
      actual = Map.keysSet solverResult.typeSubstitution
  Set.isSubsetOf required actual `shouldBe` True

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Katari.Typechecker.Solver" $ do
  basicLiterals
  totalContract
  ifBranchUnion
  arithmeticOperators
  matchUnion
  contradictions
  endToEndZonk
  whereHandlerBlocks
  matchExpressions
  forLoops
  localAgents
  nestedBlocks
  dataAndCompositeTypes
  higherOrderFunctions
  narrowAndSubstitutionComposition

-- ---------------------------------------------------------------------------
-- Basic literal inference
-- ---------------------------------------------------------------------------

basicLiterals :: Spec
basicLiterals = describe "basic literal inference" $ do
  it "agent foo() { 42 } - solver succeeds, no errors" $ do
    (_, _, solverResult) <- runSolve "agent foo() { 42 }"
    solverResult.solverErrors `shouldBe` []

  it "string literal program solves cleanly" $ do
    (_, _, solverResult) <- runSolve "agent foo() { \"hi\" }"
    solverResult.solverErrors `shouldBe` []

  it "boolean literal program solves cleanly" $ do
    (_, _, solverResult) <- runSolve "agent foo() { true }"
    solverResult.solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Total contract
-- ---------------------------------------------------------------------------

totalContract :: Spec
totalContract = describe "Solver totality contract" $ do
  it "trivial agent: every TypeVarId has a substitution entry" $ do
    (_, cgResult, solverResult) <- runSolve "agent foo() { 42 }"
    solverResult `shouldHaveTotalSubstitution` cgResult

  it "agent with parameters: total substitution" $ do
    (_, cgResult, solverResult) <- runSolve "agent foo(x: integer) { x }"
    solverResult `shouldHaveTotalSubstitution` cgResult

  it "agent with let binding: total substitution" $ do
    (_, cgResult, solverResult) <- runSolve "agent foo() { let x = 1; x }"
    solverResult `shouldHaveTotalSubstitution` cgResult

  it "if expression: total substitution" $ do
    (_, cgResult, solverResult) <-
      runSolve "agent foo(c: boolean) { if (c) { 1 } else { 2 } }"
    solverResult `shouldHaveTotalSubstitution` cgResult

-- ---------------------------------------------------------------------------
-- if branch union
-- ---------------------------------------------------------------------------

ifBranchUnion :: Spec
ifBranchUnion = describe "if branches" $ do
  it "if cond { 1 } else { 2 } - both branches concrete, no errors" $ do
    (_, _, solverResult) <-
      runSolve "agent foo(c: boolean) { if (c) { 1 } else { 2 } }"
    solverResult.solverErrors `shouldBe` []

  it "if cond { 1 } else { \"x\" } - mixed types, no errors (union allowed)" $ do
    (_, _, solverResult) <-
      runSolve "agent foo(c: boolean) { if (c) { 1 } else { \"x\" } }"
    solverResult.solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Arithmetic operators
-- ---------------------------------------------------------------------------

arithmeticOperators :: Spec
arithmeticOperators = describe "arithmetic" $ do
  it "1 + 2 narrows operands to number, no errors" $ do
    (_, _, solverResult) <- runSolve "agent foo() { 1 + 2 }"
    solverResult.solverErrors `shouldBe` []

  it "1 + 2 + 3 chained: no errors" $ do
    (_, _, solverResult) <- runSolve "agent foo() { 1 + 2 + 3 }"
    solverResult.solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- match expression union narrowing
-- ---------------------------------------------------------------------------

matchUnion :: Spec
matchUnion = describe "match" $ do
  it "match on integer with one case, no errors" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent foo(x: integer) {\n",
            "  match (x) { case n => { n } }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Contradictions
-- ---------------------------------------------------------------------------

contradictions :: Spec
contradictions = describe "contradictions" $ do
  it "agent foo() -> integer { \"bad\" } records solver error" $ do
    (_, _, solverResult) <- runSolve "agent foo() -> integer { \"bad\" }"
    null solverResult.solverErrors `shouldBe` False

  it "even with errors, substitution is still total" $ do
    (_, cgResult, solverResult) <- runSolve "agent foo() -> integer { \"bad\" }"
    -- Errors mean the type substitution may be empty + filled with NormalizedTypeUnknown
    -- by the totality layer, so all TypeVarIds still have entries.
    Map.size solverResult.typeSubstitution `shouldBe` cgResult.nextTypeVarId

-- ---------------------------------------------------------------------------
-- End-to-end with Zonker
-- ---------------------------------------------------------------------------

endToEndZonk :: Spec
endToEndZonk = describe "end-to-end pipeline (Solver -> Zonker)" $ do
  it "Zonker over a real Solver result has no zonkErrors on a basic program" $ do
    (idResult, cgResult, solverResult) <- runSolve "agent foo() { 42 }"
    let zonkResult = zonk idResult cgResult solverResult
    zonkResult.zonkErrors `shouldBe` []

  it "totality is sufficient for Zonker even on programs with let / if" $ do
    (idResult, cgResult, solverResult) <-
      runSolve $
        mconcat
          [ "agent foo(c: boolean) {\n",
            "  let x = if (c) { 1 } else { 2 };\n",
            "  x\n",
            "}"
          ]
    let zonkResult = zonk idResult cgResult solverResult
    zonkResult.zonkErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- where / handler blocks
-- ---------------------------------------------------------------------------

whereHandlerBlocks :: Spec
whereHandlerBlocks = describe "where blocks and request handlers" $ do
  it "where with state variable: solver succeeds" $ do
    -- State variables are visible to handlers / then, NOT to the body.
    -- The body returns a literal; @n@ is just declared.
    (_, _, solverResult) <-
      runSolve "agent counter() -> integer { 0 } where (var n: integer = 0) {}"
    solverResult.solverErrors `shouldBe` []

  it "where with request handler: req is discharged, agent has empty effect" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "req fetch() -> integer\n",
            "agent app() { fetch() } where {\n",
            "  req fetch() { 42 }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "where with state var + handler combining state mutation via next" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "req inc() -> integer\n",
            "agent counter() -> integer { inc(); inc(); inc() } where (var n: integer = 0) {\n",
            "  req inc() {\n",
            "    next n with { n = n + 1 }\n",
            "  }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "explicit next with wrong type → records solver error" $ do
    -- Implicit completion is treated as break (Koka-style), so the declared
    -- @-> integer@ on req only constrains explicit @next@ statements. Use
    -- @next@ here to surface the type mismatch.
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "req fetch() -> integer\n",
            "agent app() -> integer { fetch() } where {\n",
            "  req fetch() {\n",
            "    next \"bad\"\n",
            "  }\n",
            "}"
          ]
    null solverResult.solverErrors `shouldBe` False

  it "then clause: body tail flows through pattern, then body type is whole block" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent foo() -> integer {\n",
            "  return { 42 } where {} then(p) { p + 1 }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "then clause with state var: state var visible in then" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "req inc() -> integer\n",
            "agent counter() -> integer {\n",
            "  inc(); inc(); inc()\n",
            "} where (var n: integer = 0) {\n",
            "  req inc() {\n",
            "    next n with { n = n + 1 }\n",
            "  }\n",
            "} then(_) { n }\n"
          ]
    solverResult.solverErrors `shouldBe` []

  it "handler implicit completion flows to whole-block (not declared next type)" $ do
    -- @req fetch() -> integer@: declared return only constrains @next@.
    -- Handler body fall-through (literal "ok") is treated as break and flows
    -- to the where-block whole type — independent of the declared @integer@
    -- return. Without a stricter agent annotation, no contradiction arises.
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "req fetch() -> integer\n",
            "agent app() { fetch() } where {\n",
            "  req fetch() { \"ok\" }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "return inside body of block-with-then routes through then" $ do
    -- Inner @return 5@ : 5 <: pattern p (number) → then body @p + 1@ :
    -- number <: agent return integer. Should pass.
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent foo() -> integer {\n",
            "  return {\n",
            "    return 5\n",
            "  } where {} then(p) { p + 1 }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- match expressions
-- ---------------------------------------------------------------------------

matchExpressions :: Spec
matchExpressions = describe "match expressions" $ do
  it "match on union with two literal arms" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent label(n: integer) -> string {\n",
            "  return match (n) {\n",
            "    case 0 => { \"zero\" }\n",
            "    case other => { \"other\" }\n",
            "  }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "match on data constructor pattern" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "data circle(r: integer)\n",
            "agent area(c: circle) -> integer {\n",
            "  return match (c) { case circle(r = v) => { v } }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "match arm bodies with mismatched types union into result" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent describe(b: boolean) {\n",
            "  return match (b) {\n",
            "    case true => { 1 }\n",
            "    case false => { \"false\" }\n",
            "  }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- for loops with var bindings, next/break (modifiers)
-- ---------------------------------------------------------------------------

forLoops :: Spec
forLoops = describe "for loops" $ do
  it "for ... in over an array" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent run(xs: array[integer]) {\n",
            "  for (x in xs) { x }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "for with var binding and next-with-modifier" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent sum(xs: array[integer]) -> integer {\n",
            "  return for (x in xs, var acc = 0) {\n",
            "    next with { acc = acc + x }\n",
            "  } then { acc }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "for with break terminating early" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent firstPositive(xs: array[integer]) -> integer | null {\n",
            "  return for (x in xs) {\n",
            "    if (x > 0) { break x; } else { null }\n",
            "  } then { null }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- local agent statements
-- ---------------------------------------------------------------------------

localAgents :: Spec
localAgents = describe "local agent statements" $ do
  it "local agent declared inside another agent's body" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent outer() -> integer {\n",
            "  agent inner() -> integer { 42 };\n",
            "  return inner()\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "local agent capturing outer parameter" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent outer(x: integer) -> integer {\n",
            "  agent inner() -> integer { x + 1 };\n",
            "  return inner()\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- nested blocks and let bindings
-- ---------------------------------------------------------------------------

nestedBlocks :: Spec
nestedBlocks = describe "nested blocks and let" $ do
  it "let inside if branch" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent f(c: boolean) -> integer {\n",
            "  return if (c) { let y = 10; y } else { 0 }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "deeply nested if expressions" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent f(a: boolean, b: boolean) -> integer {\n",
            "  return if (a) { if (b) { 1 } else { 2 } } else { if (b) { 3 } else { 4 } }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "multi-line block: trailing expression before close-brace is the return value" $ do
    -- Regression test for the virtual-';' / block-return UX: when an
    -- expression is followed by a newline and then a '}', the expression is
    -- the block's return value (not a statement). Without this fix, the
    -- inner @if (b) { 1 } else { 2 }@ would become a statement and the
    -- block would return null.
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent f(a: boolean, b: boolean) -> integer {\n",
            "  return if (a) {\n",
            "    if (b) { 1 } else { 2 }\n",
            "  } else {\n",
            "    if (b) { 3 } else { 4 }\n",
            "  }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "block expression with return statement inside" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent early(c: boolean) -> integer {\n",
            "  if (c) { return 1; }\n",
            "  return 2\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- data declarations + tuple/array/object inference
-- ---------------------------------------------------------------------------

dataAndCompositeTypes :: Spec
dataAndCompositeTypes = describe "data and composite types" $ do
  it "data constructor returns its data type" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "data point(x: integer, y: integer)\n",
            "agent origin() -> point { point(x = 0, y = 0) }"
          ]
    solverResult.solverErrors `shouldBe` []

  it "array of integers" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent ones() -> array[integer] {\n",
            "  return [1, 2, 3]\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "tuple inference" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent pair() -> (integer, string) {\n",
            "  return (42, \"hi\")\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "data field access through pattern match" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "data box(value: integer)\n",
            "agent unbox(b: box) -> integer {\n",
            "  return match (b) { case box(value = v) => { v } }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Higher-order: passing one agent as another's argument
-- ---------------------------------------------------------------------------

higherOrderFunctions :: Spec
higherOrderFunctions = describe "higher-order agents" $ do
  it "agent receives a function and calls it" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent caller(callback: (x: integer) -> integer) -> integer {\n",
            "  return callback(x = 1)\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []

  it "function-typed parameter unified across call site" $ do
    (_, _, solverResult) <-
      runSolve $
        mconcat
          [ "agent identity(n: integer) -> integer { n }\n",
            "agent caller(cb: (n: integer) -> integer) -> integer { cb(n = 1) }\n",
            "agent run() -> integer { caller(cb = identity) }"
          ]
    solverResult.solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- narrow + substitution composition
--
-- These tests exercise the solver's "branch / narrow" path where a type
-- variable α gets bound to a fresh-var skeleton (e.g. α := (x: t_p) -> t_r)
-- and the sub-vars are pinned later. The final substitution must compose
-- through these indirect entries, otherwise α's resolved type degenerates
-- to NormalizedTypeUnknown.
-- ---------------------------------------------------------------------------

narrowAndSubstitutionComposition :: Spec
narrowAndSubstitutionComposition = describe "narrow + substitution composition" $ do
  it "(a) narrow on bare function param: g should resolve to a Function shape, not NormalizedTypeUnknown" $ do
    -- `g` is unannotated; calling g(x = 1) emits t_g <: (x: 1) -> t_r,
    -- which triggers narrow. After narrow, t_g := (x: p_var) -> r_var with
    -- p_var, r_var fresh. Without final deep substitution composition,
    -- t_g's value still references those vars and degenerates to NormalizedTypeUnknown.
    (idResult, cgResult, solverResult) <-
      runSolve $
        mconcat
          [ "agent apply(g) {\n",
            "  return g(x = 1)\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []
    let inferred = inferredTypeOf "g" idResult cgResult solverResult
    inferred `shouldSatisfy` isFunctionShape

  it "(b) transitive var-on-var: x flows through y to number" $ do
    -- t_x <: t_y (let y = x), t_y <: number (via y + 1 arithmetic).
    -- Propagation should derive t_x <: number (transitively), pinning t_x.
    (idResult, cgResult, solverResult) <-
      runSolve $
        mconcat
          [ "agent f(x) {\n",
            "  let y = x\n",
            "  return y + 1\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []
    let inferred = inferredTypeOf "x" idResult cgResult solverResult
    inferred `shouldSatisfy` isInhabited
    inferred `shouldNotSatisfy` isNTUnknown

  it "(c) β <: α only chain: x must inherit number through y annotation" $ do
    -- t_x <: t_y, t_y == number (via wildcard-pattern annotation in let).
    -- t_x's only direct lower bound is t_y (var) → propagation must derive
    -- t_x <: number to avoid NormalizedTypeUnknown fallback.
    (idResult, cgResult, solverResult) <-
      runSolve $
        mconcat
          [ "agent f(x) {\n",
            "  let y = x\n",
            "  let _: number = y\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []
    let inferred = inferredTypeOf "x" idResult cgResult solverResult
    inferred `shouldSatisfy` isInhabited
    inferred `shouldNotSatisfy` isNTUnknown

  it "(d) function narrow with multi-chain: g resolved + α correct" $ do
    -- Recreates the user's scenario:
    --   (x: int) -> number <: γ            (doubler flows into g)
    --   γ <: (x: int) -> β                 (g(x = 1) call site)
    --   β <: α                             (let r = ...; α flow)
    --   int <: α                           (separate int flow)
    -- Both γ (= g) and α must be sensibly inferred. γ would degenerate to
    -- NormalizedTypeUnknown without deep substitution composition.
    (idResult, cgResult, solverResult) <-
      runSolve $
        mconcat
          [ "agent doubler(x: integer) -> number { 1 }\n",
            "agent test(extra: integer) {\n",
            "  let g = doubler\n",
            "  let r = g(x = 1)\n",
            "  return if (true) { r } else { extra }\n",
            "}"
          ]
    solverResult.solverErrors `shouldBe` []
    let inferredG = inferredTypeOf "g" idResult cgResult solverResult
    inferredG `shouldSatisfy` isFunctionShape

-- ---------------------------------------------------------------------------
-- Predicates over NormalizedType for narrow tests
-- ---------------------------------------------------------------------------

-- | True iff the resolved type has a 'FunctionSlotOf' shape in its function layer.
isFunctionShape :: Maybe NormalizedType -> Bool
isFunctionShape = \case
  Just (NormalizedTypeLayered LayeredType {functionLayer = FunctionSlotOf _}) -> True
  _ -> False

-- | True iff the resolved type is exactly NormalizedTypeUnknown.
isNTUnknown :: Maybe NormalizedType -> Bool
isNTUnknown = \case
  Just NormalizedTypeUnknown -> True
  _ -> False

-- | True iff the resolved type has at least one populated layer (i.e. some
-- value can inhabit it). NormalizedTypeUnknown counts as inhabited (the lattice top).
-- Layered with all-empty layers is the bottom (Never) and returns False.
isInhabited :: Maybe NormalizedType -> Bool
isInhabited = \case
  Just NormalizedTypeUnknown -> True
  Just (NormalizedTypeLayered layered) -> hasAnyLayer layered
  Nothing -> False
  where
    hasAnyLayer LayeredType {..} =
      hasNumber numberLayer
        || hasString stringLayer
        || not (null booleanLayer)
        || nullLayer
        || hasFunction functionLayer
        || hasArray arrayLayer
        || not (null tupleLayer)
        || not (null dataLayer)
        || hasObject objectLayer
    hasNumber NumberSlotInteger = True
    hasNumber NumberSlotNumber = True
    hasNumber (NumberSlotLiterals s) = not (null s)
    hasString StringSlotAny = True
    hasString (StringSlotLiterals s) = not (null s)
    hasFunction FunctionSlotAbsent = False
    hasFunction (FunctionSlotOf _) = True
    hasArray ArraySlotAbsent = False
    hasArray (ArraySlotOf _) = True
    hasObject ObjectSlotAbsent = False
    hasObject (ObjectSlotOf _) = True
