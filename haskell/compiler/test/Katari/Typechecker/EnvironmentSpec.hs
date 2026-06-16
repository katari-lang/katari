module Katari.Typechecker.EnvironmentSpec (spec) where

import Data.Foldable (toList)
import Data.Map qualified as Map
import Data.Text (Text)
import Katari.Data.Environment (DataInformation (..), GenericParameterInformation (..), GenericParameters (..), RequestInformation (..), SynonymInformation (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.NormalizedType (NormalizedKindedType, NormalizedType)
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Data.SourceSpan (Located (..))
import Katari.Data.Variance (Variance (..))
import Katari.Diagnostics (Diagnostics)
import Katari.Error (compilerErrorCode)
import Katari.Identifier (identifyModule, scanExports)
import Katari.Identifier.Monad (IdentifiedModule (..), ImportContext (..), ModuleInterface)
import Katari.Parser (parseModule)
import Katari.Typechecker.Environment (TypeEnvironment (..), buildEnvironment)
import Test.Hspec

spec :: Spec
spec = do
  describe "buildEnvironment (data / request shapes)" $ do
    it "registers a data type's constructor and arity" $ do
      let environment = build "data point(x: integer, y: integer)"
      dataParameterNames environment "point" `shouldBe` Just []
    it "expands a synonym inside a constructor to the same shape as the inlined type" $ do
      -- @count@ via the synonym must normalize to the very same constructor as @plain@ written directly.
      let environment = build "type Id[T] = T\ndata count(n: Id[integer])\ndata plain(n: integer)"
      constructorOf environment "count" `shouldBe` constructorOf environment "plain"
    it "expands a nested synonym chain" $ do
      let environment = build "type A[T] = B[T]\ntype B[T] = array[T]\ndata holder(items: A[integer])\ndata direct(items: array[integer])"
      constructorOf environment "holder" `shouldBe` constructorOf environment "direct"
    it "stores a synonym's normalized definition" $ do
      let environment = build "type Id[T] = T"
      synonymParameterNames environment "Id" `shouldBe` Just ["T"]

  describe "buildEnvironment (variance inference)" $ do
    it "infers covariant for a plain constructor field" $
      varianceOfData (build "data box[T](value: T)") "box" "T" `shouldBe` Just Covariant
    it "infers contravariant for a field in function-argument position" $
      varianceOfData (build "data sink[T](consume: agent T -> null)") "sink" "T" `shouldBe` Just Contravariant
    it "infers invariant when a parameter appears in both polarities" $
      varianceOfData (build "data cell[T](get: T, put: agent T -> null)") "cell" "T" `shouldBe` Just Invariant
    it "infers bivariant for an unused parameter" $
      varianceOfData (build "data phantom[T](x: integer)") "phantom" "T" `shouldBe` Just Bivariant
    it "propagates variance through a nested data application (covariant ∘ covariant)" $
      varianceOfData (build "data box[T](value: T)\ndata wrap[T](inner: box[T])") "wrap" "T" `shouldBe` Just Covariant
    it "flips variance through a nested contravariant data application" $
      varianceOfData (build "data sink[T](consume: agent T -> null)\ndata wrap[T](inner: sink[T])") "wrap" "T" `shouldBe` Just Contravariant

  describe "buildEnvironment (request variance)" $ do
    it "infers contravariant for a request return type (dual to a function)" $
      varianceOfRequest (build "request ask[T]() -> T") "ask" "T" `shouldBe` Just Contravariant
    it "infers covariant for a request parameter" $
      varianceOfRequest (build "request tell[T](message: T) -> null") "tell" "T" `shouldBe` Just Covariant

  describe "buildEnvironment (generic upper bounds)" $ do
    it "stores a declared upper bound, normalized so equal bound texts agree" $ do
      -- @integer@ is concrete (no generic ids), so the two declarations' bounds normalize identically
      -- even though their parameter ids differ — proving the bound is captured and normalized, not dropped.
      let environment = build "data a[T extends integer](v: T)\ndata b[U extends integer](v: U)"
      boundOfData environment "a" "T" `shouldBe` boundOfData environment "b" "U"
    it "distinguishes different declared bounds" $ do
      let environment = build "data a[T extends integer](v: T)\ndata b[U extends string](v: U)"
      boundOfData environment "a" "T" `shouldNotBe` boundOfData environment "b" "U"
    it "leaves an unbounded parameter without a bound" $
      boundOfData (build "data box[T](value: T)") "box" "T" `shouldBe` Nothing

  describe "buildEnvironment (cross-module variance)" $
    it "keeps two modules' generics distinct even when they share a generic id" $ do
      -- Each module restarts generic-id numbering at 0, so box.T and sink.U both get id 0. Keying the
      -- variance fixed point by id (rather than by qualified name + parameter name) would conflate them
      -- and collapse both to Invariant.
      let environment =
            buildModules
              [ (ModuleName "a", "data box[T](value: T)"),
                (ModuleName "b", "data sink[U](consume: agent U -> null)")
              ]
      varianceOfDataIn environment (ModuleName "a") "box" "T" `shouldBe` Just Covariant
      varianceOfDataIn environment (ModuleName "b") "sink" "U" `shouldBe` Just Contravariant

  describe "buildEnvironment (elaboration coverage)" $ do
    it "elaborates an attributed field with no error" $
      codesOf (buildDiagnostics "data secret(value: integer of private)") `shouldBe` []
    it "elaborates a with-effect function field with no error" $
      codesOf (buildDiagnostics "request log(line: string) -> null\ndata handlerHolder(run: agent integer -> integer with log)") `shouldBe` []
    it "elaborates a union field with no error" $
      codesOf (buildDiagnostics "data choice(value: integer | string)") `shouldBe` []

  describe "buildEnvironment (elaboration errors)" $ do
    it "reports a synonym cycle (K3010)" $
      codesOf (buildDiagnostics "type A = B\ntype B = A") `shouldContain` ["K3010"]
    it "reports wrong type-argument arity (K3009)" $
      codesOf (buildDiagnostics "data box[T](value: T)\ndata bad(b: box[integer, string])") `shouldContain` ["K3009"]
    it "reports a kind mismatch when a type is used as an attribute (K3007)" $
      codesOf (buildDiagnostics "data bad(value: integer of integer)") `shouldContain` ["K3007"]

------------------------------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------------------------------

testModuleName :: ModuleName
testModuleName = ModuleName "test"

qualifiedNameOf :: Text -> QualifiedName
qualifiedNameOf name = QualifiedName {moduleName = testModuleName, name = name}

-- | Parse, identify, and build the type environment for a single-module program.
buildWithDiagnostics :: Text -> (TypeEnvironment, Diagnostics)
buildWithDiagnostics source =
  let (parsed, _) = parseModule testModuleName source
      interface :: ModuleInterface
      interface = scanExports testModuleName parsed
      importContext = ImportContext {moduleInterfaces = Map.singleton testModuleName interface, defaultImports = []}
      (identified, _) = identifyModule importContext testModuleName parsed
   in buildEnvironment (Map.singleton testModuleName identified.identifiedAst)

build :: Text -> TypeEnvironment
build = fst . buildWithDiagnostics

-- | Parse, identify, and build the type environment for several modules at once, to exercise the
-- cross-module variance fixed point (where generic ids from different modules collide).
buildModules :: [(ModuleName, Text)] -> TypeEnvironment
buildModules sources =
  let parsed = Map.fromList [(moduleName, fst (parseModule moduleName source)) | (moduleName, source) <- sources]
      interfaces = Map.mapWithKey scanExports parsed
      importContext = ImportContext {moduleInterfaces = interfaces, defaultImports = []}
      identified = Map.mapWithKey (\moduleName ast -> fst (identifyModule importContext moduleName ast)) parsed
   in fst (buildEnvironment ((\identifiedModule -> identifiedModule.identifiedAst) <$> identified))

buildDiagnostics :: Text -> Diagnostics
buildDiagnostics = snd . buildWithDiagnostics

codesOf :: Diagnostics -> [Text]
codesOf = map (\Located {value = compilerError} -> compilerErrorCode compilerError) . toList

dataInfoOf :: TypeEnvironment -> Text -> Maybe DataInformation
dataInfoOf environment name = Map.lookup (qualifiedNameOf name) environment.dataEnvironment

constructorOf :: TypeEnvironment -> Text -> Maybe NormalizedType
constructorOf environment name = (.constructor) <$> dataInfoOf environment name

dataParameterNames :: TypeEnvironment -> Text -> Maybe [Text]
dataParameterNames environment name = (\info -> info.genericParameters.parameterNames) <$> dataInfoOf environment name

synonymParameterNames :: TypeEnvironment -> Text -> Maybe [Text]
synonymParameterNames environment name =
  (\info -> info.genericParameters.parameterNames) <$> Map.lookup (qualifiedNameOf name) environment.synonymEnvironment

varianceOfData :: TypeEnvironment -> Text -> Text -> Maybe Variance
varianceOfData environment dataName parameterName = do
  info <- dataInfoOf environment dataName
  parameter <- Map.lookup parameterName info.genericParameters.parameterInformation
  pure parameter.variance

boundOfData :: TypeEnvironment -> Text -> Text -> Maybe NormalizedKindedType
boundOfData environment dataName parameterName = do
  info <- dataInfoOf environment dataName
  parameter <- Map.lookup parameterName info.genericParameters.parameterInformation
  parameter.upperBound

varianceOfDataIn :: TypeEnvironment -> ModuleName -> Text -> Text -> Maybe Variance
varianceOfDataIn environment moduleName dataName parameterName = do
  info <- Map.lookup (QualifiedName {moduleName = moduleName, name = dataName}) environment.dataEnvironment
  parameter <- Map.lookup parameterName info.genericParameters.parameterInformation
  pure parameter.variance

varianceOfRequest :: TypeEnvironment -> Text -> Text -> Maybe Variance
varianceOfRequest environment requestName parameterName = do
  info <- Map.lookup (qualifiedNameOf requestName) environment.requestEnvironment
  parameter <- Map.lookup parameterName info.genericParameters.parameterInformation
  pure parameter.variance
