{-# LANGUAGE ImportQualifiedPost #-}

-- | Tests for 'Katari.Typechecker.Exhaustive'.
--
-- The Exhaustive pass is the canonical place where Katari catches "this
-- match arm could never run" / "this match is missing a case" — the
-- Solver intentionally doesn't constrain pattern type vs subject type
-- (= patterns are allowed to be narrower / wider / refining the
-- subject), so the only sound place to flag a structurally unreachable
-- arm is here.
module Katari.ExhaustiveSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Katari.Compile qualified as Compile
import Katari.Diagnostic (Diagnostic (..))
import Katari.Lexer qualified as Lexer
import Katari.Parser qualified as Parser
import Katari.Typechecker.ConstraintGenerator (generateConstraints)
import Katari.Typechecker.Exhaustive (checkExhaustive, toDiagnostic)
import Katari.Typechecker.Solver (solve)
import Katari.Typechecker.Zonker (zonk)
import Test.Hspec (Spec, describe, it, shouldBe)

-- ---------------------------------------------------------------------------
-- Pipeline helper
-- ---------------------------------------------------------------------------

-- | Run parser → identify → constraint-gen → solve → zonk → exhaustive
-- and return the diagnostics. Used by the test cases below.
runExhaustive :: Text -> IO [Diagnostic]
runExhaustive source = do
  let (stream, _) = Lexer.lex "<test>" source
      (parsed, parseErrors) = Parser.parse "<test>" stream
  case parseErrors of
    (_ : _) -> fail ("parse failure: " ++ show parseErrors)
    [] -> case Compile.identifyWithStdlib (Map.singleton "main" parsed) of
      (idResult, []) -> do
        let (cgResult, _) = generateConstraints idResult
            (solverResult, _) = solve cgResult
            (zonkResult, _) = zonk idResult cgResult solverResult
            exhaustiveErrors = checkExhaustive idResult zonkResult
        pure (map toDiagnostic exhaustiveErrors)
      (_, errs) -> fail ("identify failure: " ++ show errs)

-- | True iff @diags@ contains at least one error / warning with the given code.
hasCode :: Text -> [Diagnostic] -> Bool
hasCode code = any (\d -> d . code == code)

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = describe "Katari.Typechecker.Exhaustive" $ do
  nonExhaustiveMatch
  unreachableArmCoverage
  unreachableArmTypeDisjoint
  refutableBindings
  validPatterns

-- | K0290 — match expressions missing coverage.
nonExhaustiveMatch :: Spec
nonExhaustiveMatch = describe "K0290 non-exhaustive match" $ do
  it "match on boolean with only `true` arm is non-exhaustive" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "agent f(b: boolean) {\n",
            "  match (b) {\n",
            "    case true => { 1 }\n",
            "  }\n",
            "}"
          ]
    hasCode "K0290" diags `shouldBe` True

  it "match on union of data ctors missing one is non-exhaustive" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "data leaf()\n",
            "data node()\n",
            "agent f(t: leaf | node) {\n",
            "  match (t) {\n",
            "    case leaf() => { 1 }\n",
            "  }\n",
            "}"
          ]
    hasCode "K0290" diags `shouldBe` True

-- | K0292 — arms covered by prior arms.
unreachableArmCoverage :: Spec
unreachableArmCoverage = describe "K0292 unreachable: covered by prior arms" $ do
  it "wildcard before specific literal makes the literal arm unreachable" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "agent f(x: integer) {\n",
            "  match (x) {\n",
            "    case _ => { 0 }\n",
            "    case 1 => { 1 }\n",
            "  }\n",
            "}"
          ]
    hasCode "K0292" diags `shouldBe` True

  it "two identical bool arms: second one is unreachable" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "agent f(b: boolean) {\n",
            "  match (b) {\n",
            "    case true => { 1 }\n",
            "    case true => { 2 }\n",
            "    case false => { 3 }\n",
            "  }\n",
            "}"
          ]
    hasCode "K0292" diags `shouldBe` True

-- | K0292 — arms whose pattern head is structurally disjoint from the
-- subject type, so no value of the subject type can match them.
unreachableArmTypeDisjoint :: Spec
unreachableArmTypeDisjoint = describe "K0292 unreachable: pattern head disjoint from subject" $ do
  it "string-literal pattern against integer subject" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "agent f(x: integer) {\n",
            "  match (x) {\n",
            "    case \"hi\" => { 1 }\n",
            "    case _ => { 0 }\n",
            "  }\n",
            "}"
          ]
    hasCode "K0292" diags `shouldBe` True

  it "integer-literal pattern against string subject" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "agent f(s: string) {\n",
            "  match (s) {\n",
            "    case 5 => { 1 }\n",
            "    case _ => { 0 }\n",
            "  }\n",
            "}"
          ]
    hasCode "K0292" diags `shouldBe` True

  it "boolean-literal pattern against integer subject" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "agent f(x: integer) {\n",
            "  match (x) {\n",
            "    case true => { 1 }\n",
            "    case _ => { 0 }\n",
            "  }\n",
            "}"
          ]
    hasCode "K0292" diags `shouldBe` True

  it "null pattern against integer subject" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "agent f(x: integer) {\n",
            "  match (x) {\n",
            "    case null => { 1 }\n",
            "    case _ => { 0 }\n",
            "  }\n",
            "}"
          ]
    hasCode "K0292" diags `shouldBe` True

  it "data-ctor pattern against integer subject" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "data leaf()\n",
            "agent f(x: integer) {\n",
            "  match (x) {\n",
            "    case leaf() => { 1 }\n",
            "    case _ => { 0 }\n",
            "  }\n",
            "}"
          ]
    hasCode "K0292" diags `shouldBe` True

  it "data-ctor of unrelated type against another data type" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "data leaf()\n",
            "data circle()\n",
            "agent f(t: leaf) {\n",
            "  match (t) {\n",
            "    case circle() => { 1 }\n",
            "    case leaf()   => { 2 }\n",
            "  }\n",
            "}"
          ]
    hasCode "K0292" diags `shouldBe` True

-- | K0291 — refutable patterns where an irrefutable one is required.
refutableBindings :: Spec
refutableBindings = describe "K0291 refutable irrefutable binding" $ do
  it "let pattern with refutable literal pattern fails" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "agent f(x: integer) {\n",
            "  let 5 = x;\n",
            "  0\n",
            "}"
          ]
    hasCode "K0291" diags `shouldBe` True

-- ---------------------------------------------------------------------------
-- Valid programs: no Exhaustive diagnostics expected.
-- ---------------------------------------------------------------------------

validPatterns :: Spec
validPatterns = describe "well-typed exhaustive matches produce no Exhaustive diagnostics" $ do
  it "wildcard catch-all" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "agent f(x: integer) {\n",
            "  match (x) {\n",
            "    case 1 => { 1 }\n",
            "    case _ => { 0 }\n",
            "  }\n",
            "}"
          ]
    diags `shouldBe` []

  it "both bool arms" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "agent f(b: boolean) {\n",
            "  match (b) {\n",
            "    case true  => { 1 }\n",
            "    case false => { 0 }\n",
            "  }\n",
            "}"
          ]
    diags `shouldBe` []

  it "all ctors of a data-union are covered" $ do
    diags <-
      runExhaustive $
        mconcat
          [ "data leaf()\n",
            "data node()\n",
            "agent f(t: leaf | node) {\n",
            "  match (t) {\n",
            "    case leaf() => { 1 }\n",
            "    case node() => { 2 }\n",
            "  }\n",
            "}"
          ]
    diags `shouldBe` []

  it "union subject — literal pattern from each branch is reachable" $ do
    -- subject: integer | string. The literal 1 pattern matches the integer
    -- branch; "hi" matches the string branch. Neither is disjoint from
    -- the subject's union; both arms are reachable. The trailing
    -- wildcard makes the match exhaustive.
    diags <-
      runExhaustive $
        mconcat
          [ "agent f(x: integer | string) {\n",
            "  match (x) {\n",
            "    case 1     => { 0 }\n",
            "    case \"hi\" => { 0 }\n",
            "    case _     => { 0 }\n",
            "  }\n",
            "}"
          ]
    diags `shouldBe` []
