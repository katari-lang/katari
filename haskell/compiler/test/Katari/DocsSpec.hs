-- | The @katari docs@ extraction contract: source text in, 'DocsDeclaration' rows out, checked at
-- the level the JSON serialises — signatures, TypeNode renderings and resolutions, defaults, the
-- schema attachment rule, and the Parsed (stdlib) phase. Fixtures are inline sources compiled
-- through the real 'Katari.Compile.compile' driver, so the extraction is exercised against exactly
-- the artifacts the CLI hands it.
module Katari.DocsSpec (spec) where

import Control.Monad (when)
import Data.Map qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Compile (CompileInput (..), CompileResult (..), compile)
import Katari.Data.AST (LiteralValue (..))
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.IR (SchemaInformation (..))
import Katari.Data.JSONSchema (DescribedSchema (..), JSONSchema (..), ObjectSchema (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))
import Katari.Diagnostics (hasErrors, renderDiagnostics)
import Katari.Docs
import Katari.Parser (parseModule)
import Test.Hspec

testModuleName :: ModuleName
testModuleName = ModuleName "test"

-- | Compile one inline module and extract its documented declarations (Typed phase, schemas from
-- the lowered IR — the exact pipeline @katari docs@ drives).
documentedDeclarations :: Text -> IO (List DocsDeclaration)
documentedDeclarations source = do
  let result = compile CompileInput {sources = Map.singleton testModuleName source}
  when (hasErrors result.diagnostics) $
    fail ("fixture does not compile:\n" <> Text.unpack (renderDiagnostics result.diagnostics))
  case extractModules typedExtraction result.typedModules result.loweredModules of
    [docsModule] -> pure docsModule.declarations
    modules -> fail ("expected exactly one documented module, got " <> show (length modules))

declarationNamed :: Text -> List DocsDeclaration -> IO DocsDeclaration
declarationNamed wanted declarations =
  case filter (\declaration -> declaration.name == wanted) declarations of
    [declaration] -> pure declaration
    matches -> fail ("expected exactly one declaration named " <> Text.unpack wanted <> ", got " <> show (length matches))

parameterTypeRendered :: ParameterDocumentation -> Maybe Text
parameterTypeRendered parameter = (.rendered) <$> parameter.parameterType

spec :: Spec
spec = describe "Katari.Docs" $ do
  describe "agent declarations" $ do
    it "documents the signature, parameter TypeNodes and the wire schema" $ do
      declarations <- documentedDeclarations "@\"Greets.\"\nagent greet(name: string) -> string { name }"
      declaration <- declarationNamed "greet" declarations
      declaration.kind `shouldBe` DeclarationKindAgent
      declaration.documentation `shouldBe` Just "Greets."
      declaration.signature `shouldBe` "agent greet(name: string) -> string"
      declaration.private `shouldBe` Just False
      (parameterTypeRendered <$> declaration.parameters) `shouldBe` [Just "string"]
      ((.rendered) <$> declaration.returnType) `shouldBe` Just "string"
      declaration.checkedType `shouldSatisfy` isJust
      ((.output) <$> declaration.schema) `shouldBe` Just SchemaString

    it "carries a parameter annotation into the wire schema's property description" $ do
      declarations <- documentedDeclarations "agent greet(@\"The user's name.\" name: string) -> string { name }"
      declaration <- declarationNamed "greet" declarations
      case declaration.schema of
        Just schemaInformation -> case schemaInformation.input of
          SchemaObject objectSchema ->
            lookup "name" objectSchema.properties
              `shouldBe` Just (SchemaDescribed DescribedSchema {description = "The user's name.", schema = SchemaString})
          other -> expectationFailure ("expected an object input schema, got " <> show other)
        Nothing -> expectationFailure "expected a wire schema on the agent"

    it "documents the effect row and resolves its request reference" $ do
      declarations <-
        documentedDeclarations
          "request tick() -> integer\nagent count() -> integer with tick { tick() }"
      declaration <- declarationNamed "count" declarations
      case declaration.effects of
        Just effects -> do
          effects.rendered `shouldBe` "tick"
          case effects.detail of
            DetailName nameDetail ->
              nameDetail.resolved
                `shouldBe` Just (ResolvedQualifiedName QualifiedName {moduleName = testModuleName, name = "tick"})
            other -> expectationFailure ("expected a name node for the effect row, got " <> show other)
        Nothing -> expectationFailure "expected an effects row on the agent"

    it "includes a private agent, flagged and with the private signature prefix" $ do
      declarations <- documentedDeclarations "private agent hidden() -> integer { 1 }"
      declaration <- declarationNamed "hidden" declarations
      declaration.private `shouldBe` Just True
      declaration.signature `shouldBe` "private agent hidden() -> integer"

    it "documents a generic agent with its parameters resolved as generics, and no schema" $ do
      declarations <- documentedDeclarations "agent pick[T](x: T) -> T { x }"
      declaration <- declarationNamed "pick" declarations
      declaration.signature `shouldBe` "agent pick[T](x: T) -> T"
      ((\generic -> (generic.name, generic.kind)) <$> declaration.generics)
        `shouldBe` [("T", GenericKindType)]
      declaration.schema `shouldBe` Nothing
      case declaration.parameters of
        [parameter] -> case parameter.parameterType of
          Just typeNode -> case typeNode.detail of
            DetailName nameDetail -> nameDetail.resolved `shouldBe` Just (ResolvedGenericParameter "T")
            other -> expectationFailure ("expected a name node for the parameter type, got " <> show other)
          Nothing -> expectationFailure "expected a parameter type annotation"
        parameters -> expectationFailure ("expected one parameter, got " <> show (length parameters))

    it "renders a generic bound with its `extends` clause" $ do
      declarations <- documentedDeclarations "agent widen[T extends number](x: T) -> number { x }"
      declaration <- declarationNamed "widen" declarations
      declaration.signature `shouldBe` "agent widen[T extends number](x: T) -> number"
      ((\generic -> (.rendered) <$> generic.upperBound) <$> declaration.generics) `shouldBe` [Just "number"]

  describe "request declarations" $
    it "documents typed parameters and a `?=` default" $ do
      declarations <-
        documentedDeclarations "request ask(question: string, hint: string ?= \"none\") -> string"
      declaration <- declarationNamed "ask" declarations
      declaration.kind `shouldBe` DeclarationKindRequest
      declaration.private `shouldBe` Nothing
      declaration.signature `shouldBe` "request ask(question: string, hint: string ?= \"none\") -> string"
      ((\parameter -> (parameter.label, parameter.defaultValue)) <$> declaration.parameters)
        `shouldBe` [("question", Nothing), ("hint", Just (LiteralValueString "none"))]
      ((.rendered) <$> declaration.returnType) `shouldBe` Just "string"

  describe "the other declaration kinds" $ do
    it "documents a data declaration with its constructor's wire schema" $ do
      declarations <- documentedDeclarations "data pair(left: integer, right: integer)"
      declaration <- declarationNamed "pair" declarations
      declaration.kind `shouldBe` DeclarationKindData
      declaration.signature `shouldBe` "data pair(left: integer, right: integer)"
      declaration.schema `shouldSatisfy` isJust

    it "documents a type synonym through its definition TypeNode" $ do
      declarations <- documentedDeclarations "type labels = array[string]"
      declaration <- declarationNamed "labels" declarations
      declaration.kind `shouldBe` DeclarationKindTypeSynonym
      declaration.signature `shouldBe` "type labels = array[string]"
      case declaration.definition of
        Just definition -> do
          definition.rendered `shouldBe` "array[string]"
          case definition.detail of
            DetailApplication applicationDetail ->
              ((.rendered) <$> applicationDetail.applicationArguments) `shouldBe` ["string"]
            other -> expectationFailure ("expected an application node, got " <> show other)
        Nothing -> expectationFailure "expected a definition on the synonym"

    it "documents a marker effect" $ do
      declarations <- documentedDeclarations "effect exclusive\nagent noop() -> null { null }"
      declaration <- declarationNamed "exclusive" declarations
      declaration.kind `shouldBe` DeclarationKindMarkerEffect
      declaration.signature `shouldBe` "effect exclusive"

    it "documents an external agent with its reactor clause" $ do
      -- `ffi` is the only reactor a user module may name (K3022 rejects the stdlib-reserved ones),
      -- but it still exercises the clause end to end: parsed, documented, and re-rendered.
      declarations <-
        documentedDeclarations "external agent fetch(url: string) -> string from \"ffi\""
      declaration <- declarationNamed "fetch" declarations
      declaration.kind `shouldBe` DeclarationKindExternalAgent
      declaration.reactor `shouldBe` Just "ffi"
      declaration.signature `shouldBe` "external agent fetch(url: string) -> string from \"ffi\""

  describe "TypeNode rendering" $ do
    it "renders a union and resolves a data-type reference" $ do
      declarations <-
        documentedDeclarations "data pair(left: integer, right: integer)\ntype result = string | pair"
      declaration <- declarationNamed "result" declarations
      case declaration.definition of
        Just definition -> do
          definition.rendered `shouldBe` "string | pair"
          case definition.detail of
            DetailUnion [_, pairBranch] -> case pairBranch.detail of
              DetailName nameDetail ->
                nameDetail.resolved
                  `shouldBe` Just (ResolvedQualifiedName QualifiedName {moduleName = testModuleName, name = "pair"})
              other -> expectationFailure ("expected a name branch, got " <> show other)
            other -> expectationFailure ("expected a two-branch union, got " <> show other)
        Nothing -> expectationFailure "expected a definition on the synonym"

    it "renders an `of private` attribution" $ do
      declarations <- documentedDeclarations "type secret = string of private"
      declaration <- declarationNamed "secret" declarations
      ((.rendered) <$> declaration.definition) `shouldBe` Just "string of private"

    it "parenthesises an agent type inside a union branch (the grammar would swallow the tail)" $ do
      declarations <-
        documentedDeclarations "type source = integer | agent(x: integer) -> integer"
      declaration <- declarationNamed "source" declarations
      ((.rendered) <$> declaration.definition) `shouldBe` Just "integer | (agent(x: integer) -> integer)"

  describe "the Parsed phase (stdlib mode)" $
    it "extracts declarations with null resolutions and no checked type" $ do
      let (module', _) = parseModule testModuleName "agent identity(x: value) -> value { x }\ntype value = string"
      case extractModules parsedExtraction (Map.singleton testModuleName module') mempty of
        [docsModule] -> do
          declaration <- declarationNamed "identity" docsModule.declarations
          declaration.checkedType `shouldBe` Nothing
          declaration.schema `shouldBe` Nothing
          case declaration.parameters of
            [parameter] -> case parameter.parameterType of
              Just typeNode -> case typeNode.detail of
                DetailName nameDetail -> nameDetail.resolved `shouldBe` Nothing
                other -> expectationFailure ("expected a name node, got " <> show other)
              Nothing -> expectationFailure "expected a parameter type annotation"
            parameters -> expectationFailure ("expected one parameter, got " <> show (length parameters))
        modules -> expectationFailure ("expected exactly one documented module, got " <> show (length modules))
