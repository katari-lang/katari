module Katari.Typechecker.CheckSpec (spec) where

import Data.Foldable (toList)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Compile (CompileInput (..), CompileResult (..), compile)
import Katari.Data.AST
import Katari.Data.Environment (GenericParameterInformation (..), GenericParameters (..), RequestInformation (..), Scheme (..), ValueEnvironment, monoScheme)
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.Id (GenericId (..), LocalVariableId (..), TypeResolution (..), VariableResolution (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.NormalizedType
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SourceSpan (Located (..), Position (..), SourceSpan (..))
import Katari.Data.Variance (Variance (..))
import Katari.Diagnostics (Diagnostics, renderDiagnostics)
import Katari.Error (CompilerError (..), compilerErrorCode, typeErrorCode)
import Katari.Typechecker.Check
import Katari.Typechecker.Context
  ( Checker,
    CheckerEnvironment (..),
    enterAgentBody,
    enterForBody,
    enterRequestHandler,
    initialCheckerEnvironment,
    runChecker,
    runNormalizer,
    withEffectInference,
    withWorld,
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
    it "tuple of [int, string] synthesizes to a sequence with two items and a never tail" $
      synthAt (tupleExpression [integerLiteral 1, stringLiteral "a"])
        `shouldBe` tupleNormalized [integerType, stringType]
    it "record literal becomes a closed object (required fields, a never tail)" $
      synthAt (recordExpression [("x", integerLiteral 1), ("y", booleanLiteral True)])
        `shouldBe` recordNormalizedClosed [("x", integerType), ("y", booleanType)]

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

  -- Operators desugar (in the identifier pass) to generic `primitive.*` calls, so their typing —
  -- including inferring the operand type parameter — is exercised end-to-end in
  -- "Katari.Typechecker.InferenceSpec", not as direct-AST unit tests here.

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

    it "rejects an integer scrutinee covered only by literal cases (integers have no singleton type)" $
      let scrutineeLocal = Map.singleton (LocalVariableId 0) (monoScheme integerType)
          subject = variableExpression (LocalVariableId 0)
          matchExpr =
            matchExpression
              subject
              [ (literalPattern (LiteralValueInteger 1), exprBlock (stringLiteral "one")),
                (literalPattern (LiteralValueInteger 2), exprBlock (stringLiteral "two"))
              ]
          (_, diagnostics) = runAt scrutineeLocal mempty (synthExpressionType matchExpr)
       in hasErrorCode "K3001" diagnostics `shouldBe` True

    it "accepts a boolean scrutinee covered by both `true` and `false` literal cases" $
      let scrutineeLocal = Map.singleton (LocalVariableId 0) (monoScheme booleanType)
          subject = variableExpression (LocalVariableId 0)
          matchExpr =
            matchExpression
              subject
              [ (literalPattern (LiteralValueBoolean True), exprBlock (integerLiteral 1)),
                (literalPattern (LiteralValueBoolean False), exprBlock (integerLiteral 0))
              ]
          (_, diagnostics) = runAt scrutineeLocal mempty (synthExpressionType matchExpr)
       in toList diagnostics `shouldBe` []

    it "rejects a boolean scrutinee covered by only `true`" $
      let scrutineeLocal = Map.singleton (LocalVariableId 0) (monoScheme booleanType)
          subject = variableExpression (LocalVariableId 0)
          matchExpr =
            matchExpression
              subject
              [(literalPattern (LiteralValueBoolean True), exprBlock (integerLiteral 1))]
          (_, diagnostics) = runAt scrutineeLocal mempty (synthExpressionType matchExpr)
       in hasErrorCode "K3001" diagnostics `shouldBe` True

    it "narrows the binder's type inside a TypeFilter pattern" $
      let scrutineeLocal = Map.singleton (LocalVariableId 0) (monoScheme unknownType)
          subject = variableExpression (LocalVariableId 0)
          narrowed = typeFilterPattern FilterInteger (variablePatternForLocal (LocalVariableId 1))
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
            effectRow
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
       in (extractAgentEffect result, toList diagnostics) `shouldBe` (anyEffect, [])

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

    it "a body ending in `return` typechecks against the annotated return type (the tail is unreachable)" $
      let declaration =
            agentDeclarationWith
              [paramBindingFor "x" (LocalVariableId 1) integerAnnotation]
              (Just integerAnnotation)
              Nothing
              False
              (bodyOf [returnStatementBuilder (variableExpression (LocalVariableId 1))] Nothing)
          expected = pureAgentType (paramObject [("x", integerType)]) integerType
          (result, diagnostics) = runAt mempty mempty (synthAgentType declaration)
       in (result, toList diagnostics) `shouldBe` (expected, [])

    it "infers the return type from a `return` when the body has no trailing expression" $
      let declaration =
            agentDeclarationWith
              []
              Nothing
              Nothing
              False
              (bodyOf [returnStatementBuilder (integerLiteral 5)] Nothing)
          expected = pureAgentType (paramObject []) integerType
          (result, diagnostics) = runAt mempty mempty (synthAgentType declaration)
       in (result, toList diagnostics) `shouldBe` (expected, [])

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
              (initialCheckerEnvironment emptyTypeEnvironment)
              (withWorld privateAttribute (synthAgentType declaration))
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
                          effect = anyEffect
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
                                effect = anyEffect
                              }
                      },
                generics = mempty,
                attribute = bottomAttribute
              }
          providerLocal = Map.singleton (LocalVariableId 0) (monoScheme providerType)
          -- The continuation's result R is the use body's tail (here the string "ok"), matching the
          -- provider's expected continuation return type.
          useStmt = useStatementBuilder (Just (LocalVariableId 1, integerAnnotation)) (variableExpression (LocalVariableId 0)) (exprBlock (stringLiteral "ok"))
          action = walkStatements [useStmt] (pure ())
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
          -- use's body calls the non-pure callable — its inferred effect includes fakeRequestName. Its
          -- tail is a string, so R matches the provider's expected continuation return type and only the
          -- over-broad effect can trip the continuation subtype check.
          callInBody =
            callExpression
              (variableExpression (LocalVariableId 2))
              [("x", integerLiteral 1)]
          useStmt =
            useStatementBuilder
              (Just (LocalVariableId 1, integerAnnotation))
              (variableExpression (LocalVariableId 0))
              (bodyOf [StatementExpression callInBody] (Just (stringLiteral "ok")))
          action = walkStatements [useStmt] (pure ())
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
                                effect = anyEffect
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
          action = walkStatements [useStmt] (pure ())
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
                          effect = anyEffect
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
                                effect = anyEffect
                              }
                      },
                generics = mempty,
                attribute = bottomAttribute
              }
       in (result, toList diagnostics) `shouldBe` (expected, [])

    it "handler with the wrong number of generic arguments is K3009" $
      -- One bracket argument is neither the explicit @[R, E]@ pair nor the omitted (inferred) form.
      let handlerExpr = handlerExpressionBuilder [integerAnnotation] [] Nothing
          (_, diagnostics) = runAt mempty mempty (synthExpressionType handlerExpr)
       in hasErrorCode "K3009" diagnostics `shouldBe` True

    it "a bare handler (no generic arguments) is an unapplied generic value (K3015)" $
      -- A handler is a generic value over R / E; without an application (a `use` / call) there is no
      -- continuation to infer them from, so a bare `handler { ... }` must be applied or written
      -- `handler[R, E]` — exactly like any unapplied generic.
      let handlerExpr = handlerExpressionBuilder [] [] Nothing
          (_, diagnostics) = runAt mempty mempty (synthExpressionType handlerExpr)
       in hasErrorCode "K3015" diagnostics `shouldBe` True

    it "a then clause makes the handler result the then body type R' (transforming R), not R itself" $
      -- handler[integer, all] {} then (r) { "done" }: R = integer (the then binder / continuation
      -- result), but the then body is a string, so the handler's result type is string (R'), not R. The
      -- then body is no longer constrained @<: R@ — it freely produces the transformed result.
      let handlerExpr =
            handlerExpressionBuilder
              [integerAnnotation, allEffectAnnotation]
              []
              (Just (Nothing, exprBlock (stringLiteral "done")))
          (result, diagnostics) = runAt mempty mempty (synthExpressionType handlerExpr)
          continuationAgent =
            layeredOf
              neverLayer
                { functionLayer =
                    Just
                      NormalizedFunction
                        { argumentType = recordNormalized [("value", nullType)],
                          returnType = integerType,
                          effect = anyEffect
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
                                returnType = stringType,
                                effect = anyEffect
                              }
                      },
                generics = mempty,
                attribute = bottomAttribute
              }
       in (result, toList diagnostics) `shouldBe` (expected, [])

  describe "request handler body" $ do
    it "a request body tail is the resume value, checked against the request return type (K3001 on mismatch)" $
      -- handler[integer, all] { request req() { "no" } }: the body's tail resumes the continuation, so it
      -- is checked against req's return type (here null). A string tail is not a valid resume, so it is
      -- rejected — it is /not/ joined into the handler result.
      let handlerExpr =
            handlerExpressionBuilder
              [integerAnnotation, allEffectAnnotation]
              [requestHandlerForFake (exprBlock (stringLiteral "no"))]
              Nothing
          (_, diagnostics) = runChecker (initialCheckerEnvironment typeEnvironmentWithFakeRequest) (synthExpressionType handlerExpr)
       in hasErrorCode "K3001" diagnostics `shouldBe` True

    it "accepts a request body whose tail is a valid resume value (the request return type)" $
      -- req returns null, so a null tail is a valid resume value.
      let handlerExpr =
            handlerExpressionBuilder
              [integerAnnotation, allEffectAnnotation]
              [requestHandlerForFake (exprBlock nullLiteral)]
              Nothing
          (_, diagnostics) = runChecker (initialCheckerEnvironment typeEnvironmentWithFakeRequest) (synthExpressionType handlerExpr)
       in toList diagnostics `shouldBe` []

    it "accepts a request body that ends in `break` (it diverges, so the tail is never, not null)" $
      let handlerExpr =
            handlerExpressionBuilder
              [integerAnnotation, allEffectAnnotation]
              [requestHandlerForFake (bodyOf [breakStatementBuilder (integerLiteral 7)] Nothing)]
              Nothing
          (_, diagnostics) = runChecker (initialCheckerEnvironment typeEnvironmentWithFakeRequest) (synthExpressionType handlerExpr)
       in toList diagnostics `shouldBe` []

    it "a request body's effect joins the handler's effect (E | bodyEffect), so it is not restricted by E" $
      -- handler[integer, req] { request req() { secondRequestCallable(); 0 } }: the body performs a
      -- second request; under the generic-value handler its effect joins the handler's effect (E is the
      -- residual the continuation passes through, unioned with the body's own effects), so it is not
      -- rejected.
      let callable =
            agentNormalized
              bottomAttribute
              (paramObject [("x", integerType)])
              integerType
              (effectRow EffectRow {request = Map.singleton secondRequestName mempty, tails = mempty})
          callExpr = callExpression (variableExpression (LocalVariableId 9)) [("x", integerLiteral 1)]
          handlerExpr =
            handlerExpressionBuilder
              [integerAnnotation, requestEffectAnnotation fakeRequestName]
              -- The trailing @null@ is a valid resume value for req (which returns null), so only the
              -- body's effect is under test here.
              [requestHandlerForFake (bodyOf [StatementExpression callExpr] (Just nullLiteral))]
              Nothing
          environment =
            (initialCheckerEnvironment typeEnvironmentWithFakeRequest)
              { locals = Map.singleton (LocalVariableId 9) (monoScheme callable)
              }
          (_, diagnostics) = runChecker environment (synthExpressionType handlerExpr)
       in toList diagnostics `shouldBe` []

  describe "synthExpressionType (for)" $ do
    it "iterating an array binds the element at T (no null injected)" $
      let sourceLocal = Map.singleton (LocalVariableId 0) (monoScheme (arrayOf integerType))
          forExpr =
            forExpressionBuilder
              (variablePatternForLocal (LocalVariableId 1))
              (variableExpression (LocalVariableId 0))
              (Block {statements = [forNextStatementBuilder (variableExpression (LocalVariableId 1))], returnExpression = Nothing, sourceSpan = testSpan})
              Nothing
          (result, diagnostics) = runAt sourceLocal mempty (synthExpressionType forExpr)
       in (result, toList diagnostics) `shouldBe` (arrayOf integerType, [])

    it "synthesizes array[T] from a body whose `next` emits T" $
      let sourceLocal = Map.singleton (LocalVariableId 0) (monoScheme (tupleNormalized [integerType]))
          forExpr =
            forExpressionBuilder
              (variablePatternForLocal (LocalVariableId 1))
              (variableExpression (LocalVariableId 0))
              (Block {statements = [forNextStatementBuilder (variableExpression (LocalVariableId 1))], returnExpression = Nothing, sourceSpan = testSpan})
              Nothing
          (result, diagnostics) = runAt sourceLocal mempty (synthExpressionType forExpr)
          expected = arrayOf integerType
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

    it "a body whose tail is an expression (no `next`) maps each element through it" $
      -- for (x in [1]) { x } maps to array[integer]: the body tail is an element, like an implicit `next`.
      let sourceLocal = Map.singleton (LocalVariableId 0) (monoScheme (tupleNormalized [integerType]))
          forExpr =
            forExpressionBuilder
              (variablePatternForLocal (LocalVariableId 1))
              (variableExpression (LocalVariableId 0))
              (exprBlock (variableExpression (LocalVariableId 1)))
              Nothing
          (result, diagnostics) = runAt sourceLocal mempty (synthExpressionType forExpr)
       in (result, toList diagnostics) `shouldBe` (arrayOf integerType, [])

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
          -- array[integer] (from `next`) unioned with the break value's type.
          expected = unionOf (arrayOf integerType) stringType
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

  describe "parallel for with `var` state (K3024)" $ do
    it "rejects a `parallel for` declaring `var` state (concurrent iterations cannot fold an accumulator)" $
      compiledCodes
        ( "agent main() -> integer {\n"
            <> "  parallel for (let value in [1, 2, 3], var total: integer = 0) {\n"
            <> "    next with { total = total + value }\n"
            <> "  } then (_elements) { total }\n"
            <> "}"
        )
        `shouldBe` ["K3024"]

    it "accepts the same accumulator on a sequential `for` (iterations run in order, so the state folds)" $
      compiledCodes
        ( "agent main() -> integer {\n"
            <> "  for (let value in [1, 2, 3], var total: integer = 0) {\n"
            <> "    next with { total = total + value }\n"
            <> "  } then (_elements) { total }\n"
            <> "}"
        )
        `shouldBe` []

    it "accepts a `parallel for` without `var` state (a pure concurrent map)" $
      compiledCodes "agent main() -> array[integer] { parallel for (let value in [1, 2, 3]) { next value * value } }"
        `shouldBe` []

  describe "jump statements" $ do
    it "`return` inside an agent body is in scope (its value is checked at the agent edge, not here)" $
      let action = enterAgentBody (BoundaryId 0) (walkStatements [returnStatementBuilder (integerLiteral 1)] (pure ()))
          (_, diagnostics) = runAt mempty mempty action
       in toList diagnostics `shouldBe` []

    it "`return` inside a request handler body is K3012 (a request handler bars `return`)" $
      -- A request handler clears the return target: a `return` may not escape to the enclosing agent.
      let action = enterRequestHandler (BoundaryId 0) (walkStatements [returnStatementBuilder (integerLiteral 1)] (pure ()))
          (_, diagnostics) = runAt mempty mempty action
       in hasErrorCode "K3012" diagnostics `shouldBe` True

    it "`return` outside an agent body is K3012" $
      let (_, diagnostics) = runAt mempty mempty (walkStatements [returnStatementBuilder (integerLiteral 1)] (pure ()))
       in hasErrorCode "K3012" diagnostics `shouldBe` True

    it "`next` inside a for body is accepted (the element type is inferred)" $
      let action = enterForBody (BoundaryId 0) (walkStatements [forNextStatementBuilder (integerLiteral 1)] (pure ()))
          (_, diagnostics) = runAt mempty mempty action
       in toList diagnostics `shouldBe` []

    it "`break` inside a for body is accepted (it short-circuits with its value)" $
      let action = enterForBody (BoundaryId 0) (walkStatements [forBreakStatementBuilder (stringLiteral "x")] (pure ()))
          (_, diagnostics) = runAt mempty mempty action
       in toList diagnostics `shouldBe` []

    it "for-`next` outside any `for` body is K3012" $
      let (_, diagnostics) = runAt mempty mempty (walkStatements [forNextStatementBuilder (integerLiteral 1)] (pure ()))
       in hasErrorCode "K3012" diagnostics `shouldBe` True

    it "`break` inside a handler frame is accepted (collected into the result, not checked against R)" $
      let action = enterRequestHandler (BoundaryId 0) (walkStatements [breakStatementBuilder (integerLiteral 1)] (pure ()))
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

    it "pure call does not taint the return when the parameter absorbs the private argument" $
      -- The regression this guards: passing a secret to a parameter that already expects a secret
      -- (a sink @agent(x: integer of private) -> integer@) must not leak private-ness into the
      -- otherwise-public return — the private argument is absorbed, not observed.
      let calleeType = pureAgentType (paramObject [("x", ofPrivate integerType)]) integerType
          localBindings =
            Map.fromList
              [ (LocalVariableId 0, monoScheme calleeType),
                (LocalVariableId 1, monoScheme (ofPrivate integerType))
              ]
          privateArg = variableExpression (LocalVariableId 1)
          call = callExpression (variableExpression (LocalVariableId 0)) [("x", privateArg)]
          (result, diagnostics) = runAt localBindings mempty (synthExpressionType call)
       in (result, toList diagnostics) `shouldBe` (integerType, [])

    it "pure call still taints the return when only one of several parameters absorbs the private argument" $
      -- A private argument absorbed at one position must still taint the return when another position
      -- feeds the same private value into a public parameter — absorption is per-position, not global.
      let calleeType =
            pureAgentType
              (paramObject [("absorbed", ofPrivate integerType), ("leaked", integerType)])
              integerType
          localBindings =
            Map.fromList
              [ (LocalVariableId 0, monoScheme calleeType),
                (LocalVariableId 1, monoScheme (ofPrivate integerType))
              ]
          privateArg = variableExpression (LocalVariableId 1)
          call =
            callExpression
              (variableExpression (LocalVariableId 0))
              [("absorbed", privateArg), ("leaked", privateArg)]
          (result, diagnostics) = runAt localBindings mempty (synthExpressionType call)
       in (result, toList diagnostics) `shouldBe` (ofPrivate integerType, [])

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

    it "rejects a bare reference to a generic value, unapplied (K3015)" $
      let environment = checkerEnvironmentWith mempty (Map.singleton topLevelName (identityScheme aId))
          (_, diagnostics) = runChecker environment (synthExpressionType (qualifiedVariableExpression topLevelName))
       in hasErrorCode "K3015" diagnostics `shouldBe` True

  describe "checkExternalReactor (a `from` clause names a reactor this module may use)" $ do
    let userModule = ModuleName "test"
    it "accepts an absent clause (defaults to ffi)" $
      let (_, diagnostics) = runAt mempty mempty (checkExternalReactor testSpan userModule Nothing)
       in toList diagnostics `shouldBe` []
    it "accepts ffi from a user module (the one user-facing channel)" $
      let (_, diagnostics) = runAt mempty mempty (checkExternalReactor testSpan userModule (Just "ffi"))
       in toList diagnostics `shouldBe` []
    it "rejects an unknown reactor name (K3018)" $
      let (_, diagnostics) = runAt mempty mempty (checkExternalReactor testSpan userModule (Just "grpc"))
       in hasErrorCode "K3018" diagnostics `shouldBe` True
    it "rejects a user module's claim on every built-in reactor (K3022)" $
      let rejected reactor =
            let (_, diagnostics) = runAt mempty mempty (checkExternalReactor testSpan userModule (Just reactor))
             in hasErrorCode "K3022" diagnostics
       in all rejected ["http", "webhook", "mcp", "time", "oauth"] `shouldBe` True
    it "accepts a built-in reactor from an embedded stdlib module (its compiled externals ARE the reactor's keys)" $
      let (_, diagnostics) = runAt mempty mempty (checkExternalReactor testSpan (ModuleName "prelude.time") (Just "time"))
       in toList diagnostics `shouldBe` []
    it "rejects a user source declaring `from \"time\"` end to end (K3022, not a runtime dispatch panic)" $
      compiledCodes "external agent my_now() -> number from \"time\"" `shouldContain` ["K3022"]
    it "rejects a user source declaring `from \"oauth\"` end to end (K3022 — the oauth reactor is stdlib-only)" $
      compiledCodes "external agent my_token(name: string) -> string from \"oauth\"" `shouldContain` ["K3022"]
    it "accepts a program calling the stdlib `oauth.token` (the new prelude.oauth module compiles)" $
      compiledCodes "agent main() -> string of private with io | prelude.throw[oauth.server_error] { oauth.token(name = \"github\") }"
        `shouldBe` []

  describe "forever loops (end to end)" $ do
    it "types as never with no break, so it conforms to any declared return" $
      compiledCodes "agent main() -> integer { forever { let _x = 1 } }" `shouldBe` []

    it "propagates the body's effects to the enclosing row (performed every iteration)" $
      compiledCodes "request tick() -> null\nagent daemon() -> never with tick { forever { tick() } }" `shouldBe` []

    it "rejects a body effect the declared row does not carry (the loop performs it every iteration)" $
      compiledCodes "request tick() -> null\nagent daemon() -> never with pure { forever { tick() } }" `shouldSatisfy` (not . null)

    it "types as the break value's type: `break v` exits the loop with `v`" $
      compiledCodes "agent main() -> integer { forever { break 1 } }" `shouldBe` []

    it "rejects a break value that does not match the declared result (K3001)" $
      compiledCodes "agent main() -> integer { forever { break \"x\" } }" `shouldContain` ["K3001"]

    it "unions multiple break values into the loop's result" $
      compiledCodes
        ( "data a()\ndata b()\n"
            <> "agent choose(flag: boolean) -> a | b {\n"
            <> "  forever { if (flag) { break a() } else { break b() } }\n"
            <> "}"
        )
        `shouldBe` []

    it "a break inside forever targets the forever, not an enclosing `for` (the for still yields an array)" $
      compiledCodes
        ( "agent main() -> array[integer] {\n"
            <> "  for (let x in [1, 2, 3]) { forever { break x } }\n"
            <> "}"
        )
        `shouldBe` []

    it "carries `var` state across iterations, advanced by `next … with (…)`, and broken out with a value" $
      compiledCodes
        ( "agent main() -> integer {\n"
            <> "  forever (var n = 0) {\n"
            <> "    if (n < 3) { next with { n = n + 1 } } else { break n }\n"
            <> "  }\n"
            <> "}"
        )
        `shouldBe` []

    it "checks a `with` modifier against its `var` type (K3001 on a mismatch)" $
      compiledCodes "agent main() -> never { forever (var n = 0) { next with { n = \"x\" } } }" `shouldContain` ["K3001"]

    it "a bare `next` (implicit re-iterate) needs no var and keeps the loop typed as never" $
      compiledCodes "request tick() -> null\nagent main() -> never with tick { forever { tick() } }" `shouldBe` []

    it "still supports the composed catch-and-break (a surrounding handler's break exits with the value)" $
      compiledCodes
        ( "request done(value: integer) -> never\n"
            <> "agent main() -> integer {\n"
            <> "  use handler {\n"
            <> "    request done(value: integer) -> never { break value }\n"
            <> "  }\n"
            <> "  forever { done(value = 1) }\n"
            <> "}"
        )
        `shouldBe` []

  -- The residual-type assertions run end to end (through 'Katari.Compile'): the enclosing agent's
  -- return annotation states the expected residual type, so a clean compile IS the type assertion.
  describe "partial application (`_` holes)" $ do
    let scaleDecl = "agent scale(factor: number, value: number) -> number { factor * value }\n"
        tickDecl = "request tick() -> integer\nagent effectful(label: string, count: integer) -> string with tick { label }\n"
        pickDecl = "agent pick[T](value: T, fallback: T) -> T { value }\n"
        defaultedDecl = "agent defaulted(x: integer, y: integer ?= 3) -> integer { x + y }\n"

    it "types the residual as an agent over exactly the holed parameter" $
      compiledCodes (scaleDecl <> "agent partial() -> agent (value: number) -> number { scale(factor = 2.0, value = _) }") `shouldBe` []

    it "rejects a residual annotation whose holed parameter has a different type (K3001)" $
      compiledCodes (scaleDecl <> "agent partial() -> agent (value: string) -> number { scale(factor = 2.0, value = _) }") `shouldContain` ["K3001"]

    it "moves the callee's effect onto the residual: the partial application itself is pure" $
      compiledCodes (tickDecl <> "agent partial() -> agent (count: integer) -> string with tick with pure { effectful(label = \"x\", count = _) }") `shouldBe` []

    it "rejects a residual annotation that drops the callee's effect (K3001)" $
      compiledCodes (tickDecl <> "agent partial() -> agent (count: integer) -> string { effectful(label = \"x\", count = _) }") `shouldContain` ["K3001"]

    it "keeps a holed defaulted parameter optional on the residual" $
      compiledCodes (defaultedDecl <> "agent partial() -> agent (x: integer, y ?: integer) -> integer { defaulted(x = _, y = _) }") `shouldBe` []

    it "rejects a hole label that names no callee parameter (K3020)" $
      compiledCodes (scaleDecl <> "agent partial() -> agent (value: number) -> number { scale(factor = 2.0, wrong = _) }") `shouldContain` ["K3020"]

    it "rejects a required parameter that is neither supplied nor holed (K3001)" $
      compiledCodes (scaleDecl <> "agent partial() -> agent (value: number) -> number { scale(value = _) }") `shouldContain` ["K3001"]

    it "checks a supplied argument against its parameter as a full call would (K3001)" $
      compiledCodes (scaleDecl <> "agent partial() -> agent (value: number) -> number { scale(factor = \"x\", value = _) }") `shouldContain` ["K3001"]

    it "accepts a private supplied argument as a full call would, baking it into a private residual" $
      -- A pure callee lifts across attribute worlds identically at a partial site now that both share
      -- 'Katari.Typechecker.Check.checkArgumentShape': the private `secret` is accepted (a full
      -- `scale(factor = secret, value = 2.0)` would accept it too), and the residual's handle carries
      -- that private attribute, so the residual typed as a `private` agent compiles cleanly.
      compiledCodes (scaleDecl <> "agent partial(secret: number of private) -> (agent (value: number) -> number) of private { scale(factor = secret, value = _) }") `shouldBe` []

    it "carries the baked-in private attribute on the residual — a public residual annotation is rejected (K3001)" $
      compiledCodes (scaleDecl <> "agent partial(secret: number of private) -> agent (value: number) -> number { scale(factor = secret, value = _) }") `shouldContain` ["K3001"]

    it "the residual's eventual result matches a full call's: both observe the private argument (`number of private`)" $
      compiledCodes
        ( scaleDecl
            <> "agent via_full(secret: number of private) -> number of private { scale(factor = secret, value = 21.0) }\n"
            <> "agent via_residual(secret: number of private) -> number of private { let double = scale(factor = secret, value = _)\ndouble(value = 21.0) }"
        )
        `shouldBe` []

    it "infers a generic from the supplied arguments" $
      compiledCodes (pickDecl <> "agent partial() -> agent (value: integer) -> integer { pick(value = _, fallback = 3) }") `shouldBe` []

    it "reports a generic determined only by holed parameters (K3016)" $
      compiledCodes (pickDecl <> "agent partial() -> agent (value: integer, fallback: integer) -> integer { pick(value = _, fallback = _) }") `shouldContain` ["K3016"]

    it "composes with explicit instantiation: `pick[integer](value = _, fallback = _)`" $
      compiledCodes (pickDecl <> "agent partial() -> agent (value: integer, fallback: integer) -> integer { pick[integer](value = _, fallback = _) }") `shouldBe` []

    it "partially applies an agent value (a `let`-bound callee)" $
      compiledCodes (scaleDecl <> "agent partial() -> agent (value: number) -> number { let f = scale\nf(factor = 2.0, value = _) }") `shouldBe` []

    it "the residual is callable like any agent value" $
      compiledCodes (scaleDecl <> "agent run() -> number { let double = scale(factor = 2.0, value = _)\ndouble(value = 21.0) }") `shouldBe` []

    it "rejects a hole in a `use` provider application (K3019)" $
      compiledCodes
        ( "agent provider(continuation: agent (value: null) -> integer, extra: integer) -> integer { continuation(value = null) }\n"
            <> "agent run() -> integer { let x : integer = use provider(extra = _)\nx }"
        )
        `shouldContain` ["K3019"]

  -- A finalizer runs at instance termination — the parent may already be awaiting the instance's
  -- cancellation — so its net effect must be within `io`: it may not escalate a request through that
  -- parent. The rule is checked on the finally body's residual effect (a request handled locally
  -- inside the body is discharged before it counts).
  describe "finally" $ do
    it "accepts a pure finalizer body" $
      compiledCodes "agent main() -> integer { finally { let cleanup = 1 }\n7 }" `shouldBe` []

    it "accepts an io finalizer body, joining its io into the enclosing effect row" $
      compiledCodes
        ( "primitive agent log(message: string) -> null with io\n"
            <> "agent main() -> integer with io { finally { log(message = \"bye\") }\n7 }"
        )
        `shouldBe` []

    it "leaks the finalizer's io into the enclosing row, so a `pure` agent is rejected (K3001)" $
      compiledCodes
        ( "primitive agent log(message: string) -> null with io\n"
            <> "agent main() -> integer with pure { finally { log(message = \"bye\") }\n7 }"
        )
        `shouldContain` ["K3001"]

    it "accepts a finalizer that raises a request it handles locally" $
      compiledCodes
        ( "request ping() -> integer\n"
            <> "agent main() -> integer { finally { use handler { request ping() { next 1 } }\nlet answer = ping() }\n7 }"
        )
        `shouldBe` []

    it "rejects a finalizer that escalates an unhandled throw (K3021)" $
      compiledCodes "agent main() -> integer { finally { prelude.throw(error = \"boom\") }\n7 }"
        `shouldContain` ["K3021"]

    it "rejects a finalizer that escalates a custom request (K3021)" $
      compiledCodes
        ( "request tick() -> integer\n"
            <> "agent main() -> integer with io { finally { let counted = tick() }\n7 }"
        )
        `shouldContain` ["K3021"]

  -- A string literal in type position is that string's singleton type: `"x" <: "x"` and
  -- `"x" <: string`, but never the other way around. Literal types enter through written annotations
  -- (here) and literal-binding generics (below); a string literal EXPRESSION still synthesizes
  -- `string`, so nothing changes for programs that never write a literal type.
  describe "string literal singleton types" $ do
    it "accepts a literal-typed value where the same literal is expected" $
      compiledCodes "agent pass(mode: \"fast\") -> \"fast\" { mode }" `shouldBe` []

    it "accepts a literal-typed value where string is expected (\"x\" <: string)" $
      compiledCodes "agent widen(mode: \"fast\") -> string { mode }" `shouldBe` []

    it "rejects a literal-typed value where a different literal is expected (K3001)" $
      compiledCodes "agent cross(mode: \"fast\") -> \"slow\" { mode }" `shouldContain` ["K3001"]

    it "rejects a plain string where a literal is expected (string </: \"x\", K3001)" $
      compiledCodes "agent narrow(mode: string) -> \"fast\" { mode }" `shouldContain` ["K3001"]

    it "accepts a literal member flowing into a union of literals" $
      compiledCodes "agent pick(mode: \"fast\") -> \"fast\" | \"slow\" { mode }" `shouldBe` []

    it "rejects a literal outside the expected union (K3001)" $
      compiledCodes "agent pick(mode: \"other\") -> \"fast\" | \"slow\" { mode }" `shouldContain` ["K3001"]

    it "checks a literal call argument at its singleton against a literal-annotated parameter" $
      compiledCodes "agent takes(mode: \"fast\") -> \"fast\" { mode }\nagent run() -> \"fast\" { takes(mode = \"fast\") }" `shouldBe` []

    it "rejects a mismatched literal call argument against a literal-annotated parameter (K3001)" $
      compiledCodes "agent takes(mode: \"fast\") -> \"fast\" { mode }\nagent run() -> \"fast\" { takes(mode = \"slow\") }" `shouldContain` ["K3001"]

    it "a string literal expression still synthesizes `string` (a literal-typed let annotation is not met, K3001)" $
      compiledCodes "agent run() -> string { let mode : \"fast\" = \"fast\"\nmode }" `shouldContain` ["K3001"]

  -- The TypeScript `const` type-parameter analog: a `literal`-marked generic binds at a string
  -- literal argument's singleton type; everything else infers exactly as before, and an unmarked
  -- generic can never receive a singleton implicitly.
  describe "literal-binding generic parameters" $ do
    let connectDecl = "agent connect[literal url_type extends string](url: url_type) -> url_type { url }\n"
        plainDecl = "agent plain[T](value: T) -> T { value }\n"

    it "binds the singleton from a literal argument" $
      compiledCodes (connectDecl <> "agent run() -> \"https://x\" { connect(url = \"https://x\") }") `shouldBe` []

    it "the singleton binding is exact — a different literal annotation is rejected (K3001)" $
      compiledCodes (connectDecl <> "agent run() -> \"https://y\" { connect(url = \"https://x\") }") `shouldContain` ["K3001"]

    it "binds plain string from a variable argument" $
      compiledCodes (connectDecl <> "agent run(address: string) -> string { connect(url = address) }") `shouldBe` []

    it "a variable argument never produces a singleton (K3001 against a literal annotation)" $
      compiledCodes (connectDecl <> "agent run(address: string) -> \"https://x\" { connect(url = address) }") `shouldContain` ["K3001"]

    it "an unmarked generic binds string from a literal argument, exactly as before" $
      compiledCodes (plainDecl <> "agent run() -> string { plain(value = \"x\") }") `shouldBe` []

    it "an unmarked generic never binds a singleton implicitly (K3001)" $
      compiledCodes (plainDecl <> "agent run() -> \"x\" { plain(value = \"x\") }") `shouldContain` ["K3001"]

    it "explicit literal instantiation works through type-position literals" $
      compiledCodes (connectDecl <> "agent run() -> \"https://x\" { connect[\"https://x\"](url = \"https://x\") }") `shouldBe` []

    it "explicit literal instantiation rejects a mismatched literal argument (K3001)" $
      compiledCodes (connectDecl <> "agent run() -> \"https://x\" { connect[\"https://x\"](url = \"https://y\") }") `shouldContain` ["K3001"]

    it "a literal request generic stamps the singleton into the performed row" $
      compiledCodes
        ( "request fetch[literal url_type extends string](url: url_type) -> string\n"
            <> "agent run() -> string with fetch[\"https://x\"] { fetch(url = \"https://x\") }"
        )
        `shouldBe` []

    it "the performed singleton row fits under a plain-string row (covariant request parameter)" $
      compiledCodes
        ( "request fetch[literal url_type extends string](url: url_type) -> string\n"
            <> "agent run() -> string with fetch[string] { fetch(url = \"https://x\") }"
        )
        `shouldBe` []

    it "the performed singleton row does not fit under a different literal's row (K3001)" $
      compiledCodes
        ( "request fetch[literal url_type extends string](url: url_type) -> string\n"
            <> "agent run() -> string with fetch[\"https://y\"] { fetch(url = \"https://x\") }"
        )
        `shouldContain` ["K3001"]

  -- A marker effect (`effect name[generics]`) is a pure type-level capability: it rides effect rows,
  -- gates calls, is introduced and discharged by signatures alone, cannot be performed (it binds no
  -- value name) and cannot be handled.
  describe "marker effect declarations" $ do
    let scopedDecl = "effect scoped[resource]\n"
        -- The provide SHAPE, with a neutral name: a higher-order signature that mints the capability
        -- for its callback's row and discharges it from its own result row. A primitive, because only
        -- a signature (not a checked body) can discharge a marker — and a primitive adds no io.
        provideDecl =
          "primitive agent with_resource[R, effect E](run: agent (token: string) -> R with E | scoped[\"db\"]) -> R with E\n"
        workerDecl = "agent worker(token: string) -> integer with scoped[\"db\"] { 0 }\n"

    it "declares a marker and carries it in an effect row" $
      compiledCodes (scopedDecl <> workerDecl) `shouldBe` []

    it "introduces and discharges the marker through the higher-order signature (the result row is pure)" $
      compiledCodes (scopedDecl <> provideDecl <> workerDecl <> "agent main() -> integer with pure { with_resource(run = worker) }") `shouldBe` []

    it "gates a direct call: the marker row does not fit a pure caller (K3001)" $
      compiledCodes (scopedDecl <> workerDecl <> "agent main() -> integer with pure { worker(token = \"t\") }") `shouldContain` ["K3001"]

    it "scopes by argument: a callback tagged with a different resource is rejected (K3001)" $
      compiledCodes
        ( scopedDecl
            <> provideDecl
            <> "agent other_worker(token: string) -> integer with scoped[\"other\"] { 0 }\n"
            <> "agent main() -> integer with pure { with_resource(run = other_worker) }"
        )
        `shouldContain` ["K3001"]

    it "marker generics are phantom, hence row-compared covariantly (a literal tag fits a string tag)" $
      compiledCodes (scopedDecl <> workerDecl <> "agent caller() -> integer with scoped[string] { worker(token = \"t\") }") `shouldBe` []

    it "rejects a handler naming a marker (K3017 — nothing to catch)" $
      compiledCodes
        ( scopedDecl
            <> "agent run() -> integer { use handler { request scoped() -> null { break 0 } }\n1 }"
        )
        `shouldContain` ["K3017"]

    it "a marker is unperformable by construction (no value name to call, K2001)" $
      compiledCodes (scopedDecl <> "agent run() -> null { scoped() }") `shouldContain` ["K2001"]

  -- A scoped provider written with the UNION continuation row `-> R with E | scoped[url]` (the
  -- semantically correct spelling `mcp.provide` / `katari mcp pull`'s `with_tools` declare). Inference
  -- solves the provider's own residual `E` from a call site by CANCELLING the shared `scoped[url]`
  -- entry against the actual's, rather than subtracting it into a lacks set (which the dispose step
  -- then rejected against a rigid `E`). The nested case additionally exercises the name-keyed arg-union:
  -- two literal scopes merge to `scoped["a" | "b"]`, and each provide subtracts its own url from the
  -- merged arg, so both discharge to pure.
  describe "scoped provider inference (union continuation rows)" $ do
    let scopedDecl = "effect scoped[resource]\n"
        stepA = "agent step_a(token: string) -> integer with scoped[\"a\"] { 0 }\n"
        stepB = "agent step_b(token: string) -> integer with scoped[\"b\"] { 0 }\n"
        -- The provider is a primitive (only a signature can discharge a marker; a primitive adds no io),
        -- one over a fixed literal scope and one generic over a literal-binding url.
        withA = "primitive agent with_a[R, effect E](continuation: agent (value: integer) -> R with E | scoped[\"a\"]) -> R with E\n"
        provideUrl = "primitive agent provide[literal URL, R, effect E](url: URL, continuation: agent (value: integer) -> R with E | scoped[URL]) -> R with E\n"

    it "infers a wrapper's residual E through the union row (a rigid E passes through)" $
      -- The regression: solving `with_a`'s E from `k`'s `E | scoped["a"]` used to subtract scoped into a
      -- lacks set, yielding `E \\ scoped` which the dispose rejected against the rigid declared `E`.
      -- Cancelling the shared `scoped["a"]` solves `E := E`, so this compiles.
      compiledCodes
        ( scopedDecl
            <> withA
            <> "agent wrap[R, effect E](k: agent (value: integer) -> R with E | scoped[\"a\"]) -> R with E { with_a(continuation = k) }"
        )
        `shouldBe` []

    it "the same wrapper compiles with explicit generics (the inference-free path was never broken)" $
      compiledCodes
        ( scopedDecl
            <> withA
            <> "agent wrap[R, effect E](k: agent (value: integer) -> R with E | scoped[\"a\"]) -> R with E { with_a[R, E](continuation = k) }"
        )
        `shouldBe` []

    it "a single use-provide over a literal url discharges its scope to pure" $
      compiledCodes
        ( scopedDecl
            <> stepA
            <> provideUrl
            <> "agent single() -> integer with pure {\n  let v : integer = use provide(url = \"a\")\n  step_a(token = \"x\")\n}"
        )
        `shouldBe` []

    it "two nested use-provides compose: a tool from EACH scope (and one from the outer scope) inside the inner block, both discharged to pure" $
      compiledCodes
        ( scopedDecl
            <> stepA
            <> stepB
            <> provideUrl
            <> "agent nested() -> integer with pure {\n"
            <> "  let va : integer = use provide(url = \"a\")\n"
            <> "  let vb : integer = use provide(url = \"b\")\n"
            <> "  let x = step_a(token = \"x\")\n"
            <> "  let y = step_b(token = \"y\")\n"
            <> "  let z = step_a(token = \"z\")\n"
            <> "  x + y + z\n"
            <> "}"
        )
        `shouldBe` []

    it "negative: scoped[\"a\"] alone never satisfies scoped[\"b\"] (K3001)" $
      compiledCodes
        ( scopedDecl
            <> stepB
            <> "agent wrong() -> integer with scoped[\"a\"] { step_b(token = \"x\") }"
        )
        `shouldContain` ["K3001"]

    it "a tail-lacks (override) mismatch names the subtracted marker instead of rendering two identical rows" $ do
      -- An overwrite-spelled provider param `{...E, scoped["x"]}` (tail lacks scoped) against a union
      -- continuation `E | scoped["x"]` (tail lacks nothing): both rows denormalize to `scoped["x"] | E`,
      -- so the message must name the difference (`scoped`) or it reads as two identical rows.
      let message =
            compiledMessages
              ( scopedDecl
                  <> "external agent prov[R, effect E](k: agent (value: null) -> R with {...E, scoped[\"x\"]}) -> R with E\n"
                  <> "agent wrong[R, effect E](k: agent (value: null) -> R with E | scoped[\"x\"]) -> R with io | E { prov[R, E](k = k) }"
              )
      message `shouldSatisfy` Text.isInfixOf "additionally excludes"
      message `shouldSatisfy` Text.isInfixOf "scoped"

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

-- | The error codes of a whole single-module @test@ program compiled through the full pipeline
-- (stdlib spliced in). Used where the assertion needs surface syntax the direct-AST fixtures cannot
-- spell (partial-application holes); @== []@ asserts a clean compile.
compiledCodes :: Text -> List Text
compiledCodes source =
  let result = compile CompileInput {sources = Map.singleton (ModuleName "test") source}
   in [compilerErrorCode located.value | located <- toList result.diagnostics]

-- | The rendered diagnostic text of a single-module compile — for asserting on a message's WORDING
-- (not just its code), e.g. that an override mismatch names the entry it disagrees on.
compiledMessages :: Text -> Text
compiledMessages source =
  renderDiagnostics (compile CompileInput {sources = Map.singleton (ModuleName "test") source}).diagnostics

------------------------------------------------------------------------------------------------
-- Type fixtures
------------------------------------------------------------------------------------------------

tupleNormalized :: List NormalizedType -> NormalizedType
tupleNormalized items =
  layeredOf neverLayer {sequenceLayer = Just NormalizedSequence {items = items, rest = bottomType}}

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

-- | A *closed* record literal's normalized type: like 'recordNormalized' but with a `never` tail — the
-- shape 'synthRecordExpression' produces, which makes a literal a subtype of a homogeneous `record[V]`.
recordNormalizedClosed :: List (Text, NormalizedType) -> NormalizedType
recordNormalizedClosed fieldList =
  layeredOf
    neverLayer
      { objectLayer =
          Just
            NormalizedObject
              { fields = Map.fromList [(name, NormalizedFieldInformation {normalizedType = fieldType, optional = False}) | (name, fieldType) <- fieldList],
                rest = bottomType
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
                value = ArgumentExpression value,
                sourceSpan = testSpan
              }
            | (name, value) <- arguments
          ],
        instantiation = (),
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
    (effectRow EffectRow {request = Map.singleton fakeRequestName mempty, tails = mempty})

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
                GenericParameterInformation {genericId = genericId, kind = GenericKindType, variance = Bivariant, bindsLiteral = False, upperBound = Nothing}
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
              parameterType = recordNormalized [],
              returnType = nullType,
              marker = False
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
      typeOf = (),
      sourceSpan = testSpan
    }

paramBindingFor :: Text -> LocalVariableId -> SyntacticTypeExpression Identified -> ParameterBinding Identified
paramBindingFor paramName localId annotation =
  ParameterBinding
    { annotation = Nothing,
      name = paramName,
      labelReference = Reference {sourceSpan = testSpan, resolution = ()},
      binder =
        BindVariable
          (Reference {sourceSpan = testSpan, resolution = Just (VariableResolutionLocalVariable localId)})
          (Just annotation)
          Nothing,
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
        sourceSpan = testSpan,
        typeOf = ()
      }

literalPattern :: LiteralValue -> Pattern Identified
literalPattern v =
  PatternLiteral
    LiteralPattern {value = v, sourceSpan = testSpan, typeOf = ()}

typeFilterPattern :: TypeFilter -> Pattern Identified -> Pattern Identified
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
    layer.numberLayer == NumberSlotInteger && layer.stringLayer == StringSlotString
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
