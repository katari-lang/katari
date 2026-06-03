module Katari.ConstraintGeneratorSpec (spec) where

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Compile qualified as Compile
import Katari.Diagnostic (Diagnostic, hasErrors)
import Katari.TestSupport qualified as TestSupport
import Katari.Id
  ( QualifiedName (..),
    VariableResolution (..),
  )
import Katari.Lexer qualified as Lexer
import Katari.Parser qualified as Parser
import Katari.SemanticType
import Katari.TestSupport (IdentifierResult (..))
import Katari.Typechecker.ConstraintGenerator
import Katari.Typechecker.Identifier
  ( SymbolEntry (..),
    VariableData (..),
  )
import Katari.Typechecker.ScopeIndex (ScopeFrame (..), ScopeIndex (..))
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
        (_ : _) -> fail ("parse failure: " ++ show parseErrors)
        [] -> case TestSupport.identifyWithStdlib (Map.singleton "main" parsed) of
          (result, []) ->
            let (cg, errs) = TestSupport.generateConstraintsAll result
             in pure (cg, errs, result)
          (_, errs) -> fail ("identify failure: " ++ show errs)

-- | Run the full compile pipeline (parse → identify → CG → solve → zonk →
-- lower) on a single "main" module and return all diagnostics. Unlike
-- 'runOne', this surfaces solver-level type errors (K0220, etc.) in
-- addition to CG errors.
compileOne :: Text -> IO [Diagnostic]
compileOne src =
  let entry = Compile.SourceEntry {filePath = "<test>", sourceText = src}
      input = Compile.CompileInput {sources = Map.singleton "main" entry, cache = Map.empty}
      result = TestSupport.compileSync input
   in pure result.diagnostics

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

-- | Find the VariableResolution for a named binding. Searches top-level
-- identifiedVariables first, then falls back to scanning the scopeIndex
-- for local variables (parameters, let bindings, match arm bindings).
variableResolutionOf :: Text -> IdentifierResult -> Maybe VariableResolution
variableResolutionOf name result =
  case ResolvedTopLevel . fst <$> find ((== name) . (.variableName) . snd) (Map.toList result.identifiedVariables) of
    Just resolution -> Just resolution
    Nothing ->
      -- Search all scope frames for a local variable with this name.
      let allFrames = concatMap snd (Map.toList result.scopeIndex.framesByFile)
          candidates = mapMaybe (\frame -> Map.lookup name frame.frameSymbols >>= (.variableSymbol)) allFrames
       in case candidates of
            (resolution : _) -> Just resolution
            [] -> Nothing

-- | Find the QualifiedName for a named request declaration.
requestQNameOf :: Text -> IdentifierResult -> Maybe QualifiedName
requestQNameOf name result =
  fst <$> find (\(qn, _) -> qn.name == name) (Map.toList result.identifiedRequests)

-- | Lookup the type variable assigned to a named variable.
typeVarOf :: Text -> ConstraintGenResult -> IdentifierResult -> Maybe (SemanticType Unresolved)
typeVarOf name cg ir = variableResolutionOf name ir >>= \vid -> Map.lookup vid cg.typeEnvironment

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

-- | Extract concrete QualifiedName elements from a SemanticRequest.
concreteRequests :: SemanticRequest phase -> Set.Set QualifiedName
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
  matchPatterns
  whereBlocks
  exitStatementBlocks
  typeSynonymCycle
  constraintContents
  dataNameClash
  implicitReturnReason
  crossShapeEdges
  objectTypeSyntax

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
      (_ : _) -> expectationFailure ("parse: " ++ show (libErrors ++ mainErrors))
      [] -> case TestSupport.identifyWithStdlib (Map.fromList [("lib", libMod), ("main", mainMod)]) of
        (_, e : es) -> expectationFailure ("identify errors: " ++ show (e : es))
        (result, []) -> do
          let (cg, cgErrors) = TestSupport.generateConstraintsAll result
          cgErrors `shouldBe` []
          -- 同じ helper VariableId に対して typeEnvironment に entry が一つだけ
          -- (= 同一 type var が両 module で参照されている)
          let helperEntry =
                find
                  ((== ("helper" :: Text)) . (.variableName) . snd)
                  (Map.toList result.identifiedVariables)
          case helperEntry of
            Just (qualifiedName, _) ->
              Map.member (ResolvedTopLevel qualifiedName) cg.typeEnvironment `shouldBe` True
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
-- Declarations: data ctor, request, ext-agent
-- ---------------------------------------------------------------------------

declarations :: Spec
declarations = describe "declarations" $ do
  it "data constructor signature is pure (no requests)" $ do
    (cg, errors) <- runOne "data foo(x: integer)\nagent main() { foo(x = 1) }"
    errors `shouldBe` []
    -- We don't introspect specific constraints here; just check no errors and
    -- some constraints emitted.
    countTypeConstraints cg `shouldSatisfy` (> 0)

  it "request declaration emits eq constraint" $ do
    (cg, errors) <- runOne "request foo(x: integer) -> string"
    errors `shouldBe` []
    countTypeConstraints cg `shouldSatisfy` (>= 2) -- eq = 2 subtype
  it "external-agent emits eq constraint (requests from with clause)" $ do
    (cg, errors) <- runOne "request bar(x: integer) -> string\n@\"svc\"\nexternal foo() -> integer with bar from \"FFI:lib.foo\""
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

matchPatterns :: Spec
matchPatterns = describe "match patterns" $ do
  it "variable pattern in match arm: bound variable is bound directly to the subject's type" $ do
    -- The pattern binding `y` ties directly to the subject `x`: they
    -- share the same SemanticType in the type environment. Earlier
    -- iterations emitted @x_type \<: y_type@ instead, which left
    -- @y_type@ stranded behind a type-variable indirection during
    -- bound aggregation and zonked to @unknown@. Binding @y_id@ to
    -- @x_type@ directly avoids that indirection.
    (cg, errors, ir) <-
      runOneWithIdentifier
        "agent foo(x: integer) -> integer { match (x) { case y => { y } } }"
    errors `shouldBe` []
    case (typeVarOf "x" cg ir, typeVarOf "y" cg ir) of
      (Just xType, Just yType) ->
        yType `shouldBe` xType
      _ -> expectationFailure "variables 'x' or 'y' not found"

  it "variable pattern: result-type annotation does not narrow the bound variable below the subject" $ do
    -- The solver must reject this: subject is number but return annotation is
    -- integer. The chain number <: y_type <: tMatch <: integer forces
    -- number <: integer which fails (K0220).
    diags <-
      compileOne
        "agent foo(x: number) -> integer { match (x) { case y => { y } } }"
    diags `shouldSatisfy` hasErrors

  it "tuple pattern: component type variables flow from the concrete tuple subject" $ do
    -- At CG time the subject `p` is a type variable p_type with eq constraint
    -- p_type = [integer, string]. projectTupleSubjectTypes cannot statically
    -- decompose a type variable, so we verify there are no type errors and
    -- that the overall result is well-formed (the e2e sample 10 covers the
    -- runtime behaviour more directly).
    (_, errors) <-
      runOne $
        mconcat
          [ "agent foo(p: [integer, string]) -> integer {\n",
            "  match (p) { case [a, b] => { 0 } }\n",
            "}"
          ]
    errors `shouldBe` []

  it "tuple pattern on union subject: only the tuple branch constraint, no type error" $ do
    -- subject: [integer, string] | boolean. The tuple arm [a, b] should not
    -- produce a type error even though the boolean branch cannot be a tuple.
    (_, errors) <-
      runOne $
        mconcat
          [ "agent foo(p: [integer, string] | boolean) {\n",
            "  match (p) {\n",
            "    case [a, b] => { 0 }\n",
            "    case _ => { 1 }\n",
            "  }\n",
            "}"
          ]
    errors `shouldBe` []

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
whereBlocks = describe "handle blocks" $ do
  it "handle block discharges its handled reqs" $ do
    (cg, errors) <-
      runOne $
        mconcat
          [ "request fetch() -> string\n",
            "agent main() -> string {\n",
            "  handle {\n",
            "    request fetch() -> string { \"ok\" }\n",
            "  }\n",
            "  fetch()\n",
            "}"
          ]
    errors `shouldBe` []
    -- Request constraints include the discharge: inner_eff <: outer ∪ {fetch}
    countRequestConstraints cg `shouldSatisfy` (> 0)

  it "request handler with request annotation is rejected by parser" $ do
    let (stream, _) =
          Lexer.lex "<test>" $
            mconcat
              [ "request fetch() -> string\n",
                "agent main() -> string {\n",
                "  handle {\n",
                "    request fetch() -> string with bar { \"ok\" }\n",
                "  }\n",
                "  fetch()\n",
                "}"
              ]
        (_, parseErrors) = Parser.parse "<test>" stream
    case parseErrors of
      (_ : _) -> pure () -- parse error expected
      [] -> expectationFailure "expected parse failure for handler with-clause"

  it "handler break value flows to a type variable (handle-result)" $ do
    (cg, errors) <-
      runOne $
        mconcat
          [ "request fetch() -> string\n",
            "agent main() -> string {\n",
            "  handle {\n",
            "    request fetch() -> string {\n",
            "      break \"boom\"\n",
            "    }\n",
            "  }\n",
            "  fetch()\n",
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
          [ "request fetch() -> string\n",
            "agent main() -> string {\n",
            "  handle {\n",
            "    request fetch() -> string {\n",
            "      next \"resumed\"\n",
            "    }\n",
            "  }\n",
            "  fetch()\n",
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

  it "handle: body tail value flows into the handle-result tv" $ do
    -- The body's tail expression "hello" flows into the handle-block's
    -- whole-result type variable.
    (cg, errors) <-
      runOne $
        mconcat
          [ "request fetch() -> string\n",
            "agent main() -> string {\n",
            "  handle {\n",
            "    request fetch() -> string {\n",
            "      next \"x\"\n",
            "    }\n",
            "  }\n",
            "  \"hello\"\n",
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

  it "handler body must end with break/next (never type) — explicit break passes" $ do
    -- A handler body's inferred type is constrained to 'never'. Falling
    -- through to a value would mean returning past the request handler
    -- frame with no continuation site, which is a type error. An explicit
    -- @break@ produces type 'never' and satisfies the constraint.
    (_cg, errors) <-
      runOne $
        mconcat
          [ "request fetch() -> string\n",
            "agent main() -> string {\n",
            "  handle {\n",
            "    request fetch() -> string { break \"explicit\"; }\n",
            "  }\n",
            "  fetch()\n",
            "}\n"
          ]
    errors `shouldBe` []

  it "handle block emits a handler-request-bound constraint (e4 <: e1)" $ do
    -- In addition to the discharge constraint (e3 <: e1 ∪ e2), a handle
    -- block emits an request-var <: request-var constraint bounding handler
    -- bodies' request by the outer request (e4 <: e1). Both lhs and rhs
    -- must have only requestVars populated and requestReqs empty.
    (cg, errors) <-
      runOne $
        mconcat
          [ "request fetch() -> string\n",
            "agent main() -> string {\n",
            "  handle {\n",
            "    request fetch() -> string {\n",
            "      next \"x\"\n",
            "    }\n",
            "  }\n",
            "  fetch()\n",
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
    -- (no request-id sets) since neither has a 'with' clause.
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
          [ "request fetch() -> string\n",
            "agent main() -> string {\n",
            "  handle {\n",
            "    request fetch() -> string {\n",
            "      next \"x\"\n",
            "    }\n",
            "  }\n",
            "  fetch()\n",
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

  it "request declaration produces signature with self-request" $ do
    (cg, _, ir) <- runOneWithIdentifier "request fetch() -> string"
    case (requestQNameOf "fetch" ir, typeVarOf "fetch" cg ir) of
      (Just fetchQName, Just tFetch) ->
        cg
          `shouldSatisfy` hasTypeConstraint
            ( \l r -> case l of
                SemanticTypeFunction _ ret eff ->
                  ret == SemanticTypeString
                    && Set.member fetchQName (concreteRequests eff)
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

  it "handle block emits request-discharge constraint" $ do
    (cg, _, ir) <-
      runOneWithIdentifier $
        mconcat
          [ "request fetch() -> string\n",
            "agent main() -> string {\n",
            "  handle {\n",
            "    request fetch() -> string { \"ok\" }\n",
            "  }\n",
            "  fetch()\n",
            "}"
          ]
    case requestQNameOf "fetch" ir of
      Nothing -> expectationFailure "fetch not in identifier output"
      Just fetchQName ->
        -- innerEff <: outerEff ∪ {fetch}
        -- rhs.requestReqs に fetch が含まれている request constraint が存在
        cg
          `shouldSatisfy` hasRequestConstraint
            ( \_ rhs -> Set.member fetchQName (concreteRequests rhs)
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

  it "template literal interpolation does not constrain operand type" $ do
    -- f-string interpolations accept any type; Lowering emits `format`
    -- on each interpolation before concatenation. No constraint is
    -- emitted between the interpolated value's type and 'String'.
    (cg, _) <- runOne "agent foo() { f\"hello ${42}\" }"
    cg
      `shouldNotSatisfy` hasTypeConstraint
        ( \l r -> l == SemanticTypeLiteralInteger 42 && r == SemanticTypeString
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
      (_ : _) -> expectationFailure ("parse: " ++ show (errorsA ++ errorsB))
      [] ->
        case TestSupport.identifyWithStdlib (Map.fromList [("a", parsedA), ("b", parsedB)]) of
          (_, e : es) -> expectationFailure ("identify errors: " ++ show (e : es))
          (result, []) -> do
            let (cg, cgErrors) = TestSupport.generateConstraintsAll result
            cgErrors `shouldBe` []
            -- 各モジュールの "foo" type に発行された QualifiedName を集める。
            let fooTypeQNames =
                  [ qualifiedName
                    | (qualifiedName, _td) <- Map.toList result.identifiedTypes,
                      qualifiedName.name == "foo"
                  ]
            length fooTypeQNames `shouldBe` 2
            -- どちらの QualifiedName も SemanticTypeData として制約に出現するはず。
            -- (リファクタ前は両方が SemanticTypeUnknown に degrade していた)
            let usedQNames = Set.fromList (concatMap (collectDataQNames . snd) (typeConstraints cg))
            (head fooTypeQNames `Set.member` usedQNames) `shouldBe` True
            (fooTypeQNames !! 1 `Set.member` usedQNames) `shouldBe` True
  where
    collectDataQNames :: SemanticType Unresolved -> [QualifiedName]
    collectDataQNames = \case
      SemanticTypeData qualifiedName -> [qualifiedName]
      SemanticTypeFunction params returnType _ ->
        concatMap (collectDataQNames . (.parameterType)) (Map.elems params) <> collectDataQNames returnType
      SemanticTypeArray elementType -> collectDataQNames elementType
      SemanticTypeTuple elementTypes -> concatMap collectDataQNames elementTypes
      SemanticTypeUnion branches -> concatMap collectDataQNames branches
      SemanticTypeObject fields -> concatMap collectDataQNames (Map.elems fields)
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

-- ---------------------------------------------------------------------------
-- Cross-shape subtype edges of the unified type lattice: a precise / nominal
-- type is a subtype of its more-general counterpart. Exercised end-to-end
-- through 'compileOne' (so the solver actually resolves the edge), using only
-- syntax that exists today: field access for `data <: object`, `record[T]`
-- for `data <: record`, and the `[a, b]` tuple syntax for `tuple <: array`.
-- ---------------------------------------------------------------------------

crossShapeEdges :: Spec
crossShapeEdges = describe "cross-shape subtype edges" $ do
  it "data <: object: field access on a data value yields its declared field type" $ do
    -- p.x demands point <: {x: t}; the data<:object edge expands point to its
    -- object view {x: integer, y: integer}, giving integer <: t, which matches
    -- the integer return annotation.
    diags <-
      compileOne
        "data point(x: integer, y: integer)\nagent main(p: point) -> integer { p.x }"
    diags `shouldNotSatisfy` hasErrors

  it "data <: object: a field's declared type must satisfy the demand (mismatch rejected)" $ do
    -- point.x is integer; the return annotation string forces integer <: string.
    diags <-
      compileOne
        "data point(x: integer, y: integer)\nagent main(p: point) -> string { p.x }"
    diags `shouldSatisfy` hasErrors

  it "data <: object: accessing a field the data lacks is a hard structural failure" $ do
    -- point has no `z`; point <: {z: t} must fail (a missing field is not
    -- padded to unknown).
    diags <-
      compileOne
        "data point(x: integer)\nagent main(p: point) -> integer { p.z }"
    diags `shouldSatisfy` hasErrors

  it "data <: record: every declared field must satisfy the record value bound" $ do
    diags <-
      compileOne
        "data pair(a: integer, b: integer)\nagent main(p: pair) -> record[integer] { p }"
    diags `shouldNotSatisfy` hasErrors

  it "data <: record: a field outside the record value bound is rejected" $ do
    -- pair.b is string, not <: integer.
    diags <-
      compileOne
        "data pair(a: integer, b: string)\nagent main(p: pair) -> record[integer] { p }"
    diags `shouldSatisfy` hasErrors

  it "tuple <: array: a tuple is usable as an array whose element covers all positions" $ do
    diags <-
      compileOne
        "agent main(t: [integer, string]) -> array[integer | string] { t }"
    diags `shouldNotSatisfy` hasErrors

  it "tuple <: array: a position outside the array element type is rejected" $ do
    -- the string position is not <: integer.
    diags <-
      compileOne
        "agent main(t: [integer, string]) -> array[integer] { t }"
    diags `shouldSatisfy` hasErrors

  it "array </: tuple: an array is not usable where a specific tuple is demanded" $ do
    diags <-
      compileOne
        "agent main(t: array[integer]) -> [integer, integer] { t }"
    diags `shouldSatisfy` hasErrors

-- ---------------------------------------------------------------------------
-- Object type syntax {label: T} and object-literal inference. An object
-- literal infers a precise object type (each field its own type); it is a
-- subtype of both a matching object type and a record[V] (object <: record).
-- ---------------------------------------------------------------------------

objectTypeSyntax :: Spec
objectTypeSyntax = describe "object type syntax" $ do
  it "field access through an object-typed parameter yields the field type" $ do
    diags <- compileOne "agent f(o: {x: integer}) -> integer { o.x }"
    diags `shouldNotSatisfy` hasErrors

  it "an object literal satisfies a matching object return type" $ do
    diags <- compileOne "agent f() -> {x: integer} { {x = 1} }"
    diags `shouldNotSatisfy` hasErrors

  it "extra fields on an object literal are accepted (width)" $ do
    diags <- compileOne "agent f() -> {x: integer} { {x = 1, y = \"hi\"} }"
    diags `shouldNotSatisfy` hasErrors

  it "an object literal widens to a record via object <: record" $ do
    diags <- compileOne "agent f() -> record[integer] { {x = 1, y = 2} }"
    diags `shouldNotSatisfy` hasErrors

  it "an object literal field type must satisfy the object annotation" $ do
    diags <- compileOne "agent f() -> {x: string} { {x = 1} }"
    diags `shouldSatisfy` hasErrors

  it "a missing field is rejected against an object type" $ do
    diags <- compileOne "agent f() -> {x: integer, y: integer} { {x = 1} }"
    diags `shouldSatisfy` hasErrors
