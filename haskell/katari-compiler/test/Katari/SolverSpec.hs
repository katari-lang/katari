module Katari.SolverSpec (spec) where

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Compile qualified as Compile
import Katari.Id (VariableResolution (..))
import Katari.Lexer qualified as Lexer
import Katari.Parser qualified as Parser
import Katari.SemanticType
  ( SemanticType (..),
    TypeVariableId (..),
    Unresolved,
  )
import Katari.Typechecker.ConstraintGenerator
  ( ConstraintGenResult (..),
    VariableSupply (..),
  )
import Katari.Typechecker.Identifier
  ( IdentifierResult (..),
    SymbolEntry (..),
    VariableData (..),
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
import Katari.Typechecker.ScopeIndex (ScopeFrame (..), ScopeIndex (..))
import Katari.Typechecker.Solver (SolverResult (..), solve)
import Katari.Typechecker.Solver qualified as Solver
import Katari.Typechecker.Zonker (zonk)
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

runSolve :: Text -> IO (IdentifierResult, ConstraintGenResult, SolverResult, [Solver.SolverError])
runSolve source =
  let (stream, _) = Lexer.lex "<test>" source
      (parsed, parseErrors) = Parser.parse "<test>" stream
   in case parseErrors of
        (_ : _) -> fail ("parse failure: " ++ show parseErrors)
        [] -> case Compile.identifyWithStdlib (Map.singleton "main" parsed) of
          (idResult, []) ->
            let (cgResult, _) = Compile.generateConstraintsAll idResult
                (solverResult, solverErrors) = solve cgResult
             in pure (idResult, cgResult, solverResult, solverErrors)
          (_, errors) -> fail ("identify failure: " ++ show errors)

-- | Find the VariableResolution for a named binding. Searches top-level
-- identifiedVariables first, then falls back to scanning the scopeIndex
-- for local variables (parameters, let bindings, match arm bindings).
variableResolutionOf :: Text -> IdentifierResult -> Maybe VariableResolution
variableResolutionOf name result =
  case ResolvedTopLevel . fst <$> find ((== name) . (.variableName) . snd) (Map.toList result.identifiedVariables) of
    Just resolution -> Just resolution
    Nothing ->
      let allFrames = concatMap snd (Map.toList result.scopeIndex.framesByFile)
          candidates = mapMaybe (\frame -> Map.lookup name frame.frameSymbols >>= (.variableSymbol)) allFrames
       in case candidates of
            (resolution : _) -> Just resolution
            [] -> Nothing

-- | The 'NormalizedType' that the solver assigned to the type variable
-- recorded in the identifier's typeEnvironment for a given source name.
inferredTypeOf ::
  Text ->
  IdentifierResult ->
  ConstraintGenResult ->
  SolverResult ->
  Maybe NormalizedType
inferredTypeOf name idResult cgResult solverResult = do
  variableResolution <- variableResolutionOf name idResult
  semanticType <- Map.lookup variableResolution cgResult.typeEnvironment
  case extractTypeVariableId semanticType of
    Just typeVarId -> Map.lookup typeVarId solverResult.typeSubstitution
    Nothing -> Nothing
  where
    extractTypeVariableId :: SemanticType Unresolved -> Maybe TypeVariableId
    extractTypeVariableId = \case
      SemanticTypeVariable typeVarId -> Just typeVarId
      _ -> Nothing

-- | Verify the Solver totality contract: every TypeVariableId allocated by
-- ConstraintGenerator has an entry in the substitution. The substitution
-- may contain additional entries for solver-internal fresh vars allocated
-- during branching — those are harmless.
shouldHaveTotalSubstitution ::
  SolverResult ->
  ConstraintGenResult ->
  Expectation
shouldHaveTotalSubstitution solverResult cgResult = do
  let required = Set.fromList [TypeVariableId i | i <- [0 .. cgResult.variableSupply.typeVarSupply - 1]]
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
  illTypedRejection
  unionReturnBoundAggregation

-- ---------------------------------------------------------------------------
-- Basic literal inference
-- ---------------------------------------------------------------------------

basicLiterals :: Spec
basicLiterals = describe "basic literal inference" $ do
  it "agent foo() { 42 } - solver succeeds, no errors" $ do
    (_, _, solverResult, solverErrors) <- runSolve "agent foo() { 42 }"
    solverErrors `shouldBe` []

  it "string literal program solves cleanly" $ do
    (_, _, solverResult, solverErrors) <- runSolve "agent foo() { \"hi\" }"
    solverErrors `shouldBe` []

  it "boolean literal program solves cleanly" $ do
    (_, _, solverResult, solverErrors) <- runSolve "agent foo() { true }"
    solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Total contract
-- ---------------------------------------------------------------------------

totalContract :: Spec
totalContract = describe "Solver totality contract" $ do
  it "trivial agent: every TypeVariableId has a substitution entry" $ do
    (_, cgResult, solverResult, solverErrors) <- runSolve "agent foo() { 42 }"
    solverResult `shouldHaveTotalSubstitution` cgResult

  it "agent with parameters: total substitution" $ do
    (_, cgResult, solverResult, solverErrors) <- runSolve "agent foo(x: integer) { x }"
    solverResult `shouldHaveTotalSubstitution` cgResult

  it "agent with let binding: total substitution" $ do
    (_, cgResult, solverResult, solverErrors) <- runSolve "agent foo() { let x = 1; x }"
    solverResult `shouldHaveTotalSubstitution` cgResult

  it "if expression: total substitution" $ do
    (_, cgResult, solverResult, solverErrors) <-
      runSolve "agent foo(c: boolean) { if (c) { 1 } else { 2 } }"
    solverResult `shouldHaveTotalSubstitution` cgResult

-- ---------------------------------------------------------------------------
-- if branch union
-- ---------------------------------------------------------------------------

ifBranchUnion :: Spec
ifBranchUnion = describe "if branches" $ do
  it "if cond { 1 } else { 2 } - both branches concrete, no errors" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve "agent foo(c: boolean) { if (c) { 1 } else { 2 } }"
    solverErrors `shouldBe` []

  it "if cond { 1 } else { \"x\" } - mixed types, no errors (union allowed)" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve "agent foo(c: boolean) { if (c) { 1 } else { \"x\" } }"
    solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Arithmetic operators
-- ---------------------------------------------------------------------------

arithmeticOperators :: Spec
arithmeticOperators = describe "arithmetic" $ do
  it "1 + 2 narrows operands to number, no errors" $ do
    (_, _, solverResult, solverErrors) <- runSolve "agent foo() { 1 + 2 }"
    solverErrors `shouldBe` []

  it "1 + 2 + 3 chained: no errors" $ do
    (_, _, solverResult, solverErrors) <- runSolve "agent foo() { 1 + 2 + 3 }"
    solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- match expression union narrowing
-- ---------------------------------------------------------------------------

matchUnion :: Spec
matchUnion = describe "match" $ do
  it "match on integer with one case, no errors" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent foo(x: integer) {\n",
            "  match (x) { case n => { n } }\n",
            "}"
          ]
    solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Contradictions
-- ---------------------------------------------------------------------------

contradictions :: Spec
contradictions = describe "contradictions" $ do
  it "agent foo() -> integer { \"bad\" } records solver error" $ do
    (_, _, solverResult, solverErrors) <- runSolve "agent foo() -> integer { \"bad\" }"
    null solverErrors `shouldBe` False

  it "even with errors, substitution is still total" $ do
    (_, cgResult, solverResult, solverErrors) <- runSolve "agent foo() -> integer { \"bad\" }"
    -- Errors mean the type substitution may be empty + filled with NormalizedTypeUnknown
    -- by the totality layer, so all TypeVariableIds still have entries.
    Map.size solverResult.typeSubstitution `shouldBe` cgResult.variableSupply.typeVarSupply

-- ---------------------------------------------------------------------------
-- End-to-end with Zonker
-- ---------------------------------------------------------------------------

endToEndZonk :: Spec
endToEndZonk = describe "end-to-end pipeline (Solver -> Zonker)" $ do
  it "Zonker over a real Solver result has no zonkErrors on a basic program" $ do
    (idResult, cgResult, solverResult, _solverErrors) <- runSolve "agent foo() { 42 }"
    let (_zonkResult, zonkErrors) = zonk "main" idResult cgResult solverResult
    zonkErrors `shouldBe` []

  it "totality is sufficient for Zonker even on programs with let / if" $ do
    (idResult, cgResult, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent foo(c: boolean) {\n",
            "  let x = if (c) { 1 } else { 2 };\n",
            "  x\n",
            "}"
          ]
    let (_zonkResult, zonkErrors) = zonk "main" idResult cgResult solverResult
    zonkErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- where / handler blocks
-- ---------------------------------------------------------------------------

whereHandlerBlocks :: Spec
whereHandlerBlocks = describe "handle blocks and request handlers" $ do
  it "handle with state variable: solver succeeds" $ do
    -- State variables are visible to handlers / then, NOT to the body.
    -- The body returns a literal; @n@ is just declared.
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent counter() -> integer {\n",
            "  handle (var n: integer = 0) {}\n",
            "  0\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "handle with request handler: request is discharged, agent has empty request" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "request fetch() -> integer\n",
            "agent app() {\n",
            "  handle {\n",
            "    request fetch() { break 42; }\n",
            "  }\n",
            "  fetch()\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "handle with state var + handler combining state mutation via next" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "request inc() -> integer\n",
            "agent counter() -> integer {\n",
            "  handle (var n: integer = 0) {\n",
            "    request inc() {\n",
            "      next n with { n = n + 1 }\n",
            "    }\n",
            "  }\n",
            "  inc();\n",
            "  inc();\n",
            "  inc()\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "explicit next with wrong type → records solver error" $ do
    -- The declared @-> integer@ on request constrains explicit @next@. Use
    -- @next \"bad\"@ to surface the type mismatch.
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "request fetch() -> integer\n",
            "agent app() -> integer {\n",
            "  handle {\n",
            "    request fetch() {\n",
            "      next \"bad\"\n",
            "    }\n",
            "  }\n",
            "  fetch()\n",
            "}"
          ]
    null solverErrors `shouldBe` False

  it "request handler body must be never: falling through with a value is a type error" $ do
    -- Replaces the prior implicit-break behavior. A handler body that
    -- ends with a value (no break / no next) violates the never-typing
    -- constraint and is rejected by the solver.
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "request fetch() -> integer\n",
            "agent app() {\n",
            "  handle {\n",
            "    request fetch() { 42 }\n",
            "  }\n",
            "  fetch()\n",
            "}"
          ]
    null solverErrors `shouldBe` False

  it "request handler body of type never (explicit break) passes" $ do
    -- An explicit `break v` makes the handler body inferable as `never`,
    -- satisfying the new constraint.
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "request fetch() -> integer\n",
            "agent app() {\n",
            "  handle {\n",
            "    request fetch() { break 42; }\n",
            "  }\n",
            "  fetch()\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "then clause: body tail flows through pattern, then body type is whole block" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent foo() -> integer {\n",
            "  handle {} then(p) { p + 1 }\n",
            "  42\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "then clause with state var: state var visible in then" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "request inc() -> integer\n",
            "agent counter() -> integer {\n",
            "  handle (var n: integer = 0) {\n",
            "    request inc() {\n",
            "      next n with { n = n + 1 }\n",
            "    }\n",
            "  } then(_) { n }\n",
            "  inc();\n",
            "  inc();\n",
            "  inc()\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "explicit break in handler routes value to whole-block (not declared next type)" $ do
    -- @request fetch() -> integer@: declared return only constrains @next@.
    -- An explicit @break "ok"@ flows to the handle-block whole type —
    -- independent of the declared @integer@ next return. Without a
    -- stricter agent annotation, no contradiction arises.
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "request fetch() -> integer\n",
            "agent app() {\n",
            "  handle {\n",
            "    request fetch() { break \"ok\"; }\n",
            "  }\n",
            "  fetch()\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "break inside handler body of block-with-then routes through then" $ do
    -- Handler @break 5@ : 5 <: pattern p (number) → then body @p + 1@ :
    -- number <: agent return integer. Should pass.
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "request dummy() -> integer\n",
            "agent foo() -> integer {\n",
            "  handle {\n",
            "    request dummy() -> integer { break 5; }\n",
            "  } then(p) { p + 1 }\n",
            "  dummy()\n",
            "}"
          ]
    solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- match expressions
-- ---------------------------------------------------------------------------

matchExpressions :: Spec
matchExpressions = describe "match expressions" $ do
  it "match on union with two literal arms" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent label(n: integer) -> string {\n",
            "  return match (n) {\n",
            "    case 0 => { \"zero\" }\n",
            "    case other => { \"other\" }\n",
            "  }\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "match on data constructor pattern" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "data circle(r: integer)\n",
            "agent area(c: circle) -> integer {\n",
            "  return match (c) { case circle(r = v) => { v } }\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "match arm bodies with mismatched types union into result" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent describe(b: boolean) {\n",
            "  return match (b) {\n",
            "    case true => { 1 }\n",
            "    case false => { \"false\" }\n",
            "  }\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "type-guard pattern narrows unknown -> integer inside the arm" $ do
    -- `integer(n) => add(lhs = n, rhs = 1)` requires `n : integer` —
    -- the pattern's narrowing must propagate to the bound variable, or
    -- this would fail with "expected integer, found unknown".
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent inc(v: unknown) -> integer {\n",
            "  match (v) {\n",
            "    case integer(n) => { n + 1 }\n",
            "    case _ => { 0 }\n",
            "  }\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "type-guard pattern narrows unknown -> string inside the arm" $ do
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent show(v: unknown) -> string {\n",
            "  match (v) {\n",
            "    case string(s) => { s }\n",
            "    case _ => { \"none\" }\n",
            "  }\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "record pattern entries get the record's V type" $ do
    -- `{ name = n }` against `record[string]` must give n : string.
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent extract(r: record[string]) -> string {\n",
            "  match (r) {\n",
            "    case { name = n } => { n }\n",
            "    case _ => { \"none\" }\n",
            "  }\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "record literal typechecks as record[V] with V the lub of entry types" $ do
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent make() -> record[unknown] {\n",
            "  { x = 1, y = \"hi\" }\n",
            "}"
          ]
    solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- for loops with var bindings, next/break (modifiers)
-- ---------------------------------------------------------------------------

forLoops :: Spec
forLoops = describe "for loops" $ do
  it "for ... in over an array" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent run(xs: array[integer]) {\n",
            "  for (let x in xs) { x }\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "for with var binding and next-with-modifier" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent sum(xs: array[integer]) -> integer {\n",
            "  return for (let x in xs, var acc = 0) {\n",
            "    next with { acc = acc + x }\n",
            "  } then { acc }\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "for with break terminating early" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent firstPositive(xs: array[integer]) -> integer | null {\n",
            "  return for (let x in xs) {\n",
            "    if (x > 0) { break x; } else { null }\n",
            "  } then { null }\n",
            "}"
          ]
    solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- local agent statements
-- ---------------------------------------------------------------------------

localAgents :: Spec
localAgents = describe "local agent statements" $ do
  it "local agent declared inside another agent's body" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent outer() -> integer {\n",
            "  agent inner() -> integer { 42 };\n",
            "  return inner()\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "local agent capturing outer parameter" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent outer(x: integer) -> integer {\n",
            "  agent inner() -> integer { x + 1 };\n",
            "  return inner()\n",
            "}"
          ]
    solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- nested blocks and let bindings
-- ---------------------------------------------------------------------------

nestedBlocks :: Spec
nestedBlocks = describe "nested blocks and let" $ do
  it "let inside if branch" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent f(c: boolean) -> integer {\n",
            "  return if (c) { let y = 10; y } else { 0 }\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "deeply nested if expressions" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent f(a: boolean, b: boolean) -> integer {\n",
            "  return if (a) { if (b) { 1 } else { 2 } } else { if (b) { 3 } else { 4 } }\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "multi-line block: trailing expression before close-brace is the return value" $ do
    -- Regression test for the virtual-';' / block-return UX: when an
    -- expression is followed by a newline and then a '}', the expression is
    -- the block's return value (not a statement). Without this fix, the
    -- inner @if (b) { 1 } else { 2 }@ would become a statement and the
    -- block would return null.
    (_, _, solverResult, solverErrors) <-
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
    solverErrors `shouldBe` []

  it "block expression with return statement inside" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent early(c: boolean) -> integer {\n",
            "  if (c) { return 1; }\n",
            "  return 2\n",
            "}"
          ]
    solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- data declarations + tuple/array/object inference
-- ---------------------------------------------------------------------------

dataAndCompositeTypes :: Spec
dataAndCompositeTypes = describe "data and composite types" $ do
  it "data constructor returns its data type" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "data point(x: integer, y: integer)\n",
            "agent origin() -> point { point(x = 0, y = 0) }"
          ]
    solverErrors `shouldBe` []

  it "array of integers" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent ones() -> array[integer] {\n",
            "  return [1, 2, 3]\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "tuple inference" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent pair() -> (integer, string) {\n",
            "  return (42, \"hi\")\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "data field access through pattern match" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "data box(value: integer)\n",
            "agent unbox(b: box) -> integer {\n",
            "  return match (b) { case box(value = v) => { v } }\n",
            "}"
          ]
    solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Higher-order: passing one agent as another's argument
-- ---------------------------------------------------------------------------

higherOrderFunctions :: Spec
higherOrderFunctions = describe "higher-order agents" $ do
  it "agent receives a function and calls it" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent caller(callback: agent (x: integer) -> integer) -> integer {\n",
            "  return callback(x = 1)\n",
            "}"
          ]
    solverErrors `shouldBe` []

  it "function-typed parameter unified across call site" $ do
    (_, _, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent identity(n: integer) -> integer { n }\n",
            "agent caller(cb: agent (n: integer) -> integer) -> integer { cb(n = 1) }\n",
            "agent run() -> integer { caller(cb = identity) }"
          ]
    solverErrors `shouldBe` []

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
    (idResult, cgResult, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent apply(g) {\n",
            "  return g(x = 1)\n",
            "}"
          ]
    solverErrors `shouldBe` []
    let inferred = inferredTypeOf "g" idResult cgResult solverResult
    inferred `shouldSatisfy` isFunctionShape

  it "(b) transitive var-on-var: x flows through y to number" $ do
    -- t_x <: t_y (let y = x), t_y <: number (via y + 1 arithmetic).
    -- Propagation should derive t_x <: number (transitively), pinning t_x.
    (idResult, cgResult, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent f(x) {\n",
            "  let y = x\n",
            "  return y + 1\n",
            "}"
          ]
    solverErrors `shouldBe` []
    let inferred = inferredTypeOf "x" idResult cgResult solverResult
    inferred `shouldSatisfy` isInhabited
    inferred `shouldNotSatisfy` isNTUnknown

  it "(c) β <: α only chain: x must inherit number through y annotation" $ do
    -- t_x <: t_y, t_y == number (via wildcard-pattern annotation in let).
    -- t_x's only direct lower bound is t_y (var) → propagation must derive
    -- t_x <: number to avoid NormalizedTypeUnknown fallback.
    (idResult, cgResult, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent f(x) {\n",
            "  let y = x\n",
            "  let _: number = y\n",
            "}"
          ]
    solverErrors `shouldBe` []
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
    (idResult, cgResult, solverResult, solverErrors) <-
      runSolve $
        mconcat
          [ "agent doubler(x: integer) -> number { 1 }\n",
            "agent test(extra: integer) {\n",
            "  let g = doubler\n",
            "  let r = g(x = 1)\n",
            "  return if (true) { r } else { extra }\n",
            "}"
          ]
    solverErrors `shouldBe` []
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

-- ---------------------------------------------------------------------------
-- Ill-typed program rejection
--
-- These probe whether the solver correctly REJECTS programs with type
-- errors. The existing positive tests verify well-typed programs solve
-- cleanly, but the negative coverage was thin (only 3 cases). This block
-- covers each composite-type shape (function / array / tuple / data /
-- branch / annotation) with a deliberately bad assignment.
-- ---------------------------------------------------------------------------

illTypedRejection :: Spec
illTypedRejection = describe "ill-typed program rejection" $ do
  -- Direct let-annotation mismatches: trivial concrete-vs-concrete cases.
  it "let x: integer = \"bad\" → solver error" $ do
    (_, _, _, solverErrors) <-
      runSolve "agent f() { let x: integer = \"bad\"; x }"
    null solverErrors `shouldBe` False

  it "let x: string = 42 → solver error" $ do
    (_, _, _, solverErrors) <-
      runSolve "agent f() { let x: string = 42; x }"
    null solverErrors `shouldBe` False

  -- Function-signature mismatch via annotation. Tests function shape
  -- subtyping (let contravariant in params, let covariant in return).
  it "let f: agent (s: string) -> integer = some_int_to_int_agent → error" $ do
    -- 'square' has type (n: integer) -> integer. Binding to a function
    -- expecting (s: string) -> integer should fail because the parameter
    -- types are contravariantly compared (string is not a subtype of integer).
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent square(n: integer) -> integer { n }\n",
            "agent caller() {\n",
            "  let f: agent (s: string) -> integer = square;\n",
            "  f(s = \"hi\")\n",
            "}"
          ]
    null solverErrors `shouldBe` False

  it "function return-type mismatch via annotation → error" $ do
    -- 'square' returns integer. Annotating as -> string should fail
    -- (covariant: integer is not a subtype of string).
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent square(n: integer) -> integer { n }\n",
            "agent caller() {\n",
            "  let f: agent (n: integer) -> string = square;\n",
            "  f(n = 1)\n",
            "}"
          ]
    null solverErrors `shouldBe` False

  -- Calling a known agent with the wrong argument type.
  it "calling square(n = \"hi\") → error" $ do
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent square(n: integer) -> integer { n }\n",
            "agent caller() { square(n = \"hi\") }"
          ]
    null solverErrors `shouldBe` False

  -- Branch-fallback probe: bare-param functions where one side has a
  -- conflicting shape constraint while the other side has no concrete
  -- lower bound. This is the exact pattern the audit memo flagged as
  -- "α := Never fallback silently masks structural mismatch".
  it "branch fallback probe: pass int agent where string agent expected → error" $ do
    -- 'apply_string' expects a (s: string) -> integer callable. We pass
    -- 'square' which is (n: integer) -> integer. The label mismatch
    -- (n vs s) AND the parameter type mismatch (integer vs string) both
    -- should be caught.
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent square(n: integer) -> integer { n }\n",
            "agent apply_string(cb: agent (s: string) -> integer) -> integer {\n",
            "  cb(s = \"hi\")\n",
            "}\n",
            "agent run() { apply_string(cb = square) }"
          ]
    null solverErrors `shouldBe` False

  it "branch fallback probe: incompatible return types through HOF param" $ do
    -- 'agent_returning_string' returns string. We pass it to a HOF that
    -- expects a callable returning integer; result is used in arithmetic.
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent stringify() -> string { \"hi\" }\n",
            "agent caller(cb: agent () -> integer) -> integer { cb() + 1 }\n",
            "agent run() -> integer { caller(cb = stringify) }"
          ]
    null solverErrors `shouldBe` False

  -- Array element type mismatch.
  it "let xs: array[integer] = [1, \"two\", 3] → error" $ do
    (_, _, _, solverErrors) <-
      runSolve "agent f() { let xs: array[integer] = [1, \"two\", 3]; xs }"
    null solverErrors `shouldBe` False

  -- Tuple element type mismatch.
  it "let p: (integer, string) = (\"flip\", 1) → error" $ do
    (_, _, _, solverErrors) <-
      runSolve "agent f() { let p: (integer, string) = (\"flip\", 1); p }"
    null solverErrors `shouldBe` False

  -- Data constructor field type mismatch.
  it "Point(x = \"no\", y = 2) where x: integer → error" $ do
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "data Point(x: integer, y: integer)\n",
            "agent f() { Point(x = \"no\", y = 2) }"
          ]
    null solverErrors `shouldBe` False

  -- If-branch type mismatch when the result is then constrained by an
  -- annotation that neither arm satisfies. (Both arms unioning is allowed
  -- in general; this checks the annotation pins it.)
  it "let n: integer = if (c) { 1 } else { \"x\" } → error" $ do
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent f(c: boolean) {\n",
            "  let n: integer = if (c) { 1 } else { \"x\" };\n",
            "  n\n",
            "}"
          ]
    null solverErrors `shouldBe` False

  -- Annotated function declaration whose body returns the wrong type.
  it "agent f() -> integer { true } → error" $ do
    (_, _, _, solverErrors) <-
      runSolve "agent f() -> integer { true }"
    null solverErrors `shouldBe` False

  -- Match arm result mismatch against an annotated binding.
  it "let n: integer = match (x) { ... \"string\" arm ... } → error" $ do
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent f(x: integer) {\n",
            "  let n: integer = match (x) {\n",
            "    case 0 => { \"zero\" }\n",
            "    case _ => { 1 }\n",
            "  };\n",
            "  n\n",
            "}"
          ]
    null solverErrors `shouldBe` False

  -- ─── More corner cases ──────────────────────────────────────────────

  -- Recursive call with mismatched return-type usage.
  it "recursive agent: foo() + \"str\" with foo: () -> integer → error" $ do
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent foo() -> integer { foo() + 1 }\n",
            "agent caller() { foo() + \"str\" }"
          ]
    null solverErrors `shouldBe` False

  -- Block expression annotated mismatch.
  it "let r: integer = { let x = 1; \"hi\" } → error" $ do
    (_, _, _, solverErrors) <-
      runSolve "agent f() { let r: integer = { let x = 1; \"hi\" }; r }"
    null solverErrors `shouldBe` False

  -- Empty array vs annotated incompatible element type.
  it "let xs: array[integer] = [] then push string → error" $ do
    -- An empty array literal infers its element type from context. Pushing
    -- a string later via a let binding should still be rejected if the
    -- annotated element type is integer.
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent f() {\n",
            "  let xs: array[integer] = [];\n",
            "  let bad: integer = \"hi\";\n",
            "  xs\n",
            "}"
          ]
    null solverErrors `shouldBe` False

  -- Local agent capturing an outer parameter, with conflicting use.
  it "local agent captures outer int, body misuses it as string → error" $ do
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent outer(x: integer) {\n",
            "  agent helper() -> integer { x + \"oops\" }\n",
            "  helper()\n",
            "}"
          ]
    null solverErrors `shouldBe` False

  -- HOF returning a callable; result called with wrong arg type.
  it "HOF returns a callable, call site uses wrong arg type → error" $ do
    -- The returned callable's parameter type is known statically (from the
    -- HOF's return-type annotation); calling it with the wrong-typed arg
    -- should be rejected. The HOF's inner agent definition exercises
    -- local-agent / closure handling as a side benefit.
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent makeAdder() -> agent (n: integer) -> integer {\n",
            "  agent inc(n: integer) -> integer { n + 1 }\n",
            "  inc\n",
            "}\n",
            "agent run() {\n",
            "  let f = makeAdder();\n",
            "  f(n = \"oops\")\n",
            "}"
          ]
    null solverErrors `shouldBe` False

  -- Field access on a non-data type.
  it "field access on integer-typed var → error" $ do
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent f() {\n",
            "  let n: integer = 5;\n",
            "  n.foo\n",
            "}"
          ]
    null solverErrors `shouldBe` False

  -- Indexing into a non-array.
  it "indexing into a string-typed var → error" $ do
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent f() {\n",
            "  let s: string = \"hi\";\n",
            "  s[0]\n",
            "}"
          ]
    null solverErrors `shouldBe` False

  -- Match-arm pattern type mismatch (string-literal pattern against an
  -- integer subject). By design NOT a Solver error in Katari — pattern
  -- types are allowed to be narrower/wider/disjoint from the subject.
  -- An arm whose pattern is structurally disjoint from the subject is
  -- flagged by 'Katari.Typechecker.Exhaustive' as K0292 (unreachable
  -- arm) — see 'ExhaustiveSpec'. The Solver leaves it alone.
  it "match on integer with string-literal arm → solver does NOT flag" $ do
    (_, _, _, solverErrors) <-
      runSolve $
        mconcat
          [ "agent f(x: integer) {\n",
            "  match (x) {\n",
            "    case \"hi\" => { 1 }\n",
            "    case _ => { 0 }\n",
            "  }\n",
            "}"
          ]
    solverErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Union return + multi-arm match → bound aggregation (regression)
--
-- Regression coverage for the union-return secret-taint bug
-- (project_solver_union_return_secret_taint.md). The bug was triggered by
-- `α ⊑ (A | B)` branching unsoundly when the upper-bound union was concrete:
-- the solver committed to one branch, contradicted the other lower bound,
-- and reported a misleading error. Worse, the global solver explored other
-- branchable constraints in the same world line, leaking unrelated "secret"
-- taint into f-string interpolations.
--
-- New algorithm: concrete union upper bounds are aggregated via intersectNT
-- instead of branched. Per-var lower = unionNT of lowers, upper = intersectNT
-- of uppers. The consistency check uses subtypeNormalizedType on those.
-- ---------------------------------------------------------------------------

unionReturnBoundAggregation :: Spec
unionReturnBoundAggregation =
  describe "union return + multi-arm match (bug repro)" $ do
    it "data union return with one arm per ctor compiles cleanly" $ do
      -- Minimal repro: lower bounds {ok, err}, upper bound (ok | err).
      -- Old solver: branches into [tMatch ⊑ ok] OR [tMatch ⊑ err], both fail.
      -- New solver: tMatch's lower = unionNT(ok, err); upper = (ok|err);
      -- subtypeNormalizedType check passes. No error.
      (_, _, _, solverErrors) <-
        runSolve $
          mconcat
            [ "data ok(n: integer)\n",
              "data err(message: string)\n",
              "agent maybe_fail(b: boolean) -> ok | err {\n",
              "  match (b) {\n",
              "    case true => { err(message = \"x\") }\n",
              "    case _    => { ok(n = 1) }\n",
              "  }\n",
              "}"
            ]
      solverErrors `shouldBe` []

    it "primitive union return (integer | boolean) with multi-arm match" $ do
      -- Same shape as above but without data ctors: confirms the bug is
      -- not data-specific.
      (_, _, _, solverErrors) <-
        runSolve $
          mconcat
            [ "agent maybe_int_bool(b: boolean) -> integer | boolean {\n",
              "  match (b) {\n",
              "    case true => { 1 }\n",
              "    case _    => { false }\n",
              "  }\n",
              "}"
            ]
      solverErrors `shouldBe` []

    it "union return agent does NOT contaminate unrelated f-string in same module" $ do
      -- The "secret taint leak" was the user-visible bug. Before the fix,
      -- adding `maybe_fail` to the module broke `describe_pair` with
      -- "expected string, found secret" at the to_string(value = n) span,
      -- even though no `secret` appears anywhere in source. The whole
      -- module must compile cleanly together.
      (_, _, _, solverErrors) <-
        runSolve $
          mconcat
            [ "data ok(n: integer)\n",
              "data err(message: string)\n",
              "agent describe_pair(t: (integer, string)) -> string {\n",
              "  match (t) {\n",
              "    case (0, s) => { f\"zero with ${s}\" }\n",
              "    case (n, s) => { f\"${to_string(value = n)} with ${s}\" }\n",
              "  }\n",
              "}\n",
              "agent maybe_fail(b: boolean) -> ok | err {\n",
              "  match (b) {\n",
              "    case true => { err(message = \"x\") }\n",
              "    case _    => { ok(n = 1) }\n",
              "  }\n",
              "}"
            ]
      solverErrors `shouldBe` []

    it "single-ctor return into declared union still compiles (regression: not broken by fix)" $ do
      -- The pre-fix solver accepted this case (lower = {ok}, upper = (ok|err);
      -- branching picks `tMatch ⊑ ok` and succeeds). Must continue to work.
      (_, _, _, solverErrors) <-
        runSolve $
          mconcat
            [ "data ok(n: integer)\n",
              "data err(message: string)\n",
              "agent always_ok() -> ok | err { ok(n = 1) }"
            ]
      solverErrors `shouldBe` []

    it "union argument type (not return) still works" $ do
      -- Sanity check: union ARGUMENT was never bugged. After the fix, must
      -- still compile.
      (_, _, _, solverErrors) <-
        runSolve $
          mconcat
            [ "data ok(n: integer)\n",
              "data err(message: string)\n",
              "agent describe_result(r: ok | err) -> string {\n",
              "  match (r) {\n",
              "    case ok(n = v) => { \"ok\" }\n",
              "    case err(message = m) => { m }\n",
              "  }\n",
              "}"
            ]
      solverErrors `shouldBe` []
