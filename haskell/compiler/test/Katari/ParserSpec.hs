module Katari.ParserSpec (spec) where

import Data.Foldable (toList)
import Data.Text (Text)
import Katari.Data.AST
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.SourceSpan (Located (..))
import Katari.Error (compilerErrorCode)
import Katari.Parser (parseModule)
import Test.Hspec

-- | Parse, asserting there were no diagnostics, and hand back the module.
parseClean :: Text -> IO (Module Parsed)
parseClean source = do
  let (module', diagnostics) = parseModule (ModuleName "test") source
  diagnostics `shouldSatisfy` null
  pure module'

shouldFail :: Text -> Expectation
shouldFail source = snd (parseModule (ModuleName "test") source) `shouldNotSatisfy` null

-- | The diagnostic codes emitted while parsing @source@.
codesOf :: Text -> [Text]
codesOf source = [compilerErrorCode located.value | located <- toList (snd (parseModule (ModuleName "test") source))]

-- | The single agent declaration's body block, or a test failure.
soleAgentBody :: Module Parsed -> IO (Block Parsed)
soleAgentBody module' = case module'.declarations of
  [DeclarationAgent agent] -> pure agent.body
  _ -> expectationFailure "expected exactly one agent declaration" >> error "unreachable"

spec :: Spec
spec = do
  describe "declarations" $ do
    it "parses a hello-world agent" $ do
      module' <- parseClean "agent main() -> string { \"hello, world\" }"
      case module'.declarations of
        [DeclarationAgent agent] -> do
          agent.name `shouldBe` "main"
          agent.private `shouldBe` False
        _ -> expectationFailure "expected one agent"

    it "keeps a doc annotation on the declaration" $ do
      module' <- parseClean "@\"greeting\"\nagent main() -> string { \"hi\" }"
      case module'.declarations of
        [DeclarationAgent agent] -> agent.annotation `shouldBe` Just "greeting"
        _ -> expectationFailure "expected one agent"

    it "parses a private agent" $ do
      module' <- parseClean "private agent secret() -> integer { 1 }"
      case module'.declarations of
        [DeclarationAgent agent] -> agent.private `shouldBe` True
        _ -> expectationFailure "expected one agent"

    it "parses parameters, generics, return type and effects" $ do
      module' <- parseClean "agent run[T]() -> integer with tick { 1 }"
      case module'.declarations of
        [DeclarationAgent agent] -> do
          length agent.genericParameters `shouldBe` 1
          agent.effects `shouldSatisfy` (/= Nothing)
        _ -> expectationFailure "expected one agent"

    it "parses an agent parameter written as label => pattern" $ do
      module' <- parseClean "agent coord(p => pt: point) -> integer { 1 }"
      case module'.declarations of
        [DeclarationAgent agent] -> case agent.parameters of
          [binding] -> do
            binding.name `shouldBe` "p"
            case binding.bindPattern of
              PatternVariable variable -> variable.name `shouldBe` "pt"
              _ -> expectationFailure "expected a variable bind pattern"
          _ -> expectationFailure "expected one parameter"
        _ -> expectationFailure "expected one agent"

    it "parses a generic parameter with an extends bound" $ do
      module' <- parseClean "agent identity[T extends integer](x: T) -> T { x }"
      case module'.declarations of
        [DeclarationAgent agent] -> case agent.genericParameters of
          [parameter] -> parameter.upperBound `shouldSatisfy` (/= Nothing)
          _ -> expectationFailure "expected one generic parameter"
        _ -> expectationFailure "expected one agent"

    it "parses a request declaration" $ do
      module' <- parseClean "request bump(n: integer) -> integer"
      case module'.declarations of
        [DeclarationRequest request] -> do
          request.name `shouldBe` "bump"
          length request.parameters `shouldBe` 1
        _ -> expectationFailure "expected one request"

    it "parses an external agent with a function-typed parameter" $ do
      module' <- parseClean "external agent cron(callback: agent () -> null with scheduled) -> null"
      case module'.declarations of
        [DeclarationExternalAgent external] -> external.name `shouldBe` "cron"
        _ -> expectationFailure "expected one external agent"

    it "parses a primitive agent" $ do
      module' <- parseClean "primitive agent add(a: integer, b: integer) -> integer"
      case module'.declarations of
        [DeclarationPrimitiveAgent primitive] -> length primitive.parameters `shouldBe` 2
        _ -> expectationFailure "expected one primitive agent"

    it "parses a data declaration" $ do
      module' <- parseClean "data point(x: integer, y: integer)"
      case module'.declarations of
        [DeclarationData dataDeclaration] -> do
          dataDeclaration.name `shouldBe` "point"
          length dataDeclaration.parameters `shouldBe` 2
        _ -> expectationFailure "expected one data"

    it "parses a type synonym with generics" $ do
      module' <- parseClean "type pair[T] = (T, T)"
      case module'.declarations of
        [DeclarationTypeSynonym synonym] -> synonym.name `shouldBe` "pair"
        _ -> expectationFailure "expected one type synonym"

    it "parses several declarations in one module" $ do
      module' <- parseClean "data point(x: integer)\n\nagent main() -> integer { 1 }"
      length module'.declarations `shouldBe` 2

  describe "imports" $ do
    it "parses a prefix module import" $ do
      module' <- parseClean "import list_utils.helpers"
      case module'.declarations of
        [DeclarationImport (ImportDeclaration {kind = ImportModule m})] -> m.moduleName `shouldBe` ModuleName "list_utils.helpers"
        _ -> expectationFailure "expected a module import"

    it "parses an aliased import" $ do
      module' <- parseClean "import foo.bar as baz"
      case module'.declarations of
        [DeclarationImport (ImportDeclaration {kind = ImportModule m})] -> m.alias `shouldBe` Just "baz"
        _ -> expectationFailure "expected a module import"

    it "parses a named import with a type item" $ do
      module' <- parseClean "import { double, type Pair } from list_utils"
      case module'.declarations of
        [DeclarationImport (ImportDeclaration {kind = ImportNames names})] -> length names.items `shouldBe` 2
        _ -> expectationFailure "expected a named import"

  describe "expressions and statements" $ do
    it "parses binary operators with precedence" $ do
      body <- parseClean "agent main() -> integer { 1 + 2 * 3 }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionBinaryOperator node) -> node.operator `shouldBe` BinaryOperatorAdd
        _ -> expectationFailure "expected a top-level addition"

    it "parses a let chain ending in a value" $ do
      body <- parseClean "agent main() -> integer {\n  let a = 1\n  let b = 2\n  a + b\n}" >>= soleAgentBody
      length body.statements `shouldBe` 2
      body.returnExpression `shouldSatisfy` (/= Nothing)

    it "parses calls with keyword arguments" $ do
      body <- parseClean "agent main() -> integer { sum_two(a = 2, b = 3) }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionCall node) -> length node.arguments `shouldBe` 2
        _ -> expectationFailure "expected a call"

    it "parses a record literal and field access" $ do
      _ <- parseClean "agent main() -> integer { let r = { name = \"a\", age = 30 }\n r.age }"
      pure ()

    it "parses an f-string with interpolation" $ do
      body <- parseClean "agent main() -> string { f\"sum = ${total}\" }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionTemplate node) -> length node.elements `shouldBe` 2
        _ -> expectationFailure "expected a template"

    it "parses if / else if / else" $ do
      _ <- parseClean "agent main() -> string { if (n > 0) { \"p\" } else if (n < 0) { \"n\" } else { \"z\" } }"
      pure ()

    it "parses match with constructor, type-filter and record patterns" $ do
      body <-
        parseClean "agent describe(value: unknown) -> string {\n  match (value) {\n    case integer(n) -> \"int\"\n    case point(x => xv, y => yv) -> \"point\"\n    case { name => string(s) } -> \"named\"\n    case _ -> \"other\"\n  }\n}"
          >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionMatch node) -> length node.cases `shouldBe` 4
        _ -> expectationFailure "expected a match"

    it "parses a narrowing annotated variable pattern" $ do
      _ <- parseClean "agent main() -> integer { match (v) { case n: integer -> n\n case _ -> 0 } }"
      pure ()

    it "parses a for / then loop with a state variable" $ do
      body <-
        parseClean "agent main() -> integer {\n  for (let x in [1, 2, 3], var acc: integer = 0) {\n    next with { acc = acc + x }\n  } then (ys) { acc }\n}"
          >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionFor node) -> do
          length node.varBindings `shouldBe` 1
          node.thenClause `shouldSatisfy` (/= Nothing)
        _ -> expectationFailure "expected a for"

    it "parses a parallel for" $ do
      body <- parseClean "agent main() -> integer { parallel for (let x in xs) { next x } }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionFor node) -> node.parallel `shouldBe` True
        _ -> expectationFailure "expected a for"

    it "parses a parallel tuple" $ do
      body <- parseClean "agent main() -> integer { parallel [a, b, c] }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionTuple node) -> node.parallel `shouldBe` True
        _ -> expectationFailure "expected a tuple"

    it "parses a generic instantiation" $ do
      body <- parseClean "agent main() -> integer { identity[integer](x = 1) }" >>= soleAgentBody
      case body.returnExpression of
        Just (ExpressionCall node) -> case node.callee of
          ExpressionTypeApplication _ -> pure ()
          _ -> expectationFailure "expected a generic instantiation callee"
        _ -> expectationFailure "expected a call"

  describe "handlers, use, next/break" $ do
    it "parses a use of an inline handler with next/break" $ do
      body <-
        parseClean "agent main() -> integer {\n  use handler (var counter = 1) {\n    request tick() { next counter with { counter = counter + 1 } }\n  }\n  tick()\n}"
          >>= soleAgentBody
      case body.statements of
        (StatementUse useStatement : _) -> length useStatement.body.statements `shouldBe` 0
        _ -> expectationFailure "expected a leading use statement"

    it "parses a first-class handler value with generic arguments" $ do
      _ <- parseClean "agent make() -> integer { handler[R, pure] { request ask() { next 7 } } }"
      pure ()

    it "parses let-bound use" $ do
      body <- parseClean "agent main() -> integer {\n  let x = use provide\n  x * 7\n}" >>= soleAgentBody
      case body.statements of
        (StatementUse useStatement : _) -> useStatement.binder `shouldSatisfy` (/= Nothing)
        _ -> expectationFailure "expected a use statement"

  describe "comments and layout" $ do
    it "ignores line and block comments" $ do
      _ <- parseClean "// header\nagent main() -> integer {\n  let a = 1 // trailing\n  /* block */ a\n}"
      pure ()

    it "rejects two statements on one line without a separator" $
      shouldFail "agent main() -> integer { let x = 1 let y = 2 }"

    it "reports a diagnostic on malformed input" $
      shouldFail "agent main( -> string { }"

  describe "integer literals" $ do
    it "warns (K1002) on an integer literal beyond the safe range but still parses it" $ do
      -- 2^53 + 1: not representable exactly by a runtime number.
      let (module', diagnostics) = parseModule (ModuleName "test") "agent main() -> integer { 9007199254740993 }"
      map (compilerErrorCode . (.value)) (toList diagnostics) `shouldBe` ["K1002"]
      module'.declarations `shouldSatisfy` (not . null)
    it "does not warn at the safe-range boundary (2^53 - 1)" $
      codesOf "agent main() -> integer { 9007199254740991 }" `shouldBe` []

  describe "error recovery" $ do
    it "recovers at the next declaration and keeps the good ones" $ do
      let (module', diagnostics) = parseModule (ModuleName "test") "agent broken( -> integer { 1 }\n\nagent good() -> integer { 2 }"
      diagnostics `shouldNotSatisfy` null
      case module'.declarations of
        [DeclarationError _, DeclarationAgent agent] -> agent.name `shouldBe` "good"
        other -> expectationFailure ("expected [error, good agent], got " <> show (length other) <> " declarations")

    it "still parses earlier declarations before a broken one" $ do
      let (module', diagnostics) = parseModule (ModuleName "test") "data point(x: integer)\n\nagent broken() -> { 1 }\n\nagent fine() -> integer { 3 }"
      diagnostics `shouldNotSatisfy` null
      length module'.declarations `shouldBe` 3
