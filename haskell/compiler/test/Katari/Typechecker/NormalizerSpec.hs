module Katari.Typechecker.NormalizerSpec (spec) where

import Control.Monad (void)
import Control.Monad.RWS.CPS (runRWS)
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.Environment (DataInfo (..), GenericParameterInfo (..), RequestInfo (..))
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.Id (GenericId (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.NormalizedType
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SemanticType (FieldInformation (..), SemanticAttribute (..), SemanticEffect (..), SemanticGenericArgument (..), SemanticType (..), renderSemanticType)
import Katari.Data.Variance (Variance (..))
import Katari.Error (typeErrorCode)
import Katari.Typechecker.Normalizer
import Test.Hspec

spec :: Spec
spec = do
  describe "subtype" $ do
    it "accepts data <: same data (same arguments)" $
      fooOf intType `shouldBeSubtypeOf` fooOf intType
    it "accepts data <: same data (covariant widening)" $
      fooOf intType `shouldBeSubtypeOf` fooOf numberType
    it "rejects data <: same data with incompatible arguments" $
      fooOf intType `shouldNotBeSubtypeOf` fooOf stringType
    it "accepts data <: its constructor object" $
      fooOf intType `shouldBeSubtypeOf` objectOf [("x", intType)]
    it "accepts data <: constructor object with a field supertype" $
      fooOf intType `shouldBeSubtypeOf` objectOf [("x", numberType)]
    it "rejects data <: object with an incompatible field" $
      fooOf intType `shouldNotBeSubtypeOf` objectOf [("x", stringType)]
    it "rejects data <: object with an extra required field" $
      fooOf intType `shouldNotBeSubtypeOf` objectOf [("x", intType), ("y", intType)]
    it "falls back to the constructor when nominal arguments fail" $
      fooOf intType `shouldBeSubtypeOf` unionOf (fooOf stringType) (objectOf [("x", intType)])
    it "rejects data <: string" $
      fooOf intType `shouldNotBeSubtypeOf` stringType
    it "rejects object <: data (no implicit constructor injection)" $
      objectOf [("x", intType)] `shouldNotBeSubtypeOf` fooOf intType
    it "accepts a private data field <: object of private" $
      fooOf (privateOf intType) `shouldBeSubtypeOf` privateOf (objectOf [("x", intType)])
    it "rejects a private data field <: public object" $
      fooOf (privateOf intType) `shouldNotBeSubtypeOf` objectOf [("x", intType)]
    it "accepts a private covariant data argument <: data of private" $
      fooOf (privateOf intType) `shouldBeSubtypeOf` privateOf (fooOf intType)
    it "rejects a private covariant data argument <: public data" $
      fooOf (privateOf intType) `shouldNotBeSubtypeOf` fooOf intType
    it "accepts a private invariant data argument under a private expectation (world)" $
      -- inside @inv[...] of private@ the world is private, so the invariant argument is compared as
      -- inside @inv[...] of private@ the world is private, so the invariant argument is compared as
      -- private on both sides — @inv[integer of private]@ matches @inv[integer]@ there.
      -- private on both sides — @inv[integer of private]@ matches @inv[integer]@ there.

      -- inside @inv[...] of private@ the world is private, so the invariant argument is compared as
      -- private on both sides — @inv[integer of private]@ matches @inv[integer]@ there.
      invOf (privateOf intType) `shouldBeSubtypeOf` privateOf (invOf intType)
    it "accepts an invariant data <: itself of private" $
      invOf intType `shouldBeSubtypeOf` privateOf (invOf intType)
    it "rejects null <: integer" $
      nullType `shouldNotBeSubtypeOf` intType
    it "accepts null <: null | integer" $
      nullType `shouldBeSubtypeOf` unionOf nullType intType

  describe "subtype (generic bounds)" $ do
    it "rejects an unbounded generic <: a concrete type (the default bound is top)" $
      genericOf unboundedGeneric `shouldNotBeSubtypeOf` intType
    it "accepts a bounded generic under its bound's supertype" $
      genericOf boundedGeneric `shouldBeSubtypeOf` numberType
    it "rejects a bounded generic outside its bound" $
      genericOf boundedGeneric `shouldNotBeSubtypeOf` stringType
    it "cancels a generic shared by both sides" $
      genericOf unboundedGeneric `shouldBeSubtypeOf` genericOf unboundedGeneric

  describe "subtype (unknown compares only the outermost attribute)" $ do
    it "accepts a public object <: unknown" $
      objectOf [("x", intType)] `shouldBeSubtypeOf` unknownType
    it "accepts a public container with a private field <: public unknown" $
      objectOf [("x", privateOf intType)] `shouldBeSubtypeOf` unknownType
    it "accepts a private container <: unknown of private" $
      privateOf (objectOf [("x", intType)]) `shouldBeSubtypeOf` privateOf unknownType
    it "rejects a private container <: public unknown" $
      privateOf (objectOf [("x", intType)]) `shouldNotBeSubtypeOf` unknownType

  describe "subtype (effect shadowing)" $ do
    it "keeps a row's shadow guarantees while absorbing the generic's bound" $
      normalizerErrors (subtype shadowingRow shadowedSupertype) `shouldBe` []

  describe "normalizeEffect (overwrite)" $ do
    it "unions nested overwrite shadows instead of replacing them" $
      runNormalizer
        (normalizeEffect (SemanticEffectOverwrite (SemanticEffectOverwrite (SemanticEffectGeneric effectGeneric) [(askName, mempty)]) [(logName, mempty)]))
        `shouldBe` NormalizedEffectRow
          EffectRow
            { request = Map.fromList [(askName, mempty), (logName, mempty)],
              generic = Set.singleton effectGeneric,
              shadowed = Set.fromList [askName, logName]
            }
    it "records no shadow over a concrete base" $
      runNormalizer (normalizeEffect (SemanticEffectOverwrite (SemanticEffectRequest askName mempty) [(askName, mempty)]))
        `shouldBe` NormalizedEffectRow
          EffectRow
            { request = Map.singleton askName mempty,
              generic = mempty,
              shadowed = mempty
            }

  describe "normalizeType (generic arity)" $ do
    it "accepts a data application with exactly the declared arguments" $
      normalizerErrors (void (normalizeType (SemanticTypeData fooName (Map.singleton "T" (SemanticGenericArgumentType SemanticTypeInteger)))))
        `shouldBe` []
    it "reports K3008 when generic arguments are missing" $
      (typeErrorCode <$> normalizerErrors (void (normalizeType (SemanticTypeData fooName mempty))))
        `shouldBe` ["K3008"]
    it "reports K3008 for an argument name the declaration does not have" $
      (typeErrorCode <$> normalizerErrors (void (normalizeEffect (SemanticEffectRequest askName (Map.singleton "X" (SemanticGenericArgumentType SemanticTypeInteger))))))
        `shouldBe` ["K3008"]

  describe "subtype (world)" $ do
    it "accepts a public function as a private function" $
      -- a public function is usable in a private context; lifting to accept / return private is not
      -- a public function is usable in a private context; lifting to accept / return private is not
      -- a declassification, so this holds (the reverse does not).
      -- a declassification, so this holds (the reverse does not).

      -- a public function is usable in a private context; lifting to accept / return private is not
      -- a declassification, so this holds (the reverse does not).
      functionOf intType intType `shouldBeSubtypeOf` privateOf (functionOf intType intType)
    it "rejects a private function as a public function" $
      privateOf (functionOf intType intType) `shouldNotBeSubtypeOf` functionOf intType intType
    it "compares a private union's public-looking branch as private" $
      -- the object branch of @(integer of private) | {x: integer}@ is observed privately because the
      -- the object branch of @(integer of private) | {x: integer}@ is observed privately because the
      -- node is private, so a fully-private object fits under it — without any attribute push-down.
      -- node is private, so a fully-private object fits under it — without any attribute push-down.

      -- the object branch of @(integer of private) | {x: integer}@ is observed privately because the
      -- node is private, so a fully-private object fits under it — without any attribute push-down.
      privateOf (objectOf [("x", intType)])
        `shouldBeSubtypeOf` runNormalizer (union (privateOf intType) (objectOf [("x", intType)]))

  describe "normalizeType" $
    it "puts 'of private' on the node, fields untouched (no distribution)" $
      runNormalizer (normalizeType (SemanticTypeAttribute semanticIntObject SemanticAttributePrivate))
        `shouldBe` privateOf (objectOf [("x", intType)])

  describe "denormalize" $ do
    it "renders the node attribute, with fields exactly where they sit" $
      runNormalizer (denormalize (privateOf (objectOf [("x", intType)])))
        `shouldBe` SemanticTypeAttribute semanticIntObject SemanticAttributePrivate
    it "leaves a public type unwrapped" $
      runNormalizer (denormalize intType) `shouldBe` SemanticTypeInteger
    it "round-trips through normalizeType on a normal-form type" $
      runNormalizer (normalizeType =<< denormalize (privateOf (objectOf [("x", intType)])))
        `shouldBe` privateOf (objectOf [("x", intType)])
    it "renders in surface syntax via renderSemanticType" $
      renderSemanticType (runNormalizer (denormalize (privateOf (objectOf [("x", intType)]))))
        `shouldBe` "{x: integer} of private"

shouldBeSubtypeOf :: NormalizedType -> NormalizedType -> Expectation
shouldBeSubtypeOf left right = normalizerErrors (subtype left right) `shouldBe` []

shouldNotBeSubtypeOf :: NormalizedType -> NormalizedType -> Expectation
shouldNotBeSubtypeOf left right = normalizerErrors (subtype left right) `shouldSatisfy` (not . null)

runNormalizer :: Normalizer a -> a
runNormalizer action = let (result, _, _) = runRWS action environment () in result

normalizerErrors :: Normalizer a -> List NormalizeError
normalizerErrors action = let (_, _, errors) = runRWS action environment () in errors

genericT :: GenericId
genericT = GenericId 0

-- | Registered in 'environment' with the bound @integer@.
boundedGeneric :: GenericId
boundedGeneric = GenericId 1

-- | Not registered in 'environment'; its bound defaults to top.
unboundedGeneric :: GenericId
unboundedGeneric = GenericId 9

effectGeneric :: GenericId
effectGeneric = GenericId 2

-- | Registered in 'environment' with the effect bound @log@.
boundedEffectGeneric :: GenericId
boundedEffectGeneric = GenericId 3

fooName :: QualifiedName
fooName = QualifiedName {moduleName = ModuleName "test", name = "foo"}

invName :: QualifiedName
invName = QualifiedName {moduleName = ModuleName "test", name = "inv"}

askName :: QualifiedName
askName = QualifiedName {moduleName = ModuleName "test", name = "ask"}

logName :: QualifiedName
logName = QualifiedName {moduleName = ModuleName "test", name = "log"}

-- | @{...E, ask}@ with @E@'s bound being @log@: requests {ask}, generic {E}, shadowed {ask}.
shadowingRow :: NormalizedEffect
shadowingRow =
  NormalizedEffectRow
    EffectRow
      { request = Map.singleton askName mempty,
        generic = Set.singleton boundedEffectGeneric,
        shadowed = Set.singleton askName
      }

-- | @{...log, ask}@ written concretely: requests {ask, log}, shadowed {ask}.
shadowedSupertype :: NormalizedEffect
shadowedSupertype =
  NormalizedEffectRow
    EffectRow
      { request = Map.fromList [(askName, mempty), (logName, mempty)],
        generic = mempty,
        shadowed = Set.singleton askName
      }

-- | data foo[T](x: T) with T covariant, and inv[T](x: T) with a (hand-declared) invariant T.
-- Requests ask / log take no generics. Bounds: 'boundedGeneric' extends integer,
-- 'boundedEffectGeneric' extends the effect log.
environment :: NormalizerEnvironment
environment =
  NormalizerEnvironment
    { dataEnvironment =
        Map.fromList
          [ (fooName, dataInfoOf fooName Covariant),
            (invName, dataInfoOf invName Invariant)
          ],
      requestEnvironment =
        Map.fromList
          [ (askName, requestInfoOf askName),
            (logName, requestInfoOf logName)
          ],
      genericBoundEnvironment =
        Map.fromList
          [ (boundedGeneric, NormalizedGenericArgumentType intType),
            (boundedEffectGeneric, NormalizedGenericArgumentEffect (NormalizedEffectRow EffectRow {request = Map.singleton logName mempty, generic = mempty, shadowed = mempty}))
          ],
      world = bottomAttribute
    }
  where
    dataInfoOf qualifiedName argumentVariance =
      DataInfo
        { name = qualifiedName,
          genericParameters = [GenericParameterInfo {name = "T", genericId = genericT, kind = GenericKindType, variance = argumentVariance}],
          constructor = objectOf [("x", genericOf genericT)]
        }
    requestInfoOf qualifiedName =
      RequestInfo
        { name = qualifiedName,
          genericParameters = [],
          request = (bottomType, bottomType)
        }

layerType :: LayeredType -> NormalizedType
layerType layer = NormalizedType {baseType = NormalizedBaseTypeLayered layer, generics = Set.empty, attribute = bottomAttribute}

unknownType :: NormalizedType
unknownType = NormalizedType {baseType = NormalizedBaseTypeUnknown, generics = Set.empty, attribute = bottomAttribute}

intType :: NormalizedType
intType = layerType neverLayer {numberLayer = NumberSlotInteger}

numberType :: NormalizedType
numberType = layerType neverLayer {numberLayer = NumberSlotNumber}

stringType :: NormalizedType
stringType = layerType neverLayer {stringLayer = True}

nullType :: NormalizedType
nullType = layerType neverLayer {nullLayer = True}

genericOf :: GenericId -> NormalizedType
genericOf genericId = NormalizedType {baseType = NormalizedBaseTypeLayered neverLayer, generics = Set.singleton genericId, attribute = bottomAttribute}

-- | Make a type private: set the @private@ flag on its node attribute. With world-based subtyping
-- the attribute is not distributed — it sits on the node, the way the user would write @of private@.
privateOf :: NormalizedType -> NormalizedType
privateOf normalizedType = normalizedType {attribute = normalizedType.attribute {private = True}}

functionOf :: NormalizedType -> NormalizedType -> NormalizedType
functionOf argumentType returnType = layerType neverLayer {functionLayer = Just NormalizedFunction {argumentType = argumentType, returnType = returnType, effect = bottomEffect}}

fooOf :: NormalizedType -> NormalizedType
fooOf argument = layerType neverLayer {dataLayer = Map.singleton fooName (Map.singleton "T" (NormalizedGenericArgumentType argument))}

invOf :: NormalizedType -> NormalizedType
invOf argument = layerType neverLayer {dataLayer = Map.singleton invName (Map.singleton "T" (NormalizedGenericArgumentType argument))}

objectOf :: List (Text, NormalizedType) -> NormalizedType
objectOf fieldList = objectWith fieldList unknownType

objectWith :: List (Text, NormalizedType) -> NormalizedType -> NormalizedType
objectWith fieldList restType =
  layerType
    neverLayer
      { objectLayer =
          Just $
            NormalizedObject
              { fields = Map.fromList [(fieldName, NormalizedFieldInformation {normalizedType = fieldType, optional = False}) | (fieldName, fieldType) <- fieldList],
                rest = restType
              }
      }

semanticIntObject :: SemanticType
semanticIntObject = SemanticTypeObject (Map.singleton "x" FieldInformation {semanticType = SemanticTypeInteger, optional = False})

unionOf :: NormalizedType -> NormalizedType -> NormalizedType
unionOf left right =
  let (unioned, _, errors) = runRWS (left `union` right) environment ()
   in if null errors then unioned else error "unionOf: unexpected errors"
