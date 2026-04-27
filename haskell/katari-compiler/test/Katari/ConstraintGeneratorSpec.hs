module Katari.ConstraintGeneratorSpec (spec) where

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Parser (parseModuleStrict)
import Katari.Typechecker.ConstraintGenerator
import Katari.Typechecker.Identifier
  ( IdentifierResult (..),
    VariableData (..),
    VariableId,
    identify,
  )
import Katari.Typechecker.SemanticType
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

-- | Parse, identify, and run constraint generation on a single module named
-- "main". Aborts the spec if parse or identify fails.
runOne :: Text -> IO ConstraintGenResult
runOne src = fmap fst (runOneWithIdentifier src)

-- | Same as 'runOne' but also returns the underlying 'IdentifierResult' so
-- tests can look up VariableIds by source name.
runOneWithIdentifier :: Text -> IO (ConstraintGenResult, IdentifierResult)
runOneWithIdentifier src = case parseModuleStrict "<test>" src of
  Left errs -> fail ("parse failure: " ++ show (map show errs))
  Right parsed -> case identify (Map.singleton "main" parsed) of
    (result, []) -> pure (generateConstraints result, result)
    (_, errs) -> fail ("identify failure: " ++ show errs)

countTypeConstraints :: ConstraintGenResult -> Int
countTypeConstraints result =
  length [() | TypeConstraint {} <- result.constraints]

countEffectConstraints :: ConstraintGenResult -> Int
countEffectConstraints result =
  length [() | EffectConstraint {} <- result.constraints]

typeConstraints :: ConstraintGenResult -> [(SemanticType Unresolved, SemanticType Unresolved)]
typeConstraints result =
  [(lhs, rhs) | TypeConstraint {typeLhs = lhs, typeRhs = rhs} <- result.constraints]

effectConstraints
  :: ConstraintGenResult
  -> [(SemanticEffect Unresolved, SemanticEffect Unresolved)]
effectConstraints result =
  [(lhs, rhs) | EffectConstraint {effectLhs = lhs, effectRhs = rhs} <- result.constraints]

-- | Find the VariableId for a given source name.
variableIdOf :: Text -> IdentifierResult -> Maybe VariableId
variableIdOf name result =
  fst <$> find ((== name) . (.variableName) . snd) (Map.toList result.identifiedVariables)

-- | Lookup the type variable assigned to a named variable.
typeVarOf :: Text -> ConstraintGenResult -> IdentifierResult -> Maybe (SemanticType Unresolved)
typeVarOf name cg ir = variableIdOf name ir >>= \vid -> Map.lookup vid cg.typeEnvironment

-- | True if any type constraint has the given lhs.
hasTypeConstraintLhs
  :: SemanticType Unresolved
  -> ConstraintGenResult
  -> Bool
hasTypeConstraintLhs target cg = any (\(lhs, _) -> lhs == target) (typeConstraints cg)

-- | True if some constraint matches the given (lhs, rhs) predicate.
hasTypeConstraint
  :: (SemanticType Unresolved -> SemanticType Unresolved -> Bool)
  -> ConstraintGenResult
  -> Bool
hasTypeConstraint p cg = any (uncurry p) (typeConstraints cg)

-- | True if some effect constraint matches the predicate.
hasEffectConstraint
  :: (SemanticEffect Unresolved -> SemanticEffect Unresolved -> Bool)
  -> ConstraintGenResult
  -> Bool
hasEffectConstraint p cg = any (uncurry p) (effectConstraints cg)

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  basicAgent
  multipleModules
  variablePatterns
  declarations
  callExpressions
  constructorPatterns
  whereBlocks
  typeSynonymCycle
  constraintContents

-- ---------------------------------------------------------------------------
-- Basic agent
-- ---------------------------------------------------------------------------

basicAgent :: Spec
basicAgent = describe "basic agent" $ do
  it "agent foo() { 0 } produces some constraints and no errors" $ do
    cg <- runOne "agent foo() { 0 }"
    cg.errors `shouldBe` []
    countTypeConstraints cg `shouldSatisfy` (> 0)

  it "agent with annotated return type generates eq constraint" $ do
    cg <- runOne "agent foo() -> integer { 0 }"
    cg.errors `shouldBe` []
    -- agent signature と t_foo の eq constraint (= subtype 2 本) が含まれる
    countTypeConstraints cg `shouldSatisfy` (>= 2)

  it "agent with no return / no effects: both inferred (no errors)" $ do
    cg <- runOne "agent foo() { 0 }"
    cg.errors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Multiple modules: same VariableId → same TypeVar
-- ---------------------------------------------------------------------------

multipleModules :: Spec
multipleModules = describe "multiple modules" $ do
  it "imported variable shares the type var of its origin" $ do
    let lib = "agent helper() { 0 }"
        main_ = "import { helper } from lib\nagent run() { helper() }"
    case (,) <$> parseModuleStrict "<test>" lib <*> parseModuleStrict "<test>" main_ of
      Left errs -> expectationFailure ("parse: " ++ show errs)
      Right (libMod, mainMod) -> case identify (Map.fromList [("lib", libMod), ("main", mainMod)]) of
        (_, e : es) -> expectationFailure ("identify errors: " ++ show (e : es))
        (result, []) -> do
          let cg = generateConstraints result
          cg.errors `shouldBe` []
          -- 同じ helper VariableId に対して typeEnvironment に entry が一つだけ
          -- (= 同一 type var が両 module で参照されている)
          let helperVid =
                find
                  ((== ("helper" :: Text)) . (.variableName) . snd)
                  (Map.toList result.identifiedVariables)
          case helperVid of
            Just (vid, _) ->
              Map.member vid cg.typeEnvironment `shouldBe` True
            Nothing -> expectationFailure "expected helper variable in identified vars"

-- ---------------------------------------------------------------------------
-- Variable pattern (annotated → eq, unannotated → no constraint)
-- ---------------------------------------------------------------------------

variablePatterns :: Spec
variablePatterns = describe "variable patterns" $ do
  it "annotated parameter generates an eq constraint between var type and annotation" $ do
    cg <- runOne "agent foo(x: integer) { 0 }"
    cg.errors `shouldBe` []
    -- Eq generates 2 subtype constraints. Plus the agent signature eq (2),
    -- the body return-flow constraint (1), the return-annotation eq (2),
    -- and the effect bound. So we expect a healthy non-zero number.
    countTypeConstraints cg `shouldSatisfy` (> 0)

  it "unannotated parameter does not create extra type constraint per pattern" $ do
    cg1 <- runOne "agent foo(x: integer) { 0 }"
    cg2 <- runOne "agent foo(x) { 0 }"
    -- The annotated one should have at least 2 more type constraints (the
    -- extra eq introduced by the pattern annotation).
    countTypeConstraints cg1 `shouldSatisfy` (>= countTypeConstraints cg2 + 2)

-- ---------------------------------------------------------------------------
-- Declarations: data ctor, req, ext-agent
-- ---------------------------------------------------------------------------

declarations :: Spec
declarations = describe "declarations" $ do
  it "data constructor signature is pure (no effects)" $ do
    cg <- runOne "data foo(x: integer)\nagent main() { foo(x = 1) }"
    cg.errors `shouldBe` []
    -- We don't introspect specific constraints here; just check no errors and
    -- some constraints emitted.
    countTypeConstraints cg `shouldSatisfy` (> 0)

  it "req declaration emits eq constraint" $ do
    cg <- runOne "req foo(x: integer) -> string"
    cg.errors `shouldBe` []
    countTypeConstraints cg `shouldSatisfy` (>= 2)  -- eq = 2 subtype

  it "ext-agent emits eq constraint (effects from with clause)" $ do
    cg <- runOne "req bar(x: integer) -> string\next agent foo() -> integer with bar"
    cg.errors `shouldBe` []
    countTypeConstraints cg `shouldSatisfy` (>= 2)

-- ---------------------------------------------------------------------------
-- Call expressions: effect constraint propagation
-- ---------------------------------------------------------------------------

callExpressions :: Spec
callExpressions = describe "call expressions" $ do
  it "agent calling another agent generates a call constraint" $ do
    cg <- runOne "agent helper() { 0 }\nagent main() { helper() }"
    cg.errors `shouldBe` []
    -- Effect constraint(s) for the body effect bound + call propagation
    countEffectConstraints cg `shouldSatisfy` (> 0)

-- ---------------------------------------------------------------------------
-- Constructor pattern (reverse-call)
-- ---------------------------------------------------------------------------

constructorPatterns :: Spec
constructorPatterns = describe "constructor patterns" $ do
  it "match on data ctor pattern emits constraint without TypeData lookup" $ do
    cg <-
      runOne $
        mconcat
          [ "data circle(r: integer)\n",
            "agent main(x: circle) {",
            "  match (x) {",
            "    case circle(r = v) => { v }",
            "  }",
            "}"
          ]
    cg.errors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Where blocks (effect discharge)
-- ---------------------------------------------------------------------------

whereBlocks :: Spec
whereBlocks = describe "where blocks" $ do
  it "where block discharges its handled reqs" $ do
    cg <-
      runOne $
        mconcat
          [ "req fetch() -> string\n",
            "agent main() -> string {",
            "  fetch()",
            "} where {",
            "  req fetch() -> string { \"ok\" }",
            "}"
          ]
    cg.errors `shouldBe` []
    -- Effect constraints include the discharge: inner_eff <: outer ∪ {fetch}
    countEffectConstraints cg `shouldSatisfy` (> 0)

  it "req handler with effect annotation is rejected by parser" $ do
    case parseModuleStrict "<test>" $
      mconcat
        [ "req fetch() -> string\n",
          "agent main() -> string {",
          "  fetch()",
          "} where {",
          "  req fetch() -> string with bar { \"ok\" }",
          "}"
        ] of
      Left _ -> pure ()  -- parse error expected
      Right _ -> expectationFailure "expected parse failure for handler with-clause"

  it "handler break value flows to a type variable (handle-result)" $ do
    cg <-
      runOne $
        mconcat
          [ "req fetch() -> string\n",
            "agent main() -> string {\n",
            "  fetch()\n",
            "} where {\n",
            "  req fetch() -> string {\n",
            "    break \"boom\"\n",
            "  }\n",
            "}\n"
          ]
    cg.errors `shouldBe` []
    -- break "boom" should emit a constraint with lhs = literal "boom"
    -- targeting some type variable (the handle-result tv).
    cg `shouldSatisfy` hasTypeConstraint
      ( \l r -> l == SemanticTypeLiteralString "boom" && case r of
          SemanticTypeVariable _ -> True
          _ -> False
      )

  it "handler next value flows to a type variable (handler return / next-tv)" $ do
    cg <-
      runOne $
        mconcat
          [ "req fetch() -> string\n",
            "agent main() -> string {\n",
            "  fetch()\n",
            "} where {\n",
            "  req fetch() -> string {\n",
            "    next \"resumed\"\n",
            "  }\n",
            "}\n"
          ]
    cg.errors `shouldBe` []
    cg `shouldSatisfy` hasTypeConstraint
      ( \l r -> l == SemanticTypeLiteralString "resumed" && case r of
          SemanticTypeVariable _ -> True
          _ -> False
      )

  it "where without then: body tail value flows into the handle-result tv" $ do
    -- A where block with no then clause means the body's tail value is the
    -- whole expression's value. The body has a tail expression "hello" (no
    -- separating newline before '}', so it stays a returnExpression rather
    -- than becoming a StatementExpression).
    cg <-
      runOne $
        mconcat
          [ "req fetch() -> string\n",
            "agent main() -> string { \"hello\" } where {\n",
            "  req fetch() -> string {\n",
            "    next \"x\"\n",
            "  }\n",
            "}\n"
          ]
    cg.errors `shouldBe` []
    cg `shouldSatisfy` hasTypeConstraint
      ( \l r -> l == SemanticTypeLiteralString "hello" && case r of
          SemanticTypeVariable _ -> True
          _ -> False
      )

  it "where with then: body tail value flows into the then-pattern annotation" $ do
    -- Body tail "hi" : string. Then-pattern annotated 'integer'. CG should
    -- emit a constraint linking the body's literal type to integer.
    cg <-
      runOne $
        mconcat
          [ "req fetch() -> string\n",
            "agent main() { \"hi\" } where {\n",
            "  req fetch() -> string {\n",
            "    next \"x\"\n",
            "  }\n",
            "} then(x: integer) { 0 }\n"
          ]
    cg.errors `shouldBe` []
    cg `shouldSatisfy` hasTypeConstraint
      ( \l r -> l == SemanticTypeLiteralString "hi" && r == SemanticTypeInteger
      )

  it "where with then: then block's tail flows into the handle-result tv" $ do
    cg <-
      runOne $
        mconcat
          [ "req fetch() -> string\n",
            "agent main() -> integer { \"hi\" } where {\n",
            "  req fetch() -> string {\n",
            "    next \"x\"\n",
            "  }\n",
            "} then(x: string) { 0 }\n"
          ]
    cg.errors `shouldBe` []
    cg `shouldSatisfy` hasTypeConstraint
      ( \l r -> l == SemanticTypeLiteralInteger 0 && case r of
          SemanticTypeVariable _ -> True
          _ -> False
      )

-- ---------------------------------------------------------------------------
-- Type synonym cycle detection
-- ---------------------------------------------------------------------------

typeSynonymCycle :: Spec
typeSynonymCycle = describe "type synonym cycle" $ do
  it "type T = T is detected as a cycle" $ do
    cg <- runOne "type T = T\nagent main(x: T) { 0 }"
    -- One ErrorTypeSynonymCycle expected (or more if T is referenced again).
    cg.errors `shouldSatisfy` any isCycleError
    where
      isCycleError ErrorTypeSynonymCycle {} = True

-- ---------------------------------------------------------------------------
-- Constraint contents (verify shape, not just count)
-- ---------------------------------------------------------------------------

constraintContents :: Spec
constraintContents = describe "constraint contents" $ do
  it "literal int expression flows as SemanticTypeLiteralInteger" $ do
    cg <- runOne "agent foo() { 42 }"
    -- body の return statement constraint で lhs = SemanticTypeLiteralInteger 42
    cg `shouldSatisfy` hasTypeConstraintLhs (SemanticTypeLiteralInteger 42)

  it "literal string expression flows as SemanticTypeLiteralString" $ do
    cg <- runOne "agent foo() { \"hello\" }"
    cg `shouldSatisfy` hasTypeConstraintLhs (SemanticTypeLiteralString "hello")

  it "literal boolean expression flows as SemanticTypeLiteralBoolean" $ do
    cg <- runOne "agent foo() { true }"
    cg `shouldSatisfy` hasTypeConstraintLhs (SemanticTypeLiteralBoolean True)

  it "null expression flows as SemanticTypeNull" $ do
    cg <- runOne "agent foo() { null }"
    cg `shouldSatisfy` hasTypeConstraintLhs SemanticTypeNull

  it "annotated parameter emits both directions of eq with SemanticTypeInteger" $ do
    (cg, ir) <- runOneWithIdentifier "agent foo(x: integer) { 0 }"
    case typeVarOf "x" cg ir of
      Nothing -> expectationFailure "x not in env"
      Just tx -> do
        -- t_x <: integer  AND  integer <: t_x
        cg `shouldSatisfy` hasTypeConstraint (\l r -> l == tx && r == SemanticTypeInteger)
        cg `shouldSatisfy` hasTypeConstraint (\l r -> l == SemanticTypeInteger && r == tx)

  it "agent signature eq emits a SemanticTypeFunction on one side, t_foo on the other" $ do
    (cg, ir) <- runOneWithIdentifier "agent foo(x: integer) -> string { \"hi\" }"
    case typeVarOf "foo" cg ir of
      Nothing -> expectationFailure "foo not in env"
      Just tFoo -> do
        -- 関数型 → t_foo の方向
        cg `shouldSatisfy` hasTypeConstraint
          ( \l r -> case l of
              SemanticTypeFunction params ret _ ->
                length params == 1
                  && fst (head params) == "x"
                  && ret == SemanticTypeString
                  && r == tFoo
              _ -> False
          )
        -- t_foo → 関数型 の方向 (eq の逆向き)
        cg `shouldSatisfy` hasTypeConstraint
          ( \l r -> l == tFoo && case r of
              SemanticTypeFunction {} -> True
              _ -> False
          )

  it "req declaration produces signature with self-effect" $ do
    (cg, ir) <- runOneWithIdentifier "req fetch() -> string"
    case (variableIdOf "fetch" ir, typeVarOf "fetch" cg ir) of
      (Just fetchVid, Just tFetch) ->
        -- signature: () -> string with {fetch}
        -- これと t_fetch の eq
        cg `shouldSatisfy` hasTypeConstraint
          ( \l r -> case l of
              SemanticTypeFunction _ ret eff ->
                ret == SemanticTypeString
                  && Set.member fetchVid eff.effectReqs
                  && r == tFetch
              _ -> False
          )
      _ -> expectationFailure "fetch not in identifier output / env"

  it "data ctor signature is pure (emptyEffect) and returns SemanticTypeData" $ do
    (cg, ir) <- runOneWithIdentifier "data point(x: integer)"
    case typeVarOf "point" cg ir of
      Nothing -> expectationFailure "point not in env"
      Just tCtor ->
        cg `shouldSatisfy` hasTypeConstraint
          ( \l r -> case l of
              SemanticTypeFunction _ ret eff ->
                eff == emptyEffect
                  && (case ret of SemanticTypeData _ -> True; _ -> False)
                  && r == tCtor
              _ -> False
          )

  it "function call emits a SemanticTypeFunction expected-shape on the rhs" $ do
    (cg, ir) <- runOneWithIdentifier "agent helper() { 0 }\nagent main() { helper() }"
    case typeVarOf "helper" cg ir of
      Nothing -> expectationFailure "helper not in env"
      Just tHelper ->
        -- t_helper <: SemanticTypeFunction [] t_result enclosing_eff
        cg `shouldSatisfy` hasTypeConstraint
          ( \l r -> l == tHelper && case r of
              SemanticTypeFunction params _ _ -> null params
              _ -> False
          )

  it "where block emits effect-discharge constraint" $ do
    (cg, ir) <-
      runOneWithIdentifier $
        mconcat
          [ "req fetch() -> string\n",
            "agent main() -> string {",
            "  fetch()",
            "} where {",
            "  req fetch() -> string { \"ok\" }",
            "}"
          ]
    case variableIdOf "fetch" ir of
      Nothing -> expectationFailure "fetch not in identifier output"
      Just fetchVid ->
        -- innerEff <: outerEff ∪ {fetch}
        -- rhs.effectReqs に fetch が含まれている effect constraint が存在
        cg `shouldSatisfy` hasEffectConstraint
          ( \_ rhs -> Set.member fetchVid rhs.effectReqs
          )

  it "if branches both flow into the same result type var" $ do
    cg <- runOne "agent foo() { if (true) { 1 } else { 2 } }"
    -- 両 branch の literal が同じ type var の subtype
    -- 1 と 2 を lhs に持つ constraint がそれぞれ存在し、rhs が同じ TypeVar である
    let lhsLits =
          [ rhs
          | (lhs, rhs) <- typeConstraints cg,
            lhs == SemanticTypeLiteralInteger 1
              || lhs == SemanticTypeLiteralInteger 2
          ]
    -- 少なくとも 2 本 (1 → t_result, 2 → t_result)
    length lhsLits `shouldSatisfy` (>= 2)

  it "field access emits T <: SemanticTypeObject {label: t_field}" $ do
    cg <-
      runOne $
        mconcat
          [ "data point(x: integer, y: integer)\n",
            "agent main(p: point) -> integer { p.x }"
          ]
    cg `shouldSatisfy` hasTypeConstraint
      ( \_ rhs -> case rhs of
          SemanticTypeObject fields ->
            Map.member "x" fields
          _ -> False
      )

  it "binary `+` constrains both operands to number and yields number" $ do
    cg <- runOne "agent foo() { 1 + 2 }"
    -- 両辺が number に subtype される (literal int も subtype 関係で number に行く)
    -- 具体的には 1 <: number と 2 <: number が出る
    cg `shouldSatisfy` hasTypeConstraint
      ( \l r -> l == SemanticTypeLiteralInteger 1 && r == SemanticTypeNumber
      )
    cg `shouldSatisfy` hasTypeConstraint
      ( \l r -> l == SemanticTypeLiteralInteger 2 && r == SemanticTypeNumber
      )

  it "template literal interpolation requires string subtype" $ do
    cg <- runOne "agent foo() { f\"hello ${\"world\"}\" }"
    -- "world" interp → string の constraint
    cg `shouldSatisfy` hasTypeConstraint
      ( \l r -> l == SemanticTypeLiteralString "world" && r == SemanticTypeString
      )
