module Katari.ZonkerSpec (spec) where

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.AST
import Katari.Lexer qualified as Lexer
import Katari.Parser qualified as Parser
import Katari.SemanticType
  ( RequestVariableId (..),
    Resolved,
    SemanticRequest (..),
    SemanticRequestElement (..),
    SemanticType (..),
    TypeVariableId (..),
  )
import Katari.Typechecker.ConstraintGenerator
  ( ConstraintGenResult (..),
    VariableSupply (..),
    generateConstraints,
  )
import Katari.Id (RequestId, VariableId)
import Katari.Typechecker.Identifier
  ( IdentifierResult (..),
    RequestData,
    VariableData (..),
    identify,
  )
import Katari.Typechecker.Identifier qualified as Identifier
import Katari.Typechecker.NormalizedType
  ( ArraySlot (..),
    FunctionShape (..),
    FunctionSlot (..),
    LayeredType (..),
    NormalizedType (..),
    NumberSlot (..),
    ObjectSlot (..),
    StringSlot (..),
    denormalise,
    emptyLayered,
  )
import Katari.Typechecker.Solver (SolverResult (..))
import Katari.Typechecker.Zonker
  ( ZonkError (..),
    ZonkResult (..),
    zonk,
  )
import Katari.Compile qualified as Compile
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Pipeline helpers
-- ---------------------------------------------------------------------------

-- | Run parser → identify → constraint-gen on a single-module program.
-- Aborts the spec if parse / identify fails.
pipeline :: Text -> IO (IdentifierResult, ConstraintGenResult)
pipeline src =
  let (stream, _) = Lexer.lex "<test>" src
      (parsed, parseErrors) = Parser.parse "<test>" stream
  in case parseErrors of
    (_:_) -> fail ("parse failure: " ++ show parseErrors)
    [] -> case Compile.identifyWithStdlib (Map.singleton "main" parsed) of
      (idResult, []) -> let (cg, _) = generateConstraints idResult in pure (idResult, cg)
      (_, errs) -> fail ("identify failure: " ++ show errs)

-- | Build a 'SolverResult' that satisfies the Solver totality contract for the
-- given 'ConstraintGenResult'. Every TypeVariableId / RequestVariableId allocated by
-- constraint generation receives a default (NormalizedTypeUnknown / empty req-set) entry,
-- which can be overridden by the user-supplied lists.
mkTotalSolverResult ::
  ConstraintGenResult ->
  [(TypeVariableId, NormalizedType)] ->
  [(RequestVariableId, Set RequestId)] ->
  SolverResult
mkTotalSolverResult cg typeOverrides requestOverrides =
  SolverResult
    { typeSubstitution =
        Map.fromList typeOverrides
          `Map.union` Map.fromList [(TypeVariableId i, NormalizedTypeUnknown) | i <- [0 .. cg.variableSupply.typeVarSupply - 1]],
      requestSubstitution =
        Map.fromList requestOverrides
          `Map.union` Map.fromList [(RequestVariableId i, Set.empty) | i <- [0 .. cg.variableSupply.requestVarSupply - 1]]
    }

-- | Build a Solver result that *deliberately leaves entries missing*. Used to
-- exercise the defensive Zonker fallback path.
mkPartialSolverResult ::
  [(TypeVariableId, NormalizedType)] ->
  [(RequestVariableId, Set RequestId)] ->
  SolverResult
mkPartialSolverResult ts es =
  SolverResult
    { typeSubstitution = Map.fromList ts,
      requestSubstitution = Map.fromList es
    }

-- | Run zonker end-to-end with a totalised SolverResult.
runZonkTotal :: Text -> IO (ZonkResult, [ZonkError])
runZonkTotal src = do
  (idResult, cg) <- pipeline src
  pure (zonk idResult cg (mkTotalSolverResult cg [] []))

-- | Find the VariableId for a named binding.
variableIdOf :: Text -> IdentifierResult -> Maybe VariableId
variableIdOf name result =
  fst <$> find ((== name) . (.variableName) . snd) (Map.toList result.identifiedVariables)

-- | Collect all expression metadata 'SemanticType Resolved' values reachable
-- from a Zonked module body. Used to spot-check inferred types.
expressionTypes :: Module Zonked -> [SemanticType Resolved]
expressionTypes m = concatMap declTypes m.declarations
  where
    declTypes = \case
      DeclarationAgent decl -> blockTypes decl.body
      _ -> []

    blockTypes blk =
      concatMap stmtTypes blk.statements
        ++ maybe [] exprTypes blk.returnExpression

    stmtTypes = \case
      StatementExpression e -> exprTypes e
      StatementLet s -> exprTypes s.value
      StatementReturn s -> exprTypes s.value
      StatementBreak s -> exprTypes s.value
      StatementNext s -> exprTypes s.value
      _ -> []

    exprTypes e =
      typeOfExpression e : case e of
        ExpressionTuple t -> concatMap exprTypes t.elements
        ExpressionArray a -> concatMap exprTypes a.elements
        ExpressionCall c -> exprTypes c.callee ++ concatMap (exprTypes . (.value)) c.arguments
        ExpressionBinaryOperator b -> exprTypes b.left ++ exprTypes b.right
        ExpressionUnaryOperator u -> exprTypes u.operand
        ExpressionIf i ->
          exprTypes i.condition
            ++ blockTypes i.thenBlock
            ++ maybe [] blockTypes i.elseBlock
        ExpressionMatch mexpr ->
          exprTypes mexpr.subject
            ++ concatMap (blockTypes . (.body)) mexpr.cases
        ExpressionFor f ->
          concatMap (exprTypes . (.source)) f.inBindings
            ++ concatMap (exprTypes . (.initial)) f.varBindings
            ++ blockTypes f.body
            ++ maybe [] blockTypes f.thenBlock
        ExpressionBlock b -> blockTypes b.block
        ExpressionFieldAccess fa -> exprTypes fa.object
        ExpressionIndexAccess ix -> exprTypes ix.array ++ exprTypes ix.index
        _ -> []

typeOfExpression :: Expression Zonked -> SemanticType Resolved
typeOfExpression = \case
  ExpressionLiteral x -> x.typeOf
  ExpressionVariable x -> x.typeOf
  ExpressionTuple x -> x.typeOf
  ExpressionArray x -> x.typeOf
  ExpressionCall x -> x.typeOf
  ExpressionBinaryOperator x -> x.typeOf
  ExpressionUnaryOperator x -> x.typeOf
  ExpressionIf x -> x.typeOf
  ExpressionMatch x -> x.typeOf
  ExpressionFor x -> x.typeOf
  ExpressionBlock x -> x.typeOf
  ExpressionFieldAccess x -> x.typeOf
  ExpressionIndexAccess x -> x.typeOf
  ExpressionTemplate x -> x.typeOf
  ExpressionHandle x -> x.typeOf
  ExpressionParTuple x -> x.typeOf
  ExpressionParArray x -> x.typeOf
  ExpressionQualifiedReference x -> x.typeOf

-- | Extract the head module from a 'ZonkResult' (single-module pipelines).
soleModule :: ZonkResult -> Module Zonked
soleModule zr = head (Map.elems zr.zonkedModules)

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "Katari.Typechecker.Zonker" $ do
    denormaliseUnit
    basicZonk
    typeVarSubstitution
    requestSubstitutionSpec
    typeEnvironmentZonk
    contractInvariant
    defensiveFallback

-- ---------------------------------------------------------------------------
-- Unit tests for denormalise
-- ---------------------------------------------------------------------------

denormaliseUnit :: Spec
denormaliseUnit = describe "denormalise" $ do
  it "NormalizedTypeUnknown → SemanticTypeUnknown" $
    denormalise NormalizedTypeUnknown `shouldBe` SemanticTypeUnknown

  it "NormalizedTypeLayered emptyLayered → SemanticTypeNever" $
    denormalise (NormalizedTypeLayered emptyLayered) `shouldBe` SemanticTypeNever

  it "single-branch layered (integer) → SemanticTypeInteger" $
    denormalise (NormalizedTypeLayered emptyLayered {numberLayer = NumberSlotInteger})
      `shouldBe` SemanticTypeInteger

  it "single literal integer" $
    denormalise (NormalizedTypeLayered emptyLayered {numberLayer = NumberSlotLiterals (Set.singleton 42)})
      `shouldBe` SemanticTypeLiteralInteger 42

  it "string any" $
    denormalise (NormalizedTypeLayered emptyLayered {stringLayer = StringSlotAny})
      `shouldBe` SemanticTypeString

  it "boolean both → SemanticTypeBoolean" $
    denormalise (NormalizedTypeLayered emptyLayered {booleanLayer = Set.fromList [True, False]})
      `shouldBe` SemanticTypeBoolean

  it "boolean single literal" $
    denormalise (NormalizedTypeLayered emptyLayered {booleanLayer = Set.singleton True})
      `shouldBe` SemanticTypeLiteralBoolean True

  it "null layer" $
    denormalise (NormalizedTypeLayered emptyLayered {nullLayer = True}) `shouldBe` SemanticTypeNull

  it "multi-layer union → SemanticTypeUnion" $
    denormalise (NormalizedTypeLayered emptyLayered {numberLayer = NumberSlotInteger, stringLayer = StringSlotAny})
      `shouldBe` SemanticTypeUnion [SemanticTypeInteger, SemanticTypeString]

  it "array of integer" $
    denormalise (NormalizedTypeLayered emptyLayered {arrayLayer = ArraySlotOf (NormalizedTypeLayered emptyLayered {numberLayer = NumberSlotInteger})})
      `shouldBe` SemanticTypeArray SemanticTypeInteger

  it "object with one field" $
    denormalise
      ( NormalizedTypeLayered
          emptyLayered
            { objectLayer =
                ObjectSlotOf
                  ( Map.singleton
                      "x"
                      (NormalizedTypeLayered emptyLayered {numberLayer = NumberSlotInteger})
                  )
            }
      )
      `shouldBe` SemanticTypeObject (Map.singleton "x" SemanticTypeInteger)

  it "function: integer -> string" $
    denormalise
      ( NormalizedTypeLayered
          emptyLayered
            { functionLayer =
                FunctionSlotOf
                  FunctionShape
                    { parameters =
                        Map.singleton
                          "x"
                          (NormalizedTypeLayered emptyLayered {numberLayer = NumberSlotInteger}),
                      returnType = NormalizedTypeLayered emptyLayered {stringLayer = StringSlotAny},
                      requests = Set.empty
                    }
            }
      )
      `shouldBe` SemanticTypeFunction
        (Map.singleton "x" SemanticTypeInteger)
        SemanticTypeString
        (SemanticRequest Set.empty)

-- ---------------------------------------------------------------------------
-- Basic zonk: literal expressions don't depend on substitution
-- ---------------------------------------------------------------------------

basicZonk :: Spec
basicZonk = describe "basic zonk" $ do
  it "literal integer expression keeps its concrete type" $ do
    (zr, zonkErrs) <- runZonkTotal "agent foo() { 42 }"
    -- 42 のリテラル expression に対応する metadata が SemanticTypeLiteralInteger 42
    let mod_ = soleModule zr
    SemanticTypeLiteralInteger 42 `elem` expressionTypes mod_ `shouldBe` True

  it "string literal expression keeps its concrete type" $ do
    (zr, zonkErrs) <- runZonkTotal "agent foo() { \"hello\" }"
    let mod_ = soleModule zr
    SemanticTypeLiteralString "hello" `elem` expressionTypes mod_ `shouldBe` True

  it "Identifier ids carry through Zonked AST" $ do
    -- foo の VariableId が ZonkedVariable に乗ってきて、id が一致している。
    (idResult, cg) <- pipeline "agent foo() { 0 }"
    let (zr, _zonkErrs) = zonk idResult cg (mkTotalSolverResult cg [] [])
        mainModule = soleModule zr
        Just fooVid = variableIdOf "foo" idResult
        names = [decl.name | DeclarationAgent decl <- mainModule.declarations]
        fooMeta = head [ref.resolution | ref <- names, ref.text == "foo"]
    fooMeta `shouldBe` Just fooVid

-- ---------------------------------------------------------------------------
-- TypeVar substitution
-- ---------------------------------------------------------------------------

typeVarSubstitution :: Spec
typeVarSubstitution = describe "type var substitution" $ do
  it "agent body expression-level type var resolves to integer" $ do
    -- agent foo() { 0 } では body の return-flow に t_body 型変数があり、
    -- それを NumberSlotInteger に解決すると call expression の metadata も integer になる。
    (idResult, cg) <- pipeline "agent foo() { foo() }"
    -- 全 TypeVar を NumberSlotInteger に統一して埋める
    let allInt =
          [ (TypeVariableId i, NormalizedTypeLayered emptyLayered {numberLayer = NumberSlotInteger})
            | i <- [0 .. cg.variableSupply.typeVarSupply - 1]
          ]
        (zr, _zonkErrs) = zonk idResult cg (mkTotalSolverResult cg allInt [])
        mod_ = soleModule zr
    -- expression 由来の metadata は全て SemanticTypeInteger に解決される
    -- (ただし Constructor 由来の literal e.g. SemanticTypeLiteralInteger は常駐)
    all (\t -> t == SemanticTypeInteger || isLiteralOrConcrete t) (expressionTypes mod_)
      `shouldBe` True

-- | Concrete primitive / literal types that don't go through substitution.
isLiteralOrConcrete :: SemanticType Resolved -> Bool
isLiteralOrConcrete = \case
  SemanticTypeLiteralInteger _ -> True
  SemanticTypeLiteralString _ -> True
  SemanticTypeLiteralBoolean _ -> True
  SemanticTypeNull -> True
  SemanticTypeInteger -> True
  SemanticTypeNumber -> True
  SemanticTypeString -> True
  SemanticTypeBoolean -> True
  _ -> False

-- ---------------------------------------------------------------------------
-- Request substitution
-- ---------------------------------------------------------------------------

requestSubstitutionSpec :: Spec
requestSubstitutionSpec = describe "request substitution" $ do
  it "function NormalizedType denormalises into SemanticTypeFunction with concrete request set" $ do
    -- Solver の役割を手動でシミュレートする: app の TypeVar に
    -- 「fetch を request として持つ関数」を表す NormalizedType を当てる。
    -- 結果として zonkedTypeEnvironment[app] が SemanticTypeFunction で、
    -- requestVars = empty、requestReqs ⊇ {fetch} になることを確認。
    let src = "req fetch() -> string\nagent app() { 0 }"
    (idResult, cg) <- pipeline src
    let Just fetchVid = variableIdOf "fetch" idResult
        Just appVid = variableIdOf "app" idResult
        Just (SemanticTypeVariable tApp) = Map.lookup appVid cg.typeEnvironment
        fetchReqId = head [rid | (rid, rd) <- Map.toList idResult.identifiedRequests, rd.requestVariableId == fetchVid]
        appFnNT =
          NormalizedTypeLayered
            emptyLayered
              { functionLayer =
                  FunctionSlotOf
                    FunctionShape
                      { parameters = Map.empty,
                        returnType =
                          NormalizedTypeLayered
                            emptyLayered {numberLayer = NumberSlotLiterals (Set.singleton 0)},
                        requests = Set.singleton fetchReqId
                      }
              }
        (zr, zonkErrs) = zonk idResult cg (mkTotalSolverResult cg [(tApp, appFnNT)] [])
    case Map.lookup appVid zr.zonkedTypeEnvironment of
      Just (SemanticTypeFunction _ _ eff) ->
        eff `shouldBe` SemanticRequest (Set.singleton (SemanticRequestElementConcrete fetchReqId))
      other -> expectationFailure ("app not bound to function type: " ++ show other)
    zonkErrs `shouldBe` []

-- ---------------------------------------------------------------------------
-- typeEnvironment zonk
-- ---------------------------------------------------------------------------

typeEnvironmentZonk :: Spec
typeEnvironmentZonk = describe "type environment zonk" $ do
  it "zonkedTypeEnvironment contains entry for every identifier variable" $ do
    (idResult, cg) <- pipeline "agent foo() { 0 }"
    let (zr, _zonkErrs) = zonk idResult cg (mkTotalSolverResult cg [] [])
    Map.keysSet zr.zonkedTypeEnvironment
      `shouldBe` Map.keysSet idResult.identifiedVariables

  it "every entry has a Resolved (no SemanticTypeVariable) type" $ do
    -- SemanticTypeVariable は Resolved phase では型レベルで構築不能なので、
    -- 型がついていれば自動的に保証されるが、念のため Show 文字列に
    -- "SemanticTypeVariable" が含まれていないことを spot check。
    (zr, zonkErrs) <- runZonkTotal "agent foo() { 0 }"
    let strs = map show (Map.elems zr.zonkedTypeEnvironment)
    any (\s -> "SemanticTypeVariable" `elem` words s) strs `shouldBe` False

-- ---------------------------------------------------------------------------
-- Contract invariant: total Solver → no zonkErrors
-- ---------------------------------------------------------------------------

contractInvariant :: Spec
contractInvariant = describe "Solver totality invariant" $ do
  it "totalised Solver result yields empty zonkErrors (basic)" $ do
    (zr, zonkErrs) <- runZonkTotal "agent foo() { 42 }"
    zonkErrs `shouldBe` []

  it "totalised Solver result yields empty zonkErrors (handler / handle)" $ do
    (_zr, zonkErrs) <-
      runZonkTotal $
        mconcat
          [ "req ping() -> integer\n",
            "agent app() {\n",
            "  handle {\n",
            "    req ping() { 1 }\n",
            "  }\n",
            "  ping()\n",
            "}"
          ]
    zonkErrs `shouldBe` []

-- ---------------------------------------------------------------------------
-- Defensive fallback: missing entries still produce a Zonked AST
-- ---------------------------------------------------------------------------

defensiveFallback :: Spec
defensiveFallback = describe "defensive fallback for Solver bug" $ do
  it "missing TypeVar entry: ZonkErrorMissingTypeVar is recorded and node defaults to Unknown" $ do
    (idResult, cg) <- pipeline "agent foo() { foo() }"
    -- 完全に空の substitution → 全 TypeVar が miss
    let (zr, zonkErrs) = zonk idResult cg (mkPartialSolverResult [] [])
    -- 少なくとも 1 つは ZonkErrorMissingTypeVar が出る
    any isMissingTypeVar zonkErrs `shouldBe` True
    -- AST 自体は生成されている。stdlib の 'prim' モジュールが
    -- 'Compile.identifyWithStdlib' により追加されるので、ユーザ "main"
    -- とあわせて 2 つ。
    Map.size zr.zonkedModules `shouldBe` 2
  where
    isMissingTypeVar = \case
      ZonkErrorMissingTypeVar _ _ -> True
      _ -> False
