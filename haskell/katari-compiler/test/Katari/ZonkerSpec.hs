module Katari.ZonkerSpec (spec) where

import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.AST
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
    FunctionShape (..),
    FunctionSignature (..),
    LayeredType (..),
    NormalizedType (..),
    NumberSlot (..),
    ObjectSlot (..),
    StringSlot (..),
    denormalise,
    emptyLayered,
  )
import Katari.Typechecker.SemanticType
  ( EffectVarId (..),
    Resolved,
    SemanticEffect (..),
    SemanticType (..),
    TypeVarId (..),
  )
import Katari.Typechecker.Solver (SolverResult (..))
import Katari.Typechecker.Zonker
  ( ZonkError (..),
    ZonkResult (..),
    Zonked (..),
    zonk,
  )
import Test.Hspec

-- ---------------------------------------------------------------------------
-- Pipeline helpers
-- ---------------------------------------------------------------------------

-- | Run parser → identify → constraint-gen on a single-module program.
-- Aborts the spec if parse / identify fails.
pipeline :: Text -> IO (IdentifierResult, ConstraintGenResult)
pipeline src = case parseModuleStrict "<test>" src of
  Left errs -> fail ("parse failure: " ++ show (map show errs))
  Right parsed -> case identify (Map.singleton "main" parsed) of
    (idResult, []) -> pure (idResult, generateConstraints idResult)
    (_, errs) -> fail ("identify failure: " ++ show errs)

-- | Build a 'SolverResult' that satisfies the Solver totality contract for the
-- given 'ConstraintGenResult'. Every TypeVarId / EffectVarId allocated by
-- constraint generation receives a default (NTUnknown / empty req-set) entry,
-- which can be overridden by the user-supplied lists.
mkTotalSolverResult ::
  ConstraintGenResult ->
  [(TypeVarId, NormalizedType)] ->
  [(EffectVarId, Set VariableId)] ->
  SolverResult
mkTotalSolverResult cg typeOverrides effectOverrides =
  SolverResult
    { typeSubstitution =
        Map.fromList typeOverrides
          `Map.union` Map.fromList [(TypeVarId i, NTUnknown) | i <- [0 .. cg.nextTypeVarId - 1]],
      effectSubstitution =
        Map.fromList effectOverrides
          `Map.union` Map.fromList [(EffectVarId i, Set.empty) | i <- [0 .. cg.nextEffectVarId - 1]],
      solverErrors = []
    }

-- | Build a Solver result that *deliberately leaves entries missing*. Used to
-- exercise the defensive Zonker fallback path.
mkPartialSolverResult ::
  [(TypeVarId, NormalizedType)] ->
  [(EffectVarId, Set VariableId)] ->
  SolverResult
mkPartialSolverResult ts es =
  SolverResult
    { typeSubstitution = Map.fromList ts,
      effectSubstitution = Map.fromList es,
      solverErrors = []
    }

-- | Run zonker end-to-end with a totalised SolverResult.
runZonkTotal :: Text -> IO ZonkResult
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
        ++ maybe [] whereTypes blk.whereBlock

    whereTypes wb =
      concatMap (exprTypes . (.initial)) wb.stateVariables
        ++ concatMap (blockTypes . (.body)) wb.handlers

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
typeOfExpression e = case metadataOf e of
  ZonkedExpression t -> t
  where
    metadataOf = \case
      ExpressionLiteral x -> x.metadata
      ExpressionVariable x -> x.metadata
      ExpressionTuple x -> x.metadata
      ExpressionArray x -> x.metadata
      ExpressionCall x -> x.metadata
      ExpressionBinaryOperator x -> x.metadata
      ExpressionUnaryOperator x -> x.metadata
      ExpressionIf x -> x.metadata
      ExpressionMatch x -> x.metadata
      ExpressionFor x -> x.metadata
      ExpressionBlock x -> x.metadata
      ExpressionFieldAccess x -> x.metadata
      ExpressionIndexAccess x -> x.metadata
      ExpressionTemplate x -> x.metadata
      ExpressionQualifiedReference x -> x.metadata

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
    effectSubstitutionSpec
    typeEnvironmentZonk
    contractInvariant
    defensiveFallback

-- ---------------------------------------------------------------------------
-- Unit tests for denormalise
-- ---------------------------------------------------------------------------

denormaliseUnit :: Spec
denormaliseUnit = describe "denormalise" $ do
  it "NTUnknown → SemanticTypeUnknown" $
    denormalise NTUnknown `shouldBe` SemanticTypeUnknown

  it "NTLayered emptyLayered → SemanticTypeNever" $
    denormalise (NTLayered emptyLayered) `shouldBe` SemanticTypeNever

  it "single-branch layered (integer) → SemanticTypeInteger" $
    denormalise (NTLayered emptyLayered {numberLayer = NumberInteger})
      `shouldBe` SemanticTypeInteger

  it "single literal integer" $
    denormalise (NTLayered emptyLayered {numberLayer = NumberLiterals (Set.singleton 42)})
      `shouldBe` SemanticTypeLiteralInteger 42

  it "string any" $
    denormalise (NTLayered emptyLayered {stringLayer = StringAny})
      `shouldBe` SemanticTypeString

  it "boolean both → SemanticTypeBoolean" $
    denormalise (NTLayered emptyLayered {booleanLayer = Set.fromList [True, False]})
      `shouldBe` SemanticTypeBoolean

  it "boolean single literal" $
    denormalise (NTLayered emptyLayered {booleanLayer = Set.singleton True})
      `shouldBe` SemanticTypeLiteralBoolean True

  it "null layer" $
    denormalise (NTLayered emptyLayered {nullLayer = True}) `shouldBe` SemanticTypeNull

  it "multi-layer union → SemanticTypeUnion" $
    denormalise (NTLayered emptyLayered {numberLayer = NumberInteger, stringLayer = StringAny})
      `shouldBe` SemanticTypeUnion [SemanticTypeInteger, SemanticTypeString]

  it "array of integer" $
    denormalise (NTLayered emptyLayered {arrayLayer = ArrayOf (NTLayered emptyLayered {numberLayer = NumberInteger})})
      `shouldBe` SemanticTypeArray SemanticTypeInteger

  it "object with one field" $
    denormalise
      ( NTLayered
          emptyLayered
            { objectLayer =
                ObjectOf
                  ( Map.singleton
                      "x"
                      (NTLayered emptyLayered {numberLayer = NumberInteger})
                  )
            }
      )
      `shouldBe` SemanticTypeObject (Map.singleton "x" SemanticTypeInteger)

  it "function: integer -> string" $
    denormalise
      ( NTLayered
          emptyLayered
            { functionLayer =
                Map.singleton
                  (FunctionSignature ["x"])
                  FunctionShape
                    { parameterTypes = [NTLayered emptyLayered {numberLayer = NumberInteger}],
                      returnType = NTLayered emptyLayered {stringLayer = StringAny},
                      effects = Set.empty
                    }
            }
      )
      `shouldBe` SemanticTypeFunction
        [("x", SemanticTypeInteger)]
        SemanticTypeString
        (SemanticEffect Set.empty Set.empty)

-- ---------------------------------------------------------------------------
-- Basic zonk: literal expressions don't depend on substitution
-- ---------------------------------------------------------------------------

basicZonk :: Spec
basicZonk = describe "basic zonk" $ do
  it "literal integer expression keeps its concrete type" $ do
    zr <- runZonkTotal "agent foo() { 42 }"
    -- 42 のリテラル expression に対応する metadata が SemanticTypeLiteralInteger 42
    let mod_ = soleModule zr
    SemanticTypeLiteralInteger 42 `elem` expressionTypes mod_ `shouldBe` True

  it "string literal expression keeps its concrete type" $ do
    zr <- runZonkTotal "agent foo() { \"hello\" }"
    let mod_ = soleModule zr
    SemanticTypeLiteralString "hello" `elem` expressionTypes mod_ `shouldBe` True

  it "Identifier ids carry through Zonked AST" $ do
    -- foo の VariableId が ZonkedVariable に乗ってきて、id が一致している。
    (idResult, cg) <- pipeline "agent foo() { 0 }"
    let zr = zonk idResult cg (mkTotalSolverResult cg [] [])
        mainModule = soleModule zr
        Just fooVid = variableIdOf "foo" idResult
        names = [decl.name | DeclarationAgent decl <- mainModule.declarations]
        fooMeta = head [ref.metadata | ref <- names, ref.text == "foo"]
    fooMeta `shouldBe` ZonkedVariable fooVid

-- ---------------------------------------------------------------------------
-- TypeVar substitution
-- ---------------------------------------------------------------------------

typeVarSubstitution :: Spec
typeVarSubstitution = describe "type var substitution" $ do
  it "agent body expression-level type var resolves to integer" $ do
    -- agent foo() { 0 } では body の return-flow に t_body 型変数があり、
    -- それを NumberInteger に解決すると call expression の metadata も integer になる。
    (idResult, cg) <- pipeline "agent foo() { foo() }"
    -- 全 TypeVar を NumberInteger に統一して埋める
    let allInt =
          [ (TypeVarId i, NTLayered emptyLayered {numberLayer = NumberInteger})
            | i <- [0 .. cg.nextTypeVarId - 1]
          ]
        zr = zonk idResult cg (mkTotalSolverResult cg allInt [])
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
-- Effect substitution
-- ---------------------------------------------------------------------------

effectSubstitutionSpec :: Spec
effectSubstitutionSpec = describe "effect substitution" $ do
  it "function NormalizedType denormalises into SemanticTypeFunction with concrete request set" $ do
    -- Solver の役割を手動でシミュレートする: app の TypeVar に
    -- 「fetch を effect として持つ関数」を表す NormalizedType を当てる。
    -- 結果として zonkedTypeEnvironment[app] が SemanticTypeFunction で、
    -- effectVars = empty、effectReqs ⊇ {fetch} になることを確認。
    let src = "req fetch() -> string\nagent app() { 0 }"
    (idResult, cg) <- pipeline src
    let Just fetchVid = variableIdOf "fetch" idResult
        Just appVid = variableIdOf "app" idResult
        Just (SemanticTypeVariable tApp) = Map.lookup appVid cg.typeEnvironment
        appFnNT =
          NTLayered
            emptyLayered
              { functionLayer =
                  Map.singleton
                    (FunctionSignature [])
                    FunctionShape
                      { parameterTypes = [],
                        returnType =
                          NTLayered
                            emptyLayered {numberLayer = NumberLiterals (Set.singleton 0)},
                        effects = Set.singleton fetchVid
                      }
              }
        zr = zonk idResult cg (mkTotalSolverResult cg [(tApp, appFnNT)] [])
    case Map.lookup appVid zr.zonkedTypeEnvironment of
      Just (SemanticTypeFunction _ _ eff) -> do
        eff.effectVars `shouldBe` Set.empty
        eff.effectReqs `shouldBe` Set.singleton fetchVid
      other -> expectationFailure ("app not bound to function type: " ++ show other)
    zr.zonkErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- typeEnvironment zonk
-- ---------------------------------------------------------------------------

typeEnvironmentZonk :: Spec
typeEnvironmentZonk = describe "type environment zonk" $ do
  it "zonkedTypeEnvironment contains entry for every identifier variable" $ do
    (idResult, cg) <- pipeline "agent foo() { 0 }"
    let zr = zonk idResult cg (mkTotalSolverResult cg [] [])
    Map.keysSet zr.zonkedTypeEnvironment
      `shouldBe` Map.keysSet idResult.identifiedVariables

  it "every entry has a Resolved (no SemanticTypeVariable) type" $ do
    -- SemanticTypeVariable は Resolved phase では型レベルで構築不能なので、
    -- 型がついていれば自動的に保証されるが、念のため Show 文字列に
    -- "SemanticTypeVariable" が含まれていないことを spot check。
    zr <- runZonkTotal "agent foo() { 0 }"
    let strs = map show (Map.elems zr.zonkedTypeEnvironment)
    any (\s -> "SemanticTypeVariable" `elem` words s) strs `shouldBe` False

-- ---------------------------------------------------------------------------
-- Contract invariant: total Solver → no zonkErrors
-- ---------------------------------------------------------------------------

contractInvariant :: Spec
contractInvariant = describe "Solver totality invariant" $ do
  it "totalised Solver result yields empty zonkErrors (basic)" $ do
    zr <- runZonkTotal "agent foo() { 42 }"
    zr.zonkErrors `shouldBe` []

  it "totalised Solver result yields empty zonkErrors (handler / where)" $ do
    zr <-
      runZonkTotal $
        mconcat
          [ "req ping() -> integer\n",
            "agent app() {\n",
            "  ping()\n",
            "} where {\n",
            "  req ping() { 1 }\n",
            "}"
          ]
    zr.zonkErrors `shouldBe` []

-- ---------------------------------------------------------------------------
-- Defensive fallback: missing entries still produce a Zonked AST
-- ---------------------------------------------------------------------------

defensiveFallback :: Spec
defensiveFallback = describe "defensive fallback for Solver bug" $ do
  it "missing TypeVar entry: ZonkErrorMissingTypeVar is recorded and node defaults to Unknown" $ do
    (idResult, cg) <- pipeline "agent foo() { foo() }"
    -- 完全に空の substitution → 全 TypeVar が miss
    let zr = zonk idResult cg (mkPartialSolverResult [] [])
    -- 少なくとも 1 つは ZonkErrorMissingTypeVar が出る
    any isMissingTypeVar zr.zonkErrors `shouldBe` True
    -- AST 自体は生成されている
    Map.size zr.zonkedModules `shouldBe` 1
  where
    isMissingTypeVar = \case
      ZonkErrorMissingTypeVar _ _ -> True
      _ -> False
