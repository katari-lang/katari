module Katari.Typechecker.CheckSpec (spec) where

import Data.Foldable (toList)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Environment (GenericParameterInformation (..), GenericParameters (..), RequestInformation (..), Scheme (..), ValueEnvironment, monoScheme)
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.Id (GenericId (..), LocalVariableId (..), TypeResolution (..), VariableResolution (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.NormalizedType
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SourceSpan (Located (..), Position (..), SourceSpan (..))
import Katari.Data.Variance (Variance (..))
import Katari.Diagnostics (Diagnostics)
import Katari.Error (CompilerError (..), typeErrorCode)
import Katari.Typechecker.Check
import Katari.Typechecker.Context
  ( Checker,
    CheckerEnvironment (..),
    ForContext (..),
    HandleContext (..),
    initialCheckerEnvironment,
    pushForContext,
    pushHandleContext,
    runChecker,
    runNormalizer,
    withEffectInference,
    withReturnTarget,
  )
import Katari.Typechecker.Elaborate (emptyContext)
import Katari.Typechecker.Environment (TypeEnvironment (..), emptyTypeEnvironment)
import Katari.Typechecker.Normalizer (joinAttribute, union)
import Test.Hspec

spec :: Spec
spec = do
  describe "synthExpressionType (literals)" $ do
    it "synthesizes an integer literal as integer" $
      synthAt (integerLiteral 42) `shouldBe` integerType
    it "synthesizes a number literal as number" $
      synthAt (numberLiteral 3.14) `shouldBe` numberType
    it "synthesizes a string literal as string" $
      synthAt (stringLiteral "hi") `shouldBe` stringType
    it "synthesizes a boolean literal as boolean" $
      synthAt (booleanLiteral True) `shouldBe` booleanType
    it "synthesizes a null literal as null" $
      synthAt nullLiteral `shouldBe` nullType

  describe "synthExpressionType (local variable)" $ do
    it "reads a bound local's type" $
      synthIn [(LocalVariableId 0, stringType)] (variableExpression (LocalVariableId 0)) `shouldBe` stringType
    it "reads a top-level value's scheme from the value environment" $
      let agentScheme = simpleScheme integerType
          environment = checkerEnvironmentWith mempty (Map.singleton topLevelName agentScheme)
          (result, _) = runChecker environment (synthExpressionType (qualifiedVariableExpression topLevelName))
       in result `shouldBe` integerType

  describe "synthExpressionType (tuple / record)" $ do
    it "tuple of [int, string] synthesizes to a sequence with two items and null tail" $
      synthAt (tupleExpression [integerLiteral 1, stringLiteral "a"])
        `shouldBe` tupleNormalized [integerType, stringType]
    it "record literal becomes an object with required fields and an unknown tail" $
      synthAt (recordExpression [("x", integerLiteral 1), ("y", booleanLiteral True)])
        `shouldBe` recordNormalized [("x", integerType), ("y", booleanType)]

  describe "synthExpressionType (if)" $ do
    it "if-then-else unions the branches" $
      synthAt (ifExpression (booleanLiteral True) [integerLiteral 1] (Just [stringLiteral "x"]))
        `shouldBe` unionOf integerType stringType
    it "if without else unions the then-branch with null" $
      synthAt (ifExpression (booleanLiteral True) [integerLiteral 1] Nothing)
        `shouldBe` unionOf integerType nullType
    it "rejects a non-boolean condition" $
      let (_, diagnostics) = runAt mempty mempty (synthExpressionType (ifExpression (integerLiteral 1) [nullLiteral] Nothing))
       in hasErrorCode "K3001" diagnostics `shouldBe` True

  describe "synthExpressionType (binary operators)" $ do
    it "integer + integer is integer" $
      synthAt (binaryExpression BinaryOperatorAdd (integerLiteral 1) (integerLiteral 2)) `shouldBe` integerType
    it "integer + number widens to number" $
      synthAt (binaryExpression BinaryOperatorAdd (integerLiteral 1) (numberLiteral 2.0)) `shouldBe` numberType
    it "divide returns number even for integer inputs" $
      synthAt (binaryExpression BinaryOperatorDivide (integerLiteral 4) (integerLiteral 2)) `shouldBe` numberType
    it "equality returns boolean for any pair (no constraint)" $
      synthAt (binaryExpression BinaryOperatorEqual (integerLiteral 1) (stringLiteral "x")) `shouldBe` booleanType
    it "less-than rejects a string operand" $
      let (_, diagnostics) = runAt mempty mempty (synthExpressionType (binaryExpression BinaryOperatorLessThan (integerLiteral 1) (stringLiteral "x")))
       in hasErrorCode "K3001" diagnostics `shouldBe` True
    it "and returns boolean for boolean pair" $
      synthAt (binaryExpression BinaryOperatorAnd (booleanLiteral True) (booleanLiteral False)) `shouldBe` booleanType
    it "concat returns string for string pair" $
      synthAt (binaryExpression BinaryOperatorConcat (stringLiteral "a") (stringLiteral "b")) `shouldBe` stringType

  describe "synthExpressionType (unary operators)" $ do
    it "not on a boolean returns boolean" $
      synthAt (unaryExpression UnaryOperatorNot (booleanLiteral True)) `shouldBe` booleanType
    it "negate on an integer returns integer" $
      synthAt (unaryExpression UnaryOperatorNegate (integerLiteral 1)) `shouldBe` integerType
    it "negate on a string is rejected" $
      let (_, diagnostics) = runAt mempty mempty (synthExpressionType (unaryExpression UnaryOperatorNegate (stringLiteral "x")))
       in hasErrorCode "K3001" diagnostics `shouldBe` True

  describe "synthExpressionType (let / block)" $ do
    it "let x = e brings x into scope for the return expression" $
      let block = blockExpression [letStatement (LocalVariableId 0) (integerLiteral 1)] (Just (variableExpression (LocalVariableId 0)))
       in synthAt block `shouldBe` integerType
    it "empty block returns null" $
      synthAt (blockExpression [] Nothing) `shouldBe` nullType
    it "bare expression statement does not leak its type" $
      let block = blockExpression [StatementExpression (integerLiteral 99)] (Just (stringLiteral "ok"))
       in synthAt block `shouldBe` stringType

  describe "checkExpression" $ do
    it "accepts an integer literal against integer" $
      let (_, diagnostics) = runAt mempty mempty (checkExpression (integerLiteral 1) integerType)
       in toList diagnostics `shouldBe` []
    it "rejects an integer literal against string" $
      let (_, diagnostics) = runAt mempty mempty (checkExpression (integerLiteral 1) stringType)
       in hasErrorCode "K3001" diagnostics `shouldBe` True
    it "accepts integer against number (subtype widening)" $
      let (_, diagnostics) = runAt mempty mempty (checkExpression (integerLiteral 1) numberType)
       in toList diagnostics `shouldBe` []

  describe "synthExpressionType (match)" $ do
    it "rejects a match on `unknown` without a wildcard case" $
      let scrutineeLocal = Map.singleton (LocalVariableId 0) (monoScheme unknownType)
          subject = variableExpression (LocalVariableId 0)
          matchExpr =
            matchExpression
              subject
              [(literalPattern (LiteralValueInteger 1), exprBlock (stringLiteral "ok"))]
          (_, diagnostics) = runAt scrutineeLocal mempty (synthExpressionType matchExpr)
       in hasErrorCode "K3001" diagnostics `shouldBe` True

    it "accepts a match on `unknown` with a wildcard case" $
      let scrutineeLocal = Map.singleton (LocalVariableId 0) (monoScheme unknownType)
          subject = variableExpression (LocalVariableId 0)
          matchExpr =
            matchExpression
              subject
              [(wildcardPattern, exprBlock (integerLiteral 1))]
          (result, diagnostics) = runAt scrutineeLocal mempty (synthExpressionType matchExpr)
       in (result, toList diagnostics) `shouldBe` (integerType, [])

    it "covers an integer scrutinee with literal cases (intentionally permissive)" $
      let scrutineeLocal = Map.singleton (LocalVariableId 0) (monoScheme integerType)
          subject = variableExpression (LocalVariableId 0)
          matchExpr =
            matchExpression
              subject
              [ (literalPattern (LiteralValueInteger 1), exprBlock (stringLiteral "one")),
                (literalPattern (LiteralValueInteger 2), exprBlock (stringLiteral "two"))
              ]
          (result, diagnostics) = runAt scrutineeLocal mempty (synthExpressionType matchExpr)
       in (result, toList diagnostics) `shouldBe` (stringType, [])

    it "narrows the binder's type inside a TypeFilter pattern" $
      let scrutineeLocal = Map.singleton (LocalVariableId 0) (monoScheme unknownType)
          subject = variableExpression (LocalVariableId 0)
          narrowed = typeFilterPattern integerAnnotation (variablePatternForLocal (LocalVariableId 1))
          matchExpr =
            matchExpression
              subject
              [ (narrowed, exprBlock (variableExpression (LocalVariableId 1))),
                (wildcardPattern, exprBlock (integerLiteral 0))
              ]
          (result, diagnostics) = runAt scrutineeLocal mempty (synthExpressionType matchExpr)
       in (result, toList diagnostics) `shouldBe` (integerType, [])

    it "unions the body types across cases" $
      let scrutineeLocal = Map.singleton (LocalVariableId 0) (monoScheme booleanType)
          subject = variableExpression (LocalVariableId 0)
          matchExpr =
            matchExpression
              subject
              [ (literalPattern (LiteralValueBoolean True), exprBlock (integerLiteral 1)),
                (literalPattern (LiteralValueBoolean False), exprBlock (stringLiteral "no"))
              ]
          (result, _) = runAt scrutineeLocal mempty (synthExpressionType matchExpr)
       in result `shouldBe` unionOf integerType stringType

  describe "let (annotation and destructuring)" $ do
    it "let x : integer = 1 binds x at integer" $
      let block =
            blockExpression
              [letStatementAnnotated (LocalVariableId 0) integerAnnotation (integerLiteral 1)]
              (Just (variableExpression (LocalVariableId 0)))
          (result, diagnostics) = runAt mempty mempty (synthExpressionType block)
       in (result, toList diagnostics) `shouldBe` (integerType, [])

    it "let x : integer = \"x\" is K3001" $
      let block =
            blockExpression
              [letStatementAnnotated (LocalVariableId 0) integerAnnotation (stringLiteral "x")]
              (Just (variableExpression (LocalVariableId 0)))
          (_, diagnostics) = runAt mempty mempty (synthExpressionType block)
       in hasErrorCode "K3001" diagnostics `shouldBe` True

    it "let (x, y) = (1, \"a\") binds x at integer and y at string" $
      let pair = tupleExpression [integerLiteral 1, stringLiteral "a"]
          pattern =
            tuplePattern
              [ variablePatternForLocal (LocalVariableId 0),
                variablePatternForLocal (LocalVariableId 1)
              ]
          block =
            blockExpression
              [letStatementWithPattern pattern pair]
              (Just (variableExpression (LocalVariableId 1)))
          (result, diagnostics) = runAt mempty mempty (synthExpressionType block)
       in (result, toList diagnostics) `shouldBe` (stringType, [])

  describe "effect aggregation (synthAgent)" $ do
    it "infers a pure (bottom) effect from a body with no calls" $
      let declaration =
            agentDeclarationWith
              []
              (Just integerAnnotation)
              Nothing
              False
              (bodyOf [] (Just (integerLiteral 1)))
          (result, _) = runAt mempty mempty (synthAgentType declaration)
       in extractAgentEffect result `shouldBe` bottomEffect

    it "aggregates a non-pure call's effect into the body's inferred effect" $
      let callableType = nonPureAgentType bottomAttribute (paramObject [("x", integerType)]) integerType
          callableLocal = Map.singleton (LocalVariableId 10) (monoScheme callableType)
          callExpr =
            callExpression
              (variableExpression (LocalVariableId 10))
              [("x", integerLiteral 1)]
          declaration =
            agentDeclarationWith
              []
              (Just integerAnnotation)
              Nothing
              False
              (bodyOf [] (Just callExpr))
          environment =
            (initialCheckerEnvironment emptyTypeEnvironment) {locals = callableLocal}
          (result, diagnostics) = runChecker environment (synthAgentType declaration)
          expectedEffect =
            NormalizedEffectRow
              EffectRow {request = Map.singleton fakeRequestName mempty, tails = mempty}
       in (extractAgentEffect result, toList diagnostics) `shouldBe` (expectedEffect, [])

    it "annotated effect `all` accepts a body with a smaller inferred effect" $
      let callableType = nonPureAgentType bottomAttribute (paramObject [("x", integerType)]) integerType
          callableLocal = Map.singleton (LocalVariableId 10) (monoScheme callableType)
          callExpr =
            callExpression
              (variableExpression (LocalVariableId 10))
              [("x", integerLiteral 1)]
          declaration =
            agentDeclarationWith
              []
              (Just integerAnnotation)
              (Just allEffectAnnotation)
              False
              (bodyOf [] (Just callExpr))
          environment =
            (initialCheckerEnvironment emptyTypeEnvironment) {locals = callableLocal}
          (result, diagnostics) = runChecker environment (synthAgentType declaration)
       in (extractAgentEffect result, toList diagnostics) `shouldBe` (NormalizedEffectAny, [])

    it "synthHandler does not emit any effect to the enclosing scope (handler is a value, not a call)" $
      let handlerExpr = handlerExpressionBuilder [integerAnnotation, allEffectAnnotation] [] Nothing
          action = withEffectInference (synthExpressionType handlerExpr)
          ((collectedEffect, _), diagnostics) = runAt mempty mempty action
       in (collectedEffect, toList diagnostics) `shouldBe` (bottomEffect, [])

  describe "synthAgent" $ do
    it "checks an annotated body against its return type and yields the matching scheme" $
      let declaration =
            agentDeclarationWith
              [paramBindingFor "x" (LocalVariableId 1) integerAnnotation]
              (Just integerAnnotation)
              Nothing
              False
              (bodyOf [] (Just (variableExpression (LocalVariableId 1))))
          expected = pureAgentType (paramObject [("x", integerType)]) integerType
          (result, diagnostics) = runAt mempty mempty (synthAgentType declaration)
       in (result, toList diagnostics) `shouldBe` (expected, [])

    it "infers the return type from the body when no return annotation is given" $
      let declaration =
            agentDeclarationWith
              [paramBindingFor "x" (LocalVariableId 1) integerAnnotation]
              Nothing
              Nothing
              False
              (bodyOf [] (Just (variableExpression (LocalVariableId 1))))
          expected = pureAgentType (paramObject [("x", integerType)]) integerType
          (result, diagnostics) = runAt mempty mempty (synthAgentType declaration)
       in (result, toList diagnostics) `shouldBe` (expected, [])

    it "annotated return that the body does not satisfy is K3001" $
      let declaration =
            agentDeclarationWith
              [paramBindingFor "x" (LocalVariableId 1) integerAnnotation]
              (Just stringAnnotation)
              Nothing
              False
              (bodyOf [] (Just (variableExpression (LocalVariableId 1))))
          (_, diagnostics) = runAt mempty mempty (synthAgentType declaration)
       in hasErrorCode "K3001" diagnostics `shouldBe` True

    it "a `private agent` declaration carries the private outer attribute" $
      let declaration =
            agentDeclarationWith
              [paramBindingFor "x" (LocalVariableId 1) integerAnnotation]
              (Just integerAnnotation)
              Nothing
              True
              (bodyOf [] (Just (variableExpression (LocalVariableId 1))))
          expected =
            agentNormalized
              privateAttribute
              (paramObject [("x", integerType)])
              integerType
              bottomEffect
          (result, diagnostics) = runAt mempty mempty (synthAgentType declaration)
       in (result, toList diagnostics) `shouldBe` (expected, [])

    it "a local agent declared inside a private world inherits the private outer attribute" $
      -- The agent itself is /not/ declared @private@; the closure world raises it.
      let declaration =
            agentDeclarationWith
              [paramBindingFor "x" (LocalVariableId 1) integerAnnotation]
              (Just integerAnnotation)
              Nothing
              False
              (bodyOf [] (Just (variableExpression (LocalVariableId 1))))
          expected =
            agentNormalized
              privateAttribute
              (paramObject [("x", integerType)])
              integerType
              bottomEffect
          (result, diagnostics) =
            runChecker
              (rebuildWithPrivateWorld (initialCheckerEnvironment emptyTypeEnvironment))
              (synthAgentType declaration)
       in (result, toList diagnostics) `shouldBe` (expected, [])

  describe "use statement" $ do
    it "use h type-checks against a properly-shaped provider's continuation" $
      let continuationAgent =
            layeredOf
              neverLayer
                { functionLayer =
                    Just
                      NormalizedFunction
                        { argumentType = recordNormalized [("value", integerType)],
                          returnType = stringType,
                          effect = NormalizedEffectAny
                        }
                }
          providerType =
            NormalizedType
              { baseType =
                  NormalizedBaseTypeLayered
                    neverLayer
                      { functionLayer =
                          Just
                            NormalizedFunction
                              { argumentType = recordNormalized [("continuation", continuationAgent)],
                                returnType = stringType,
                                effect = NormalizedEffectAny
                              }
                      },
                generics = mempty,
                attribute = bottomAttribute
              }
          providerLocal = Map.singleton (LocalVariableId 0) (monoScheme providerType)
          useStmt = useStatementBuilder (Just (LocalVariableId 1, integerAnnotation)) (variableExpression (LocalVariableId 0)) (exprBlock (stringLiteral "ok"))
          action = withReturnTarget stringType (walkStatements [useStmt] (pure ()))
          (_, diagnostics) = runAt providerLocal mempty action
       in toList diagnostics `shouldBe` []

    it "use body's effect must be a subtype of the provider's continuation expected effect" $
      let -- Provider whose continuation must be pure: continuation.effect = bottomEffect.
          pureContinuation =
            layeredOf
              neverLayer
                { functionLayer =
                    Just
                      NormalizedFunction
                        { argumentType = recordNormalized [("value", integerType)],
                          returnType = stringType,
                          effect = bottomEffect
                        }
                }
          providerType =
            NormalizedType
              { baseType =
                  NormalizedBaseTypeLayered
                    neverLayer
                      { functionLayer =
                          Just
                            NormalizedFunction
                              { argumentType = recordNormalized [("continuation", pureContinuation)],
                                returnType = stringType,
                                effect = bottomEffect
                              }
                      },
                generics = mempty,
                attribute = bottomAttribute
              }
          -- A non-pure callable bound in scope so the use's body can perform an effect.
          nonPureCallable = nonPureAgentType bottomAttribute (paramObject [("x", integerType)]) integerType
          localBindings =
            Map.fromList
              [ (LocalVariableId 0, monoScheme providerType),
                (LocalVariableId 2, monoScheme nonPureCallable)
              ]
          -- use's body calls the non-pure callable — its inferred effect includes fakeRequestName.
          callInBody =
            callExpression
              (variableExpression (LocalVariableId 2))
              [("x", integerLiteral 1)]
          useStmt =
            useStatementBuilder
              (Just (LocalVariableId 1, integerAnnotation))
              (variableExpression (LocalVariableId 0))
              (exprBlock callInBody)
          action = withReturnTarget stringType (walkStatements [useStmt] (pure ()))
          (_, diagnostics) = runAt localBindings mempty action
       in -- The continuation subtype check at the use site catches the over-broad body effect.
          hasErrorCode "K3001" diagnostics `shouldBe` True

    it "let x = use ... without annotation is K3013" $
      let providerType =
            NormalizedType
              { baseType =
                  NormalizedBaseTypeLayered
                    neverLayer
                      { functionLayer =
                          Just
                            NormalizedFunction
                              { argumentType = recordNormalized [("continuation", topType)],
                                returnType = topType,
                                effect = NormalizedEffectAny
                              }
                      },
                generics = mempty,
                attribute = bottomAttribute
              }
          providerLocal = Map.singleton (LocalVariableId 0) (monoScheme providerType)
          -- Binder without annotation (only the var pattern, typeAnnotation = Nothing)
          useStmt =
            StatementUse
              UseStatement
                { binder = Just (variablePatternForLocal (LocalVariableId 1)),
                  provider = variableExpression (LocalVariableId 0),
                  body = exprBlock nullLiteral,
                  sourceSpan = testSpan
                }
          action = withReturnTarget topType (walkStatements [useStmt] (pure ()))
          (_, diagnostics) = runAt providerLocal mempty action
       in hasErrorCode "K3013" diagnostics `shouldBe` True

  describe "synthExpressionType (handler)" $ do
    it "handler[integer, all] {} produces the expected outer agent type" $
      let handlerExpr = handlerExpressionBuilder [integerAnnotation, allEffectAnnotation] [] Nothing
          (result, diagnostics) = runAt mempty mempty (synthExpressionType handlerExpr)
          continuationAgent =
            layeredOf
              neverLayer
                { functionLayer =
                    Just
                      NormalizedFunction
                        { argumentType = recordNormalized [("value", nullType)],
                          returnType = integerType,
                          effect = NormalizedEffectAny
                        }
                }
          expected =
            NormalizedType
              { baseType =
                  NormalizedBaseTypeLayered
                    neverLayer
                      { functionLayer =
                          Just
                            NormalizedFunction
                              { argumentType = recordNormalized [("continuation", continuationAgent)],
                                returnType = integerType,
                                effect = NormalizedEffectAny
                              }
                      },
                generics = mempty,
                attribute = bottomAttribute
              }
       in (result, toList diagnostics) `shouldBe` (expected, [])

    it "handler with the wrong number of generic arguments is K3009" $
      let handlerExpr = handlerExpressionBuilder [] [] Nothing
          (_, diagnostics) = runAt mempty mempty (synthExpressionType handlerExpr)
       in hasErrorCode "K3009" diagnostics `shouldBe` True

    it "with a then clause whose body produces R, the handler still has R as its result" $
      let handlerExpr =
            handlerExpressionBuilder
              [integerAnnotation, allEffectAnnotation]
              []
              (Just (Nothing, exprBlock (integerLiteral 42)))
          (_, diagnostics) = runAt mempty mempty (synthExpressionType handlerExpr)
       in toList diagnostics `shouldBe` []

    it "then clause body mismatched against R is K3001" $
      let handlerExpr =
            handlerExpressionBuilder
              [integerAnnotation, allEffectAnnotation]
              []
              (Just (Nothing, exprBlock (stringLiteral "no")))
          (_, diagnostics) = runAt mempty mempty (synthExpressionType handlerExpr)
       in hasErrorCode "K3001" diagnostics `shouldBe` True

  describe "request handler body" $ do
    it "rejects a request body whose tail type is not the handler result R" $
      -- handler[integer, all] { request req() { "no" } } — the body's implicit break yields a string.
      let handlerExpr =
            handlerExpressionBuilder
              [integerAnnotation, allEffectAnnotation]
              [requestHandlerForFake (exprBlock (stringLiteral "no"))]
              Nothing
          (_, diagnostics) = runChecker (initialCheckerEnvironment typeEnvironmentWithFakeRequest) (synthExpressionType handlerExpr)
       in hasErrorCode "K3001" diagnostics `shouldBe` True

    it "accepts a request body whose tail type is the handler result R" $
      let handlerExpr =
            handlerExpressionBuilder
              [integerAnnotation, allEffectAnnotation]
              [requestHandlerForFake (exprBlock (integerLiteral 7))]
              Nothing
          (_, diagnostics) = runChecker (initialCheckerEnvironment typeEnvironmentWithFakeRequest) (synthExpressionType handlerExpr)
       in toList diagnostics `shouldBe` []

    it "rejects a request body whose effect exceeds the handler's residual effect E" $
      -- handler[integer, req] { request req() { secondRequestCallable(); 0 } }: the body performs a
      -- different request than E permits.
      let callable =
            agentNormalized
              bottomAttribute
              (paramObject [("x", integerType)])
              integerType
              (NormalizedEffectRow EffectRow {request = Map.singleton secondRequestName mempty, tails = mempty})
          callExpr = callExpression (variableExpression (LocalVariableId 9)) [("x", integerLiteral 1)]
          handlerExpr =
            handlerExpressionBuilder
              [integerAnnotation, requestEffectAnnotation fakeRequestName]
              [requestHandlerForFake (bodyOf [StatementExpression callExpr] (Just (integerLiteral 0)))]
              Nothing
          environment =
            (initialCheckerEnvironment typeEnvironmentWithFakeRequest)
              { locals = Map.singleton (LocalVariableId 9) (monoScheme callable)
              }
          (_, diagnostics) = runChecker environment (synthExpressionType handlerExpr)
       in hasErrorCode "K3001" diagnostics `shouldBe` True

  describe "synthExpressionType (for)" $ do
    it "synthesizes array[T | null] from a body whose `next` emits T" $
      let sourceLocal = Map.singleton (LocalVariableId 0) (monoScheme (tupleNormalized [integerType]))
          forExpr =
            forExpressionBuilder
              (variablePatternForLocal (LocalVariableId 1))
              (variableExpression (LocalVariableId 0))
              (Block {statements = [forNextStatementBuilder (variableExpression (LocalVariableId 1))], returnExpression = Nothing, sourceSpan = testSpan})
              Nothing
          (result, diagnostics) = runAt sourceLocal mempty (synthExpressionType forExpr)
          expected = arrayOfNullable integerType
       in (result, toList diagnostics) `shouldBe` (expected, [])

    it "unions multiple `next` value types across the body" $
      let -- Tuple has two positions of differing types; iteration yields int|string per element.
          sourceLocal = Map.singleton (LocalVariableId 0) (monoScheme (tupleNormalized [integerType, stringType]))
          forExpr =
            forExpressionBuilder
              (variablePatternForLocal (LocalVariableId 1))
              (variableExpression (LocalVariableId 0))
              (Block {statements = [forNextStatementBuilder (variableExpression (LocalVariableId 1))], returnExpression = Nothing, sourceSpan = testSpan})
              Nothing
          (result, _) = runAt sourceLocal mempty (synthExpressionType forExpr)
       in -- result should be array[int | string | null]
          extractSequenceElement result `shouldSatisfy` carriesIntegerAndString

    it "with a then clause, evaluates to the then body's type" $
      let sourceLocal = Map.singleton (LocalVariableId 0) (monoScheme (tupleNormalized [integerType]))
          forExpr =
            forExpressionBuilder
              (variablePatternForLocal (LocalVariableId 1))
              (variableExpression (LocalVariableId 0))
              (Block {statements = [forNextStatementBuilder (variableExpression (LocalVariableId 1))], returnExpression = Nothing, sourceSpan = testSpan})
              -- then (_) { "done" }
              (Just (Nothing, exprBlock (stringLiteral "done")))
          (result, diagnostics) = runAt sourceLocal mempty (synthExpressionType forExpr)
       in (result, toList diagnostics) `shouldBe` (stringType, [])

    it "includes a `break` value in the for's result type (short-circuit)" $
      let sourceLocal = Map.singleton (LocalVariableId 0) (monoScheme (tupleNormalized [integerType]))
          forExpr =
            forExpressionBuilder
              (variablePatternForLocal (LocalVariableId 1))
              (variableExpression (LocalVariableId 0))
              ( Block
                  { statements =
                      [ forNextStatementBuilder (variableExpression (LocalVariableId 1)),
                        forBreakStatementBuilder (stringLiteral "done")
                      ],
                    returnExpression = Nothing,
                    sourceSpan = testSpan
                  }
              )
              Nothing
          (result, diagnostics) = runAt sourceLocal mempty (synthExpressionType forExpr)
          -- array[integer | null] (from `next`) unioned with the break value's type.
          expected = unionOf (arrayOfNullable integerType) stringType
       in (result, toList diagnostics) `shouldBe` (expected, [])

    it "reports K3014 when the source is not a sequence" $
      let sourceLocal = Map.singleton (LocalVariableId 0) (monoScheme integerType)
          forExpr =
            forExpressionBuilder
              (variablePatternForLocal (LocalVariableId 1))
              (variableExpression (LocalVariableId 0))
              (Block {statements = [forNextStatementBuilder (integerLiteral 1)], returnExpression = Nothing, sourceSpan = testSpan})
              Nothing
          (_, diagnostics) = runAt sourceLocal mempty (synthExpressionType forExpr)
       in hasErrorCode "K3014" diagnostics `shouldBe` True

  describe "jump statements" $ do
    it "`return` matches the agent's return type" $
      let action = withReturnTarget integerType (walkStatements [returnStatementBuilder (integerLiteral 1)] (pure ()))
          (_, diagnostics) = runAt mempty mempty action
       in toList diagnostics `shouldBe` []

    it "`return` value mismatched against the return type is K3001" $
      let action = withReturnTarget integerType (walkStatements [returnStatementBuilder (stringLiteral "x")] (pure ()))
          (_, diagnostics) = runAt mempty mempty action
       in hasErrorCode "K3001" diagnostics `shouldBe` True

    it "`return` outside an agent body is K3012" $
      let (_, diagnostics) = runAt mempty mempty (walkStatements [returnStatementBuilder (integerLiteral 1)] (pure ()))
       in hasErrorCode "K3012" diagnostics `shouldBe` True

    it "`next` inside a for body is accepted (the element type is inferred)" $
      let action = pushForContext ForContext (walkStatements [forNextStatementBuilder (integerLiteral 1)] (pure ()))
          (_, diagnostics) = runAt mempty mempty action
       in toList diagnostics `shouldBe` []

    it "`break` inside a for body is accepted (it short-circuits with its value)" $
      let action = pushForContext ForContext (walkStatements [forBreakStatementBuilder (stringLiteral "x")] (pure ()))
          (_, diagnostics) = runAt mempty mempty action
       in toList diagnostics `shouldBe` []

    it "for-`next` outside any `for` body is K3012" $
      let (_, diagnostics) = runAt mempty mempty (walkStatements [forNextStatementBuilder (integerLiteral 1)] (pure ()))
       in hasErrorCode "K3012" diagnostics `shouldBe` True

    it "`break` inside a handler frame matches the frame's handlerResultType" $
      let frame =
            HandleContext
              { handlerResultType = integerType,
                handlerResidualEffect = bottomEffect,
                handledRequests = mempty,
                currentRequestReturnType = topType
              }
          action = pushHandleContext frame (walkStatements [breakStatementBuilder (integerLiteral 1)] (pure ()))
          (_, diagnostics) = runAt mempty mempty action
       in toList diagnostics `shouldBe` []

    it "handler-`break` outside any handler is K3012" $
      let (_, diagnostics) = runAt mempty mempty (walkStatements [breakStatementBuilder (integerLiteral 1)] (pure ()))
       in hasErrorCode "K3012" diagnostics `shouldBe` True

  describe "synthExpressionType (call)" $ do
    it "pure call with matching arg returns the function's return type" $
      let calleeType = pureAgentType (paramObject [("x", integerType)]) integerType
          localBindings = Map.singleton (LocalVariableId 0) (monoScheme calleeType)
          call = callExpression (variableExpression (LocalVariableId 0)) [("x", integerLiteral 1)]
          (result, diagnostics) = runAt localBindings mempty (synthExpressionType call)
       in (result, toList diagnostics) `shouldBe` (integerType, [])

    it "pure call lifts a private argument through the return type" $
      let calleeType = pureAgentType (paramObject [("x", integerType)]) integerType
          localBindings =
            Map.fromList
              [ (LocalVariableId 0, monoScheme calleeType),
                (LocalVariableId 1, monoScheme (ofPrivate integerType))
              ]
          privateArg = variableExpression (LocalVariableId 1)
          call = callExpression (variableExpression (LocalVariableId 0)) [("x", privateArg)]
          (result, diagnostics) = runAt localBindings mempty (synthExpressionType call)
       in (result, toList diagnostics) `shouldBe` (ofPrivate integerType, [])

    it "non-pure call in a matching world returns the declared return type without lift" $
      let calleeType = nonPureAgentType bottomAttribute (paramObject [("x", integerType)]) integerType
          localBindings = Map.singleton (LocalVariableId 0) (monoScheme calleeType)
          call = callExpression (variableExpression (LocalVariableId 0)) [("x", integerLiteral 1)]
          (result, diagnostics) = runAt localBindings mempty (synthExpressionType call)
       in (result, toList diagnostics) `shouldBe` (integerType, [])

    it "rejects a private non-pure callee in a public world" $
      let calleeType = nonPureAgentType privateAttribute (paramObject [("x", integerType)]) integerType
          localBindings = Map.singleton (LocalVariableId 0) (monoScheme calleeType)
          call = callExpression (variableExpression (LocalVariableId 0)) [("x", integerLiteral 1)]
          (_, diagnostics) = runAt localBindings mempty (synthExpressionType call)
       in hasErrorCode "K3001" diagnostics `shouldBe` True

    it "rejects a private argument against a public non-pure callee (no lift)" $
      let calleeType = nonPureAgentType bottomAttribute (paramObject [("x", integerType)]) integerType
          localBindings =
            Map.fromList
              [ (LocalVariableId 0, monoScheme calleeType),
                (LocalVariableId 1, monoScheme (ofPrivate integerType))
              ]
          privateArg = variableExpression (LocalVariableId 1)
          call = callExpression (variableExpression (LocalVariableId 0)) [("x", privateArg)]
          (_, diagnostics) = runAt localBindings mempty (synthExpressionType call)
       in hasErrorCode "K3001" diagnostics `shouldBe` True

    it "reports a non-callable callee with K3014" $
      let localBindings = Map.singleton (LocalVariableId 0) (monoScheme integerType)
          call = callExpression (variableExpression (LocalVariableId 0)) []
          (result, diagnostics) = runAt localBindings mempty (synthExpressionType call)
       in (result, hasErrorCode "K3014" diagnostics) `shouldBe` (bottomType, True)

    it "pure call lifts a nested private field through the return type (structural lift)" $
      let -- Pure callee: agent({x: {y: int}}) -> int — expects an object with an int field
          calleeType =
            pureAgentType
              (recordNormalized [("x", recordNormalized [("y", integerType)])])
              integerType
          -- Argument: an object whose inner field y is private (outer attribute of arg is public).
          nestedPrivateArg = recordNormalized [("y", ofPrivate integerType)]
          localBindings =
            Map.fromList
              [ (LocalVariableId 0, monoScheme calleeType),
                (LocalVariableId 1, monoScheme nestedPrivateArg)
              ]
          call =
            callExpression
              (variableExpression (LocalVariableId 0))
              [("x", variableExpression (LocalVariableId 1))]
          (result, diagnostics) = runAt localBindings mempty (synthExpressionType call)
       in -- The nested private attribute lifts: the return is observed as private.
          (result, toList diagnostics) `shouldBe` (ofPrivate integerType, [])

  describe "explicit generic application" $ do
    it "instantiates a generic value's scheme by explicit type argument" $
      -- A top-level `agent[a](x: a) -> a` applied as `topAgent[integer]` instantiates to
      -- `agent(x: integer) -> integer`.
      let environment = checkerEnvironmentWith mempty (Map.singleton topLevelName (identityScheme aId))
          application = typeApplication (qualifiedVariableExpression topLevelName) [integerAnnotation]
          (result, diagnostics) = runChecker environment (synthExpressionType application)
          expected = pureAgentType (paramObject [("x", integerType)]) integerType
       in (result, toList diagnostics) `shouldBe` (expected, [])

    it "rejects the wrong number of explicit type arguments (K3009)" $
      let environment = checkerEnvironmentWith mempty (Map.singleton topLevelName (identityScheme aId))
          application = typeApplication (qualifiedVariableExpression topLevelName) [integerAnnotation, stringAnnotation]
          (_, diagnostics) = runChecker environment (synthExpressionType application)
       in hasErrorCode "K3009" diagnostics `shouldBe` True

    it "rejects a bare reference to a generic value, unapplied (K3013)" $
      let environment = checkerEnvironmentWith mempty (Map.singleton topLevelName (identityScheme aId))
          (_, diagnostics) = runChecker environment (synthExpressionType (qualifiedVariableExpression topLevelName))
       in hasErrorCode "K3013" diagnostics `shouldBe` True

------------------------------------------------------------------------------------------------
-- Runners
------------------------------------------------------------------------------------------------

-- | Build a checker environment with the given locals and value entries in scope. Other fields
-- stay at their defaults so the test exercises the expression walk in isolation.
checkerEnvironmentWith :: Map.Map LocalVariableId Scheme -> ValueEnvironment -> CheckerEnvironment
checkerEnvironmentWith locals values =
  let baseEnvironment = initialCheckerEnvironment emptyTypeEnvironment
   in baseEnvironment {locals = locals, valueEnvironment = values}

runAt :: Map.Map LocalVariableId Scheme -> ValueEnvironment -> Checker a -> (a, Diagnostics)
runAt locals values = runChecker (checkerEnvironmentWith locals values)

-- | Synthesize an expression's type in the empty environment.
synthAt :: Expression Identified -> NormalizedType
synthAt expression = fst (runAt mempty mempty (synthExpressionType expression))

-- | Synthesize an expression's type with the given local bindings in scope.
synthIn :: List (LocalVariableId, NormalizedType) -> Expression Identified -> NormalizedType
synthIn bindings expression =
  let locals = Map.fromList [(localId, monoScheme boundType) | (localId, boundType) <- bindings]
   in fst (runAt locals mempty (synthExpressionType expression))

------------------------------------------------------------------------------------------------
-- Diagnostic helpers
------------------------------------------------------------------------------------------------

hasErrorCode :: Text -> Diagnostics -> Bool
hasErrorCode code diagnostics =
  any (\located -> typeErrorCode' located.value == Just code) (toList diagnostics)
  where
    typeErrorCode' = \case
      CompilerErrorType typeError -> Just (typeErrorCode typeError)
      _ -> Nothing

------------------------------------------------------------------------------------------------
-- Type fixtures
------------------------------------------------------------------------------------------------

tupleNormalized :: List NormalizedType -> NormalizedType
tupleNormalized items =
  layeredOf neverLayer {sequenceLayer = Just NormalizedSequence {items = items, rest = nullType}}

recordNormalized :: List (Text, NormalizedType) -> NormalizedType
recordNormalized fieldList =
  layeredOf
    neverLayer
      { objectLayer =
          Just
            NormalizedObject
              { fields = Map.fromList [(name, NormalizedFieldInformation {normalizedType = fieldType, optional = False}) | (name, fieldType) <- fieldList],
                rest = unknownType
              }
      }

-- | The normalized union of two types, computed by the real lattice join, so a union assertion is
-- exact equality rather than slot-subset satisfaction.
unionOf :: NormalizedType -> NormalizedType -> NormalizedType
unionOf left right = fst (runAt mempty mempty (runNormalizer testSpan (union left right)))

------------------------------------------------------------------------------------------------
-- AST builders (Identified phase) — minimal scaffolding for tests
------------------------------------------------------------------------------------------------

testSpan :: SourceSpan
testSpan = SourceSpan {filePath = "<test>", start = Position {line = 1, column = 1}, end = Position {line = 1, column = 1}}

topLevelName :: QualifiedName
topLevelName = QualifiedName {moduleName = ModuleName "test", name = "topAgent"}

simpleScheme :: NormalizedType -> Scheme
simpleScheme = monoScheme

integerLiteral :: Int -> Expression Identified
integerLiteral n = ExpressionLiteral LiteralExpression {value = LiteralValueInteger n, sourceSpan = testSpan, typeOf = ()}

numberLiteral :: Double -> Expression Identified
numberLiteral n = ExpressionLiteral LiteralExpression {value = LiteralValueNumber n, sourceSpan = testSpan, typeOf = ()}

stringLiteral :: Text -> Expression Identified
stringLiteral s = ExpressionLiteral LiteralExpression {value = LiteralValueString s, sourceSpan = testSpan, typeOf = ()}

booleanLiteral :: Bool -> Expression Identified
booleanLiteral b = ExpressionLiteral LiteralExpression {value = LiteralValueBoolean b, sourceSpan = testSpan, typeOf = ()}

nullLiteral :: Expression Identified
nullLiteral = ExpressionLiteral LiteralExpression {value = LiteralValueNull, sourceSpan = testSpan, typeOf = ()}

variableExpression :: LocalVariableId -> Expression Identified
variableExpression localId =
  ExpressionVariable
    VariableExpression
      { name = "x",
        variableReference =
          Reference {sourceSpan = testSpan, resolution = Just (VariableResolutionLocalVariable localId)},
        sourceSpan = testSpan,
        typeOf = ()
      }

qualifiedVariableExpression :: QualifiedName -> Expression Identified
qualifiedVariableExpression qualifiedName =
  ExpressionVariable
    VariableExpression
      { name = qualifiedName.name,
        variableReference =
          Reference {sourceSpan = testSpan, resolution = Just (VariableResolutionQualifiedName qualifiedName)},
        sourceSpan = testSpan,
        typeOf = ()
      }

tupleExpression :: List (Expression Identified) -> Expression Identified
tupleExpression elements =
  ExpressionTuple
    TupleExpression {parallel = False, elements = elements, sourceSpan = testSpan, typeOf = ()}

recordExpression :: List (Text, Expression Identified) -> Expression Identified
recordExpression entries =
  ExpressionRecord
    RecordExpression
      { entries = [RecordEntry {name = name, value = value, sourceSpan = testSpan} | (name, value) <- entries],
        sourceSpan = testSpan,
        typeOf = ()
      }

binaryExpression :: BinaryOperator -> Expression Identified -> Expression Identified -> Expression Identified
binaryExpression operator left right =
  ExpressionBinaryOperator
    BinaryOperatorExpression
      { operator = operator,
        left = left,
        right = right,
        sourceSpan = testSpan,
        typeOf = ()
      }

unaryExpression :: UnaryOperator -> Expression Identified -> Expression Identified
unaryExpression operator operand =
  ExpressionUnaryOperator
    UnaryOperatorExpression {operator = operator, operand = operand, sourceSpan = testSpan, typeOf = ()}

ifExpression :: Expression Identified -> List (Expression Identified) -> Maybe (List (Expression Identified)) -> Expression Identified
ifExpression condition thenStatements maybeElseStatements =
  ExpressionIf
    IfExpression
      { condition = condition,
        thenBlock = simpleBlock thenStatements,
        elseBlock = simpleBlock <$> maybeElseStatements,
        sourceSpan = testSpan,
        typeOf = ()
      }
  where
    -- A simple block: every statement except the final expression becomes a bare-expression
    -- statement; the final one becomes the return expression. An empty list yields an empty block.
    simpleBlock expressions = case reverse expressions of
      [] -> Block {statements = [], returnExpression = Nothing, sourceSpan = testSpan}
      (final : rest) -> Block {statements = reverse [StatementExpression expression | expression <- rest], returnExpression = Just final, sourceSpan = testSpan}

blockExpression :: List (Statement Identified) -> Maybe (Expression Identified) -> Expression Identified
blockExpression statements maybeReturn =
  ExpressionBlock
    BlockExpression
      { block = Block {statements = statements, returnExpression = maybeReturn, sourceSpan = testSpan},
        sourceSpan = testSpan,
        typeOf = ()
      }

letStatement :: LocalVariableId -> Expression Identified -> Statement Identified
letStatement localId value =
  StatementLet
    LetStatement
      { pattern = PatternVariable variablePatternFor,
        value = value,
        sourceSpan = testSpan
      }
  where
    variablePatternFor =
      VariablePattern
        { name = "x",
          variableReference =
            Reference {sourceSpan = testSpan, resolution = Just (VariableResolutionLocalVariable localId)},
          typeAnnotation = Nothing,
          defaultValue = Nothing,
          sourceSpan = testSpan,
          typeOf = ()
        }

callExpression :: Expression Identified -> List (Text, Expression Identified) -> Expression Identified
callExpression callee arguments =
  ExpressionCall
    CallExpression
      { callee = callee,
        arguments =
          [ CallArgument
              { name = name,
                labelReference = Reference {sourceSpan = testSpan, resolution = ()},
                value = value,
                sourceSpan = testSpan
              }
            | (name, value) <- arguments
          ],
        sourceSpan = testSpan,
        typeOf = ()
      }

------------------------------------------------------------------------------------------------
-- Function and attribute fixtures (for call-rule tests)
------------------------------------------------------------------------------------------------

agentNormalized :: NormalizedAttribute -> NormalizedType -> NormalizedType -> NormalizedEffect -> NormalizedType
agentNormalized outerAttribute parameterType returnType effect =
  NormalizedType
    { baseType =
        NormalizedBaseTypeLayered
          neverLayer
            { functionLayer =
                Just
                  NormalizedFunction
                    { argumentType = parameterType,
                      returnType = returnType,
                      effect = effect
                    }
            },
      generics = mempty,
      attribute = outerAttribute
    }

pureAgentType :: NormalizedType -> NormalizedType -> NormalizedType
pureAgentType parameterType returnType = agentNormalized bottomAttribute parameterType returnType bottomEffect

-- | A non-pure agent: its effect carries a single fake request so 'isPureEffect' returns False
-- and the call rule fires. The request is never resolved (no subtype on the effect), so it does
-- not have to exist in any environment.
nonPureAgentType :: NormalizedAttribute -> NormalizedType -> NormalizedType -> NormalizedType
nonPureAgentType outerAttribute parameterType returnType =
  agentNormalized
    outerAttribute
    parameterType
    returnType
    (NormalizedEffectRow EffectRow {request = Map.singleton fakeRequestName mempty, tails = mempty})

fakeRequestName :: QualifiedName
fakeRequestName = QualifiedName {moduleName = ModuleName "test", name = "req"}

secondRequestName :: QualifiedName
secondRequestName = QualifiedName {moduleName = ModuleName "test", name = "req2"}

paramObject :: List (Text, NormalizedType) -> NormalizedType
paramObject = recordNormalized

------------------------------------------------------------------------------------------------
-- Generic fixtures
------------------------------------------------------------------------------------------------

aId :: GenericId
aId = GenericId (ModuleName "test") 0

-- | A bare generic type variable.
genericVariable :: GenericId -> NormalizedType
genericVariable genericId =
  NormalizedType {baseType = NormalizedBaseTypeLayered neverLayer, generics = Set.singleton genericId, attribute = bottomAttribute}

-- | The scheme of a generic identity agent @agent[a](x: a) -> a@, quantified over the given id.
identityScheme :: GenericId -> Scheme
identityScheme genericId =
  Scheme
    { genericParameters =
        GenericParameters
          { parameterNames = ["a"],
            parameterInformation =
              Map.singleton
                "a"
                GenericParameterInformation {genericId = genericId, kind = GenericKindType, variance = Bivariant, upperBound = Nothing}
          },
      valueType = pureAgentType (paramObject [("x", genericVariable genericId)]) (genericVariable genericId)
    }

-- | An explicit generic application @callee[args]@.
typeApplication :: Expression Identified -> List (SyntacticTypeExpression Identified) -> Expression Identified
typeApplication callee typeArguments =
  ExpressionTypeApplication
    TypeApplicationExpression
      { callee = callee,
        typeArguments = typeArguments,
        instantiation = (),
        sourceSpan = testSpan,
        typeOf = ()
      }

------------------------------------------------------------------------------------------------
-- Request handler fixtures
------------------------------------------------------------------------------------------------

-- | A type environment with 'fakeRequestName' registered — in the request environment (so the
-- checker can walk a handler for it) and the elaborator's registry (so a request-name effect
-- annotation resolves). The request takes no arguments and returns null.
typeEnvironmentWithFakeRequest :: TypeEnvironment
typeEnvironmentWithFakeRequest =
  TypeEnvironment
    { dataEnvironment = mempty,
      requestEnvironment =
        Map.singleton
          fakeRequestName
          RequestInformation
            { name = fakeRequestName,
              genericParameters = emptyGenerics,
              request = (recordNormalized [], nullType)
            },
      synonymEnvironment = mempty,
      elaborateContext = emptyContext mempty (Map.singleton fakeRequestName emptyGenerics) mempty
    }
  where
    emptyGenerics = GenericParameters {parameterNames = [], parameterInformation = mempty}

-- | A handler for 'fakeRequestName' with no parameters and the given body.
requestHandlerForFake :: Block Identified -> RequestHandler Identified
requestHandlerForFake body =
  RequestHandler
    { moduleQualifier = Nothing,
      name = "req",
      typeReference = Reference {sourceSpan = testSpan, resolution = Just (TypeResolutionQualifiedName fakeRequestName)},
      genericArguments = [],
      instantiation = (),
      parameters = [],
      returnType = Nothing,
      body = body,
      sourceSpan = testSpan
    }

-- | The effect @{req}@ written as a bare request name (resolved to the given request).
requestEffectAnnotation :: QualifiedName -> SyntacticTypeExpression Identified
requestEffectAnnotation requestName =
  TypeName
    TypeNameNode
      { moduleQualifier = Nothing,
        name = requestName.name,
        typeReference = Reference {sourceSpan = testSpan, resolution = Just (TypeResolutionQualifiedName requestName)},
        sourceSpan = testSpan
      }

------------------------------------------------------------------------------------------------
-- Agent declaration fixtures
------------------------------------------------------------------------------------------------

-- | Construct an 'AgentDeclaration' over the four fields the tests vary, leaving every other
-- field at a sensible default. A builder rather than record-update from a default is used because
-- 'AgentDeclaration' shares several field names (@parameters@, @returnType@, @effects@, @body@)
-- with other records, which makes a record update ambiguous under DuplicateRecordFields.
agentDeclarationWith ::
  List (ParameterBinding Identified) ->
  Maybe (SyntacticTypeExpression Identified) ->
  Maybe (SyntacticTypeExpression Identified) ->
  Bool ->
  Block Identified ->
  AgentDeclaration Identified
agentDeclarationWith parameters returnType effects isPrivate body =
  AgentDeclaration
    { annotation = Nothing,
      private = isPrivate,
      name = "agentUnderTest",
      -- The 'synthAgent' path does not consult 'variableReference'; only 'withLocalAgent' (via
      -- 'StatementAgent') does, so a placeholder local id is fine for direct-call tests.
      variableReference =
        Reference {sourceSpan = testSpan, resolution = Just (VariableResolutionLocalVariable (LocalVariableId 100))},
      genericParameters = [],
      parameters = parameters,
      returnType = returnType,
      effects = effects,
      body = body,
      sourceSpan = testSpan
    }

-- | A checker environment with its world set to private. Rebuilt explicitly to dodge the
-- DuplicateRecordFields ambiguity on the shared @world@ field (same workaround as
-- 'rebuildWithWorld' in 'Katari.Typechecker.Context').
rebuildWithPrivateWorld :: CheckerEnvironment -> CheckerEnvironment
rebuildWithPrivateWorld environment =
  let _ = environment.world -- touched so the field name resolves locally
   in environment {world = privateAttribute}

paramBindingFor :: Text -> LocalVariableId -> SyntacticTypeExpression Identified -> ParameterBinding Identified
paramBindingFor paramName localId annotation =
  ParameterBinding
    { annotation = Nothing,
      name = paramName,
      labelReference = Reference {sourceSpan = testSpan, resolution = ()},
      bindPattern =
        PatternVariable
          VariablePattern
            { name = paramName,
              variableReference =
                Reference {sourceSpan = testSpan, resolution = Just (VariableResolutionLocalVariable localId)},
              typeAnnotation = Just annotation,
              defaultValue = Nothing,
              sourceSpan = testSpan,
              typeOf = ()
            },
      sourceSpan = testSpan
    }

bodyOf :: List (Statement Identified) -> Maybe (Expression Identified) -> Block Identified
bodyOf statements returnExpr = Block {statements = statements, returnExpression = returnExpr, sourceSpan = testSpan}

primitiveAnnotation :: PrimitiveTypeKind -> SyntacticTypeExpression Identified
primitiveAnnotation kind = TypePrimitive PrimitiveTypeNode {kind = kind, sourceSpan = testSpan}

integerAnnotation :: SyntacticTypeExpression Identified
integerAnnotation = primitiveAnnotation PrimitiveTypeKindInteger

stringAnnotation :: SyntacticTypeExpression Identified
stringAnnotation = primitiveAnnotation PrimitiveTypeKindString

allEffectAnnotation :: SyntacticTypeExpression Identified
allEffectAnnotation = TypeAll testSpan

------------------------------------------------------------------------------------------------
-- Pattern / match / let fixtures
------------------------------------------------------------------------------------------------

matchExpression :: Expression Identified -> List (Pattern Identified, Block Identified) -> Expression Identified
matchExpression subject caseEntries =
  ExpressionMatch
    MatchExpression
      { subject = subject,
        cases =
          [ CaseArm {pattern = patternForCase, body = caseBody, sourceSpan = testSpan}
            | (patternForCase, caseBody) <- caseEntries
          ],
        sourceSpan = testSpan,
        typeOf = ()
      }

wildcardPattern :: Pattern Identified
wildcardPattern =
  PatternWildcard
    WildcardPattern {typeAnnotation = Nothing, sourceSpan = testSpan, typeOf = ()}

variablePatternForLocal :: LocalVariableId -> Pattern Identified
variablePatternForLocal localId =
  PatternVariable
    VariablePattern
      { name = "x",
        variableReference =
          Reference {sourceSpan = testSpan, resolution = Just (VariableResolutionLocalVariable localId)},
        typeAnnotation = Nothing,
        defaultValue = Nothing,
        sourceSpan = testSpan,
        typeOf = ()
      }

literalPattern :: LiteralValue -> Pattern Identified
literalPattern v =
  PatternLiteral
    LiteralPattern {value = v, sourceSpan = testSpan, typeOf = ()}

typeFilterPattern :: SyntacticTypeExpression Identified -> Pattern Identified -> Pattern Identified
typeFilterPattern matchedType inner =
  PatternTypeFilter
    TypeFilterPattern
      { matchedType = matchedType,
        inner = inner,
        sourceSpan = testSpan,
        typeOf = ()
      }

tuplePattern :: List (Pattern Identified) -> Pattern Identified
tuplePattern patterns =
  PatternTuple
    TuplePattern {elements = patterns, sourceSpan = testSpan, typeOf = ()}

exprBlock :: Expression Identified -> Block Identified
exprBlock expression =
  Block {statements = [], returnExpression = Just expression, sourceSpan = testSpan}

letStatementAnnotated :: LocalVariableId -> SyntacticTypeExpression Identified -> Expression Identified -> Statement Identified
letStatementAnnotated localId annotation value =
  StatementLet
    LetStatement
      { pattern =
          PatternVariable
            VariablePattern
              { name = "x",
                variableReference =
                  Reference {sourceSpan = testSpan, resolution = Just (VariableResolutionLocalVariable localId)},
                typeAnnotation = Just annotation,
                defaultValue = Nothing,
                sourceSpan = testSpan,
                typeOf = ()
              },
        value = value,
        sourceSpan = testSpan
      }

letStatementWithPattern :: Pattern Identified -> Expression Identified -> Statement Identified
letStatementWithPattern letPattern value =
  StatementLet
    LetStatement {pattern = letPattern, value = value, sourceSpan = testSpan}

------------------------------------------------------------------------------------------------
-- Jump statement fixtures
------------------------------------------------------------------------------------------------

returnStatementBuilder :: Expression Identified -> Statement Identified
returnStatementBuilder value =
  StatementReturn ReturnStatement {value = value, sourceSpan = testSpan}

forNextStatementBuilder :: Expression Identified -> Statement Identified
forNextStatementBuilder value =
  StatementForNext ForNextStatement {value = value, modifiers = [], sourceSpan = testSpan}

forBreakStatementBuilder :: Expression Identified -> Statement Identified
forBreakStatementBuilder value =
  StatementForBreak ForBreakStatement {value = value, sourceSpan = testSpan}

breakStatementBuilder :: Expression Identified -> Statement Identified
breakStatementBuilder value =
  StatementBreak BreakStatement {value = value, sourceSpan = testSpan}

------------------------------------------------------------------------------------------------
-- @use@ statement fixtures
------------------------------------------------------------------------------------------------

-- | Build a 'StatementUse' from a (optional) binder spec @(LocalVariableId, annotation)@, a
-- provider expression, and a body block.
useStatementBuilder ::
  Maybe (LocalVariableId, SyntacticTypeExpression Identified) ->
  Expression Identified ->
  Block Identified ->
  Statement Identified
useStatementBuilder maybeBinder provider body =
  StatementUse
    UseStatement
      { binder = binderPattern <$> maybeBinder,
        provider = provider,
        body = body,
        sourceSpan = testSpan
      }
  where
    binderPattern (localId, annotation) =
      PatternVariable
        VariablePattern
          { name = "x",
            variableReference =
              Reference {sourceSpan = testSpan, resolution = Just (VariableResolutionLocalVariable localId)},
            typeAnnotation = Just annotation,
            defaultValue = Nothing,
            sourceSpan = testSpan,
            typeOf = ()
          }

------------------------------------------------------------------------------------------------
-- For expression fixtures
------------------------------------------------------------------------------------------------

forExpressionBuilder ::
  Pattern Identified ->
  Expression Identified ->
  Block Identified ->
  Maybe (Maybe (Pattern Identified), Block Identified) ->
  Expression Identified
forExpressionBuilder iterationPattern source body maybeThen =
  ExpressionFor
    ForExpression
      { parallel = False,
        inBinding =
          ForInBinding
            { pattern = iterationPattern,
              source = source,
              sourceSpan = testSpan
            },
        varBindings = [],
        body = body,
        thenClause =
          ( \(binder, thenBody) ->
              ThenClause {binder = binder, body = thenBody, sourceSpan = testSpan}
          )
            <$> maybeThen,
        sourceSpan = testSpan,
        typeOf = ()
      }

------------------------------------------------------------------------------------------------
-- Handler expression fixtures
------------------------------------------------------------------------------------------------

handlerExpressionBuilder ::
  List (SyntacticTypeExpression Identified) ->
  List (RequestHandler Identified) ->
  Maybe (Maybe (Pattern Identified), Block Identified) ->
  Expression Identified
handlerExpressionBuilder genericArgs requestHandlers maybeThen =
  ExpressionHandler
    HandlerExpression
      { parallel = False,
        genericArguments = genericArgs,
        instantiation = (),
        stateVariables = [],
        handlers = requestHandlers,
        thenClause =
          ( \(binder, thenBody) ->
              ThenClause {binder = binder, body = thenBody, sourceSpan = testSpan}
          )
            <$> maybeThen,
        sourceSpan = testSpan,
        typeOf = ()
      }

-- | The expected result shape of a basic for over the given element type: @array[T | null]@.
arrayOfNullable :: NormalizedType -> NormalizedType
arrayOfNullable elementType =
  layeredOf
    neverLayer
      { sequenceLayer =
          Just NormalizedSequence {items = [], rest = withNull elementType}
      }
  where
    withNull normalizedType = case normalizedType.baseType of
      NormalizedBaseTypeUnknown -> normalizedType
      NormalizedBaseTypeLayered layer ->
        NormalizedType
          { baseType = NormalizedBaseTypeLayered layer {nullLayer = True},
            generics = normalizedType.generics,
            attribute = normalizedType.attribute
          }

-- | Pull the function-layer effect out of an agent type. 'bottomEffect' for non-agents.
extractAgentEffect :: NormalizedType -> NormalizedEffect
extractAgentEffect normalizedType = case normalizedType.baseType of
  NormalizedBaseTypeLayered layer | Just function <- layer.functionLayer -> function.effect
  _ -> bottomEffect

-- | Pull the @rest@ slot out of an array's normalized form. Returns 'bottomType' if the input
-- isn't a sequence — caller-side soft check for the union test below.
extractSequenceElement :: NormalizedType -> NormalizedType
extractSequenceElement normalizedType = case normalizedType.baseType of
  NormalizedBaseTypeLayered layer
    | Just normalizedSequence <- layer.sequenceLayer ->
        normalizedSequence.rest
  _ -> bottomType

carriesIntegerAndString :: NormalizedType -> Bool
carriesIntegerAndString normalizedType = case normalizedType.baseType of
  NormalizedBaseTypeLayered layer ->
    layer.numberLayer == NumberSlotInteger && layer.stringLayer && layer.nullLayer
  _ -> False

-- | Wrap a normalized type in @of private@: keep its base and generics, raise its outer attribute
-- to private. The 'attribute' field name is shared with 'AttributedTypeNode' under
-- DuplicateRecordFields, so the record is rebuilt explicitly (see 'liftByAttribute' in Check.hs
-- for the same workaround). The 'privateAttribute' value comes from 'Katari.Typechecker.Check'.
ofPrivate :: NormalizedType -> NormalizedType
ofPrivate normalizedType =
  NormalizedType
    { baseType = normalizedType.baseType,
      generics = normalizedType.generics,
      attribute = joinAttribute normalizedType.attribute privateAttribute
    }
