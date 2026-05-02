module Katari.ConstraintGeneratorSpec (spec) where

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Id (QualifiedName (QualifiedName))
import Katari.Lexer qualified as Lexer
import Katari.Parser qualified as Parser
import Katari.SemanticType
import Katari.Typechecker.ConstraintGenerator
import Katari.Typechecker.Identifier
  ( IdentifierResult (..),
    RequestData (RequestData),
    RequestId,
    TypeData (..),
    TypeId,
    VariableData (..),
    VariableId,
    identify,
  )
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

-- | Parse, identify, and run constraint generation on a single module named
-- "main". Aborts the spec if parse or identify fails.
-- Returns (ConstraintGenResult, [ConstraintError]).
runOne :: Text -> IO (ConstraintGenResult, [ConstraintError])
runOne src = (\(cg, errs, _) -> (cg, errs)) <$> runOneWithIdentifier src

-- | Same as 'runOne' but also returns the underlying 'IdentifierResult' so
-- tests can look up VariableIds by source name.
runOneWithIdentifier :: Text -> IO (ConstraintGenResult, [ConstraintError], IdentifierResult)
runOneWithIdentifier src =
  let (stream, _) = Lexer.lex "<test>" src
      (parsed, parseErrors) = Parser.parse "<test>" stream
  in case parseErrors of
    (_:_) -> fail ("parse failure: " ++ show parseErrors)
    [] -> case identify (Map.singleton "main" parsed) of
      (result, []) ->
        let (cg, errs) = generateConstraints result
         in pure (cg, errs, result)
      (_, errs) -> fail ("identify failure: " ++ show errs)

countTypeConstraints :: ConstraintGenResult -> Int
countTypeConstraints result =
  length [() | TypeConstraint {} <- Set.toList result.constraints]

countRequestConstraints :: ConstraintGenResult -> Int
countRequestConstraints result =
  length [() | RequestConstraint {} <- Set.toList result.constraints]

typeConstraints :: ConstraintGenResult -> [(SemanticType Unresolved, SemanticType Unresolved)]
typeConstraints result =
  [(lhs, rhs) | TypeConstraint {typeLhs = lhs, typeRhs = rhs} <- Set.toList result.constraints]

requestConstraints ::
  ConstraintGenResult ->
  [(SemanticRequest Unresolved, SemanticRequest Unresolved)]
requestConstraints result =
  [(lhs, rhs) | RequestConstraint {requestLhs = lhs, requestRhs = rhs} <- Set.toList result.constraints]

-- | Find the VariableId for a given source name.
variableIdOf :: Text -> IdentifierResult -> Maybe VariableId
variableIdOf name result =
  fst <$> find ((== name) . (.variableName) . snd) (Map.toList result.identifiedVariables)

-- | Look up the 'RequestId' that corresponds to a given call-side
-- 'VariableId'. Used to populate request-set assertions in tests where the
-- request lookup is keyed by request id.
requestIdOfVariable :: VariableId -> IdentifierResult -> RequestId
requestIdOfVariable vid result =
  head
    [ rid
      | (rid, rd) <- Map.toList result.identifiedRequests,
        requestVariableIdOf rd == vid
    ]
  where
    requestVariableIdOf :: RequestData -> VariableId
    requestVariableIdOf (RequestData _ _ v _) = v

-- | Lookup the type variable assigned to a named variable.
typeVarOf :: Text -> ConstraintGenResult -> IdentifierResult -> Maybe (SemanticType Unresolved)
typeVarOf name cg ir = variableIdOf name ir >>= \vid -> Map.lookup vid cg.typeEnvironment

-- | True if any type constraint has the given lhs.
hasTypeConstraintLhs ::
  SemanticType Unresolved ->
  ConstraintGenResult ->
  Bool
hasTypeConstraintLhs target cg = any (\(lhs, _) -> lhs == target) (typeConstraints cg)

-- | True if some constraint matches the given (lhs, rhs) predicate.
hasTypeConstraint ::
  (SemanticType Unresolved -> SemanticType Unresolved -> Bool) ->
  ConstraintGenResult ->
  Bool
hasTypeConstraint p cg = any (uncurry p) (typeConstraints cg)

-- | True if some request constraint matches the predicate.
hasRequestConstraint ::
  (SemanticRequest Unresolved -> SemanticRequest Unresolved -> Bool) ->
  ConstraintGenResult ->
  Bool
hasRequestConstraint p cg = any (uncurry p) (requestConstraints cg)

-- | Extract concrete RequestId elements from a SemanticRequest.
concreteRequests :: SemanticRequest phase -> Set.Set RequestId
concreteRequests (SemanticRequest elements) =
  Set.fromList [r | SemanticRequestElementConcrete r <- Set.toList elements]

-- | Extract RequestVariableId elements from an Unresolved SemanticRequest.
variableRequests :: SemanticRequest Unresolved -> Set.Set RequestVariableId
variableRequests (SemanticRequest elements) =
  Set.fromList [v | SemanticRequestElementVariable v <- Set.toList elements]

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
  exitStatementBlocks
  typeSynonymCycle
  constraintContents
  dataNameClash
  implicitReturnReason

-- ---------------------------------------------------------------------------
-- Basic agent
-- ---------------------------------------------------------------------------

basicAgent :: Spec
basicAgent = describe "basic agent" $ do
  it "agent foo() { 0 } produces some constraints and no errors" $ do
    (cg, errors) <- runOne "agent foo() { 0 }"
    errors `shouldBe` []
    countTypeConstraints cg `shouldSatisfy` (> 0)

  it "agent with annotated return type generates eq constraint" $ do
    (cg, errors) <- runOne "agent foo() -> integer { 0 }"
    errors `shouldBe` []
    -- agent signature と t_foo の eq constraint (= subtype 2 本) が含まれる
    countTypeConstraints cg `shouldSatisfy` (>= 2)

  it "agent with no return / no requests: both inferred (no errors)" $ do
    (_, errors) <- runOne "agent foo() { 0 }"
    errors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Multiple modules: same VariableId → same TypeVar
-- ---------------------------------------------------------------------------

multipleModules :: Spec
multipleModules = describe "multiple modules" $ do
  it "imported variable shares the type var of its origin" $ do
    let lib = "agent helper() { 0 }"
        main_ = "import { helper } from lib\nagent run() { helper() }"
        (libStream, _) = Lexer.lex "<test>" lib
        (libMod, libErrors) = Parser.parse "<test>" libStream
        (mainStream, _) = Lexer.lex "<test>" main_
        (mainMod, mainErrors) = Parser.parse "<test>" mainStream
    case libErrors ++ mainErrors of
      (_:_) -> expectationFailure ("parse: " ++ show (libErrors ++ mainErrors))
      [] -> case identify (Map.fromList [("lib", libMod), ("main", mainMod)]) of
        (_, e : es) -> expectationFailure ("identify errors: " ++ show (e : es))
        (result, []) -> do
          let (cg, cgErrors) = generateConstraints result
          cgErrors `shouldBe` []
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
    (cg, errors) <- runOne "agent foo(x: integer) { 0 }"
    errors `shouldBe` []
    -- Eq generates 2 subtype constraints. Plus the agent signature eq (2),
    -- the body return-flow constraint (1), the return-annotation eq (2),
    -- and the request bound. So we expect a healthy non-zero number.
    countTypeConstraints cg `shouldSatisfy` (> 0)

  it "unannotated parameter does not create extra type constraint per pattern" $ do
    (cg1, _) <- runOne "agent foo(x: integer) { 0 }"
    (cg2, _) <- runOne "agent foo(x) { 0 }"
    -- The annotated one should have at least 2 more type constraints (the
    -- extra eq introduced by the pattern annotation).
    countTypeConstraints cg1 `shouldSatisfy` (>= countTypeConstraints cg2 + 2)

-- ---------------------------------------------------------------------------
-- Declarations: data ctor, req, ext-agent
-- ---------------------------------------------------------------------------

declarations :: Spec
declarations = describe "declarations" $ do
  it "data constructor signature is pure (no requests)" $ do
    (cg, errors) <- runOne "data foo(x: integer)\nagent main() { foo(x = 1) }"
    errors `shouldBe` []
    -- We don't introspect specific constraints here; just check no errors and
    -- some constraints emitted.
    countTypeConstraints cg `shouldSatisfy` (> 0)

  it "req declaration emits eq constraint" $ do
    (cg, errors) <- runOne "req foo(x: integer) -> string"
    errors `shouldBe` []
    countTypeConstraints cg `shouldSatisfy` (>= 2) -- eq = 2 subtype
  it "ext-agent emits eq constraint (requests from with clause)" $ do
    (cg, errors) <- runOne "req bar(x: integer) -> string\n@\"svc\"\next agent foo() -> integer with bar"
    errors `shouldBe` []
    countTypeConstraints cg `shouldSatisfy` (>= 2)

-- ---------------------------------------------------------------------------
-- Call expressions: request constraint propagation
-- ---------------------------------------------------------------------------

callExpressions :: Spec
callExpressions = describe "call expressions" $ do
  it "agent calling another agent generates a call constraint" $ do
    (cg, errors) <- runOne "agent helper() { 0 }\nagent main() { helper() }"
    errors `shouldBe` []
    -- Request constraint(s) for the body request bound + call propagation
    countRequestConstraints cg `shouldSatisfy` (> 0)

-- ---------------------------------------------------------------------------
-- Constructor pattern (reverse-call)
-- ---------------------------------------------------------------------------

constructorPatterns :: Spec
constructorPatterns = describe "constructor patterns" $ do
  it "match on data ctor pattern emits constraint without TypeData lookup" $ do
    (_, errors) <-
      runOne $
        mconcat
          [ "data circle(r: integer)\n",
            "agent main(x: circle) {",
            "  match (x) {",
            "    case circle(r = v) => { v }",
            "  }",
            "}"
          ]
    errors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Where blocks (request discharge)
-- ---------------------------------------------------------------------------

whereBlocks :: Spec
whereBlocks = describe "where blocks" $ do
  it "where block discharges its handled reqs" $ do
    (cg, errors) <-
      runOne $
        mconcat
          [ "req fetch() -> string\n",
            "agent main() -> string {",
            "  fetch()",
            "} where {",
            "  req fetch() -> string { \"ok\" }",
            "}"
          ]
    errors `shouldBe` []
    -- Request constraints include the discharge: inner_eff <: outer ∪ {fetch}
    countRequestConstraints cg `shouldSatisfy` (> 0)

  it "req handler with request annotation is rejected by parser" $ do
    let (stream, _) = Lexer.lex "<test>" $
          mconcat
            [ "req fetch() -> string\n",
              "agent main() -> string {",
              "  fetch()",
              "} where {",
              "  req fetch() -> string with bar { \"ok\" }",
              "}"
            ]
        (_, parseErrors) = Parser.parse "<test>" stream
    case parseErrors of
      (_:_) -> pure () -- parse error expected
      [] -> expectationFailure "expected parse failure for handler with-clause"

  it "handler break value flows to a type variable (handle-result)" $ do
    (cg, errors) <-
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
    errors `shouldBe` []
    -- break "boom" should emit a constraint with lhs = literal "boom"
    -- targeting some type variable (the handle-result tv).
    cg
      `shouldSatisfy` hasTypeConstraint
        ( \l r ->
            l == SemanticTypeLiteralString "boom" && case r of
              SemanticTypeVariable _ -> True
              _ -> False
        )

  it "handler next value flows to a type variable (handler return / next-tv)" $ do
    (cg, errors) <-
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
    errors `shouldBe` []
    cg
      `shouldSatisfy` hasTypeConstraint
        ( \l r ->
            l == SemanticTypeLiteralString "resumed" && case r of
              SemanticTypeVariable _ -> True
              _ -> False
        )

  it "where: body tail value flows into the handle-result tv" $ do
    -- The body's tail expression "hello" flows into the where-block's
    -- whole-result type variable.
    (cg, errors) <-
      runOne $
        mconcat
          [ "req fetch() -> string\n",
            "agent main() -> string { \"hello\" } where {\n",
            "  req fetch() -> string {\n",
            "    next \"x\"\n",
            "  }\n",
            "}\n"
          ]
    errors `shouldBe` []
    cg
      `shouldSatisfy` hasTypeConstraint
        ( \l r ->
            l == SemanticTypeLiteralString "hello" && case r of
              SemanticTypeVariable _ -> True
              _ -> False
        )

  it "handler implicit completion: body tail flows to whole-block tv (implicit break)" $ do
    -- A handler body that falls through without explicit 'next' / 'break'
    -- is treated as an implicit 'break' (Koka-style algebraic requests). Its
    -- tail value flows to the where-containing block's whole type, NOT to
    -- the handler's declared return type.
    (cg, errors) <-
      runOne $
        mconcat
          [ "req fetch() -> string\n",
            "agent main() -> string { fetch() } where {\n",
            "  req fetch() -> string { \"implicit\" }\n",
            "}\n"
          ]
    errors `shouldBe` []
    cg
      `shouldSatisfy` hasTypeConstraint
        ( \l r ->
            l == SemanticTypeLiteralString "implicit" && case r of
              SemanticTypeVariable _ -> True
              _ -> False
        )

  it "where block emits a handler-request-bound constraint (e4 <: e1)" $ do
    -- In addition to the discharge constraint (e3 <: e1 ∪ e2), a where
    -- block emits an request-var <: request-var constraint bounding handler
    -- bodies' request by the outer request (e4 <: e1). Both lhs and rhs
    -- must have only requestVars populated and requestReqs empty.
    (cg, errors) <-
      runOne $
        mconcat
          [ "req fetch() -> string\n",
            "agent main() -> string { fetch() } where {\n",
            "  req fetch() -> string {\n",
            "    next \"x\"\n",
            "  }\n",
            "}\n"
          ]
    errors `shouldBe` []
    cg
      `shouldSatisfy` hasRequestConstraint
        ( \lhs rhs ->
            Set.null (concreteRequests lhs)
              && Set.null (concreteRequests rhs)
              && not (Set.null (variableRequests lhs))
              && not (Set.null (variableRequests rhs))
        )

  it "block without where emits only the agent's bodyEff <: declared constraint" $ do
    -- A plain block (no where) should not introduce extra request
    -- constraints of its own. The only request constraint the agent should
    -- produce is bodyEff <: declared, with both sides request-vars only
    -- (no req-id sets) since neither has a 'with' clause.
    (cg, errors) <- runOne "agent main() -> string { \"hi\" }\n"
    errors `shouldBe` []
    let effs = requestConstraints cg
    length effs `shouldBe` 1
    case effs of
      [(lhs, rhs)] -> do
        Set.null (concreteRequests lhs) `shouldBe` True
        Set.null (concreteRequests rhs) `shouldBe` True
        Set.size (variableRequests lhs) `shouldBe` 1
        Set.size (variableRequests rhs) `shouldBe` 1
      _ -> expectationFailure "expected exactly one request constraint"

-- ---------------------------------------------------------------------------
-- Blocks containing global-exit statements (return / next / break / ...)
-- have type 'never', so the implicit fall-through value never produces a
-- spurious null-flow constraint.
-- ---------------------------------------------------------------------------

exitStatementBlocks :: Spec
exitStatementBlocks = describe "exit-statement blocks" $ do
  it "handler body that always exits via 'next' yields no spurious null flow" $ do
    -- Before the never-typing fix, the handler's implicit completion would
    -- emit (null <: retTvId) because 'next \"x\"' is a statement and the
    -- block has no tail expression, leaving bodyTy = null. With the fix,
    -- bodyTy = never instead, so no such constraint should appear.
    (cg, errors) <-
      runOne $
        mconcat
          [ "req fetch() -> string\n",
            "agent main() -> string { fetch() } where {\n",
            "  req fetch() -> string {\n",
            "    next \"x\"\n",
            "  }\n",
            "}\n"
          ]
    errors `shouldBe` []
    cg
      `shouldSatisfy` not
        . hasTypeConstraint
          ( \l r ->
              l == SemanticTypeNull && case r of
                SemanticTypeVariable _ -> True
                _ -> False
          )

  it "if-then branch ending with 'return' contributes type never to the if result" $ do
    -- The then-branch is just 'return \"a\"', so walkBlock yields
    -- bodyTy = never for that branch, and walkIfExpr then emits
    -- (never <: tResult). The else branch contributes string. Together the
    -- if's result type stays string (never is bottom) — but we should see
    -- never as the lhs of some constraint.
    (cg, errors) <-
      runOne $
        mconcat
          [ "agent main() -> string {\n",
            "  if (true) {\n",
            "    return \"a\"\n",
            "  } else {\n",
            "    \"b\"\n",
            "  }\n",
            "}\n"
          ]
    errors `shouldBe` []
    cg `shouldSatisfy` hasTypeConstraintLhs SemanticTypeNever

  it "agent body whose only statement is 'return' types as never" $ do
    -- Body has a single 'return \"x\"' statement — no tail expression. With
    -- the never-typing fix, walkBlock returns SemanticTypeNever rather
    -- than SemanticTypeNull, so processAgentLike's
    -- (bodyType <: retTvId) constraint becomes never <: retTvId.
    (cg, errors) <-
      runOne $
        mconcat
          [ "agent main() -> string {\n",
            "  return \"x\"\n",
            "}\n"
          ]
    errors `shouldBe` []
    cg `shouldSatisfy` hasTypeConstraintLhs SemanticTypeNever

-- ---------------------------------------------------------------------------
-- Type synonym cycle detection
-- ---------------------------------------------------------------------------

typeSynonymCycle :: Spec
typeSynonymCycle = describe "type synonym cycle" $ do
  it "type T = T is detected as a cycle" $ do
    (_, errors) <- runOne "type T = T\nagent main(x: T) { 0 }"
    -- One ConstraintErrorTypeSynonymCycle expected (or more if T is referenced again).
    errors `shouldSatisfy` any isCycleError
  where
    isCycleError ConstraintErrorTypeSynonymCycle {} = True

-- ---------------------------------------------------------------------------
-- Constraint contents (verify shape, not just count)
-- ---------------------------------------------------------------------------

constraintContents :: Spec
constraintContents = describe "constraint contents" $ do
  it "literal int expression flows as SemanticTypeLiteralInteger" $ do
    (cg, _) <- runOne "agent foo() { 42 }"
    -- body の return statement constraint で lhs = SemanticTypeLiteralInteger 42
    cg `shouldSatisfy` hasTypeConstraintLhs (SemanticTypeLiteralInteger 42)

  it "literal string expression flows as SemanticTypeLiteralString" $ do
    (cg, _) <- runOne "agent foo() { \"hello\" }"
    cg `shouldSatisfy` hasTypeConstraintLhs (SemanticTypeLiteralString "hello")

  it "literal boolean expression flows as SemanticTypeLiteralBoolean" $ do
    (cg, _) <- runOne "agent foo() { true }"
    cg `shouldSatisfy` hasTypeConstraintLhs (SemanticTypeLiteralBoolean True)

  it "null expression flows as SemanticTypeNull" $ do
    (cg, _) <- runOne "agent foo() { null }"
    cg `shouldSatisfy` hasTypeConstraintLhs SemanticTypeNull

  it "annotated parameter emits both directions of eq with SemanticTypeInteger" $ do
    (cg, _, ir) <- runOneWithIdentifier "agent foo(x: integer) { 0 }"
    case typeVarOf "x" cg ir of
      Nothing -> expectationFailure "x not in env"
      Just tx -> do
        -- t_x <: integer  AND  integer <: t_x
        cg `shouldSatisfy` hasTypeConstraint (\l r -> l == tx && r == SemanticTypeInteger)
        cg `shouldSatisfy` hasTypeConstraint (\l r -> l == SemanticTypeInteger && r == tx)

  it "agent signature eq emits a SemanticTypeFunction on one side, t_foo on the other" $ do
    (cg, _, ir) <- runOneWithIdentifier "agent foo(x: integer) -> string { \"hi\" }"
    case typeVarOf "foo" cg ir of
      Nothing -> expectationFailure "foo not in env"
      Just tFoo -> do
        -- 関数型 → t_foo の方向
        cg
          `shouldSatisfy` hasTypeConstraint
            ( \l r -> case l of
                SemanticTypeFunction params ret _ ->
                  Map.keys params == ["x"]
                    && ret == SemanticTypeString
                    && r == tFoo
                _ -> False
            )
        -- t_foo → 関数型 の方向 (eq の逆向き)
        cg
          `shouldSatisfy` hasTypeConstraint
            ( \l r ->
                l == tFoo && case r of
                  SemanticTypeFunction {} -> True
                  _ -> False
            )

  it "req declaration produces signature with self-request" $ do
    (cg, _, ir) <- runOneWithIdentifier "req fetch() -> string"
    case (variableIdOf "fetch" ir, typeVarOf "fetch" cg ir) of
      (Just fetchVid, Just tFetch) ->
        let fetchReqId = requestIdOfVariable fetchVid ir
         in cg
              `shouldSatisfy` hasTypeConstraint
                ( \l r -> case l of
                    SemanticTypeFunction _ ret eff ->
                      ret == SemanticTypeString
                        && Set.member fetchReqId (concreteRequests eff)
                        && r == tFetch
                    _ -> False
                )
      _ -> expectationFailure "fetch not in identifier output / env"

  it "data ctor signature is pure (emptyRequest) and returns SemanticTypeData" $ do
    (cg, _, ir) <- runOneWithIdentifier "data point(x: integer)"
    case typeVarOf "point" cg ir of
      Nothing -> expectationFailure "point not in env"
      Just tCtor ->
        cg
          `shouldSatisfy` hasTypeConstraint
            ( \l r -> case l of
                SemanticTypeFunction _ ret eff ->
                  eff == emptyRequest
                    && (case ret of SemanticTypeData _ -> True; _ -> False)
                    && r == tCtor
                _ -> False
            )

  it "function call emits a SemanticTypeFunction expected-shape on the rhs" $ do
    (cg, _, ir) <- runOneWithIdentifier "agent helper() { 0 }\nagent main() { helper() }"
    case typeVarOf "helper" cg ir of
      Nothing -> expectationFailure "helper not in env"
      Just tHelper ->
        -- t_helper <: SemanticTypeFunction [] t_result enclosing_eff
        cg
          `shouldSatisfy` hasTypeConstraint
            ( \l r ->
                l == tHelper && case r of
                  SemanticTypeFunction params _ _ -> null params
                  _ -> False
            )

  it "where block emits request-discharge constraint" $ do
    (cg, _, ir) <-
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
        -- rhs.requestReqs に fetch が含まれている request constraint が存在
        let fetchReqId = requestIdOfVariable fetchVid ir
         in cg
              `shouldSatisfy` hasRequestConstraint
                ( \_ rhs -> Set.member fetchReqId (concreteRequests rhs)
                )

  it "if branches both flow into the same result type var" $ do
    (cg, _) <- runOne "agent foo() { if (true) { 1 } else { 2 } }"
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
    (cg, _) <-
      runOne $
        mconcat
          [ "data point(x: integer, y: integer)\n",
            "agent main(p: point) -> integer { p.x }"
          ]
    cg
      `shouldSatisfy` hasTypeConstraint
        ( \_ rhs -> case rhs of
            SemanticTypeObject fields ->
              Map.member "x" fields
            _ -> False
        )

  it "binary `+` constrains both operands to number" $ do
    (cg, _) <- runOne "agent foo() { 1 + 2 }"
    -- 両オペランドは直接 number にサブタイプされる
    -- 1 <: number, 2 <: number
    cg
      `shouldSatisfy` hasTypeConstraint
        ( \l r -> l == SemanticTypeLiteralInteger 1 && r == SemanticTypeNumber
        )
    cg
      `shouldSatisfy` hasTypeConstraint
        ( \l r -> l == SemanticTypeLiteralInteger 2 && r == SemanticTypeNumber
        )

  it "template literal interpolation requires string subtype" $ do
    (cg, _) <- runOne "agent foo() { f\"hello ${\"world\"}\" }"
    -- "world" interp → string の constraint
    cg
      `shouldSatisfy` hasTypeConstraint
        ( \l r -> l == SemanticTypeLiteralString "world" && r == SemanticTypeString
        )

-- ---------------------------------------------------------------------------
-- Cross-module same-named `data` declarations should produce distinct TypeIds
-- on each constructor signature. Pre-refactor, ConstraintGenerator's text-based
-- TypeId lookup collided across modules and silently fell back to
-- SemanticTypeUnknown for both.
-- ---------------------------------------------------------------------------

dataNameClash :: Spec
dataNameClash = describe "cross-module data name clash" $ do
  it "two modules each declaring `data foo` produce distinct SemanticTypeData TypeIds" $ do
    let modA = "data foo(x: integer)\nagent runA() { foo(x = 1) }"
        modB = "data foo(y: string)\nagent runB() { foo(y = \"a\") }"
        (streamA, _) = Lexer.lex "<test>" modA
        (parsedA, errorsA) = Parser.parse "<test>" streamA
        (streamB, _) = Lexer.lex "<test>" modB
        (parsedB, errorsB) = Parser.parse "<test>" streamB
    case errorsA ++ errorsB of
      (_:_) -> expectationFailure ("parse: " ++ show (errorsA ++ errorsB))
      [] ->
        case identify (Map.fromList [("a", parsedA), ("b", parsedB)]) of
          (_, e : es) -> expectationFailure ("identify errors: " ++ show (e : es))
          (result, []) -> do
            let (cg, cgErrors) = generateConstraints result
            cgErrors `shouldBe` []
            -- 各モジュールの "foo" type に発行された TypeId を集める。
            let fooTypeIds =
                  [ tid
                    | (tid, td) <- Map.toList result.identifiedTypes,
                      typeNameOf td == "foo"
                  ]
            length fooTypeIds `shouldBe` 2
            -- どちらの TypeId も SemanticTypeData として制約に出現するはず。
            -- (リファクタ前は両方が SemanticTypeUnknown に degrade していた)
            let usedTids = Set.fromList (concatMap (collectDataTids . snd) (typeConstraints cg))
            (head fooTypeIds `Set.member` usedTids) `shouldBe` True
            (fooTypeIds !! 1 `Set.member` usedTids) `shouldBe` True
  where
    -- Bare name extracted from the qualified name (TypeData no longer
    -- carries a separate @typeName@ field).
    typeNameOf :: TypeData -> Text
    typeNameOf td = case td.typeQualifiedName of
      QualifiedName _ n -> n
    collectDataTids :: SemanticType Unresolved -> [TypeId]
    collectDataTids = \case
      SemanticTypeData tid -> [tid]
      SemanticTypeFunction params returnType _ ->
        concatMap collectDataTids (Map.elems params) <> collectDataTids returnType
      SemanticTypeArray elementType -> collectDataTids elementType
      SemanticTypeTuple elementTypes -> concatMap collectDataTids elementTypes
      SemanticTypeUnion branches -> concatMap collectDataTids branches
      SemanticTypeObject fields -> concatMap collectDataTids (Map.elems fields)
      _ -> []

-- ---------------------------------------------------------------------------
-- Implicit-return constraint reason: agent body fall-through (no explicit
-- 'return') uses ReasonKindImplicitReturn, while explicit 'return e' uses
-- ReasonKindReturnStatement.
-- ---------------------------------------------------------------------------

implicitReturnReason :: Spec
implicitReturnReason = describe "ReasonKindImplicitReturn vs ReasonKindReturnStatement" $ do
  it "agent body fall-through tags constraint with ReasonKindImplicitReturn" $ do
    (cg, errors) <- runOne "agent foo() -> integer { 1 }"
    errors `shouldBe` []
    let reasons = [r | TypeConstraint {reason = r} <- Set.toList cg.constraints]
    any isImplicitReturn reasons `shouldBe` True

  it "explicit return statement tags constraint with ReasonKindReturnStatement" $ do
    (cg, errors) <- runOne "agent foo() -> integer { return 1; }"
    errors `shouldBe` []
    let reasons = [r | TypeConstraint {reason = r} <- Set.toList cg.constraints]
    any isReturnStatement reasons `shouldBe` True
  where
    isImplicitReturn reason = reason.kind == ReasonKindImplicitReturn
    isReturnStatement reason = reason.kind == ReasonKindReturnStatement
