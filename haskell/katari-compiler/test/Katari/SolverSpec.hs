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
  ( NormalizedType (..),
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
    -- Errors mean the type substitution may be empty + filled with NTUnknown
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
